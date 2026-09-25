import Link from 'next/link';
import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { ArrowLeft } from 'lucide-react';

import { getPurchaseOrder } from '@/server/services/purchases/purchase-order-service';
import {
  approvePurchaseOrderAction,
  cancelGoodsReceiptAction,
  closePurchaseOrderAction,
} from '@/server/services/purchases/purchase-order-actions';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { Panel, PanelContent, PanelHeader, PanelTitle, SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { ActionForm } from '@/components/forms/action-form';
import { GoodsReceiptForm } from '@/components/purchases/purchase-order-forms';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Purchase order' };
export const dynamic = 'force-dynamic';

const inr = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', minimumFractionDigits: 2 });
const TONE: Record<string, 'neutral' | 'info' | 'positive' | 'warning' | 'danger'> = {
  DRAFT: 'info', APPROVED: 'warning', PARTIAL: 'warning', RECEIVED: 'positive', CLOSED: 'neutral', CANCELLED: 'danger',
  POSTED: 'positive',
};

export default async function PurchaseOrderPage({ params }: { params: Promise<{ id: string }> }) {
  const context = await requirePermission('purchases.view');
  const { id } = await params;
  const po = await getPurchaseOrder(id);
  if (!po) notFound();

  const canPost = hasPermission(context, 'purchases.post');
  const canClose = canPost || hasPermission(context, 'purchases.cancel');
  const open = po.status === 'APPROVED' || po.status === 'PARTIAL';
  const toReceive = po.lines.filter((l) => l.pending > 0);

  return (
    <div className="space-y-4">
      <Button variant="ghost" size="sm" asChild className="-ml-2">
        <Link href="/purchases/orders"><ArrowLeft aria-hidden />Purchase orders</Link>
      </Button>

      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="flex items-center gap-2">
            <h1 className="font-mono text-xl font-bold tracking-tight text-ink-900">{po.poNumber}</h1>
            <Badge variant={TONE[po.status] ?? 'neutral'}>{po.status.toLowerCase()}</Badge>
          </div>
          <p className="mt-0.5 text-sm text-ink-500">
            {po.supplierName} · ordered {formatDate(po.orderDate)}
            {po.expectedDate && <> · expected {formatDate(po.expectedDate)}</>} · {po.branchName}
          </p>
          {po.notes && <p className="mt-1 whitespace-pre-line text-xs text-ink-600">{po.notes}</p>}
        </div>
        <div className="flex flex-wrap gap-2">
          {po.status === 'DRAFT' && canPost && (
            <div className="w-40">
              <ActionForm fields={[]} fixed={{ orderId: po.id }} action={approvePurchaseOrderAction} submitLabel="Approve order" columns={1} />
            </div>
          )}
        </div>
      </div>

      <SolidPanel className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-[11px] uppercase tracking-wide text-ink-500">
              <th className="px-4 py-2 text-left font-semibold">Item</th>
              <th className="px-4 py-2 text-left font-semibold">Lot</th>
              <th className="px-4 py-2 text-right font-semibold">Rate</th>
              <th className="px-4 py-2 text-right font-semibold">GST</th>
              <th className="px-4 py-2 text-right font-semibold">Ordered</th>
              <th className="px-4 py-2 text-right font-semibold">Received</th>
              <th className="px-4 py-2 text-right font-semibold">Billed</th>
              <th className="px-4 py-2 text-right font-semibold">Pending</th>
            </tr>
          </thead>
          <tbody>
            {po.lines.map((l) => (
              <tr key={l.id} className="border-t border-ink-100">
                <td className="px-4 py-2 text-ink-800">{l.description}</td>
                <td className="px-4 py-2 text-xs text-ink-500">{l.source.toLowerCase()}</td>
                <td className="numeric px-4 py-2">{inr.format(l.unitRate)}</td>
                <td className="numeric px-4 py-2">{l.gstRate}%</td>
                <td className="numeric px-4 py-2">{l.quantity}</td>
                <td className="numeric px-4 py-2">{l.received}</td>
                <td className="numeric px-4 py-2">{l.billed}</td>
                <td className="numeric px-4 py-2 font-semibold">{l.pending || '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </SolidPanel>

      {open && canPost && toReceive.length > 0 && (
        <Panel>
          <PanelHeader><PanelTitle>Receive goods</PanelTitle></PanelHeader>
          <PanelContent>
            <GoodsReceiptForm orderId={po.id} orderDate={po.orderDate}
              lines={toReceive.map((l) => ({ id: l.id, description: l.description, pending: l.pending, unitRate: l.unitRate }))} />
          </PanelContent>
        </Panel>
      )}

      {po.receipts.length > 0 && (
        <Panel>
          <PanelHeader><PanelTitle>Goods receipts</PanelTitle></PanelHeader>
          <PanelContent>
            <ul className="divide-y divide-ink-100">
              {po.receipts.map((r) => (
                <li key={r.id} className="flex flex-wrap items-start justify-between gap-3 py-3 first:pt-0">
                  <div className="text-sm">
                    <span className="font-mono text-xs text-ink-800">{r.grnNumber}</span>
                    <Badge variant={TONE[r.status] ?? 'neutral'} className="ml-2">{r.status.toLowerCase()}</Badge>
                    <span className="ml-2 text-xs text-ink-500">{formatDate(r.receiptDate)}</span>
                    <span className="block text-xs text-ink-500">
                      {r.challan && <>Challan {r.challan} · </>}{r.transport ?? 'No transport details'}
                      {r.cancelReason && <> · cancelled: {r.cancelReason}</>}
                    </span>
                    {r.journalEntryId && (
                      <Link href={`/accounting/journals/${r.journalEntryId}`} className="text-xs text-brand-700 hover:underline">Journal entry</Link>
                    )}
                  </div>
                  <div className="flex items-start gap-3">
                    <span className="numeric text-sm font-semibold">{inr.format(r.totalValue)}</span>
                    {r.status === 'POSTED' && canClose && (
                      <div className="w-64">
                        <ActionForm fields={[{ name: 'reason', label: 'Reason to cancel', required: true }]}
                          fixed={{ receiptId: r.id, orderId: po.id }} action={cancelGoodsReceiptAction}
                          submitLabel="Cancel receipt" columns={1}
                          confirm="Cancel this receipt? Its stock goes back out and its journal is reversed." />
                      </div>
                    )}
                  </div>
                </li>
              ))}
            </ul>
          </PanelContent>
        </Panel>
      )}

      {(po.status === 'DRAFT' || open) && canClose && (
        <Panel>
          <PanelHeader><PanelTitle>{po.receipts.some((r) => r.status === 'POSTED') ? 'Close the order' : 'Cancel the order'}</PanelTitle></PanelHeader>
          <PanelContent>
            <p className="mb-3 text-xs text-ink-500">
              Closing stops what was not received from showing as pending. An order nothing was received against is cancelled.
            </p>
            <div className="max-w-md">
              <ActionForm fields={[{ name: 'reason', label: 'Reason', required: true, placeholder: 'Supplier short-shipped' }]}
                fixed={{ orderId: po.id }} action={closePurchaseOrderAction} submitLabel="Close order" columns={1} />
            </div>
          </PanelContent>
        </Panel>
      )}
    </div>
  );
}
