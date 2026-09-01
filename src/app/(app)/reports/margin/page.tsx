import type { Metadata } from 'next';

import { getMarginReport, type MarginRow } from '@/server/services/reports/reports-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { add, formatINR, paise, percentageOf } from '@/lib/money';
import { monthRange } from '@/lib/period';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Margin report' };
export const dynamic = 'force-dynamic';

const columns: Column<MarginRow>[] = [
  { key: 'stream', header: 'Stream', render: (row) => <span className="font-medium">{row.stream}</span> },
  { key: 'documents', header: 'Documents', numeric: true, render: (row) => row.documents },
  { key: 'revenue', header: 'Revenue', numeric: true, render: (row) => formatINR(row.revenue) },
  { key: 'cost', header: 'Cost', numeric: true, render: (row) => formatINR(row.cost) },
  {
    key: 'margin',
    header: 'Margin',
    numeric: true,
    render: (row) => (
      <span className={row.margin < 0 ? 'font-medium text-danger-700' : 'font-medium text-positive-700'}>
        {formatINR(row.margin)}
      </span>
    ),
  },
  {
    key: 'percent',
    header: 'Margin %',
    numeric: true,
    render: (row) => (
      <span className={row.marginPercent < 0 ? 'text-danger-700' : 'text-ink-700'}>
        {row.marginPercent.toFixed(2)}%
      </span>
    ),
  },
];

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ from?: string; to?: string }>;
}) {
  // This page exists only for roles holding reports.margin.view (spec §41, §52).
  await requirePermission('reports.margin.view');
  const params = await searchParams;
  const range = monthRange(params.from, params.to);

  const rows = await getMarginReport({ from: range.from, to: range.to });

  const revenue = rows.reduce((sum, r) => add(sum, r.revenue), paise(0));
  const cost = rows.reduce((sum, r) => add(sum, r.cost), paise(0));
  const margin = rows.reduce((sum, r) => add(sum, r.margin), paise(0));
  const overall = percentageOf(margin, revenue);

  return (
    <>
      <PageHeader
        title="Margin report"
        description={`Where the money is actually made, ${formatDate(range.from)} – ${formatDate(range.to)} (spec §41).`}
        count={rows.length}
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

      <div className="mb-4 grid gap-3 sm:grid-cols-4">
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Revenue</p>
          <p className="numeric mt-1 text-xl font-semibold text-ink-900">{formatINR(revenue)}</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Cost</p>
          <p className="numeric mt-1 text-xl font-semibold text-ink-900">{formatINR(cost)}</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Margin</p>
          <p className={`numeric mt-1 text-xl font-semibold ${margin < 0 ? 'text-danger-700' : 'text-positive-700'}`}>
            {formatINR(margin)}
          </p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Margin %</p>
          <p className="numeric mt-1 text-xl font-semibold text-ink-900">
            {overall != null ? `${overall.toFixed(2)}%` : '—'}
          </p>
        </Panel>
      </div>

      <p className="mb-3 text-xs text-ink-500">
        Vehicle margin is invoice value less what that specific chassis cost. Service margin is billed
        value less the cost of the parts actually consumed. Finance commission carries no cost of its own.
      </p>

      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.stream}
        emptyMessage="No business posted in this period."
        caption="Margin by stream"
      />
    </>
  );
}
