import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ArrowLeft, Lock } from 'lucide-react';

import {
  getPurchaseBill,
  getPurchasePickers,
  getUnbilledVehicles,
} from '@/server/services/purchases/purchase-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { PurchaseBillEditor } from '@/components/purchases/purchase-bill-editor';
import { Panel, PanelContent, PanelHeader, PanelTitle } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatINR } from '@/lib/money';
import { formatDate, formatDateTime } from '@/lib/format';

export const metadata: Metadata = { title: 'Purchase bill' };
export const dynamic = 'force-dynamic';

const TONE: Record<string, 'neutral' | 'info' | 'positive' | 'danger'> = {
  DRAFT: 'info',
  POSTED: 'positive',
  CANCELLED: 'danger',
};

export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  const context = await requirePermission('purchases.view');
  const { id } = await params;

  const bill = await getPurchaseBill(id);
  if (!bill) {
    notFound();
  }

  const can = {
    edit: hasPermission(context, 'purchases.create'),
    post: hasPermission(context, 'purchases.post'),
    cancel: hasPermission(context, 'purchases.cancel'),
  };

  // Only a draft can gain lines, so the pickers are only worth loading for one.
  const [vehicles, pickers] = await Promise.all([
    bill.status === 'DRAFT' && can.edit
      ? getUnbilledVehicles({ branchId: bill.branchId })
      : Promise.resolve([]),
    bill.status === 'DRAFT' && can.edit
      ? getPurchasePickers()
      : Promise.resolve({ suppliers: [], items: [] }),
  ]);

  return (
    <div>
      <Button variant="ghost" size="sm" asChild className="-ml-2 mb-2">
        <Link href="/purchases"><ArrowLeft aria-hidden />Purchase bills</Link>
      </Button>

      <div className="mb-4 flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <h1 className="font-mono text-xl font-bold tracking-tight text-ink-900">{bill.billNumber}</h1>
            <Badge variant={TONE[bill.status] ?? 'neutral'}>{bill.status}</Badge>
            {bill.status === 'POSTED' && (
              <span className="flex items-center gap-1 text-xs text-ink-500">
                <Lock className="size-3.5" aria-hidden />
                Immutable
              </span>
            )}
          </div>
          <p className="mt-0.5 text-sm text-ink-500">
            {bill.supplierName} · their bill{' '}
            <span className="font-mono text-ink-700">{bill.supplierBillNumber}</span> ·{' '}
            {formatDate(bill.billDate)} · {bill.branchName}
          </p>
        </div>

        {bill.journalEntryId && (
          <Button variant="secondary" size="sm" asChild>
            <Link href={`/accounting/journals/${bill.journalEntryId}`}>Journal entry</Link>
          </Button>
        )}
      </div>

      <div className="grid gap-4 lg:grid-cols-3">
        <div className="space-y-4 lg:col-span-2">
          <PurchaseBillEditor
            bill={bill}
            unbilledVehicles={vehicles}
            items={pickers.items}
            can={can}
          />
        </div>

        <div className="space-y-4">
          <Panel>
            <PanelHeader><PanelTitle>Summary</PanelTitle></PanelHeader>
            <PanelContent>
              <dl className="space-y-2.5">
                <Row label="Taxable value" value={formatINR(bill.taxableValue)} />
                {bill.cgstAmount > 0 && <Row label="Input CGST" value={formatINR(bill.cgstAmount)} />}
                {bill.sgstAmount > 0 && <Row label="Input SGST" value={formatINR(bill.sgstAmount)} />}
                {bill.igstAmount > 0 && <Row label="Input IGST" value={formatINR(bill.igstAmount)} />}
                <div className="border-t border-ink-200 pt-2.5">
                  <Row label="Payable to supplier" value={formatINR(bill.totalAmount)} strong />
                </div>
              </dl>
              <p className="mt-3 text-[11px] text-ink-400">
                Input GST is an asset — it is credit the dealer claims back, not part of what the
                stock cost.
              </p>
            </PanelContent>
          </Panel>

          <Panel>
            <PanelHeader><PanelTitle>Bill</PanelTitle></PanelHeader>
            <PanelContent>
              <dl className="space-y-2.5">
                <Row label="Supplier" value={bill.supplierName} />
                <Row label="Supplier code" value={bill.supplierCode} />
                <Row label="Bill date" value={formatDate(bill.billDate)} />
                <Row label="Due" value={bill.dueDate ? formatDate(bill.dueDate) : '—'} />
                {bill.postedAt && <Row label="Posted" value={formatDateTime(bill.postedAt)} />}
              </dl>
              {bill.notes && (
                <p className="mt-3 whitespace-pre-line rounded-lg border border-ink-100 bg-ink-50 px-3 py-2 text-xs text-ink-600">
                  {bill.notes}
                </p>
              )}
            </PanelContent>
          </Panel>
        </div>
      </div>
    </div>
  );
}

function Row({
  label,
  value,
  strong = false,
}: {
  readonly label: string;
  readonly value: string;
  readonly strong?: boolean;
}) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <dt className="text-xs text-ink-500">{label}</dt>
      <dd className={strong ? 'numeric text-base font-bold text-ink-900' : 'numeric text-sm text-ink-800'}>
        {value}
      </dd>
    </div>
  );
}
