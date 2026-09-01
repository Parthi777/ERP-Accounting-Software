'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { BadgeCheck, Banknote, Loader2, X } from 'lucide-react';

import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import {
  decideFinanceApplicationAction,
  disburseFinanceApplicationAction,
} from '@/server/services/finance/finance-actions';

type Dialog = 'approve' | 'reject' | 'disburse' | null;

/**
 * What can be done to a finance application — spec §27.
 *
 * Only the next legal step is offered: an application is approved or rejected
 * before it can disburse, and a rejection states why. Disbursement asks which
 * bank account the money reached, because the bank book has to show it too — a
 * disbursement that exists only in the ledger cannot be reconciled.
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
      router.refresh();
    });
  };

  if (!canManage) return null;

  const open = (which: Dialog) => {
    setError(null);
    if (which === 'approve') setAmount(String(pendingAmount));
    if (which === 'disburse') setAmount(String(pendingAmount));
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
            Disburse
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
          <div className="glass-strong w-full max-w-md rounded-2xl p-6" onClick={(e) => e.stopPropagation()}>
            <h2 className="text-sm font-semibold text-ink-900">
              {dialog === 'approve' && `Approve ${applicationNumber}?`}
              {dialog === 'reject' && `Reject ${applicationNumber}?`}
              {dialog === 'disburse' && `Record disbursement for ${applicationNumber}`}
            </h2>

            <p className="mt-1 text-sm text-ink-600">
              {dialog === 'approve' &&
                'Enter the amount the finance company actually agreed to, which may be less than was asked for.'}
              {dialog === 'reject' && 'The reason stays on the application and in the audit trail.'}
              {dialog === 'disburse' &&
                'This posts the journal, writes the bank book entry and moves the company ledger — together, or not at all.'}
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
                    Amount<span className="ml-0.5 text-danger-600">*</span>
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
                      {pendingAmount} still to be disbursed. A part payment is fine.
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
                      className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
                    >
                      <option value="">Choose the account the money reached</option>
                      {bankAccounts.map((b) => (
                        <option key={b.id} value={b.id}>{b.label}</option>
                      ))}
                    </select>
                  </div>
                  <div>
                    <Label htmlFor="fin-ref" className="mb-1.5 block">DD or bank reference</Label>
                    <Input
                      id="fin-ref"
                      value={reference}
                      onChange={(e) => setReference(e.target.value)}
                      placeholder="e.g. DD-889120"
                    />
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
                    className="w-full rounded-lg border border-ink-200 bg-white px-3 py-2 text-sm shadow-sm"
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
                  disabled={pending || !(Number(amount) > 0) || !bankAccountId}
                  onClick={() =>
                    run(() =>
                      disburseFinanceApplicationAction({
                        applicationId,
                        amount: Number(amount),
                        bankAccountId,
                        bankReference: reference || null,
                      }),
                    )
                  }
                >
                  {pending && <Loader2 className="animate-spin" aria-hidden />}
                  Record disbursement
                </Button>
              )}
            </div>
          </div>
        </div>
      )}
    </>
  );
}
