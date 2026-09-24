'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/accounting/chart-service';
import { toAppError } from '@/server/errors';

export async function createAccountAction(
  input: Parameters<typeof service.createAccount>[0],
): Promise<service.ChartResult> {
  try {
    const result = await service.createAccount(input);
    if (result.ok) revalidatePath('/accounting/chart-of-accounts');
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function setAccountStatusAction(
  accountId: string,
  status: 'ACTIVE' | 'INACTIVE',
): Promise<service.ChartResult> {
  try {
    const result = await service.setAccountStatus(accountId, status);
    if (result.ok) revalidatePath('/accounting/chart-of-accounts');
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function setBooksLockAction(
  input: Parameters<typeof service.setBooksLock>[0],
): Promise<service.ChartResult> {
  try {
    const result = await service.setBooksLock(input);
    if (result.ok) {
      revalidatePath('/accounting/journals');
      revalidatePath('/accounting/trial-balance');
    }
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
