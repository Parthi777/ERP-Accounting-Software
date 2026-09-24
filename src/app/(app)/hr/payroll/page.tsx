import Link from 'next/link';
import type { Metadata } from 'next';

import { getPayrollRuns } from '@/server/services/payroll/payroll-service';
import { createPayrollRunAction } from '@/server/services/payroll/payroll-actions';
import { requirePermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel, PanelContent, PanelHeader, PanelTitle, SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { ActionForm } from '@/components/forms/action-form';
import { formatINR } from '@/lib/money';

export const metadata: Metadata = { title: 'Payroll' };
export const dynamic = 'force-dynamic';

/** Monthly payroll — checklist §02 "payroll" (0082). */
export default async function PayrollPage() {
  const context = await requirePermission('hr.payroll.run');
  const runs = await getPayrollRuns();
  const th = 'px-4 py-2.5 text-[11px] font-semibold uppercase tracking-wide text-ink-500';

  return (
    <div className="space-y-5">
      <PageHeader title="Payroll" description="Prepare the month from salary structures, review, post, then pay from the bank." count={runs.length} />
      <Panel>
        <PanelHeader><PanelTitle>Prepare a month</PanelTitle></PanelHeader>
        <PanelContent>
          <ActionForm action={createPayrollRunAction} submitLabel="Prepare draft" columns={3} fields={[
            { name: 'month', label: 'Month', type: 'month', required: true, defaultValue: new Date().toISOString().slice(0, 7) },
            { name: 'branchId', label: 'Branch', type: 'select', required: true, defaultValue: context.activeBranch?.id,
              options: context.accessibleBranches.map((b) => ({ value: b.id, label: b.name })) },
          ]} />
        </PanelContent>
      </Panel>
      <SolidPanel className="overflow-hidden">
        <table className="w-full border-collapse text-sm">
          <thead><tr>
            <th className={`${th} text-left`}>Month</th><th className={`${th} text-left`}>Branch</th>
            <th className={`${th} text-right`}>Employees</th><th className={`${th} text-right`}>Gross</th>
            <th className={`${th} text-right`}>Net pay</th><th className={`${th} text-left`}>Status</th>
          </tr></thead>
          <tbody>
            {runs.length === 0 ? (
              <tr><td colSpan={6} className="px-4 py-12 text-center text-ink-400">No payroll prepared yet.</td></tr>
            ) : runs.map((r) => (
              <tr key={r.id} className="border-t border-ink-100">
                <td className="px-4 py-2"><Link href={`/hr/payroll/${r.id}`} className="font-semibold text-brand-700 hover:underline">
                  {new Date(r.period).toLocaleDateString('en-IN', { month: 'long', year: 'numeric' })}</Link></td>
                <td className="px-4 py-2 text-ink-600">{r.branch}</td>
                <td className="numeric px-4 py-2">{r.employees}</td>
                <td className="numeric px-4 py-2">{formatINR(r.gross)}</td>
                <td className="numeric px-4 py-2 font-semibold">{formatINR(r.net)}</td>
                <td className="px-4 py-2"><Badge variant={r.status === 'PAID' ? 'positive' : r.status === 'POSTED' ? 'info' : 'warning'}>{r.status}</Badge></td>
              </tr>
            ))}
          </tbody>
        </table>
      </SolidPanel>
    </div>
  );
}
