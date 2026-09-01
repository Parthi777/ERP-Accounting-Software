'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/sales/sale-service';
import { toAppError } from '@/server/errors';

function refresh(id: string) {
  revalidatePath('/sales');
  revalidatePath(`/sales/${id}`);
  revalidatePath('/vehicles');
  revalidatePath('/dashboard');
}

export async function transitionSaleAction(
  id: string,
  action: 'submit' | 'verify' | 'approve' | 'reject' | 'cancel',
  reason?: string,
): Promise<service.SaleResult> {
  try {
    const result = await service.transitionSale(id, action, reason);
    if (result.ok) refresh(id);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function postSaleAction(id: string): Promise<service.SaleResult> {
  try {
    const result = await service.postSale(id);
    if (result.ok) refresh(id);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function recordPaymentAction(
  saleId: string, amount: number, mode: string, reference?: string,
): Promise<service.SaleResult> {
  try {
    const result = await service.recordPayment(saleId, amount, mode, reference);
    if (result.ok) refresh(saleId);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function deliverSaleAction(
  saleId: string, receivedBy?: string, odometer?: number, remarks?: string,
): Promise<service.SaleResult> {
  try {
    const result = await service.deliverSale(saleId, receivedBy, odometer, remarks);
    if (result.ok) refresh(saleId);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function createSaleDraftAction(
  input: service.CreateSaleInput,
): Promise<service.SaleResult> {
  try {
    const result = await service.createSaleDraft(input);
    if (result.ok) {
      revalidatePath('/sales');
      revalidatePath('/vehicles');
      revalidatePath('/bookings');
    }
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function returnSaleAction(
  saleId: string,
  reason: string,
): Promise<service.SaleResult> {
  try {
    const result = await service.returnSale(saleId, reason);
    if (result.ok) {
      refresh(saleId);
      revalidatePath('/sales/returns');
      revalidatePath('/inventory/ledger');
      revalidatePath('/accounting/journals');
    }
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
