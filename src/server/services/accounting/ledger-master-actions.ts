'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/accounting/ledger-master-service';
import type { ChartResult } from '@/server/services/accounting/chart-service';
import { toAppError } from '@/server/errors';

function refreshLedgers() {
  revalidatePath('/accounting/ledgers');
  revalidatePath('/accounting/ledger-groups');
  revalidatePath('/accounting/chart-of-accounts');
  revalidatePath('/accounting/trial-balance');
}

async function run(work: () => Promise<ChartResult>, after: () => void): Promise<ChartResult> {
  try {
    const result = await work();
    if (result.ok) after();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function createLedgerAction(input: Parameters<typeof service.createLedger>[0]): Promise<ChartResult> {
  return run(() => service.createLedger(input), refreshLedgers);
}

export async function modifyAccountAction(input: Parameters<typeof service.modifyAccount>[0]): Promise<ChartResult> {
  return run(() => service.modifyAccount(input), refreshLedgers);
}

export async function setOpeningBalanceAction(
  input: Parameters<typeof service.setOpeningBalance>[0],
): Promise<ChartResult> {
  return run(() => service.setOpeningBalance(input), () => {
    refreshLedgers();
    revalidatePath('/accounting/balance-sheet');
  });
}

function refreshYears() {
  revalidatePath('/accounting/financial-years');
  // The header's year switcher reads the years on every page.
  revalidatePath('/', 'layout');
}

export async function createFinancialYearAction(): Promise<ChartResult> {
  return run(() => service.createFinancialYear(), refreshYears);
}

export async function closeFinancialYearAction(values: Record<string, string>): Promise<ChartResult> {
  return run(() => service.closeFinancialYear(values.periodId ?? ''), refreshYears);
}

export async function reopenFinancialYearAction(values: Record<string, string>): Promise<ChartResult> {
  return run(() => service.reopenFinancialYear(values.periodId ?? '', values.reason ?? ''), refreshYears);
}
