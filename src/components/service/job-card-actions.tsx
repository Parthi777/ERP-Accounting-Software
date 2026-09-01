'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, Receipt } from 'lucide-react';

import { Button } from '@/components/ui/button';
import {
  createServiceInvoiceAction,
  updateJobCardStatusAction,
} from '@/server/services/service/service-actions';

/**
 * What can be done to a job card from the list — spec §32.
 *
 * Only the next legal step is offered. A job that has not been worked on yet
 * cannot be billed, and one already billed offers its invoice instead.
 */
export function JobCardActions({
  jobCardId,
  status,
  invoiceId,
  canBill,
  canEdit,
}: {
  readonly jobCardId: string;
  readonly status: string;
  readonly invoiceId: string | null;
  readonly canBill: boolean;
  readonly canEdit: boolean;
}) {
  const router = useRouter();
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);

  const run = (fn: () => Promise<{ ok: boolean; error?: string; id?: string }>, then?: (id?: string) => void) => {
    setError(null);
    startTransition(async () => {
      const result = await fn();
      if (!result.ok) {
        setError(result.error ?? 'That action could not be completed.');
        return;
      }
      then?.(result.id);
      router.refresh();
    });
  };

  if (invoiceId) {
    return (
      <Button size="sm" variant="ghost" onClick={() => router.push(`/service/billing/${invoiceId}`)}>
        <Receipt aria-hidden />
        Open bill
      </Button>
    );
  }

  const next =
    status === 'OPEN' ? { to: 'IN_PROGRESS', label: 'Start work' }
      : status === 'IN_PROGRESS' ? { to: 'READY', label: 'Mark ready' }
        : null;

  return (
    <div className="flex items-center justify-end gap-1">
      {error && <span className="mr-2 text-[11px] text-danger-700">{error}</span>}

      {canEdit && next && (
        <Button size="sm" variant="ghost" disabled={pending}
          onClick={() => run(() => updateJobCardStatusAction(jobCardId, next.to))}>
          {pending && <Loader2 className="animate-spin" aria-hidden />}
          {next.label}
        </Button>
      )}

      {canBill && (status === 'READY' || status === 'IN_PROGRESS') && (
        <Button size="sm" variant="secondary" disabled={pending}
          onClick={() =>
            run(
              () => createServiceInvoiceAction(jobCardId),
              (id) => id && router.push(`/service/billing/${id}`),
            )
          }>
          {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Receipt aria-hidden />}
          Bill
        </Button>
      )}
    </div>
  );
}
