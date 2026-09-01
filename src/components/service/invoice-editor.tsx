'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, Plus, Send, Trash2, Wallet } from 'lucide-react';

import { Panel, SolidPanel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { formatINR, fromRupees, paise } from '@/lib/money';
import {
  addServiceLineAction,
  postServiceInvoiceAction,
  recordServicePaymentAction,
  removeServiceLineAction,
} from '@/server/services/service/service-actions';
import type { ServiceInvoiceDetail } from '@/server/services/service/service-service';

interface Item {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly rate: number;
  readonly taxCode: string | null;
  readonly onHand: number;
}

const LINE_TYPES = [
  { value: 'LABOUR', label: 'Labour' },
  { value: 'SPARE', label: 'Spare part' },
  { value: 'ACCESSORY', label: 'Accessory' },
  { value: 'OTHER_CHARGE', label: 'Other charge' },
];

/**
 * The service bill — spec §32.
 *
 * A draft is editable; a posted invoice is not. Posting writes revenue, GST,
 * COGS and the stock movement in one transaction, so the button says what it
 * will do rather than just "Save".
 */
export function ServiceInvoiceEditor({
  invoice,
  items,
  taxCodes,
  canBill,
  canCollect,
}: {
  readonly invoice: ServiceInvoiceDetail;
  readonly items: readonly Item[];
  readonly taxCodes: readonly { code: string; label: string }[];
  readonly canBill: boolean;
  readonly canCollect: boolean;
}) {
  const router = useRouter();
  const [error, setError] = React.useState<string | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();
  const [dialog, setDialog] = React.useState<'payment' | null>(null);

  const [lineType, setLineType] = React.useState('LABOUR');
  const [itemId, setItemId] = React.useState('');
  const [description, setDescription] = React.useState('');
  const [quantity, setQuantity] = React.useState('1');
  const [unitRate, setUnitRate] = React.useState('');
  const [taxCode, setTaxCode] = React.useState('');
  const [discount, setDiscount] = React.useState('');

  const [amount, setAmount] = React.useState('');
  const [mode, setMode] = React.useState('CASH');
  const [reference, setReference] = React.useState('');

  const draft = invoice.status === 'DRAFT';
  const posted = invoice.status === 'POSTED';
  const needsItem = lineType === 'SPARE' || lineType === 'ACCESSORY';

  const run = (fn: () => Promise<{ ok: boolean; error?: string; message?: string }>, after?: () => void) => {
    setError(null);
    setNotice(null);
    startTransition(async () => {
      const result = await fn();
      if (!result.ok) {
        setError(result.error ?? 'That action could not be completed.');
        return;
      }
      if (result.message) setNotice(result.message);
      after?.();
      router.refresh();
    });
  };

  // Choosing a part fills in its description, price and tax code — the operator
  // can still override any of them.
  const chooseItem = (id: string) => {
    setItemId(id);
    const item = items.find((i) => i.id === id);
    if (item) {
      setDescription(item.name);
      setUnitRate(String(item.rate / 100));
      if (item.taxCode) setTaxCode(item.taxCode);
    }
  };

  const addLine = (event: React.FormEvent) => {
    event.preventDefault();
    if (!description.trim()) return setError('Describe the line.');
    if (!(Number(quantity) > 0)) return setError('Quantity must be greater than zero.');
    if (needsItem && !itemId) return setError('Choose the part this line is for.');

    run(
      () =>
        addServiceLineAction({
          invoiceId: invoice.id,
          lineType,
          description: description.trim(),
          quantity: Number(quantity),
          unitRate: Number(unitRate) || 0,
          itemId: itemId || null,
          taxCode: taxCode || null,
          discount: Number(discount) || 0,
        }),
      () => {
        setDescription('');
        setQuantity('1');
        setUnitRate('');
        setItemId('');
        setDiscount('');
      },
    );
  };

  return (
    <div className="space-y-4">
      {error && (
        <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
          {error}
        </div>
      )}
      {notice && (
        <div className="rounded-lg border border-positive-200 bg-positive-50 px-3 py-2 text-sm text-positive-700">
          {notice}
        </div>
      )}

      <SolidPanel className="overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full border-collapse text-sm">
            <thead className="bg-ink-50 text-left text-xs font-medium text-ink-600">
              <tr>
                <th className="px-3 py-2">#</th>
                <th className="px-3 py-2">Type</th>
                <th className="px-3 py-2">Description</th>
                <th className="px-3 py-2 text-right">Qty</th>
                <th className="px-3 py-2 text-right">Rate</th>
                <th className="px-3 py-2 text-right">Taxable</th>
                <th className="px-3 py-2 text-right">GST</th>
                <th className="px-3 py-2 text-right">Total</th>
                {draft && <th className="px-3 py-2" />}
              </tr>
            </thead>
            <tbody>
              {invoice.lines.length === 0 && (
                <tr>
                  <td colSpan={draft ? 9 : 8} className="px-3 py-8 text-center text-sm text-ink-500">
                    No lines yet. Add the labour and parts for this job below.
                  </td>
                </tr>
              )}
              {invoice.lines.map((line) => (
                <tr key={line.id} className="border-t border-ink-100">
                  <td className="px-3 py-2 text-ink-400">{line.lineNumber}</td>
                  <td className="px-3 py-2">{line.lineType.replace('_', ' ')}</td>
                  <td className="px-3 py-2">
                    <span className="block">{line.description}</span>
                    {line.stockSource && (
                      <span className="block text-[11px] text-ink-400">from {line.stockSource} stock</span>
                    )}
                  </td>
                  <td className="numeric px-3 py-2 text-right">{line.quantity}</td>
                  <td className="numeric px-3 py-2 text-right">{formatINR(line.unitRate)}</td>
                  <td className="numeric px-3 py-2 text-right">{formatINR(line.taxableValue)}</td>
                  <td className="numeric px-3 py-2 text-right text-ink-500">
                    {formatINR(paise(line.cgst + line.sgst))}
                  </td>
                  <td className="numeric px-3 py-2 text-right font-medium">{formatINR(line.total)}</td>
                  {draft && (
                    <td className="px-3 py-2 text-right">
                      <Button size="sm" variant="ghost" disabled={pending}
                        onClick={() => run(() => removeServiceLineAction(line.id, invoice.id))}
                        aria-label={`Remove line ${line.lineNumber}`}>
                        <Trash2 aria-hidden />
                      </Button>
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <dl className="grid gap-2 border-t border-ink-100 bg-ink-50/50 px-4 py-3 text-sm sm:ml-auto sm:max-w-xs">
          <div className="flex justify-between">
            <dt className="text-ink-600">Taxable value</dt>
            <dd className="numeric">{formatINR(invoice.taxableValue)}</dd>
          </div>
          <div className="flex justify-between">
            <dt className="text-ink-600">GST</dt>
            <dd className="numeric">{formatINR(paise(invoice.cgst + invoice.sgst + invoice.igst))}</dd>
          </div>
          <div className="flex justify-between border-t border-ink-200 pt-2 font-semibold">
            <dt>Invoice total</dt>
            <dd className="numeric">{formatINR(invoice.total)}</dd>
          </div>
          {posted && (
            <>
              <div className="flex justify-between">
                <dt className="text-ink-600">Received</dt>
                <dd className="numeric text-positive-700">{formatINR(invoice.paid)}</dd>
              </div>
              <div className="flex justify-between font-semibold">
                <dt>Balance due</dt>
                <dd className={`numeric ${invoice.balance > 0 ? 'text-warning-700' : 'text-positive-700'}`}>
                  {formatINR(invoice.balance)}
                </dd>
              </div>
            </>
          )}
        </dl>
      </SolidPanel>

      {draft && canBill && (
        <Panel className="p-5">
          <h2 className="mb-4 text-sm font-semibold text-ink-900">Add a line</h2>

          <form onSubmit={addLine} className="grid gap-4 sm:grid-cols-6" noValidate>
            <div className="sm:col-span-2">
              <Label htmlFor="line-type" className="mb-1.5 block">Type</Label>
              <select id="line-type" value={lineType}
                onChange={(e) => { setLineType(e.target.value); setItemId(''); }}
                className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
                {LINE_TYPES.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
              </select>
            </div>

            {needsItem && (
              <div className="sm:col-span-4">
                <Label htmlFor="item" className="mb-1.5 block">
                  Part<span className="ml-0.5 text-danger-600">*</span>
                </Label>
                <select id="item" value={itemId} onChange={(e) => chooseItem(e.target.value)}
                  className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
                  <option value="">Choose a part</option>
                  {items.map((i) => (
                    <option key={i.id} value={i.id} disabled={i.onHand <= 0}>
                      {i.code} · {i.name} ({i.onHand > 0 ? `${i.onHand} in stock` : 'out of stock'})
                    </option>
                  ))}
                </select>
              </div>
            )}

            <div className={needsItem ? 'sm:col-span-6' : 'sm:col-span-4'}>
              <Label htmlFor="description" className="mb-1.5 block">
                Description<span className="ml-0.5 text-danger-600">*</span>
              </Label>
              <Input id="description" value={description} onChange={(e) => setDescription(e.target.value)} />
            </div>

            <div>
              <Label htmlFor="quantity" className="mb-1.5 block">Qty</Label>
              <Input id="quantity" type="number" min="0" step="0.001" value={quantity}
                onChange={(e) => setQuantity(e.target.value)} />
            </div>

            <div>
              <Label htmlFor="rate" className="mb-1.5 block">Rate</Label>
              <Input id="rate" type="number" min="0" step="0.01" value={unitRate}
                onChange={(e) => setUnitRate(e.target.value)} />
            </div>

            <div>
              <Label htmlFor="discount" className="mb-1.5 block">Discount</Label>
              <Input id="discount" type="number" min="0" step="0.01" value={discount}
                onChange={(e) => setDiscount(e.target.value)} />
            </div>

            <div className="sm:col-span-2">
              <Label htmlFor="tax" className="mb-1.5 block">Tax code</Label>
              <select id="tax" value={taxCode} onChange={(e) => setTaxCode(e.target.value)}
                className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
                <option value="">No GST</option>
                {taxCodes.map((t) => <option key={t.code} value={t.code}>{t.label}</option>)}
              </select>
            </div>

            <div className="flex items-end sm:col-span-1">
              <Button type="submit" size="sm" disabled={pending}>
                {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Plus aria-hidden />}
                Add
              </Button>
            </div>
          </form>
        </Panel>
      )}

      <Panel className="p-4">
        <div className="flex flex-wrap items-center gap-2">
          {draft && canBill && (
            <Button size="sm" disabled={pending || invoice.lines.length === 0}
              onClick={() => run(() => postServiceInvoiceAction(invoice.id))}>
              {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Send aria-hidden />}
              Post the invoice
            </Button>
          )}

          {posted && canCollect && invoice.balance > 0 && (
            <Button size="sm" onClick={() => setDialog('payment')} disabled={pending}>
              <Wallet aria-hidden />
              Collect payment
            </Button>
          )}

          {posted && invoice.journalEntryId && (
            <Button size="sm" variant="secondary" asChild>
              <a href={`/accounting/journals/${invoice.journalEntryId}`}>View journal entry</a>
            </Button>
          )}
        </div>

        {draft && (
          <p className="mt-2 text-xs text-ink-500">
            Posting recognises revenue and GST, relieves the parts from stock and records their cost —
            all in one transaction. After that the invoice cannot be edited.
          </p>
        )}
      </Panel>

      {dialog === 'payment' && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
          role="dialog" aria-modal="true" onClick={() => setDialog(null)}>
          <div className="glass-strong w-full max-w-md rounded-2xl p-6" onClick={(e) => e.stopPropagation()}>
            <h2 className="text-sm font-semibold text-ink-900">Collect payment</h2>
            <p className="mt-1 text-sm text-ink-600">
              {formatINR(invoice.balance)} outstanding on {invoice.number}.
            </p>

            <div className="mt-4 space-y-3">
              <div>
                <Label htmlFor="pay-amount" className="mb-1.5 block">Amount</Label>
                <Input id="pay-amount" type="number" step="0.01" min="0" value={amount}
                  onChange={(e) => setAmount(e.target.value)} placeholder={String(invoice.balance / 100)} />
              </div>
              <div>
                <Label htmlFor="pay-mode" className="mb-1.5 block">Mode</Label>
                <select id="pay-mode" value={mode} onChange={(e) => setMode(e.target.value)}
                  className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
                  {['CASH', 'UPI', 'CARD', 'NEFT', 'RTGS', 'IMPS', 'CHEQUE'].map((m) => (
                    <option key={m} value={m}>{m}</option>
                  ))}
                </select>
              </div>
              <div>
                <Label htmlFor="pay-ref" className="mb-1.5 block">Reference</Label>
                <Input id="pay-ref" value={reference} onChange={(e) => setReference(e.target.value)} />
              </div>
            </div>

            {Number(amount) > 0 && fromRupees(Number(amount)) > invoice.balance && (
              <p className="mt-3 rounded-lg border border-warning-200 bg-warning-50 px-3 py-2 text-xs text-warning-800">
                That is more than the balance outstanding, and will be refused.
              </p>
            )}

            <div className="mt-4 flex justify-end gap-2">
              <Button variant="secondary" size="sm" onClick={() => setDialog(null)} disabled={pending}>Cancel</Button>
              <Button size="sm" disabled={pending || !(Number(amount) > 0)}
                onClick={() =>
                  run(
                    () =>
                      recordServicePaymentAction({
                        invoiceId: invoice.id,
                        amount: Number(amount),
                        mode,
                        reference: reference || null,
                      }),
                    () => { setDialog(null); setAmount(''); setReference(''); },
                  )
                }>
                {pending && <Loader2 className="animate-spin" aria-hidden />}
                Record payment
              </Button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
