'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { FilePlus2, Loader2, Send } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import {
  createFinanceSettlementAction,
  postFinanceSettlementAction,
} from '@/server/services/finance/finance-actions';

/**
 * Raising a settlement — spec §26.
 *
 * Net is never typed. It is gross less commission and deductions, shown as the
 * form is filled so the operator can check it against the company's statement
 * before anything is saved; the database computes the stored value.
 */
export function SettlementForm({
  companies,
}: {
  readonly companies: readonly { id: string; label: string }[];
}) {
  const router = useRouter();
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);
  const [companyId, setCompanyId] = React.useState('');
  const [from, setFrom] = React.useState('');
  const [to, setTo] = React.useState('');
  const [gross, setGross] = React.useState('');
  const [commission, setCommission] = React.useState('');
  const [deductions, setDeductions] = React.useState('');

  const grossValue = Number(gross) || 0;
  const commissionValue = Number(commission) || 0;
  const deductionsValue = Number(deductions) || 0;
  const net = grossValue - commissionValue - deductionsValue;

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);
    setNotice(null);

    if (!companyId) return setError('Choose the finance company.');
    if (!(grossValue > 0)) return setError('Enter a gross amount greater than zero.');
    if (net < 0) return setError('Commission and deductions together cannot exceed the gross.');

    startTransition(async () => {
      const result = await createFinanceSettlementAction({
        companyId,
        from: from || new Date().toISOString().slice(0, 10),
        to: to || new Date().toISOString().slice(0, 10),
        gross: grossValue,
        commission: commissionValue,
        deductions: deductionsValue,
      });

      if (!result.ok) {
        setError(result.error ?? 'The settlement could not be created.');
        return;
      }
      setNotice(`${result.number} raised as a draft. Post it once the money is in the bank.`);
      setGross('');
      setCommission('');
      setDeductions('');
      router.refresh();
    });
  };

  if (companies.length === 0) {
    return (
      <Panel className="p-5">
        <h2 className="text-sm font-semibold text-ink-900">Raise a settlement</h2>
        <p className="mt-1 text-xs text-ink-500">No active finance companies to settle with.</p>
      </Panel>
    );
  }

  return (
    <Panel className="p-5">
      <h2 className="flex items-center gap-2 text-sm font-semibold text-ink-900">
        <FilePlus2 className="text-brand-600" aria-hidden />
        Raise a settlement
      </h2>
      <p className="mb-4 text-xs text-ink-500">
        A settlement is a draft until it is posted, so the figures can be checked against the
        company&rsquo;s statement first.
      </p>

      <form onSubmit={submit} className="space-y-4" noValidate>
        {error && (
          <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
            {error}
          </div>
        )}
        {notice && (
          <div role="status" className="rounded-lg border border-positive-200 bg-positive-50 px-3 py-2 text-sm text-positive-700">
            {notice}
          </div>
        )}

        <div className="grid gap-4 sm:grid-cols-2">
          <div className="sm:col-span-2">
            <Label htmlFor="s-company" className="mb-1.5 block">
              Finance company<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <select
              id="s-company" value={companyId} onChange={(e) => setCompanyId(e.target.value)}
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            >
              <option value="">Choose a company</option>
              {companies.map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}
            </select>
          </div>

          <div>
            <Label htmlFor="s-from" className="mb-1.5 block">Period from</Label>
            <Input id="s-from" type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
          </div>
          <div>
            <Label htmlFor="s-to" className="mb-1.5 block">Period to</Label>
            <Input id="s-to" type="date" value={to} onChange={(e) => setTo(e.target.value)} />
          </div>

          <div>
            <Label htmlFor="s-gross" className="mb-1.5 block">
              Gross<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <Input id="s-gross" type="number" step="0.01" min="0" value={gross}
              onChange={(e) => setGross(e.target.value)} />
          </div>
          <div>
            <Label htmlFor="s-commission" className="mb-1.5 block">Commission withheld</Label>
            <Input id="s-commission" type="number" step="0.01" min="0" value={commission}
              onChange={(e) => setCommission(e.target.value)} />
          </div>
          <div>
            <Label htmlFor="s-deductions" className="mb-1.5 block">Deductions</Label>
            <Input id="s-deductions" type="number" step="0.01" min="0" value={deductions}
              onChange={(e) => setDeductions(e.target.value)} />
          </div>

          <div>
            <Label className="mb-1.5 block">Net to bank</Label>
            <div className="flex h-9 items-center rounded-lg border border-ink-200 bg-ink-50 px-3 text-sm">
              {grossValue > 0 ? (
                <span className={net < 0 ? 'font-medium text-danger-700' : 'font-medium text-ink-800'}>
                  {net.toFixed(2)}
                </span>
              ) : (
                <span className="text-ink-400">—</span>
              )}
            </div>
            <p className="mt-1 text-xs text-ink-400">Gross less commission and deductions.</p>
          </div>
        </div>

        <Button type="submit" size="sm" disabled={pending}>
          {pending ? <Loader2 className="animate-spin" aria-hidden /> : <FilePlus2 aria-hidden />}
          Raise draft
        </Button>
      </form>
    </Panel>
  );
}

/**
 * Posting clears the receivable at gross and puts the net in the bank. It is a
 * confirmation rather than a one-click action because it is not reversible
 * except by a further entry.
 */
export function SettlementPostAction({
  settlementId,
  settlementNumber,
  netLabel,
  bankAccounts,
}: {
  readonly settlementId: string;
  readonly settlementNumber: string;
  readonly netLabel: string;
  readonly bankAccounts: readonly { id: string; label: string }[];
}) {
  const router = useRouter();
  const [open, setOpen] = React.useState(false);
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [bankAccountId, setBankAccountId] = React.useState(bankAccounts[0]?.id ?? '');

  const submit = () => {
    setError(null);
    startTransition(async () => {
      const result = await postFinanceSettlementAction(settlementId, bankAccountId);
      if (!result.ok) {
        setError(result.error ?? 'The settlement could not be posted.');
        return;
      }
      setOpen(false);
      router.refresh();
    });
  };

  return (
    <>
      <div className="flex justify-end">
        <Button size="sm" variant="secondary" onClick={() => setOpen(true)}>
          <Send aria-hidden />
          Post
        </Button>
      </div>

      {open && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
          role="dialog" aria-modal="true" onClick={() => setOpen(false)}
        >
          <div className="glass-strong w-full max-w-md rounded-2xl p-6" onClick={(e) => e.stopPropagation()}>
            <h2 className="text-sm font-semibold text-ink-900">Post {settlementNumber}?</h2>
            <p className="mt-1 text-sm text-ink-600">
              The receivable clears at gross, the commission and deductions post as their own lines,
              and {netLabel} lands in the bank. A posted settlement is corrected by a further entry,
              never edited.
            </p>

            {error && (
              <div role="alert" className="mt-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
                {error}
              </div>
            )}

            <div className="mt-4">
              <Label htmlFor="post-bank" className="mb-1.5 block">
                Bank account<span className="ml-0.5 text-danger-600">*</span>
              </Label>
              <select
                id="post-bank" value={bankAccountId} onChange={(e) => setBankAccountId(e.target.value)}
                className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
              >
                <option value="">Choose the account it was paid into</option>
                {bankAccounts.map((b) => <option key={b.id} value={b.id}>{b.label}</option>)}
              </select>
            </div>

            <div className="mt-4 flex justify-end gap-2">
              <Button variant="secondary" size="sm" onClick={() => setOpen(false)} disabled={pending}>
                Back
              </Button>
              <Button size="sm" disabled={pending || !bankAccountId} onClick={submit}>
                {pending && <Loader2 className="animate-spin" aria-hidden />}
                Post settlement
              </Button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
