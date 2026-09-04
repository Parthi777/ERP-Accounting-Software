'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/accounting/settlement-service';
import { toAppError } from '@/server/errors';

/**
 * Settling a party ledger — spec §41.
 *
 * A split changes no accounting figure, so the pages revalidated here are the
 * ones that show which bills are still open, not the ones that show a balance.
 */
export async function splitPaymentAction(
  input: service.SplitInput,
): Promise<service.SettlementResult> {
  try {
    const result = await service.splitPayment(input);
    if (result.ok) {
      revalidatePath('/accounting/customer-ledger');
      revalidatePath('/accounting/supplier-ledger');
      revalidatePath('/customers/ledger');
    }
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
