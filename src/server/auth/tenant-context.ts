import 'server-only';

import { cache } from 'react';
import { cookies } from 'next/headers';

import { createPermissionSet, type Permission, type PermissionSet } from '@/lib/permissions';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { ForbiddenError, UnauthenticatedError } from '@/server/errors';

/**
 * Tenant context — the security spine of the application.
 *
 * Everything an authorization decision needs is resolved here, from the
 * authenticated session and the database, and from nowhere else. Spec §47 is
 * explicit that the following must never be read from the client:
 *
 *   - the user's role
 *   - dealer_id
 *   - branch_id
 *   - whether margin fields are visible
 *
 * The one thing the client does influence is *which* of the branches it already
 * has access to is currently active, via a cookie. That value is validated
 * against `accessibleBranches` below before it is honoured, so a forged cookie
 * simply falls back to the default branch.
 */

export const ACTIVE_BRANCH_COOKIE = 'tw_active_branch';

export interface BranchSummary {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly isHeadOffice: boolean;
}

export interface TenantContext {
  readonly userId: string;
  readonly email: string;
  readonly fullName: string;
  readonly isPlatformAdmin: boolean;

  readonly dealerId: string | null;
  readonly dealerName: string | null;
  readonly dealerCode: string | null;

  /** Branches this user may reach. Length > 1 enables the branch switcher. */
  readonly accessibleBranches: readonly BranchSummary[];
  /** The branch currently in context, or null when viewing all branches. */
  readonly activeBranch: BranchSummary | null;
  readonly hasAllBranchAccess: boolean;

  readonly roles: readonly string[];
  readonly permissions: PermissionSet;
}

/**
 * Resolves the current context, or null when there is no session.
 *
 * Wrapped in React's `cache` so a request that renders the sidebar, the header
 * and three server components performs one round of lookups, not five.
 */
export const getTenantContext = cache(async (): Promise<TenantContext | null> => {
  const supabase = await createSupabaseServerClient();

  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  if (authError || !user) {
    return null;
  }

  // All three run together. Neither the branch list nor the role list depends on
  // the profile row — branches are limited by RLS from the JWT, and roles are
  // keyed on the user id we already have — so awaiting the profile first cost a
  // whole network round trip on every page render for nothing.
  const [
    { data: profile, error: profileError },
    { data: branchRows },
    { data: roleRows },
  ] = await Promise.all([
    supabase
      .from('user_profiles')
      .select(
        `
        id,
        email,
        full_name,
        is_platform_admin,
        has_all_branch_access,
        default_branch_id,
        status,
        dealer_id,
        dealers ( id, code, trade_name, legal_name )
      `,
      )
      .eq('id', user.id)
      .maybeSingle(),
    // RLS already limits this to branches the user may reach, so no extra filter
    // is needed here — and adding one from client input is exactly what §47 forbids.
    supabase
      .from('branches')
      .select('id, code, name, is_head_office')
      .eq('status', 'ACTIVE')
      .order('is_head_office', { ascending: false })
      .order('name'),
    supabase
      .from('user_roles')
      .select('roles ( code, role_permissions ( permission_code ) )')
      .eq('user_id', user.id),
  ]);

  // A user with no profile row is authenticated but not yet provisioned into a
  // dealer. Treat that as no session rather than as a half-configured tenant.
  // Checked after the fetch rather than before: the other two queries were
  // already in flight, and discarding their results costs nothing.
  if (profileError || !profile || profile.status !== 'ACTIVE') {
    return null;
  }

  const accessibleBranches: BranchSummary[] = (branchRows ?? []).map((branch) => ({
    id: branch.id,
    code: branch.code,
    name: branch.name,
    isHeadOffice: branch.is_head_office,
  }));

  const roles: string[] = [];
  const permissionCodes = new Set<string>();
  for (const row of roleRows ?? []) {
    const role = row.roles;
    if (!role) {
      continue;
    }
    roles.push(role.code);
    for (const grant of role.role_permissions ?? []) {
      permissionCodes.add(grant.permission_code);
    }
  }

  const dealer = profile.dealers;

  return {
    userId: profile.id,
    email: profile.email,
    fullName: profile.full_name,
    isPlatformAdmin: profile.is_platform_admin,

    dealerId: profile.dealer_id,
    dealerName: dealer?.trade_name ?? dealer?.legal_name ?? null,
    dealerCode: dealer?.code ?? null,

    accessibleBranches,
    activeBranch: await resolveActiveBranch(accessibleBranches, profile.default_branch_id),
    hasAllBranchAccess: profile.has_all_branch_access || profile.is_platform_admin,

    roles,
    permissions: createPermissionSet([...permissionCodes]),
  };
});

/**
 * Picks the active branch from the cookie, but only if the user actually has
 * access to it. An unknown or forged value falls back to the default branch, then
 * to the head office, then to the first accessible branch.
 */
async function resolveActiveBranch(
  accessible: readonly BranchSummary[],
  defaultBranchId: string | null,
): Promise<BranchSummary | null> {
  if (accessible.length === 0) {
    return null;
  }

  const cookieStore = await cookies();
  const requested = cookieStore.get(ACTIVE_BRANCH_COOKIE)?.value;

  const fromCookie = requested ? accessible.find((branch) => branch.id === requested) : undefined;
  if (fromCookie) {
    return fromCookie;
  }

  const fromDefault = defaultBranchId
    ? accessible.find((branch) => branch.id === defaultBranchId)
    : undefined;

  return fromDefault ?? accessible.find((branch) => branch.isHeadOffice) ?? accessible[0] ?? null;
}

/** Context or bust. Use in any code path that must have a signed-in user. */
export async function requireTenantContext(): Promise<TenantContext> {
  const context = await getTenantContext();
  if (!context) {
    throw new UnauthenticatedError();
  }
  return context;
}

/**
 * Asserts a permission and returns the context, so a service can do both in one
 * line: `const ctx = await requirePermission('sales.post');`
 */
export async function requirePermission(...permissions: readonly Permission[]): Promise<TenantContext> {
  const context = await requireTenantContext();
  for (const permission of permissions) {
    if (!context.permissions.has(permission)) {
      throw new ForbiddenError(permission);
    }
  }
  return context;
}

export function hasPermission(context: TenantContext, permission: Permission): boolean {
  return context.permissions.has(permission);
}
