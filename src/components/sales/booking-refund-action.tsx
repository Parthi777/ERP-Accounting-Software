'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, Undo2 } from 'lucide-react';

import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { refundBookingAdvanceAction } from '@/server/services/sales/booking-actions';

/**
 * Returning a cancelled booking's advance — spec §18, §23.
 *
 * Deliberately not automatic on cancellation: a cancelled booking's advance is
 * often kept as a forfeit, and refunding by default would post money the dealer
 * never paid. The reason is required because the entry is a movement of real
 * cash that someone will be asked about later.
 */
export function BookingRefundAction({
  bookingId,
  bookingNumber,
  maxAmount,
  bankAccounts,
}: {
  readonly bookingId: string;
  readonly bookingNumber: string;
  /** Rupees received and not yet reversed. */
  readonly maxAmount: number;
  readonly bankAccounts: readonly { id: string; label: string }[];
}) {
  const router = useRouter();
  const [open, setOpen] = React.useState(false);
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [amount, setAmount] = React.useState(String(maxAmount));
  const [mode, setMode] = React.useState<'CASH' | 'BANK'>('CASH');
  const [bankAccountId, setBankAccountId] = React.useState(bankAccounts[0]?.id ?? '');
  const [reason, setReason] = React.useState('');

  const value = Number(amount) || 0;

  const submit = () => {
    setError(null);
    startTransition(async () => {
      const result = await refundBookingAdvanceAction({
        bookingId,
        amount: value,
        mode,
        reason,
        bankAccountId: mode === 'BANK' ? bankAccountId : null,
      });
      if (!result.ok) {
        setError(result.error ?? 'The refund could not be recorded.');
        return;
      }
      setOpen(false);
      setReason('');
      router.refresh();
    });
  };

  return (
    <>
      <div className="flex justify-end">
        <Button size="sm" variant="ghost" onClick={() => setOpen(true)}>
          <Undo2 aria-hidden />
          Refund
        </Button>
      </div>

      {open && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
          role="dialog" aria-modal="true" onClick={() => setOpen(false)}
        >
          <div className="glass-strong w-full max-w-md rounded-2xl p-6" onClick={(e) => e.stopPropagation()}>
            <h2 className="text-sm font-semibold text-ink-900">Refund the advance on {bookingNumber}?</h2>
            <p className="mt-1 text-sm text-ink-600">
              This clears the liability the dealer is holding and pays the money out through the cash
              book or the bank. The receipt is marked reversed rather than deleted.
            </p>

            {error && (
              <div role="alert" className="mt-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
                {error}
              </div>
            )}

            <div className="mt-4 space-y-3">
              <div>
                <Label htmlFor="refund-amount" className="mb-1.5 block">
                  Amount<span className="ml-0.5 text-danger-600">*</span>
                </Label>
                <Input
                  id="refund-amount" type="number" step="0.01" min="0" max={maxAmount}
                  value={amount} onChange={(e) => setAmount(e.target.value)} autoFocus
                />
                <p className="mt-1 text-xs text-ink-400">{maxAmount} received and not yet returned.</p>
              </div>

              <div>
                <Label htmlFor="refund-mode" className="mb-1.5 block">Paid by</Label>
                <select
                  id="refund-mode" value={mode}
                  onChange={(e) => setMode(e.target.value as 'CASH' | 'BANK')}
                  className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
                >
                  <option value="CASH">Cash</option>
                  <option value="BANK">Bank</option>
                </select>
              </div>

              {mode === 'BANK' && (
                <div>
                  <Label htmlFor="refund-bank" className="mb-1.5 block">
                    Bank account<span className="ml-0.5 text-danger-600">*</span>
                  </Label>
                  <select
                    id="refund-bank" value={bankAccountId}
                    onChange={(e) => setBankAccountId(e.target.value)}
                    className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
                  >
                    <option value="">Choose an account</option>
                    {bankAccounts.map((b) => <option key={b.id} value={b.id}>{b.label}</option>)}
                  </select>
                </div>
              )}

              <div>
                <Label htmlFor="refund-reason" className="mb-1.5 block">
                  Reason<span className="ml-0.5 text-danger-600">*</span>
                </Label>
                <textarea
                  id="refund-reason" rows={3} value={reason}
                  onChange={(e) => setReason(e.target.value)}
                  placeholder="e.g. Customer cancelled, advance returned in full"
                  className="w-full rounded-lg border border-ink-200 bg-white px-3 py-2 text-sm shadow-sm"
                />
              </div>
            </div>

            <div className="mt-4 flex justify-end gap-2">
              <Button variant="secondary" size="sm" onClick={() => setOpen(false)} disabled={pending}>
                Back
              </Button>
              <Button
                variant="danger" size="sm"
                disabled={pending || !reason.trim() || !(value > 0) || (mode === 'BANK' && !bankAccountId)}
                onClick={submit}
              >
                {pending && <Loader2 className="animate-spin" aria-hidden />}
                Refund advance
              </Button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
