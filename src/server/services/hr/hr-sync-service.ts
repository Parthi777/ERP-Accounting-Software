import 'server-only';

import { serverEnv } from '@/config/env';
import { createSupabaseAdminClient } from '@/lib/supabase/server';
import { hrClient, isHrConfigured } from '@/server/services/hr/hr-client';

/**
 * Keeping this ERP in step with the HR Payroll app (0095).
 *
 * Runs without a signed-in user — for the webhook, for a scheduler, and after a
 * person presses "Sync now" (whose permission the caller has already checked) —
 * so it uses the server-only admin client and names the dealer explicitly. The
 * SQL functions it calls are executable by the service role alone.
 *
 * The webhook delivers approvals as they happen; this pull is the repair: it
 * reads what changed since the last sync, and it reports claims paid here back
 * to the HR app until the HR app acknowledges them.
 */

export interface SyncOutcome {
  readonly ok: boolean;
  readonly message: string;
  readonly claims?: number;
  readonly people?: number;
  readonly reported?: number;
}

/** The dealer the HR workspace belongs to (HR_DEALER_CODE). */
export async function hrDealerId(): Promise<string | null> {
  const code = serverEnv().HR_DEALER_CODE;
  if (!code) return null;
  const admin = createSupabaseAdminClient();
  const { data } = await admin.from('dealers').select('id').eq('code', code).maybeSingle();
  return data?.id ?? null;
}

export async function syncFromHr(): Promise<SyncOutcome> {
  if (!isHrConfigured()) return { ok: false, message: 'The HR app is not connected.' };
  const dealerId = await hrDealerId();
  if (!dealerId) return { ok: false, message: `No dealer has the code ${serverEnv().HR_DEALER_CODE}.` };
  const admin = createSupabaseAdminClient();

  const { data: link } = await admin
    .from('hr_links')
    .select('last_claims_sync_at, last_people_sync_at')
    .eq('dealer_id', dealerId)
    .maybeSingle();

  const [who, people, approved, changed] = await Promise.all([
    hrClient.whoami(),
    hrClient.employees(link?.last_people_sync_at ?? null),
    hrClient.claims('APPROVED'),
    // Approvals taken back since the last sync.
    link?.last_claims_sync_at
      ? hrClient.claims('REJECTED,NEEDS_CLARIFICATION,PENDING', link.last_claims_sync_at)
      : Promise.resolve({ ok: true as const, data: { claims: [] } }),
  ]);
  const failure = [who, people, approved, changed].find((r) => !r.ok);
  if (failure && !failure.ok) {
    await admin.rpc('hr_record_sync_error', { p_dealer_id: dealerId, p_error: failure.message });
    return { ok: false, message: failure.message };
  }
  if (!who.ok || !people.ok || !approved.ok || !changed.ok) return { ok: false, message: 'The HR app could not be read.' };

  const { data, error } = await admin.rpc('hr_sync_batch', {
    p_dealer_id: dealerId,
    p_claims: [...approved.data.claims, ...changed.data.claims] as never,
    p_employees: people.data.employees as never,
    p_workspace: who.data.workspace as never,
  });
  if (error) {
    await admin.rpc('hr_record_sync_error', { p_dealer_id: dealerId, p_error: error.message });
    return { ok: false, message: error.message };
  }

  const reported = await reportPayments(dealerId);
  const counts = (data ?? {}) as { claims?: number; people?: number };
  return {
    ok: true,
    message: `Synced: ${counts.claims ?? 0} claim(s), ${counts.people ?? 0} employee record(s)${reported ? `, ${reported} payment(s) reported to the HR app` : ''}.`,
    claims: counts.claims,
    people: counts.people,
    reported,
  };
}

/** Tell the HR app about claims paid here that it has not yet acknowledged. */
export async function reportPayments(dealerId?: string | null): Promise<number> {
  if (!isHrConfigured()) return 0;
  const dealer = dealerId ?? (await hrDealerId());
  if (!dealer) return 0;
  const admin = createSupabaseAdminClient();
  const { data: pending } = await admin
    .from('employee_claims')
    .select('id, hr_claim_id, payment_ref, paid_at, callback_attempts')
    .eq('dealer_id', dealer)
    .eq('status', 'PAID')
    .in('callback_status', ['PENDING', 'FAILED'])
    .lt('callback_attempts', 20)
    .limit(100);

  let reported = 0;
  for (const claim of pending ?? []) {
    const result = await hrClient.markPaid(claim.hr_claim_id, claim.payment_ref ?? 'ERP', claim.paid_at ?? new Date().toISOString());
    await admin.rpc('hr_mark_callback', {
      p_dealer_id: dealer,
      p_claim_id: claim.id,
      p_ok: result.ok,
      p_error: result.ok ? undefined : result.message,
    });
    if (result.ok) reported += 1;
  }
  return reported;
}
