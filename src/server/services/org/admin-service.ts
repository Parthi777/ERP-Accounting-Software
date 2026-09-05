import 'server-only';

import { requirePermission } from '@/server/auth/tenant-context';
import {
  createSupabaseServerClient,
  createSupabaseAdminClient,
} from '@/lib/supabase/server';
import { recordAudit } from '@/server/services/audit/record-audit';
import { publicEnv } from '@/config/env';
import { PERMISSIONS } from '@/lib/permissions';

/**
 * Administration — spec §5, §6, §46, §47.
 *
 * The Administration section was built as a view: users, roles and branches
 * could all be read and none of them changed. This is the writing half.
 *
 * Nothing here needed a migration. Every RLS policy it relies on has existed
 * since 0009 — roles_insert, role_permissions_write, user_profiles_insert,
 * user_branches_write, branches_insert — each already gated on the matching
 * admin.*.manage permission. The database was ready; the application had simply
 * never asked.
 */

export interface AdminResult {
  readonly ok: boolean;
  readonly id?: string;
  readonly error?: string;
  readonly message?: string;
}

/** A permission, with the module grouping and sensitivity the picker needs. */
export interface PermissionOption {
  readonly code: string;
  readonly module: string;
  readonly description: string;
  readonly sensitive: boolean;
}

export const PERMISSION_CATALOGUE: readonly PermissionOption[] = PERMISSIONS.map((p) => ({
  code: p.code,
  module: p.module,
  description: p.description,
  sensitive: 'sensitive' in p,
}));

function describeAdminError(message: string): string {
  if (message.includes('roles_dealer_code_key') || message.includes('roles_system_code_key')) {
    return 'A role with that code already exists.';
  }
  if (message.includes('branches_dealer_code_key')) {
    return 'A branch with that code already exists for this dealer.';
  }
  if (message.includes('user_profiles_email')) {
    return 'That email address is already in use.';
  }
  if (message.includes('violates row-level security')) {
    return 'You do not have permission to make that change.';
  }
  if (message.includes('branches_gstin_check')) {
    return 'That GSTIN is not in the right format.';
  }
  return message;
}

// ─────────────────────────────────────────────────────────────────────────────
// Roles and their permissions
// ─────────────────────────────────────────────────────────────────────────────

export interface RoleDetail {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly description: string | null;
  readonly isSystem: boolean;
  readonly permissions: readonly string[];
  readonly userCount: number;
}

export async function getRoleDetail(roleId: string): Promise<RoleDetail | null> {
  await requirePermission('admin.roles.view');
  const supabase = await createSupabaseServerClient();

  const [role, users] = await Promise.all([
    supabase
      .from('roles')
      .select('id, code, name, description, is_system, role_permissions ( permission_code )')
      .eq('id', roleId)
      .maybeSingle(),
    supabase.from('user_roles').select('user_id').eq('role_id', roleId),
  ]);

  if (role.error) throw new Error(`Failed to load the role: ${role.error.message}`);
  if (!role.data) return null;

  return {
    id: role.data.id,
    code: role.data.code,
    name: role.data.name,
    description: role.data.description,
    isSystem: role.data.is_system,
    permissions: (role.data.role_permissions ?? []).map((g) => g.permission_code),
    userCount: (users.data ?? []).length,
  };
}

export interface RoleInput {
  readonly id?: string | null;
  readonly code: string;
  readonly name: string;
  readonly description?: string | null;
  readonly permissions: readonly string[];
}

/**
 * Creates or updates one of this dealer's own roles.
 *
 * A system role is never editable here, and the guard matters: the seven system
 * roles are global rows with dealer_id = null, shared by every tenant. Editing
 * one would silently change what a Cashier can do at every other dealership on
 * the platform. A dealer who wants different permissions makes their own role.
 */
export async function saveRole(input: RoleInput): Promise<AdminResult> {
  const context = await requirePermission('admin.roles.manage');
  const supabase = await createSupabaseServerClient();

  if (!input.code.trim() || !input.name.trim()) {
    return { ok: false, error: 'A role needs a code and a name.' };
  }

  const valid = new Set(PERMISSIONS.map((p) => p.code as string));
  const unknown = input.permissions.filter((code) => !valid.has(code));
  if (unknown.length > 0) {
    return { ok: false, error: `Unknown permission: ${unknown[0]}.` };
  }

  let roleId = input.id ?? null;

  if (roleId) {
    const existing = await getRoleDetail(roleId);
    if (!existing) return { ok: false, error: 'That role no longer exists.' };
    if (existing.isSystem) {
      return {
        ok: false,
        error:
          'System roles are shared by every dealer on the platform and cannot be edited. Create your own role instead.',
      };
    }

    const { error } = await supabase
      .from('roles')
      .update({
        name: input.name.trim(),
        description: input.description?.trim() || null,
      })
      .eq('id', roleId);

    if (error) return { ok: false, error: describeAdminError(error.message) };
  } else {
    const { data, error } = await supabase
      .from('roles')
      .insert({
        dealer_id: context.dealerId!,
        code: input.code.trim().toUpperCase(),
        name: input.name.trim(),
        description: input.description?.trim() || null,
        is_system: false,
      })
      .select('id')
      .single();

    if (error) return { ok: false, error: describeAdminError(error.message) };
    roleId = data.id;
  }

  // Replace the grants wholesale: "what may this role do" is one decision, and a
  // diff would leave a window where it is half-applied.
  await supabase.from('role_permissions').delete().eq('role_id', roleId);

  if (input.permissions.length > 0) {
    const { error } = await supabase.from('role_permissions').insert(
      input.permissions.map((code) => ({ role_id: roleId!, permission_code: code })),
    );
    if (error) return { ok: false, error: describeAdminError(error.message) };
  }

  await recordAudit({
    action: input.id ? 'UPDATE' : 'CREATE',
    entityType: 'roles',
    entityId: roleId!,
    dealerId: context.dealerId,
    branchId: null,
    userId: context.userId,
    userEmail: context.email,
    newData: { code: input.code, name: input.name, permissions: input.permissions.length },
  });

  return { ok: true, id: roleId!, message: `${input.name.trim()} saved with ${input.permissions.length} permissions.` };
}

export async function deleteRole(roleId: string): Promise<AdminResult> {
  const context = await requirePermission('admin.roles.manage');
  const supabase = await createSupabaseServerClient();

  const role = await getRoleDetail(roleId);
  if (!role) return { ok: false, error: 'That role no longer exists.' };
  if (role.isSystem) {
    return { ok: false, error: 'System roles cannot be deleted.' };
  }
  if (role.userCount > 0) {
    return {
      ok: false,
      error: `${role.userCount} user${role.userCount === 1 ? ' is' : 's are'} still assigned this role. Move them first.`,
    };
  }

  await supabase.from('role_permissions').delete().eq('role_id', roleId);
  const { error } = await supabase.from('roles').delete().eq('id', roleId);
  if (error) return { ok: false, error: describeAdminError(error.message) };

  await recordAudit({
    action: 'DELETE',
    entityType: 'roles',
    entityId: roleId,
    dealerId: context.dealerId,
    branchId: null,
    userId: context.userId,
    userEmail: context.email,
    newData: { code: role.code, name: role.name },
  });

  return { ok: true, message: `${role.name} was deleted.` };
}

// ─────────────────────────────────────────────────────────────────────────────
// Branches
// ─────────────────────────────────────────────────────────────────────────────

export interface BranchInput {
  readonly id?: string | null;
  /**
   * Which dealer this branch belongs to. Only a platform administrator may name
   * one — everybody else gets their own, because their session has exactly one
   * and accepting it from the client is what spec §47 forbids.
   */
  readonly dealerId?: string | null;
  readonly code: string;
  readonly name: string;
  readonly city?: string | null;
  readonly state?: string | null;
  readonly stateCode?: string | null;
  readonly gstin?: string | null;
  readonly phone?: string | null;
  readonly isHeadOffice?: boolean;
}

/**
 * Adds or edits a branch of this dealer.
 *
 * A new branch gets a cash account immediately, because without one
 * record_cash_transaction() raises "This branch has no cash account" the first
 * time anyone takes money there — the same trap provisioning avoids for the
 * first branch.
 */
export async function saveBranch(input: BranchInput): Promise<AdminResult> {
  const context = await requirePermission('admin.branches.manage');
  const supabase = await createSupabaseServerClient();

  if (!input.code.trim() || !input.name.trim()) {
    return { ok: false, error: 'A branch needs a code and a name.' };
  }

  // A platform admin has no dealer of their own, so they must say which tenant
  // the branch is for — that is how branches get added while onboarding. Anyone
  // else is pinned to their own dealer whatever they send.
  const dealerId = context.isPlatformAdmin ? (input.dealerId ?? null) : context.dealerId;
  if (!dealerId) {
    return {
      ok: false,
      error: context.isPlatformAdmin
        ? 'Choose which dealer this branch belongs to.'
        : 'Your login is not attached to a dealer.',
    };
  }

  const row = {
    name: input.name.trim(),
    city: input.city?.trim() || null,
    state: input.state?.trim() || null,
    state_code: input.stateCode?.trim() || null,
    gstin: input.gstin?.trim().toUpperCase() || null,
    phone: input.phone?.trim() || null,
    is_head_office: input.isHeadOffice ?? false,
  };

  let branchId = input.id ?? null;

  if (branchId) {
    const { error } = await supabase
      .from('branches')
      .update({ ...row, updated_by: context.userId })
      .eq('id', branchId);
    if (error) return { ok: false, error: describeAdminError(error.message) };
  } else {
    const { data, error } = await supabase
      .from('branches')
      .insert({
        ...row,
        dealer_id: dealerId,
        code: input.code.trim().toUpperCase(),
        status: 'ACTIVE',
        created_by: context.userId,
      })
      .select('id')
      .single();
    if (error) return { ok: false, error: describeAdminError(error.message) };
    branchId = data.id;
  }

  await recordAudit({
    action: input.id ? 'UPDATE' : 'CREATE',
    entityType: 'branches',
    entityId: branchId!,
    dealerId,
    branchId,
    userId: context.userId,
    userEmail: context.email,
    newData: { code: input.code, name: input.name },
  });

  return {
    ok: true,
    id: branchId!,
    message: input.id
      ? `${input.name.trim()} was updated.`
      : `${input.name.trim()} was added. Its cash account is ready.`,
  };
}

export interface DealerBranch {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly city: string | null;
  readonly state: string | null;
  readonly gstin: string | null;
  readonly is_head_office: boolean;
  readonly status: string;
  /** True once anything has been booked to it — then it is suspended, not removed. */
  readonly hasActivity: boolean;
}

/**
 * One dealer's branches, for the tenant console.
 *
 * RLS shows a platform admin every branch, so the dealer filter here is what
 * makes the list mean "this tenant" rather than "everyone".
 */
export async function getDealerBranches(dealerId: string): Promise<readonly DealerBranch[]> {
  await requirePermission('admin.branches.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase
    .from('branches')
    .select('id, code, name, city, state, gstin, is_head_office, status')
    .eq('dealer_id', dealerId)
    .order('is_head_office', { ascending: false })
    .order('name');

  if (error) throw new Error(`Failed to load branches: ${error.message}`);

  const ids = (data ?? []).map((b) => b.id);
  const active = new Set<string>();
  if (ids.length > 0) {
    const { data: entries } = await supabase
      .from('journal_entries')
      .select('branch_id')
      .in('branch_id', ids)
      .limit(1000);
    for (const e of entries ?? []) if (e.branch_id) active.add(e.branch_id);
  }

  return (data ?? []).map((b) => ({ ...b, hasActivity: active.has(b.id) }));
}

export async function setBranchStatus(
  branchId: string,
  status: 'ACTIVE' | 'SUSPENDED' | 'CLOSED',
): Promise<AdminResult> {
  const context = await requirePermission('admin.branches.manage');
  const supabase = await createSupabaseServerClient();

  const { error } = await supabase
    .from('branches')
    .update({ status, updated_by: context.userId })
    .eq('id', branchId);

  if (error) return { ok: false, error: describeAdminError(error.message) };

  await recordAudit({
    action: 'UPDATE',
    entityType: 'branches',
    entityId: branchId,
    dealerId: context.dealerId,
    branchId,
    userId: context.userId,
    userEmail: context.email,
    newData: { status },
  });

  return {
    ok: true,
    message:
      status === 'ACTIVE' ? 'Branch reactivated.'
      : status === 'SUSPENDED' ? 'Branch suspended. Its records stay; no new work can be booked to it.'
      : 'Branch closed.',
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Users: the login, the role, and which branches they reach
// ─────────────────────────────────────────────────────────────────────────────

export interface UserDetail {
  readonly id: string;
  readonly fullName: string;
  readonly email: string;
  readonly mobile: string | null;
  readonly status: string;
  readonly hasAllBranchAccess: boolean;
  readonly isPlatformAdmin: boolean;
  readonly roleIds: readonly string[];
  readonly branchIds: readonly string[];
  readonly lastLoginAt: string | null;
}

export async function getUserDetail(userId: string): Promise<UserDetail | null> {
  await requirePermission('admin.users.view');
  const supabase = await createSupabaseServerClient();

  const [profile, roles, branches] = await Promise.all([
    supabase
      .from('user_profiles')
      .select('id, full_name, email, mobile, status, has_all_branch_access, is_platform_admin, last_login_at')
      .eq('id', userId)
      .maybeSingle(),
    supabase.from('user_roles').select('role_id').eq('user_id', userId),
    supabase.from('user_branches').select('branch_id').eq('user_id', userId),
  ]);

  if (profile.error) throw new Error(`Failed to load the user: ${profile.error.message}`);
  if (!profile.data) return null;

  return {
    id: profile.data.id,
    fullName: profile.data.full_name,
    email: profile.data.email,
    mobile: profile.data.mobile,
    status: profile.data.status,
    hasAllBranchAccess: profile.data.has_all_branch_access,
    isPlatformAdmin: profile.data.is_platform_admin,
    roleIds: (roles.data ?? []).map((r) => r.role_id),
    branchIds: (branches.data ?? []).map((b) => b.branch_id),
    lastLoginAt: profile.data.last_login_at,
  };
}

/** How the new user first gets in. */
export type CredentialMode = 'INVITE' | 'PASSWORD';

export interface CreateUserInput {
  readonly fullName: string;
  readonly email: string;
  readonly mobile?: string | null;
  readonly roleIds: readonly string[];
  /** Ignored when hasAllBranchAccess is true. */
  readonly branchIds: readonly string[];
  readonly hasAllBranchAccess: boolean;
  readonly credentialMode: CredentialMode;
  /** Required when credentialMode is PASSWORD. */
  readonly password?: string | null;
}

/**
 * Creates a login for this dealer.
 *
 * Two ways in, because dealerships have both kinds of staff:
 *
 *   INVITE    an email with a link; they choose their own password and nobody
 *             else ever knows it. Right for anyone with a working address.
 *   PASSWORD  the administrator sets one and hands it over. Right for counter
 *             and workshop staff who have no email in practice — and the only
 *             option that works at all if outbound email is not configured.
 *
 * The auth account is created first and deleted again if anything after it
 * fails, so a half-made user is never left behind: a login that can sign in and
 * is authorized for nothing is worse than no login.
 */
export async function createUser(input: CreateUserInput): Promise<AdminResult> {
  const context = await requirePermission('admin.users.manage');
  const supabase = await createSupabaseServerClient();
  const admin = createSupabaseAdminClient();

  const email = input.email.trim().toLowerCase();
  if (!input.fullName.trim() || !email) {
    return { ok: false, error: 'A name and an email address are required.' };
  }
  if (input.roleIds.length === 0) {
    return { ok: false, error: 'Give them at least one role, or they can sign in and do nothing.' };
  }
  if (input.credentialMode === 'PASSWORD') {
    if (!input.password || input.password.length < 8) {
      return { ok: false, error: 'Set a password of at least 8 characters.' };
    }
  }
  if (!input.hasAllBranchAccess && input.branchIds.length === 0) {
    return { ok: false, error: 'Choose at least one branch, or give them access to all of them.' };
  }
  if (!context.dealerId) {
    return { ok: false, error: 'Select a dealer before adding a user.' };
  }

  const created = await admin.auth.admin.createUser(
    input.credentialMode === 'PASSWORD'
      ? { email, password: input.password!, email_confirm: true, user_metadata: { full_name: input.fullName.trim() } }
      : { email, email_confirm: false, user_metadata: { full_name: input.fullName.trim() } },
  );

  if (created.error || !created.data.user) {
    const message = created.error?.message ?? 'The login could not be created.';
    return {
      ok: false,
      error: message.toLowerCase().includes('already')
        ? 'A login already exists for that email address.'
        : `The login could not be created: ${message}`,
    };
  }

  const userId = created.data.user.id;

  const undo = async () => {
    await admin.auth.admin.deleteUser(userId).catch(() => undefined);
  };

  const { error: profileError } = await supabase.from('user_profiles').insert({
    id: userId,
    dealer_id: context.dealerId,
    full_name: input.fullName.trim(),
    email,
    mobile: input.mobile?.trim() || null,
    has_all_branch_access: input.hasAllBranchAccess,
    status: 'ACTIVE',
  });

  if (profileError) {
    await undo();
    return { ok: false, error: describeAdminError(profileError.message) };
  }

  const { error: roleError } = await supabase
    .from('user_roles')
    .insert(input.roleIds.map((roleId) => ({ user_id: userId, role_id: roleId })));

  if (roleError) {
    await supabase.from('user_profiles').delete().eq('id', userId);
    await undo();
    return { ok: false, error: describeAdminError(roleError.message) };
  }

  if (!input.hasAllBranchAccess && input.branchIds.length > 0) {
    const { error: branchError } = await supabase.from('user_branches').insert(
      input.branchIds.map((branchId) => ({
        user_id: userId,
        branch_id: branchId,
        dealer_id: context.dealerId!,
      })),
    );
    if (branchError) {
      await supabase.from('user_roles').delete().eq('user_id', userId);
      await supabase.from('user_profiles').delete().eq('id', userId);
      await undo();
      return { ok: false, error: describeAdminError(branchError.message) };
    }
  }

  await recordAudit({
    action: 'CREATE',
    entityType: 'user_profiles',
    entityId: userId,
    dealerId: context.dealerId,
    branchId: null,
    userId: context.userId,
    userEmail: context.email,
    // Never the password itself, and never a hash of it.
    newData: {
      email,
      full_name: input.fullName.trim(),
      roles: input.roleIds.length,
      all_branches: input.hasAllBranchAccess,
      credential_mode: input.credentialMode,
    },
  });

  // The invite goes last, after everything that can fail has succeeded — the
  // same ordering provisioning uses, and for the same reason.
  if (input.credentialMode === 'INVITE') {
    const invited = await admin.auth.admin.inviteUserByEmail(email, {
      redirectTo: `${publicEnv.appUrl}/reset-password`,
    });
    if (invited.error) {
      return {
        ok: true,
        id: userId,
        message:
          `${input.fullName.trim()} was created, but the invite email could not be sent. ` +
          'Use Reset password to try again, or set a password directly.',
      };
    }
    return { ok: true, id: userId, message: `${input.fullName.trim()} was created. An invite has gone to ${email}.` };
  }

  return {
    ok: true,
    id: userId,
    message: `${input.fullName.trim()} was created. Hand them the password you set — they can change it once signed in.`,
  };
}

export interface UpdateUserInput {
  readonly id: string;
  readonly fullName: string;
  readonly mobile?: string | null;
  readonly roleIds: readonly string[];
  readonly branchIds: readonly string[];
  readonly hasAllBranchAccess: boolean;
  readonly status: 'ACTIVE' | 'SUSPENDED' | 'DISABLED';
}

export async function updateUser(input: UpdateUserInput): Promise<AdminResult> {
  const context = await requirePermission('admin.users.manage');
  const supabase = await createSupabaseServerClient();

  if (input.roleIds.length === 0) {
    return { ok: false, error: 'Give them at least one role, or they can sign in and do nothing.' };
  }
  if (!input.hasAllBranchAccess && input.branchIds.length === 0) {
    return { ok: false, error: 'Choose at least one branch, or give them access to all of them.' };
  }
  // Locking yourself out is the one mistake this screen can make that nobody
  // else can undo for you.
  if (input.id === context.userId && input.status !== 'ACTIVE') {
    return { ok: false, error: 'You cannot deactivate your own login.' };
  }

  const { error } = await supabase
    .from('user_profiles')
    .update({
      full_name: input.fullName.trim(),
      mobile: input.mobile?.trim() || null,
      has_all_branch_access: input.hasAllBranchAccess,
      status: input.status,
    })
    .eq('id', input.id);

  if (error) return { ok: false, error: describeAdminError(error.message) };

  // Roles and branches are replaced wholesale rather than diffed: "what may this
  // person do" is one decision, and a partial apply is a person with the wrong
  // access for however long it takes to notice.
  await supabase.from('user_roles').delete().eq('user_id', input.id);
  const { error: roleError } = await supabase
    .from('user_roles')
    .insert(input.roleIds.map((roleId) => ({ user_id: input.id, role_id: roleId })));
  if (roleError) return { ok: false, error: describeAdminError(roleError.message) };

  await supabase.from('user_branches').delete().eq('user_id', input.id);
  if (!input.hasAllBranchAccess && input.branchIds.length > 0) {
    const { error: branchError } = await supabase.from('user_branches').insert(
      input.branchIds.map((branchId) => ({
        user_id: input.id,
        branch_id: branchId,
        dealer_id: context.dealerId!,
      })),
    );
    if (branchError) return { ok: false, error: describeAdminError(branchError.message) };
  }

  await recordAudit({
    action: 'UPDATE',
    entityType: 'user_profiles',
    entityId: input.id,
    dealerId: context.dealerId,
    branchId: null,
    userId: context.userId,
    userEmail: context.email,
    newData: {
      full_name: input.fullName.trim(),
      status: input.status,
      roles: input.roleIds.length,
      all_branches: input.hasAllBranchAccess,
      branches: input.branchIds.length,
    },
  });

  return { ok: true, message: `${input.fullName.trim()} was updated.` };
}

/** Sets a new password, or sends a reset link — whichever suits the person. */
export async function resetUserPassword(
  userId: string,
  mode: CredentialMode,
  password?: string,
): Promise<AdminResult> {
  const context = await requirePermission('admin.users.manage');
  const admin = createSupabaseAdminClient();

  const user = await getUserDetail(userId);
  if (!user) return { ok: false, error: 'That user no longer exists.' };

  if (mode === 'PASSWORD') {
    if (!password || password.length < 8) {
      return { ok: false, error: 'Set a password of at least 8 characters.' };
    }
    const { error } = await admin.auth.admin.updateUserById(userId, { password });
    if (error) return { ok: false, error: `The password could not be set: ${error.message}` };
  } else {
    const { error } = await admin.auth.admin.inviteUserByEmail(user.email, {
      redirectTo: `${publicEnv.appUrl}/reset-password`,
    });
    if (error) return { ok: false, error: `The reset link could not be sent: ${error.message}` };
  }

  await recordAudit({
    action: 'UPDATE',
    entityType: 'user_profiles',
    entityId: userId,
    dealerId: context.dealerId,
    branchId: null,
    userId: context.userId,
    userEmail: context.email,
    // The fact, never the credential.
    newData: { password_reset: mode },
  });

  return {
    ok: true,
    message: mode === 'PASSWORD'
      ? `A new password is set for ${user.fullName}. Hand it over directly.`
      : `A reset link has gone to ${user.email}.`,
  };
}
