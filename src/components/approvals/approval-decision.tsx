'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Check, Loader2, Undo2, X } from 'lucide-react';

import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { decideApprovalAction, withdrawApprovalAction } from '@/server/services/approvals/approval-actions';

/**
 * Approve, reject (with a reason) or withdraw one request. Whether this person
 * may decide it — never their own, only with the approve permission — is the
 * database's call; the buttons shown are a courtesy, not the control.
 */
export function ApprovalDecision({
  requestId,
  mine,
  canDecide,
}: {
  readonly requestId: string;
  readonly mine: boolean;
  readonly canDecide: boolean;
}) {
  const router = useRouter();
  const [note, setNote] = React.useState('');
  const [error, setError] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  const run = (fn: () => Promise<{ ok: boolean; error?: string }>) => {
    setError(null);
    startTransition(async () => {
      const result = await fn();
      if (!result.ok) {
        setError(result.error ?? 'That could not be done.');
        return;
      }
      router.refresh();
    });
  };

  if (mine) {
    return (
      <div className="flex flex-col items-end gap-1">
        <Button size="sm" variant="secondary" disabled={pending}
          onClick={() => run(() => withdrawApprovalAction(requestId))}>
          {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Undo2 aria-hidden />}
          Withdraw
        </Button>
        <span className="text-[11px] text-ink-400">Someone else has to approve it.</span>
        {error && <span role="alert" className="text-[11px] text-danger-700">{error}</span>}
      </div>
    );
  }

  if (!canDecide) {
    return <span className="text-xs text-ink-400">Waiting for an approver</span>;
  }

  return (
    <div className="flex flex-col items-end gap-2">
      <Input aria-label="Note or reason" placeholder="Note (required to reject)" value={note}
        onChange={(e) => setNote(e.target.value)} className="h-9 w-64" />
      <div className="flex gap-2">
        <Button size="sm" variant="danger" disabled={pending}
          onClick={() => run(() => decideApprovalAction({ requestId, approve: false, note }))}>
          <X aria-hidden />
          Reject
        </Button>
        <Button size="sm" disabled={pending}
          onClick={() => run(() => decideApprovalAction({ requestId, approve: true, note }))}>
          {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Check aria-hidden />}
          Approve &amp; post
        </Button>
      </div>
      {error && <span role="alert" className="max-w-72 text-right text-[11px] text-danger-700">{error}</span>}
    </div>
  );
}
