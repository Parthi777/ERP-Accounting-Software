'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { ArrowDownLeft, ArrowUpRight, Loader2 } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { add, formatINR, fromRupees, paise, subtract } from '@/lib/money';
import { recordCashAction } from '@/server/services/cash/cash-actions';

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
}: {
  readonly direction: 'RECEIPT' | 'PAYMENT';
  readonly accounts: readonly Account[];
  readonly customers: readonly Customer[];
  readonly businessDate: string;
  readonly branchName: string;
  readonly currentBalance: number;
  readonly locked: boolean;
}) {
  const router = useRouter();
  const [error, setError] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();
  const [amount, setAmount] = React.useState('');
  const [particular, setParticular] = React.useState('');
  const [accountId, setAccountId] = React.useState('');
  const [customerId, setCustomerId] = React.useState('');
  const [reference, setReference] = React.useState('');

  const isReceipt = direction === 'RECEIPT';
  const value = Number(amount) || 0;
  const opening = paise(currentBalance);
  const entered = Number.isFinite(value) ? fromRupees(value) : paise(0);
  const projected = isReceipt ? add(opening, entered) : subtract(opening, entered);

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);

    if (!(value > 0)) return setError('Enter an amount greater than zero.');
    if (!particular.trim()) return setError('Describe what this entry is for.');
    if (!accountId) return setError('Choose the account this posts against.');
    if (!isReceipt && projected < 0) {
      return setError('This payment is more than the cash in hand.');
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
      });

      if (!result.ok) {
        setError(result.error ?? 'The entry could not be recorded.');
        return;
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
            <div className="relative">
              <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-ink-400">₹</span>
              <Input id="amount" type="number" step="0.01" min="0" className="pl-7"
                value={amount} onChange={(e) => setAmount(e.target.value)} autoFocus />
            </div>
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
              placeholder={isReceipt ? 'e.g. Advance from customer' : 'e.g. Fuel for delivery van'} />
          </div>

          <div className="sm:col-span-2">
            <Label htmlFor="account" className="mb-1.5 block">
              {isReceipt ? 'Received against' : 'Paid towards'}<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <select id="account" value={accountId} onChange={(e) => setAccountId(e.target.value)}
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
              <option value="">Choose an account</option>
              {accounts.map((a) => (
                <option key={a.id} value={a.id}>{a.code} · {a.name}</option>
              ))}
            </select>
            <p className="mt-1 text-xs text-ink-400">
              Cash is {isReceipt ? 'debited' : 'credited'} automatically; this is the other side of the entry.
            </p>
          </div>

          <div className="sm:col-span-2">
            <Label htmlFor="customer" className="mb-1.5 block">Customer</Label>
            <select id="customer" value={customerId} onChange={(e) => setCustomerId(e.target.value)}
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
              <option value="">Not linked to a customer</option>
              {customers.map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}
            </select>
          </div>
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
