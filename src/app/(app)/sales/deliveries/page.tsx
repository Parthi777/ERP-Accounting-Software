import type { Metadata } from 'next';
import Link from 'next/link';

import {
  getSales,
  getDeliveries,
  type SaleListRow,
  type DeliveryRow,
} from '@/server/services/sales/sale-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { DeliverAction } from '@/components/sales/deliver-action';
import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { formatINR } from '@/lib/money';
import { formatDate, formatDateTime } from '@/lib/format';

export const metadata: Metadata = { title: 'Deliveries' };
export const dynamic = 'force-dynamic';

/**
 * Spec §19. Two halves of the same job: what is paid for and waiting to be
 * handed over, and what has already gone. Pending leads, because that is the
 * list someone works from.
 */
const VIEWS = [
  { value: 'PENDING', label: 'Awaiting delivery' },
  { value: 'DELIVERED', label: 'Delivered' },
];

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ view?: string; q?: string }>;
}) {
  const context = await requirePermission('sales.view');
  const params = await searchParams;
  const view = params.view === 'DELIVERED' ? 'DELIVERED' : 'PENDING';
  const canDeliver = hasPermission(context, 'sales.deliver');

  if (view === 'DELIVERED') {
    const rows = await getDeliveries({ branchId: null, q: params.q });

    const columns: Column<DeliveryRow>[] = [
      {
        key: 'note',
        header: 'Delivery note',
        render: (row) => (
          <span>
            <span className="block font-mono text-xs text-ink-700">{row.deliveryNumber}</span>
            <span className="block text-[11px] text-ink-400">{formatDateTime(row.deliveredAt)}</span>
          </span>
        ),
      },
      {
        key: 'invoice',
        header: 'Invoice',
        render: (row) => (
          <Link href={`/sales/${row.saleId}`} className="font-mono text-xs text-brand-600 hover:underline">
            {row.invoiceNumber}
          </Link>
        ),
      },
      { key: 'customer', header: 'Customer', render: (row) => row.customerName },
      {
        key: 'vehicle',
        header: 'Vehicle',
        render: (row) => (
          <span>
            <span className="block text-ink-700">{row.modelLabel}</span>
            <span className="block font-mono text-[11px] text-ink-400">{row.chassisNo}</span>
          </span>
        ),
      },
      { key: 'branch', header: 'Branch', render: (row) => row.branchName },
      {
        key: 'receivedBy',
        header: 'Received by',
        render: (row) => row.receivedBy ?? <span className="text-ink-300">—</span>,
      },
      {
        key: 'odometer',
        header: 'Odometer',
        numeric: true,
        render: (row) => (row.odometer === null ? <span className="text-ink-300">—</span> : row.odometer),
      },
    ];

    return (
      <>
        <PageHeader
          title="Deliveries"
          description="Handovers already made, each with its own delivery note (spec §19, §45)."
          count={rows.length}
        />
        <Filters view={view} q={params.q} />
        <DataTable
          columns={columns}
          rows={rows}
          getRowKey={(row) => row.id}
          emptyMessage="No deliveries recorded."
          caption="Deliveries"
        />
      </>
    );
  }

  // Awaiting delivery: posted sales that have not been handed over. A sale is
  // POSTED from the moment it is invoiced until delivery moves it on, so this
  // list is exactly the vehicles the branch still holds against a sale.
  const rows = await getSales({ status: 'POSTED', branchId: null, q: params.q });

  const columns: Column<SaleListRow>[] = [
    {
      key: 'invoice',
      header: 'Invoice',
      render: (row) => (
        <span>
          <Link href={`/sales/${row.id}`} className="block font-mono text-xs text-brand-600 hover:underline">
            {row.invoiceNumber}
          </Link>
          <span className="block text-[11px] text-ink-400">{formatDate(row.invoiceDate)}</span>
        </span>
      ),
    },
    {
      key: 'customer',
      header: 'Customer',
      render: (row) => (
        <span>
          <span className="block font-medium text-ink-800">{row.customerName}</span>
          <span className="block font-mono text-[11px] text-ink-400">{row.customerCode}</span>
        </span>
      ),
    },
    {
      key: 'vehicle',
      header: 'Vehicle',
      render: (row) => (
        <span>
          <span className="block text-ink-700">{row.modelLabel}</span>
          <span className="block font-mono text-[11px] text-ink-400">{row.chassisNo}</span>
        </span>
      ),
    },
    { key: 'branch', header: 'Branch', render: (row) => row.branchName },
    { key: 'total', header: 'Invoice value', numeric: true, render: (row) => formatINR(row.totalAmount) },
    {
      key: 'balance',
      header: 'Balance',
      numeric: true,
      render: (row) =>
        row.balanceAmount > 0 ? (
          // Not a block on delivery — many dealers hand over against finance —
          // but the person at the counter should see it before they do.
          <span className="font-medium text-warning-700">{formatINR(row.balanceAmount)}</span>
        ) : (
          <span className="text-positive-700">Settled</span>
        ),
    },
    {
      key: 'actions',
      header: '',
      render: (row) =>
        canDeliver ? (
          <DeliverAction
            saleId={row.id}
            invoiceNumber={row.invoiceNumber}
            customerName={row.customerName}
          />
        ) : null,
    },
  ];

  return (
    <>
      <PageHeader
        title="Deliveries"
        description="Posted sales waiting to be handed over. Delivery issues a note and closes the sale (spec §19)."
        count={rows.length}
      />
      <Filters view={view} q={params.q} />
      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.id}
        emptyMessage="Nothing is waiting for delivery."
        caption="Awaiting delivery"
      />
    </>
  );
}

function Filters({ view, q }: { readonly view: string; readonly q?: string }) {
  return (
    <Panel className="mb-4 p-4">
      <form method="get" className="flex flex-wrap items-end gap-3">
        <div>
          <label htmlFor="view" className="mb-1.5 block text-xs font-medium text-ink-600">Showing</label>
          <select
            id="view"
            name="view"
            defaultValue={view}
            className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
          >
            {VIEWS.map((v) => (
              <option key={v.value} value={v.value}>{v.label}</option>
            ))}
          </select>
        </div>
        <div className="min-w-48 flex-1">
          <label htmlFor="q" className="mb-1.5 block text-xs font-medium text-ink-600">Search</label>
          <input
            id="q"
            name="q"
            defaultValue={q ?? ''}
            placeholder="Invoice, customer or chassis"
            className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
          />
        </div>
        <Button type="submit" variant="secondary" size="sm">Filter</Button>
      </form>
    </Panel>
  );
}
