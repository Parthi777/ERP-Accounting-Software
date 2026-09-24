'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { ArrowRight, Loader2 } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { recordContraAction } from '@/server/services/bank/bank-actions';
import { useIdempotencyKey } from '@/components/forms/use-idempotency-key';

export interface MoneyAccountOption {
  /** `CASH:<branch id>` or `BANK:<bank account id>`. */
  readonly value: string;
  readonly label: string;
}

/**
 * Contra — spec §36, §38.
 *
 * The day's takings banked, cash drawn for petty expenses, a sweep between two
 * banks. Both sides are the dealer's own money, so both books move and the
 * journal is one debit and one credit between two cash/bank ledgers.
 */
export function ContraForm({ options }: { readonly options: readonly MoneyAccountOption[] }) {
  const router = useRouter();
  const [from, setFrom] = React.useState(options.find((o) => o.value.startsWith('CASH:'))?.value ?? '');
  const [to, setTo] = React.useState(options.find((o) => o.value.startsWith('BANK:'))?.value ?? '');
  const [amount, setAmount] = React.useState('');
  const [date, setDate] = React.useState(() => new Date().toISOString().slice(0, 10));
  const [reference, setReference] = React.useState('');
  const [narration, setNarration] = React.useState('');
  const [error, setError] = React.useState<string | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  const idempotency = useIdempotencyKey(`contra:${from}:${to}:${date}`);

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);
    setNotice(null);

    const value = Number(amount) || 0;
    if (!from || !to) return setError('Choose where the money leaves and where it arrives.');
    if (from === to) return setError('The money has to go to a different account.');
    if (from.startsWith('CASH:') && to.startsWith('CASH:')) {
      return setError('Cash between branches is a branch transfer, not a contra.');
    }
    if (!(value > 0)) return setError('Enter an amount greater than zero.');

    const [fromKind, fromId] = from.split(':') as ['CASH' | 'BANK', string];
    const [toKind, toId] = to.split(':') as ['CASH' | 'BANK', string];

    startTransition(async () => {
      const result = await recordContraAction({
        fromKind, fromId, toKind, toId,
        amount: value,
        date,
        reference: reference || null,
        narration: narration || null,
        idempotencyKey: idempotency.key(),
      });
      if (!result.ok) {
        setError(result.error ?? 'The contra could not be recorded.');
        return;
      }
      idempotency.renew();
      setNotice(result.message ?? 'Recorded.');
      setAmount('');
      setReference('');
      setNarration('');
      router.refresh();
    });
  };

  const select = (id: string, value: string, onChange: (v: string) => void) => (
    <select id={id} value={value} onChange={(e) => onChange(e.target.value)}
      className="h-9 w-full field px-3 text-sm">
      <option value="">Choose…</option>
      <optgroup label="Cash">
        {options.filter((o) => o.value.startsWith('CASH:')).map((o) => (
          <option key={o.value} value={o.value}>{o.label}</option>
        ))}
      </optgroup>
      <optgroup label="Bank">
        {options.filter((o) => o.value.startsWith('BANK:')).map((o) => (
          <option key={o.value} value={o.value}>{o.label}</option>
        ))}
      </optgroup>
    </select>
  );

  return (
    <Panel className="p-5">
      <form onSubmit={submit} className="grid gap-4 sm:grid-cols-[1fr_auto_1fr]" noValidate>
        <div>
          <Label htmlFor="contra-from" className="mb-1.5 block">From</Label>
          {select('contra-from', from, setFrom)}
        </div>
        <ArrowRight className="hidden size-4 self-end mb-2.5 text-ink-400 sm:block" aria-hidden />
        <div>
          <Label htmlFor="contra-to" className="mb-1.5 block">To</Label>
          {select('contra-to', to, setTo)}
        </div>

        <div>
          <Label htmlFor="contra-amount" className="mb-1.5 block">
            Amount<span className="ml-0.5 text-danger-600">*</span>
          </Label>
          <div className="relative">
            <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-ink-400">₹</span>
            <Input id="contra-amount" type="number" step="0.01" min="0" className="pl-7 numeric"
              value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" />
          </div>
        </div>
        <span className="hidden sm:block" />
        <div>
          <Label htmlFor="contra-date" className="mb-1.5 block">Date</Label>
          <Input id="contra-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
        </div>

        <div>
          <Label htmlFor="contra-ref" className="mb-1.5 block">Reference</Label>
          <Input id="contra-ref" value={reference} onChange={(e) => setReference(e.target.value)}
            placeholder="Deposit slip or cheque no." />
        </div>
        <span className="hidden sm:block" />
        <div>
          <Label htmlFor="contra-narration" className="mb-1.5 block">Narration</Label>
          <Input id="contra-narration" value={narration} onChange={(e) => setNarration(e.target.value)}
            placeholder="Day's takings deposited" />
        </div>

        {error && (
          <p role="alert" className="rounded-lg bg-danger-50 px-3 py-2 text-sm text-danger-700 sm:col-span-3">{error}</p>
        )}
        {notice && (
          <p className="rounded-lg bg-positive-50 px-3 py-2 text-sm text-positive-700 sm:col-span-3">{notice}</p>
        )}

        <div className="sm:col-span-3">
          <Button type="submit" disabled={pending}>
            {pending && <Loader2 className="animate-spin" aria-hidden />}
            Record contra
          </Button>
        </div>
      </form>
    </Panel>
  );
}
