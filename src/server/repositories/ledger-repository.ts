import 'server-only';

import { createSupabaseServerClient } from '@/lib/supabase/server';
import { fromDb, type Paise } from '@/lib/money';
import type { AccountBalance } from '@/types/database.types';

/**
 * Data access for the general ledger.
 *
 * Repositories issue queries and translate rows; they hold no business rules and
 * make no permission decisions. Services do both (spec §57.3).
 */

export interface LedgerBalance {
  readonly accountId: string;
  readonly code: string;
  readonly name: string;
  readonly type: AccountBalance['account_type'];
  readonly normalBalance: AccountBalance['normal_balance'];
  /** Movement within the requested period, in the account's normal direction. */
  readonly periodMovement: Paise;
  /** Cumulative balance to the end of the period. */
  readonly closingBalance: Paise;
}

export interface LedgerPeriod {
  readonly from: string;
  readonly to: string;
  readonly branchId: string | null;
}

/**
 * Account balances for a period. RLS scopes the result to the caller's dealer
 * and branches, so no tenant filter is passed from here (spec §47).
 */
export async function getAccountBalances(period: LedgerPeriod): Promise<LedgerBalance[]> {
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('account_balances', {
    p_from: period.from,
    p_to: period.to,
    p_branch_id: period.branchId,
  });

  if (error) {
    throw new Error(`Failed to load account balances: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    accountId: row.account_id,
    code: row.account_code,
    name: row.account_name,
    type: row.account_type,
    normalBalance: row.normal_balance,
    periodMovement: fromDb(row.period_movement),
    closingBalance: fromDb(row.closing_balance),
  }));
}

/** Daily posted revenue, for the sales-trend chart. */
export interface DailyRevenue {
  readonly date: string;
  readonly amount: Paise;
}

export async function getDailyRevenue(
  period: LedgerPeriod,
  revenueAccountCodes: readonly string[],
): Promise<DailyRevenue[]> {
  const supabase = await createSupabaseServerClient();

  // PostgREST cannot express "group by date" directly, so the lines are fetched
  // for the window and folded here. The window is a month of one dealer's revenue
  // lines, which is small; if this ever grows, it becomes a database function
  // alongside account_balances().
  const { data, error } = await supabase
    .from('journal_entry_lines')
    .select('credit, debit, chart_of_accounts!inner(code), journal_entries!inner(entry_date, status, branch_id)')
    .in('chart_of_accounts.code', [...revenueAccountCodes])
    .eq('journal_entries.status', 'POSTED')
    .gte('journal_entries.entry_date', period.from)
    .lte('journal_entries.entry_date', period.to);

  if (error) {
    throw new Error(`Failed to load daily revenue: ${error.message}`);
  }

  const byDate = new Map<string, number>();
  for (const row of data ?? []) {
    const entry = row.journal_entries;
    if (period.branchId && entry.branch_id !== period.branchId) {
      continue;
    }
    // Revenue accounts are credit-normal: credits increase them, debits reduce.
    const amount = fromDb(row.credit) - fromDb(row.debit);
    byDate.set(entry.entry_date, (byDate.get(entry.entry_date) ?? 0) + amount);
  }

  return [...byDate.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([date, amount]) => ({ date, amount: amount as Paise }));
}
