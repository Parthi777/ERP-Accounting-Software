'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/purchases/purchase-service';
import { toAppError } from '@/server/errors';

/**
 * Purchase bills — spec §24, §34, §41.
 *
 * Posting one moves stock and money, so the books that itemise both are
 * revalidated alongside the bill itself.
 */
function refresh(billId?: string) {
  revalidatePath('/purchases');
  if (billId) revalidatePath(`/purchases/${billId}`);
}

function refreshPosted(billId: string) {
  refresh(billId);
  revalidatePath('/vehicles');
  revalidatePath('/inventory/accessories');
  revalidatePath('/inventory/spares');
  revalidatePath('/inventory/ledger');
  revalidatePath('/accounting/journals');
  revalidatePath('/accounting/supplier-ledger');
  revalidatePath('/accounting/trial-balance');
}

export async function createPurchaseBillAction(
  input: service.CreatePurchaseInput,
): Promise<service.PurchaseResult> {
  try {
    const result = await service.createPurchaseBill(input);
    if (result.ok) refresh(result.id);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function addPurchaseLineAction(
  input: service.PurchaseLineInput,
): Promise<service.PurchaseResult> {
  try {
    const result = await service.addPurchaseLine(input);
    if (result.ok) refresh(input.billId);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function removePurchaseLineAction(
  lineId: string,
  billId: string,
): Promise<service.PurchaseResult> {
  try {
    const result = await service.removePurchaseLine(lineId);
    if (result.ok) refresh(billId);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function postPurchaseBillAction(
  billId: string,
): Promise<service.PurchaseResult> {
  try {
    const result = await service.postPurchaseBill(billId);
    if (result.ok) refreshPosted(billId);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function cancelPurchaseBillAction(
  billId: string,
  reason: string,
): Promise<service.PurchaseResult> {
  try {
    const result = await service.cancelPurchaseBill(billId, reason);
    if (result.ok) refreshPosted(billId);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
