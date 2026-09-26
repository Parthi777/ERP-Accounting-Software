import 'server-only';

import { after } from 'next/server';

import { requirePermission, requireTenantContext } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { recordAudit } from '@/server/services/audit/record-audit';
import { hrClient, isHrConfigured } from '@/server/services/hr/hr-client';
import { reportPayments, syncFromHr } from '@/server/services/hr/hr-sync-service';
import type { ChartResult } from '@/server/services/accounting/chart-service';

/**
 * Claims approved in the HR app, paid here (0095). The cashier ticks claims and
 * pays them from the cash book in one voucher; the payment is reported back to
 * the HR app straight after the response, and by every later sync until the
 * HR app acknowledges it.
 */

export type ClaimTab = 'topay' | 'paid' | 'mapping' | 'review' | 'cancelled';

export interface EmployeeClaimRow {
  readonly id: string;
  readonly claimNo: number | null;
  readonly hrVoucherNo: number | null;
  readonly employeeName: string;
  readonly employeeCode: string | null;
  readonly branchName: string | null;
  readonly typeLabel: string;
  readonly title: string;
  readonly amount: number;
  readonly approvedAt: string | null;
  readonly approvedBy: string | null;
  readonly status: string;
  readonly hasPhoto: boolean;
  readonly hasDocument: boolean;
  readonly paidAt: string | null;
  readonly paymentRef: string | null;
  readonly cashTransactionId: number | null;
  readonly callbackStatus: string;
  readonly callbackError: string | null;
  readonly reviewNote: string | null;
}

type ClaimStatus = 'APPROVED' | 'PAID' | 'AWAITING_MAPPING' | 'NEEDS_REVIEW' | 'CANCELLED';

const STATUS_FOR: Record<ClaimTab, ClaimStatus[]> = {
  topay: ['APPROVED'],
  paid: ['PAID'],
  mapping: ['AWAITING_MAPPING'],
  review: ['NEEDS_REVIEW'],
  cancelled: ['CANCELLED'],
};

export async function listEmployeeClaims(tab: ClaimTab): Promise<EmployeeClaimRow[]> {
  await requirePermission('hr.claims.view');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from('employee_claims')
    .select('id, claim_no, hr_voucher_no, employee_name, employee_code, type_label, title, amount, approved_at, approved_by, status, has_photo, has_document, paid_at, payment_ref, cash_transaction_id, callback_status, callback_error, review_note, branches ( name )')
    .in('status', STATUS_FOR[tab])
    .order(tab === 'paid' ? 'paid_at' : 'approved_at', { ascending: tab !== 'paid' })
    .limit(500);
  if (error) throw new Error(`Failed to load claims: ${error.message}`);
  return (data ?? []).map((c) => ({
    id: c.id,
    claimNo: c.claim_no,
    hrVoucherNo: c.hr_voucher_no,
    employeeName: c.employee_name,
    employeeCode: c.employee_code,
    branchName: c.branches?.name ?? null,
    typeLabel: c.type_label,
    title: c.title,
    amount: Number(c.amount),
    approvedAt: c.approved_at,
    approvedBy: c.approved_by,
    status: c.status,
    hasPhoto: c.has_photo,
    hasDocument: c.has_document,
    paidAt: c.paid_at,
    paymentRef: c.payment_ref,
    cashTransactionId: c.cash_transaction_id,
    callbackStatus: c.callback_status,
    callbackError: c.callback_error,
    reviewNote: c.review_note,
  }));
}

export async function claimCounts(): Promise<Record<ClaimTab, number>> {
  await requirePermission('hr.claims.view');
  const supabase = await createSupabaseServerClient();
  const { data } = await supabase.from('employee_claims').select('status');
  const counts: Record<ClaimTab, number> = { topay: 0, paid: 0, mapping: 0, review: 0, cancelled: 0 };
  for (const row of data ?? []) {
    for (const [tab, statuses] of Object.entries(STATUS_FOR) as [ClaimTab, ClaimStatus[]][]) {
      if (statuses.includes(row.status as ClaimStatus)) counts[tab] += 1;
    }
  }
  return counts;
}

export async function payClaims(input: {
  readonly claimIds: readonly string[];
  readonly book: 'CASH' | 'BANK';
  readonly bankAccountId: string | null;
  readonly date: string;
  readonly reference: string | null;
  readonly idempotencyKey: string;
}): Promise<ChartResult & { transactionId?: string }> {
  const context = await requirePermission('hr.claims.pay');
  if (input.claimIds.length === 0) return { ok: false, error: 'Tick the claims to pay.' };
  if (input.book === 'CASH' && !context.activeBranch) return { ok: false, error: 'Select the branch whose cash pays these claims.' };
  if (input.book === 'BANK' && !input.bankAccountId) return { ok: false, error: 'Choose the bank account.' };

  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('pay_employee_claims', {
    p_claim_ids: [...input.claimIds] as unknown as string,
    p_book: input.book,
    p_branch_id: input.book === 'CASH' ? context.activeBranch!.id : undefined,
    p_bank_account_id: input.book === 'BANK' ? input.bankAccountId ?? undefined : undefined,
    p_date: input.date,
    p_reference: input.reference?.trim() || undefined,
    p_idempotency_key: input.idempotencyKey,
  });
  if (error) return { ok: false, error: error.message };
  const row = Array.isArray(data) ? data[0] : data;

  await recordAudit({
    action: 'POST', entityType: 'employee_claims', entityId: String(row?.journal_entry_id ?? ''),
    dealerId: context.dealerId, branchId: context.activeBranch?.id ?? null, userId: context.userId, userEmail: context.email,
    newData: { claims: input.claimIds.length, book: input.book },
  });
  // Tell the HR app once the cashier has their answer; a failure is retried by the next sync.
  after(async () => {
    try {
      await reportPayments();
    } catch (err) {
      console.error('[hr] reporting payments failed', err);
    }
  });

  return {
    ok: true,
    transactionId: row?.transaction_id != null ? String(row.transaction_id) : undefined,
    message: `${input.claimIds.length} claim(s) paid. The HR app is being told.`,
  };
}

export async function syncNow(): Promise<ChartResult> {
  const context = await requireTenantContext();
  if (!context.permissions.has('hr.claims.pay') && !context.permissions.has('hr.mapping.manage')) {
    return { ok: false, error: 'You may not sync with the HR app.' };
  }
  const outcome = await syncFromHr();
  return outcome.ok ? { ok: true, message: outcome.message } : { ok: false, error: outcome.message };
}

export async function resolveReview(id: string, note: string): Promise<ChartResult> {
  await requirePermission('hr.mapping.manage');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('resolve_employee_claim_review', { p_claim_id: id, p_note: note });
  if (error) return { ok: false, error: error.message };
  return { ok: true, message: 'Marked as dealt with.' };
}

// ─────────────────────────────────────────────────────────────────────────────
// The connection screen
// ─────────────────────────────────────────────────────────────────────────────

export interface HrLinkStatus {
  readonly configured: boolean;
  readonly workspaceName: string | null;
  readonly lastClaimsSyncAt: string | null;
  readonly lastError: string | null;
  readonly branches: readonly { hrBranchId: string; hrBranchName: string; branchId: string | null }[];
  readonly heads: readonly { claimType: string; label: string; accountId: string | null }[];
}

export async function getHrLinkStatus(): Promise<HrLinkStatus> {
  await requirePermission('hr.mapping.manage');
  const supabase = await createSupabaseServerClient();
  const [link, branches, heads] = await Promise.all([
    supabase.from('hr_links').select('workspace_name, last_claims_sync_at, last_error').maybeSingle(),
    supabase.from('hr_branch_map').select('hr_branch_id, hr_branch_name, branch_id').order('hr_branch_name'),
    supabase.from('hr_claim_heads').select('claim_type, label, account_id').order('label'),
  ]);
  return {
    configured: isHrConfigured(),
    workspaceName: link.data?.workspace_name ?? null,
    lastClaimsSyncAt: link.data?.last_claims_sync_at ?? null,
    lastError: link.data?.last_error ?? null,
    branches: (branches.data ?? []).map((b) => ({ hrBranchId: b.hr_branch_id, hrBranchName: b.hr_branch_name, branchId: b.branch_id })),
    heads: (heads.data ?? []).map((h) => ({ claimType: h.claim_type, label: h.label, accountId: h.account_id })),
  };
}

export async function mapHead(claimType: string, accountId: string | null): Promise<ChartResult> {
  await requirePermission('hr.mapping.manage');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('map_hr_claim_head', { p_claim_type: claimType, p_account_id: accountId as string });
  if (error) return { ok: false, error: error.message };
  return { ok: true, message: data ? `Saved; ${data} waiting claim(s) booked.` : 'Saved.' };
}

export async function mapBranch(hrBranchId: string, branchId: string | null): Promise<ChartResult> {
  await requirePermission('hr.mapping.manage');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('map_hr_branch', { p_hr_branch_id: hrBranchId, p_branch_id: branchId as string });
  if (error) return { ok: false, error: error.message };
  return { ok: true, message: data ? `Saved; ${data} waiting claim(s) booked.` : 'Saved. Sync to bring in claims from this branch.' };
}

/** Bring a month's finalised HR payslips in as draft payroll runs. */
export async function importPayroll(month: string): Promise<ChartResult> {
  const context = await requirePermission('hr.payroll.run');
  const match = /^(\d{4})-(\d{2})$/.exec(month);
  if (!match) return { ok: false, error: 'Choose the month.' };
  const [year, mon] = [Number(match[1]), Number(match[2])];
  const payroll = await hrClient.payroll(year, mon);
  if (!payroll.ok) return { ok: false, error: payroll.message };
  if (!payroll.data.finalized) {
    return { ok: false, error: 'That month is not finalised in the HR app yet. Finalise the payroll there first.' };
  }
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('import_hr_payroll', {
    p_period: `${month}-01`,
    p_lines: payroll.data.lines as never,
  });
  if (error) return { ok: false, error: error.message };
  await recordAudit({
    action: 'IMPORT', entityType: 'payroll_runs', dealerId: context.dealerId, userId: context.userId,
    userEmail: context.email, newData: { source: 'HR', month, runs: data, lines: payroll.data.lines.length },
  });
  return { ok: true, message: `${payroll.data.lines.length} payslip(s) brought in as ${data} draft run(s). Review and post them under HR → Payroll.` };
}

/** Bank accounts this user may pay from (RLS decides; a cashier may see none). */
export async function getClaimPayBanks(): Promise<{ value: string; label: string }[]> {
  await requirePermission('hr.claims.pay');
  const supabase = await createSupabaseServerClient();
  const { data } = await supabase.from('bank_accounts').select('id, name, bank_name').eq('status', 'ACTIVE').order('name');
  return (data ?? []).map((b) => ({ value: b.id, label: `${b.name} · ${b.bank_name}` }));
}
