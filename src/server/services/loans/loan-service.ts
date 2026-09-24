import 'server-only';

import { requirePermission } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { fromDb, type Paise } from '@/lib/money';

/** Loans — checklist §02 "loans and interest" (0082). */

export interface LoanRow {
  readonly id: string; readonly number: string; readonly lender: string; readonly principal: Paise;
  readonly rate: number; readonly tenure: number; readonly startDate: string; readonly status: string;
  readonly disbursed: Paise; readonly repaid: Paise; readonly interestPaid: Paise; readonly outstanding: Paise;
}

export interface ScheduleRow {
  readonly instalment: number; readonly dueDate: string; readonly emi: number;
  readonly principal: number; readonly interest: number; readonly balance: number;
}

export interface Result { readonly ok: boolean; readonly error?: string; readonly message?: string }

export async function getLoans(): Promise<LoanRow[]> {
  await requirePermission('loans.view');
  const supabase = await createSupabaseServerClient();
  const [{ data: loans, error }, { data: txns }] = await Promise.all([
    supabase.from('loans').select('id, loan_number, lender, principal, interest_rate, tenure_months, start_date, status').order('loan_number'),
    supabase.from('loan_transactions').select('loan_id, kind, principal, interest'),
  ]);
  if (error) throw new Error(`Failed to load loans: ${error.message}`);
  return (loans ?? []).map((l) => {
    const mine = (txns ?? []).filter((t) => t.loan_id === l.id);
    const sum = (kind: string, field: 'principal' | 'interest') =>
      mine.filter((t) => t.kind === kind).reduce((s, t) => s + fromDb(t[field]), 0);
    const disbursed = sum('DISBURSEMENT', 'principal');
    const repaid = sum('REPAYMENT', 'principal');
    return {
      id: l.id, number: l.loan_number, lender: l.lender, principal: fromDb(l.principal),
      rate: Number(l.interest_rate), tenure: l.tenure_months, startDate: l.start_date, status: l.status,
      disbursed: disbursed as Paise, repaid: repaid as Paise,
      interestPaid: sum('REPAYMENT', 'interest') as Paise, outstanding: (disbursed - repaid) as Paise,
    };
  });
}

export async function getSchedule(loanId: string): Promise<ScheduleRow[]> {
  await requirePermission('loans.view');
  const supabase = await createSupabaseServerClient();
  const { data } = await supabase.rpc('loan_schedule', { p_loan_id: loanId });
  return (data ?? []).map((r) => ({
    instalment: r.instalment, dueDate: r.due_date, emi: Number(r.emi),
    principal: Number(r.principal), interest: Number(r.interest), balance: Number(r.balance),
  }));
}

export async function createLoan(input: {
  readonly lender: string; readonly principal: number; readonly rate: number;
  readonly startDate: string; readonly tenure: number;
}): Promise<Result> {
  await requirePermission('loans.manage');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('create_loan', {
    p_lender: input.lender, p_principal: input.principal, p_interest_rate: input.rate,
    p_start_date: input.startDate, p_tenure_months: input.tenure,
  });
  return error ? { ok: false, error: error.message } : { ok: true, message: 'Loan recorded. Record the disbursement when the money arrives.' };
}

export async function recordLoanTransaction(input: {
  readonly loanId: string; readonly kind: 'DISBURSEMENT' | 'REPAYMENT'; readonly bankAccountId: string;
  readonly date: string; readonly principal: number; readonly interest: number; readonly idempotencyKey: string;
}): Promise<Result> {
  await requirePermission('loans.manage');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('record_loan_transaction', {
    p_loan_id: input.loanId, p_kind: input.kind, p_bank_account_id: input.bankAccountId, p_date: input.date,
    p_principal: input.principal, p_interest: input.interest, p_idempotency_key: input.idempotencyKey,
  });
  return error ? { ok: false, error: error.message } : { ok: true, message: 'Recorded in the ledger and the bank book.' };
}
