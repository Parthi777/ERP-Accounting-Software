'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, Undo2 } from 'lucide-react';

import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { returnSaleAction } from '@/server/services/sales/sale-actions';
import { formatINR, fromRupees, paise, subtract, toRupees } from '@/lib/money';

/**
 * Returning a posted sale, and paying back what was received — spec §21, §23, §37.
 *
 * A return is not an undo. It posts a second journal that reverses the first,
 * both stay on the record permanently, and — where the customer had paid — a
 * third that takes the money back out of the drawer or the bank. The reason is
 * required because it is written onto the reversal, which is what makes the set
 * explainable a year later.
 *
 * The refund is asked for here rather than left as a separate errand. A return
 * that reverses the invoice and says nothing about the ₹50,000 on the counter
 * leaves the customer in credit with no record of why, and the person doing it
 * has walked away by the time anyone notices.
 */
export function SaleReturnAction({
  saleId,
  invoiceNumber,
  paidAmount,
  financeAmount,
  bankAccounts,
}: {
  readonly saleId: string;
  readonly invoiceNumber: string;
  /** Received and not yet reversed, in paise. Excludes finance disbursement. */
  readonly paidAmount: number;
  /** Disbursed by a financier, in paise. Not refundable to the customer here. */
  readonly financeAmount: number;
  readonly bankAccounts: readonly { id: string; label: string }[];
}) {
  const router = useRouter();
  const [open, setOpen] = React.useState(false);
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [reason, setReason] = React.useState('');

  const received = paise(paidAmount);
  const financed = paise(financeAmount);
  const hasPayment = received > 0;

  const [amount, setAmount] = React.useState(hasPayment ? String(toRupees(received)) : '');
  const [mode, setMode] = React.useState<'CASH' | 'BANK'>('CASH');
  const [bankAccountId, setBankAccountId] = React.useState(bankAccounts[0]?.id ?? '');
  const [reference, setReference] = React.useState('');

  const value = Number(amount) || 0;
  const refunding = hasPayment ? fromRupees(value) : paise(0);
  const retained = subtract(received, refunding);

  const submit = () => {
    setError(null);

    if (hasPayment) {
      if (!(refunding > 0)) {
        return setError('Enter what is being refunded. It cannot be nil while money is held.');
      }
      if (refunding > received) {
        return setError(`Only ${formatINR(received)} was received against this invoice.`);
      }
      if (mode === 'BANK' && !bankAccountId) {
        return setError('Choose the bank account the refund is being paid from.');
      }
    }

    startTransition(async () => {
      const result = await returnSaleAction(
        saleId,
        reason,
        hasPayment
          ? {
              mode,
              amount: value,
              bankAccountId: mode === 'BANK' ? bankAccountId : null,
              reference: reference.trim() || null,
            }
          : { mode: null },
      );

      if (!result.ok) {
        setError(result.error ?? 'The sale could not be returned.');
        return;
      }
      setOpen(false);
      setReason('');
      setReference('');
      router.refresh();
    });
  };

  return (
    <>
      <div className="flex justify-end">
        <Button size="sm" variant="ghost" onClick={() => setOpen(true)}>
          <Undo2 aria-hidden />
          Return
        </Button>
      </div>

      {open && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
          role="dialog"
          aria-modal="true"
          onClick={() => setOpen(false)}
        >
          <div
            className="glass-strong max-h-[90vh] w-full max-w-md overflow-y-auto rounded-2xl p-6"
            onClick={(e) => e.stopPropagation()}
          >
            <h2 className="text-sm font-semibold text-ink-900">Return invoice {invoiceNumber}?</h2>
            <p className="mt-1 text-sm text-ink-600">
              The invoice is not edited or deleted. Its journal is reversed by a second entry, the
              vehicle goes back into stock and any fitted accessories return to the lot they came
              from.
            </p>

            {error && (
              <div
                role="alert"
                className="mt-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700"
              >
                {error}
              </div>
            )}

            {hasPayment && (
              <div className="mt-4 space-y-3 rounded-xl border border-warning-200 bg-warning-50/60 p-3">
                <p className="text-xs text-warning-800">
                  <span className="numeric font-semibold">{formatINR(received)}</span> was received
                  against this invoice. Reversing it alone would leave the customer in credit, so
                  say how the money goes back.
                </p>

                <div>
                  <Label htmlFor="refund-amount" className="mb-1.5 block">
                    Refund amount<span className="ml-0.5 text-danger-600">*</span>
                  </Label>
                  <div className="relative">
                    <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-ink-400">
                      ₹
                    </span>
                    <Input
                      id="refund-amount"
                      type="number"
                      step="0.01"
                      min="0"
                      className="pl-7"
                      value={amount}
                      onChange={(e) => setAmount(e.target.value)}
                    />
                  </div>
                  {retained > 0 && refunding > 0 && (
                    // Not absorbed into income. It stays a credit on the ledger,
                    // where Accounts can see it and decide what it is.
                    <p className="mt-1 text-xs text-warning-800">
                      {formatINR(retained)} stays to the customer&rsquo;s credit on their ledger.
                    </p>
                  )}
                </div>

                <div>
                  <Label htmlFor="refund-mode" className="mb-1.5 block">
                    Paid back by<span className="ml-0.5 text-danger-600">*</span>
                  </Label>
                  <select
                    id="refund-mode"
                    value={mode}
                    onChange={(e) => setMode(e.target.value as 'CASH' | 'BANK')}
                    className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
                  >
                    <option value="CASH">Cash — from the branch drawer</option>
                    <option value="BANK">Bank — transfer, cheque or DD</option>
                  </select>
                  <p className="mt-1 text-xs text-ink-500">
                    {mode === 'CASH'
                      ? 'Written to the branch cash book as a payment. The day must be open.'
                      : 'Written to the bank book as a payment.'}
                  </p>
                </div>

                {mode === 'BANK' && (
                  <div>
                    <Label htmlFor="refund-bank" className="mb-1.5 block">
                      Bank account<span className="ml-0.5 text-danger-600">*</span>
                    </Label>
                    <select
                      id="refund-bank"
                      value={bankAccountId}
                      onChange={(e) => setBankAccountId(e.target.value)}
                      className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
                    >
                      <option value="">Choose an account</option>
                      {bankAccounts.map((b) => (
                        <option key={b.id} value={b.id}>{b.label}</option>
                      ))}
                    </select>
                  </div>
                )}

                <div>
                  <Label htmlFor="refund-reference" className="mb-1.5 block">
                    Reference
                  </Label>
                  <Input
                    id="refund-reference"
                    value={reference}
                    onChange={(e) => setReference(e.target.value)}
                    placeholder={mode === 'CASH' ? 'Voucher number' : 'UTR, cheque or DD number'}
                  />
                </div>
              </div>
            )}

            {financed > 0 && (
              <p className="mt-4 rounded-xl border border-brand-200 bg-brand-50 p-3 text-xs text-brand-800">
                <span className="numeric font-semibold">{formatINR(financed)}</span> of this invoice
                was disbursed by a financier. Reversing the invoice reverses that receivable, but the
                money itself goes back through a finance settlement, not through this refund.
              </p>
            )}

            <label className="mt-4 block">
              <span className="text-sm font-medium text-ink-700">
                Reason<span className="ml-0.5 text-danger-600">*</span>
              </span>
              <textarea
                rows={3}
                value={reason}
                onChange={(e) => setReason(e.target.value)}
                placeholder="e.g. Customer rejected delivery — colour mismatch"
                className="mt-1 w-full rounded-lg border border-ink-200 bg-white px-3 py-2 text-sm shadow-sm"
              />
              <span className="mt-1 block text-xs text-ink-400">
                Recorded on the reversal, on the refund and in the audit trail.
              </span>
            </label>

            <div className="mt-4 flex justify-end gap-2">
              <Button variant="secondary" size="sm" onClick={() => setOpen(false)} disabled={pending}>
                Back
              </Button>
              <Button
                variant="danger"
                size="sm"
                disabled={pending || !reason.trim() || (hasPayment && !(value > 0))}
                onClick={submit}
              >
                {pending && <Loader2 className="animate-spin" aria-hidden />}
                {hasPayment ? 'Return and refund' : 'Return sale'}
              </Button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
