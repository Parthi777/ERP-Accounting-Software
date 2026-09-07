'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/vehicles/pricing-service';
import { toAppError } from '@/server/errors';

export async function createPriceVersionAction(input: service.PriceInput): Promise<service.PriceResult> {
  try {
    const result = await service.createPriceVersion(input);
    if (result.ok) {
      revalidatePath('/vehicles/pricing');
    }
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function decidePriceVersionAction(
  id: string,
  action: service.PriceAction,
  reason?: string,
): Promise<service.PriceResult> {
  try {
    const result = await service.decidePriceVersion(id, action, reason);
    if (result.ok) {
      revalidatePath('/masters/pricing');
      revalidatePath('/vehicles/pricing');
      revalidatePath('/sales/new');
    }
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function decideAllPriceVersionsAction(
  fromStatus: 'SUBMITTED' | 'APPROVED',
  action: 'APPROVE' | 'ACTIVATE',
): Promise<service.BulkPriceResult> {
  try {
    const result = await service.decideAllPriceVersions(fromStatus, action);
    if (result.done > 0) {
      revalidatePath('/masters/pricing');
      revalidatePath('/vehicles/pricing');
      revalidatePath('/sales/new');
    }
    return result;
  } catch (error) {
    return { ok: false, done: 0, failed: 0, error: toAppError(error).userMessage };
  }
}
