import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowDownLeft, ArrowUpRight, Lock } from 'lucide-react';

import { getCashDay, type CashEntry } from '@/server/services/cash/cash-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatINR, paise } from '@/lib/money';
import { formatDate, formatTime } from '@/lib/format';

export const metadata: Metadata = { title: 'Cash book' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'info' | 'neutral' | 'warning'> = {
  OPEN: 'neutral',
  IN_PROGRESS: 'info',
  COUNTED: 'warning',
  CLOSED: 'positive',
};

const columns: Column<CashEntry>[] = [
  { key: 'time', header: 'Time', render: (row) => formatTime(row.time) },
  {
    key: 'reference',
    header: 'Reference',
    render: (row) =>
      row.reference ? <span className="font-mono text-xs text-ink-600">{row.reference}</span> : <span className="text-ink-300">—</span>,
  },
  { key: 'particular', header: 'Particulars', render: (row) => row.particular },
  {
    key: 'receipt',
    header: 'Receipt',
    numeric: true,
    render: (row) => (row.receipt > 0 ? <span className="text-positive-700">{formatINR(row.receipt)}</span> : <span className="text-ink-300">—</span>),
  },
  {
    key: 'payment',
    header: 'Payment',
    numeric: true,
    render: (row) => (row.payment > 0 ? <span className="text-danger-700">{formatINR(row.payment)}</span> : <span className="text-ink-300">—</span>),
  },
  {
    key: 'balance',
    header: 'Balance',
    numeric: true,
    render: (row) => <span className="font-medium">{formatINR(row.balance)}</span>,
  },
  {
    key: 'journal',
    header: '',
    render: (row) =>
      row.journalEntryId ? (
        <Link href={`/accounting/journals/${row.journalEntryId}`} className="text-xs text-brand-600 hover:underline">
          Journal
        </Link>
      ) : null,
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

  const day = await getCashDay({ date });

  if (!day) {
    return (
      <>
        <PageHeader title="Cash book" description="Daily cash book per branch (spec §36, §37)." />
        <Panel className="p-6">
          <p className="text-sm text-ink-700">Select a branch to view its cash book.</p>
        </Panel>
      </>
    );
  }

  const canReceive = hasPermission(context, 'cashbook.receipts.create');
  const canPay = hasPermission(context, 'cashbook.payments.create');
  const canClose = hasPermission(context, 'cashbook.day_close');
  const locked = day.status === 'CLOSED';

  const summary = [
    { label: 'Opening balance', value: day.opening, tone: 'neutral' as const },
    { label: 'Receipts', value: day.receipts, tone: 'positive' as const },
    { label: 'Payments', value: day.payments, tone: 'danger' as const },
    { label: 'Expected closing', value: day.expectedClosing, tone: 'brand' as const },
  ];

  return (
    <>
      <PageHeader
        title="Cash book"
        description={`${day.branchName}${day.accountName ? ` · ${day.accountName}` : ''} · ${formatDate(day.businessDate)}`}
        count={day.entries.length}
        action={
          <div className="flex flex-wrap items-center gap-2">
            {canReceive && !locked && (
              <Button size="sm" asChild>
                <Link href={`/cash-book/receipts?date=${date}`}>
                  <ArrowDownLeft aria-hidden />
                  Receipt
                </Link>
              </Button>
            )}
            {canPay && !locked && (
              <Button variant="secondary" size="sm" asChild>
                <Link href={`/cash-book/payments?date=${date}`}>
                  <ArrowUpRight aria-hidden />
                  Payment
                </Link>
              </Button>
            )}
            {canClose && (
              <Button variant="secondary" size="sm" asChild>
                <Link href={`/cash-book/day-close?date=${date}`}>
                  <Lock aria-hidden />
                  {locked ? 'View close' : 'Close day'}
                </Link>
              </Button>
            )}
          </div>
        }
      />

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div>
            <label htmlFor="date" className="mb-1.5 block text-xs font-medium text-ink-600">
              Business date
            </label>
            <input
              id="date"
              name="date"
              type="date"
              defaultValue={date}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            />
          </div>
          <Button type="submit" variant="secondary" size="sm">Show</Button>
          <div className="ml-auto flex items-center gap-2">
            <Badge variant={STATUS_TONE[day.status] ?? 'neutral'}>{day.status.replace('_', ' ')}</Badge>
            {locked && day.closedAt && (
              <span className="text-xs text-ink-500">Closed {formatDate(day.closedAt)}</span>
            )}
          </div>
        </form>
      </Panel>

      <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {summary.map((item) => (
          <Panel key={item.label} className="p-4">
            <p className="text-xs text-ink-500">{item.label}</p>
            <p
              className={`numeric mt-1 text-xl font-semibold ${
                item.tone === 'positive'
                  ? 'text-positive-700'
                  : item.tone === 'danger'
                    ? 'text-danger-700'
                    : item.tone === 'brand'
                      ? 'text-brand-700'
                      : 'text-ink-900'
              }`}
            >
              {formatINR(item.value)}
            </p>
          </Panel>
        ))}
      </div>

      {day.status === 'CLOSED' && day.difference != null && day.difference !== 0 && (
        <Panel className="mb-4 border-warning-200 bg-warning-50 p-4">
          <p className="text-sm font-medium text-warning-900">
            This day closed with a {day.difference > 0 ? 'cash excess' : 'cash shortage'} of{' '}
            <span className="numeric">{formatINR(paise(Math.abs(day.difference)))}</span>.
          </p>
          {day.remarks && <p className="mt-1 text-xs text-warning-800">{day.remarks}</p>}
        </Panel>
      )}

      <DataTable
        columns={columns}
        rows={day.entries}
        getRowKey={(row) => String(row.id)}
        emptyMessage={
          locked
            ? 'No cash moved on this day.'
            : 'No entries yet today. Record a receipt or a payment to start the book.'
        }
        caption={`Cash book for ${formatDate(day.businessDate)}`}
      />
    </>
  );
}
