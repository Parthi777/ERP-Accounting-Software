import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ArrowLeft, Lock } from 'lucide-react';

import {
  getPurchaseBill,
  getPurchasePickers,
  getUnbilledVehicles,  getPurchaseGstRates,
} from '@/server/services/purchases/purchase-service';
import {
  getReturnableLines,
  getReturnsForBill,
} from '@/server/services/purchases/purchase-return-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { PurchaseBillEditor } from '@/components/purchases/purchase-bill-editor';
import { ReceiptLinesPicker } from '@/components/purchases/purchase-order-forms';
import { getUnbilledReceiptLines } from '@/server/services/purchases/purchase-order-service';
import { getTdsPreview } from '@/server/services/accounting/tds-service';
import { setBillTdsModeAction } from '@/server/services/accounting/tds-actions';
import { ActionForm } from '@/components/forms/action-form';
import { PurchaseReturnForm } from '@/components/purchases/purchase-return-form';
import { AttachmentsPanel } from '@/components/attachments/attachments-panel';
import { Panel, PanelContent, PanelHeader, PanelTitle } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { add, formatINR, fromRupees, subtract, ZERO } from '@/lib/money';
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
    return: hasPermission(context, 'purchases.return'),
  };

  // Only a draft can gain lines, so the pickers are only worth loading for one;
  // only a posted bill can be returned against, so the same holds there.
  const [vehicles, pickers, returnable, notes, gstRates, receiptLines, tds] = await Promise.all([
    bill.status === 'DRAFT' && can.edit
      ? getUnbilledVehicles({ branchId: bill.branchId })
      : Promise.resolve([]),
    bill.status === 'DRAFT' && can.edit
      ? getPurchasePickers()
      : Promise.resolve({ suppliers: [], items: [], accounts: [] }),
    bill.status === 'POSTED' && can.return
      ? getReturnableLines(bill.id)
      : Promise.resolve([]),
    bill.status === 'DRAFT' ? Promise.resolve([]) : getReturnsForBill(bill.id),
    // From the tax master, never a list written into the editor (spec §16).
    bill.status === 'DRAFT' && can.edit ? getPurchaseGstRates() : Promise.resolve([]),
    // Goods already received from this supplier, waiting for their bill (0092).
    bill.status === 'DRAFT' && can.edit ? getUnbilledReceiptLines(bill.supplierId, bill.branchId) : Promise.resolve([]),
    // What the bill will deduct as TDS when posted, or why it cannot post (0093).
    bill.status === 'DRAFT' ? getTdsPreview(bill.id) : Promise.resolve({ preview: null, problem: null }),
  ]);

  // Reversed notes took nothing back, so they do not count against the bill.
  const returned = notes
    .filter((note) => note.status === 'POSTED')
    .reduce((running, note) => add(running, note.totalAmount), ZERO);

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
          <AttachmentsPanel entityType="PURCHASE_BILL" entityId={bill.id} revalidate={`/purchases/${bill.id}`} />

          {bill.status === 'DRAFT' && can.edit && <ReceiptLinesPicker billId={bill.id} lines={receiptLines} />}

          <PurchaseBillEditor
            gstRates={gstRates}
            bill={bill}
            unbilledVehicles={vehicles}
            items={pickers.items}
            accounts={pickers.accounts}
            can={can}
          />

          {bill.status === 'POSTED' && can.return && (
            <PurchaseReturnForm
              billId={bill.id}
              billNumber={bill.billNumber}
              supplierName={bill.supplierName}
              lines={returnable}
            />
          )}

          {notes.length > 0 && (
            <Panel>
              <PanelHeader><PanelTitle>Returned to the supplier</PanelTitle></PanelHeader>
              <PanelContent>
                <ul className="divide-y divide-ink-100">
                  {notes.map((note) => (
                    <li key={note.id} className="flex flex-wrap items-baseline justify-between gap-2 py-2 first:pt-0 last:pb-0">
                      <span className="min-w-0">
                        <Link href={`/purchases/returns/${note.id}`} className="font-mono text-xs text-brand-600 hover:underline">
                          {note.returnNumber}
                        </Link>
                        <span className="ml-2 text-xs text-ink-500">{formatDate(note.returnDate)}</span>
                        <span className="block truncate text-xs text-ink-600">{note.reason}</span>
                      </span>
                      <span className="flex items-center gap-2">
                        <Badge variant={note.status === 'POSTED' ? 'warning' : 'neutral'}>
                          {note.status === 'CANCELLED' ? 'REVERSED' : 'RETURNED'}
                        </Badge>
                        <span className={`numeric text-sm ${note.status === 'POSTED' ? 'text-ink-900' : 'text-ink-400 line-through'}`}>
                          {formatINR(note.totalAmount)}
                        </span>
                      </span>
                    </li>
                  ))}
                </ul>
              </PanelContent>
            </Panel>
          )}
        </div>

        <div className="space-y-4">
          {bill.status === 'DRAFT' && (tds.preview || tds.problem || bill.tdsMode === 'NONE') && (
            <Panel>
              <PanelHeader><PanelTitle>TDS</PanelTitle></PanelHeader>
              <PanelContent>
                {tds.problem && <p role="alert" className="mb-2 rounded-lg bg-danger-50 px-3 py-2 text-xs text-danger-700">{tds.problem}</p>}
                {tds.preview && (
                  <dl className="space-y-2">
                    <Row label={`${tds.preview.sectionRef}`} value={`${tds.preview.rate}%`} />
                    <Row label="Deducted on" value={formatINR(fromRupees(tds.preview.deductibleBase))} />
                    <Row label="TDS kept back" value={formatINR(fromRupees(tds.preview.amount))} strong />
                  </dl>
                )}
                {bill.tdsMode === 'NONE' && <p className="text-xs text-ink-600">Marked as bearing no TDS.</p>}
                {can.edit && (
                  <div className="mt-3">
                    <ActionForm fields={[]} fixed={{ billId: bill.id, mode: bill.tdsMode === 'NONE' ? 'AUTO' : 'NONE' }}
                      action={setBillTdsModeAction} columns={1}
                      submitLabel={bill.tdsMode === 'NONE' ? 'Apply TDS to this bill' : 'This bill bears no TDS'} />
                  </div>
                )}
              </PanelContent>
            </Panel>
          )}

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
                {returned > 0 && (
                  // What the bill charged is a fact and never changes; what is
                  // still owed on it is the figure someone is actually asking for.
                  <div className="border-t border-ink-200 pt-2.5">
                    <Row label="Returned since" value={`− ${formatINR(returned)}`} />
                    <Row label="Net of returns" value={formatINR(subtract(bill.totalAmount, returned))} strong />
                  </div>
                )}
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
