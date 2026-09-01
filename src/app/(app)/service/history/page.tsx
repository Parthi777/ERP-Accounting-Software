import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import {
  getServiceHistory,
  type ServiceHistoryRow,
} from '@/server/services/service/service-service';
import { getCustomerOptions } from '@/server/services/customers/customer-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatINR } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Service history' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'info' | 'neutral' | 'warning' | 'danger'> = {
  OPEN: 'warning',
  IN_PROGRESS: 'info',
  READY: 'positive',
  INVOICED: 'positive',
  CLOSED: 'neutral',
  CANCELLED: 'danger',
};

const columns: Column<ServiceHistoryRow>[] = [
  {
    key: 'date',
    header: 'Date',
    render: (row) => (
      <span>
        <span className="block">{formatDate(row.jobDate)}</span>
        <span className="block font-mono text-[11px] text-ink-400">{row.number}</span>
      </span>
    ),
  },
  { key: 'customer', header: 'Customer', render: (row) => row.customerName },
  {
    key: 'vehicle',
    header: 'Vehicle',
    render: (row) => (
      <span>
        <span className="block font-mono text-xs">{row.registrationNo ?? '—'}</span>
        {row.odometer != null && (
          <span className="block text-[11px] text-ink-400">{row.odometer.toLocaleString('en-IN')} km</span>
        )}
      </span>
    ),
  },
  { key: 'type', header: 'Type', render: (row) => row.serviceType.replace('_', ' ') },
  {
    key: 'complaint',
    header: 'Complaint',
    render: (row) =>
      row.complaint ? (
        <span className="line-clamp-2 max-w-xs text-ink-600">{row.complaint}</span>
      ) : (
        <span className="text-ink-300">—</span>
      ),
  },
  {
    key: 'invoice',
    header: 'Invoice',
    render: (row) =>
      row.invoiceNumber ? (
        <span className="font-mono text-xs text-ink-600">{row.invoiceNumber}</span>
      ) : (
        <span className="text-ink-300">Not billed</span>
      ),
  },
  {
    key: 'total',
    header: 'Value',
    numeric: true,
    render: (row) => (row.invoiceTotal > 0 ? formatINR(row.invoiceTotal) : <span className="text-ink-300">—</span>),
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
  searchParams: Promise<{ customer?: string; registration?: string }>;
}) {
  await requirePermission('service.history.view');
  const params = await searchParams;

  const searching = Boolean(params.customer || params.registration);

  const [rows, customers] = await Promise.all([
    searching
      ? getServiceHistory({ customerId: params.customer, registrationNo: params.registration })
      : Promise.resolve([]),
    getCustomerOptions(),
  ]);

  return (
    <>
      <PageHeader
        title="Service history"
        description="Every visit for a vehicle or a customer (spec §33)."
        count={searching ? rows.length : undefined}
        action={
          <Button variant="secondary" size="sm" asChild>
            <Link href="/service"><ArrowLeft aria-hidden />Job cards</Link>
          </Button>
        }
      />

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div className="min-w-56">
            <label htmlFor="customer" className="mb-1.5 block text-xs font-medium text-ink-600">Customer</label>
            <select id="customer" name="customer" defaultValue={params.customer ?? ''}
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
              <option value="">Any customer</option>
              {customers.map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}
            </select>
          </div>
          <div>
            <label htmlFor="registration" className="mb-1.5 block text-xs font-medium text-ink-600">
              Registration number
            </label>
            <input id="registration" name="registration" defaultValue={params.registration ?? ''}
              placeholder="TN01AB1234"
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm uppercase shadow-sm" />
          </div>
          <Button type="submit" variant="secondary" size="sm">Search</Button>
        </form>
      </Panel>

      {!searching ? (
        <Panel className="p-8 text-center">
          <p className="text-sm text-ink-700">Choose a customer or enter a registration number.</p>
          <p className="mt-1 text-xs text-ink-500">
            History is looked up rather than listed, because a workshop&rsquo;s full history is not a
            list anyone reads.
          </p>
        </Panel>
      ) : (
        <DataTable
          columns={columns}
          rows={rows}
          getRowKey={(row) => row.jobCardId}
          emptyMessage="No service history found for that vehicle or customer."
          caption="Service history"
        />
      )}
    </>
  );
}
