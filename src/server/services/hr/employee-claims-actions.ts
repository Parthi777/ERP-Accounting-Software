'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/hr/employee-claims-service';
import type { ChartResult } from '@/server/services/accounting/chart-service';
import { toAppError } from '@/server/errors';

async function run<T extends ChartResult>(work: () => Promise<T>, paths: string[]): Promise<T | ChartResult> {
  try {
    const result = await work();
    if (result.ok) for (const p of paths) revalidatePath(p);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

const CLAIMS = ['/cash-book/claims', '/hr/integration', '/cash-book'];

export async function payClaimsAction(input: Parameters<typeof service.payClaims>[0]) {
  return run(() => service.payClaims(input), CLAIMS) as Promise<ChartResult & { transactionId?: string }>;
}
export async function syncNowAction() { return run(() => service.syncNow(), CLAIMS); }
export async function resolveReviewAction(values: Record<string, string>) {
  return run(() => service.resolveReview(values.id ?? '', values.note ?? ''), CLAIMS);
}
export async function mapHeadAction(values: Record<string, string>) {
  return run(() => service.mapHead(values.claimType ?? '', values.accountId || null), CLAIMS);
}
export async function mapBranchAction(values: Record<string, string>) {
  return run(() => service.mapBranch(values.hrBranchId ?? '', values.branchId || null), CLAIMS);
}
export async function importPayrollAction(values: Record<string, string>) {
  return run(() => service.importPayroll(values.month ?? ''), ['/hr/payroll', '/hr/integration']);
}
