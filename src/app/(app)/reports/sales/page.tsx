import type { Metadata } from 'next';

import { getSalesSummary, type SalesSummaryRow } from '@/server/services/reports/reports-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { ExportButtons } from '@/components/export/export-buttons';
import { add, formatINR, paise } from '@/lib/money';
import { monthRange } from '@/lib/period';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Sales report' };
export const dynamic = 'force-dynamic';

const GROUPINGS = [
  { value: 'MODEL', label: 'By model' },
  { value: 'BRANCH', label: 'By branch' },
  { value: 'EMPLOYEE', label: 'By sales executive' },
  { value: 'DAY', label: 'By day' },
];

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ from?: string; to?: string; group?: string }>;
}) {
  const context = await requirePermission('reports.sales.view');
  const params = await searchParams;
  const range = monthRange(params.from, params.to);
  const groupBy = params.group ?? 'MODEL';

  const rows = await getSalesSummary({ from: range.from, to: range.to, groupBy });
  const showMargin = hasPermission(context, 'reports.margin.view');

  const columns: Column<SalesSummaryRow>[] = [
    { key: 'label', header: GROUPINGS.find((g) => g.value === groupBy)?.label.replace('By ', '') ?? 'Group', render: (row) => row.groupLabel },
    { key: 'units', header: 'Units', numeric: true, render: (row) => row.units },
    { key: 'gross', header: 'Gross', numeric: true, render: (row) => formatINR(row.gross) },
    { key: 'tax', header: 'Tax', numeric: true, render: (row) => formatINR(row.tax) },
    ...(showMargin
      ? [
          {
            key: 'cost',
            header: 'Cost',
            numeric: true,
            render: (row: SalesSummaryRow) => (row.cost != null ? formatINR(row.cost) : '—'),
          },
          {
            key: 'margin',
            header: 'Margin',
            numeric: true,
            render: (row: SalesSummaryRow) =>
              row.margin != null ? (
                <span className={row.margin < 0 ? 'font-medium text-danger-700' : 'font-medium text-positive-700'}>
                  {formatINR(row.margin)}
                </span>
              ) : (
                '—'
              ),
          },
        ]
      : []),
  ];

  const units = rows.reduce((n, r) => n + r.units, 0);
  const gross = rows.reduce((sum, r) => add(sum, r.gross), paise(0));

  return (
    <>
      <PageHeader
        title="Sales report"
        description={`Posted and delivered invoices, ${formatDate(range.from)} – ${formatDate(range.to)} (spec §41).`}
        count={rows.length}
        action={
          <div className="flex flex-wrap items-end gap-4">
            <div>
              <p className="mb-1 text-[11px] font-medium uppercase tracking-wide text-ink-400">
                Sales summary
              </p>
              <ExportButtons report="sales-summary" />
            </div>
            <div>
              <p className="mb-1 text-[11px] font-medium uppercase tracking-wide text-ink-400">
                Delivery register
              </p>
              <ExportButtons report="deliveries" />
            </div>
          </div>
        }
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
          <div>
            <label htmlFor="group" className="mb-1.5 block text-xs font-medium text-ink-600">Group by</label>
            <select id="group" name="group" defaultValue={groupBy}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
              {GROUPINGS.map((g) => <option key={g.value} value={g.value}>{g.label}</option>)}
            </select>
          </div>
          <Button type="submit" variant="secondary" size="sm">Apply</Button>
        </form>
      </Panel>

      <div className="mb-4 grid gap-3 sm:grid-cols-2">
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Units sold</p>
          <p className="numeric mt-1 text-xl font-semibold text-ink-900">{units}</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Gross value</p>
          <p className="numeric mt-1 text-xl font-semibold text-ink-900">{formatINR(gross)}</p>
        </Panel>
      </div>

      {!showMargin && (
        <p className="mb-3 text-xs text-ink-500">
          Cost and margin are withheld from this response — they need the margin permission (spec §52).
        </p>
      )}

      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.groupKey}
        emptyMessage="No sales posted in this period."
        caption="Sales summary"
      />
    </>
  );
}
