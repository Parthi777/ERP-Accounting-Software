import Link from 'next/link';
import type { Metadata } from 'next';
import { Plus } from 'lucide-react';

import {
  getGrniOutstanding,
  getPendingOrderLines,
  listPurchaseOrders,
  type GrniLine,
  type PendingLine,
  type PurchaseOrderRow,
} from '@/server/services/purchases/purchase-order-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatDate } from '@/lib/format';
import { cn } from '@/lib/utils';

export const metadata: Metadata = { title: 'Purchase Orders' };
export const dynamic = 'force-dynamic';

const inr = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', minimumFractionDigits: 2 });
const TONE: Record<string, 'neutral' | 'info' | 'positive' | 'warning' | 'danger'> = {
  DRAFT: 'info', APPROVED: 'warning', PARTIAL: 'warning', RECEIVED: 'positive', CLOSED: 'neutral', CANCELLED: 'danger',
};

const orderColumns: Column<PurchaseOrderRow>[] = [
  { key: 'po', header: 'Order', render: (r) => <Link href={`/purchases/orders/${r.id}`} className="font-mono text-xs text-brand-700 hover:underline">{r.poNumber}</Link> },
  { key: 'date', header: 'Date', render: (r) => formatDate(r.orderDate) },
  { key: 'supplier', header: 'Supplier', render: (r) => r.supplierName },
  { key: 'branch', header: 'Branch', render: (r) => <span className="text-ink-500">{r.branchName}</span> },
  { key: 'expected', header: 'Expected', render: (r) => (r.expectedDate ? formatDate(r.expectedDate) : '—') },
  { key: 'value', header: 'Value', numeric: true, render: (r) => inr.format(r.value) },
  { key: 'status', header: '', render: (r) => <Badge variant={TONE[r.status] ?? 'neutral'}>{r.status.toLowerCase()}</Badge> },
];

const pendingColumns: Column<PendingLine>[] = [
  { key: 'po', header: 'Order', render: (r) => <Link href={`/purchases/orders/${r.orderId}`} className="font-mono text-xs text-brand-700 hover:underline">{r.poNumber}</Link> },
  { key: 'supplier', header: 'Supplier', render: (r) => r.supplierName },
  { key: 'item', header: 'Item', render: (r) => r.description },
  { key: 'ordered', header: 'Ordered', numeric: true, render: (r) => r.ordered },
  { key: 'received', header: 'Received', numeric: true, render: (r) => r.received },
  { key: 'pending', header: 'Pending', numeric: true, render: (r) => <span className="font-semibold">{r.pending}</span> },
  {
    key: 'due', header: 'Expected',
    render: (r) => (
      <span className={cn(r.overdue && 'font-medium text-danger-700')}>
        {r.expectedDate ? formatDate(r.expectedDate) : '—'}{r.overdue && ' · overdue'}
      </span>
    ),
  },
];

const grniColumns: Column<GrniLine>[] = [
  { key: 'grn', header: 'Receipt', render: (r) => <span className="font-mono text-xs">{r.grnNumber}</span> },
  { key: 'date', header: 'Received', render: (r) => formatDate(r.receiptDate) },
  { key: 'supplier', header: 'Supplier', render: (r) => r.supplierName },
  { key: 'item', header: 'Item', render: (r) => r.description },
  { key: 'qty', header: 'Unbilled', numeric: true, render: (r) => r.unbilled },
  { key: 'value', header: 'Value', numeric: true, render: (r) => inr.format(r.value) },
];

const TABS = [
  { key: 'orders', label: 'Orders' },
  { key: 'pending', label: 'Pending items' },
  { key: 'grni', label: 'Received, not billed' },
] as const;

/**
 * Purchase orders (F33, F40): the orders, what is still to come against them,
 * and goods received but not yet billed — which is exactly the balance of
 * 2760 Goods Received Not Invoiced.
 */
export default async function PurchaseOrdersPage({ searchParams }: { searchParams: Promise<{ view?: string; open?: string }> }) {
  const context = await requirePermission('purchases.view');
  const params = await searchParams;
  const view = TABS.some((t) => t.key === params.view) ? params.view! : 'orders';

  const [orders, pending, grni] = await Promise.all([
    view === 'orders' ? listPurchaseOrders({ open: params.open === '1' }) : Promise.resolve([]),
    view === 'pending' ? getPendingOrderLines() : Promise.resolve([]),
    view === 'grni' ? getGrniOutstanding() : Promise.resolve([]),
  ]);

  return (
    <div className="space-y-4">
      <PageHeader
        title="Purchase Orders"
        description="Order from the supplier, receive the goods against the order, then bill the receipt — stock comes in once, at receipt."
        action={hasPermission(context, 'purchases.create') ? (
          <Button asChild size="sm"><Link href="/purchases/orders/new"><Plus aria-hidden />New order</Link></Button>
        ) : undefined}
      />

      <nav className="flex gap-1 text-sm" aria-label="Views">
        {TABS.map((t) => (
          <Link key={t.key} href={`/purchases/orders?view=${t.key}`}
            className={cn('rounded-lg px-3 py-1.5', view === t.key ? 'bg-brand-50 font-medium text-brand-800' : 'text-ink-600 hover:bg-ink-50')}>
            {t.label}
          </Link>
        ))}
        {view === 'orders' && (
          <Link href={`/purchases/orders?view=orders${params.open === '1' ? '' : '&open=1'}`} className="ml-auto px-3 py-1.5 text-xs text-ink-500 hover:underline">
            {params.open === '1' ? 'Show all' : 'Open orders only'}
          </Link>
        )}
      </nav>

      {view === 'orders' && (
        <DataTable columns={orderColumns} rows={orders} getRowKey={(r) => r.id} caption="Purchase orders"
          emptyMessage="No purchase orders yet." maxHeight="40rem" />
      )}
      {view === 'pending' && (
        <DataTable columns={pendingColumns} rows={pending} getRowKey={(r) => `${r.orderId}:${r.description}:${r.ordered}`}
          caption="Pending purchase order items" emptyMessage="Nothing is pending — every approved order is fully received." maxHeight="40rem" />
      )}
      {view === 'grni' && (
        <>
          <DataTable columns={grniColumns} rows={grni} getRowKey={(r) => r.grnLineId} caption="Goods received not billed"
            emptyMessage="Every receipt has been billed." maxHeight="40rem" />
          <p className="text-right text-sm text-ink-600">
            Total <span className="numeric font-semibold text-ink-900">{inr.format(grni.reduce((s, r) => s + r.value, 0))}</span>
            {' '}— the balance of 2760 Goods Received Not Invoiced.
          </p>
        </>
      )}
    </div>
  );
}
