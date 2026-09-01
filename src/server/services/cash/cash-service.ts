import 'server-only';

import { requirePermission, type TenantContext } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { formatINR, fromDb, type Paise } from '@/lib/money';
import { recordAudit } from '@/server/services/audit/record-audit';

/**
 * The daily cash book — spec §36, §37, §60.14, §60.15.
 *
 * Two rules shape everything here. First, cash is counted against a figure the
 * system computed, never against a figure the cashier typed — the difference is
 * the whole point of a close. Second, once a day is CLOSED its entries are
 * frozen; the trigger in migration 0022 refuses the write, so this layer's job
 * is to explain that in English rather than to prevent it.
 */

export interface CashEntry {
  readonly id: number;
  readonly time: string;
  readonly reference: string | null;
  readonly particular: string;
  readonly receipt: Paise;
  readonly payment: Paise;
  readonly balance: Paise;
  readonly journalEntryId: string | null;
}

export interface CashDay {
  readonly exists: boolean;
  readonly status: 'OPEN' | 'IN_PROGRESS' | 'COUNTED' | 'CLOSED';
  readonly businessDate: string;
  readonly branchId: string;
  readonly branchName: string;
  readonly accountName: string | null;
  readonly opening: Paise;
  readonly receipts: Paise;
  readonly payments: Paise;
  readonly expectedClosing: Paise;
  readonly physicalCash: Paise | null;
  readonly difference: Paise | null;
  readonly closedAt: string | null;
  readonly remarks: string | null;
  readonly reopenReason: string | null;
  readonly entries: readonly CashEntry[];
}

export interface CashResult {
  readonly ok: boolean;
  readonly error?: string;
  readonly message?: string;
}

/** Accounts a receipt or payment can be posted against, minus cash itself. */
export interface ContraAccount {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly type: string;
}

function activeBranch(context: TenantContext, requested?: string | null): string | null {
  if (requested && context.accessibleBranches.some((b) => b.id === requested)) {
    return requested;
  }
  return context.activeBranch?.id ?? null;
}

/**
 * The trigger messages are precise but they are written for whoever reads the
 * schema. These are written for whoever is holding the cash.
 */
function describeCashError(message: string): string {
  if (message.includes('is closed and cannot be changed')) {
    return 'The cash book for this date is closed. Reopen the day, or post an adjustment entry instead.';
  }
  if (message.includes('no cash account')) {
    return 'This branch has no cash account yet. An administrator must create one before cash can be recorded.';
  }
  if (message.includes('already closed')) {
    return 'This day has already been closed.';
  }
  if (message.includes('No accounting rule')) {
    return 'The ledger account for this entry is not configured. Set it under Administration → Accounting rules.';
  }
  if (message.includes('period') && message.includes('closed')) {
    return 'The accounting period for this date is closed.';
  }
  if (message.includes('greater than zero')) {
    return 'Enter an amount greater than zero.';
  }
  return message;
}

export async function getCashDay(params: {
  readonly date: string;
  readonly branchId?: string | null;
}): Promise<CashDay | null> {
  const context = await requirePermission('cashbook.view');
  const supabase = await createSupabaseServerClient();

  const branchId = activeBranch(context, params.branchId);
  if (!branchId) {
    return null;
  }
  const branch = context.accessibleBranches.find((b) => b.id === branchId);

  const [dayResult, entriesResult, accountResult] = await Promise.all([
    supabase
      .from('cash_day_closings')
      .select(
        'status, business_date, opening_balance, total_receipts, total_payments, expected_closing, physical_cash, difference, closed_at, remarks, reopen_reason',
      )
      .eq('branch_id', branchId)
      .eq('business_date', params.date)
      .maybeSingle(),
    supabase.rpc('cash_book', { p_branch_id: branchId, p_date: params.date }),
    supabase.from('cash_accounts').select('name, opening_balance').eq('branch_id', branchId).maybeSingle(),
  ]);

  if (entriesResult.error) {
    throw new Error(`Failed to load the cash book: ${entriesResult.error.message}`);
  }

  const day = dayResult.data;
  const entries: CashEntry[] = (entriesResult.data ?? []).map((row, index) => ({
    id: index,
    time: row.transaction_time,
    reference: row.reference_number,
    particular: row.particular,
    receipt: fromDb(row.receipt),
    payment: fromDb(row.payment),
    balance: fromDb(row.running_balance),
    journalEntryId: row.journal_entry_id,
  }));

  // No row yet means nobody has transacted today. That is a real, ordinary state
  // — an opening balance carried forward and nothing else — not an error.
  const opening = day
    ? fromDb(day.opening_balance)
    : fromDb(accountResult.data?.opening_balance ?? 0);

  return {
    exists: Boolean(day),
    status: (day?.status ?? 'OPEN') as CashDay['status'],
    businessDate: params.date,
    branchId,
    branchName: branch?.name ?? 'Branch',
    accountName: accountResult.data?.name ?? null,
    opening,
    receipts: fromDb(day?.total_receipts ?? 0),
    payments: fromDb(day?.total_payments ?? 0),
    expectedClosing: day ? fromDb(day.expected_closing) : opening,
    physicalCash: day?.physical_cash != null ? fromDb(day.physical_cash) : null,
    difference: day?.difference != null ? fromDb(day.difference) : null,
    closedAt: day?.closed_at ?? null,
    remarks: day?.remarks ?? null,
    reopenReason: day?.reopen_reason ?? null,
    entries,
  };
}

/**
 * Contra accounts for the picker. Cash accounts are excluded — a receipt from
 * cash into cash is not a transaction, and offering it invites the mistake.
 */
export async function getContraAccounts(direction: 'RECEIPT' | 'PAYMENT'): Promise<ContraAccount[]> {
  const context = await requirePermission('cashbook.view');
  const supabase = await createSupabaseServerClient();

  // A platform admin with no dealer in context has no chart of accounts to show.
  // RLS scopes everything below to the dealer regardless; this is just honest
  // about the empty case rather than issuing a query with a null filter.
  if (!context.dealerId) {
    return [];
  }

  const { data: cashLedgers } = await supabase
    .from('cash_accounts')
    .select('ledger_account_id')
    .eq('dealer_id', context.dealerId);

  const excluded = new Set((cashLedgers ?? []).map((c) => c.ledger_account_id));

  const { data, error } = await supabase
    .from('chart_of_accounts')
    .select('id, code, name, account_type, is_group, status')
    .eq('dealer_id', context.dealerId)
    .eq('is_group', false)
    .eq('status', 'ACTIVE')
    .order('code');

  if (error) {
    throw new Error(`Failed to load accounts: ${error.message}`);
  }

  // A receipt most often credits income or a receivable; a payment most often
  // debits an expense or a payable. Both lists stay complete — the ordering just
  // puts the likely answer near the top.
  const preferred =
    direction === 'RECEIPT'
      ? ['INCOME', 'ASSET', 'LIABILITY', 'EQUITY', 'EXPENSE']
      : ['EXPENSE', 'LIABILITY', 'ASSET', 'EQUITY', 'INCOME'];

  return (data ?? [])
    .filter((row) => !excluded.has(row.id))
    .map((row) => ({ id: row.id, code: row.code, name: row.name, type: row.account_type }))
    .sort((a, b) => {
      const byType = preferred.indexOf(a.type) - preferred.indexOf(b.type);
      return byType !== 0 ? byType : a.code.localeCompare(b.code);
    });
}

export interface CashTransactionInput {
  readonly direction: 'RECEIPT' | 'PAYMENT';
  readonly amount: number;
  readonly particular: string;
  readonly accountId: string;
  readonly customerId?: string | null;
  readonly reference?: string | null;
  readonly date: string;
}

export async function recordCashTransaction(input: CashTransactionInput): Promise<CashResult> {
  const context = await requirePermission(
    input.direction === 'RECEIPT' ? 'cashbook.receipts.create' : 'cashbook.payments.create',
  );
  const supabase = await createSupabaseServerClient();

  if (!context.activeBranch) {
    return { ok: false, error: 'Select a branch before recording cash.' };
  }
  if (!(input.amount > 0)) {
    return { ok: false, error: 'Enter an amount greater than zero.' };
  }
  if (!input.particular.trim()) {
    return { ok: false, error: 'Describe what this entry is for.' };
  }
  if (!input.accountId) {
    return { ok: false, error: 'Choose the account this posts against.' };
  }

  const { data, error } = await supabase.rpc('record_cash_transaction', {
    p_branch_id: context.activeBranch.id,
    p_direction: input.direction,
    p_amount: input.amount,
    p_particular: input.particular.trim(),
    p_account_id: input.accountId,
    p_customer_id: input.customerId || null,
    p_reference: input.reference?.trim() || null,
    p_date: input.date,
  });

  if (error) {
    console.error('[cash] record failed', error.message);
    return { ok: false, error: describeCashError(error.message) };
  }

  const row = Array.isArray(data) ? data[0] : data;

  await recordAudit({
    action: 'CREATE',
    entityType: 'cash_transactions',
    entityId: String(row?.transaction_id ?? ''),
    dealerId: context.dealerId,
    branchId: context.activeBranch.id,
    userId: context.userId,
    userEmail: context.email,
    newData: {
      direction: input.direction,
      amount: input.amount,
      particular: input.particular,
      date: input.date,
    },
  });

  return { ok: true, message: `Recorded. Cash in hand is now ${formatINR(fromDb(row?.balance_after ?? 0))}.` };
}

export async function closeCashDay(input: {
  readonly date: string;
  readonly physicalCash: number;
  readonly denominations?: Record<string, number> | null;
  readonly remarks?: string | null;
}): Promise<CashResult> {
  const context = await requirePermission('cashbook.day_close');
  const supabase = await createSupabaseServerClient();

  if (!context.activeBranch) {
    return { ok: false, error: 'Select a branch before closing the day.' };
  }
  if (!(input.physicalCash >= 0)) {
    return { ok: false, error: 'Enter the physical cash counted.' };
  }

  const { data, error } = await supabase.rpc('close_cash_day', {
    p_branch_id: context.activeBranch.id,
    p_date: input.date,
    p_physical_cash: input.physicalCash,
    p_denominations: input.denominations ?? null,
    p_remarks: input.remarks?.trim() || null,
  });

  if (error) {
    console.error('[cash] close failed', error.message);
    return { ok: false, error: describeCashError(error.message) };
  }

  const row = Array.isArray(data) ? data[0] : data;
  const difference = fromDb(row?.difference ?? 0);

  await recordAudit({
    action: 'UPDATE',
    entityType: 'cash_day_closings',
    entityId: `${context.activeBranch.id}:${input.date}`,
    dealerId: context.dealerId,
    branchId: context.activeBranch.id,
    userId: context.userId,
    userEmail: context.email,
    newData: {
      status: 'CLOSED',
      expected: row?.expected,
      counted: row?.counted,
      difference: row?.difference,
    },
  });

  return {
    ok: true,
    message:
      difference === 0
        ? 'Day closed. Cash tallies exactly.'
        : `Day closed with a difference of ${difference > 0 ? 'excess' : 'shortage'}.`,
  };
}

export async function reopenCashDay(input: {
  readonly date: string;
  readonly reason: string;
}): Promise<CashResult> {
  const context = await requirePermission('cashbook.day_reopen');
  const supabase = await createSupabaseServerClient();

  if (!context.activeBranch) {
    return { ok: false, error: 'Select a branch first.' };
  }
  if (!input.reason.trim()) {
    return { ok: false, error: 'A reason is required to reopen a closed day.' };
  }

  const { error } = await supabase.rpc('reopen_cash_day', {
    p_branch_id: context.activeBranch.id,
    p_date: input.date,
    p_reason: input.reason.trim(),
  });

  if (error) {
    return { ok: false, error: describeCashError(error.message) };
  }

  await recordAudit({
    action: 'UPDATE',
    entityType: 'cash_day_closings',
    entityId: `${context.activeBranch.id}:${input.date}`,
    dealerId: context.dealerId,
    branchId: context.activeBranch.id,
    userId: context.userId,
    userEmail: context.email,
    newData: { status: 'REOPENED', reason: input.reason },
  });

  return { ok: true, message: 'The day is reopened for adjustment.' };
}

export interface CashDayHistoryRow {
  readonly businessDate: string;
  readonly branchName: string;
  readonly status: string;
  readonly opening: Paise;
  readonly receipts: Paise;
  readonly payments: Paise;
  readonly expected: Paise;
  readonly counted: Paise | null;
  readonly difference: Paise | null;
}

/** Recent closes, so an unexplained difference is visible rather than buried. */
export async function getCashDayHistory(days = 30): Promise<CashDayHistoryRow[]> {
  const context = await requirePermission('cashbook.view');
  const supabase = await createSupabaseServerClient();

  let query = supabase
    .from('cash_day_closings')
    .select(
      'business_date, status, opening_balance, total_receipts, total_payments, expected_closing, physical_cash, difference, branches!inner ( name )',
    )
    .order('business_date', { ascending: false })
    .limit(days);

  if (!context.hasAllBranchAccess && context.activeBranch) {
    query = query.eq('branch_id', context.activeBranch.id);
  }

  const { data, error } = await query;
  if (error) {
    throw new Error(`Failed to load closing history: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    businessDate: row.business_date,
    branchName: row.branches.name,
    status: row.status,
    opening: fromDb(row.opening_balance),
    receipts: fromDb(row.total_receipts),
    payments: fromDb(row.total_payments),
    expected: fromDb(row.expected_closing),
    counted: row.physical_cash != null ? fromDb(row.physical_cash) : null,
    difference: row.difference != null ? fromDb(row.difference) : null,
  }));
}
