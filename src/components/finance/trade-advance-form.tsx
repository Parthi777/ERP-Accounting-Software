'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Handshake, Loader2 } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { recordTradeAdvanceAction } from '@/server/services/finance/finance-actions';
import {
  BANK_BACKED_TYPES,
  TRADE_ADVANCE_TYPES,
  type TradeAdvanceType,
} from '@/lib/finance/trade-advance';

/** What each type does, in the words a dealer would use — spec §26. */
const EXPLANATIONS: Record<TradeAdvanceType, string> = {
  ADVANCE_RECEIVED: 'The company funds the dealer ahead of sales. Cash in, and the dealer owes it back.',
  VEHICLE_ADJUSTMENT: 'An advance already held is consumed by a vehicle the company financed.',
  SETTLEMENT: 'The company pays what it owes against financed vehicles.',
  REFUND: 'Unused advance is returned to the company.',
  COMMISSION: 'Commission earned but not yet received, so it is receivable rather than cash.',
  MANUAL_ADJUSTMENT: 'A correction between the two finance accounts. The ledger is append-only, so a mistake is fixed by a further entry.',
};

function label(type: TradeAdvanceType): string {
  return type.charAt(0) + type.slice(1).toLowerCase().replace(/_/g, ' ');
}

/**
 * Recording a movement against a finance company — spec §26.
 *
 * The type drives the accounts, not the operator: choosing the wrong contra
 * account is exactly the mistake an accounting-first ERP should make impossible.
 */
export function TradeAdvanceForm({
  companies,
  bankAccounts,
  selectedCompanyId,
}: {
  readonly companies: readonly { id: string; label: string }[];
  readonly bankAccounts: readonly { id: string; label: string }[];
  readonly selectedCompanyId: string;
}) {
  const router = useRouter();
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);
  const [companyId, setCompanyId] = React.useState(selectedCompanyId);
  const [type, setType] = React.useState<TradeAdvanceType>('ADVANCE_RECEIVED');
  const [amount, setAmount] = React.useState('');
  const [bankAccountId, setBankAccountId] = React.useState(bankAccounts[0]?.id ?? '');
  const [narration, setNarration] = React.useState('');
  const [reference, setReference] = React.useState('');

  const needsBank = BANK_BACKED_TYPES.includes(type);
  const value = Number(amount) || 0;

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);
    setNotice(null);

    if (!companyId) return setError('Choose the finance company.');
    if (!(value > 0)) return setError('Enter an amount greater than zero.');
    if (needsBank && !bankAccountId) {
      return setError('Choose the bank account the money moved through.');
    }

    startTransition(async () => {
      const result = await recordTradeAdvanceAction({
        companyId,
        type,
        amount: value,
        bankAccountId: needsBank ? bankAccountId : null,
        narration: narration.trim() || null,
        reference: reference.trim() || null,
      });

      if (!result.ok) {
        setError(result.error ?? 'The entry could not be recorded.');
        return;
      }
      setNotice(result.message ?? 'Recorded.');
      setAmount('');
      setNarration('');
      setReference('');
      router.refresh();
    });
  };

  if (companies.length === 0) {
    return (
      <Panel className="p-5">
        <h2 className="text-sm font-semibold text-ink-900">Record a movement</h2>
        <p className="mt-1 text-xs text-ink-500">
          No active finance companies. Spec §25 keeps a separate ledger per company, so a movement
          must name one.
        </p>
      </Panel>
    );
  }

  return (
    <Panel className="p-5">
      <h2 className="flex items-center gap-2 text-sm font-semibold text-ink-900">
        <Handshake className="text-brand-600" aria-hidden />
        Record a movement
      </h2>
      <p className="mb-4 text-xs text-ink-500">
        The type decides which accounts are used, so the journal cannot be posted to the wrong side.
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
          <div>
            <Label htmlFor="ta-company" className="mb-1.5 block">
              Finance company<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <select
              id="ta-company"
              value={companyId}
              onChange={(e) => setCompanyId(e.target.value)}
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            >
              <option value="">Choose a company</option>
              {companies.map((c) => (
                <option key={c.id} value={c.id}>{c.label}</option>
              ))}
            </select>
          </div>

          <div>
            <Label htmlFor="ta-type" className="mb-1.5 block">
              Type<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <select
              id="ta-type"
              value={type}
              onChange={(e) => setType(e.target.value as TradeAdvanceType)}
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            >
              {TRADE_ADVANCE_TYPES.map((t) => (
                <option key={t} value={t}>{label(t)}</option>
              ))}
            </select>
            <p className="mt-1 text-xs text-ink-400">{EXPLANATIONS[type]}</p>
          </div>

          <div>
            <Label htmlFor="ta-amount" className="mb-1.5 block">
              Amount<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <div className="relative">
              <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-ink-400">₹</span>
              <Input
                id="ta-amount" type="number" step="0.01" min="0" className="pl-7"
                value={amount} onChange={(e) => setAmount(e.target.value)}
              />
            </div>
          </div>

          {needsBank && (
            <div>
              <Label htmlFor="ta-bank" className="mb-1.5 block">
                Bank account<span className="ml-0.5 text-danger-600">*</span>
              </Label>
              <select
                id="ta-bank"
                value={bankAccountId}
                onChange={(e) => setBankAccountId(e.target.value)}
                className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
              >
                <option value="">Choose an account</option>
                {bankAccounts.map((b) => (
                  <option key={b.id} value={b.id}>{b.label}</option>
                ))}
              </select>
              <p className="mt-1 text-xs text-ink-400">Money moved, so the bank book records it too.</p>
            </div>
          )}

          <div>
            <Label htmlFor="ta-reference" className="mb-1.5 block">Reference</Label>
            <Input
              id="ta-reference" value={reference} onChange={(e) => setReference(e.target.value)}
              placeholder="UTR, DD or voucher number"
            />
          </div>

          <div className={needsBank ? 'sm:col-span-2' : ''}>
            <Label htmlFor="ta-narration" className="mb-1.5 block">Narration</Label>
            <Input
              id="ta-narration" value={narration} onChange={(e) => setNarration(e.target.value)}
              placeholder="Defaults to the type and company name"
            />
          </div>
        </div>

        <Button type="submit" size="sm" disabled={pending}>
          {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Handshake aria-hidden />}
          Record
        </Button>
      </form>
    </Panel>
  );
}
