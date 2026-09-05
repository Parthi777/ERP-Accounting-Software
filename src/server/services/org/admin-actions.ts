'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/org/admin-service';
import { toAppError } from '@/server/errors';

/**
 * Administration — spec §6, §46.
 *
 * Everything here changes who can do what, so every one of them is audited by
 * the service before it returns.
 */
function refreshAdmin() {
  revalidatePath('/admin/users');
  revalidatePath('/admin/roles');
  revalidatePath('/admin/branches');
}

export async function saveRoleAction(input: service.RoleInput): Promise<service.AdminResult> {
  try {
    const result = await service.saveRole(input);
    if (result.ok) refreshAdmin();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function deleteRoleAction(roleId: string): Promise<service.AdminResult> {
  try {
    const result = await service.deleteRole(roleId);
    if (result.ok) refreshAdmin();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function saveBranchAction(input: service.BranchInput): Promise<service.AdminResult> {
  try {
    const result = await service.saveBranch(input);
    if (result.ok) refreshAdmin();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function setBranchStatusAction(
  branchId: string,
  status: 'ACTIVE' | 'SUSPENDED' | 'CLOSED',
): Promise<service.AdminResult> {
  try {
    const result = await service.setBranchStatus(branchId, status);
    if (result.ok) refreshAdmin();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function createUserAction(input: service.CreateUserInput): Promise<service.AdminResult> {
  try {
    const result = await service.createUser(input);
    if (result.ok) refreshAdmin();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function updateUserAction(input: service.UpdateUserInput): Promise<service.AdminResult> {
  try {
    const result = await service.updateUser(input);
    if (result.ok) refreshAdmin();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function resetUserPasswordAction(
  userId: string,
  mode: service.CredentialMode,
  password?: string,
): Promise<service.AdminResult> {
  try {
    return await service.resetUserPassword(userId, mode, password);
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

/** One tenant's branches, for the platform admin's console. */
export async function getDealerBranchesAction(dealerId: string) {
  try {
    return await service.getDealerBranches(dealerId);
  } catch {
    return [];
  }
}

/** Loaded on demand so the edit dialog opens with what the person actually has. */
export async function getUserDetailAction(userId: string) {
  try {
    return await service.getUserDetail(userId);
  } catch {
    return null;
  }
}

export async function getRoleDetailAction(roleId: string) {
  try {
    return await service.getRoleDetail(roleId);
  } catch {
    return null;
  }
}
