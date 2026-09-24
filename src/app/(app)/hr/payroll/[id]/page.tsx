import Link from 'next/link';
import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { ArrowLeft } from 'lucide-react';

import { getPayrollLines, getPayrollRuns } from '@/server/services/payroll/payroll-service';
import { payPayrollRunAction, postPayrollRunAction, updatePayrollLineAction } from '@/server/services/payroll/payroll-actions';
import { getBankAccounts } from '@/server/services/bank/bank-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel, PanelContent, PanelHeader, PanelTitle, SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { ActionForm } from '@/components/forms/action-form';
import { add, formatINR, ZERO, type Paise } from '@/lib/money';

export const metadata: Metadata = { title: 'Payroll run' };
export const dynamic = 'force-dynamic';

export default async function PayrollRunPage({ params }: { params: Promise<{ id: string }> }) {
  await requirePermission('hr.payroll.run');
  const { id } = await params;
  const run = (await getPayrollRuns()).find((r) => r.id === id);
  if (!run) notFound();
  const [lines, banks] = await Promise.all([getPayrollLines(id), getBankAccounts()]);
  const draft = run.status === 'DRAFT';
  const sum = (k: 'gross' | 'pf' | 'esi' | 'pt' | 'tds' | 'other' | 'net') => lines.reduce<Paise>((s, l) => add(s, l[k]), ZERO);
  const th = 'px-3 py-2.5 text-[11px] font-semibold uppercase tracking-wide text-ink-500';
  const month = new Date(run.period).toLocaleDateString('en-IN', { month: 'long', year: 'numeric' });

  return (
    <div className="space-y-5">
      <Button variant="ghost" size="sm" asChild className="-ml-2"><Link href="/hr/payroll"><ArrowLeft aria-hidden />Payroll</Link></Button>
      <PageHeader title={`Payroll · ${month}`} description={`${run.branch} · ${lines.length} employees`}
        action={<Badge variant={run.status === 'PAID' ? 'positive' : run.status === 'POSTED' ? 'info' : 'warning'}>{run.status}</Badge>} />

      <SolidPanel className="overflow-auto">
        <table className="w-full border-collapse text-sm">
          <thead><tr>
            <th className={`${th} text-left`}>Employee</th><th className={`${th} text-right`}>Gross</th>
            <th className={`${th} text-right`}>PF</th><th className={`${th} text-right`}>ESI</th>
            <th className={`${th} text-right`}>PT</th><th className={`${th} text-right`}>TDS</th>
            <th className={`${th} text-right`}>Other</th><th className={`${th} text-right`}>Net pay</th>
          </tr></thead>
          <tbody>
            {lines.map((l) => (
              <tr key={l.id} className="border-t border-ink-100 align-top">
                <td className="px-3 py-2">
                  <span className="font-semibold text-ink-900">{l.employee}</span>
                  <span className="block text-[11px] text-ink-500">{l.code} · employer PF {formatINR(l.employerPf)}, ESI {formatINR(l.employerEsi)}</span>
                  {draft && (
                    <details className="mt-1"><summary className="cursor-pointer text-xs font-semibold text-brand-700">TDS / other deductions…</summary>
                      <div className="mt-2 max-w-md">
                        <ActionForm action={updatePayrollLineAction} submitLabel="Save" columns={2} resetOnSuccess={false} fixed={{ lineId: l.id }} fields={[
                          { name: 'tds', label: 'TDS (₹)', type: 'number', defaultValue: String(l.tds / 100) },
                          { name: 'other', label: 'Other (₹)', type: 'number', defaultValue: String(l.other / 100), hint: 'An advance recovered goes back against Other Receivables.' },
                        ]} />
                      </div>
                    </details>
                  )}
                </td>
                <td className="numeric px-3 py-2">{formatINR(l.gross)}</td>
                <td className="numeric px-3 py-2">{formatINR(l.pf)}</td>
                <td className="numeric px-3 py-2">{formatINR(l.esi)}</td>
                <td className="numeric px-3 py-2">{formatINR(l.pt)}</td>
                <td className="numeric px-3 py-2">{formatINR(l.tds)}</td>
                <td className="numeric px-3 py-2">{formatINR(l.other)}</td>
                <td className="numeric px-3 py-2 font-semibold">{formatINR(l.net)}</td>
              </tr>
            ))}
          </tbody>
          <tfoot><tr className="border-t-2 border-ink-300 bg-ink-50 font-semibold">
            <td className="px-3 py-3">Total</td>
            {(['gross', 'pf', 'esi', 'pt', 'tds', 'other', 'net'] as const).map((k) => (
              <td key={k} className="numeric px-3 py-3">{formatINR(sum(k))}</td>
            ))}
          </tr></tfoot>
        </table>
      </SolidPanel>

      <div className="grid gap-5 lg:grid-cols-2">
        {draft && (
          <Panel>
            <PanelHeader><PanelTitle>Post to the ledger</PanelTitle></PanelHeader>
            <PanelContent>
              <p className="mb-3 text-sm text-ink-600">Salaries and employer PF/ESI are charged; net pay is owed to each employee, and PF, ESI, TDS and professional tax to the government. The run then locks.</p>
              <ActionForm action={postPayrollRunAction} submitLabel="Post payroll" fixed={{ runId: run.id }} fields={[]}
                confirm="Post this payroll? It cannot be edited afterwards." />
            </PanelContent>
          </Panel>
        )}
        {run.status === 'POSTED' && (
          <Panel>
            <PanelHeader><PanelTitle>Pay net salaries</PanelTitle></PanelHeader>
            <PanelContent>
              <ActionForm action={payPayrollRunAction} submitLabel="Pay from bank" columns={2} fixed={{ runId: run.id }}
                confirm="Record the salary payment from this bank account?" fields={[
                  { name: 'bankAccountId', label: 'Bank account', type: 'select', required: true,
                    options: banks.map((b) => ({ value: b.id, label: `${b.name} · ${b.accountNumber}` })) },
                  { name: 'date', label: 'Paid on', type: 'date', required: true, defaultValue: new Date().toISOString().slice(0, 10) },
                ]} />
            </PanelContent>
          </Panel>
        )}
        {run.journalEntryId && (
          <Panel className="p-4 text-sm">
            <Link href={`/accounting/journals/${run.journalEntryId}`} className="font-semibold text-brand-700 hover:underline">Payroll journal →</Link>
            {run.paymentJournalId && (
              <Link href={`/accounting/journals/${run.paymentJournalId}`} className="ml-4 font-semibold text-brand-700 hover:underline">Payment journal →</Link>
            )}
          </Panel>
        )}
      </div>
    </div>
  );
}
