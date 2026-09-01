'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/cash/cash-service';
import { toAppError } from '@/server/errors';

function refreshCashBook() {
  revalidatePath('/cash-book');
  revalidatePath('/cash-book/receipts');
  revalidatePath('/cash-book/payments');
  revalidatePath('/cash-book/day-close');
  revalidatePath('/dashboard');
}

export async function recordCashAction(
  input: service.CashTransactionInput,
): Promise<service.CashResult> {
  try {
    const result = await service.recordCashTransaction(input);
    if (result.ok) refreshCashBook();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function closeCashDayAction(input: {
  date: string;
  physicalCash: number;
  denominations?: Record<string, number> | null;
  remarks?: string | null;
}): Promise<service.CashResult> {
  try {
    const result = await service.closeCashDay(input);
    if (result.ok) refreshCashBook();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function reopenCashDayAction(input: {
  date: string;
  reason: string;
}): Promise<service.CashResult> {
  try {
    const result = await service.reopenCashDay(input);
    if (result.ok) refreshCashBook();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
