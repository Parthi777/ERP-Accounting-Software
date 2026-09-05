'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/org/provisioning-service';
import { toAppError } from '@/server/errors';

/**
 * Onboarding a dealer — spec §4, §48.
 *
 * Every one of these reaches Supabase Auth as well as the database, so none is
 * a pure database write and all of them can partially succeed in ways the
 * service explains rather than hides.
 */
export async function provisionDealerAction(
  input: service.ProvisionInput,
): Promise<service.ProvisionResult> {
  try {
    const result = await service.provisionDealer(input);
    if (result.ok) revalidatePath('/admin/dealers');
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function resendOwnerInviteAction(
  dealerId: string,
): Promise<service.ProvisionResult> {
  try {
    return await service.resendOwnerInvite(dealerId);
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function purgeDealerAction(
  dealerId: string,
  reason: string,
): Promise<service.ProvisionResult> {
  try {
    const result = await service.purgeDealer(dealerId, reason);
    if (result.ok) revalidatePath('/admin/dealers');
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
