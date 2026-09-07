'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { CheckCheck, Loader2 } from 'lucide-react';

import { decideAllPriceVersionsAction } from '@/server/services/vehicles/pricing-actions';
import { Button } from '@/components/ui/button';

/**
 * Approving or activating a whole price list at once — spec §15.
 *
 * A dealer's list arrives as the entire range: a new TVS sheet is dozens of
 * variants, and stepping through them individually is the same decision made
 * over and over until it stops being a decision. The confirmation below names
 * the count and what it will do, because that — not the number of clicks — is
 * what makes the approval considered.
 *
 * Each version is still decided individually on the server, so the two-person
 * rule and the audit row per price both survive; anything the caller may not
 * approve fails on its own and is reported rather than stopping the batch.
 */
export function BulkPriceActions({
  fromStatus,
  count,
}: {
  readonly fromStatus: 'SUBMITTED' | 'APPROVED';
  readonly count: number;
}) {
  const router = useRouter();
  const [open, setOpen] = React.useState(false);
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);

  const action = fromStatus === 'SUBMITTED' ? 'APPROVE' : 'ACTIVATE';
  const label = action === 'APPROVE' ? 'Approve all' : 'Activate all';

  const run = () => {
    setError(null);
    setNotice(null);
    startTransition(async () => {
      const result = await decideAllPriceVersionsAction(fromStatus, action);
      if (!result.ok) {
        setError(result.error ?? 'Nothing could be updated.');
        return;
      }
      setNotice(result.message ?? null);
      setOpen(false);
      router.refresh();
    });
  };

  if (count === 0) {
    return null;
  }

  return (
    <>
      <Button size="sm" variant="secondary" onClick={() => setOpen(true)} disabled={pending}>
        {pending ? <Loader2 className="animate-spin" aria-hidden /> : <CheckCheck aria-hidden />}
        {label} ({count})
      </Button>

      {notice && (
        <p role="status" className="mt-2 text-xs text-positive-700">{notice}</p>
      )}
      {error && !open && (
        <p role="alert" className="mt-2 text-xs text-danger-700">{error}</p>
      )}

      {open && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
          role="dialog" aria-modal="true" onClick={() => setOpen(false)}>
          <div className="glass-strong w-full max-w-md rounded-2xl p-6" onClick={(e) => e.stopPropagation()}>
            <h2 className="text-sm font-semibold text-ink-900">
              {label.replace(' all', '')} all {count} prices?
            </h2>
            <p className="mt-1 text-sm text-ink-600">
              {action === 'APPROVE'
                ? 'Every submitted price is approved in one go. Check the figures against the supplier’s price list first — once these go live, every invoice is computed from them.'
                : 'Every approved price goes live. Any price currently active for the same model and variant is superseded at the same moment, so there is never more than one live price.'}
            </p>
            {error && (
              <div role="alert" className="mt-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
                {error}
              </div>
            )}
            <div className="mt-4 flex justify-end gap-2">
              <Button variant="secondary" size="sm" onClick={() => setOpen(false)} disabled={pending}>
                Back
              </Button>
              <Button size="sm" onClick={run} disabled={pending}>
                {pending && <Loader2 className="animate-spin" aria-hidden />}
                {label}
              </Button>
            </div>
            {pending && (
              <p className="mt-3 text-xs text-ink-500">
                Each price is decided individually so the audit trail records every one — this takes
                a moment for a long list.
              </p>
            )}
          </div>
        </div>
      )}
    </>
  );
}
