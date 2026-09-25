'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Landmark, Loader2 } from 'lucide-react';

import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { useIdempotencyKey } from '@/components/forms/use-idempotency-key';
import { recordRemittanceAction } from '@/server/services/accounting/tds-actions';

const inr = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', minimumFractionDigits: 2 });

/**
 * Record a TDS deposit already made at the bank (F67): tick the deductions the
 * challan covers, give the challan serial, BSR code and date. It posts the
 * bank payment Dr 2745 Cr Bank; it does not pay, and it files nothing.
 */
export function TdsRemittanceForm({
  deductions,
  banks,
}: {
  readonly deductions: readonly { id: string; label: string; amount: number }[];
  readonly banks: readonly { value: string; label: string }[];
}) {
  const router = useRouter();
  const idempotency = useIdempotencyKey('tds-remittance');
  const [picked, setPicked] = React.useState<Set<string>>(() => new Set());
  const [bank, setBank] = React.useState(banks[0]?.value ?? '');
  const [date, setDate] = React.useState(new Date().toISOString().slice(0, 10));
  const [challan, setChallan] = React.useState('');
  const [bsr, setBsr] = React.useState('');
  const [error, setError] = React.useState<string | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();
  const total = deductions.filter((d) => picked.has(d.id)).reduce((s, d) => s + d.amount, 0);

  if (deductions.length === 0) {
    return <p className="text-sm text-ink-500">Every deduction has been deposited.</p>;
  }

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);
    setNotice(null);
    if (picked.size === 0) return setError('Tick the deductions this challan covers.');
    if (!bank) return setError('Choose the bank account the deposit was made from.');
    if (!/^[0-9]{7}$/.test(bsr.trim())) return setError('A BSR code is seven digits.');
    if (!challan.trim()) return setError('Enter the challan serial number.');
    if (!confirm(`Record a deposit of ${inr.format(total)} already made on ${date}?`)) return;
    startTransition(async () => {
      const result = await recordRemittanceAction({
        bankAccountId: bank, depositDate: date, challanNumber: challan, bsrCode: bsr,
        deductionIds: [...picked], idempotencyKey: idempotency.key(),
      });
      if (!result.ok) return setError(result.error ?? 'The deposit could not be recorded.');
      idempotency.renew();
      setPicked(new Set());
      setChallan('');
      setNotice(result.message ?? 'Recorded.');
      router.refresh();
    });
  };

  return (
    <form onSubmit={submit} className="space-y-4" noValidate>
      <ul className="max-h-72 divide-y divide-ink-100 overflow-auto rounded-xl border border-ink-100 text-sm">
        {deductions.map((d) => (
          <li key={d.id}>
            <label className="flex items-center justify-between gap-3 px-3 py-2">
              <span className="flex items-center gap-2">
                <input type="checkbox" checked={picked.has(d.id)}
                  onChange={(e) => setPicked((cur) => {
                    const next = new Set(cur);
                    if (e.target.checked) next.add(d.id); else next.delete(d.id);
                    return next;
                  })} />
                {d.label}
              </span>
              <span className="numeric">{inr.format(d.amount)}</span>
            </label>
          </li>
        ))}
      </ul>
      <div className="grid gap-3 sm:grid-cols-4">
        <div className="sm:col-span-2">
          <Label htmlFor="tds-bank" className="mb-1 block text-xs">Paid from</Label>
          <select id="tds-bank" value={bank} onChange={(e) => setBank(e.target.value)} className="field h-10 w-full px-3 text-sm">
            {banks.map((b) => <option key={b.value} value={b.value}>{b.label}</option>)}
          </select>
        </div>
        <div>
          <Label htmlFor="tds-date" className="mb-1 block text-xs">Deposited on</Label>
          <Input id="tds-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
        </div>
        <div>
          <Label htmlFor="tds-bsr" className="mb-1 block text-xs">BSR code</Label>
          <Input id="tds-bsr" inputMode="numeric" maxLength={7} value={bsr} onChange={(e) => setBsr(e.target.value)} />
        </div>
        <div>
          <Label htmlFor="tds-challan" className="mb-1 block text-xs">Challan serial</Label>
          <Input id="tds-challan" maxLength={20} value={challan} onChange={(e) => setChallan(e.target.value)} />
        </div>
      </div>
      <p className="text-sm text-ink-600">Deposit: <span className="numeric font-semibold text-ink-900">{inr.format(total)}</span></p>
      {error && <p role="alert" className="rounded-xl bg-danger-50 px-3 py-2 text-sm text-danger-700">{error}</p>}
      {notice && <p className="rounded-xl bg-positive-50 px-3 py-2 text-sm text-positive-700">{notice}</p>}
      <Button type="submit" disabled={pending}>
        {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Landmark aria-hidden />}
        Record deposit
      </Button>
    </form>
  );
}
