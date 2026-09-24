import 'server-only';

import { requirePermission } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { recordAudit } from '@/server/services/audit/record-audit';

/**
 * Maintaining the chart of accounts, and locking the books — spec §23, §24, §46.
 *
 * Both are thin: the rules live in the database (0076), where every caller meets
 * them. create_account() derives the normal side from the type and refuses a
 * parent that is not a heading of the same type; the chart_of_accounts guard
 * refuses anything that would strand posted lines — changing a used account's
 * type, deactivating one that still carries a balance, deleting one at all.
 * A second copy of those rules here would be a second place for them to drift.
 */

export type AccountType = 'ASSET' | 'LIABILITY' | 'EQUITY' | 'INCOME' | 'EXPENSE';

export interface ChartResult {
  readonly ok: boolean;
  readonly id?: string;
  readonly message?: string;
  readonly error?: string;
}

export async function createAccount(input: {
  readonly code: string;
  readonly name: string;
  readonly type: AccountType;
  readonly parentId: string | null;
  readonly isGroup: boolean;
}): Promise<ChartResult> {
  const context = await requirePermission('accounting.coa.manage');
  const supabase = await createSupabaseServerClient();

  const code = input.code.trim().toUpperCase();
  if (!/^[0-9A-Z][0-9A-Z._-]{0,29}$/.test(code)) {
    return { ok: false, error: 'An account code is letters and digits, up to 30 characters — 1952, EXP-TRAVEL.' };
  }
  if (input.name.trim().length < 2) {
    return { ok: false, error: 'Give the account a name.' };
  }

  const { data, error } = await supabase.rpc('create_account', {
    p_code: code,
    p_name: input.name.trim(),
    p_type: input.type,
    p_parent_id: input.parentId ?? undefined,
    p_is_group: input.isGroup,
  });

  if (error) {
    console.error('[chart] create failed', error.message);
    return { ok: false, error: error.message };
  }

  await recordAudit({
    action: 'CREATE',
    entityType: 'chart_of_accounts',
    entityId: String(data),
    dealerId: context.dealerId,
    userId: context.userId,
    userEmail: context.email,
    newData: { code, name: input.name.trim(), type: input.type, isGroup: input.isGroup },
  });

  return { ok: true, id: String(data), message: `Account ${code} added.` };
}

export async function setAccountStatus(accountId: string, status: 'ACTIVE' | 'INACTIVE'): Promise<ChartResult> {
  const context = await requirePermission('accounting.coa.manage');
  const supabase = await createSupabaseServerClient();

  const { error } = await supabase.rpc('set_account_status', {
    p_account_id: accountId,
    p_status: status,
  });

  if (error) {
    // "still carries a balance of …" and "is the ledger behind an active cash
    // or bank account" are written for the person reading them.
    return { ok: false, error: error.message };
  }

  await recordAudit({
    action: 'UPDATE',
    entityType: 'chart_of_accounts',
    entityId: accountId,
    dealerId: context.dealerId,
    userId: context.userId,
    userEmail: context.email,
    newData: { status },
    changedFields: ['status'],
  });

  return { ok: true, message: status === 'ACTIVE' ? 'Account reactivated.' : 'Account deactivated.' };
}

// ─────────────────────────────────────────────────────────────────────────────
// The lock date
// ─────────────────────────────────────────────────────────────────────────────

export interface BooksLock {
  /** Nothing dated on or before this posts. Null when the books are open. */
  readonly lockedThrough: string | null;
  readonly history: readonly {
    readonly lockedThrough: string | null;
    readonly reason: string;
    readonly createdAt: string;
  }[];
}

export async function getBooksLock(): Promise<BooksLock> {
  await requirePermission('accounting.journals.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase
    .from('accounting_locks')
    .select('locked_through, reason, created_at, seq')
    .order('seq', { ascending: false })
    .limit(10);

  if (error) {
    throw new Error(`Failed to load the lock date: ${error.message}`);
  }

  const history = (data ?? []).map((row) => ({
    lockedThrough: row.locked_through,
    reason: row.reason,
    createdAt: row.created_at,
  }));

  return { lockedThrough: history[0]?.lockedThrough ?? null, history };
}

export async function setBooksLock(input: {
  readonly lockedThrough: string | null;
  readonly reason: string;
}): Promise<ChartResult> {
  const context = await requirePermission('accounting.periods.manage');
  const supabase = await createSupabaseServerClient();

  if (input.reason.trim().length < 3) {
    return { ok: false, error: 'Say why the lock date is changing. The reason is kept with it.' };
  }

  const { data, error } = await supabase.rpc('set_books_lock', {
    // NULL is meaningful here — it reopens the books — and the generated types
    // have no way to say an argument without a default may be null.
    p_locked_through: input.lockedThrough as string,
    p_reason: input.reason.trim(),
  });

  if (error) {
    return { ok: false, error: error.message };
  }

  const row = Array.isArray(data) ? data[0] : data;

  await recordAudit({
    action: 'UPDATE',
    entityType: 'accounting_locks',
    dealerId: context.dealerId,
    userId: context.userId,
    userEmail: context.email,
    oldData: { lockedThrough: row?.previous ?? null },
    newData: { lockedThrough: input.lockedThrough },
    reason: input.reason.trim(),
  });

  return {
    ok: true,
    message: input.lockedThrough ? `Books locked through ${input.lockedThrough}.` : 'Books reopened.',
  };
}
