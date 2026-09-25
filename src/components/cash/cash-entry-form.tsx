'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { ArrowDownLeft, ArrowUpRight, Loader2, Plus, Printer, Trash2 } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { add, formatINR, fromRupees, paise, subtract } from '@/lib/money';
import { recordCashAction, recordCashVoucherAction } from '@/server/services/cash/cash-actions';
import { useIdempotencyKey } from '@/components/forms/use-idempotency-key';
import { SearchSelect } from '@/components/forms/search-select';
import { AmountInput } from '@/components/forms/amount-input';
import { QuickAdd } from '@/components/forms/quick-add';

interface Account {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly type: string;
}

interface Customer {
  readonly id: string;
  readonly label: string;
}

/**
 * Recording a cash receipt or payment — spec §37.
 *
 * The form shows what cash in hand will be once this is saved, because that is
 * the number the cashier can check against the drawer without waiting for the
 * close.
 */
export function CashEntryForm({
  direction,
  accounts,
  customers,
  businessDate,
  branchName,
  currentBalance,
  locked,
  narrations = [],
}: {
  readonly direction: 'RECEIPT' | 'PAYMENT';
  readonly accounts: readonly Account[];
  readonly customers: readonly Customer[];
  readonly businessDate: string;
  readonly branchName: string;
  readonly currentBalance: number;
  readonly locked: boolean;
  /** Narration templates for this voucher type (0091), offered as suggestions. */
  readonly narrations?: readonly string[];
}) {
  const router = useRouter();
  const [error, setError] = React.useState<string | null>(null);
  const [printId, setPrintId] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();
  const [amount, setAmount] = React.useState('');
  const [particular, setParticular] = React.useState('');
  const [accountId, setAccountId] = React.useState('');
  const [customerId, setCustomerId] = React.useState('');
  const [reference, setReference] = React.useState('');
  // Split: one voucher over several accounts — one cash row, one journal (0091).
  const [split, setSplit] = React.useState(false);
  const [lines, setLines] = React.useState([{ key: 1, accountId: '', amount: '', narration: '' }]);
  const nextKey = React.useRef(2);
  const setLine = (key: number, patch: Partial<{ accountId: string; amount: string; narration: string }>) =>
    setLines((cur) => cur.map((l) => (l.key === key ? { ...l, ...patch } : l)));

  // Scoped to the branch and business date: two tabs on different days are two
  // different entries and must not share a key.
  const idempotency = useIdempotencyKey(`cash-entry:${businessDate}`);

  const isReceipt = direction === 'RECEIPT';
  const splitTotal = lines.reduce((sum, l) => sum + (Number(l.amount) || 0), 0);
  const value = split ? Math.round(splitTotal * 100) / 100 : Number(amount) || 0;
  const opening = paise(currentBalance);
  const entered = Number.isFinite(value) ? fromRupees(value) : paise(0);
  const projected = isReceipt ? add(opening, entered) : subtract(opening, entered);

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);

    if (!(value > 0)) return setError('Enter an amount greater than zero.');
    if (!particular.trim()) return setError('Describe what this entry is for.');
    if (!split && !accountId) return setError('Choose the account this posts against.');
    if (split) {
      const bad = lines.findIndex((l) => !l.accountId || !(Number(l.amount) > 0));
      if (bad >= 0) return setError(`Line ${bad + 1}: choose the account and enter an amount.`);
    }
    if (!isReceipt && projected < 0) {
      return setError('This payment is more than the cash in hand.');
    }

    if (split) {
      startTransition(async () => {
        const result = await recordCashVoucherAction({
          direction,
          particular: particular.trim(),
          lines: lines.map((l) => ({ accountId: l.accountId, amount: Number(l.amount), narration: l.narration })),
          reference: reference.trim() || null,
          date: businessDate,
          idempotencyKey: idempotency.key(),
        });
        if (!result.ok) {
          setError(result.error ?? 'The voucher could not be recorded.');
          return;
        }
        idempotency.renew();
        if (result.id) {
          setPrintId(result.id);
          window.open(`/print/cash/${result.id}?print=1`, '_blank', 'noopener');
        }
        setParticular('');
        setReference('');
        setLines([{ key: nextKey.current++, accountId: '', amount: '', narration: '' }]);
        router.refresh();
      });
      return;
    }

    startTransition(async () => {
      const result = await recordCashAction({
        direction,
        amount: value,
        particular: particular.trim(),
        accountId,
        customerId: customerId || null,
        reference: reference.trim() || null,
        date: businessDate,
        idempotencyKey: idempotency.key(),
      });

      if (!result.ok) {
        setError(result.error ?? 'The entry could not be recorded.');
        return;
      }
      // Only after the server confirmed. Renewing on the way out would give a
      // retry of a failed submission a fresh key, which is the case the key
      // exists for.
      idempotency.renew();
      // The customer's receipt (or the payment voucher), straight to the printer.
      if (result.id) {
        setPrintId(result.id);
        window.open(`/print/cash/${result.id}?print=1`, '_blank', 'noopener');
      }
      setAmount('');
      setParticular('');
      setReference('');
      setCustomerId('');
      router.refresh();
    });
  };

  if (locked) {
    return (
      <Panel className="p-5">
        <p className="text-sm text-ink-700">
          The cash book for {businessDate} is closed. No further entries can be recorded against it.
        </p>
        <p className="mt-1 text-xs text-ink-500">
          Reopen the day from Day close, or post an adjustment journal instead.
        </p>
      </Panel>
    );
  }

  return (
    <form onSubmit={submit} className="space-y-4" noValidate>
      {printId && (
        <div className="flex items-center justify-between gap-3 rounded-lg bg-positive-50 px-3 py-2 text-sm text-positive-800">
          <span>Recorded.</span>
          <Button type="button" size="sm" variant="secondary"
            onClick={() => window.open(`/print/cash/${printId}?print=1`, '_blank', 'noopener')}>
            <Printer aria-hidden />Print {direction === 'RECEIPT' ? 'receipt' : 'voucher'}
          </Button>
        </div>
      )}
      {error && (
        <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
          {error}
        </div>
      )}

      <Panel className="p-5">
        <h2 className="flex items-center gap-2 text-sm font-semibold text-ink-900">
          {isReceipt ? <ArrowDownLeft className="text-positive-600" aria-hidden /> : <ArrowUpRight className="text-danger-600" aria-hidden />}
          {isReceipt ? 'Cash received' : 'Cash paid out'}
        </h2>
        <p className="mb-4 text-xs text-ink-500">
          {branchName} · {businessDate}. The journal entry is written at the same time.
        </p>

        <div className="grid gap-4 sm:grid-cols-2">
          <div>
            <Label htmlFor="amount" className="mb-1.5 block">
              Amount<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            {split ? (
              <p className="numeric flex h-10 items-center text-base font-semibold text-ink-900">{formatINR(fromRupees(value))}</p>
            ) : (
              <div className="relative">
                <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-ink-400">₹</span>
                <AmountInput id="amount" className="pl-7" value={amount} onValueChange={setAmount} autoFocus />
              </div>
            )}
          </div>

          <div>
            <Label htmlFor="reference" className="mb-1.5 block">Reference</Label>
            <Input id="reference" value={reference} onChange={(e) => setReference(e.target.value)}
              placeholder="Voucher or slip number" />
          </div>

          <div className="sm:col-span-2">
            <Label htmlFor="particular" className="mb-1.5 block">
              Particulars<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <Input id="particular" value={particular} onChange={(e) => setParticular(e.target.value)}
              list={narrations.length ? 'cash-narrations' : undefined}
              placeholder={isReceipt ? 'e.g. Advance from customer' : 'e.g. Fuel for delivery van'} />
            {narrations.length > 0 && (
              <datalist id="cash-narrations">
                {narrations.map((n) => <option key={n} value={n} />)}
              </datalist>
            )}
          </div>

          <label className="flex items-center gap-2 text-sm text-ink-700 sm:col-span-2">
            <input type="checkbox" checked={split} onChange={(e) => setSplit(e.target.checked)} />
            Split over several accounts — one voucher, one cash entry
          </label>

          {split ? (
            <div className="space-y-2 sm:col-span-2">
              {lines.map((line, index) => (
                <div key={line.key} className="grid gap-2 sm:grid-cols-[1fr_8rem_1fr_auto] sm:items-end">
                  <div>
                    <Label htmlFor={`line-acc-${line.key}`} className="mb-1 block text-xs">Account {index + 1}</Label>
                    <SearchSelect
                      id={`line-acc-${line.key}`}
                      name={`line-acc-${line.key}`}
                      options={accounts.map((a) => ({ id: a.id, label: `${a.code} · ${a.name}` }))}
                      defaultValue={line.accountId}
                      placeholder="Search the chart of accounts…"
                      onChange={(v) => setLine(line.key, { accountId: v })}
                    />
                  </div>
                  <div>
                    <Label htmlFor={`line-amt-${line.key}`} className="mb-1 block text-xs">Amount</Label>
                    <AmountInput id={`line-amt-${line.key}`} value={line.amount}
                      onValueChange={(v) => setLine(line.key, { amount: v })} />
                  </div>
                  <div>
                    <Label htmlFor={`line-nar-${line.key}`} className="mb-1 block text-xs">Narration</Label>
                    <Input id={`line-nar-${line.key}`} value={line.narration}
                      onChange={(e) => setLine(line.key, { narration: e.target.value })} placeholder="Optional" />
                  </div>
                  <Button type="button" variant="ghost" size="sm" aria-label={`Remove line ${index + 1}`}
                    disabled={lines.length === 1}
                    onClick={() => setLines((cur) => cur.filter((l) => l.key !== line.key))}>
                    <Trash2 aria-hidden />
                  </Button>
                </div>
              ))}
              <Button type="button" variant="secondary" size="sm"
                onClick={() => setLines((cur) => [...cur, { key: nextKey.current++, accountId: '', amount: '', narration: '' }])}>
                <Plus aria-hidden />Add line
              </Button>
            </div>
          ) : (
            <>
            <div className="sm:col-span-2">
              <Label htmlFor="account" className="mb-1.5 block">
                {isReceipt ? 'Received against' : 'Paid towards'}<span className="ml-0.5 text-danger-600">*</span>
              </Label>
              <SearchSelect
                id="account"
                name="account"
                options={accounts.map((a) => ({ id: a.id, label: `${a.code} · ${a.name}` }))}
                defaultValue={accountId}
                placeholder="Search the chart of accounts…"
                onChange={setAccountId}
              />
              <p className="mt-1 text-xs text-ink-400">
                Cash is {isReceipt ? 'debited' : 'credited'} automatically; this is the other side of the entry.
              </p>
            </div>

            <div className="sm:col-span-2">
              <Label htmlFor="customer" className="mb-1.5 block">Customer<QuickAdd href="/customers/new" noun="customer" /></Label>
              <SearchSelect
                id="customer"
                name="customer"
                options={customers}
                defaultValue={customerId}
                placeholder="Not linked to a customer"
                onChange={setCustomerId}
              />
            </div>
            </>
          )}
        </div>

        <div className="mt-5 flex items-center justify-between rounded-lg border border-brand-200 bg-brand-50 px-4 py-3">
          <span className="text-sm font-medium text-brand-800">Cash in hand after this entry</span>
          <span className={`numeric text-lg font-bold ${projected < 0 ? 'text-danger-700' : 'text-brand-900'}`}>
            {formatINR(projected)}
          </span>
        </div>
      </Panel>

      <Button type="submit" disabled={pending}>
        {pending && <Loader2 className="animate-spin" aria-hidden />}
        {pending ? 'Recording…' : isReceipt ? 'Record receipt' : 'Record payment'}
      </Button>
    </form>
  );
}
