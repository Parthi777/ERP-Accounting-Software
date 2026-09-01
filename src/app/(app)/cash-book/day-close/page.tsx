import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import {
  getCashDay,
  getCashDayHistory,
  type CashDayHistoryRow,
} from '@/server/services/cash/cash-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { DayCloseForm } from '@/components/cash/day-close-form';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatINR, paise } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Day close' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'info' | 'neutral' | 'warning'> = {
  OPEN: 'neutral',
  IN_PROGRESS: 'info',
  COUNTED: 'warning',
  CLOSED: 'positive',
};

const historyColumns: Column<CashDayHistoryRow>[] = [
  {
    key: 'date',
    header: 'Date',
    render: (row) => (
      <Link href={`/cash-book?date=${row.businessDate}`} className="text-brand-600 hover:underline">
        {formatDate(row.businessDate)}
      </Link>
    ),
  },
  { key: 'branch', header: 'Branch', render: (row) => row.branchName },
  { key: 'opening', header: 'Opening', numeric: true, render: (row) => formatINR(row.opening) },
  { key: 'receipts', header: 'Receipts', numeric: true, render: (row) => formatINR(row.receipts) },
  { key: 'payments', header: 'Payments', numeric: true, render: (row) => formatINR(row.payments) },
  { key: 'expected', header: 'Expected', numeric: true, render: (row) => formatINR(row.expected) },
  {
    key: 'counted',
    header: 'Counted',
    numeric: true,
    render: (row) => (row.counted != null ? formatINR(row.counted) : <span className="text-ink-300">—</span>),
  },
  {
    key: 'difference',
    header: 'Difference',
    numeric: true,
    render: (row) => {
      if (row.difference == null) return <span className="text-ink-300">—</span>;
      if (row.difference === 0) return <span className="text-positive-700">Tallied</span>;
      return (
        <span className="font-medium text-danger-700">
          {row.difference > 0 ? '+' : '−'}
          {formatINR(paise(Math.abs(row.difference)))}
        </span>
      );
    },
  },
  {
    key: 'status',
    header: 'Status',
    render: (row) => <Badge variant={STATUS_TONE[row.status] ?? 'neutral'}>{row.status.replace('_', ' ')}</Badge>,
  },
];

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ date?: string }>;
}) {
  const context = await requirePermission('cashbook.view');
  const params = await searchParams;
  const date = params.date ?? new Date().toISOString().slice(0, 10);

  const [day, history] = await Promise.all([getCashDay({ date }), getCashDayHistory()]);

  if (!day) {
    return (
      <>
        <PageHeader title="Day close" />
        <Panel className="p-6">
          <p className="text-sm text-ink-700">Select a branch to close its cash book.</p>
        </Panel>
      </>
    );
  }

  return (
    <>
      <PageHeader
        title="Day close"
        description="Counting the drawer against the book is mandatory each day (spec §36, §60.15)."
        action={
          <Button variant="secondary" size="sm" asChild>
            <Link href={`/cash-book?date=${date}`}>
              <ArrowLeft aria-hidden />
              Cash book
            </Link>
          </Button>
        }
      />

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div>
            <label htmlFor="date" className="mb-1.5 block text-xs font-medium text-ink-600">
              Business date
            </label>
            <input id="date" name="date" type="date" defaultValue={date}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" />
          </div>
          <Button type="submit" variant="secondary" size="sm">Show</Button>
        </form>
      </Panel>

      <div className="mb-6 max-w-3xl">
        <DayCloseForm
          businessDate={day.businessDate}
          branchName={day.branchName}
          expectedClosing={day.expectedClosing}
          status={day.status}
          physicalCash={day.physicalCash}
          difference={day.difference}
          remarks={day.remarks}
          canClose={hasPermission(context, 'cashbook.day_close')}
          canReopen={hasPermission(context, 'cashbook.day_reopen')}
        />
      </div>

      <h2 className="mb-3 text-sm font-semibold text-ink-900">Recent closings</h2>
      <DataTable
        columns={historyColumns}
        rows={history}
        getRowKey={(row) => `${row.businessDate}:${row.branchName}`}
        emptyMessage="No days have been closed yet."
        caption="Cash closing history"
      />
    </>
  );
}
