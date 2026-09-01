import 'server-only';

import { requirePermission, type TenantContext } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { fromDb, type Paise } from '@/lib/money';
import { recordAudit } from '@/server/services/audit/record-audit';

/**
 * Bookings — spec §18.
 *
 * The accounting rule that matters: a booking advance is money held, not revenue
 * earned. It posts Cash/Bank Dr → Customer Advances Cr, and revenue is only
 * recognised when the booking becomes a sale. The
 * `accounting.booking_recognises_revenue` setting exists to make that policy
 * explicit rather than assumed.
 */

export interface BookingListRow {
  readonly id: string;
  readonly bookingNumber: string;
  readonly bookingDate: string;
  readonly customerName: string;
  readonly customerCode: string;
  readonly modelLabel: string;
  readonly branchName: string;
  readonly bookingAmount: Paise;
  readonly receivedAmount: Paise;
  readonly status: string;
  readonly expectedDelivery: string | null;
}

function resolveBranch(context: TenantContext, requested: string | null): string | null {
  if (!requested) {
    return context.hasAllBranchAccess ? null : (context.activeBranch?.id ?? null);
  }
  return context.accessibleBranches.some((b) => b.id === requested)
    ? requested
    : (context.activeBranch?.id ?? null);
}

export async function getBookings(params: {
  readonly status: string;
  readonly branchId: string | null;
  readonly q?: string;
  /**
   * Row cap. Defaults to the screen's, which is all anyone scrolls; the
   * report exporter raises it, because a spreadsheet has no such limit and a
   * silently truncated financial extract is worse than none.
   */
  readonly limit?: number;
}): Promise<BookingListRow[]> {
  const context = await requirePermission('bookings.view');
  const supabase = await createSupabaseServerClient();

  let query = supabase
    .from('bookings')
    .select(
      'id, booking_number, booking_date, booking_amount, received_amount, status, expected_delivery, customers!inner ( name, customer_code ), vehicle_models!inner ( brand, name ), branches!inner ( name )',
    )
    .order('booking_date', { ascending: false })
    .limit(params.limit ?? 200);

  if (params.status !== 'ALL') {
    query = query.eq('status', params.status as 'OPEN');
  }
  const branchId = resolveBranch(context, params.branchId);
  if (branchId) {
    query = query.eq('branch_id', branchId);
  }

  const { data, error } = await query;
  if (error) {
    throw new Error(`Failed to load bookings: ${error.message}`);
  }

  const term = params.q?.trim().toLowerCase();

  return (data ?? [])
    .map((row) => ({
      id: row.id,
      bookingNumber: row.booking_number,
      bookingDate: row.booking_date,
      customerName: row.customers.name,
      customerCode: row.customers.customer_code,
      modelLabel: `${row.vehicle_models.brand} ${row.vehicle_models.name}`,
      branchName: row.branches.name,
      bookingAmount: fromDb(row.booking_amount),
      receivedAmount: fromDb(row.received_amount),
      status: row.status,
      expectedDelivery: row.expected_delivery,
    }))
    // Filtering here rather than in the query: the joined customer name is not
    // reachable from a PostgREST `or` filter on the parent table.
    .filter(
      (row) =>
        !term ||
        row.bookingNumber.toLowerCase().includes(term) ||
        row.customerName.toLowerCase().includes(term) ||
        row.customerCode.toLowerCase().includes(term),
    );
}

export interface BookingDetail {
  readonly booking: {
    readonly id: string;
    readonly bookingNumber: string;
    readonly bookingDate: string;
    readonly status: string;
    readonly bookingAmount: Paise;
    readonly receivedAmount: Paise;
    readonly expectedDelivery: string | null;
    readonly notes: string | null;
    readonly cancelledReason: string | null;
    readonly convertedSaleId: string | null;
    readonly customerId: string;
    readonly modelId: string;
    readonly variantId: string | null;
  };
  readonly customerName: string;
  readonly customerCode: string;
  readonly customerMobile: string;
  readonly modelLabel: string;
  readonly branchName: string;
  readonly payments: readonly {
    readonly id: string;
    readonly receiptNumber: string;
    readonly paymentDate: string;
    readonly amount: Paise;
    readonly mode: string;
    readonly reference: string | null;
    readonly journalEntryId: string | null;
  }[];
}

export async function getBooking(id: string): Promise<BookingDetail | null> {
  await requirePermission('bookings.view');
  const supabase = await createSupabaseServerClient();

  const [{ data, error }, { data: payments }] = await Promise.all([
    supabase
      .from('bookings')
      .select('*, customers ( name, customer_code, mobile ), vehicle_models ( brand, name ), branches ( name )')
      .eq('id', id)
      .maybeSingle(),
    supabase
      .from('booking_payments')
      .select('id, receipt_number, payment_date, amount, payment_mode, reference, journal_entry_id')
      .eq('booking_id', id)
      .order('payment_date'),
  ]);

  if (error) {
    throw new Error(`Failed to load the booking: ${error.message}`);
  }
  if (!data) {
    return null;
  }

  return {
    booking: {
      id: data.id,
      bookingNumber: data.booking_number,
      bookingDate: data.booking_date,
      status: data.status,
      bookingAmount: fromDb(data.booking_amount),
      receivedAmount: fromDb(data.received_amount),
      expectedDelivery: data.expected_delivery,
      notes: data.notes,
      cancelledReason: data.cancelled_reason,
      convertedSaleId: data.converted_sale_id,
      customerId: data.customer_id,
      modelId: data.model_id,
      variantId: data.variant_id,
    },
    customerName: data.customers.name,
    customerCode: data.customers.customer_code,
    customerMobile: data.customers.mobile,
    modelLabel: `${data.vehicle_models.brand} ${data.vehicle_models.name}`,
    branchName: data.branches.name,
    payments: (payments ?? []).map((p) => ({
      id: p.id,
      receiptNumber: p.receipt_number,
      paymentDate: p.payment_date,
      amount: fromDb(p.amount),
      mode: p.payment_mode,
      reference: p.reference,
      journalEntryId: p.journal_entry_id,
    })),
  };
}

export interface CreateBookingInput {
  readonly customer_id: string;
  readonly model_id: string;
  readonly variant_id?: string;
  readonly vehicle_id?: string;
  readonly booking_amount: number;
  readonly advance_amount: number;
  readonly payment_mode: string;
  readonly reference?: string;
  readonly expected_delivery?: string;
  readonly sales_executive_id?: string;
  readonly notes?: string;
}

export interface BookingResult {
  readonly ok: boolean;
  readonly id?: string;
  readonly bookingNumber?: string;
  readonly error?: string;
}

/**
 * Creates a booking, its advance receipt and the journal.
 *
 * One RPC, not three REST calls. Each REST call is its own transaction, so doing
 * this in steps could leave a receipt the ledger never saw. The database function
 * does all three or none (spec §48).
 */
export async function createBooking(input: CreateBookingInput): Promise<BookingResult> {
  const context = await requirePermission('bookings.create');
  const supabase = await createSupabaseServerClient();

  if (!context.activeBranch) {
    return { ok: false, error: 'Select a branch before creating a booking.' };
  }
  if (input.advance_amount <= 0) {
    return { ok: false, error: 'Enter the advance amount received.' };
  }

  const { data, error } = await supabase.rpc('create_booking_with_advance', {
    p_customer_id: input.customer_id,
    p_model_id: input.model_id,
    p_branch_id: context.activeBranch.id,
    p_booking_amount: input.booking_amount,
    p_advance_amount: input.advance_amount,
    p_payment_mode: input.payment_mode,
    p_variant_id: input.variant_id || null,
    p_vehicle_id: input.vehicle_id || null,
    p_expected_delivery: input.expected_delivery || null,
    p_sales_executive_id: input.sales_executive_id || null,
    p_reference: input.reference || null,
    p_notes: input.notes || null,
  });

  if (error) {
    console.error('[bookings] create failed', error.message);
    return { ok: false, error: describeBookingError(error.message) };
  }

  const row = Array.isArray(data) ? data[0] : data;
  if (!row) {
    return { ok: false, error: 'The booking could not be created.' };
  }

  await recordAudit({
    action: 'CREATE',
    entityType: 'bookings',
    entityId: row.booking_id,
    dealerId: context.dealerId,
    branchId: context.activeBranch.id,
    userId: context.userId,
    userEmail: context.email,
    newData: { booking_number: row.booking_number, advance: input.advance_amount },
  });

  return { ok: true, id: row.booking_id, bookingNumber: row.booking_number };
}

/** Turns a database error into something a cashier can act on (spec §55). */
function describeBookingError(message: string): string {
  if (message.includes('No accounting rule')) {
    return 'Accounting rules for booking advances are not configured. Ask Accounts to set them up before taking bookings.';
  }
  if (message.includes('No document sequence configured')) {
    return 'No booking or receipt number sequence is configured for this branch and year. Add one under Administration → Settings.';
  }
  if (message.includes('advance cannot exceed')) {
    return 'The advance cannot exceed the booking amount.';
  }
  if (message.includes('row-level security')) {
    return 'You do not have permission to create bookings at this branch.';
  }
  if (message.includes('duplicate key')) {
    return 'That booking number was just used. Try again.';
  }
  return 'The booking could not be created. Nothing was saved.';
}

export async function cancelBooking(id: string, reason: string): Promise<BookingResult> {
  const context = await requirePermission('bookings.cancel');
  const supabase = await createSupabaseServerClient();

  if (!reason.trim()) {
    return { ok: false, error: 'A cancellation reason is required.' };
  }

  const { error } = await supabase
    .from('bookings')
    .update({ status: 'CANCELLED', cancelled_reason: reason, updated_by: context.userId })
    .eq('id', id)
    .eq('status', 'OPEN');

  if (error) {
    return { ok: false, error: `The booking could not be cancelled: ${error.message}` };
  }

  await recordAudit({
    action: 'CANCEL',
    entityType: 'bookings',
    entityId: id,
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    reason,
  });

  return { ok: true, id };
}
