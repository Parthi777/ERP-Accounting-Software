import 'server-only';

import { requirePermission, requireTenantContext } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { recordAudit } from '@/server/services/audit/record-audit';
import { fromDb, type Paise } from '@/lib/money';

/**
 * The maker-checker queue — spec §6, §23, §35 (0081).
 *
 * The rules are in the database: a request is validated in full when it is
 * made, only a different person holding the approve permission may decide it,
 * and a rejection must say why. This layer reads the queue and passes the
 * decision through.
 */

export type ApprovalKind = 'MANUAL_JOURNAL' | 'STOCK_ADJUSTMENT';
export type ApprovalStatus = 'PENDING' | 'APPROVED' | 'REJECTED' | 'WITHDRAWN';

export interface ApprovalRow {
  readonly id: string;
  readonly kind: ApprovalKind;
  readonly status: ApprovalStatus;
  readonly summary: string;
  readonly amount: Paise | null;
  readonly entryDate: string | null;
  readonly requestedBy: string;
  readonly requestedByName: string;
  readonly requestedAt: string;
  readonly decidedByName: string | null;
  readonly decidedAt: string | null;
  readonly decisionNote: string | null;
  readonly resultId: string | null;
  readonly lines: readonly { account: string; debit: number; credit: number }[];
  readonly mine: boolean;
}

export interface ApprovalResult {
  readonly ok: boolean;
  readonly error?: string;
  readonly message?: string;
}

export async function getApprovals(status: ApprovalStatus | 'ALL'): Promise<ApprovalRow[]> {
  const context = await requireTenantContext();
  const supabase = await createSupabaseServerClient();

  let query = supabase
    .from('approval_requests')
    .select('id, kind, status, summary, amount, payload, requested_by, requested_at, decided_by, decided_at, decision_note, result_id')
    .order('requested_at', { ascending: false })
    .limit(200);
  if (status !== 'ALL') {
    query = query.eq('status', status);
  }

  const { data, error } = await query;
  if (error) {
    throw new Error(`Failed to load approvals: ${error.message}`);
  }

  const rows = data ?? [];
  const userIds = [...new Set(rows.flatMap((r) => [r.requested_by, r.decided_by]).filter((v): v is string => !!v))];
  const accountIds = [
    ...new Set(
      rows.flatMap((r) =>
        r.kind === 'MANUAL_JOURNAL'
          ? ((r.payload as { lines?: { account_id: string }[] }).lines ?? []).map((l) => l.account_id)
          : [],
      ),
    ),
  ];

  const [{ data: people }, { data: accounts }] = await Promise.all([
    userIds.length
      ? supabase.from('user_profiles').select('id, full_name').in('id', userIds)
      : Promise.resolve({ data: [] as { id: string; full_name: string }[] }),
    accountIds.length
      ? supabase.from('chart_of_accounts').select('id, code, name').in('id', accountIds)
      : Promise.resolve({ data: [] as { id: string; code: string; name: string }[] }),
  ]);
  const nameOf = new Map((people ?? []).map((p) => [p.id, p.full_name]));
  const accountOf = new Map((accounts ?? []).map((a) => [a.id, `${a.code} ${a.name}`]));

  return rows.map((r) => {
    const payload = r.payload as {
      entry_date?: string;
      lines?: { account_id: string; debit?: number; credit?: number }[];
    };
    return {
      id: r.id,
      kind: r.kind as ApprovalKind,
      status: r.status as ApprovalStatus,
      summary: r.summary,
      amount: r.amount == null ? null : fromDb(r.amount),
      entryDate: payload.entry_date ?? null,
      requestedBy: r.requested_by,
      requestedByName: nameOf.get(r.requested_by) ?? 'Unknown',
      requestedAt: r.requested_at,
      decidedByName: r.decided_by ? (nameOf.get(r.decided_by) ?? 'Unknown') : null,
      decidedAt: r.decided_at,
      decisionNote: r.decision_note,
      resultId: r.result_id,
      lines: (payload.lines ?? []).map((l) => ({
        account: accountOf.get(l.account_id) ?? 'Account',
        debit: Number(l.debit ?? 0),
        credit: Number(l.credit ?? 0),
      })),
      mine: r.requested_by === context.userId,
    };
  });
}

export async function decideApproval(input: {
  readonly requestId: string;
  readonly approve: boolean;
  readonly note?: string | null;
}): Promise<ApprovalResult> {
  const context = await requireTenantContext();
  const supabase = await createSupabaseServerClient();

  const { error } = await supabase.rpc('decide_approval', {
    p_request_id: input.requestId,
    p_approve: input.approve,
    p_note: input.note?.trim() || undefined,
  });
  if (error) {
    return { ok: false, error: error.message };
  }

  await recordAudit({
    action: input.approve ? 'APPROVE' : 'REJECT',
    entityType: 'approval_requests',
    entityId: input.requestId,
    dealerId: context.dealerId,
    userId: context.userId,
    userEmail: context.email,
    reason: input.note ?? undefined,
  });

  return { ok: true, message: input.approve ? 'Approved and posted.' : 'Rejected. The requester can see why.' };
}

export async function withdrawApproval(requestId: string): Promise<ApprovalResult> {
  await requirePermission('accounting.journals.view');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('withdraw_approval', { p_request_id: requestId });
  if (error) {
    return { ok: false, error: error.message };
  }
  return { ok: true, message: 'Withdrawn.' };
}
