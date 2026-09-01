'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/bank/bank-service';
import { parseStatement, type StatementParseResult } from '@/server/services/bank/statement-parser';
import { requirePermission } from '@/server/auth/tenant-context';
import { toAppError } from '@/server/errors';

function refreshBank() {
  revalidatePath('/bank');
  revalidatePath('/bank/book');
  revalidatePath('/bank/import');
  revalidatePath('/bank/reconciliation');
  revalidatePath('/dashboard');
}

export async function recordBankTransactionAction(
  input: service.BankTransactionInput,
): Promise<service.BankResult> {
  try {
    const result = await service.recordBankTransaction(input);
    if (result.ok) refreshBank();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function importStatementAction(
  bankAccountId: string,
  rows: readonly service.ParsedStatementRow[],
): Promise<service.ImportResult> {
  try {
    const result = await service.importStatement(bankAccountId, rows);
    if (result.ok) refreshBank();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function matchLineAction(
  statementLineId: number,
  transactionId: number,
): Promise<service.BankResult> {
  try {
    const result = await service.matchLine(statementLineId, transactionId);
    if (result.ok) refreshBank();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function unmatchLineAction(statementLineId: number): Promise<service.BankResult> {
  try {
    const result = await service.unmatchLine(statementLineId);
    if (result.ok) refreshBank();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function ignoreLineAction(statementLineId: number): Promise<service.BankResult> {
  try {
    const result = await service.ignoreLine(statementLineId);
    if (result.ok) refreshBank();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function completeReconciliationAction(input: {
  bankAccountId: string;
  from: string;
  to: string;
  statementClosing: number;
  notes?: string | null;
}): Promise<service.BankResult> {
  try {
    const result = await service.completeReconciliation(input);
    if (result.ok) refreshBank();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

/**
 * Parses a statement without writing anything, so the operator sees exactly what
 * will land — and what will not — before committing (the same Upload → Preview →
 * Confirm shape as the vehicle stock import, spec §14, §39).
 */
export async function previewStatementAction(csv: string): Promise<StatementParseResult> {
  await requirePermission('bank.statement.import');
  return parseStatement(csv);
}
