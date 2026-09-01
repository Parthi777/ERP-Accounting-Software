'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, Undo2 } from 'lucide-react';

import { Button } from '@/components/ui/button';
import { returnSaleAction } from '@/server/services/sales/sale-actions';

/**
 * Returning a posted sale — spec §21, §23.
 *
 * Deliberately a two-step action behind a confirmation. A return is not an
 * undo: it posts a second journal that reverses the first, and both stay on the
 * record permanently. The reason is required because it is written onto the
 * reversal, which is what makes the pair explainable a year later.
 */
export function SaleReturnAction({
  saleId,
  invoiceNumber,
  hasPayment,
}: {
  readonly saleId: string;
  readonly invoiceNumber: string;
  readonly hasPayment: boolean;
}) {
  const router = useRouter();
  const [open, setOpen] = React.useState(false);
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [reason, setReason] = React.useState('');

  const submit = () => {
    setError(null);
    startTransition(async () => {
      const result = await returnSaleAction(saleId, reason);
      if (!result.ok) {
        setError(result.error ?? 'The sale could not be returned.');
        return;
      }
      setOpen(false);
      setReason('');
      router.refresh();
    });
  };

  // Money received has to be refunded first, or the reversal would leave the
  // customer in credit with nothing recording it. Saying so here saves a
  // round trip to the database to be told the same thing.
  if (hasPayment) {
    return (
      <span className="text-[11px] text-ink-400" title="Refund the receipt before returning the sale">
        Payment received
      </span>
    );
  }

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
          <div className="glass-strong w-full max-w-md rounded-2xl p-6" onClick={(e) => e.stopPropagation()}>
            <h2 className="text-sm font-semibold text-ink-900">Return invoice {invoiceNumber}?</h2>
            <p className="mt-1 text-sm text-ink-600">
              The invoice is not edited or deleted. Its journal is reversed by a second entry, the
              vehicle goes back into stock and any fitted accessories return to the lot they came
              from.
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
              <textarea
                rows={3}
                value={reason}
                onChange={(e) => setReason(e.target.value)}
                placeholder="e.g. Customer rejected delivery — colour mismatch"
                className="mt-1 w-full rounded-lg border border-ink-200 bg-white px-3 py-2 text-sm shadow-sm"
              />
              <span className="mt-1 block text-xs text-ink-400">
                Recorded on the reversal and in the audit trail.
              </span>
            </label>

            <div className="mt-4 flex justify-end gap-2">
              <Button variant="secondary" size="sm" onClick={() => setOpen(false)} disabled={pending}>
                Back
              </Button>
              <Button variant="danger" size="sm" disabled={pending || !reason.trim()} onClick={submit}>
                {pending && <Loader2 className="animate-spin" aria-hidden />}
                Return sale
              </Button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
