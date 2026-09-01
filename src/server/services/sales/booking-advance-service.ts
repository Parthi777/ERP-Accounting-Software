import 'server-only';

import { requirePermission, type TenantContext } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { add, fromDb, ZERO, type Paise } from '@/lib/money';
import { recordAudit } from '@/server/services/audit/record-audit';

/**
 * Booking advances as a liability — spec §18, §41.
 *
 * A booking advance is money the dealer holds and has not earned. It sits in
 * Customer Advances until the sale it was taken for is invoiced, and the longer
 * an unconverted booking sits there the more it matters — which is why this
 * screen ages the liability rather than merely listing bookings.
 */

export interface AdvanceReceiptRow {
  readonly paymentId: string;
  readonly bookingId: string;
  readonly bookingNumber: string;
  readonly receiptNumber: string;
  readonly paymentDate: string;
  readonly ageDays: number;
  readonly bucket: AgeBucket;
  readonly amount: Paise;
  readonly mode: string;
  readonly status: string;
  readonly customerId: string;
  readonly customerName: string;
  readonly customerCode: string;
  readonly modelLabel: string;
  readonly branchName: string;
  readonly bookingStatus: string;
  readonly journalEntryId: string | null;
}

export type AgeBucket = '0–30' | '31–60' | '61–90' | '90+';

const BUCKETS: readonly AgeBucket[] = ['0–30', '31–60', '61–90', '90+'];

function bucketFor(ageDays: number): AgeBucket {
  if (ageDays <= 30) return '0–30';
  if (ageDays <= 60) return '31–60';
  if (ageDays <= 90) return '61–90';
  return '90+';
}

export interface AdvanceAgeing {
  readonly buckets: readonly { bucket: AgeBucket; count: number; amount: Paise }[];
  /** Everything still held: receipts on bookings that are still open. */
  readonly outstanding: Paise;
  /** What Customer Advances says, for comparison. */
  readonly controlBalance: Paise;
}

function resolveBranch(context: TenantContext, requested: string | null): string | null {
  if (!requested) {
    return context.hasAllBranchAccess ? null : (context.activeBranch?.id ?? null);
  }
  return context.accessibleBranches.some((b) => b.id === requested)
    ? requested
    : (context.activeBranch?.id ?? null);
}

export async function getBookingAdvances(params: {
  readonly branchId: string | null;
  readonly status: string;
}): Promise<{ rows: AdvanceReceiptRow[]; ageing: AdvanceAgeing }> {
  const context = await requirePermission('bookings.view');
  const supabase = await createSupabaseServerClient();

  const branchId = resolveBranch(context, params.branchId);

  const [payments, control] = await Promise.all([
    supabase
      .from('booking_payments')
      .select(
        'id, booking_id, receipt_number, payment_date, amount, payment_mode, status, journal_entry_id, bookings!inner ( booking_number, status, branch_id, customer_id, customers!inner ( name, customer_code ), vehicle_models!inner ( brand, name ), branches!inner ( name ) )',
      )
      .order('payment_date', { ascending: false })
      .limit(500),
    // The control account, read independently. Advances taken before the
    // release was implemented are still sitting on 2100, and showing the two
    // side by side is how that difference stays visible rather than hidden.
    supabase
      .from('journal_entry_lines')
      .select('debit, credit, chart_of_accounts!inner ( code ), journal_entries!inner ( status )')
      .eq('chart_of_accounts.code', '2100')
      .limit(20000),
  ]);

  if (payments.error) {
    throw new Error(`Failed to load booking advances: ${payments.error.message}`);
  }
  if (control.error) {
    throw new Error(`Failed to load the control balance: ${control.error.message}`);
  }

  const today = new Date();

  let rows: AdvanceReceiptRow[] = (payments.data ?? []).map((row) => {
    const ageDays = Math.max(
      0,
      Math.floor((today.getTime() - new Date(row.payment_date).getTime()) / 86_400_000),
    );
    return {
      paymentId: row.id,
      bookingId: row.booking_id,
      bookingNumber: row.bookings.booking_number,
      receiptNumber: row.receipt_number,
      paymentDate: row.payment_date,
      ageDays,
      bucket: bucketFor(ageDays),
      amount: fromDb(row.amount),
      mode: row.payment_mode,
      status: row.status,
      customerId: row.bookings.customer_id,
      customerName: row.bookings.customers.name,
      customerCode: row.bookings.customers.customer_code,
      modelLabel: `${row.bookings.vehicle_models.brand} ${row.bookings.vehicle_models.name}`,
      branchName: row.bookings.branches.name,
      bookingStatus: row.bookings.status,
      journalEntryId: row.journal_entry_id,
    };
  });

  if (branchId) {
    const allowed = new Set(
      (payments.data ?? [])
        .filter((row) => row.bookings.branch_id === branchId)
        .map((row) => row.id),
    );
    rows = rows.filter((row) => allowed.has(row.paymentId));
  }
  if (params.status !== 'ALL') {
    rows = rows.filter((row) => row.bookingStatus === params.status);
  }

  // Still held: received, against a booking that has not converted or cancelled.
  const held = rows.filter((row) => row.status === 'RECEIVED' && row.bookingStatus === 'OPEN');

  const buckets = BUCKETS.map((bucket) => {
    const inBucket = held.filter((row) => row.bucket === bucket);
    return {
      bucket,
      count: inBucket.length,
      amount: inBucket.reduce((sum, row) => add(sum, row.amount), ZERO),
    };
  });

  const controlBalance = (control.data ?? []).reduce((sum, line) => {
    if (line.journal_entries.status !== 'POSTED' && line.journal_entries.status !== 'REVERSED') {
      return sum;
    }
    // A liability: credits increase what is held.
    return (sum + fromDb(line.credit) - fromDb(line.debit)) as Paise;
  }, ZERO);

  return {
    rows,
    ageing: {
      buckets,
      outstanding: held.reduce((sum, row) => add(sum, row.amount), ZERO),
      controlBalance,
    },
  };
}

export interface RefundResult {
  readonly ok: boolean;
  readonly error?: string;
  readonly message?: string;
}

export async function refundBookingAdvance(input: {
  readonly bookingId: string;
  readonly amount: number;
  readonly mode: 'CASH' | 'BANK';
  readonly reason: string;
  readonly bankAccountId?: string | null;
}): Promise<RefundResult> {
  const context = await requirePermission('bookings.refund');
  const supabase = await createSupabaseServerClient();

  if (!(input.amount > 0)) {
    return { ok: false, error: 'Enter a refund greater than zero.' };
  }
  if (!input.reason?.trim()) {
    return { ok: false, error: 'A refund must say why. The reason stays on the record.' };
  }
  if (input.mode === 'BANK' && !input.bankAccountId) {
    return { ok: false, error: 'Choose the bank account the refund was paid from.' };
  }

  const { error } = await supabase.rpc('refund_booking_advance', {
    p_booking_id: input.bookingId,
    p_amount: input.amount,
    p_mode: input.mode,
    p_reason: input.reason.trim(),
    p_cash_branch_id: context.activeBranch?.id ?? null,
    p_bank_account_id: input.bankAccountId || null,
  });

  if (error) {
    console.error('[bookings] refund failed', error.message);
    if (error.message.includes('cancel it before refunding')) {
      return { ok: false, error: 'Cancel the booking before refunding its advance.' };
    }
    if (error.message.includes('was received against')) {
      return { ok: false, error: error.message };
    }
    if (error.message.includes('day')) {
      return { ok: false, error: 'The cash book for today is closed. Reopen it or refund by bank.' };
    }
    return { ok: false, error: `The refund could not be recorded: ${error.message}` };
  }

  await recordAudit({
    action: 'REVERSE',
    entityType: 'booking_payments',
    entityId: input.bookingId,
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { refunded: input.amount, mode: input.mode },
    reason: input.reason.trim(),
  });

  return { ok: true, message: 'Refunded. The advance is cleared and the payment is in the book.' };
}
