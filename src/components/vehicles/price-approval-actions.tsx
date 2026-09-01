'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { BadgeCheck, Loader2, Rocket, Send, X } from 'lucide-react';

import { Button } from '@/components/ui/button';
import { decidePriceVersionAction } from '@/server/services/vehicles/pricing-actions';
import type { PriceAction } from '@/server/services/vehicles/pricing-service';

/**
 * Moving a price through its workflow — spec §15.
 *
 * Only the next legal step is offered, and only to whoever may take it: the
 * owner submits and activates, the approver approves or rejects. The database
 * refuses self-approval regardless, so a user holding both permissions still
 * cannot walk a price to live on their own.
 */
export function PriceApprovalActions({
  versionId,
  status,
  canManage,
  canApprove,
}: {
  readonly versionId: string;
  readonly status: string;
  readonly canManage: boolean;
  readonly canApprove: boolean;
}) {
  const router = useRouter();
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [rejecting, setRejecting] = React.useState(false);
  const [reason, setReason] = React.useState('');

  const run = (action: PriceAction, why?: string) => {
    setError(null);
    startTransition(async () => {
      const result = await decidePriceVersionAction(versionId, action, why);
      if (!result.ok) {
        setError(result.error ?? 'That action could not be completed.');
        return;
      }
      setRejecting(false);
      setReason('');
      router.refresh();
    });
  };

  return (
    <>
      <div className="flex items-center justify-end gap-1">
        {error && <span className="mr-2 max-w-xs text-[11px] text-danger-700">{error}</span>}

        {status === 'DRAFT' && canManage && (
          <Button size="sm" variant="ghost" disabled={pending} onClick={() => run('SUBMIT')}>
            {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Send aria-hidden />}
            Submit
          </Button>
        )}

        {status === 'SUBMITTED' && canApprove && (
          <>
            <Button size="sm" variant="ghost" disabled={pending} onClick={() => run('APPROVE')}>
              <BadgeCheck aria-hidden />
              Approve
            </Button>
            <Button size="sm" variant="ghost" disabled={pending} onClick={() => setRejecting(true)}>
              <X aria-hidden />
              Reject
            </Button>
          </>
        )}

        {status === 'APPROVED' && canManage && (
          <Button size="sm" variant="secondary" disabled={pending} onClick={() => run('ACTIVATE')}>
            {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Rocket aria-hidden />}
            Go live
          </Button>
        )}
      </div>

      {rejecting && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
          role="dialog" aria-modal="true" onClick={() => setRejecting(false)}
        >
          <div className="glass-strong w-full max-w-md rounded-2xl p-6" onClick={(e) => e.stopPropagation()}>
            <h2 className="text-sm font-semibold text-ink-900">Reject this price?</h2>
            <p className="mt-1 text-sm text-ink-600">
              It goes back as rejected and the reason is kept on the version, so whoever prepared it
              can see what to change.
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
                placeholder="e.g. Ex-showroom does not match the circular"
                className="mt-1 w-full rounded-lg border border-ink-200 bg-white px-3 py-2 text-sm shadow-sm"
              />
            </label>

            <div className="mt-4 flex justify-end gap-2">
              <Button variant="secondary" size="sm" onClick={() => setRejecting(false)} disabled={pending}>
                Back
              </Button>
              <Button
                variant="danger"
                size="sm"
                disabled={pending || !reason.trim()}
                onClick={() => run('REJECT', reason)}
              >
                {pending && <Loader2 className="animate-spin" aria-hidden />}
                Reject price
              </Button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
