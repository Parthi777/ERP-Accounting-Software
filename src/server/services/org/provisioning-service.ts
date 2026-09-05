import 'server-only';

import { requireTenantContext } from '@/server/auth/tenant-context';
import { ForbiddenError } from '@/server/errors';
import {
  createSupabaseServerClient,
  createSupabaseAdminClient,
} from '@/lib/supabase/server';
import { recordAudit } from '@/server/services/audit/record-audit';
import { publicEnv } from '@/config/env';

/**
 * Onboarding a dealer — spec §4, §6, §48, §60.3.
 *
 * Until this existed, the only thing that had ever created a tenant was
 * supabase/seed.sql, hand-run and hardcoded to one dealer. Onboarding the second
 * meant editing SQL against production.
 *
 * ── The order of the three side effects ─────────────────────────────────────
 *
 * Provisioning touches three systems and only one of them can roll back, so the
 * order is deliberate rather than incidental:
 *
 *   1. Create the owner's Supabase Auth account, WITHOUT inviting them. If
 *      anything later fails, this is deleted again — safe, because it is seconds
 *      old and has no profile attached.
 *   2. Call public.provision_dealer(). One transaction: dealer, branch, chart of
 *      accounts, every rule seeder, sequences, cash account, period, owner
 *      profile and role. It refuses to commit a tenant that cannot trade.
 *   3. Send the invite — only now, after the transaction has committed. An email
 *      cannot be un-sent, so it must never be the thing that outlives a rollback.
 *
 * Get that order wrong and the failure is memorable: an owner holding a working
 * link to a dealership that does not exist.
 */

export interface ProvisionInput {
  readonly code: string;
  readonly legalName: string;
  readonly tradeName?: string | null;
  readonly state: string;
  readonly stateCode: string;
  readonly city?: string | null;
  readonly phone?: string | null;
  readonly gstin?: string | null;
  readonly pan?: string | null;
  readonly branchName?: string | null;
  readonly ownerName: string;
  readonly ownerEmail: string;
}

export interface ReadinessCheck {
  readonly name: string;
  readonly ok: boolean;
  readonly detail: string;
}

export interface ProvisionResult {
  readonly ok: boolean;
  readonly dealerId?: string;
  readonly error?: string;
  readonly message?: string;
  /** Set when the tenant committed but the invite could not be sent. */
  readonly inviteFailed?: boolean;
  readonly readiness?: readonly ReadinessCheck[];
}

async function requirePlatformAdmin() {
  const context = await requireTenantContext();
  if (!context.isPlatformAdmin) {
    throw new ForbiddenError('admin.dealers.manage');
  }
  return context;
}

/** The database messages are precise; these are the ones an operator can act on. */
function describeProvisionError(message: string): string {
  if (message.includes('already taken')) {
    return 'That dealer code is already in use. Choose another.';
  }
  if (message.includes('already belongs to another dealer')) {
    return 'That GSTIN is already registered to another dealer. Two tenants cannot share one.';
  }
  if (message.includes('That login already belongs')) {
    return 'That email already belongs to a user of another dealer.';
  }
  if (message.includes('two-digit state code')) {
    return 'Enter the two-digit GST state code — it decides CGST+SGST versus IGST on every invoice.';
  }
  if (message.includes('unable to trade')) {
    return `Provisioning was rolled back because the tenant would not have worked. ${message.split(': ').slice(1).join(': ')}`;
  }
  if (message.includes('DEALER_OWNER system role is missing')) {
    return 'The system roles are missing from this database. Run seed.sql before provisioning.';
  }
  if (message.includes('platform administrator')) {
    return 'Only a platform administrator can provision a dealer.';
  }
  return message;
}

export async function provisionDealer(input: ProvisionInput): Promise<ProvisionResult> {
  const context = await requirePlatformAdmin();
  const admin = createSupabaseAdminClient();
  const supabase = await createSupabaseServerClient();

  const email = input.ownerEmail.trim().toLowerCase();
  if (!email || !input.code.trim() || !input.legalName.trim()) {
    return { ok: false, error: 'Dealer code, legal name and owner email are all required.' };
  }

  // ── 1. The owner's auth account, created but not yet invited ─────────────
  const created = await admin.auth.admin.createUser({
    email,
    email_confirm: false,
    user_metadata: { full_name: input.ownerName.trim() },
  });

  if (created.error || !created.data.user) {
    const message = created.error?.message ?? 'The owner account could not be created.';
    return {
      ok: false,
      error: message.toLowerCase().includes('already')
        ? 'A login already exists for that email address.'
        : `The owner account could not be created: ${message}`,
    };
  }

  const ownerId = created.data.user.id;

  // ── 2. The tenant, in one transaction ────────────────────────────────────
  const { data, error } = await supabase.rpc('provision_dealer', {
    p_code: input.code.trim().toUpperCase(),
    p_legal_name: input.legalName.trim(),
    p_trade_name: input.tradeName?.trim() || input.legalName.trim(),
    p_state: input.state.trim(),
    p_state_code: input.stateCode.trim(),
    p_owner_email: email,
    p_owner_name: input.ownerName.trim(),
    p_owner_user_id: ownerId,
    p_branch_name: input.branchName?.trim() || 'Head Office',
    p_gstin: input.gstin?.trim().toUpperCase() || null,
    p_pan: input.pan?.trim().toUpperCase() || null,
    p_city: input.city?.trim() || null,
    p_phone: input.phone?.trim() || null,
  });

  if (error) {
    // The transaction rolled back, so the tenant does not exist. Take the auth
    // account back too, or it is left orphaned — a login that can sign in and be
    // authorized for nothing.
    await admin.auth.admin.deleteUser(ownerId).catch(() => undefined);
    console.error('[provisioning] failed', error.message);
    return { ok: false, error: describeProvisionError(error.message) };
  }

  const row = Array.isArray(data) ? data[0] : data;
  const dealerId = row?.new_dealer_id;

  if (!dealerId) {
    await admin.auth.admin.deleteUser(ownerId).catch(() => undefined);
    return { ok: false, error: 'Provisioning returned no dealer. Nothing was changed.' };
  }

  await recordAudit({
    action: 'CREATE',
    entityType: 'dealers',
    entityId: dealerId,
    dealerId,
    branchId: null,
    userId: context.userId,
    userEmail: context.email,
    newData: {
      code: input.code.trim().toUpperCase(),
      legal_name: input.legalName.trim(),
      accounts: row?.accounts_created ?? 0,
      rules: row?.rules_created ?? 0,
      owner_email: email,
    },
  });

  const readiness = await getDealerReadiness(dealerId);

  // ── 3. The invite — after the commit, never before ───────────────────────
  // The tenant exists from here whatever happens next. A failed invite is a
  // Resend away; a sent invite for a rolled-back tenant is not recoverable.
  const invited = await admin.auth.admin.inviteUserByEmail(email, {
    redirectTo: `${publicEnv.appUrl}/reset-password`,
  });

  if (invited.error) {
    console.error('[provisioning] invite failed', invited.error.message);
    return {
      ok: true,
      dealerId,
      inviteFailed: true,
      readiness,
      message:
        `${input.legalName.trim()} was created, but the invite email could not be sent. ` +
        'The tenant is ready — use Resend invite to try again.',
    };
  }

  return {
    ok: true,
    dealerId,
    readiness,
    message:
      `${input.legalName.trim()} is provisioned with ${row?.accounts_created ?? 0} accounts ` +
      `and ${row?.rules_created ?? 0} accounting rules. An invite has gone to ${email}.`,
  };
}

export interface TenantRow {
  readonly id: string;
  readonly code: string;
  readonly legalName: string;
  readonly tradeName: string | null;
  readonly gstin: string | null;
  readonly city: string | null;
  readonly state: string | null;
  readonly status: string;
  readonly createdAt: string;
  readonly branchCount: number;
  readonly userCount: number;
  /** True once anything has been posted — from then on it can only be closed. */
  readonly hasPosted: boolean;
}

/** Every tenant on the platform. Platform admins only; RLS shows them all. */
export async function getTenants(): Promise<readonly TenantRow[]> {
  await requirePlatformAdmin();
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase
    .from('dealers')
    .select('id, code, legal_name, trade_name, gstin, city, state, status, created_at')
    .order('created_at', { ascending: false });

  if (error) {
    throw new Error(`Failed to load tenants: ${error.message}`);
  }

  const ids = (data ?? []).map((d) => d.id);
  if (ids.length === 0) return [];

  // Counted in three queries rather than three per tenant.
  const [branches, users, posted] = await Promise.all([
    supabase.from('branches').select('dealer_id').in('dealer_id', ids),
    supabase.from('user_profiles').select('dealer_id').in('dealer_id', ids),
    supabase.from('journal_entries').select('dealer_id').in('dealer_id', ids).in('status', ['POSTED', 'REVERSED']),
  ]);

  const tally = (rows: { dealer_id: string | null }[] | null) => {
    const map = new Map<string, number>();
    for (const row of rows ?? []) {
      if (row.dealer_id) map.set(row.dealer_id, (map.get(row.dealer_id) ?? 0) + 1);
    }
    return map;
  };

  const branchCount = tally(branches.data);
  const userCount = tally(users.data);
  const postedCount = tally(posted.data);

  return (data ?? []).map((d) => ({
    id: d.id,
    code: d.code,
    legalName: d.legal_name,
    tradeName: d.trade_name,
    gstin: d.gstin,
    city: d.city,
    state: d.state,
    status: d.status,
    createdAt: d.created_at,
    branchCount: branchCount.get(d.id) ?? 0,
    userCount: userCount.get(d.id) ?? 0,
    hasPosted: (postedCount.get(d.id) ?? 0) > 0,
  }));
}

export async function getDealerReadiness(dealerId: string): Promise<readonly ReadinessCheck[]> {
  await requirePlatformAdmin();
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('dealer_readiness', { p_dealer_id: dealerId });
  if (error) {
    throw new Error(`Failed to check readiness: ${error.message}`);
  }
  return (data ?? []).map((row) => ({
    name: row.check_name,
    ok: row.ok,
    detail: row.detail,
  }));
}

/** Sends the invite again, for a tenant whose first one failed. */
export async function resendOwnerInvite(dealerId: string): Promise<ProvisionResult> {
  await requirePlatformAdmin();
  const supabase = await createSupabaseServerClient();
  const admin = createSupabaseAdminClient();

  const { data } = await supabase
    .from('user_profiles')
    .select('email')
    .eq('dealer_id', dealerId)
    .eq('status', 'ACTIVE')
    .limit(1)
    .maybeSingle();

  if (!data?.email) {
    return { ok: false, error: 'That dealer has no active user to invite.' };
  }

  const invited = await admin.auth.admin.inviteUserByEmail(data.email, {
    redirectTo: `${publicEnv.appUrl}/reset-password`,
  });

  if (invited.error) {
    return { ok: false, error: `The invite could not be sent: ${invited.error.message}` };
  }
  return { ok: true, message: `Invite sent to ${data.email}.` };
}

/**
 * Deletes a mis-created tenant.
 *
 * The database refuses once anything is posted — that ledger is the dealer's
 * statutory record whether or not they are still a customer. The owner's auth
 * account is removed here, because it lives outside the database's foreign keys
 * and would otherwise survive as a login authorized for nothing.
 */
export async function purgeDealer(dealerId: string, reason: string): Promise<ProvisionResult> {
  const context = await requirePlatformAdmin();
  const supabase = await createSupabaseServerClient();
  const admin = createSupabaseAdminClient();

  if (!reason.trim()) {
    return { ok: false, error: 'Purging a dealer needs a reason. It is written to the audit trail.' };
  }

  // Collected before the rows go; afterwards there is nothing left to read.
  const { data: users } = await supabase
    .from('user_profiles')
    .select('id, email')
    .eq('dealer_id', dealerId);

  const { error } = await supabase.rpc('purge_dealer', {
    p_dealer_id: dealerId,
    p_reason: reason.trim(),
  });

  if (error) {
    return {
      ok: false,
      error: error.message.includes('posted journals')
        ? 'This dealer has posted journals and cannot be deleted. Set them to CLOSED instead — their ledger is a statutory record.'
        : error.message,
    };
  }

  for (const user of users ?? []) {
    await admin.auth.admin.deleteUser(user.id).catch(() => undefined);
  }

  await recordAudit({
    action: 'DELETE',
    entityType: 'dealers',
    entityId: dealerId,
    dealerId: null,
    branchId: null,
    userId: context.userId,
    userEmail: context.email,
    reason: reason.trim(),
  });

  return { ok: true, message: 'The tenant and its logins were removed.' };
}
