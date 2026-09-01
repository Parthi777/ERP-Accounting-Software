'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { ChevronDown, Loader2, Plus } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { recordBankTransactionAction } from '@/server/services/bank/bank-actions';

interface Account {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly type: string;
}

/**
 * A manual bank entry — spec §38.
 *
 * Collapsed by default: most bank movement arrives from sales, service and
 * finance postings, and a form standing open invites duplicate entry of money
 * the system already knows about.
 */
export function BankEntryForm({
  bankAccountId,
  accountName,
  accounts,
}: {
  readonly bankAccountId: string;
  readonly accountName: string;
  readonly accounts: readonly Account[];
}) {
  const router = useRouter();
  const [open, setOpen] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  const [direction, setDirection] = React.useState<'RECEIPT' | 'PAYMENT'>('RECEIPT');
  const [amount, setAmount] = React.useState('');
  const [particular, setParticular] = React.useState('');
  const [accountId, setAccountId] = React.useState('');
  const [date, setDate] = React.useState(() => new Date().toISOString().slice(0, 10));
  const [reference, setReference] = React.useState('');
  const [utr, setUtr] = React.useState('');

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);
    setNotice(null);

    const value = Number(amount) || 0;
    if (!(value > 0)) return setError('Enter an amount greater than zero.');
    if (!particular.trim()) return setError('Describe what this entry is for.');
    if (!accountId) return setError('Choose the account this posts against.');

    startTransition(async () => {
      const result = await recordBankTransactionAction({
        bankAccountId,
        direction,
        amount: value,
        particular: particular.trim(),
        accountId,
        date,
        reference: reference.trim() || null,
        utr: utr.trim() || null,
      });

      if (!result.ok) {
        setError(result.error ?? 'The entry could not be recorded.');
        return;
      }
      setNotice(result.message ?? 'Recorded.');
      setAmount('');
      setParticular('');
      setReference('');
      setUtr('');
      router.refresh();
    });
  };

  if (!open) {
    return (
      <Button variant="secondary" size="sm" onClick={() => setOpen(true)}>
        <Plus aria-hidden />
        Record an entry
      </Button>
    );
  }

  return (
    <Panel className="p-5">
      <div className="mb-4 flex items-center justify-between">
        <h2 className="text-sm font-semibold text-ink-900">Record an entry in {accountName}</h2>
        <Button variant="ghost" size="sm" onClick={() => setOpen(false)} aria-label="Close">
          <ChevronDown aria-hidden />
        </Button>
      </div>

      {error && (
        <div role="alert" className="mb-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
          {error}
        </div>
      )}
      {notice && (
        <div className="mb-3 rounded-lg border border-positive-200 bg-positive-50 px-3 py-2 text-sm text-positive-700">
          {notice}
        </div>
      )}

      <form onSubmit={submit} className="grid gap-4 sm:grid-cols-2" noValidate>
        <div>
          <Label htmlFor="direction" className="mb-1.5 block">Direction</Label>
          <select id="direction" value={direction} onChange={(e) => setDirection(e.target.value as 'RECEIPT')}
            className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
            <option value="RECEIPT">Money in</option>
            <option value="PAYMENT">Money out</option>
          </select>
        </div>

        <div>
          <Label htmlFor="bank-date" className="mb-1.5 block">Date</Label>
          <Input id="bank-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
        </div>

        <div>
          <Label htmlFor="bank-amount" className="mb-1.5 block">
            Amount<span className="ml-0.5 text-danger-600">*</span>
          </Label>
          <div className="relative">
            <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-ink-400">₹</span>
            <Input id="bank-amount" type="number" step="0.01" min="0" className="pl-7"
              value={amount} onChange={(e) => setAmount(e.target.value)} />
          </div>
        </div>

        <div>
          <Label htmlFor="bank-utr" className="mb-1.5 block">UTR</Label>
          <Input id="bank-utr" value={utr} onChange={(e) => setUtr(e.target.value)}
            placeholder="Helps match this against the statement" />
        </div>

        <div className="sm:col-span-2">
          <Label htmlFor="bank-particular" className="mb-1.5 block">
            Particulars<span className="ml-0.5 text-danger-600">*</span>
          </Label>
          <Input id="bank-particular" value={particular} onChange={(e) => setParticular(e.target.value)} />
        </div>

        <div className="sm:col-span-2">
          <Label htmlFor="bank-account" className="mb-1.5 block">
            {direction === 'RECEIPT' ? 'Received against' : 'Paid towards'}
            <span className="ml-0.5 text-danger-600">*</span>
          </Label>
          <select id="bank-account" value={accountId} onChange={(e) => setAccountId(e.target.value)}
            className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
            <option value="">Choose an account</option>
            {accounts.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}
          </select>
        </div>

        <div className="sm:col-span-2">
          <Label htmlFor="bank-reference" className="mb-1.5 block">Reference</Label>
          <Input id="bank-reference" value={reference} onChange={(e) => setReference(e.target.value)}
            placeholder="Cheque number, voucher…" />
        </div>

        <div className="sm:col-span-2">
          <Button type="submit" disabled={pending}>
            {pending && <Loader2 className="animate-spin" aria-hidden />}
            {pending ? 'Recording…' : 'Record entry'}
          </Button>
        </div>
      </form>
    </Panel>
  );
}
