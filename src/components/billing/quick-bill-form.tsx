'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { CheckCircle2, Loader2, Plus, Printer, Trash2, UserCheck } from 'lucide-react';

import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { Panel } from '@/components/ui/panel';
import { useIdempotencyKey } from '@/components/forms/use-idempotency-key';
import { formatINR, fromRupees } from '@/lib/money';
import { createQuickBillAction, findBillCustomerAction } from '@/server/services/billing/quick-bill-actions';
import type { BillCustomerMatch, BillHead, BillKind, PaymentMode } from '@/server/services/billing/quick-bill-service';

const SERVICE_HEADS: readonly { head: BillHead; label: string }[] = [
  { head: 'SPARES', label: 'Spares' },
  { head: 'LABOUR', label: 'Labour' },
  { head: 'WATERWASH', label: 'Water wash' },
  { head: 'CONSUMABLES', label: 'Other consumables' },
];
const MODES: readonly { value: PaymentMode; label: string }[] = [
  { value: 'CASH', label: 'Cash' }, { value: 'UPI', label: 'UPI / GPay' }, { value: 'CARD', label: 'Card' },
  { value: 'NEFT', label: 'Bank transfer' }, { value: 'CHEQUE', label: 'Cheque' },
];

interface CounterRow { key: number; name: string; head: BillHead; amount: string }

/**
 * The cashier's bill — spec §32, §33 as the dealer runs them (0088).
 *
 * Service: name, mobile and vehicle number, then four values. Counter: a
 * product name and a value per line. The values are what the customer pays
 * (GST inside), the money received fills itself in, and saving posts the bill
 * and the receipt together and offers the print.
 */
export function QuickBillForm({
  kind,
  branches,
  defaultBranchId,
}: {
  readonly kind: BillKind;
  readonly branches: readonly { id: string; name: string }[];
  readonly defaultBranchId: string | null;
}) {
  const router = useRouter();
  const idempotency = useIdempotencyKey(`quick-bill:${kind}`);
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [saved, setSaved] = React.useState<{ id: string; number: string; receipt: string | null } | null>(null);

  const [branchId, setBranchId] = React.useState(defaultBranchId ?? branches[0]?.id ?? '');
  const [mobile, setMobile] = React.useState('');
  const [vehicle, setVehicle] = React.useState('');
  const [name, setName] = React.useState('');
  const [match, setMatch] = React.useState<BillCustomerMatch | null>(null);
  const [values, setValues] = React.useState<Record<string, string>>({});
  const [rows, setRows] = React.useState<CounterRow[]>([{ key: 1, name: '', head: 'SPARES', amount: '' }]);
  const nextKey = React.useRef(2);
  const [mode, setMode] = React.useState<PaymentMode>('CASH');
  const [received, setReceived] = React.useState<string | null>(null);
  const [reference, setReference] = React.useState('');

  const total = kind === 'SERVICE'
    ? SERVICE_HEADS.reduce((s, h) => s + (Number(values[h.head]) || 0), 0)
    : rows.reduce((s, r) => s + (Number(r.amount) || 0), 0);
  // "Cash paid is filled automatically": the whole bill, until someone changes it.
  const receivedValue = received === null ? total : Number(received) || 0;

  const lookup = async (by: { mobile?: string; vehicleNo?: string }) => {
    const found = await findBillCustomerAction(by);
    setMatch(found);
    if (found) {
      setName(found.name);
      if (!mobile && found.mobile) setMobile(found.mobile);
      if (!vehicle && found.vehicles[0]) setVehicle(found.vehicles[0]);
    }
  };

  const reset = () => {
    setMobile(''); setVehicle(''); setName(''); setMatch(null); setValues({});
    setRows([{ key: nextKey.current++, name: '', head: 'SPARES', amount: '' }]);
    setMode('CASH'); setReceived(null); setReference(''); setError(null);
  };

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);
    startTransition(async () => {
      const result = await createQuickBillAction({
        kind,
        branchId,
        customerName: name,
        mobile,
        vehicleNo: vehicle,
        lines: kind === 'SERVICE'
          ? SERVICE_HEADS.map((h) => ({ head: h.head, amount: Number(values[h.head]) || 0 }))
          : rows.map((r) => ({ head: r.head, amount: Number(r.amount) || 0, description: r.name })),
        paymentMode: mode,
        amountReceived: receivedValue,
        reference,
        idempotencyKey: idempotency.key(),
      });
      if (!result.ok || !result.invoiceId) {
        setError(result.error ?? 'The bill could not be saved.');
        return;
      }
      idempotency.renew();
      setSaved({ id: result.invoiceId, number: result.invoiceNumber ?? '', receipt: result.receiptNumber ?? null });
      window.open(`/print/bill/${result.invoiceId}?print=1`, '_blank', 'noopener');
      reset();
      router.refresh();
    });
  };

  const amountInput = (id: string, value: string, onChange: (v: string) => void, label: string) => (
    <div className="relative">
      <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-ink-400">₹</span>
      <Input id={id} aria-label={label} type="number" inputMode="decimal" step="0.01" min="0"
        className="numeric pl-7" value={value} onChange={(e) => onChange(e.target.value)} placeholder="0.00" />
    </div>
  );

  return (
    <Panel className="p-5">
      {saved && (
        <div className="mb-4 flex flex-wrap items-center justify-between gap-3 rounded-lg bg-positive-50 px-4 py-3 text-sm text-positive-800">
          <span className="flex items-center gap-2">
            <CheckCircle2 className="size-4" aria-hidden />
            Bill <strong className="font-mono">{saved.number}</strong> saved
            {saved.receipt && <> · receipt <strong className="font-mono">{saved.receipt}</strong></>}
          </span>
          <Button size="sm" variant="secondary" type="button"
            onClick={() => window.open(`/print/bill/${saved.id}?print=1`, '_blank', 'noopener')}>
            <Printer aria-hidden />Print receipt
          </Button>
        </div>
      )}

      <form onSubmit={submit} className="space-y-5" noValidate>
        <div className="grid gap-4 sm:grid-cols-3">
          <div>
            <Label htmlFor="qb-mobile" className="mb-1.5 block">Mobile no.</Label>
            <Input id="qb-mobile" inputMode="numeric" autoFocus value={mobile} maxLength={14}
              onChange={(e) => setMobile(e.target.value)}
              onBlur={() => mobile.replace(/\D/g, '').length >= 10 && lookup({ mobile })} placeholder="98765 43210" />
          </div>
          <div>
            <Label htmlFor="qb-vehicle" className="mb-1.5 block">
              Vehicle no.{kind === 'SERVICE' && <span className="ml-0.5 text-danger-600">*</span>}
            </Label>
            <Input id="qb-vehicle" className="uppercase" value={vehicle}
              onChange={(e) => setVehicle(e.target.value.toUpperCase())}
              onBlur={() => !match && vehicle.replace(/[^A-Za-z0-9]/g, '').length >= 6 && lookup({ vehicleNo: vehicle })}
              placeholder="TN 34 AZ 1434" />
          </div>
          <div>
            <Label htmlFor="qb-name" className="mb-1.5 block">Customer name</Label>
            <Input id="qb-name" value={name} onChange={(e) => setName(e.target.value)} placeholder="Name" />
          </div>
        </div>
        {match && (
          <p className="-mt-2 flex items-center gap-1.5 text-xs text-positive-700">
            <UserCheck className="size-3.5" aria-hidden />
            Existing customer {match.customerCode}, found by {match.matchedBy === 'MOBILE' ? 'mobile' : 'vehicle number'}
            {match.vehicles.length > 0 && ` · vehicles: ${match.vehicles.join(', ')}`}. The bill goes to their account.
          </p>
        )}

        {kind === 'SERVICE' ? (
          <div className="grid gap-4 sm:grid-cols-4">
            {SERVICE_HEADS.map((h) => (
              <div key={h.head}>
                <Label htmlFor={`qb-${h.head}`} className="mb-1.5 block">{h.label}</Label>
                {amountInput(`qb-${h.head}`, values[h.head] ?? '', (v) => setValues((c) => ({ ...c, [h.head]: v })), h.label)}
              </div>
            ))}
          </div>
        ) : (
          <div className="space-y-2">
            {rows.map((r, i) => (
              <div key={r.key} className="grid gap-2 sm:grid-cols-[1fr_9rem_10rem_auto]">
                <Input aria-label="Product name" value={r.name} placeholder={i === 0 ? 'Product name, e.g. Brake shoe' : 'Product name'}
                  onChange={(e) => setRows((c) => c.map((x) => (x.key === r.key ? { ...x, name: e.target.value } : x)))} />
                <select aria-label="Kind" value={r.head} className="h-9 field px-2 text-sm"
                  onChange={(e) => setRows((c) => c.map((x) => (x.key === r.key ? { ...x, head: e.target.value as BillHead } : x)))}>
                  <option value="SPARES">Spare</option>
                  <option value="ACCESSORIES">Accessory</option>
                  <option value="CONSUMABLES">Consumable</option>
                  <option value="OTHER">Other</option>
                </select>
                {amountInput(`qb-row-${r.key}`, r.amount,
                  (v) => setRows((c) => c.map((x) => (x.key === r.key ? { ...x, amount: v } : x))), 'Amount')}
                <Button type="button" variant="ghost" size="icon" aria-label="Remove line" disabled={rows.length === 1}
                  onClick={() => setRows((c) => c.filter((x) => x.key !== r.key))}>
                  <Trash2 className="size-4" aria-hidden />
                </Button>
              </div>
            ))}
            <Button type="button" variant="secondary" size="sm"
              onClick={() => setRows((c) => [...c, { key: nextKey.current++, name: '', head: 'SPARES', amount: '' }])}>
              <Plus aria-hidden />Add product
            </Button>
          </div>
        )}

        <div className="grid gap-4 rounded-xl border border-ink-200 bg-white/70 p-4 sm:grid-cols-4">
          <div>
            <p className="text-xs text-ink-500">Bill total (GST included)</p>
            <p className="numeric mt-1 text-2xl font-bold text-ink-900">{formatINR(fromRupees(total))}</p>
          </div>
          <div>
            <Label htmlFor="qb-mode" className="mb-1.5 block">Paid by</Label>
            <select id="qb-mode" value={mode} onChange={(e) => setMode(e.target.value as PaymentMode)} className="h-9 w-full field px-3 text-sm">
              {MODES.map((m) => <option key={m.value} value={m.value}>{m.label}</option>)}
            </select>
          </div>
          <div>
            <Label htmlFor="qb-received" className="mb-1.5 block">Amount received</Label>
            {amountInput('qb-received', received ?? (total ? String(total) : ''), (v) => setReceived(v), 'Amount received')}
            {receivedValue < total && (
              <p className="mt-1 text-xs text-warning-700">
                {formatINR(fromRupees(total - receivedValue))} stays on the customer&rsquo;s account.
              </p>
            )}
          </div>
          <div>
            <Label htmlFor="qb-ref" className="mb-1.5 block">{mode === 'CASH' ? 'Note' : 'UTR / reference'}</Label>
            <Input id="qb-ref" value={reference} onChange={(e) => setReference(e.target.value)}
              placeholder={mode === 'CASH' ? 'Optional' : 'e.g. G/PAY-662369677111'} />
          </div>
        </div>

        {branches.length > 1 && (
          <div className="max-w-xs">
            <Label htmlFor="qb-branch" className="mb-1.5 block">Branch</Label>
            <select id="qb-branch" value={branchId} onChange={(e) => setBranchId(e.target.value)} className="h-9 w-full field px-3 text-sm">
              {branches.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
            </select>
          </div>
        )}

        {error && <p role="alert" className="rounded-lg bg-danger-50 px-3 py-2 text-sm text-danger-700">{error}</p>}

        <div className="flex flex-wrap items-center gap-3">
          <Button type="submit" disabled={pending || total <= 0 || receivedValue > total}>
            {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Printer aria-hidden />}
            Save bill &amp; print receipt
          </Button>
          <Button type="button" variant="ghost" onClick={reset} disabled={pending}>Clear</Button>
          <span className="text-xs text-ink-500">GST is worked out of each amount at the rate set by the accountant.</span>
        </div>
      </form>
    </Panel>
  );
}
