import Link from 'next/link';
import type { Metadata } from 'next';

import { getLoans, getSchedule } from '@/server/services/loans/loan-service';
import { createLoanAction, loanTransactionAction } from '@/server/services/loans/loan-actions';
import { getBankAccounts } from '@/server/services/bank/bank-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel, PanelContent, PanelHeader, PanelTitle, SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { ActionForm } from '@/components/forms/action-form';
import { formatINR } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Loans' };
export const dynamic = 'force-dynamic';

/**
 * Loans — checklist §02 "loans and interest" (0082). A repayment is always
 * split: principal reduces the liability, interest is an expense.
 */
export default async function LoansPage({ searchParams }: { searchParams: Promise<{ loan?: string }> }) {
  const context = await requireTenantContext();
  const params = await searchParams;
  const canManage = context.permissions.has('loans.manage');
  const today = new Date().toISOString().slice(0, 10);
  const [loans, banks] = await Promise.all([getLoans(), canManage ? getBankAccounts() : Promise.resolve([])]);
  const selected = loans.find((l) => l.id === params.loan) ?? loans[0] ?? null;
  const schedule = selected ? await getSchedule(selected.id) : [];
  const th = 'px-4 py-2.5 text-[11px] font-semibold uppercase tracking-wide text-ink-500';

  return (
    <div className="space-y-5">
      <PageHeader title="Loans" description="Borrowings, what has been drawn, and every instalment split into principal and interest." count={loans.length} />

      {canManage && (
        <div className="grid gap-5 lg:grid-cols-2">
          <Panel>
            <PanelHeader><PanelTitle>New loan</PanelTitle></PanelHeader>
            <PanelContent>
              <ActionForm action={createLoanAction} submitLabel="Record loan" columns={2} fields={[
                { name: 'lender', label: 'Lender', required: true, placeholder: 'Canara Bank term loan' },
                { name: 'principal', label: 'Sanctioned (₹)', type: 'number', required: true },
                { name: 'rate', label: 'Interest % a year', type: 'number', required: true },
                { name: 'tenure', label: 'Tenure (months)', type: 'number', step: '1', required: true },
                { name: 'startDate', label: 'Starts', type: 'date', required: true, defaultValue: today },
              ]} />
            </PanelContent>
          </Panel>
          {loans.length > 0 && (
            <Panel>
              <PanelHeader><PanelTitle>Money in or out</PanelTitle></PanelHeader>
              <PanelContent>
                <ActionForm action={loanTransactionAction} submitLabel="Record" columns={2} fields={[
                  { name: 'loanId', label: 'Loan', type: 'select', required: true, defaultValue: selected?.id,
                    options: loans.filter((l) => l.status === 'ACTIVE').map((l) => ({ value: l.id, label: `${l.number} ${l.lender}` })) },
                  { name: 'kind', label: 'What', type: 'select', required: true, defaultValue: 'REPAYMENT',
                    options: [{ value: 'DISBURSEMENT', label: 'Loan received' }, { value: 'REPAYMENT', label: 'Instalment paid' }] },
                  { name: 'bankAccountId', label: 'Bank account', type: 'select', required: true,
                    options: banks.map((b) => ({ value: b.id, label: `${b.name} · ${b.accountNumber}` })) },
                  { name: 'date', label: 'Date', type: 'date', required: true, defaultValue: today },
                  { name: 'principal', label: 'Principal (₹)', type: 'number' },
                  { name: 'interest', label: 'Interest (₹)', type: 'number', hint: 'Instalments only: interest goes to 5960, never to the loan.' },
                ]} />
              </PanelContent>
            </Panel>
          )}
        </div>
      )}

      <SolidPanel className="overflow-hidden">
        <table className="w-full border-collapse text-sm">
          <thead><tr>
            <th className={`${th} text-left`}>Loan</th><th className={`${th} text-right`}>Sanctioned</th>
            <th className={`${th} text-right`}>Drawn</th><th className={`${th} text-right`}>Principal repaid</th>
            <th className={`${th} text-right`}>Interest paid</th><th className={`${th} text-right`}>Outstanding</th>
            <th className={`${th} text-left`}>Status</th>
          </tr></thead>
          <tbody>
            {loans.length === 0 ? (
              <tr><td colSpan={7} className="px-4 py-12 text-center text-ink-400">No loans recorded.</td></tr>
            ) : loans.map((l) => (
              <tr key={l.id} className="border-t border-ink-100">
                <td className="px-4 py-2">
                  <Link href={`/accounting/loans?loan=${l.id}`} className="font-semibold text-brand-700 hover:underline">{l.number}</Link>
                  <span className="block text-[11px] text-ink-500">{l.lender} · {l.rate}% · {l.tenure} months from {formatDate(l.startDate)}</span>
                </td>
                <td className="numeric px-4 py-2">{formatINR(l.principal)}</td>
                <td className="numeric px-4 py-2">{formatINR(l.disbursed)}</td>
                <td className="numeric px-4 py-2">{formatINR(l.repaid)}</td>
                <td className="numeric px-4 py-2">{formatINR(l.interestPaid)}</td>
                <td className="numeric px-4 py-2 font-semibold">{formatINR(l.outstanding)}</td>
                <td className="px-4 py-2"><Badge variant={l.status === 'ACTIVE' ? 'info' : 'neutral'}>{l.status}</Badge></td>
              </tr>
            ))}
          </tbody>
        </table>
      </SolidPanel>

      {selected && schedule.length > 0 && (
        <SolidPanel className="overflow-hidden">
          <div className="px-4 pt-4 text-sm font-semibold text-ink-900">Repayment schedule — {selected.number} (reducing balance)</div>
          <div className="table-sticky overflow-auto" style={{ maxHeight: '26rem' }}>
            <table className="w-full border-collapse text-sm">
              <thead><tr>
                <th className={`${th} text-left`}>#</th><th className={`${th} text-left`}>Due</th>
                <th className={`${th} text-right`}>EMI</th><th className={`${th} text-right`}>Principal</th>
                <th className={`${th} text-right`}>Interest</th><th className={`${th} text-right`}>Balance</th>
              </tr></thead>
              <tbody>
                {schedule.map((s) => (
                  <tr key={s.instalment} className="border-t border-ink-100">
                    <td className="px-4 py-1.5">{s.instalment}</td><td className="px-4 py-1.5 text-ink-600">{formatDate(s.dueDate)}</td>
                    <td className="numeric px-4 py-1.5">{s.emi.toLocaleString('en-IN', { minimumFractionDigits: 2 })}</td>
                    <td className="numeric px-4 py-1.5">{s.principal.toLocaleString('en-IN', { minimumFractionDigits: 2 })}</td>
                    <td className="numeric px-4 py-1.5">{s.interest.toLocaleString('en-IN', { minimumFractionDigits: 2 })}</td>
                    <td className="numeric px-4 py-1.5">{s.balance.toLocaleString('en-IN', { minimumFractionDigits: 2 })}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </SolidPanel>
      )}
    </div>
  );
}
