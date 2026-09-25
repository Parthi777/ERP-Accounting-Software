import 'server-only';

import { requirePermission, requireTenantContext } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { recordAudit } from '@/server/services/audit/record-audit';
import { NotFoundError } from '@/server/errors';
import type { AccountType, ChartResult } from '@/server/services/accounting/chart-service';

/**
 * The ledger master, ledger groups and financial years — the BUSY way of
 * keeping accounts (0090).
 *
 * Every ledger sits under a group and can be opened and modified; a customer,
 * supplier or finance company is a ledger too, under Sundry Debtors or Sundry
 * Creditors. The rules are the database's: update_account() keeps a system
 * ledger's code and refuses a group beneath itself, the 0076 guard keeps types
 * straight, set_ledger_opening_balance() posts only the difference against
 * 3300, and the financial-year functions keep years contiguous and closed in
 * order. This layer shapes input and output and says nothing twice.
 */

export type LedgerKind = 'ACCOUNT' | 'CUSTOMER' | 'SUPPLIER' | 'FINANCE_COMPANY';

export const LEDGER_KINDS: readonly LedgerKind[] = ['ACCOUNT', 'CUSTOMER', 'SUPPLIER', 'FINANCE_COMPANY'];

export interface LedgerRow {
  readonly kind: LedgerKind;
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly alias: string | null;
  readonly groupId: string | null;
  readonly groupName: string | null;
  readonly type: AccountType;
  /** Debit positive. */
  readonly opening: number;
  /** Debit positive. */
  readonly closing: number;
  readonly status: string;
  readonly contact: string | null;
  readonly isSystem: boolean;
}

export interface LedgerGroup {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly alias: string | null;
  readonly type: AccountType;
  readonly parentId: string | null;
  readonly isSystem: boolean;
  readonly status: string;
  /** 0 for a type heading, 1 for a group under it, and so on. */
  readonly depth: number;
  /** "Assets › Current Assets › Input GST" — for pickers. */
  readonly path: string;
}

export interface ChartNode {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly alias: string | null;
  readonly type: AccountType;
  readonly parentId: string | null;
  readonly isGroup: boolean;
  readonly isSystem: boolean;
  readonly status: string;
}

function toRow(r: {
  kind: string; id: string; code: string; name: string; alias: string | null; group_id: string | null;
  group_name: string | null; account_type: string; opening: string | number | null; closing: string | number | null;
  status: string; contact: string | null; is_system: boolean;
}): LedgerRow {
  return {
    kind: r.kind as LedgerKind,
    id: r.id,
    code: r.code,
    name: r.name,
    alias: r.alias,
    groupId: r.group_id,
    groupName: r.group_name,
    type: r.account_type as AccountType,
    opening: Number(r.opening ?? 0),
    closing: Number(r.closing ?? 0),
    status: r.status,
    contact: r.contact,
    isSystem: r.is_system,
  };
}

async function requireLedgerView() {
  const context = await requireTenantContext();
  if (!context.permissions.has('accounting.ledgers.view') && !context.permissions.has('accounting.coa.view')) {
    await requirePermission('accounting.coa.view'); // throws the standard permission error
  }
  return context;
}

// ─────────────────────────────────────────────────────────────────────────────
// Reading
// ─────────────────────────────────────────────────────────────────────────────

export async function listLedgers(params: {
  readonly search?: string;
  readonly groupId?: string;
  readonly limit?: number;
  readonly offset?: number;
}): Promise<LedgerRow[]> {
  await requireLedgerView();
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('ledger_master', {
    p_search: params.search?.trim() || undefined,
    p_group_id: params.groupId || undefined,
    p_limit: params.limit ?? 500,
    p_offset: params.offset ?? 0,
  });
  if (error) throw new Error(`Failed to load the ledgers: ${error.message}`);
  return (data ?? []).map(toRow);
}

export async function getLedger(kind: LedgerKind, id: string): Promise<LedgerRow> {
  await requireLedgerView();
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('ledger_master', { p_kind: kind, p_id: id, p_limit: 1 });
  if (error) throw new Error(`Failed to load the ledger: ${error.message}`);
  const row = data?.[0];
  if (!row) throw new NotFoundError('Ledger');
  return toRow(row);
}

/** The opening balance already entered for a ledger, debit positive. */
export async function getOpeningEntered(kind: LedgerKind, id: string): Promise<number> {
  await requireLedgerView();
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('ledger_opening_entered', { p_kind: kind, p_id: id });
  if (error) throw new Error(`Failed to read the opening balance: ${error.message}`);
  return Number(data ?? 0);
}

/** The whole chart — groups and ledgers — for trees and pickers. */
export async function getChart(): Promise<ChartNode[]> {
  await requireLedgerView();
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from('chart_of_accounts')
    .select('id, code, name, alias, account_type, parent_id, is_group, is_system, status')
    .order('code');
  if (error) throw new Error(`Failed to load the chart of accounts: ${error.message}`);
  return (data ?? []).map((a) => ({
    id: a.id,
    code: a.code,
    name: a.name,
    alias: a.alias,
    type: a.account_type as AccountType,
    parentId: a.parent_id,
    isGroup: a.is_group,
    isSystem: a.is_system,
    status: a.status,
  }));
}

/**
 * Which groups hold parties, cash and bank. A ledger "added" under Sundry
 * Debtors is a customer, under Sundry Creditors a supplier; under Cash-in-Hand
 * or Bank Accounts it is a cash or bank account, whose master writes the book
 * too. Read from the posting rules and the cash/bank masters, not from codes.
 */
export type GroupRole = 'DEBTORS' | 'CREDITORS' | 'FINANCIERS' | 'CASH' | 'BANK';

export async function getGroupRoles(chart: readonly ChartNode[]): Promise<Record<string, GroupRole>> {
  await requireLedgerView();
  const supabase = await createSupabaseServerClient();
  const [rules, cash, bank] = await Promise.all([
    supabase
      .from('accounting_rules')
      .select('component, account_id')
      .eq('status', 'ACTIVE')
      .is('branch_id', null)
      .in('component', ['RECEIVABLE', 'PAYABLE', 'FINANCE_RECEIVABLE']),
    supabase.from('cash_accounts').select('ledger_account_id'),
    supabase.from('bank_accounts').select('ledger_account_id'),
  ]);
  const parentOf = (accountId: string | null | undefined) =>
    chart.find((a) => a.id === accountId)?.parentId ?? null;

  const roles: Record<string, GroupRole> = {};
  const mark = (accountId: string | null | undefined, role: GroupRole) => {
    const group = parentOf(accountId);
    if (group && !roles[group]) roles[group] = role;
  };
  // Sundry Debtors holds the financiers' ledger too; customers name the group.
  const ordered = [...(rules.data ?? [])].sort((a, b) =>
    Number(a.component === 'FINANCE_RECEIVABLE') - Number(b.component === 'FINANCE_RECEIVABLE'));
  for (const r of ordered) {
    mark(r.account_id, r.component === 'RECEIVABLE' ? 'DEBTORS' : r.component === 'PAYABLE' ? 'CREDITORS' : 'FINANCIERS');
  }
  for (const c of cash.data ?? []) mark(c.ledger_account_id, 'CASH');
  for (const b of bank.data ?? []) mark(b.ledger_account_id, 'BANK');
  return roles;
}

/** The groups in tree order (each followed by the groups beneath it). */
export function groupsInTreeOrder(chart: readonly ChartNode[]): LedgerGroup[] {
  const groups = chart.filter((a) => a.isGroup);
  const children = new Map<string | null, ChartNode[]>();
  for (const g of groups) {
    const key = g.parentId && groups.some((p) => p.id === g.parentId) ? g.parentId : null;
    children.set(key, [...(children.get(key) ?? []), g]);
  }
  const out: LedgerGroup[] = [];
  const walk = (parent: string | null, depth: number, trail: string[]) => {
    for (const g of (children.get(parent) ?? []).sort((a, b) => a.code.localeCompare(b.code))) {
      const path = [...trail, g.name];
      out.push({
        id: g.id, code: g.code, name: g.name, alias: g.alias, type: g.type, parentId: g.parentId,
        isSystem: g.isSystem, status: g.status, depth, path: path.join(' › '),
      });
      walk(g.id, depth + 1, path);
    }
  };
  walk(null, 0, []);
  return out;
}

/** The next free code beneath a group: one past its highest numeric child. */
export function suggestCode(chart: readonly ChartNode[], groupId: string): string {
  const group = chart.find((a) => a.id === groupId);
  if (!group) return '';
  const used = new Set(chart.map((a) => a.code));
  const numeric = chart
    .filter((a) => a.parentId === groupId && /^\d+$/.test(a.code))
    .map((a) => Number(a.code));
  let next = numeric.length ? Math.max(...numeric) + 1 : /^\d+$/.test(group.code) ? Number(group.code) * 10 + 1 : 0;
  if (!next) return '';
  while (used.has(String(next))) next += 1;
  return String(next);
}

// ─────────────────────────────────────────────────────────────────────────────
// Writing
// ─────────────────────────────────────────────────────────────────────────────

function parseAmount(value: string | number | undefined): number | null {
  if (value === undefined || value === '') return 0;
  const n = typeof value === 'number' ? value : Number(String(value).replace(/,/g, ''));
  return Number.isFinite(n) && n >= 0 ? Math.round(n * 100) / 100 : null;
}

/** Add a ledger (not a party) or a group, with its alias and opening balance. */
export async function createLedger(input: {
  readonly name: string;
  readonly alias?: string;
  readonly code: string;
  readonly groupId: string;
  readonly isGroup: boolean;
  readonly openingAmount?: string;
  readonly openingSide?: 'DR' | 'CR';
}): Promise<ChartResult> {
  const context = await requirePermission('accounting.coa.manage');
  const supabase = await createSupabaseServerClient();

  const code = input.code.trim().toUpperCase();
  if (!/^[0-9A-Z][0-9A-Z._-]{0,29}$/.test(code)) {
    return { ok: false, error: 'A code is letters and digits, up to 30 characters — 5601, EXP-TRAVEL.' };
  }
  if (input.name.trim().length < 2) return { ok: false, error: 'Give the ledger a name.' };
  if (!input.groupId) return { ok: false, error: 'Choose the group it belongs under.' };
  const amount = parseAmount(input.openingAmount);
  if (amount === null) return { ok: false, error: 'The opening balance is an amount; choose Dr or Cr beside it.' };

  const { data: group, error: groupError } = await supabase
    .from('chart_of_accounts')
    .select('account_type, is_group')
    .eq('id', input.groupId)
    .maybeSingle();
  if (groupError || !group?.is_group) return { ok: false, error: 'Choose a group from the list.' };

  const { data, error } = await supabase.rpc('create_account', {
    p_code: code,
    p_name: input.name.trim(),
    p_type: group.account_type,
    p_parent_id: input.groupId,
    p_is_group: input.isGroup,
  });
  if (error) return { ok: false, error: error.message };
  const id = String(data);

  if (input.alias?.trim()) {
    const { error: aliasError } = await supabase.rpc('update_account', {
      p_account_id: id, p_name: input.name.trim(), p_code: code, p_parent_id: input.groupId, p_alias: input.alias.trim(),
    });
    if (aliasError) return { ok: false, id, error: `Added, but the alias was not saved: ${aliasError.message}` };
  }

  await recordAudit({
    action: 'CREATE',
    entityType: 'chart_of_accounts',
    entityId: id,
    dealerId: context.dealerId,
    userId: context.userId,
    userEmail: context.email,
    newData: { code, name: input.name.trim(), alias: input.alias?.trim() || null, isGroup: input.isGroup },
  });

  if (!input.isGroup && amount > 0) {
    const opening = await setOpeningBalance({ kind: 'ACCOUNT', id, amount: String(amount), side: input.openingSide ?? 'DR' });
    if (!opening.ok) return { ok: false, id, error: `Added, but the opening balance was not posted: ${opening.error}` };
  }

  return { ok: true, id, message: `${input.isGroup ? 'Group' : 'Ledger'} ${input.name.trim()} added.` };
}

/** Modify a ledger or a group: name, alias, code and group. */
export async function modifyAccount(input: {
  readonly id: string;
  readonly name: string;
  readonly alias?: string;
  readonly code: string;
  readonly groupId: string | null;
}): Promise<ChartResult> {
  const context = await requirePermission('accounting.coa.manage');
  const supabase = await createSupabaseServerClient();

  const { data: before } = await supabase
    .from('chart_of_accounts')
    .select('code, name, alias, parent_id')
    .eq('id', input.id)
    .maybeSingle();

  const { error } = await supabase.rpc('update_account', {
    p_account_id: input.id,
    p_name: input.name.trim(),
    p_code: input.code.trim().toUpperCase(),
    // A type heading has no parent; null is meaningful and the generated
    // types cannot say an argument without a default may be null.
    p_parent_id: input.groupId as string,
    p_alias: input.alias?.trim() ?? '',
  });
  if (error) return { ok: false, error: error.message };

  await recordAudit({
    action: 'UPDATE',
    entityType: 'chart_of_accounts',
    entityId: input.id,
    dealerId: context.dealerId,
    userId: context.userId,
    userEmail: context.email,
    oldData: before ?? undefined,
    newData: { code: input.code.trim().toUpperCase(), name: input.name.trim(), alias: input.alias?.trim() || null, parent_id: input.groupId },
  });

  return { ok: true, id: input.id, message: `${input.name.trim()} saved.` };
}

/** Set a ledger's opening balance; the database posts only the difference. */
export async function setOpeningBalance(input: {
  readonly kind: LedgerKind;
  readonly id: string;
  readonly amount: string;
  readonly side: 'DR' | 'CR';
}): Promise<ChartResult> {
  const context = await requirePermission('accounting.journals.post');
  if (!LEDGER_KINDS.includes(input.kind)) return { ok: false, error: 'Unknown kind of ledger.' };
  const amount = parseAmount(input.amount);
  if (amount === null) return { ok: false, error: 'The opening balance is an amount; choose Dr or Cr beside it.' };
  if (input.side !== 'DR' && input.side !== 'CR') return { ok: false, error: 'An opening balance is Dr or Cr.' };

  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('set_ledger_opening_balance', {
    p_kind: input.kind,
    p_id: input.id,
    p_amount: amount,
    p_side: input.side,
  });
  if (error) return { ok: false, error: error.message };

  if (data) {
    await recordAudit({
      action: 'POST',
      entityType: 'journal_entries',
      entityId: String(data),
      dealerId: context.dealerId,
      userId: context.userId,
      userEmail: context.email,
      newData: { openingBalanceOf: { kind: input.kind, id: input.id }, amount, side: input.side },
    });
  }

  return {
    ok: true,
    id: data ? String(data) : undefined,
    message: data ? 'Opening balance saved; the change is posted against Opening Balance Equity.' : 'The opening balance was already that.',
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Financial years
// ─────────────────────────────────────────────────────────────────────────────

export interface FinancialYear {
  readonly id: string;
  readonly name: string;
  readonly startDate: string;
  readonly endDate: string;
  readonly status: string;
  readonly closedAt: string | null;
  readonly reason: string | null;
}

export async function listFinancialYears(): Promise<FinancialYear[]> {
  await requirePermission('accounting.journals.view');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from('accounting_periods')
    .select('id, name, start_date, end_date, status, closed_at, status_reason')
    .order('start_date', { ascending: false });
  if (error) throw new Error(`Failed to load the financial years: ${error.message}`);
  return (data ?? []).map((p) => ({
    id: p.id,
    name: p.name,
    startDate: p.start_date,
    endDate: p.end_date,
    status: p.status,
    closedAt: p.closed_at,
    reason: p.status_reason,
  }));
}

export async function createFinancialYear(): Promise<ChartResult> {
  await requirePermission('accounting.periods.manage');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('create_financial_year');
  if (error) return { ok: false, error: error.message };
  const { data: row } = await supabase.from('accounting_periods').select('name').eq('id', String(data)).maybeSingle();
  return { ok: true, id: String(data), message: `${row?.name ?? 'The new financial year'} created.` };
}

export async function closeFinancialYear(id: string): Promise<ChartResult> {
  await requirePermission('accounting.periods.manage');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('close_financial_year', { p_period_id: id });
  if (error) return { ok: false, error: error.message };
  return { ok: true, message: 'Financial year closed. Nothing more can post into it.' };
}

export async function reopenFinancialYear(id: string, reason: string): Promise<ChartResult> {
  await requirePermission('accounting.periods.manage');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('reopen_financial_year', { p_period_id: id, p_reason: reason.trim() });
  if (error) return { ok: false, error: error.message };
  return { ok: true, message: 'Financial year reopened.' };
}

// ─────────────────────────────────────────────────────────────────────────────
// Pickers
// ─────────────────────────────────────────────────────────────────────────────

export interface GroupPickerOption {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly type: string;
  readonly depth: number;
  readonly path: string;
  readonly role?: GroupRole;
  readonly suggestedCode: string;
}

/** Every active group, in tree order, with its role and the next free code. */
export async function getGroupOptions(chart?: readonly ChartNode[]): Promise<GroupPickerOption[]> {
  const nodes = chart ?? (await getChart());
  const roles = await getGroupRoles(nodes);
  return groupsInTreeOrder(nodes)
    .filter((g) => g.status === 'ACTIVE')
    .map((g) => ({
      id: g.id,
      code: g.code,
      name: g.name,
      type: g.type,
      depth: g.depth,
      path: g.path,
      role: roles[g.id],
      suggestedCode: suggestCode(nodes, g.id),
    }));
}

// ─────────────────────────────────────────────────────────────────────────────
// A party's opening bills (0091)
// ─────────────────────────────────────────────────────────────────────────────

export interface OpeningBill {
  readonly lineId: string;
  readonly reference: string;
  readonly billDate: string;
  readonly amount: number;
  readonly outstanding: number;
}

/** The party's opening balance lines, bill by bill, with what is still open. */
export async function getOpeningBills(kind: 'CUSTOMER' | 'SUPPLIER', id: string): Promise<OpeningBill[]> {
  await requireLedgerView();
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('party_open_items', {
    p_party_type: kind,
    p_party_id: id,
    p_include_settled: true,
  });
  if (error) throw new Error(`Failed to load the opening bills: ${error.message}`);
  return (data ?? [])
    .filter((r) => r.document_type === 'OPENING_BALANCE')
    .map((r) => ({
      lineId: r.line_id,
      reference: r.document_ref,
      billDate: r.entry_date,
      amount: Number(r.amount ?? 0),
      outstanding: Number(r.outstanding ?? 0),
    }));
}
