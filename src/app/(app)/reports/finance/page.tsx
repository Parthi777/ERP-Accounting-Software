import type { Metadata } from 'next';

import { getFinanceSummary, type FinanceSummaryRow } from '@/server/services/reports/reports-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { ExportButtons } from '@/components/export/export-buttons';
import { add, formatINR, paise } from '@/lib/money';
import { monthRange } from '@/lib/period';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Finance report' };
export const dynamic = 'force-dynamic';

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ from?: string; to?: string }>;
}) {
  const context = await requirePermission('reports.finance.view');
  const params = await searchParams;
  const range = monthRange(params.from, params.to);

  const rows = await getFinanceSummary({ from: range.from, to: range.to });
  const showCommission = hasPermission(context, 'finance.commission.view');

  const columns: Column<FinanceSummaryRow>[] = [
    { key: 'company', header: 'Finance company', render: (row) => row.financeCompanyName },
    { key: 'applications', header: 'Applications', numeric: true, render: (row) => row.applications },
    {
      key: 'status',
      header: 'Approved / Pending / Rejected',
      render: (row) => (
        <span className="text-xs">
          <span className="text-positive-700">{row.approved}</span>
          {' / '}
          <span className="text-warning-700">{row.pending}</span>
          {' / '}
          <span className="text-danger-700">{row.rejected}</span>
        </span>
      ),
    },
    { key: 'loan', header: 'Loan amount', numeric: true, render: (row) => formatINR(row.loanAmount) },
    { key: 'disbursed', header: 'Disbursed', numeric: true, render: (row) => formatINR(row.disbursed) },
    {
      key: 'pendingDisbursement',
      header: 'Awaiting disbursement',
      numeric: true,
      render: (row) =>
        row.pendingDisbursement > 0 ? (
          <span className="font-medium text-warning-700">{formatINR(row.pendingDisbursement)}</span>
        ) : (
          <span className="text-positive-700">Clear</span>
        ),
    },
    ...(showCommission
      ? [{
          key: 'commission',
          header: 'Commission',
          numeric: true,
          render: (row: FinanceSummaryRow) =>
            row.financeCommission != null ? formatINR(row.financeCommission) : '—',
        }]
      : []),
  ];

  const loan = rows.reduce((sum, r) => add(sum, r.loanAmount), paise(0));
  const awaiting = rows.reduce((sum, r) => add(sum, r.pendingDisbursement), paise(0));

  return (
    <>
      <PageHeader
        title="Finance report"
        description={`Hire-purchase business by finance company, ${formatDate(range.from)} – ${formatDate(range.to)} (spec §41).`}
        count={rows.length}
        action={<ExportButtons report="finance-summary" />}
      />

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div>
            <label htmlFor="from" className="mb-1.5 block text-xs font-medium text-ink-600">From</label>
            <input id="from" name="from" type="date" defaultValue={range.from}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" />
          </div>
          <div>
            <label htmlFor="to" className="mb-1.5 block text-xs font-medium text-ink-600">To</label>
            <input id="to" name="to" type="date" defaultValue={range.to}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" />
          </div>
          <Button type="submit" variant="secondary" size="sm">Apply</Button>
        </form>
      </Panel>

      <div className="mb-4 grid gap-3 sm:grid-cols-2">
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Financed value</p>
          <p className="numeric mt-1 text-xl font-semibold text-ink-900">{formatINR(loan)}</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Awaiting disbursement</p>
          <p className={`numeric mt-1 text-xl font-semibold ${awaiting > 0 ? 'text-warning-700' : 'text-positive-700'}`}>
            {formatINR(awaiting)}
          </p>
        </Panel>
      </div>

      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.financeCompanyId}
        emptyMessage="No finance applications in this period."
        caption="Finance summary"
      />
    </>
  );
}
