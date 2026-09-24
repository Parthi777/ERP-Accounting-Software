'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/loans/loan-service';
import { toAppError } from '@/server/errors';

type R = { ok: boolean; error?: string; message?: string };

async function run(fn: () => Promise<R>): Promise<R> {
  try {
    const result = await fn();
    if (result.ok) {
      revalidatePath('/accounting/loans');
      revalidatePath('/bank/book');
    }
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function createLoanAction(v: Record<string, string>): Promise<R> {
  return run(() => service.createLoan({
    lender: v.lender ?? '', principal: Number(v.principal), rate: Number(v.rate),
    startDate: v.startDate ?? '', tenure: Number(v.tenure),
  }));
}

export async function loanTransactionAction(v: Record<string, string>): Promise<R> {
  return run(() => service.recordLoanTransaction({
    loanId: v.loanId ?? '', kind: v.kind === 'DISBURSEMENT' ? 'DISBURSEMENT' : 'REPAYMENT',
    bankAccountId: v.bankAccountId ?? '', date: v.date ?? '', principal: Number(v.principal || 0),
    interest: Number(v.interest || 0), idempotencyKey: v.idempotencyKey ?? crypto.randomUUID(),
  }));
}
