'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/purchases/purchase-return-service';
import { toAppError } from '@/server/errors';

/**
 * Purchase returns — spec §21, §23, §34, §41.
 *
 * A note moves stock and money, so every book that itemises either is
 * revalidated alongside the note and the bill it came off.
 */
function refresh(billId: string, returnId?: string) {
  revalidatePath('/purchases/returns');
  revalidatePath('/purchases');
  revalidatePath(`/purchases/${billId}`);
  if (returnId) revalidatePath(`/purchases/returns/${returnId}`);
  revalidatePath('/vehicles');
  revalidatePath('/inventory/accessories');
  revalidatePath('/inventory/spares');
  revalidatePath('/inventory/ledger');
  revalidatePath('/accounting/journals');
  revalidatePath('/accounting/supplier-ledger');
  revalidatePath('/accounting/trial-balance');
}

export async function postPurchaseReturnAction(
  input: service.PostPurchaseReturnInput,
): Promise<service.PurchaseReturnResult> {
  try {
    const result = await service.postPurchaseReturn(input);
    if (result.ok) refresh(input.billId, result.id);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function cancelPurchaseReturnAction(
  returnId: string,
  billId: string,
  reason: string,
): Promise<service.PurchaseReturnResult> {
  try {
    const result = await service.cancelPurchaseReturn(returnId, reason);
    if (result.ok) refresh(billId, returnId);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
