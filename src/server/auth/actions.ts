'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { cookies } from 'next/headers';

import { createSupabaseServerClient } from '@/lib/supabase/server';
import { recordAudit } from '@/server/services/audit/record-audit';
import { ACTIVE_BRANCH_COOKIE, requireTenantContext } from '@/server/auth/tenant-context';

/**
 * Switches the active branch.
 *
 * The submitted id is checked against the branches the session actually has
 * access to before the cookie is written. Spec §47: a client-submitted branch_id
 * is never trusted on its own.
 */
export async function switchBranch(branchId: string): Promise<{ error?: string }> {
  const context = await requireTenantContext();

  const target = context.accessibleBranches.find((branch) => branch.id === branchId);
  if (!target) {
    return { error: 'You do not have access to that branch.' };
  }

  const cookieStore = await cookies();
  cookieStore.set(ACTIVE_BRANCH_COOKIE, target.id, {
    httpOnly: true,
    sameSite: 'lax',
    secure: process.env.NODE_ENV === 'production',
    path: '/',
    maxAge: 60 * 60 * 24 * 30,
  });

  await recordAudit({
    action: 'BRANCH_SWITCH',
    entityType: 'branches',
    entityId: target.id,
    dealerId: context.dealerId,
    branchId: target.id,
    userId: context.userId,
    newData: { branch_code: target.code, branch_name: target.name },
  });

  revalidatePath('/', 'layout');
  return {};
}

export async function signOut(): Promise<never> {
  const context = await getContextQuietly();
  const supabase = await createSupabaseServerClient();
  await supabase.auth.signOut();

  if (context) {
    await recordAudit({
      action: 'LOGOUT',
      entityType: 'user_profiles',
      entityId: context.userId,
      dealerId: context.dealerId,
      branchId: context.activeBranch?.id ?? null,
      userId: context.userId,
    });
  }

  redirect('/login');
}

/** Signing out must succeed even if the profile lookup fails. */
async function getContextQuietly() {
  try {
    return await requireTenantContext();
  } catch {
    return null;
  }
}
