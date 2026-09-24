'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';

import { setDealerSwitchAction } from '@/server/services/org/settings-actions';
import type { DealerSwitchKey } from '@/server/services/org/org-service';
import { cn } from '@/lib/utils';

/** One clay toggle per dealer switch; the change is saved as it is made. */
export function DealerSwitches({
  switches,
  values,
  canManage,
}: {
  readonly switches: readonly { key: DealerSwitchKey; label: string; detail: string }[];
  readonly values: Readonly<Record<DealerSwitchKey, boolean>>;
  readonly canManage: boolean;
}) {
  const router = useRouter();
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);

  return (
    <div className="space-y-3">
      {switches.map((s) => {
        const on = values[s.key];
        return (
          <div key={s.key} className="clay-pit flex items-center justify-between gap-4 rounded-xl px-4 py-3">
            <div>
              <p className="text-sm font-semibold text-ink-900">{s.label}</p>
              <p className="text-xs text-ink-500">{s.detail}</p>
            </div>
            <button
              type="button"
              role="switch"
              aria-checked={on}
              aria-label={s.label}
              disabled={!canManage || pending}
              onClick={() =>
                startTransition(async () => {
                  setError(null);
                  const result = await setDealerSwitchAction(s.key, !on);
                  if (!result.ok) setError(result.error ?? 'Could not save.');
                  router.refresh();
                })
              }
              className={cn(
                'relative h-7 w-12 shrink-0 rounded-full transition-colors disabled:opacity-50',
                on ? 'bg-brand-600 shadow-[inset_0_2px_4px_rgba(0,0,0,.2)]' : 'bg-ink-200 shadow-[inset_2px_2px_4px_rgba(118,140,180,.35)]',
              )}
            >
              <span
                className={cn(
                  'clay-raised absolute top-1 size-5 rounded-full transition-[left]',
                  on ? 'left-6' : 'left-1',
                )}
              />
            </button>
          </div>
        );
      })}
      {error && <p role="alert" className="text-sm text-danger-700">{error}</p>}
    </div>
  );
}
