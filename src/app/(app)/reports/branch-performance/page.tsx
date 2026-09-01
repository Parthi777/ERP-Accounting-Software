import type { Metadata } from 'next';

import {
  getBranchPerformance,
  type BranchPerformanceRow,
} from '@/server/services/reports/reports-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { ExportButtons } from '@/components/export/export-buttons';
import { add, formatINR, paise } from '@/lib/money';
import { monthRange } from '@/lib/period';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Branch performance' };
export const dynamic = 'force-dynamic';

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ from?: string; to?: string }>;
}) {
  const context = await requirePermission('reports.branch_performance.view');
  const params = await searchParams;
  const range = monthRange(params.from, params.to);

  const rows = await getBranchPerformance({ from: range.from, to: range.to });
  const showMargin = hasPermission(context, 'reports.margin.view');

  const columns: Column<BranchPerformanceRow>[] = [
    {
      key: 'branch',
      header: 'Branch',
      render: (row) => (
        <span>
          <span className="block font-medium">{row.branchName}</span>
          <span className="block font-mono text-[11px] text-ink-400">{row.branchCode}</span>
        </span>
      ),
    },
    { key: 'units', header: 'Vehicles', numeric: true, render: (row) => row.vehicleUnits },
    { key: 'vehicleRevenue', header: 'Vehicle revenue', numeric: true, render: (row) => formatINR(row.vehicleRevenue) },
    ...(showMargin
      ? [{
          key: 'margin',
          header: 'Vehicle margin',
          numeric: true,
          render: (row: BranchPerformanceRow) =>
            row.margin != null ? (
              <span className={row.margin < 0 ? 'font-medium text-danger-700' : 'font-medium text-positive-700'}>
                {formatINR(row.margin)}
              </span>
            ) : (
              '—'
            ),
        }]
      : []),
    { key: 'jobs', header: 'Service jobs', numeric: true, render: (row) => row.serviceJobs },
    { key: 'serviceRevenue', header: 'Service revenue', numeric: true, render: (row) => formatINR(row.serviceRevenue) },
    { key: 'bookings', header: 'Open bookings', numeric: true, render: (row) => row.bookingsOpen },
    { key: 'advances', header: 'Advances held', numeric: true, render: (row) => formatINR(row.bookingAdvances) },
    { key: 'cash', header: 'Cash in hand', numeric: true, render: (row) => formatINR(row.cashInHand) },
    {
      key: 'receivables',
      header: 'Receivables',
      numeric: true,
      render: (row) =>
        row.receivables > 0 ? (
          <span className="font-medium text-warning-700">{formatINR(row.receivables)}</span>
        ) : (
          <span className="text-positive-700">Clear</span>
        ),
    },
  ];

  const revenue = rows.reduce((sum, r) => add(sum, add(r.vehicleRevenue, r.serviceRevenue)), paise(0));
  const receivables = rows.reduce((sum, r) => add(sum, r.receivables), paise(0));
  const cash = rows.reduce((sum, r) => add(sum, r.cashInHand), paise(0));

  return (
    <>
      <PageHeader
        title="Branch performance"
        description={`Every branch side by side, ${formatDate(range.from)} – ${formatDate(range.to)} (spec §43).`}
        count={rows.length}
        action={<ExportButtons report="branch-performance" />}
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

      <div className="mb-4 grid gap-3 sm:grid-cols-3">
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Revenue across branches</p>
          <p className="numeric mt-1 text-xl font-semibold text-ink-900">{formatINR(revenue)}</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Cash in hand</p>
          <p className="numeric mt-1 text-xl font-semibold text-ink-900">{formatINR(cash)}</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Receivables</p>
          <p className={`numeric mt-1 text-xl font-semibold ${receivables > 0 ? 'text-warning-700' : 'text-positive-700'}`}>
            {formatINR(receivables)}
          </p>
        </Panel>
      </div>

      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.branchId}
        emptyMessage="No active branches."
        caption="Branch performance"
      />
    </>
  );
}
