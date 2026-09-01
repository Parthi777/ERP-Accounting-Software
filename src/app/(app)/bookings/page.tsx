import type { Metadata } from 'next';
import Link from 'next/link';
import { Plus, Search } from 'lucide-react';

import { getBookings, type BookingListRow } from '@/server/services/sales/booking-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatINR, subtract } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Bookings' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'info' | 'neutral' | 'danger'> = {
  OPEN: 'positive',
  CONVERTED: 'info',
  CANCELLED: 'danger',
  EXPIRED: 'neutral',
};

const columns: Column<BookingListRow>[] = [
  {
    key: 'number',
    header: 'Booking',
    render: (row) => (
      <Link href={`/bookings/${row.id}`} className="font-mono text-xs text-brand-600 hover:underline">
        {row.bookingNumber}
      </Link>
    ),
  },
  { key: 'date', header: 'Date', render: (row) => formatDate(row.bookingDate) },
  {
    key: 'customer',
    header: 'Customer',
    render: (row) => (
      <span>
        <span className="block font-medium text-ink-900">{row.customerName}</span>
        <span className="block font-mono text-[11px] text-ink-400">{row.customerCode}</span>
      </span>
    ),
  },
  { key: 'model', header: 'Model', render: (row) => row.modelLabel },
  { key: 'branch', header: 'Branch', render: (row) => row.branchName },
  { key: 'amount', header: 'Booking value', numeric: true, render: (row) => formatINR(row.bookingAmount) },
  { key: 'received', header: 'Advance', numeric: true, render: (row) => formatINR(row.receivedAmount) },
  {
    key: 'balance',
    header: 'Balance',
    numeric: true,
    render: (row) => {
      const balance = subtract(row.bookingAmount, row.receivedAmount);
      return <span className={balance > 0 ? 'text-warning-700' : 'text-positive-700'}>{formatINR(balance)}</span>;
    },
  },
  {
    key: 'delivery',
    header: 'Expected',
    render: (row) => (row.expectedDelivery ? formatDate(row.expectedDelivery) : '—'),
  },
  {
    key: 'status',
    header: 'Status',
    render: (row) => <Badge variant={STATUS_TONE[row.status] ?? 'neutral'}>{row.status}</Badge>,
  },
];

export default async function BookingsPage({
  searchParams,
}: {
  searchParams: Promise<{ status?: string; branch?: string; q?: string }>;
}) {
  const context = await requireTenantContext();
  const params = await searchParams;
  const status = params.status ?? 'OPEN';
  const branchId = params.branch === 'all' ? null : (params.branch ?? null);

  const rows = await getBookings({ status, branchId, q: params.q });
  const canCreate = context.permissions.has('bookings.create');

  return (
    <div>
      <PageHeader
        title="Bookings"
        description="An advance is money held, not revenue — it posts to Customer Advances until the sale is raised."
        count={rows.length}
        action={
          canCreate ? (
            <Button asChild>
              <Link href="/bookings/new"><Plus aria-hidden />New booking</Link>
            </Button>
          ) : undefined
        }
      />

      <Panel className="mb-4 p-3">
        <form method="GET" className="flex flex-wrap items-center gap-2">
          <div className="relative min-w-0 flex-1">
            <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-ink-400" aria-hidden />
            <input type="search" name="q" defaultValue={params.q ?? ''}
              placeholder="Booking number, customer name or ID…" aria-label="Search bookings"
              className="h-9 w-full rounded-lg border border-ink-200 bg-white pl-9 pr-3 text-sm shadow-sm placeholder:text-ink-400 focus:border-brand-400 focus:outline-none focus:ring-2 focus:ring-brand-500/20" />
          </div>
          <select name="status" defaultValue={status} aria-label="Status"
            className="h-9 rounded-lg border border-ink-200 bg-white px-2 text-sm text-ink-700 shadow-sm">
            <option value="OPEN">Open</option>
            <option value="ALL">All</option>
            <option value="CONVERTED">Converted</option>
            <option value="CANCELLED">Cancelled</option>
          </select>
          {context.accessibleBranches.length > 0 && (
            <select name="branch" defaultValue={params.branch ?? 'all'} aria-label="Branch"
              className="h-9 rounded-lg border border-ink-200 bg-white px-2 text-sm text-ink-700 shadow-sm">
              {context.hasAllBranchAccess && <option value="all">All branches</option>}
              {context.accessibleBranches.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
            </select>
          )}
          <Button type="submit" variant="secondary" size="sm">Search</Button>
        </form>
      </Panel>

      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.id}
        caption="Bookings"
        emptyMessage="No bookings yet."
        maxHeight="40rem"
      />
    </div>
  );
}
