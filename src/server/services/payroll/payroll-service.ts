import 'server-only';

import { requirePermission } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { fromDb, type Paise } from '@/lib/money';

/** Payroll — checklist §02 "payroll" (0082). Pay is sensitive: hr.payroll.run only. */

export interface PayrollRun {
  readonly id: string; readonly period: string; readonly branch: string; readonly status: string;
  readonly journalEntryId: string | null; readonly paymentJournalId: string | null;
  readonly gross: Paise; readonly net: Paise; readonly employees: number;
}

export interface PayrollLine {
  readonly id: string; readonly employee: string; readonly code: string;
  readonly gross: Paise; readonly pf: Paise; readonly esi: Paise; readonly pt: Paise; readonly tds: Paise;
  readonly other: Paise; readonly net: Paise; readonly employerPf: Paise; readonly employerEsi: Paise;
}

export interface Result { readonly ok: boolean; readonly error?: string; readonly message?: string; readonly id?: string }

export async function getPayrollRuns(): Promise<PayrollRun[]> {
  await requirePermission('hr.payroll.run');
  const supabase = await createSupabaseServerClient();
  const [{ data: runs, error }, { data: lines }, { data: branches }] = await Promise.all([
    supabase.from('payroll_runs').select('id, period, branch_id, status, journal_entry_id, payment_journal_id').order('period', { ascending: false }),
    supabase.from('payroll_lines').select('run_id, gross, net_pay'),
    supabase.from('branches').select('id, name'),
  ]);
  if (error) throw new Error(`Failed to load payroll: ${error.message}`);
  const branchName = new Map((branches ?? []).map((b) => [b.id, b.name]));
  return (runs ?? []).map((r) => {
    const mine = (lines ?? []).filter((l) => l.run_id === r.id);
    return {
      id: r.id, period: r.period, branch: branchName.get(r.branch_id) ?? '', status: r.status,
      journalEntryId: r.journal_entry_id, paymentJournalId: r.payment_journal_id,
      gross: mine.reduce((s, l) => s + fromDb(l.gross), 0) as Paise,
      net: mine.reduce((s, l) => s + fromDb(l.net_pay), 0) as Paise,
      employees: mine.length,
    };
  });
}

export async function getPayrollLines(runId: string): Promise<PayrollLine[]> {
  await requirePermission('hr.payroll.run');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.from('payroll_lines')
    .select('id, gross, pf_employee, esi_employee, professional_tax, tds, other_deduction, net_pay, pf_employer, esi_employer, employees!inner ( name, employee_code )')
    .eq('run_id', runId);
  if (error) throw new Error(`Failed to load payroll lines: ${error.message}`);
  return (data ?? []).map((l) => ({
    id: l.id, employee: l.employees.name, code: l.employees.employee_code,
    gross: fromDb(l.gross), pf: fromDb(l.pf_employee), esi: fromDb(l.esi_employee), pt: fromDb(l.professional_tax),
    tds: fromDb(l.tds), other: fromDb(l.other_deduction), net: fromDb(l.net_pay),
    employerPf: fromDb(l.pf_employer), employerEsi: fromDb(l.esi_employer),
  })).sort((a, b) => a.employee.localeCompare(b.employee));
}

export async function createPayrollRun(period: string, branchId: string): Promise<Result> {
  await requirePermission('hr.payroll.run');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('create_payroll_run', { p_period: period, p_branch_id: branchId });
  if (error) {
    return { ok: false, error: error.message.includes('payroll_runs_period_key') ? 'That branch already has a payroll for this month.' : error.message };
  }
  return { ok: true, id: String(data), message: 'Draft payroll prepared from the salary structures.' };
}

export async function updatePayrollLine(lineId: string, tds: number, other: number): Promise<Result> {
  await requirePermission('hr.payroll.run');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.from('payroll_lines')
    .update({ tds: String(tds), other_deduction: String(other) }).eq('id', lineId);
  return error ? { ok: false, error: error.message } : { ok: true };
}

export async function postPayrollRun(runId: string): Promise<Result> {
  await requirePermission('hr.payroll.run');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('post_payroll_run', { p_run_id: runId });
  return error ? { ok: false, error: error.message } : { ok: true, message: 'Posted: salaries, employer cost and the statutory payables.' };
}

export async function payPayrollRun(runId: string, bankAccountId: string, date: string): Promise<Result> {
  await requirePermission('hr.payroll.run');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('pay_payroll_run', { p_run_id: runId, p_bank_account_id: bankAccountId, p_date: date });
  return error ? { ok: false, error: error.message } : { ok: true, message: 'Paid from the bank; the bank book shows it.' };
}
