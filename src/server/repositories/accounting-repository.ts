import 'server-only';

import { createSupabaseServerClient } from '@/lib/supabase/server';
import { fromDb, type Paise } from '@/lib/money';
import type { JournalStatus, Tables } from '@/types/database.types';

/** The module column is a union; a filter value has to be one of its members. */
export type SourceModule = Tables<'journal_entries'>['source_module'];

/**
 * Accounting reads.
 *
 * Every figure here comes from the same posted journals — there is one ledger and
 * one source of truth (spec §60.18). The report functions are SECURITY INVOKER,
 * so RLS scopes them to the caller without this layer filtering by dealer.
 */

export interface ChartAccount {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly type: Tables<'chart_of_accounts'>['account_type'];
  readonly normalBalance: 'DEBIT' | 'CREDIT';
  readonly isGroup: boolean;
  readonly isSystem: boolean;
  readonly parentId: string | null;
  readonly status: string;
}

export async function listChartOfAccounts(): Promise<ChartAccount[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from('chart_of_accounts')
    .select('id, code, name, account_type, normal_balance, is_group, is_system, parent_id, status')
    .order('code');

  if (error) {
    throw new Error(`Failed to load the chart of accounts: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    id: row.id,
    code: row.code,
    name: row.name,
    type: row.account_type,
    normalBalance: row.normal_balance,
    isGroup: row.is_group,
    isSystem: row.is_system,
    parentId: row.parent_id,
    status: row.status,
  }));
}

export interface JournalSummary {
  readonly id: string;
  readonly entryNumber: string;
  readonly entryDate: string;
  readonly sourceModule: string;
  readonly narration: string | null;
  readonly status: string;
  readonly totalDebit: Paise;
  readonly reversalOfId: string | null;
  readonly reversedById: string | null;
  readonly branchName: string | null;
}

export async function listJournals(params: {
  readonly from: string;
  readonly to: string;
  readonly branchId: string | null;
  readonly module: SourceModule | null;
  // Narrowed rather than plain string: the columns are unions, and eq() checks
  // the value against them.
  readonly status: JournalStatus | null;
  readonly limit?: number;
}): Promise<JournalSummary[]> {
  const supabase = await createSupabaseServerClient();

  let query = supabase
    .from('journal_entries')
    .select(
      'id, entry_number, entry_date, source_module, narration, status, total_debit, reversal_of_id, reversed_by_id, branches ( name )',
    )
    .gte('entry_date', params.from)
    .lte('entry_date', params.to)
    .order('entry_date', { ascending: false })
    .order('entry_number', { ascending: false })
    .limit(params.limit ?? 200);

  if (params.branchId) {
    query = query.eq('branch_id', params.branchId);
  }
  if (params.module) {
    query = query.eq('source_module', params.module);
  }
  if (params.status) {
    query = query.eq('status', params.status);
  }

  const { data, error } = await query;
  if (error) {
    throw new Error(`Failed to load journal entries: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    id: row.id,
    entryNumber: row.entry_number,
    entryDate: row.entry_date,
    sourceModule: row.source_module,
    narration: row.narration,
    status: row.status,
    totalDebit: fromDb(row.total_debit),
    reversalOfId: row.reversal_of_id,
    reversedById: row.reversed_by_id,
    branchName: row.branches?.name ?? null,
  }));
}

export interface JournalLine {
  readonly lineNumber: number;
  readonly accountCode: string;
  readonly accountName: string;
  readonly narration: string | null;
  readonly debit: Paise;
  readonly credit: Paise;
  readonly partyType: string | null;
}

export interface JournalDetail {
  readonly entry: Tables<'journal_entries'>;
  readonly lines: readonly JournalLine[];
}

export async function getJournal(id: string): Promise<JournalDetail | null> {
  const supabase = await createSupabaseServerClient();

  const [{ data: entry, error: entryError }, { data: lines, error: lineError }] = await Promise.all([
    supabase.from('journal_entries').select('*').eq('id', id).maybeSingle(),
    supabase
      .from('journal_entry_lines')
      .select('line_number, narration, debit, credit, party_type, chart_of_accounts ( code, name )')
      .eq('journal_entry_id', id)
      .order('line_number'),
  ]);

  if (entryError) {
    throw new Error(`Failed to load the journal entry: ${entryError.message}`);
  }
  if (lineError) {
    throw new Error(`Failed to load journal lines: ${lineError.message}`);
  }
  if (!entry) {
    return null;
  }

  return {
    entry,
    lines: (lines ?? []).map((row) => ({
      lineNumber: row.line_number,
      accountCode: row.chart_of_accounts.code,
      accountName: row.chart_of_accounts.name,
      narration: row.narration,
      debit: fromDb(row.debit),
      credit: fromDb(row.credit),
      partyType: row.party_type,
    })),
  };
}

export interface TrialBalanceRow {
  readonly code: string;
  readonly name: string;
  // The report function returns this as plain text; only the table column
  // carries the union.
  readonly type: string;
  readonly debit: Paise;
  readonly credit: Paise;
}

export async function getTrialBalance(asOn: string, branchId: string | null): Promise<TrialBalanceRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('trial_balance', {
    p_as_on: asOn,
    p_branch_id: branchId,
  });

  if (error) {
    throw new Error(`Failed to load the trial balance: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    code: row.account_code,
    name: row.account_name,
    type: row.account_type,
    debit: fromDb(row.debit_balance),
    credit: fromDb(row.credit_balance),
  }));
}

export interface StatementRow {
  readonly section: string;
  readonly code: string;
  readonly name: string;
  readonly amount: Paise;
}

export async function getProfitAndLoss(
  from: string,
  to: string,
  branchId: string | null,
): Promise<StatementRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('profit_and_loss', {
    p_from: from,
    p_to: to,
    p_branch_id: branchId,
  });

  if (error) {
    throw new Error(`Failed to load the profit and loss statement: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    section: row.section,
    code: row.account_code,
    name: row.account_name,
    amount: fromDb(row.amount),
  }));
}

export async function getBalanceSheet(asOn: string, branchId: string | null): Promise<StatementRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('balance_sheet', {
    p_as_on: asOn,
    p_branch_id: branchId,
  });

  if (error) {
    throw new Error(`Failed to load the balance sheet: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    section: row.section,
    code: row.account_code,
    name: row.account_name,
    amount: fromDb(row.amount),
  }));
}
