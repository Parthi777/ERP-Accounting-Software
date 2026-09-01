import 'server-only';

import { requirePermission } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { formatINR, fromDb, type Paise } from '@/lib/money';
import { recordAudit } from '@/server/services/audit/record-audit';

/**
 * Bank book and reconciliation — spec §38, §39.
 *
 * Reconciliation is where a dealer finds out whether the books are true. The
 * rule the module turns on: a statement line is never marked reconciled without
 * a recorded link to the book entry it matched. Auto-matching therefore
 * *proposes*; a person accepts. That is what makes the audit trail worth having.
 */

export interface BankAccountSummary {
  readonly id: string;
  readonly name: string;
  readonly bankName: string;
  readonly accountNumber: string;
  readonly ifsc: string | null;
  readonly accountType: string;
  readonly branchName: string | null;
  readonly currentBalance: Paise;
  readonly status: string;
  readonly unreconciled: number;
}

export interface BankEntry {
  readonly id: number;
  readonly date: string;
  readonly particular: string;
  readonly reference: string | null;
  readonly utr: string | null;
  readonly receipt: Paise;
  readonly payment: Paise;
  readonly balance: Paise;
  readonly reconciled: boolean;
  readonly journalEntryId: string | null;
}

export interface StatementLine {
  readonly id: number;
  readonly statementDate: string;
  readonly narration: string;
  readonly reference: string | null;
  readonly utr: string | null;
  readonly debit: Paise;
  readonly credit: Paise;
  readonly matchStatus: string;
  readonly matchedTransactionId: number | null;
  readonly locked: boolean;
}

export interface MatchSuggestion {
  readonly statementLineId: number;
  readonly statementDate: string;
  readonly narration: string;
  readonly debit: Paise;
  readonly credit: Paise;
  readonly transactionId: number;
  readonly transactionDate: string;
  readonly particular: string;
  readonly amount: Paise;
  readonly confidence: 'EXACT' | 'LIKELY' | 'POSSIBLE';
  readonly reason: string;
}

export interface BankResult {
  readonly ok: boolean;
  readonly error?: string;
  readonly message?: string;
}

function describeBankError(message: string): string {
  if (message.includes('already matched')) {
    return 'That statement line has already been matched to a book entry.';
  }
  if (message.includes('already reconciled')) {
    return 'That book entry is already reconciled against another statement line.';
  }
  if (message.includes('amounts differ')) {
    return message.replace('The amounts differ:', 'The amounts do not match:');
  }
  if (message.includes('completed reconciliation')) {
    return 'This line belongs to a completed reconciliation and can no longer be unmatched.';
  }
  if (message.includes('No accounting rule')) {
    return 'The ledger account for this entry is not configured. Set it under Administration → Accounting rules.';
  }
  if (message.includes('No document sequence')) {
    return 'No reconciliation number sequence is configured for this financial year.';
  }
  if (message.includes('period') && message.includes('closed')) {
    return 'The accounting period for this date is closed.';
  }
  return message;
}

export async function getBankAccounts(): Promise<BankAccountSummary[]> {
  await requirePermission('bank.accounts.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase
    .from('bank_accounts')
    .select('id, name, bank_name, account_number, ifsc, account_type, current_balance, status, branches ( name )')
    .order('name');

  if (error) {
    throw new Error(`Failed to load bank accounts: ${error.message}`);
  }

  const accounts = data ?? [];

  // One count query for all accounts rather than one per account.
  const { data: pending } = await supabase
    .from('bank_transactions')
    .select('bank_account_id')
    .eq('reconciled', false)
    .eq('status', 'ACTIVE');

  const unreconciled = new Map<string, number>();
  for (const row of pending ?? []) {
    unreconciled.set(row.bank_account_id, (unreconciled.get(row.bank_account_id) ?? 0) + 1);
  }

  return accounts.map((row) => ({
    id: row.id,
    name: row.name,
    bankName: row.bank_name,
    accountNumber: row.account_number,
    ifsc: row.ifsc,
    accountType: row.account_type,
    branchName: row.branches?.name ?? null,
    currentBalance: fromDb(row.current_balance),
    status: row.status,
    unreconciled: unreconciled.get(row.id) ?? 0,
  }));
}

export async function getBankBook(params: {
  readonly bankAccountId: string;
  readonly from?: string | null;
  readonly to?: string | null;
}): Promise<BankEntry[]> {
  await requirePermission('bank.book.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('bank_book', {
    p_bank_account_id: params.bankAccountId,
    p_from_date: params.from || null,
    p_to_date: params.to || null,
  });

  if (error) {
    throw new Error(`Failed to load the bank book: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    id: row.id,
    date: row.transaction_date,
    particular: row.particular,
    reference: row.reference_number,
    utr: row.utr,
    receipt: fromDb(row.receipt),
    payment: fromDb(row.payment),
    balance: fromDb(row.running_balance),
    reconciled: row.reconciled,
    journalEntryId: row.journal_entry_id,
  }));
}

export interface BankTransactionInput {
  readonly bankAccountId: string;
  readonly direction: 'RECEIPT' | 'PAYMENT';
  readonly amount: number;
  readonly particular: string;
  readonly accountId: string;
  readonly date: string;
  readonly reference?: string | null;
  readonly utr?: string | null;
  readonly instrument?: string | null;
}

export async function recordBankTransaction(input: BankTransactionInput): Promise<BankResult> {
  const context = await requirePermission('bank.book.record');
  const supabase = await createSupabaseServerClient();

  if (!(input.amount > 0)) {
    return { ok: false, error: 'Enter an amount greater than zero.' };
  }
  if (!input.particular.trim()) {
    return { ok: false, error: 'Describe what this entry is for.' };
  }
  if (!input.accountId) {
    return { ok: false, error: 'Choose the account this posts against.' };
  }

  const { data, error } = await supabase.rpc('record_bank_transaction', {
    p_bank_account_id: input.bankAccountId,
    p_direction: input.direction,
    p_amount: input.amount,
    p_particular: input.particular.trim(),
    p_account_id: input.accountId,
    p_date: input.date,
    p_reference: input.reference?.trim() || null,
    p_utr: input.utr?.trim() || null,
    p_instrument: input.instrument?.trim() || null,
  });

  if (error) {
    console.error('[bank] record failed', error.message);
    return { ok: false, error: describeBankError(error.message) };
  }

  const row = Array.isArray(data) ? data[0] : data;

  await recordAudit({
    action: 'CREATE',
    entityType: 'bank_transactions',
    entityId: String(row?.transaction_id ?? ''),
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { direction: input.direction, amount: input.amount, particular: input.particular },
  });

  return { ok: true, message: `Recorded. Balance is now ${formatINR(fromDb(row?.balance_after ?? 0))}.` };
}

// ── Statement import ─────────────────────────────────────────────────────────

export interface ParsedStatementRow {
  readonly statement_date: string;
  readonly value_date?: string | null;
  readonly narration: string;
  readonly reference?: string | null;
  readonly utr?: string | null;
  readonly cheque_number?: string | null;
  readonly debit: number;
  readonly credit: number;
  readonly running_balance?: number | null;
}

export interface ImportResult extends BankResult {
  readonly imported?: number;
  readonly skipped?: number;
}

export async function importStatement(
  bankAccountId: string,
  rows: readonly ParsedStatementRow[],
): Promise<ImportResult> {
  const context = await requirePermission('bank.statement.import');
  const supabase = await createSupabaseServerClient();

  if (rows.length === 0) {
    return { ok: false, error: 'The file contained no usable rows.' };
  }

  const { data, error } = await supabase.rpc('import_bank_statement', {
    p_bank_account_id: bankAccountId,
    p_rows: rows as unknown as never,
  });

  if (error) {
    console.error('[bank] import failed', error.message);
    return { ok: false, error: describeBankError(error.message) };
  }

  const row = Array.isArray(data) ? data[0] : data;
  const imported = Number(row?.imported ?? 0);
  const skipped = Number(row?.skipped ?? 0);

  await recordAudit({
    action: 'CREATE',
    entityType: 'bank_statement_lines',
    entityId: String(row?.import_batch ?? ''),
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { bank_account_id: bankAccountId, imported, skipped },
  });

  return {
    ok: true,
    imported,
    skipped,
    message:
      skipped > 0
        ? `Imported ${imported} lines. ${skipped} were skipped as duplicates or unreadable.`
        : `Imported ${imported} lines.`,
  };
}

export type StatementLineStatus = 'UNMATCHED' | 'MATCHED' | 'PARTIAL' | 'IGNORED';

export async function getStatementLines(params: {
  readonly bankAccountId: string;
  readonly status?: StatementLineStatus | 'ALL';
}): Promise<StatementLine[]> {
  await requirePermission('bank.reconcile');
  const supabase = await createSupabaseServerClient();

  let query = supabase
    .from('bank_statement_lines')
    .select('id, statement_date, narration, reference, utr, debit, credit, match_status, matched_transaction_id, reconciliation_id')
    .eq('bank_account_id', params.bankAccountId)
    .order('statement_date')
    .limit(500);

  if (params.status && params.status !== 'ALL') {
    query = query.eq('match_status', params.status);
  }

  const { data, error } = await query;
  if (error) {
    throw new Error(`Failed to load statement lines: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    id: row.id,
    statementDate: row.statement_date,
    narration: row.narration,
    reference: row.reference,
    utr: row.utr,
    debit: fromDb(row.debit),
    credit: fromDb(row.credit),
    matchStatus: row.match_status,
    matchedTransactionId: row.matched_transaction_id,
    // Part of a completed reconciliation: settled, and not to be unpicked.
    locked: row.reconciliation_id != null,
  }));
}

export async function getMatchSuggestions(bankAccountId: string): Promise<MatchSuggestion[]> {
  await requirePermission('bank.reconcile');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('suggest_bank_matches', {
    p_bank_account_id: bankAccountId,
    p_date_window: 5,
  });

  if (error) {
    throw new Error(`Failed to compute matches: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    statementLineId: row.statement_line_id,
    statementDate: row.statement_date,
    narration: row.narration,
    debit: fromDb(row.debit),
    credit: fromDb(row.credit),
    transactionId: row.transaction_id,
    transactionDate: row.transaction_date,
    particular: row.particular,
    amount: fromDb(row.amount),
    confidence: row.confidence as MatchSuggestion['confidence'],
    reason: row.reason,
  }));
}

export async function matchLine(statementLineId: number, transactionId: number): Promise<BankResult> {
  const context = await requirePermission('bank.reconcile');
  const supabase = await createSupabaseServerClient();

  const { error } = await supabase.rpc('match_bank_line', {
    p_statement_line_id: statementLineId,
    p_transaction_id: transactionId,
  });

  if (error) {
    return { ok: false, error: describeBankError(error.message) };
  }

  await recordAudit({
    action: 'UPDATE',
    entityType: 'bank_statement_lines',
    entityId: String(statementLineId),
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { match_status: 'MATCHED', matched_transaction_id: transactionId },
  });

  return { ok: true, message: 'Matched.' };
}

export async function unmatchLine(statementLineId: number): Promise<BankResult> {
  const context = await requirePermission('bank.reconcile');
  const supabase = await createSupabaseServerClient();

  const { error } = await supabase.rpc('unmatch_bank_line', { p_statement_line_id: statementLineId });
  if (error) {
    return { ok: false, error: describeBankError(error.message) };
  }

  await recordAudit({
    action: 'UPDATE',
    entityType: 'bank_statement_lines',
    entityId: String(statementLineId),
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { match_status: 'UNMATCHED' },
  });

  return { ok: true, message: 'Unmatched.' };
}

export async function ignoreLine(statementLineId: number): Promise<BankResult> {
  await requirePermission('bank.reconcile');
  const supabase = await createSupabaseServerClient();

  const { error } = await supabase.rpc('ignore_bank_line', { p_statement_line_id: statementLineId });
  if (error) {
    return { ok: false, error: describeBankError(error.message) };
  }
  return { ok: true, message: 'Line ignored.' };
}

export async function completeReconciliation(input: {
  readonly bankAccountId: string;
  readonly from: string;
  readonly to: string;
  readonly statementClosing: number;
  readonly notes?: string | null;
}): Promise<BankResult> {
  const context = await requirePermission('bank.reconcile');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('complete_bank_reconciliation', {
    p_bank_account_id: input.bankAccountId,
    p_from_date: input.from,
    p_to_date: input.to,
    p_statement_closing: input.statementClosing,
    p_notes: input.notes?.trim() || null,
  });

  if (error) {
    console.error('[bank] reconciliation failed', error.message);
    return { ok: false, error: describeBankError(error.message) };
  }

  const row = Array.isArray(data) ? data[0] : data;
  const difference = fromDb(row?.difference ?? 0);

  await recordAudit({
    action: 'CREATE',
    entityType: 'bank_reconciliations',
    entityId: String(row?.reconciliation_id ?? ''),
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { number: row?.number, difference: row?.difference, unmatched: row?.unmatched },
  });

  return {
    ok: true,
    message:
      difference === 0
        ? `${row?.number}: reconciled, statement and book agree.`
        : `${row?.number}: completed with a difference of ${formatINR(difference)} still to explain.`,
  };
}

export interface ReconciliationRow {
  readonly id: string;
  readonly number: string;
  readonly accountName: string;
  readonly fromDate: string;
  readonly toDate: string;
  readonly statementClosing: Paise;
  readonly bookClosing: Paise;
  readonly difference: Paise;
  readonly matched: number;
  readonly unmatched: number;
  readonly status: string;
}

export async function getReconciliations(): Promise<ReconciliationRow[]> {
  await requirePermission('bank.reconcile');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase
    .from('bank_reconciliations')
    .select(
      'id, reconciliation_number, from_date, to_date, statement_closing_balance, book_closing_balance, difference, matched_count, unmatched_count, status, bank_accounts!inner ( name )',
    )
    .order('to_date', { ascending: false })
    .limit(50);

  if (error) {
    throw new Error(`Failed to load reconciliations: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    id: row.id,
    number: row.reconciliation_number,
    accountName: row.bank_accounts.name,
    fromDate: row.from_date,
    toDate: row.to_date,
    statementClosing: fromDb(row.statement_closing_balance),
    bookClosing: fromDb(row.book_closing_balance),
    difference: fromDb(row.difference),
    matched: row.matched_count,
    unmatched: row.unmatched_count,
    status: row.status,
  }));
}
