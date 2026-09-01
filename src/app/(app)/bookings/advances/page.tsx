import type { Metadata } from 'next';
import Link from 'next/link';

import {
  getBookingAdvances,
  type AdvanceReceiptRow,
} from '@/server/services/sales/booking-advance-service';
import { getFinancePickers } from '@/server/services/finance/finance-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { BookingRefundAction } from '@/components/sales/booking-refund-action';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatINR, subtract, toRupees } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Booking advances' };
export const dynamic = 'force-dynamic';

const BOOKING_TONE: Record<string, 'positive' | 'info' | 'neutral' | 'warning' | 'danger'> = {
  OPEN: 'warning',
  CONVERTED: 'positive',
  CANCELLED: 'danger',
  EXPIRED: 'neutral',
};

const STATUSES = ['OPEN', 'CONVERTED', 'CANCELLED', 'ALL'];

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ status?: string }>;
}) {
  const context = await requirePermission('bookings.view');
  const params = await searchParams;
  const status = params.status && STATUSES.includes(params.status) ? params.status : 'OPEN';

  const canRefund = hasPermission(context, 'bookings.refund');

  const [{ rows, ageing }, pickers] = await Promise.all([
    getBookingAdvances({ branchId: null, status }),
    canRefund ? getFinancePickers() : Promise.resolve({ companies: [], bankAccounts: [] }),
  ]);

  // Advances taken before the release was implemented are still on 2100. Showing
  // the gap rather than one number keeps it honest.
  const drift = subtract(ageing.controlBalance, ageing.outstanding);

  const columns: Column<AdvanceReceiptRow>[] = [
    {
      key: 'receipt',
      header: 'Receipt',
      render: (row) => (
        <span>
          <span className="block font-mono text-xs text-ink-700">{row.receiptNumber}</span>
          <span className="block text-[11px] text-ink-400">{formatDate(row.paymentDate)}</span>
        </span>
      ),
    },
    {
      key: 'booking',
      header: 'Booking',
      render: (row) => (
        <Link href={`/bookings/${row.bookingId}`} className="font-mono text-xs text-brand-600 hover:underline">
          {row.bookingNumber}
        </Link>
      ),
    },
    {
      key: 'customer',
      header: 'Customer',
      render: (row) => (
        <span>
          <Link href={`/customers/${row.customerId}`} className="block font-medium text-brand-600 hover:underline">
            {row.customerName}
          </Link>
          <span className="block font-mono text-[11px] text-ink-400">{row.customerCode}</span>
        </span>
      ),
    },
    { key: 'model', header: 'Model', render: (row) => row.modelLabel },
    { key: 'branch', header: 'Branch', render: (row) => row.branchName },
    { key: 'mode', header: 'Mode', render: (row) => row.mode },
    { key: 'amount', header: 'Advance', numeric: true, render: (row) => formatINR(row.amount) },
    {
      key: 'age',
      header: 'Age',
      numeric: true,
      render: (row) =>
        row.status === 'REVERSED' ? (
          <span className="text-ink-300">—</span>
        ) : (
          <span className={row.ageDays > 90 ? 'font-medium text-danger-700' : 'text-ink-700'}>
            {row.ageDays}d
          </span>
        ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (row) => (
        <span className="flex flex-col gap-1">
          <Badge variant={BOOKING_TONE[row.bookingStatus] ?? 'neutral'}>{row.bookingStatus}</Badge>
          {row.status === 'REVERSED' && <Badge variant="neutral">Refunded</Badge>}
        </span>
      ),
    },
    {
      key: 'actions',
      header: '',
      render: (row) =>
        canRefund && row.bookingStatus === 'CANCELLED' && row.status === 'RECEIVED' ? (
          <BookingRefundAction
            bookingId={row.bookingId}
            bookingNumber={row.bookingNumber}
            maxAmount={toRupees(row.amount)}
            bankAccounts={pickers.bankAccounts}
          />
        ) : null,
    },
  ];

  return (
    <>
      <PageHeader
        title="Booking advances"
        description="Money the dealer is holding and has not earned. It clears when the sale is invoiced, or when it is refunded (spec §18)."
        count={rows.length}
      />

      <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {ageing.buckets.map((b) => (
          <Panel key={b.bucket} className="p-4">
            <p className="text-xs text-ink-500">{b.bucket} days</p>
            <p
              className={
                b.bucket === '90+' && b.amount > 0
                  ? 'mt-0.5 text-lg font-semibold text-danger-700'
                  : 'mt-0.5 text-lg font-semibold text-ink-800'
              }
            >
              {formatINR(b.amount)}
            </p>
            <p className="mt-0.5 text-[11px] text-ink-400">
              {b.count} {b.count === 1 ? 'booking' : 'bookings'} still open
            </p>
          </Panel>
        ))}
      </div>

      <Panel className="mb-4 p-4">
        <div className="flex flex-wrap items-baseline justify-between gap-3">
          <div>
            <p className="text-xs text-ink-500">Held against open bookings</p>
            <p className="mt-0.5 text-lg font-semibold text-ink-800">{formatINR(ageing.outstanding)}</p>
          </div>
          <div>
            <p className="text-xs text-ink-500">Customer Advances (2100)</p>
            <p className="mt-0.5 text-lg font-semibold text-ink-800">{formatINR(ageing.controlBalance)}</p>
          </div>
          <div>
            <p className="text-xs text-ink-500">Difference</p>
            <p
              className={
                drift === 0
                  ? 'mt-0.5 text-lg font-semibold text-positive-700'
                  : 'mt-0.5 text-lg font-semibold text-warning-700'
              }
            >
              {formatINR(drift)}
            </p>
          </div>
        </div>
        {drift !== 0 && (
          <p className="mt-3 border-t border-ink-100 pt-3 text-xs text-ink-500">
            The control account holds more than the open bookings account for. Advances taken before
            the release on posting was added were never cleared from 2100, and they are not
            back-posted because that would put journals into closed periods. New bookings clear
            correctly; this difference is the historical remainder and should be written off by
            journal rather than left to drift.
          </p>
        )}
      </Panel>

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div>
            <label htmlFor="status" className="mb-1.5 block text-xs font-medium text-ink-600">
              Booking status
            </label>
            <select
              id="status" name="status" defaultValue={status}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            >
              {STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
            </select>
          </div>
          <Button type="submit" variant="secondary" size="sm">Filter</Button>
        </form>
      </Panel>

      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.paymentId}
        emptyMessage={
          status === 'OPEN'
            ? 'No advances are being held against open bookings.'
            : 'No advance receipts match this filter.'
        }
        caption="Booking advance receipts"
        maxHeight="40rem"
      />
    </>
  );
}
