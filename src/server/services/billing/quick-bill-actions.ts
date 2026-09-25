'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/billing/quick-bill-service';
import { toAppError } from '@/server/errors';

export async function createQuickBillAction(
  input: Parameters<typeof service.createQuickBill>[0],
): Promise<service.QuickBillResult> {
  try {
    const result = await service.createQuickBill(input);
    if (result.ok) {
      revalidatePath('/service/billing');
      revalidatePath('/inventory/counter-sales');
      revalidatePath('/cash-book', 'layout');
      revalidatePath('/customers', 'layout');
      revalidatePath('/dashboard');
    }
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function findBillCustomerAction(input: { mobile?: string; vehicleNo?: string }) {
  try {
    return await service.findBillCustomer(input);
  } catch {
    return null;
  }
}

export async function saveQuickBillTaxCodesAction(v: Record<string, string>) {
  try {
    const heads = ['SPARES', 'ACCESSORIES', 'LABOUR', 'WATERWASH', 'CONSUMABLES', 'OTHER'] as const;
    const result = await service.setQuickBillTaxCodes(
      Object.fromEntries(heads.map((h) => [h, v[h] || 'GST18'])) as Record<(typeof heads)[number], string>,
      Object.fromEntries(heads.map((h) => [h, (v[`${h}_hsn`] ?? '').trim()])) as Record<(typeof heads)[number], string>,
    );
    if (result.ok) revalidatePath('/admin/settings');
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
