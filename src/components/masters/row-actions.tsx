'use client';

import * as React from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { Loader2, Pencil, Trash2, TriangleAlert } from 'lucide-react';

import { Button } from '@/components/ui/button';
import type { MasterKind } from '@/lib/validation/masters';
import { deactivateMasterAction, deleteMasterAction } from '@/server/services/masters/actions';

/**
 * Edit and delete for a master row.
 *
 * Delete is attempted for real rather than always soft-deleting. If a foreign key
 * refuses it, the record is in use and the dialog offers deactivation instead —
 * which is the honest outcome: a tax code that priced last year's invoices cannot
 * vanish without making those invoices unreadable, but it can stop appearing on
 * new ones.
 */
export function RowActions({
  kind,
  id,
  label,
  editHref,
  canManage,
}: {
  readonly kind: MasterKind;
  readonly id: string;
  readonly label: string;
  readonly editHref: string;
  readonly canManage: boolean;
}) {
  const router = useRouter();
  const [open, setOpen] = React.useState(false);
  const [pending, startTransition] = React.useTransition();
  const [inUseMessage, setInUseMessage] = React.useState<string | null>(null);
  const [error, setError] = React.useState<string | null>(null);

  if (!canManage) {
    return null;
  }

  const close = () => {
    setOpen(false);
    setInUseMessage(null);
    setError(null);
  };

  const remove = () => {
    setError(null);
    startTransition(async () => {
      const result = await deleteMasterAction(kind, id);
      if (result.ok) {
        close();
        router.refresh();
        return;
      }
      if (result.inUse) {
        setInUseMessage(result.error ?? 'This record is in use.');
        return;
      }
      setError(result.error ?? 'The record could not be deleted.');
    });
  };

  const deactivate = () => {
    setError(null);
    startTransition(async () => {
      const result = await deactivateMasterAction(kind, id);
      if (result.ok) {
        close();
        router.refresh();
        return;
      }
      setError(result.error ?? 'The record could not be deactivated.');
    });
  };

  return (
    <>
      <span className="flex items-center justify-end gap-1">
        <Button variant="ghost" size="sm" asChild>
          <Link href={editHref} aria-label={`Edit ${label}`}>
            <Pencil aria-hidden />
            Edit
          </Link>
        </Button>
        <Button
          variant="ghost"
          size="sm"
          className="text-danger-600 hover:bg-danger-50 hover:text-danger-700"
          onClick={() => setOpen(true)}
          aria-label={`Delete ${label}`}
        >
          <Trash2 aria-hidden />
        </Button>
      </span>

      {open && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
          role="dialog"
          aria-modal="true"
          aria-labelledby="delete-title"
          onClick={close}
        >
          <div className="glass-strong w-full max-w-md rounded-2xl p-6" onClick={(e) => e.stopPropagation()}>
            <div className="mb-4 flex items-start gap-3">
              <span
                className={`flex size-10 shrink-0 items-center justify-center rounded-xl ${
                  inUseMessage ? 'bg-warning-50 text-warning-600' : 'bg-danger-50 text-danger-600'
                }`}
              >
                {inUseMessage ? <TriangleAlert className="size-5" aria-hidden /> : <Trash2 className="size-5" aria-hidden />}
              </span>
              <div className="min-w-0">
                <h2 id="delete-title" className="text-sm font-semibold text-ink-900">
                  {inUseMessage ? 'This record is in use' : `Delete ${label}?`}
                </h2>
                <p className="mt-1 text-sm text-ink-600">
                  {inUseMessage ?? 'This cannot be undone. Records referencing it will block the delete.'}
                </p>
              </div>
            </div>

            {error && (
              <div role="alert" className="mb-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
                {error}
              </div>
            )}

            <div className="flex justify-end gap-2">
              <Button variant="secondary" size="sm" onClick={close} disabled={pending}>
                Cancel
              </Button>
              {inUseMessage ? (
                <Button variant="primary" size="sm" onClick={deactivate} disabled={pending}>
                  {pending && <Loader2 className="animate-spin" aria-hidden />}
                  Deactivate instead
                </Button>
              ) : (
                <Button variant="danger" size="sm" onClick={remove} disabled={pending}>
                  {pending && <Loader2 className="animate-spin" aria-hidden />}
                  Delete
                </Button>
              )}
            </div>
          </div>
        </div>
      )}
    </>
  );
}
