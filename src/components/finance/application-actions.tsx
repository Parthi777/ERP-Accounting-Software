'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { BadgeCheck, Banknote, Loader2, X } from 'lucide-react';

import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import {
  decideFinanceApplicationAction,
  receiveFinanceDdAction,
} from '@/server/services/finance/finance-actions';
import { useIdempotencyKey } from '@/components/forms/use-idempotency-key';
import { formatINR, fromRupees } from '@/lib/money';

type Bearer = 'CUSTOMER' | 'DEALER';
interface DeductionRow { amount: string; borneBy: Bearer; note: string }
const DEDUCTIONS = [
  { kind: 'DOCUMENT_CHARGES', label: 'Document charges' },
  { kind: 'FREIGHT', label: 'Freight charges' },
  { kind: 'OTHER', label: 'Other deduction' },
] as const;
type DeductionKind = (typeof DEDUCTIONS)[number]['kind'];
const freshDeductions = (): Record<DeductionKind, DeductionRow> => ({
  DOCUMENT_CHARGES: { amount: '', borneBy: 'CUSTOMER', note: '' },
  FREIGHT: { amount: '', borneBy: 'DEALER', note: '' },
  OTHER: { amount: '', borneBy: 'DEALER', note: '' },
});

type Dialog = 'approve' | 'reject' | 'disburse' | null;

/**
 * What can be done to a finance application — spec §27.
 *
 * Only the next legal step is offered: an application is approved or rejected
 * before it can disburse, and a rejection states why. Receiving the DD asks which
 * bank account the money reached, because the bank book has to show it too, and
 * what the financier kept back (document charges, freight): each is charged to
 * the customer or to the dealer, and the loan is settled by DD + deductions.
 */
export function ApplicationActions({
  applicationId,
  applicationNumber,
  approvalStatus,
  disbursementStatus,
  pendingAmount,
  bankAccounts,
  canManage,
}: {
  readonly applicationId: string;
  readonly applicationNumber: string;
  readonly approvalStatus: string;
  readonly disbursementStatus: string;
  /** In rupees, for the default disbursement amount. */
  readonly pendingAmount: number;
  readonly bankAccounts: readonly { id: string; label: string }[];
  readonly canManage: boolean;
}) {
  const router = useRouter();
  const [dialog, setDialog] = React.useState<Dialog>(null);
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [amount, setAmount] = React.useState('');
  const [reason, setReason] = React.useState('');
  const [bankAccountId, setBankAccountId] = React.useState(bankAccounts[0]?.id ?? '');
  const [reference, setReference] = React.useState('');
  const [ddDate, setDdDate] = React.useState(() => new Date().toISOString().slice(0, 10));
  const [deductions, setDeductions] = React.useState(freshDeductions);
  const idempotency = useIdempotencyKey(`finance-dd:${applicationId}`);

  const deducted = DEDUCTIONS.reduce((sum, d) => sum + (Number(deductions[d.kind].amount) || 0), 0);
  const settles = (Number(amount) || 0) + deducted;
  const updateDeduction = (kind: DeductionKind, patch: Partial<DeductionRow>) =>
    setDeductions((current) => ({ ...current, [kind]: { ...current[kind], ...patch } }));

  const run = (fn: () => Promise<{ ok: boolean; error?: string }>) => {
    setError(null);
    startTransition(async () => {
      const result = await fn();
      if (!result.ok) {
        setError(result.error ?? 'That action could not be completed.');
        return;
      }
      setDialog(null);
      setAmount('');
      setReason('');
      setReference('');
      setDeductions(freshDeductions());
      idempotency.renew();
      router.refresh();
    });
  };

  if (!canManage) return null;

  const open = (which: Dialog) => {
    setError(null);
    if (which === 'approve') setAmount(String(pendingAmount));
    if (which === 'disburse') {
      setAmount(String(pendingAmount));
      setDeductions(freshDeductions());
    }
    setDialog(which);
  };

  const canDisburse =
    approvalStatus === 'APPROVED' && disbursementStatus !== 'DISBURSED' && pendingAmount > 0;

  return (
    <>
      <div className="flex items-center justify-end gap-1">
        {approvalStatus === 'PENDING' && (
          <>
            <Button size="sm" variant="ghost" onClick={() => open('approve')}>
              <BadgeCheck aria-hidden />
              Approve
            </Button>
            <Button size="sm" variant="ghost" onClick={() => open('reject')}>
              <X aria-hidden />
              Reject
            </Button>
          </>
        )}
        {canDisburse && (
          <Button size="sm" variant="secondary" onClick={() => open('disburse')}>
            <Banknote aria-hidden />
            Receive DD
          </Button>
        )}
      </div>

      {dialog && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
          role="dialog"
          aria-modal="true"
          onClick={() => setDialog(null)}
        >
          <div
            className={`glass-strong max-h-[90vh] w-full overflow-y-auto rounded-2xl p-6 ${dialog === 'disburse' ? 'max-w-xl' : 'max-w-md'}`}
            onClick={(e) => e.stopPropagation()}
          >
            <h2 className="text-sm font-semibold text-ink-900">
              {dialog === 'approve' && `Approve ${applicationNumber}?`}
              {dialog === 'reject' && `Reject ${applicationNumber}?`}
              {dialog === 'disburse' && `Receive DD for ${applicationNumber}`}
            </h2>

            <p className="mt-1 text-sm text-ink-600">
              {dialog === 'approve' &&
                'Enter the amount the finance company actually agreed to, which may be less than was asked for.'}
              {dialog === 'reject' && 'The reason stays on the application and in the audit trail.'}
              {dialog === 'disburse' &&
                'Enter the DD as received, and anything the financier kept back. The loan is settled by the DD plus the deductions; the journal, bank book and company ledger move together.'}
            </p>

            {error && (
              <div role="alert" className="mt-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
                {error}
              </div>
            )}

            <div className="mt-4 space-y-3">
              {(dialog === 'approve' || dialog === 'disburse') && (
                <div>
                  <Label htmlFor="fin-amount" className="mb-1.5 block">
                    {dialog === 'disburse' ? 'DD amount' : 'Amount'}<span className="ml-0.5 text-danger-600">*</span>
                  </Label>
                  <Input
                    id="fin-amount"
                    type="number"
                    step="0.01"
                    min="0"
                    value={amount}
                    onChange={(e) => setAmount(e.target.value)}
                    autoFocus
                  />
                  {dialog === 'disburse' && (
                    <p className="mt-1 text-xs text-ink-400">
                      {formatINR(fromRupees(pendingAmount))} of the loan is still due. A part payment is fine.
                    </p>
                  )}
                </div>
              )}

              {dialog === 'disburse' && (
                <>
                  <div>
                    <Label htmlFor="fin-bank" className="mb-1.5 block">
                      Bank account<span className="ml-0.5 text-danger-600">*</span>
                    </Label>
                    <select
                      id="fin-bank"
                      value={bankAccountId}
                      onChange={(e) => setBankAccountId(e.target.value)}
                      className="h-9 w-full field px-3 text-sm"
                    >
                      <option value="">Choose the account the money reached</option>
                      {bankAccounts.map((b) => (
                        <option key={b.id} value={b.id}>{b.label}</option>
                      ))}
                    </select>
                  </div>
                  <div className="grid gap-3 sm:grid-cols-2">
                    <div>
                      <Label htmlFor="fin-ref" className="mb-1.5 block">DD number or UTR</Label>
                      <Input
                        id="fin-ref"
                        value={reference}
                        onChange={(e) => setReference(e.target.value)}
                        placeholder="e.g. DD-889120"
                      />
                    </div>
                    <div>
                      <Label htmlFor="fin-date" className="mb-1.5 block">Date received</Label>
                      <Input id="fin-date" type="date" value={ddDate} onChange={(e) => setDdDate(e.target.value)} />
                    </div>
                  </div>

                  <div className="rounded-xl border border-ink-200 bg-white/70 p-3">
                    <p className="text-xs font-semibold text-ink-700">Kept back by the financier</p>
                    <p className="mb-2 text-[11px] text-ink-500">
                      Charged to the customer: added to what they owe you. Dealer&rsquo;s cost: an expense.
                    </p>
                    <div className="space-y-2">
                      {DEDUCTIONS.map((d) => (
                        <div key={d.kind} className="grid grid-cols-[1fr_7rem_8.5rem] items-center gap-2">
                          {d.kind === 'OTHER' ? (
                            <Input
                              aria-label="What the other deduction is for"
                              value={deductions.OTHER.note}
                              onChange={(e) => updateDeduction('OTHER', { note: e.target.value })}
                              placeholder="Other (say what)"
                              className="h-8 text-sm"
                            />
                          ) : (
                            <span className="text-sm text-ink-700">{d.label}</span>
                          )}
                          <Input
                            aria-label={`${d.label} amount`}
                            type="number" step="0.01" min="0" className="numeric h-8"
                            value={deductions[d.kind].amount}
                            onChange={(e) => updateDeduction(d.kind, { amount: e.target.value })}
                            placeholder="0.00"
                          />
                          <select
                            aria-label={`Who bears the ${d.label.toLowerCase()}`}
                            value={deductions[d.kind].borneBy}
                            onChange={(e) => updateDeduction(d.kind, { borneBy: e.target.value as Bearer })}
                            className="h-8 field px-2 text-xs"
                          >
                            <option value="CUSTOMER">Customer pays</option>
                            <option value="DEALER">Dealer&rsquo;s cost</option>
                          </select>
                        </div>
                      ))}
                    </div>
                  </div>

                  <div className={`rounded-lg px-3 py-2 text-xs ${settles > pendingAmount + 0.001 ? 'bg-danger-50 text-danger-700' : 'bg-brand-50 text-brand-800'}`}>
                    DD {formatINR(fromRupees(Number(amount) || 0))} + deductions {formatINR(fromRupees(deducted))}
                    {' '}= <strong>{formatINR(fromRupees(settles))}</strong> settled of {formatINR(fromRupees(pendingAmount))} due
                    {settles > pendingAmount + 0.001
                      ? ' — more than is due.'
                      : settles < pendingAmount - 0.001
                        ? ` · ${formatINR(fromRupees(pendingAmount - settles))} will stay pending.`
                        : ' · settles the loan in full.'}
                  </div>
                </>
              )}

              {dialog === 'reject' && (
                <div>
                  <Label htmlFor="fin-reason" className="mb-1.5 block">
                    Reason<span className="ml-0.5 text-danger-600">*</span>
                  </Label>
                  <textarea
                    id="fin-reason"
                    rows={3}
                    value={reason}
                    onChange={(e) => setReason(e.target.value)}
                    placeholder="e.g. Credit check not cleared"
                    className="w-full field px-3 py-2 text-sm"
                  />
                </div>
              )}
            </div>

            <div className="mt-4 flex justify-end gap-2">
              <Button variant="secondary" size="sm" onClick={() => setDialog(null)} disabled={pending}>
                Back
              </Button>

              {dialog === 'approve' && (
                <Button
                  size="sm"
                  disabled={pending || !(Number(amount) > 0)}
                  onClick={() => run(() => decideFinanceApplicationAction(applicationId, 'APPROVED', Number(amount)))}
                >
                  {pending && <Loader2 className="animate-spin" aria-hidden />}
                  Approve
                </Button>
              )}

              {dialog === 'reject' && (
                <Button
                  variant="danger"
                  size="sm"
                  disabled={pending || !reason.trim()}
                  onClick={() =>
                    run(() => decideFinanceApplicationAction(applicationId, 'REJECTED', undefined, reason))
                  }
                >
                  {pending && <Loader2 className="animate-spin" aria-hidden />}
                  Reject
                </Button>
              )}

              {dialog === 'disburse' && (
                <Button
                  size="sm"
                  disabled={pending || !(settles > 0) || settles > pendingAmount + 0.001
                    || (Number(amount) > 0 && !bankAccountId)}
                  onClick={() =>
                    run(() =>
                      receiveFinanceDdAction({
                        applicationId,
                        bankAccountId,
                        ddAmount: Number(amount) || 0,
                        deductions: DEDUCTIONS.map((d) => ({
                          kind: d.kind,
                          amount: Number(deductions[d.kind].amount) || 0,
                          borneBy: deductions[d.kind].borneBy,
                          note: d.kind === 'OTHER' ? deductions.OTHER.note : null,
                        })),
                        ddNumber: reference || null,
                        date: ddDate,
                        idempotencyKey: idempotency.key(),
                      }),
                    )
                  }
                >
                  {pending && <Loader2 className="animate-spin" aria-hidden />}
                  Record DD
                </Button>
              )}
            </div>
          </div>
        </div>
      )}
    </>
  );
}
