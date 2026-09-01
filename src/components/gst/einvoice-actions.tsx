'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, Send, Upload } from 'lucide-react';

import { Button } from '@/components/ui/button';
import { queueEinvoiceAction, submitEinvoiceAction } from '@/server/services/gst/gst-actions';

/**
 * Queue a document, then file it — spec §40.
 *
 * Two steps, deliberately. Queueing decides *what* to file and is instant and
 * local. Filing reaches the tax portal, can take seconds, and can fail for
 * reasons that have nothing to do with the invoice being correct. Collapsing
 * them into one button would make a network timeout look like a bad invoice.
 *
 * Nothing here can damage the accounting: a failed filing leaves the invoice
 * posted and the e-invoice retryable.
 */
export function EinvoiceActions({
  einvoiceId,
  documentType,
  documentId,
  status,
  attemptCount,
  canGenerate,
  canRetry,
  portalConfigured,
}: {
  readonly einvoiceId: string | null;
  readonly documentType: string;
  readonly documentId: string;
  readonly status: string;
  readonly attemptCount: number;
  readonly canGenerate: boolean;
  readonly canRetry: boolean;
  /** False when no provider is wired up, so filing is offered honestly. */
  readonly portalConfigured: boolean;
}) {
  const router = useRouter();
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);

  if (status === 'GENERATED') {
    return <span className="text-xs text-positive-700">Filed</span>;
  }

  const retrying = status === 'FAILED';
  if (retrying ? !canRetry : !canGenerate) {
    return null;
  }

  const run = (fn: () => Promise<{ ok: boolean; error?: string }>) => {
    setError(null);
    startTransition(async () => {
      const result = await fn();
      if (!result.ok) {
        setError(result.error ?? 'That could not be completed.');
      }
      // Refresh either way: a failure updates the attempt count and the recorded
      // error, which is what the operator needs to see next.
      router.refresh();
    });
  };

  // Not queued yet: the first step is local and always available.
  if (!einvoiceId) {
    return (
      <span className="inline-flex items-center gap-2">
        {error && <span className="max-w-xs text-[11px] text-danger-700">{error}</span>}
        <Button
          size="sm"
          variant="ghost"
          disabled={pending}
          onClick={() => run(() => queueEinvoiceAction(documentType, documentId))}
        >
          {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Upload aria-hidden />}
          Queue
        </Button>
      </span>
    );
  }

  return (
    <span className="inline-flex items-center gap-2">
      {error && <span className="max-w-xs text-[11px] text-danger-700">{error}</span>}
      <Button
        size="sm"
        variant={retrying ? 'secondary' : 'ghost'}
        disabled={pending || !portalConfigured}
        title={
          portalConfigured
            ? undefined
            : 'No e-invoice provider is configured, so nothing can be sent to the portal yet.'
        }
        onClick={() => run(() => submitEinvoiceAction(einvoiceId))}
      >
        {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Send aria-hidden />}
        {retrying ? `Retry${attemptCount > 0 ? ` (${attemptCount})` : ''}` : 'File'}
      </Button>
    </span>
  );
}
