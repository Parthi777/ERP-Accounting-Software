'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Ban, Loader2 } from 'lucide-react';

import { Button } from '@/components/ui/button';
import { cancelBookingAction } from '@/server/services/sales/booking-actions';

/**
 * Cancel a booking.
 *
 * The reason is mandatory and goes to the audit trail (spec §46) — a cancelled
 * booking with an advance against it is a question someone will ask later.
 */
export function CancelBooking({ id, canCancel }: { readonly id: string; readonly canCancel: boolean }) {
  const router = useRouter();
  const [open, setOpen] = React.useState(false);
  const [reason, setReason] = React.useState('');
  const [error, setError] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  if (!canCancel) return null;

  const submit = () => {
    if (!reason.trim()) {
      setError('Enter a reason.');
      return;
    }
    setError(null);
    startTransition(async () => {
      const result = await cancelBookingAction(id, reason.trim());
      if (!result.ok) {
        setError(result.error ?? 'The booking could not be cancelled.');
        return;
      }
      setOpen(false);
      router.refresh();
    });
  };

  return (
    <>
      <Button variant="secondary" size="sm" onClick={() => setOpen(true)}>
        <Ban aria-hidden />
        Cancel booking
      </Button>

      {open && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
          role="dialog" aria-modal="true" aria-labelledby="cancel-title" onClick={() => setOpen(false)}>
          <div className="glass-strong w-full max-w-md rounded-2xl p-6" onClick={(e) => e.stopPropagation()}>
            <h2 id="cancel-title" className="text-sm font-semibold text-ink-900">Cancel this booking?</h2>
            <p className="mt-1 text-sm text-ink-600">
              Any advance already received stays in the ledger. Refund it separately as a cash payment.
            </p>

            <label className="mt-4 block">
              <span className="text-sm font-medium text-ink-700">Reason</span>
              <textarea
                rows={3}
                value={reason}
                onChange={(e) => setReason(e.target.value)}
                placeholder="Why is this booking being cancelled?"
                className="mt-1 w-full rounded-lg border border-ink-200 bg-white px-3 py-2 text-sm shadow-sm"
              />
            </label>

            {error && <p role="alert" className="mt-2 text-sm text-danger-600">{error}</p>}

            <div className="mt-4 flex justify-end gap-2">
              <Button variant="secondary" size="sm" onClick={() => setOpen(false)} disabled={pending}>
                Keep booking
              </Button>
              <Button variant="danger" size="sm" onClick={submit} disabled={pending}>
                {pending && <Loader2 className="animate-spin" aria-hidden />}
                Cancel booking
              </Button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
