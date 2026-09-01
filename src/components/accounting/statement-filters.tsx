'use client';

import * as React from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { CalendarDays, Filter } from 'lucide-react';

import { Panel } from '@/components/ui/panel';

/**
 * Branch and date filters shared by the accounting statements.
 *
 * Writes to the query string so the server component re-runs. Filtering in the
 * browser would mean shipping figures to a session that may not be entitled to
 * see them.
 */
export function StatementFilters({
  basePath,
  branches,
  canViewAllBranches,
  branchId,
  asOn,
  from,
  to,
}: {
  readonly basePath: string;
  readonly branches: readonly { readonly id: string; readonly name: string }[];
  readonly canViewAllBranches: boolean;
  readonly branchId: string | null;
  readonly asOn?: string;
  readonly from?: string;
  readonly to?: string;
}) {
  const router = useRouter();
  const searchParams = useSearchParams();
  const [pending, startTransition] = React.useTransition();

  const apply = (updates: Record<string, string>) => {
    const next = new URLSearchParams(searchParams.toString());
    for (const [key, value] of Object.entries(updates)) {
      next.set(key, value);
    }
    startTransition(() => router.push(`${basePath}?${next.toString()}`));
  };

  return (
    <Panel className="flex flex-wrap items-center gap-2 p-2">
      <Filter className="ml-1 size-4 shrink-0 text-ink-400" aria-hidden />

      {branches.length > 0 && (
        <select
          aria-label="Branch"
          value={branchId ?? 'all'}
          disabled={pending}
          onChange={(event) => apply({ branch: event.target.value })}
          className="h-8 rounded-lg border border-ink-200 bg-white px-2 text-sm text-ink-700 shadow-sm"
        >
          {canViewAllBranches && <option value="all">All branches</option>}
          {branches.map((branch) => (
            <option key={branch.id} value={branch.id}>
              {branch.name}
            </option>
          ))}
        </select>
      )}

      <div className="flex items-center gap-1.5 rounded-lg border border-ink-200 bg-white px-2 shadow-sm">
        <CalendarDays className="size-4 shrink-0 text-ink-400" aria-hidden />
        {asOn !== undefined ? (
          <input
            type="date"
            aria-label="As at date"
            value={asOn}
            disabled={pending}
            onChange={(event) => apply({ asOn: event.target.value })}
            className="h-8 bg-transparent text-sm text-ink-700 outline-none"
          />
        ) : (
          <>
            <input
              type="date"
              aria-label="From date"
              value={from}
              max={to}
              disabled={pending}
              onChange={(event) => apply({ from: event.target.value })}
              className="h-8 bg-transparent text-sm text-ink-700 outline-none"
            />
            <span className="text-ink-300">–</span>
            <input
              type="date"
              aria-label="To date"
              value={to}
              min={from}
              disabled={pending}
              onChange={(event) => apply({ to: event.target.value })}
              className="h-8 bg-transparent text-sm text-ink-700 outline-none"
            />
          </>
        )}
      </div>
    </Panel>
  );
}
