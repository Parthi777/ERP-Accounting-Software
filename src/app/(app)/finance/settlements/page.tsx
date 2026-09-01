import type { Metadata } from 'next';
import Link from 'next/link';

import {
  getFinanceSettlements,
  getFinancePickers,
  type SettlementRow,
} from '@/server/services/finance/finance-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { SettlementForm, SettlementPostAction } from '@/components/finance/settlement-actions';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { ExportButtons } from '@/components/export/export-buttons';
import { formatINR } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Finance settlements' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'neutral' | 'warning' | 'danger'> = {
  DRAFT: 'warning',
  POSTED: 'positive',
  CANCELLED: 'danger',
};

const VIEWS = [
  { value: 'DRAFT', label: 'Drafts' },
  { value: 'POSTED', label: 'Posted' },
  { value: 'ALL', label: 'All' },
];

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ view?: string }>;
}) {
  const context = await requirePermission('finance.settlements.manage');
  const params = await searchParams;
  const view = params.view && ['DRAFT', 'POSTED', 'ALL'].includes(params.view) ? params.view : 'DRAFT';

  const showCommission = hasPermission(context, 'finance.commission.view');

  const [rows, pickers] = await Promise.all([
    getFinanceSettlements(view),
    getFinancePickers(),
  ]);

  const columns: Column<SettlementRow>[] = [
    {
      key: 'number',
      header: 'Settlement',
      render: (row) => (
        <span>
          <span className="block font-mono text-xs text-ink-700">{row.settlementNumber}</span>
          <span className="block text-[11px] text-ink-400">{formatDate(row.settlementDate)}</span>
        </span>
      ),
    },
    { key: 'company', header: 'Company', render: (row) => row.companyName },
    {
      key: 'period',
      header: 'Period',
      render: (row) =>
        row.fromDate && row.toDate ? (
          <span className="text-xs text-ink-600">
            {formatDate(row.fromDate)} – {formatDate(row.toDate)}
          </span>
        ) : (
          <span className="text-ink-300">—</span>
        ),
    },
    { key: 'gross', header: 'Gross', numeric: true, render: (row) => formatINR(row.grossAmount) },
    ...(showCommission
      ? ([
          {
            key: 'commission',
            header: 'Commission',
            numeric: true,
            render: (row: SettlementRow) =>
              row.commissionAmount === null ? '—' : formatINR(row.commissionAmount),
          },
        ] as Column<SettlementRow>[])
      : []),
    {
      key: 'deductions',
      header: 'Deductions',
      numeric: true,
      render: (row) => (row.deductions > 0 ? formatINR(row.deductions) : <span className="text-ink-300">—</span>),
    },
    {
      key: 'net',
      header: 'Net',
      numeric: true,
      render: (row) => <span className="font-medium text-ink-800">{formatINR(row.netAmount)}</span>,
    },
    {
      key: 'status',
      header: 'Status',
      render: (row) => (
        <span className="flex items-center gap-2">
          <Badge variant={STATUS_TONE[row.status] ?? 'neutral'}>{row.status}</Badge>
          {row.journalEntryId && (
            <Link
              href={`/accounting/journals/${row.journalEntryId}`}
              className="text-[11px] text-brand-600 hover:underline"
            >
              Journal
            </Link>
          )}
        </span>
      ),
    },
    {
      key: 'actions',
      header: '',
      render: (row) =>
        row.status === 'DRAFT' ? (
          <SettlementPostAction
            settlementId={row.id}
            settlementNumber={row.settlementNumber}
            netLabel={formatINR(row.netAmount)}
            bankAccounts={pickers.bankAccounts}
          />
        ) : null,
    },
  ];

  return (
    <>
      <PageHeader
        title="Finance settlements"
        description="What a finance company has paid against financed vehicles, and what it withheld (spec §26)."
        count={rows.length}
        action={<ExportButtons report="finance-settlements" />}
      />

      <div className="mb-4">
        <SettlementForm companies={pickers.companies} />
      </div>

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div>
            <label htmlFor="view" className="mb-1.5 block text-xs font-medium text-ink-600">Showing</label>
            <select
              id="view" name="view" defaultValue={view}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            >
              {VIEWS.map((v) => <option key={v.value} value={v.value}>{v.label}</option>)}
            </select>
          </div>
          <Button type="submit" variant="secondary" size="sm">Filter</Button>
        </form>
      </Panel>

      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.id}
        emptyMessage={view === 'DRAFT' ? 'No settlements are waiting to be posted.' : 'No settlements match this filter.'}
        caption="Finance settlements"
      />
    </>
  );
}
