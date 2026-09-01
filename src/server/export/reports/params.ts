import { formatDate } from '@/lib/format';
import { isIsoDate, monthRange, todayIso } from '@/lib/period';
import type { TenantContext } from '@/server/auth/tenant-context';

import type { ExportFact } from '../types';

/**
 * Reading filters off the export URL.
 *
 * The export link carries the same query string the screen was showing, so the
 * file matches what the user was looking at. That makes the query string
 * user-controlled, which is fine for dates and free text and emphatically not
 * fine for the branch: `branchParam` never returns a branch the session cannot
 * reach, whatever the URL says (spec §47 — never trust a client-submitted
 * branch_id). The services apply the same rule again; this is the outer of the
 * two gates, not the only one.
 */

/** A date from the query string, defaulting to today. */
export function dateParam(params: URLSearchParams, key: string, fallback = todayIso()): string {
  const value = params.get(key) ?? undefined;
  return isIsoDate(value) ? value : fallback;
}

/** A from/to pair, defaulting to the current month exactly as the screens do. */
export function monthParams(params: URLSearchParams): { from: string; to: string } {
  return monthRange(params.get('from') ?? undefined, params.get('to') ?? undefined);
}

/**
 * The branch to report on.
 *
 * `null` means every branch the user can see, which is what a dealer owner gets
 * by default. A branch id is honoured only when the session actually has access
 * to it; a user without all-branch access is pinned to their own branch however
 * the URL is written.
 */
export function branchParam(context: TenantContext, params: URLSearchParams): string | null {
  const requested = params.get('branch');

  if (requested && requested !== 'ALL') {
    const permitted = context.accessibleBranches.some((branch) => branch.id === requested);
    if (permitted) return requested;
  }

  return context.hasAllBranchAccess ? null : (context.activeBranch?.id ?? null);
}

export function periodFact(from: string, to: string): ExportFact {
  return { label: 'Period', value: `${formatDate(from)} to ${formatDate(to)}` };
}

export function filterFact(label: string, value: string | null, allLabel = 'All'): ExportFact {
  return { label, value: value && value !== 'ALL' ? value : allLabel };
}

/**
 * The row cap an export asks a service for.
 *
 * Screens cap at 200–500 rows because nobody scrolls further; an export is read
 * by a spreadsheet and has no such limit. This is high enough to cover a large
 * dealer's year and low enough that a runaway query cannot exhaust the server.
 * When a loader comes back with exactly this many rows the renderers print an
 * incomplete-export banner rather than letting the file look whole.
 */
export const EXPORT_ROW_CAP = 10_000;

/** Marks the data as truncated when the loader returned a full page. */
export function truncation(rowCount: number, cap = EXPORT_ROW_CAP): number | undefined {
  return rowCount >= cap ? cap : undefined;
}
