'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, Lock, LockOpen } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { setBooksLockAction } from '@/server/services/accounting/chart-actions';
import { formatDate } from '@/lib/format';

/**
 * "Books locked through" — spec §23, §46.
 *
 * Once a month's GST return is filed, nothing dated in it should post — not a
 * late receipt, not a reversal. The lock date is that switch. Moving it back
 * (reopening) is allowed, because accountants do need to post an auditor's
 * adjustment, but it takes a reason and every move is kept.
 */
export function BooksLockPanel({
  lockedThrough,
  canManage,
}: {
  readonly lockedThrough: string | null;
  readonly canManage: boolean;
}) {
  const router = useRouter();
  const [editing, setEditing] = React.useState(false);
  const [date, setDate] = React.useState(lockedThrough ?? '');
  const [reason, setReason] = React.useState('');
  const [error, setError] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  const yesterday = React.useMemo(() => {
    const d = new Date();
    d.setDate(d.getDate() - 1);
    return d.toISOString().slice(0, 10);
  }, []);

  const save = (next: string | null) => {
    setError(null);
    if (reason.trim().length < 3) return setError('Say why — the reason is kept with the lock.');
    startTransition(async () => {
      const result = await setBooksLockAction({ lockedThrough: next, reason });
      if (!result.ok) {
        setError(result.error ?? 'The lock date could not be changed.');
        return;
      }
      setEditing(false);
      setReason('');
      router.refresh();
    });
  };

  return (
    <Panel className="mb-4 flex flex-wrap items-center gap-3 px-4 py-3">
      {lockedThrough ? (
        <Lock className="size-4 text-warning-600" aria-hidden />
      ) : (
        <LockOpen className="size-4 text-ink-400" aria-hidden />
      )}
      <p className="text-sm text-ink-700">
        {lockedThrough ? (
          <>Books locked through <strong>{formatDate(lockedThrough)}</strong>. Nothing dated on or before it can be posted or reversed.</>
        ) : (
          <>Books are open. Lock a period once its return is filed.</>
        )}
      </p>

      {canManage && !editing && (
        <Button variant="secondary" size="sm" className="ml-auto" onClick={() => setEditing(true)}>
          Change lock date
        </Button>
      )}

      {canManage && editing && (
        <div className="flex w-full flex-wrap items-end gap-3 border-t border-ink-100 pt-3">
          <div>
            <Label htmlFor="lock-date" className="mb-1.5 block">Lock through</Label>
            <Input id="lock-date" type="date" max={yesterday} value={date}
              onChange={(e) => setDate(e.target.value)} />
          </div>
          <div className="min-w-64 flex-1">
            <Label htmlFor="lock-reason" className="mb-1.5 block">
              Reason<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <Input id="lock-reason" value={reason} onChange={(e) => setReason(e.target.value)}
              placeholder="August GSTR-3B filed" />
          </div>
          <Button size="sm" disabled={pending || !date} onClick={() => save(date)}>
            {pending && <Loader2 className="animate-spin" aria-hidden />}
            Lock
          </Button>
          {lockedThrough && (
            <Button variant="secondary" size="sm" disabled={pending} onClick={() => save(null)}>
              Reopen all
            </Button>
          )}
          <Button variant="ghost" size="sm" disabled={pending} onClick={() => setEditing(false)}>
            Cancel
          </Button>
          {error && <p role="alert" className="w-full text-sm text-danger-700">{error}</p>}
        </div>
      )}
    </Panel>
  );
}
