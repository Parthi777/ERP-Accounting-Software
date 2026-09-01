import type { Metadata } from 'next';
import Link from 'next/link';

import {
  getCounterInvoices,
  type ServiceInvoiceRow,
} from '@/server/services/service/service-service';
import { getCustomerOptions } from '@/server/services/customers/customer-service';
import { getSetting } from '@/server/services/org/org-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { CounterSaleStart } from '@/components/service/counter-sale-start';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { ExportButtons } from '@/components/export/export-buttons';
import { formatINR } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Counter sales' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'info' | 'neutral' | 'warning' | 'danger'> = {
  DRAFT: 'warning',
  POSTED: 'positive',
  CANCELLED: 'neutral',
  RETURNED: 'danger',
};

const STATUSES = ['ALL', 'DRAFT', 'POSTED', 'CANCELLED'];

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ status?: string }>;
}) {
  await requirePermission('inventory.counter_sale.create');
  const params = await searchParams;
  const status = params.status && STATUSES.includes(params.status) ? params.status : 'ALL';

  const [rows, customers, requireCustomer] = await Promise.all([
    getCounterInvoices({ status }),
    getCustomerOptions(),
    getSetting('counter_sale.require_customer'),
  ]);

  const columns: Column<ServiceInvoiceRow>[] = [
    {
      key: 'number',
      header: 'Invoice',
      render: (row) => (
        <span>
          <Link
            href={`/inventory/counter-sales/${row.id}`}
            className="block font-mono text-xs text-brand-600 hover:underline"
          >
            {row.number}
          </Link>
          <span className="block text-[11px] text-ink-400">{formatDate(row.invoiceDate)}</span>
        </span>
      ),
    },
    {
      key: 'customer',
      header: 'Customer',
      render: (row) => row.customerName ?? <span className="text-ink-400">Walk-in</span>,
    },
    { key: 'branch', header: 'Branch', render: (row) => row.branchName },
    { key: 'total', header: 'Value', numeric: true, render: (row) => formatINR(row.total) },
    { key: 'paid', header: 'Received', numeric: true, render: (row) => formatINR(row.paid) },
    {
      key: 'balance',
      header: 'Balance',
      numeric: true,
      render: (row) =>
        row.balance > 0 ? (
          <span className="font-medium text-warning-700">{formatINR(row.balance)}</span>
        ) : (
          <span className="text-positive-700">Settled</span>
        ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (row) => <Badge variant={STATUS_TONE[row.status] ?? 'neutral'}>{row.status}</Badge>,
    },
  ];

  return (
    <>
      <PageHeader
        title="Counter sales"
        description="Accessories and spares sold over the counter, billed through the same engine as service (spec §33)."
        count={rows.length}
        action={
          <div className="flex flex-wrap items-center gap-2">
            <ExportButtons report="counter-sales" />
            <CounterSaleStart customers={customers} requireCustomer={requireCustomer} />
          </div>
        }
      />

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div>
            <label htmlFor="status" className="mb-1.5 block text-xs font-medium text-ink-600">Status</label>
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
        getRowKey={(row) => row.id}
        emptyMessage="No counter sales yet."
        caption="Counter sales"
      />
    </>
  );
}
