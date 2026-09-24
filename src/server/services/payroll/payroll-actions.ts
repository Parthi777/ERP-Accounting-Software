'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/payroll/payroll-service';
import { toAppError } from '@/server/errors';

type R = { ok: boolean; error?: string; message?: string };

async function run(fn: () => Promise<R>): Promise<R> {
  try {
    const result = await fn();
    if (result.ok) revalidatePath('/hr/payroll', 'layout');
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function createPayrollRunAction(v: Record<string, string>): Promise<R> {
  return run(() => service.createPayrollRun(`${v.month}-01`, v.branchId ?? ''));
}

export async function updatePayrollLineAction(v: Record<string, string>): Promise<R> {
  return run(() => service.updatePayrollLine(v.lineId ?? '', Number(v.tds || 0), Number(v.other || 0)));
}

export async function postPayrollRunAction(v: Record<string, string>): Promise<R> {
  return run(() => service.postPayrollRun(v.runId ?? ''));
}

export async function payPayrollRunAction(v: Record<string, string>): Promise<R> {
  return run(() => service.payPayrollRun(v.runId ?? '', v.bankAccountId ?? '', v.date ?? ''));
}
