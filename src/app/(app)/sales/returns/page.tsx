import type { Metadata } from 'next';
import Link from 'next/link';

import {
  getSales,
  getRefundBankAccounts,
  type SaleListRow,
} from '@/server/services/sales/sale-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { SaleReturnAction } from '@/components/sales/return-action';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatINR } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Sales returns' };
export const dynamic = 'force-dynamic';

/**
 * Spec §21, §23. Two views of the same thing: invoices that could still be
 * returned, and those already reversed. Returned sits first as the record;
 * posted is the working list.
 */
const VIEWS = [
  { value: 'POSTED', label: 'Returnable (posted)' },
  { value: 'RETURNED', label: 'Returned' },
];

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ view?: string; q?: string }>;
}) {
  const context = await requirePermission('sales.return');
  const params = await searchParams;
  const view = params.view === 'RETURNED' ? 'RETURNED' : 'POSTED';

  const canReturn = hasPermission(context, 'sales.return');
  const [rows, bankAccounts] = await Promise.all([
    getSales({ status: view, branchId: null, q: params.q }),
    // Needed only for the refund half of the dialog, and only where a return is
    // actually possible.
    canReturn && view === 'POSTED' ? getRefundBankAccounts() : Promise.resolve([]),
  ]);

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
      key: 'paid',
      header: 'Received',
      numeric: true,
      render: (row) =>
        row.paidAmount > 0 ? formatINR(row.paidAmount) : <span className="text-ink-300">—</span>,
    },
    {
      key: 'status',
      header: 'Status',
      render: (row) => (
        <Badge variant={row.status === 'RETURNED' ? 'danger' : 'positive'}>{row.status}</Badge>
      ),
    },
    {
      key: 'actions',
      header: '',
      render: (row) =>
        view === 'POSTED' && canReturn ? (
          <SaleReturnAction
            saleId={row.id}
            invoiceNumber={row.invoiceNumber}
            paidAmount={row.paidAmount}
            financeAmount={row.financeAmount}
            bankAccounts={bankAccounts}
          />
        ) : null,
    },
  ];

  return (
    <>
      <PageHeader
        title="Sales returns"
        description="A return reverses the invoice, refunds what was received through the cash or bank book, and puts the vehicle and its fitted accessories back into stock. The invoice itself is never edited (spec §21, §23)."
        count={rows.length}
      />

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div>
            <label htmlFor="view" className="mb-1.5 block text-xs font-medium text-ink-600">
              Showing
            </label>
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
              defaultValue={params.q ?? ''}
              placeholder="Invoice, customer or chassis"
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
        emptyMessage={
          view === 'RETURNED' ? 'No sales have been returned.' : 'No posted sales to return.'
        }
        caption="Sales returns"
      />
    </>
  );
}
