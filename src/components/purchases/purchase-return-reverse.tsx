'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2 } from 'lucide-react';

import { cancelPurchaseReturnAction } from '@/server/services/purchases/purchase-return-actions';
import { Button } from '@/components/ui/button';

/**
 * Reversing a debit note — spec §23.
 *
 * The note was wrong, or the supplier would not take the goods. A second
 * journal undoes the first, the stock comes back into the lot it left and a
 * returned chassis comes back into stock. Both entries stay on the record; the
 * reason is what makes the pair explainable a year later.
 */
export function PurchaseReturnReverse({
  returnId,
  billId,
  returnNumber,
}: {
  readonly returnId: string;
  readonly billId: string;
  readonly returnNumber: string;
}) {
  const router = useRouter();
  const [open, setOpen] = React.useState(false);
  const [reason, setReason] = React.useState('');
  const [error, setError] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  const submit = () => {
    setError(null);
    startTransition(async () => {
      const result = await cancelPurchaseReturnAction(returnId, billId, reason);
      if (!result.ok) {
        setError(result.error ?? 'The note could not be reversed.');
        return;
      }
      setOpen(false);
      setReason('');
      router.refresh();
    });
  };

  return (
    <>
      <Button variant="danger" size="sm" onClick={() => setOpen(true)}>
        Reverse note
      </Button>

      {open && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
          role="dialog" aria-modal="true" onClick={() => setOpen(false)}>
          <div className="glass-strong w-full max-w-md rounded-2xl p-6" onClick={(e) => e.stopPropagation()}>
            <h2 className="text-sm font-semibold text-ink-900">Reverse {returnNumber}?</h2>
            <p className="mt-1 text-sm text-ink-600">
              A second journal undoes this one, the stock comes back into the lot it left, and any
              chassis on the note returns to stock. The note stays on the record as reversed.
            </p>

            {error && (
              <div role="alert" className="mt-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
                {error}
              </div>
            )}

            <label className="mt-4 block">
              <span className="text-sm font-medium text-ink-700">
                Reason<span className="ml-0.5 text-danger-600">*</span>
              </span>
              <textarea rows={3} value={reason} onChange={(e) => setReason(e.target.value)}
                placeholder="e.g. The supplier would not accept the chassis back"
                className="mt-1 w-full rounded-lg border border-ink-200 bg-white px-3 py-2 text-sm shadow-sm" />
            </label>

            <div className="mt-4 flex justify-end gap-2">
              <Button variant="secondary" size="sm" onClick={() => setOpen(false)} disabled={pending}>
                Back
              </Button>
              <Button variant="danger" size="sm" disabled={pending || !reason.trim()} onClick={submit}>
                {pending && <Loader2 className="animate-spin" aria-hidden />}
                Reverse note
              </Button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
