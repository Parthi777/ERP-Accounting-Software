'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, PackageCheck, Plus, Save, Trash2 } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { SearchSelect } from '@/components/forms/search-select';
import { QuickAdd } from '@/components/forms/quick-add';
import { useIdempotencyKey } from '@/components/forms/use-idempotency-key';
import {
  addReceiptLinesToBillAction,
  createPurchaseOrderAction,
  postGoodsReceiptAction,
} from '@/server/services/purchases/purchase-order-actions';

const inr = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', minimumFractionDigits: 2 });

function ErrorNote({ error }: { readonly error: string | null }) {
  return error ? <p role="alert" className="rounded-xl bg-danger-50 px-3 py-2 text-sm text-danger-700">{error}</p> : null;
}

// ─────────────────────────────────────────────────────────────────────────────
// Raise an order
// ─────────────────────────────────────────────────────────────────────────────

interface OrderLine {
  key: number;
  itemId: string;
  source: 'LOCAL' | 'COMPANY';
  quantity: string;
  unitRate: string;
  gstRate: string;
  unit: string;
}

/** A purchase order (F33): supplier, dates and the items wanted, at what rate. Posts nothing. */
export function PurchaseOrderForm({
  suppliers,
  items,
  gstRates,
  itemUnits = {},
}: {
  readonly suppliers: readonly { id: string; label: string }[];
  readonly items: readonly { id: string; label: string; standardCost: number }[];
  readonly gstRates: readonly number[];
  /** Each item's base unit and pack sizes (0094). */
  readonly itemUnits?: Readonly<Record<string, { base: string; packs: readonly { unit: string; factor: number }[] }>>;
}) {
  const router = useRouter();
  const idempotency = useIdempotencyKey('purchase-order');
  const today = new Date().toISOString().slice(0, 10);
  const [supplierId, setSupplierId] = React.useState('');
  const [orderDate, setOrderDate] = React.useState(today);
  const [expectedDate, setExpectedDate] = React.useState('');
  const [interState, setInterState] = React.useState(false);
  const [notes, setNotes] = React.useState('');
  const nextKey = React.useRef(2);
  const blank = (key: number): OrderLine => ({ key, itemId: '', source: 'COMPANY', quantity: '', unitRate: '', gstRate: String(gstRates.at(-1) ?? 18), unit: '' });
  const [lines, setLines] = React.useState<OrderLine[]>([blank(1)]);
  const [error, setError] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  const set = (key: number, patch: Partial<OrderLine>) => setLines((cur) => cur.map((l) => (l.key === key ? { ...l, ...patch } : l)));
  const taxable = lines.reduce((s, l) => s + (Number(l.quantity) || 0) * (Number(l.unitRate) || 0), 0);
  const tax = lines.reduce((s, l) => s + ((Number(l.quantity) || 0) * (Number(l.unitRate) || 0) * (Number(l.gstRate) || 0)) / 100, 0);

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);
    if (!supplierId) return setError('Choose the supplier.');
    const bad = lines.findIndex((l) => !l.itemId || !(Number(l.quantity) > 0) || !(Number(l.unitRate) >= 0) || l.unitRate === '');
    if (bad >= 0) return setError(`Line ${bad + 1}: choose the item and enter a quantity and a rate.`);
    startTransition(async () => {
      const result = await createPurchaseOrderAction({
        supplierId,
        orderDate,
        expectedDate: expectedDate || null,
        notes: notes || null,
        lines: lines.map((l) => ({
          itemId: l.itemId, source: l.source, quantity: Number(l.quantity), unitRate: Number(l.unitRate),
          gstRate: Number(l.gstRate) || 0, interState, unit: l.unit || null,
        })),
        idempotencyKey: idempotency.key(),
      });
      if (!result.ok) return setError(result.error ?? 'The order could not be raised.');
      idempotency.renew();
      router.push(`/purchases/orders/${result.id}`);
    });
  };

  return (
    <form onSubmit={submit} className="space-y-4" noValidate>
      <Panel className="grid gap-4 p-5 sm:grid-cols-2 lg:grid-cols-4">
        <div className="sm:col-span-2">
          <Label htmlFor="po-supplier" className="mb-1.5 block">Supplier<span className="ml-0.5 text-danger-600">*</span><QuickAdd href="/masters/suppliers/new" noun="supplier" /></Label>
          <SearchSelect id="po-supplier" name="supplier" options={suppliers} defaultValue={supplierId}
            placeholder="Search suppliers…" onChange={setSupplierId} />
        </div>
        <div>
          <Label htmlFor="po-date" className="mb-1.5 block">Order date</Label>
          <Input id="po-date" type="date" value={orderDate} onChange={(e) => setOrderDate(e.target.value)} />
        </div>
        <div>
          <Label htmlFor="po-expected" className="mb-1.5 block">Expected by</Label>
          <Input id="po-expected" type="date" value={expectedDate} min={orderDate} onChange={(e) => setExpectedDate(e.target.value)} />
        </div>
        <label className="flex items-center gap-2 text-sm text-ink-700 sm:col-span-2">
          <input type="checkbox" checked={interState} onChange={(e) => setInterState(e.target.checked)} />
          Supplier is in another state (IGST)
        </label>
        <div className="sm:col-span-2">
          <Label htmlFor="po-notes" className="mb-1.5 block">Notes</Label>
          <Input id="po-notes" value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="Optional" />
        </div>
      </Panel>

      <Panel className="space-y-3 p-5">
        <h2 className="text-sm font-semibold text-ink-900">Items<QuickAdd href="/masters/spares/new" noun="item" /></h2>
        {lines.map((line, index) => (
          <div key={line.key} className="grid gap-2 sm:grid-cols-[1fr_7rem_6rem_7rem_6rem_auto] sm:items-end">
            <div>
              <Label htmlFor={`po-item-${line.key}`} className="mb-1 block text-xs">Item {index + 1}</Label>
              <SearchSelect id={`po-item-${line.key}`} name={`item-${line.key}`} options={items} defaultValue={line.itemId}
                placeholder="Search accessories and spares…"
                onChange={(v) => set(line.key, {
                  itemId: v,
                  unit: itemUnits[v]?.base ?? '',
                  unitRate: line.unitRate || String(items.find((i) => i.id === v)?.standardCost ?? ''),
                })} />
              {line.itemId && (itemUnits[line.itemId]?.packs.length ?? 0) > 0 && (
                <select aria-label={`Unit for line ${index + 1}`} value={line.unit} className="field mt-1 h-8 w-full px-2 text-xs"
                  onChange={(e) => set(line.key, { unit: e.target.value })}>
                  <option value={itemUnits[line.itemId]!.base}>{itemUnits[line.itemId]!.base}</option>
                  {itemUnits[line.itemId]!.packs.map((p) => (
                    <option key={p.unit} value={p.unit}>{p.unit} of {p.factor} {itemUnits[line.itemId]!.base}</option>
                  ))}
                </select>
              )}
            </div>
            <div>
              <Label htmlFor={`po-src-${line.key}`} className="mb-1 block text-xs">Stock lot</Label>
              <select id={`po-src-${line.key}`} value={line.source} className="field h-10 w-full px-2 text-sm"
                onChange={(e) => set(line.key, { source: e.target.value as 'LOCAL' | 'COMPANY' })}>
                <option value="COMPANY">Company</option>
                <option value="LOCAL">Local</option>
              </select>
            </div>
            <div>
              <Label htmlFor={`po-qty-${line.key}`} className="mb-1 block text-xs">Quantity</Label>
              <Input id={`po-qty-${line.key}`} type="number" min="0" step="1" className="numeric" value={line.quantity}
                onChange={(e) => set(line.key, { quantity: e.target.value })} />
            </div>
            <div>
              <Label htmlFor={`po-rate-${line.key}`} className="mb-1 block text-xs">Rate (before GST)</Label>
              <Input id={`po-rate-${line.key}`} type="number" min="0" step="0.01" className="numeric" value={line.unitRate}
                onChange={(e) => set(line.key, { unitRate: e.target.value })} />
            </div>
            <div>
              <Label htmlFor={`po-gst-${line.key}`} className="mb-1 block text-xs">GST %</Label>
              <select id={`po-gst-${line.key}`} value={line.gstRate} className="field h-10 w-full px-2 text-sm"
                onChange={(e) => set(line.key, { gstRate: e.target.value })}>
                {gstRates.map((r) => <option key={r} value={r}>{r}%</option>)}
              </select>
            </div>
            <Button type="button" variant="ghost" size="sm" aria-label={`Remove line ${index + 1}`} disabled={lines.length === 1}
              onClick={() => setLines((cur) => cur.filter((l) => l.key !== line.key))}>
              <Trash2 aria-hidden />
            </Button>
          </div>
        ))}
        <Button type="button" variant="secondary" size="sm" onClick={() => setLines((cur) => [...cur, blank(nextKey.current++)])}>
          <Plus aria-hidden />Add item
        </Button>
        <div className="flex justify-end gap-6 border-t border-ink-100 pt-3 text-sm">
          <span className="text-ink-500">Taxable <span className="numeric font-semibold text-ink-900">{inr.format(taxable)}</span></span>
          <span className="text-ink-500">GST (estimate) <span className="numeric font-semibold text-ink-900">{inr.format(tax)}</span></span>
        </div>
      </Panel>

      <ErrorNote error={error} />
      <Button type="submit" disabled={pending}>
        {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Save aria-hidden />}
        Raise purchase order
      </Button>
    </form>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Receive goods
// ─────────────────────────────────────────────────────────────────────────────

/** A goods receipt (F34–F36): what arrived against the order, with the challan and transport. */
export function GoodsReceiptForm({
  orderId,
  orderDate,
  lines,
}: {
  readonly orderId: string;
  readonly orderDate: string;
  readonly lines: readonly { id: string; description: string; pending: number; unitRate: number }[];
}) {
  const router = useRouter();
  const idempotency = useIdempotencyKey(`goods-receipt:${orderId}`);
  const [qty, setQty] = React.useState<Record<string, string>>(() =>
    Object.fromEntries(lines.map((l) => [l.id, String(l.pending)])));
  const [date, setDate] = React.useState(new Date().toISOString().slice(0, 10));
  const [t, setT] = React.useState({ supplierChallanNumber: '', transporter: '', lrNumber: '', vehicleNumber: '', origin: '', originPincode: '' });
  const [error, setError] = React.useState<string | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();
  const value = lines.reduce((s, l) => s + (Number(qty[l.id]) || 0) * l.unitRate, 0);

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);
    setNotice(null);
    const over = lines.find((l) => (Number(qty[l.id]) || 0) > l.pending);
    if (over) return setError(`${over.description}: only ${over.pending} still to come.`);
    if (!confirm('Post this goods receipt? Stock comes in now and GRNI is credited.')) return;
    startTransition(async () => {
      const result = await postGoodsReceiptAction({
        orderId,
        receiptDate: date,
        lines: lines.map((l) => ({ poLineId: l.id, quantity: Number(qty[l.id]) || 0 })),
        transport: t,
        idempotencyKey: idempotency.key(),
      });
      if (!result.ok) return setError(result.error ?? 'The receipt could not be posted.');
      idempotency.renew();
      setNotice(result.message ?? 'Received.');
      router.refresh();
    });
  };

  const field = (key: keyof typeof t, label: string, placeholder = '') => (
    <div>
      <Label htmlFor={`grn-${key}`} className="mb-1 block text-xs">{label}</Label>
      <Input id={`grn-${key}`} value={t[key]} placeholder={placeholder} onChange={(e) => setT((cur) => ({ ...cur, [key]: e.target.value }))} />
    </div>
  );

  return (
    <form onSubmit={submit} className="space-y-4" noValidate>
      <table className="w-full text-sm">
        <thead>
          <tr className="text-[11px] uppercase tracking-wide text-ink-500">
            <th className="py-1 text-left font-semibold">Item</th>
            <th className="py-1 text-right font-semibold">Still to come</th>
            <th className="py-1 text-right font-semibold">Received now</th>
          </tr>
        </thead>
        <tbody>
          {lines.map((l) => (
            <tr key={l.id} className="border-t border-ink-100">
              <td className="py-1.5 text-ink-800">{l.description}</td>
              <td className="numeric py-1.5">{l.pending}</td>
              <td className="py-1.5 text-right">
                <Input type="number" min="0" max={l.pending} step="1" className="numeric ml-auto w-24" aria-label={`Received now: ${l.description}`}
                  value={qty[l.id] ?? ''} onChange={(e) => setQty((cur) => ({ ...cur, [l.id]: e.target.value }))} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      <div className="grid gap-3 sm:grid-cols-3">
        <div>
          <Label htmlFor="grn-date" className="mb-1 block text-xs">Received on</Label>
          <Input id="grn-date" type="date" value={date} min={orderDate} onChange={(e) => setDate(e.target.value)} />
        </div>
        {field('supplierChallanNumber', "Supplier's challan no.")}
        {field('transporter', 'Transporter')}
        {field('lrNumber', 'LR / consignment no.')}
        {field('vehicleNumber', 'Vehicle no.', 'TN09AB1234')}
        {field('origin', 'Dispatched from')}
        {field('originPincode', 'From PIN')}
      </div>

      <p className="text-xs text-ink-500">Value at the order rate: <span className="numeric font-semibold text-ink-800">{inr.format(value)}</span></p>
      <ErrorNote error={error} />
      {notice && <p className="rounded-xl bg-positive-50 px-3 py-2 text-sm text-positive-700">{notice}</p>}
      <Button type="submit" disabled={pending}>
        {pending ? <Loader2 className="animate-spin" aria-hidden /> : <PackageCheck aria-hidden />}
        Post goods receipt
      </Button>
    </form>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Bill received goods
// ─────────────────────────────────────────────────────────────────────────────

/**
 * On a draft bill: the supplier's received-but-unbilled lines (F37). Ticked
 * lines join the bill pointing at their receipt, so posting clears GRNI and
 * adds no stock. The rate is the supplier's; any difference from the order
 * rate goes to price variance.
 */
export function ReceiptLinesPicker({
  billId,
  lines,
}: {
  readonly billId: string;
  readonly lines: readonly { grnLineId: string; grnNumber: string; poNumber: string; description: string; unbilled: number; unitCost: number }[];
}) {
  const router = useRouter();
  const [chosen, setChosen] = React.useState<Record<string, { on: boolean; qty: string; rate: string }>>(() =>
    Object.fromEntries(lines.map((l) => [l.grnLineId, { on: false, qty: String(l.unbilled), rate: String(l.unitCost) }])));
  const [error, setError] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  if (lines.length === 0) return null;

  const submit = () => {
    setError(null);
    const picked = lines
      .filter((l) => chosen[l.grnLineId]?.on)
      .map((l) => ({ grnLineId: l.grnLineId, quantity: Number(chosen[l.grnLineId]?.qty) || 0, unitRate: Number(chosen[l.grnLineId]?.rate) || 0 }));
    if (picked.length === 0) return setError('Tick the receipt lines this bill covers.');
    startTransition(async () => {
      const result = await addReceiptLinesToBillAction(billId, picked);
      if (!result.ok) return setError(result.error ?? 'The lines could not be added.');
      router.refresh();
    });
  };

  return (
    <Panel className="p-5">
      <h2 className="text-sm font-semibold text-ink-900">Goods received from this supplier, not yet billed</h2>
      <p className="mb-3 text-xs text-ink-500">
        Tick what this bill is for. These lines add no stock — the receipt already did — and clear Goods Received Not Invoiced.
      </p>
      <table className="w-full text-sm">
        <thead>
          <tr className="text-[11px] uppercase tracking-wide text-ink-500">
            <th className="py-1" />
            <th className="py-1 text-left font-semibold">Receipt</th>
            <th className="py-1 text-left font-semibold">Item</th>
            <th className="py-1 text-right font-semibold">Qty</th>
            <th className="py-1 text-right font-semibold">Bill rate</th>
          </tr>
        </thead>
        <tbody>
          {lines.map((l) => {
            type Choice = { on: boolean; qty: string; rate: string };
            const c: Choice = chosen[l.grnLineId] ?? { on: false, qty: String(l.unbilled), rate: String(l.unitCost) };
            const upd = (patch: Partial<Choice>) => setChosen((cur) => ({ ...cur, [l.grnLineId]: { ...c, ...cur[l.grnLineId], ...patch } }));
            return (
              <tr key={l.grnLineId} className="border-t border-ink-100">
                <td className="py-1.5"><input type="checkbox" aria-label={`Bill ${l.description}`} checked={c.on} onChange={(e) => upd({ on: e.target.checked })} /></td>
                <td className="py-1.5 font-mono text-xs">{l.grnNumber}<span className="block text-[10px] text-ink-400">{l.poNumber}</span></td>
                <td className="py-1.5 text-ink-800">{l.description}</td>
                <td className="py-1.5 text-right">
                  <Input type="number" min="0" max={l.unbilled} className="numeric ml-auto w-20" aria-label={`Quantity: ${l.description}`}
                    value={c.qty} onChange={(e) => upd({ qty: e.target.value })} />
                </td>
                <td className="py-1.5 text-right">
                  <Input type="number" min="0" step="0.01" className="numeric ml-auto w-28" aria-label={`Rate: ${l.description}`}
                    value={c.rate} onChange={(e) => upd({ rate: e.target.value })} />
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
      <div className="mt-3 space-y-2">
        <ErrorNote error={error} />
        <Button type="button" size="sm" variant="secondary" disabled={pending} onClick={submit}>
          {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Plus aria-hidden />}
          Add to bill
        </Button>
      </div>
    </Panel>
  );
}
