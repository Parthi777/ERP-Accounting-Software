'use client';

import * as React from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { CalendarDays, Filter } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';

/**
 * Dashboard filters (spec §10): branch and date range.
 *
 * They write to the query string, so the server component re-runs and recomputes
 * the KPIs. Filtering in the browser would mean shipping unfiltered figures to a
 * user who may not be allowed to see them.
 */
export function DashboardFilters({
  branches,
  canViewAllBranches,
  from,
  to,
  branchId,
}: {
  readonly branches: readonly { readonly id: string; readonly code: string; readonly name: string }[];
  readonly canViewAllBranches: boolean;
  readonly from: string;
  readonly to: string;
  readonly branchId: string | null;
}) {
  const router = useRouter();
  const searchParams = useSearchParams();
  const [pending, startTransition] = React.useTransition();

  const apply = (updates: Record<string, string>) => {
    const params = new URLSearchParams(searchParams.toString());
    for (const [key, value] of Object.entries(updates)) {
      params.set(key, value);
    }
    startTransition(() => router.push(`/dashboard?${params.toString()}`));
  };

  return (
    <Panel className="flex flex-wrap items-center gap-2 p-2">
      <Filter className="ml-1 size-4 shrink-0 text-ink-400" aria-hidden />

      {branches.length > 0 && (
        <select
          aria-label="Branch"
          value={branchId ?? 'all'}
          onChange={(event) => apply({ branch: event.target.value })}
          disabled={pending}
          className="h-8 rounded-lg border border-ink-200 bg-white px-2 text-sm text-ink-700 shadow-sm focus:border-brand-400 focus:outline-none focus:ring-2 focus:ring-brand-500/20"
        >
          {canViewAllBranches && <option value="all">All Branches</option>}
          {branches.map((branch) => (
            <option key={branch.id} value={branch.id}>
              {branch.name}
            </option>
          ))}
        </select>
      )}

      <div className="flex items-center gap-1.5 rounded-lg border border-ink-200 bg-white px-2 shadow-sm">
        <CalendarDays className="size-4 shrink-0 text-ink-400" aria-hidden />
        <input
          type="date"
          aria-label="From date"
          value={from}
          max={to}
          onChange={(event) => apply({ from: event.target.value })}
          disabled={pending}
          className="h-8 bg-transparent text-sm text-ink-700 outline-none"
        />
        <span className="text-ink-300">–</span>
        <input
          type="date"
          aria-label="To date"
          value={to}
          min={from}
          onChange={(event) => apply({ to: event.target.value })}
          disabled={pending}
          className="h-8 bg-transparent text-sm text-ink-700 outline-none"
        />
      </div>

      <Button
        variant="secondary"
        size="sm"
        onClick={() => startTransition(() => router.push('/dashboard'))}
        disabled={pending}
      >
        This month
      </Button>
    </Panel>
  );
}
