import type { Metadata } from 'next';
import Link from 'next/link';

import {
  getPurchaseReturns,
  type PurchaseReturnListRow,
} from '@/server/services/purchases/purchase-return-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatINR } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Purchase returns' };
export const dynamic = 'force-dynamic';

/**
 * Spec §21, §23, §34, §41. Debit notes: what went back to the supplier, off
 * which bill, and what it took off the account. A note is raised from the bill
 * itself — that is where the prices and the tax split live — so this screen
 * lists and explains rather than creating.
 */
const VIEWS = [
  { value: 'ALL', label: 'All notes' },
  { value: 'POSTED', label: 'Posted' },
  { value: 'CANCELLED', label: 'Reversed' },
];

const TONE: Record<string, 'neutral' | 'info' | 'positive' | 'danger'> = {
  DRAFT: 'info',
  POSTED: 'positive',
  CANCELLED: 'danger',
};

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ status?: string; q?: string }>;
}) {
  await requirePermission('purchases.view');
  const params = await searchParams;
  const status = params.status ?? 'ALL';

  const rows = await getPurchaseReturns({ status, q: params.q, branchId: null });

  const columns: Column<PurchaseReturnListRow>[] = [
    {
      key: 'note',
      header: 'Debit note',
      render: (row) => (
        <span>
          <Link href={`/purchases/returns/${row.id}`} className="block font-mono text-xs text-brand-600 hover:underline">
            {row.returnNumber}
          </Link>
          <span className="block text-[11px] text-ink-400">{formatDate(row.returnDate)}</span>
        </span>
      ),
    },
    {
      key: 'supplier',
      header: 'Supplier',
      render: (row) => (
        <span>
          <span className="block font-medium text-ink-800">{row.supplierName}</span>
          <span className="block font-mono text-[11px] text-ink-400">{row.supplierCode}</span>
        </span>
      ),
    },
    {
      key: 'bill',
      header: 'Against bill',
      render: (row) => (
        <span>
          <Link href={`/purchases/${row.billId}`} className="block font-mono text-xs text-brand-600 hover:underline">
            {row.billNumber}
          </Link>
          <span className="block font-mono text-[11px] text-ink-400">{row.supplierBillNumber}</span>
        </span>
      ),
    },
    {
      key: 'reason',
      header: 'Reason',
      render: (row) => <span className="block max-w-xs truncate text-ink-600">{row.reason}</span>,
    },
    { key: 'branch', header: 'Branch', render: (row) => row.branchName },
    {
      key: 'lines',
      header: 'Lines',
      numeric: true,
      render: (row) => (row.lineCount > 0 ? row.lineCount : <span className="text-ink-300">—</span>),
    },
    { key: 'taxable', header: 'Goods', numeric: true, render: (row) => formatINR(row.taxableValue) },
    {
      key: 'tax',
      header: 'GST reversed',
      numeric: true,
      render: (row) => (row.taxAmount > 0 ? formatINR(row.taxAmount) : <span className="text-ink-300">—</span>),
    },
    {
      key: 'total',
      header: 'Note total',
      numeric: true,
      render: (row) => <span className="font-medium text-ink-900">{formatINR(row.totalAmount)}</span>,
    },
    {
      key: 'status',
      header: 'Status',
      render: (row) => <Badge variant={TONE[row.status] ?? 'neutral'}>{row.status === 'CANCELLED' ? 'REVERSED' : row.status}</Badge>,
    },
  ];

  return (
    <>
      <PageHeader
        title="Purchase returns"
        description="Debit notes: stock sent back to the supplier at the price it came in at, its input GST reversed, and the payable reduced (spec §21, §34, §41)."
        count={rows.length}
        action={
          <Button variant="secondary" asChild>
            <Link href="/purchases?status=POSTED">Open a bill to raise one</Link>
          </Button>
        }
      />

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div>
            <label htmlFor="status" className="mb-1.5 block text-xs font-medium text-ink-600">Showing</label>
            <select
              id="status" name="status" defaultValue={status}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            >
              {VIEWS.map((v) => <option key={v.value} value={v.value}>{v.label}</option>)}
            </select>
          </div>
          <div className="min-w-48 flex-1">
            <label htmlFor="q" className="mb-1.5 block text-xs font-medium text-ink-600">Search</label>
            <input
              id="q" name="q" defaultValue={params.q ?? ''}
              placeholder="Note number or their credit note"
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
        emptyMessage="No debit notes yet. Open a posted purchase bill to send part of it back."
        caption="Purchase returns"
      />
    </>
  );
}
