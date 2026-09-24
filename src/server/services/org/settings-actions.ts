'use server';

import { revalidatePath } from 'next/cache';

import { setDealerSwitch, type DealerSwitchKey } from '@/server/services/org/org-service';
import { toAppError } from '@/server/errors';

export async function setDealerSwitchAction(
  key: DealerSwitchKey,
  value: boolean,
): Promise<{ ok: boolean; error?: string }> {
  try {
    const result = await setDealerSwitch(key, value);
    if (result.ok) revalidatePath('/admin/settings');
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
