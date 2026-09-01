'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Building2, Check, ChevronsUpDown } from 'lucide-react';

import { cn } from '@/lib/utils';
import { switchBranch } from '@/server/auth/actions';

export interface BranchOption {
  readonly id: string;
  readonly code: string;
  readonly name: string;
}

/**
 * Branch context selector (spec §51).
 *
 * The list is whatever the server said this user can reach. Selecting an entry
 * calls a server action that re-validates the choice against `user_branches`
 * before writing the cookie — the browser's copy of the list is a convenience,
 * never the authority (spec §47).
 */
export function BranchSwitcher({
  branches,
  activeBranchId,
}: {
  readonly branches: readonly BranchOption[];
  readonly activeBranchId: string | null;
}) {
  const router = useRouter();
  const [open, setOpen] = React.useState(false);
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const containerRef = React.useRef<HTMLDivElement>(null);

  const active = branches.find((branch) => branch.id === activeBranchId);

  React.useEffect(() => {
    if (!open) {
      return;
    }
    const onPointerDown = (event: MouseEvent) => {
      if (!containerRef.current?.contains(event.target as Node)) {
        setOpen(false);
      }
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        setOpen(false);
      }
    };
    document.addEventListener('mousedown', onPointerDown);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('mousedown', onPointerDown);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, [open]);

  const select = (branchId: string) => {
    setError(null);
    setOpen(false);
    startTransition(async () => {
      const result = await switchBranch(branchId);
      if (result.error) {
        setError(result.error);
        return;
      }
      router.refresh();
    });
  };

  if (branches.length === 0) {
    return null;
  }

  return (
    <div ref={containerRef} className="relative">
      <button
        type="button"
        onClick={() => setOpen((value) => !value)}
        disabled={pending || branches.length === 1}
        aria-haspopup="listbox"
        aria-expanded={open}
        className={cn(
          'flex w-full items-center gap-3 rounded-lg border border-brand-100 bg-brand-50/70 px-3 py-2 text-left transition-colors',
          branches.length > 1 && 'hover:bg-brand-50',
          pending && 'opacity-60',
        )}
      >
        <Building2 className="size-4 shrink-0 text-brand-600" aria-hidden />
        <span className="min-w-0 flex-1">
          <span className="block text-[11px] font-medium uppercase tracking-wide text-brand-600">
            Branch
          </span>
          <span className="block truncate text-sm font-medium text-ink-800">
            {active?.name ?? 'All Branches'}
          </span>
        </span>
        {branches.length > 1 && (
          <ChevronsUpDown className="size-4 shrink-0 text-ink-400" aria-hidden />
        )}
      </button>

      {open && (
        <ul
          role="listbox"
          className="glass-strong absolute bottom-full left-0 z-50 mb-2 max-h-72 w-full overflow-y-auto rounded-xl p-1"
        >
          {branches.map((branch) => {
            const selected = branch.id === activeBranchId;
            return (
              <li key={branch.id}>
                <button
                  type="button"
                  role="option"
                  aria-selected={selected}
                  onClick={() => select(branch.id)}
                  className={cn(
                    'flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left text-sm transition-colors',
                    selected ? 'bg-brand-50 text-brand-700' : 'text-ink-700 hover:bg-ink-100',
                  )}
                >
                  <span className="min-w-0 flex-1">
                    <span className="block truncate font-medium">{branch.name}</span>
                    <span className="block text-xs text-ink-400">{branch.code}</span>
                  </span>
                  {selected && <Check className="size-4 shrink-0 text-brand-600" aria-hidden />}
                </button>
              </li>
            );
          })}
        </ul>
      )}

      {error && (
        <p role="alert" className="mt-1 px-1 text-xs text-danger-600">
          {error}
        </p>
      )}
    </div>
  );
}
