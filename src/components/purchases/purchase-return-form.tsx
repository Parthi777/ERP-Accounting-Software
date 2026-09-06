'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, Undo2 } from 'lucide-react';

import type { ReturnableLine } from '@/server/services/purchases/purchase-return-service';
import { postPurchaseReturnAction } from '@/server/services/purchases/purchase-return-actions';
import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { add, applyRate, formatINR, multiply, ZERO, type Paise } from '@/lib/money';

/**
 * Raising a debit note against a posted bill — spec §21, §23, §34, §41.
 *
 * The quantities are entered against the bill's own lines rather than typed
 * fresh, because what goes back has to be priced at what it cost: a return
 * valued at today's rate leaves the difference sitting in inventory for ever.
 * The figures below are the browser's estimate; the server recomputes every one
 * of them from the bill before anything is written.
 *
 * The idempotency key is minted once when the form mounts, so a double-click or
 * a retried submission returns the note the first one wrote instead of sending
 * the goods back twice (spec §50).
 */
export function PurchaseReturnForm({
  billId,
  billNumber,
  supplierName,
  lines,
}: {
  readonly billId: string;
  readonly billNumber: string;
  readonly supplierName: string;
  readonly lines: readonly ReturnableLine[];
}) {
  const router = useRouter();
  const [open, setOpen] = React.useState(false);
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);

  const [quantities, setQuantities] = React.useState<Record<string, string>>({});
  const [reason, setReason] = React.useState('');
  const [supplierRef, setSupplierRef] = React.useState('');
  const [returnDate, setReturnDate] = React.useState(() => new Date().toISOString().slice(0, 10));
  const [key, setKey] = React.useState(() => crypto.randomUUID());

  const returnable = lines.filter((line) => line.returnableQuantity > 0);

  // A chassis that has moved on since the bill is no longer the dealer's to send
  // back. Shown, not hidden: "why can I not return this one" is a real question.
  const blocked = returnable.filter(
    (line) => line.lineType === 'VEHICLE' && line.vehicleStatus !== 'IN_STOCK',
  );
  const eligible = returnable.filter((line) => !blocked.includes(line));

  const chosen = eligible
    .map((line) => ({ line, quantity: Number(quantities[line.billLineId] ?? '') || 0 }))
    .filter((entry) => entry.quantity > 0);

  const estimate = chosen.reduce<{ taxable: Paise; tax: Paise }>(
    (running, { line, quantity }) => {
      const taxable = multiply(line.unitRate, quantity);
      return {
        taxable: add(running.taxable, taxable),
        // applyRate takes a fraction; the bill records the split as percentages.
        tax: add(running.tax, applyRate(taxable, line.taxRate / 100)),
      };
    },
    { taxable: ZERO, tax: ZERO },
  );

  const tooMany = chosen.find(({ line, quantity }) => quantity > line.returnableQuantity);
  const ready = chosen.length > 0 && reason.trim().length > 0 && !tooMany;

  const reset = () => {
    setQuantities({});
    setReason('');
    setSupplierRef('');
    setKey(crypto.randomUUID());
  };

  const submit = () => {
    setError(null);
    setNotice(null);
    startTransition(async () => {
      const result = await postPurchaseReturnAction({
        billId,
        lines: chosen.map(({ line, quantity }) => ({ billLineId: line.billLineId, quantity })),
        reason,
        returnDate,
        supplierRef,
        idempotencyKey: key,
      });
      if (!result.ok) {
        setError(result.error ?? 'The note could not be posted.');
        return;
      }
      setNotice(result.message ?? null);
      setOpen(false);
      reset();
      router.refresh();
    });
  };

  if (returnable.length === 0) {
    return (
      <Panel className="p-4">
        <h2 className="text-sm font-semibold text-ink-900">Return to supplier</h2>
        <p className="mt-1 text-sm text-ink-500">
          Everything on this bill has already gone back. The bill itself stays posted — the notes
          against it are listed below.
        </p>
      </Panel>
    );
  }

  return (
    <Panel className="p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold text-ink-900">Return to supplier</h2>
          <p className="mt-0.5 text-sm text-ink-500">
            Send part of {billNumber} back to {supplierName}. The stock comes off the books at what
            it cost, its input GST is reversed, and what is owed falls by the same amount.
          </p>
        </div>
        {!open && (
          <Button size="sm" variant="secondary" onClick={() => setOpen(true)}>
            <Undo2 aria-hidden />
            Raise a debit note
          </Button>
        )}
      </div>

      {notice && (
        <div role="status" className="mt-3 rounded-lg border border-positive-200 bg-positive-50 px-3 py-2 text-sm text-positive-700">
          {notice}
        </div>
      )}

      {open && (
        <div className="mt-4 space-y-4">
          {error && (
            <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
              {error}
            </div>
          )}

          <div className="overflow-x-auto">
            <table className="w-full min-w-[40rem] border-collapse text-sm">
              <thead>
                <tr className="border-b border-ink-200 text-left text-xs font-medium text-ink-500">
                  <th className="py-2 pr-3">Line</th>
                  <th className="py-2 pr-3">Billed</th>
                  <th className="py-2 pr-3">Returned</th>
                  <th className="py-2 pr-3 text-right">Rate</th>
                  <th className="py-2 pl-3 text-right">Send back</th>
                </tr>
              </thead>
              <tbody>
                {eligible.map((line) => {
                  const quantity = Number(quantities[line.billLineId] ?? '') || 0;
                  const over = quantity > line.returnableQuantity;
                  return (
                    <tr key={line.billLineId} className="border-b border-ink-100 last:border-0">
                      <td className="py-2 pr-3">
                        <span className="block text-ink-800">{line.description}</span>
                        <span className="block font-mono text-[11px] text-ink-400">
                          {line.chassisNo ?? line.itemCode}
                          {line.source ? ` · ${line.source === 'LOCAL' ? 'Local' : 'Company'}` : ''}
                        </span>
                      </td>
                      <td className="numeric py-2 pr-3 text-ink-600">{line.billedQuantity}</td>
                      <td className="numeric py-2 pr-3 text-ink-600">
                        {line.returnedQuantity > 0 ? line.returnedQuantity : <span className="text-ink-300">—</span>}
                      </td>
                      <td className="numeric py-2 pr-3 text-right text-ink-700">{formatINR(line.unitRate)}</td>
                      <td className="py-2 pl-3">
                        <div className="flex items-center justify-end gap-2">
                          <Input
                            type="number"
                            min={0}
                            max={line.returnableQuantity}
                            step={line.lineType === 'VEHICLE' ? 1 : 'any'}
                            aria-label={`Quantity to return of ${line.description}`}
                            aria-invalid={over || undefined}
                            value={quantities[line.billLineId] ?? ''}
                            onChange={(e) =>
                              setQuantities((q) => ({ ...q, [line.billLineId]: e.target.value }))
                            }
                            className={`h-8 w-24 text-right ${over ? 'border-danger-300' : ''}`}
                          />
                          <span className="w-16 text-[11px] text-ink-400">
                            of {line.returnableQuantity}
                          </span>
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>

          {blocked.length > 0 && (
            <div className="rounded-lg border border-ink-200 bg-ink-50 px-3 py-2 text-xs text-ink-600">
              <p className="font-medium text-ink-700">Not available to return</p>
              <ul className="mt-1 space-y-0.5">
                {blocked.map((line) => (
                  <li key={line.billLineId}>
                    <span className="font-mono">{line.chassisNo}</span> is {line.vehicleStatus} — a
                    vehicle that has been booked, sold or transferred is not the dealer&rsquo;s to
                    send back.
                  </li>
                ))}
              </ul>
            </div>
          )}

          <div className="grid gap-3 sm:grid-cols-3">
            <div>
              <Label htmlFor="return-date" className="mb-1.5 block">Return date</Label>
              <Input id="return-date" type="date" value={returnDate}
                onChange={(e) => setReturnDate(e.target.value)} />
            </div>
            <div>
              <Label htmlFor="return-ref" className="mb-1.5 block">Their credit note</Label>
              <Input id="return-ref" value={supplierRef} placeholder="TVS/CN/2026/41"
                onChange={(e) => setSupplierRef(e.target.value)} />
              <p className="mt-1 text-xs text-ink-400">Optional — they may not have raised it yet.</p>
            </div>
            <div className="sm:col-span-1">
              <Label htmlFor="return-reason" className="mb-1.5 block">
                Reason<span className="ml-0.5 text-danger-600">*</span>
              </Label>
              <Input id="return-reason" value={reason} placeholder="Water damaged in transit"
                onChange={(e) => setReason(e.target.value)} />
            </div>
          </div>

          <div className="flex flex-wrap items-center justify-between gap-3 border-t border-ink-100 pt-3">
            <dl className="flex flex-wrap items-baseline gap-x-6 gap-y-1 text-sm">
              <div className="flex items-baseline gap-2">
                <dt className="text-xs text-ink-500">Goods</dt>
                <dd className="numeric text-ink-800">{formatINR(estimate.taxable)}</dd>
              </div>
              <div className="flex items-baseline gap-2">
                <dt className="text-xs text-ink-500">GST reversed</dt>
                <dd className="numeric text-ink-800">{formatINR(estimate.tax)}</dd>
              </div>
              <div className="flex items-baseline gap-2">
                <dt className="text-xs text-ink-500">Off the supplier&rsquo;s account</dt>
                <dd className="numeric text-base font-bold text-ink-900">
                  {formatINR(add(estimate.taxable, estimate.tax))}
                </dd>
              </div>
            </dl>

            <div className="flex items-center gap-2">
              <Button variant="secondary" size="sm" disabled={pending}
                onClick={() => { setOpen(false); reset(); }}>
                Cancel
              </Button>
              <Button size="sm" disabled={pending || !ready} onClick={submit}>
                {pending && <Loader2 className="animate-spin" aria-hidden />}
                Post debit note
              </Button>
            </div>
          </div>

          {tooMany && (
            <p className="text-xs text-danger-600">
              Only {tooMany.line.returnableQuantity} of {tooMany.line.description} is left to return.
            </p>
          )}
          <p className="text-xs text-ink-400">
            Posting writes the journal, takes the stock out and reduces the payable in one
            transaction. The note then appears on the supplier&rsquo;s ledger as an open debit you
            can set against this bill or the next one.
          </p>
        </div>
      )}
    </Panel>
  );
}
