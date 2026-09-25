'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/accounting/opening-balance-import';
import { toAppError } from '@/server/errors';

export async function previewOpeningBalancesAction(
  partyType: service.PartyType,
  csv: string,
): Promise<service.OpeningBalancePreview> {
  try {
    return await service.previewOpeningBalances(partyType, csv);
  } catch (error) {
    return {
      rows: [
        {
          rowNumber: 0, party_code: '', party_name: '', amount: '', direction: '',
          errors: [toAppError(error).userMessage],
        },
      ],
      validCount: 0,
      errorCount: 1,
      headers: [],
      net: 0,
    };
  }
}

export async function commitOpeningBalancesAction(
  partyType: service.PartyType,
  csv: string,
  asOn: string,
  idempotencyKey: string,
): Promise<service.OpeningBalanceResult> {
  try {
    const result = await service.commitOpeningBalances(partyType, csv, asOn, idempotencyKey);
    if (result.ok) {
      revalidatePath('/accounting/trial-balance');
      revalidatePath('/customers/ledger');
      revalidatePath('/accounting/supplier-ledger');
    }
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function previewOpeningBillsAction(
  partyType: service.PartyType,
  csv: string,
  asOn: string,
): Promise<service.OpeningBillPreview> {
  try {
    return await service.previewOpeningBills(partyType, csv, asOn);
  } catch (error) {
    return {
      rows: [{
        rowNumber: 0, party_code: '', party_name: '', bill_reference: '', bill_date: '', due_date: '', amount: '',
        errors: [toAppError(error).userMessage],
      }],
      validCount: 0,
      errorCount: 1,
      headers: [],
      total: 0,
    };
  }
}

export async function commitOpeningBillsAction(
  partyType: service.PartyType,
  csv: string,
  asOn: string,
  idempotencyKey: string,
): Promise<service.OpeningBalanceResult> {
  try {
    const result = await service.commitOpeningBills(partyType, csv, asOn, idempotencyKey);
    if (result.ok) {
      revalidatePath('/accounting/trial-balance');
      revalidatePath('/accounting/ageing');
      revalidatePath('/accounting/ledgers');
    }
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
