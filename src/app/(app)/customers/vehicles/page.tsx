import type { Metadata } from 'next';
import Link from 'next/link';

import {
  getCustomerVehicles,
  type CustomerVehicleRow,
} from '@/server/services/customers/customer-vehicle-service';
import { getCustomerOptions } from '@/server/services/customers/customer-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatDate, formatMobile } from '@/lib/format';

export const metadata: Metadata = { title: 'Vehicle history' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'neutral' | 'danger'> = {
  ACTIVE: 'positive',
  SOLD: 'neutral',
  SCRAPPED: 'danger',
};

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ customer?: string; q?: string }>;
}) {
  await requirePermission('customers.view');
  const params = await searchParams;

  const [rows, customers] = await Promise.all([
    getCustomerVehicles({ customerId: params.customer || null, q: params.q }),
    getCustomerOptions(),
  ]);

  const columns: Column<CustomerVehicleRow>[] = [
    {
      key: 'vehicle',
      header: 'Vehicle',
      render: (row) => (
        <span>
          <span className="block font-medium text-ink-800">
            {row.registrationNo ?? <span className="text-ink-400">Unregistered</span>}
          </span>
          {row.modelLabel && <span className="block text-[11px] text-ink-500">{row.modelLabel}</span>}
        </span>
      ),
    },
    {
      key: 'chassis',
      header: 'Chassis',
      render: (row) =>
        row.chassisNo ? (
          <span className="font-mono text-[11px] text-ink-600">{row.chassisNo}</span>
        ) : (
          <span className="text-ink-300">—</span>
        ),
    },
    {
      key: 'customer',
      header: 'Owner',
      render: (row) => (
        <span>
          <Link href={`/customers/${row.customerId}`} className="block font-medium text-brand-600 hover:underline">
            {row.customerName}
          </Link>
          <span className="block font-mono text-[11px] text-ink-400">{row.customerCode}</span>
        </span>
      ),
    },
    { key: 'mobile', header: 'Mobile', render: (row) => formatMobile(row.mobile) },
    {
      key: 'source',
      header: 'Source',
      render: (row) =>
        row.soldByUs ? (
          <Badge variant="positive">Sold by us</Badge>
        ) : (
          <Badge variant="neutral">Workshop</Badge>
        ),
    },
    {
      key: 'purchased',
      header: 'Since',
      render: (row) =>
        row.purchaseDate ? formatDate(row.purchaseDate) : <span className="text-ink-300">—</span>,
    },
    {
      key: 'status',
      header: 'Status',
      render: (row) => <Badge variant={STATUS_TONE[row.status] ?? 'neutral'}>{row.status}</Badge>,
    },
    {
      key: 'actions',
      header: '',
      render: (row) =>
        row.registrationNo ? (
          <div className="flex justify-end">
            <Button size="sm" variant="ghost" asChild>
              <Link href={`/service/history?registration=${encodeURIComponent(row.registrationNo)}`}>
                Service history
              </Link>
            </Button>
          </div>
        ) : null,
    },
  ];

  return (
    <>
      <PageHeader
        title="Vehicle history"
        description="Which vehicle belongs to whom — built from deliveries and workshop visits, not a separate register to maintain (spec §11)."
        count={rows.length}
      />

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div className="min-w-56 flex-1">
            <label htmlFor="customer" className="mb-1.5 block text-xs font-medium text-ink-600">
              Customer
            </label>
            <select
              id="customer" name="customer" defaultValue={params.customer ?? ''}
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            >
              <option value="">All customers</option>
              {customers.map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}
            </select>
          </div>
          <div className="min-w-48 flex-1">
            <label htmlFor="q" className="mb-1.5 block text-xs font-medium text-ink-600">Search</label>
            <input
              id="q" name="q" defaultValue={params.q ?? ''}
              placeholder="Registration, chassis or customer"
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            />
          </div>
          <Button type="submit" variant="secondary" size="sm">Filter</Button>
        </form>
      </Panel>

      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.id}
        emptyMessage="No customer vehicles yet. A vehicle is registered here when it is delivered, or when a job card is raised for it."
        caption="Customer vehicles"
      />
    </>
  );
}
