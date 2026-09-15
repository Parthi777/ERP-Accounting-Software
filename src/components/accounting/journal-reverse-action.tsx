'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, Undo2 } from 'lucide-react';

import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { reverseJournalAction } from '@/server/services/accounting/journal-actions';

/**
 * The correction mechanism spec §23 requires, and the only one there is.
 *
 * A posted journal cannot be edited — the database refuses it. So correcting an
 * entry means reversing it and posting a replacement, and both stay visible:
 * the reversal carries its reason and its author, so a reader a year later can
 * see that a correction happened and why.
 */
export function JournalReverseAction({
  journalId,
  entryNumber,
}: {
  readonly journalId: string;
  readonly entryNumber: string;
}) {
  const router = useRouter();
  const [open, setOpen] = React.useState(false);
  const [reason, setReason] = React.useState('');
  const [error, setError] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  const submit = () => {
    setError(null);
    startTransition(async () => {
      const result = await reverseJournalAction({ journalId, reason });
      if (!result.ok) {
        setError(result.error ?? 'The reversal failed.');
        return;
      }
      setOpen(false);
      setReason('');
      router.push(`/accounting/journals/${result.id}`);
      router.refresh();
    });
  };

  return (
    <>
      <Button variant="danger" size="sm" onClick={() => setOpen(true)}>
        <Undo2 aria-hidden />
        Reverse
      </Button>

      {open && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/20 p-4">
          <div className="w-full max-w-md rounded-2xl bg-white p-5 shadow-xl">
            <h2 className="text-sm font-semibold text-ink-900">Reverse {entryNumber}?</h2>
            <p className="mt-1 text-sm text-ink-600">
              This posts an opposite entry. {entryNumber} stays on the record, marked reversed and
              linked to the one that undid it — nothing is removed, because an entry that vanishes
              takes the evidence of the mistake with it.
            </p>

            {error && (
              <div role="alert" className="mt-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
                {error}
              </div>
            )}

            <div className="mt-4">
              <Label htmlFor="reversal-reason" className="mb-1.5 block">
                Reason<span className="ml-0.5 text-danger-600">*</span>
              </Label>
              <Input
                id="reversal-reason" value={reason} autoFocus
                onChange={(e) => setReason(e.target.value)}
                placeholder="Charged to the wrong account"
              />
              <p className="mt-1 text-xs text-ink-400">
                Kept on the record permanently (spec §23).
              </p>
            </div>

            <div className="mt-5 flex justify-end gap-2">
              <Button variant="secondary" size="sm" onClick={() => setOpen(false)} disabled={pending}>
                Cancel
              </Button>
              <Button variant="danger" size="sm" onClick={submit} disabled={pending || !reason.trim()}>
                {pending && <Loader2 className="animate-spin" ariaatrue-hidden />}
                Reverse entry
              </Button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
