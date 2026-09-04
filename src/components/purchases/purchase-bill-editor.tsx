'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, Plus, Trash2 } from 'lucide-react';

import type {
  PurchaseBill,
  PurchaseLineType,
  StockSource,
  UnbilledVehicle,
} from '@/server/services/purchases/purchase-service';
import {
  addPurchaseLineAction,
  cancelPurchaseBillAction,
  postPurchaseBillAction,
  removePurchaseLineAction,
} from '@/server/services/purchases/purchase-actions';
import { Panel, SolidPanel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Input, Label } from '@/components/ui/input';
import { add, formatINR, fromRupees, ZERO, type Paise } from '@/lib/money';

/**
 * Building and posting a purchase bill — spec §21, §24, §28, §34, §48.
 *
 * Lines are added one at a time against a draft, because a vehicle line has to
 * choose a specific chassis out of stock and an accessory line has to choose
 * which lot — LOCAL or COMPANY — the quantity joins (spec §28). Neither is a
 * thing a grid of free-text fields can get right.
 *
 * Tax is shown here as the operator types, but it is computed again on the
 * server before anything is written: a client-supplied tax figure is one the
 * dealer would have to defend without knowing where it came from (spec §16).
 */
export function PurchaseBillEditor({
  bill,
  unbilledVehicles,
  items,
  can,
}: {
  readonly bill: PurchaseBill;
  readonly unbilledVehicles: readonly UnbilledVehicle[];
  readonly items: readonly { id: string; label: string; type: PurchaseLineType; standardCost: number }[];
  readonly can: { readonly edit: boolean; readonly post: boolean; readonly cancel: boolean };
}) {
  const router = useRouter();
  const [error, setError] = React.useState<string | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();
  const [dialog, setDialog] = React.useState<'cancel' | null>(null);
  const [reason, setReason] = React.useState('');

  const draft = bill.status === 'DRAFT';
  const editable = draft && can.edit;

  const run = (fn: () => Promise<{ ok: boolean; error?: string; message?: string }>) => {
    setError(null);
    setNotice(null);
    startTransition(async () => {
      const result = await fn();
      if (!result.ok) {
        setError(result.error ?? 'That could not be done.');
        return;
      }
      setNotice(result.message ?? null);
      setDialog(null);
      setReason('');
      router.refresh();
    });
  };

  return (
    <div className="space-y-4">
      {error && (
        <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
          {error}
        </div>
      )}
      {notice && (
        <div role="status" className="rounded-lg border border-positive-200 bg-positive-50 px-3 py-2 text-sm text-positive-700">
          {notice}
        </div>
      )}

      {editable && (
        <AddLine
          billId={bill.id}
          unbilledVehicles={unbilledVehicles}
          items={items}
          pending={pending}
          onAdd={(input) => run(() => addPurchaseLineAction(input))}
        />
      )}

      <Lines bill={bill} editable={editable} pending={pending}
        onRemove={(lineId) => run(() => removePurchaseLineAction(lineId, bill.id))} />

      <div className="flex flex-wrap items-center gap-2">
        {draft && can.post && (
          <Button
            disabled={pending || bill.lines.length === 0}
            onClick={() => run(() => postPurchaseBillAction(bill.id))}
          >
            {pending && <Loader2 className="animate-spin" aria-hidden />}
            Post to accounts
          </Button>
        )}
        {bill.status !== 'CANCELLED' && can.cancel && (
          <Button variant="danger" size="sm" disabled={pending} onClick={() => setDialog('cancel')}>
            {draft ? 'Discard draft' : 'Cancel and reverse'}
          </Button>
        )}
        {draft && can.post && (
          <p className="text-xs text-ink-500">
            Posting writes the journal, capitalises the chassis and moves the counted stock — all in
            one transaction. Any failure leaves the draft as it was.
          </p>
        )}
      </div>

      {dialog === 'cancel' && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
          role="dialog" aria-modal="true" onClick={() => setDialog(null)}>
          <div className="glass-strong w-full max-w-md rounded-2xl p-6" onClick={(e) => e.stopPropagation()}>
            <h2 className="text-sm font-semibold text-ink-900">
              {draft ? `Discard draft ${bill.billNumber}?` : `Cancel ${bill.billNumber}?`}
            </h2>
            <p className="mt-1 text-sm text-ink-600">
              {draft
                ? 'The draft never reached the ledger, so it is simply removed. Any chassis on it become available to bill again.'
                : 'The journal is reversed by a second entry and the stock this bill brought in is taken back out. The bill itself stays on the record.'}
            </p>
            <label className="mt-4 block">
              <span className="text-sm font-medium text-ink-700">
                Reason<span className="ml-0.5 text-danger-600">*</span>
              </span>
              <textarea rows={3} value={reason} onChange={(e) => setReason(e.target.value)}
                placeholder="e.g. Supplier raised a corrected invoice"
                className="mt-1 w-full rounded-lg border border-ink-200 bg-white px-3 py-2 text-sm shadow-sm" />
            </label>
            <div className="mt-4 flex justify-end gap-2">
              <Button variant="secondary" size="sm" onClick={() => setDialog(null)} disabled={pending}>Back</Button>
              <Button variant="danger" size="sm" disabled={pending || !reason.trim()}
                onClick={() => run(() => cancelPurchaseBillAction(bill.id, reason))}>
                {pending && <Loader2 className="animate-spin" aria-hidden />}
                {draft ? 'Discard' : 'Cancel bill'}
              </Button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

/** Standard GST splits a dealer actually buys at. */
const GST_RATES = [0, 5, 12, 18, 28];

function AddLine({
  billId,
  unbilledVehicles,
  items,
  pending,
  onAdd,
}: {
  readonly billId: string;
  readonly unbilledVehicles: readonly UnbilledVehicle[];
  readonly items: readonly { id: string; label: string; type: PurchaseLineType; standardCost: number }[];
  readonly pending: boolean;
  readonly onAdd: (input: {
    billId: string;
    lineType: PurchaseLineType;
    vehicleId?: string | null;
    itemId?: string | null;
    source?: StockSource | null;
    description: string;
    quantity: number;
    unitRate: number;
    cgstRate: number;
    sgstRate: number;
    igstRate: number;
  }) => void;
}) {
  const [lineType, setLineType] = React.useState<PurchaseLineType>('VEHICLE');
  const [vehicleId, setVehicleId] = React.useState('');
  const [itemId, setItemId] = React.useState('');
  const [source, setSource] = React.useState<StockSource>('COMPANY');
  const [quantity, setQuantity] = React.useState('1');
  const [rate, setRate] = React.useState('');
  const [gst, setGst] = React.useState(28);
  const [interState, setInterState] = React.useState(false);

  const isVehicle = lineType === 'VEHICLE';
  const vehicle = unbilledVehicles.find((v) => v.vehicleId === vehicleId);
  const item = items.find((i) => i.id === itemId);
  const pickable = items.filter((i) => i.type === lineType);

  const qty = isVehicle ? 1 : Number(quantity) || 0;
  const rateValue = Number(rate) || 0;
  const taxable = fromRupees(rateValue * qty);
  const tax = fromRupees((rateValue * qty * gst) / 100);

  const reset = () => {
    setVehicleId('');
    setItemId('');
    setQuantity('1');
    setRate('');
  };

  const submit = () => {
    const description = isVehicle
      ? `${vehicle?.modelLabel ?? 'Vehicle'} — ${vehicle?.chassisNo ?? ''}`.trim()
      : (item?.label ?? 'Item');

    onAdd({
      billId,
      lineType,
      vehicleId: isVehicle ? vehicleId : null,
      itemId: isVehicle ? null : itemId,
      source: isVehicle ? null : source,
      description,
      quantity: qty,
      unitRate: rateValue,
      // Intra-state splits in half; inter-state is one IGST figure (spec §16).
      cgstRate: interState ? 0 : gst / 2,
      sgstRate: interState ? 0 : gst / 2,
      igstRate: interState ? gst : 0,
    });
    reset();
  };

  const ready = isVehicle ? Boolean(vehicleId) && rateValue > 0 : Boolean(itemId) && qty > 0 && rateValue > 0;

  return (
    <Panel className="p-4">
      <h2 className="mb-3 text-sm font-semibold text-ink-900">Add a line</h2>

      <div className="mb-3 flex flex-wrap gap-1.5">
        {(['VEHICLE', 'ACCESSORY', 'SPARE'] as const).map((t) => (
          <Button
            key={t}
            type="button"
            size="sm"
            variant={lineType === t ? 'primary' : 'secondary'}
            onClick={() => { setLineType(t); reset(); setGst(t === 'VEHICLE' ? 28 : 18); }}
          >
            {t === 'VEHICLE' ? 'Vehicle' : t === 'ACCESSORY' ? 'Accessory' : 'Spare'}
          </Button>
        ))}
      </div>

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {isVehicle ? (
          <div className="sm:col-span-2">
            <Label htmlFor="line-vehicle" className="mb-1.5 block">Chassis</Label>
            <select id="line-vehicle" value={vehicleId} onChange={(e) => {
              setVehicleId(e.target.value);
              const v = unbilledVehicles.find((x) => x.vehicleId === e.target.value);
              if (v && v.purchaseCost > 0 && !rate) setRate(String(v.purchaseCost / 100));
            }}
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
              <option value="">Choose a chassis in stock</option>
              {unbilledVehicles.map((v) => (
                <option key={v.vehicleId} value={v.vehicleId}>
                  {v.chassisNo} · {v.modelLabel} · {v.branchName}
                </option>
              ))}
            </select>
            <p className="mt-1 text-xs text-ink-400">
              {unbilledVehicles.length === 0
                ? 'Every chassis in stock is already on a bill. Upload stock first (Vehicles → Stock Upload).'
                : `${unbilledVehicles.length} chassis in stock and not yet billed.`}
            </p>
          </div>
        ) : (
          <>
            <div className="sm:col-span-2">
              <Label htmlFor="line-item" className="mb-1.5 block">Item</Label>
              <select id="line-item" value={itemId} onChange={(e) => {
                setItemId(e.target.value);
                const i = items.find((x) => x.id === e.target.value);
                if (i && i.standardCost > 0 && !rate) setRate(String(i.standardCost));
              }}
                className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
                <option value="">Choose an item</option>
                {pickable.map((i) => <option key={i.id} value={i.id}>{i.label}</option>)}
              </select>
            </div>
            <div>
              <Label htmlFor="line-source" className="mb-1.5 block">Lot</Label>
              <select id="line-source" value={source} onChange={(e) => setSource(e.target.value as StockSource)}
                className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
                <option value="COMPANY">Company</option>
                <option value="LOCAL">Local</option>
              </select>
              {/* Spec §28: the two lots never merge, so the bill has to say which. */}
              <p className="mt-1 text-xs text-ink-400">Kept separate from the other lot.</p>
            </div>
          </>
        )}

        {!isVehicle && (
          <div>
            <Label htmlFor="line-qty" className="mb-1.5 block">Quantity</Label>
            <Input id="line-qty" type="number" step="0.001" min="0" value={quantity}
              onChange={(e) => setQuantity(e.target.value)} />
          </div>
        )}

        <div>
          <Label htmlFor="line-rate" className="mb-1.5 block">Rate (before GST)</Label>
          <div className="relative">
            <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-ink-400">₹</span>
            <Input id="line-rate" type="number" step="0.01" min="0" className="pl-7"
              value={rate} onChange={(e) => setRate(e.target.value)} />
          </div>
        </div>

        <div>
          <Label htmlFor="line-gst" className="mb-1.5 block">GST</Label>
          <select id="line-gst" value={gst} onChange={(e) => setGst(Number(e.target.value))}
            className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
            {GST_RATES.map((r) => <option key={r} value={r}>{r}%</option>)}
          </select>
          <label className="mt-1.5 flex items-center gap-1.5 text-xs text-ink-500">
            <input type="checkbox" checked={interState} onChange={(e) => setInterState(e.target.checked)} />
            Inter-state (IGST)
          </label>
        </div>
      </div>

      <div className="mt-4 flex flex-wrap items-center justify-between gap-3 rounded-lg border border-brand-200 bg-brand-50 px-4 py-2.5">
        <div className="flex flex-wrap gap-x-6 gap-y-1 text-xs text-brand-800">
          <span>Taxable <span className="numeric font-semibold">{formatINR(taxable)}</span></span>
          <span>GST <span className="numeric font-semibold">{formatINR(tax)}</span></span>
          <span>Line total <span className="numeric font-semibold">{formatINR(add(taxable, tax))}</span></span>
        </div>
        <Button type="button" size="sm" disabled={pending || !ready} onClick={submit}>
          {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Plus aria-hidden />}
          Add line
        </Button>
      </div>
    </Panel>
  );
}

function Lines({
  bill,
  editable,
  pending,
  onRemove,
}: {
  readonly bill: PurchaseBill;
  readonly editable: boolean;
  readonly pending: boolean;
  readonly onRemove: (lineId: string) => void;
}) {
  const tone: Record<string, 'info' | 'positive' | 'accent'> = {
    VEHICLE: 'info',
    ACCESSORY: 'positive',
    SPARE: 'accent',
  };

  return (
    <SolidPanel className="overflow-hidden">
      <div className="overflow-x-auto">
        <table className="w-full border-collapse text-sm">
          <caption className="sr-only">Purchase bill lines</caption>
          <thead>
            <tr className="bg-ink-50">
              <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">What</th>
              <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Qty</th>
              <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Rate</th>
              <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Taxable</th>
              <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">GST</th>
              <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Total</th>
              {editable && <th scope="col" className="px-4 py-2.5" />}
            </tr>
          </thead>
          <tbody>
            {bill.lines.length === 0 ? (
              <tr>
                <td colSpan={editable ? 7 : 6} className="px-4 py-10 text-center text-sm text-ink-400">
                  No lines yet. A bill with nothing on it cannot be posted.
                </td>
              </tr>
            ) : (
              bill.lines.map((line) => {
                const tax = add(line.cgstAmount, line.sgstAmount, line.igstAmount) as Paise;
                return (
                  <tr key={line.id} className="border-t border-ink-100">
                    <td className="px-4 py-2">
                      <span className="flex flex-wrap items-center gap-2">
                        <Badge variant={tone[line.lineType] ?? 'neutral'}>{line.lineType}</Badge>
                        <span className="text-ink-800">{line.description}</span>
                        {line.source && <Badge variant="neutral">{line.source}</Badge>}
                      </span>
                      {(line.chassisNo || line.itemCode) && (
                        <span className="mt-0.5 block font-mono text-[11px] text-ink-400">
                          {line.chassisNo ?? line.itemCode}
                        </span>
                      )}
                    </td>
                    <td className="numeric px-4 py-2 text-right">{line.quantity}</td>
                    <td className="numeric px-4 py-2 text-right">{formatINR(line.unitRate)}</td>
                    <td className="numeric px-4 py-2 text-right">{formatINR(line.taxableValue)}</td>
                    <td className="numeric px-4 py-2 text-right text-ink-500">
                      {tax > 0 ? formatINR(tax) : <span className="text-ink-300">—</span>}
                    </td>
                    <td className="numeric px-4 py-2 text-right font-medium">{formatINR(line.totalAmount)}</td>
                    {editable && (
                      <td className="px-4 py-2 text-right">
                        <Button variant="ghost" size="sm" disabled={pending}
                          aria-label={`Remove line ${line.lineNumber}`}
                          onClick={() => onRemove(line.id)}>
                          <Trash2 aria-hidden />
                        </Button>
                      </td>
                    )}
                  </tr>
                );
              })
            )}
          </tbody>
          {bill.lines.length > 0 && (
            <tfoot>
              <tr className="border-t-2 border-ink-200 bg-ink-50/60">
                <td className="px-4 py-2.5 text-xs font-semibold uppercase tracking-wide text-ink-500" colSpan={3}>
                  Bill total
                </td>
                <td className="numeric px-4 py-2.5 text-right font-semibold">{formatINR(bill.taxableValue)}</td>
                <td className="numeric px-4 py-2.5 text-right font-semibold">
                  {formatINR(bill.taxAmount ?? ZERO)}
                </td>
                <td className="numeric px-4 py-2.5 text-right font-bold text-ink-900">
                  {formatINR(bill.totalAmount)}
                </td>
                {editable && <td />}
              </tr>
            </tfoot>
          )}
        </table>
      </div>
    </SolidPanel>
  );
}
