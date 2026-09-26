'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Banknote, Loader2, Printer } from 'lucide-react';

import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { useIdempotencyKey } from '@/components/forms/use-idempotency-key';
import { payClaimsAction } from '@/server/services/hr/employee-claims-actions';

const inr = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', minimumFractionDigits: 2 });

export interface PayableClaim {
  readonly id: string;
  readonly claimNo: number | null;
  readonly employeeName: string;
  readonly employeeCode: string | null;
  readonly branchName: string | null;
  readonly typeLabel: string;
  readonly title: string;
  readonly amount: number;
  readonly approvedAt: string | null;
  readonly approvedBy: string | null;
  readonly hasPhoto: boolean;
  readonly hasDocument: boolean;
}

/**
 * Claims approved in the HR app, to be paid (0095). Tick them — usually one
 * person's — and pay from the cash drawer or a bank account: one voucher, the
 * receipt printed for the employee to sign, the HR app told it is paid.
 */
export function ClaimsPayForm({
  claims,
  banks,
  branchName,
  canPay,
}: {
  readonly claims: readonly PayableClaim[];
  readonly banks: readonly { value: string; label: string }[];
  readonly branchName: string | null;
  readonly canPay: boolean;
}) {
  const router = useRouter();
  const idempotency = useIdempotencyKey('hr-claims-pay');
  const [picked, setPicked] = React.useState<Set<string>>(() => new Set());
  const [book, setBook] = React.useState<'CASH' | 'BANK'>('CASH');
  const [bank, setBank] = React.useState(banks[0]?.value ?? '');
  const [date, setDate] = React.useState(new Date().toISOString().slice(0, 10));
  const [reference, setReference] = React.useState('');
  const [error, setError] = React.useState<string | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);
  const [printId, setPrintId] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  const total = claims.filter((c) => picked.has(c.id)).reduce((s, c) => s + c.amount, 0);
  const toggle = (id: string, on: boolean) =>
    setPicked((cur) => {
      const next = new Set(cur);
      if (on) next.add(id); else next.delete(id);
      return next;
    });

  const pay = () => {
    setError(null);
    setNotice(null);
    if (picked.size === 0) return setError('Tick the claims to pay.');
    if (book === 'BANK' && !bank) return setError('Choose the bank account.');
    const names = [...new Set(claims.filter((c) => picked.has(c.id)).map((c) => c.employeeName))].join(', ');
    if (!confirm(`Pay ${inr.format(total)} to ${names} from the ${book === 'CASH' ? `cash at ${branchName ?? 'this branch'}` : 'bank'}?`)) return;
    startTransition(async () => {
      const result = await payClaimsAction({
        claimIds: [...picked], book, bankAccountId: book === 'BANK' ? bank : null, date,
        reference: reference || null, idempotencyKey: idempotency.key(),
      });
      if (!result.ok) return setError(result.error ?? 'The claims could not be paid.');
      idempotency.renew();
      setPicked(new Set());
      setReference('');
      setNotice(result.message ?? 'Paid.');
      if (book === 'CASH' && 'transactionId' in result && result.transactionId) {
        setPrintId(result.transactionId);
        window.open(`/print/cash/${result.transactionId}?print=1`, '_blank', 'noopener');
      }
      router.refresh();
    });
  };

  if (claims.length === 0) {
    return <p className="p-6 text-center text-sm text-ink-500">No approved claims are waiting to be paid.</p>;
  }

  return (
    <div className="space-y-4">
      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-[11px] uppercase tracking-wide text-ink-500">
              {canPay && <th className="w-8 px-3 py-2" />}
              <th className="px-3 py-2 text-left font-semibold">Employee</th>
              <th className="px-3 py-2 text-left font-semibold">Claim</th>
              <th className="px-3 py-2 text-left font-semibold">Approved</th>
              <th className="px-3 py-2 text-left font-semibold">Receipt</th>
              <th className="px-3 py-2 text-right font-semibold">Amount</th>
            </tr>
          </thead>
          <tbody>
            {claims.map((c) => (
              <tr key={c.id} className="border-t border-ink-100">
                {canPay && (
                  <td className="px-3 py-2">
                    <input type="checkbox" aria-label={`Pay ${c.title}`} checked={picked.has(c.id)} onChange={(e) => toggle(c.id, e.target.checked)} />
                  </td>
                )}
                <td className="px-3 py-2">
                  <span className="font-medium text-ink-900">{c.employeeName}</span>
                  <span className="block text-[11px] text-ink-400">{c.employeeCode}{c.branchName && ` · ${c.branchName}`}</span>
                </td>
                <td className="px-3 py-2">
                  <span className="text-ink-800">{c.title}</span>
                  <span className="block text-[11px] text-ink-400">
                    {c.claimNo != null && `No. ${String(c.claimNo).padStart(3, '0')} · `}{c.typeLabel}
                  </span>
                </td>
                <td className="px-3 py-2 text-xs text-ink-600">
                  {c.approvedAt ? new Date(c.approvedAt).toLocaleDateString('en-IN', { day: 'numeric', month: 'short' }) : '—'}
                  {c.approvedBy && <span className="block text-[11px] text-ink-400">{c.approvedBy}</span>}
                </td>
                <td className="px-3 py-2 text-xs">
                  {c.hasPhoto && <a className="text-brand-700 hover:underline" href={`/api/integrations/hr/claims/${c.id}/file?which=photo`} target="_blank" rel="noopener">Photo</a>}
                  {c.hasPhoto && c.hasDocument && ' · '}
                  {c.hasDocument && <a className="text-brand-700 hover:underline" href={`/api/integrations/hr/claims/${c.id}/file?which=pdf`} target="_blank" rel="noopener">PDF</a>}
                  {!c.hasPhoto && !c.hasDocument && <span className="text-ink-400">—</span>}
                </td>
                <td className="numeric px-3 py-2 font-semibold">{inr.format(c.amount)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {canPay && (
        <div className="grid gap-3 rounded-xl border border-ink-100 p-4 sm:grid-cols-5 sm:items-end">
          <div>
            <Label htmlFor="cl-book" className="mb-1 block text-xs">Pay from</Label>
            <select id="cl-book" value={book} onChange={(e) => setBook(e.target.value as 'CASH' | 'BANK')} className="field h-10 w-full px-3 text-sm">
              <option value="CASH">Cash{branchName ? ` — ${branchName}` : ''}</option>
              {banks.length > 0 && <option value="BANK">Bank</option>}
            </select>
          </div>
          {book === 'BANK' ? (
            <div>
              <Label htmlFor="cl-bank" className="mb-1 block text-xs">Bank account</Label>
              <select id="cl-bank" value={bank} onChange={(e) => setBank(e.target.value)} className="field h-10 w-full px-3 text-sm">
                {banks.map((b) => <option key={b.value} value={b.value}>{b.label}</option>)}
              </select>
            </div>
          ) : <div />}
          <div>
            <Label htmlFor="cl-date" className="mb-1 block text-xs">Date</Label>
            <Input id="cl-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
          </div>
          <div>
            <Label htmlFor="cl-ref" className="mb-1 block text-xs">Reference</Label>
            <Input id="cl-ref" value={reference} onChange={(e) => setReference(e.target.value)} placeholder="Voucher / UTR" />
          </div>
          <Button type="button" onClick={pay} disabled={pending || picked.size === 0}>
            {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Banknote aria-hidden />}
            Pay {picked.size > 0 ? inr.format(total) : ''}
          </Button>
        </div>
      )}
      {error && <p role="alert" className="rounded-xl bg-danger-50 px-3 py-2 text-sm text-danger-700">{error}</p>}
      {notice && (
        <p className="flex items-center justify-between rounded-xl bg-positive-50 px-3 py-2 text-sm text-positive-700">
          {notice}
          {printId && (
            <Button type="button" size="sm" variant="secondary" onClick={() => window.open(`/print/cash/${printId}?print=1`, '_blank', 'noopener')}>
              <Printer aria-hidden />Print voucher
            </Button>
          )}
        </p>
      )}
    </div>
  );
}
