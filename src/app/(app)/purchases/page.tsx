import type { Metadata } from 'next';
import Link from 'next/link';
import { Plus } from 'lucide-react';

import { getPurchaseBills, type PurchaseListRow } from '@/server/services/purchases/purchase-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatINR } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Purchase bills' };
export const dynamic = 'force-dynamic';

/**
 * Spec §24, §41. The document that puts bought stock on the balance sheet and
 * the payable on the supplier's ledger — the entry point the INVENTORY/PURCHASE
 * accounting rules were written for.
 */
const VIEWS = [
  { value: 'ALL', label: 'All bills' },
  { value: 'DRAFT', label: 'Drafts' },
  { value: 'POSTED', label: 'Posted' },
  { value: 'CANCELLED', label: 'Cancelled' },
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
  const context = await requirePermission('purchases.view');
  const params = await searchParams;
  const status = params.status ?? 'ALL';

  const rows = await getPurchaseBills({ status, q: params.q, branchId: null });
  const canCreate = hasPermission(context, 'purchases.create');

  const columns: Column<PurchaseListRow>[] = [
    {
      key: 'bill',
      header: 'Bill',
      render: (row) => (
        <span>
          <Link href={`/purchases/${row.id}`} className="block font-mono text-xs text-brand-600 hover:underline">
            {row.billNumber}
          </Link>
          <span className="block text-[11px] text-ink-400">{formatDate(row.billDate)}</span>
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
      key: 'ref',
      header: 'Their bill no.',
      render: (row) => <span className="font-mono text-xs text-ink-700">{row.supplierBillNumber}</span>,
    },
    { key: 'branch', header: 'Branch', render: (row) => row.branchName },
    {
      key: 'lines',
      header: 'Lines',
      numeric: true,
      render: (row) => (row.lineCount > 0 ? row.lineCount : <span className="text-ink-300">—</span>),
    },
    { key: 'taxable', header: 'Taxable', numeric: true, render: (row) => formatINR(row.taxableValue) },
    {
      key: 'tax',
      header: 'GST',
      numeric: true,
      render: (row) => (row.taxAmount > 0 ? formatINR(row.taxAmount) : <span className="text-ink-300">—</span>),
    },
    {
      key: 'total',
      header: 'Bill total',
      numeric: true,
      render: (row) => <span className="font-medium text-ink-900">{formatINR(row.totalAmount)}</span>,
    },
    {
      key: 'status',
      header: 'Status',
      render: (row) => <Badge variant={TONE[row.status] ?? 'neutral'}>{row.status}</Badge>,
    },
  ];

  return (
    <>
      <PageHeader
        title="Purchase bills"
        description="A supplier's bill: stock onto the balance sheet, input GST to ITC, and what is owed onto the supplier's ledger (spec §24, §41)."
        count={rows.length}
        action={
          canCreate ? (
            <Button asChild>
              <Link href="/purchases/new"><Plus aria-hidden />New purchase bill</Link>
            </Button>
          ) : null
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
              placeholder="Our bill number or the supplier's"
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
        emptyMessage="No purchase bills yet. Enter one to bring bought stock onto the books."
        caption="Purchase bills"
      />
    </>
  );
}
