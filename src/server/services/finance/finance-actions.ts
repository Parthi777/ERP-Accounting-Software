'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/finance/finance-service';
import { toAppError } from '@/server/errors';

/** Finance touches the ledger, the bank book and the dashboard together. */
function refresh() {
  revalidatePath('/finance/hp-sales');
  revalidatePath('/finance/trade-advances');
  revalidatePath('/finance/settlements');
  revalidatePath('/bank/book');
  revalidatePath('/accounting/journals');
  revalidatePath('/reports/finance');
  revalidatePath('/dashboard');
}

export async function createFinanceApplicationAction(
  input: service.CreateApplicationInput,
): Promise<service.FinanceResult> {
  try {
    const result = await service.createFinanceApplication(input);
    if (result.ok) refresh();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function decideFinanceApplicationAction(
  id: string,
  decision: 'APPROVED' | 'REJECTED' | 'CANCELLED',
  approvedAmount?: number,
  reason?: string,
): Promise<service.FinanceResult> {
  try {
    const result = await service.decideFinanceApplication(id, decision, approvedAmount, reason);
    if (result.ok) refresh();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function disburseFinanceApplicationAction(input: {
  applicationId: string;
  amount: number;
  bankAccountId: string;
  ddNumber?: string | null;
  bankReference?: string | null;
}): Promise<service.FinanceResult> {
  try {
    const result = await service.disburseFinanceApplication(input);
    if (result.ok) refresh();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function recordTradeAdvanceAction(input: {
  companyId: string;
  type: service.TradeAdvanceType;
  amount: number;
  bankAccountId?: string | null;
  date?: string;
  narration?: string | null;
  reference?: string | null;
}): Promise<service.FinanceResult> {
  try {
    const result = await service.recordTradeAdvance(input);
    if (result.ok) refresh();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function createFinanceSettlementAction(input: {
  companyId: string;
  from: string;
  to: string;
  gross: number;
  commission?: number;
  deductions?: number;
  notes?: string | null;
}): Promise<service.FinanceResult> {
  try {
    const result = await service.createFinanceSettlement(input);
    if (result.ok) refresh();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function postFinanceSettlementAction(
  id: string,
  bankAccountId: string,
): Promise<service.FinanceResult> {
  try {
    const result = await service.postFinanceSettlement(id, bankAccountId);
    if (result.ok) refresh();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
