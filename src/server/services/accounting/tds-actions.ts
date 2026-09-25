'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/accounting/tds-service';
import type { ChartResult } from '@/server/services/accounting/chart-service';
import { toAppError } from '@/server/errors';

async function run(work: () => Promise<ChartResult>, paths: string[] = ['/accounting/tds']): Promise<ChartResult> {
  try {
    const result = await work();
    if (result.ok) for (const p of paths) revalidatePath(p);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function saveDeductorAction(values: Record<string, string>) { return run(() => service.saveDeductor(values)); }
export async function addSectionAction(values: Record<string, string>) { return run(() => service.addSection(values)); }
export async function reviewSectionAction(values: Record<string, string>) { return run(() => service.reviewSection(values.id ?? '')); }
export async function endSectionAction(values: Record<string, string>) {
  return run(() => service.endSection(values.id ?? '', values.effectiveTo ?? ''));
}
export async function savePayeeAction(values: Record<string, string>) { return run(() => service.savePayee(values)); }
export async function recordRemittanceAction(input: Parameters<typeof service.recordRemittance>[0]) {
  return run(() => service.recordRemittance(input), ['/accounting/tds', '/bank/book']);
}
export async function setBillTdsModeAction(values: Record<string, string>) {
  const billId = values.billId ?? '';
  return run(() => service.setBillTdsMode(billId, values.mode === 'NONE' ? 'NONE' : 'AUTO'), [`/purchases/${billId}`]);
}
