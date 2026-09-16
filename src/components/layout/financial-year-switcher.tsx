'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { CalendarRange, Check, ChevronsUpDown, Lock } from 'lucide-react';

import { cn } from '@/lib/utils';
import { switchFinancialYear } from '@/server/auth/actions';

export interface FinancialYearOption {
  readonly id: string;
  readonly name: string;
  readonly startDate: string;
  readonly endDate: string;
  readonly status: 'OPEN' | 'CLOSED' | 'LOCKED';
}

/**
 * Financial-year context selector (spec §24, §51).
 *
 * Sits in the header beside the page title, because "which year am I looking
 * at" is a question about everything on the screen rather than about one
 * filter on it.
 *
 * The list is the dealer's own accounting periods — not a span of years worked
 * out by arithmetic. A period is what defines the range and says whether it is
 * still open, so a year the dealer has no period for is not a year they can
 * look at. The choice is re-validated server-side before the cookie is written
 * (spec §47).
 *
 * Selecting a year changes where dated screens *land*, never what they are
 * allowed to show: a screen with an explicit date in its URL keeps that date.
 */
export function FinancialYearSwitcher({
  years,
  activeYearId,
}: {
  readonly years: readonly FinancialYearOption[];
  readonly activeYearId: string | null;
}) {
  const router = useRouter();
  const [open, setOpen] = React.useState(false);
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const containerRef = React.useRef<HTMLDivElement>(null);

  const active = years.find((year) => year.id === activeYearId);

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

  const select = (yearId: string) => {
    setError(null);
    setOpen(false);
    startTransition(async () => {
      const result = await switchFinancialYear(yearId);
      if (result.error) {
        setError(result.error);
        return;
      }
      router.refresh();
    });
  };

  // A dealer with no accounting period has nothing to choose between, and
  // saying so here would be noise: dealer_readiness() already reports it as a
  // tenant that cannot trade.
  if (years.length === 0) {
    return null;
  }

  const onlyOne = years.length === 1;

  return (
    <div ref={containerRef} className="relative">
      <button
        type="button"
        onClick={() => setOpen((value) => !value)}
        disabled={pending || onlyOne}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-label={`Financial year: ${active?.name ?? 'none'}`}
        className={cn(
          'flex items-center gap-2 rounded-lg border border-ink-200 bg-white/70 px-2.5 py-1.5 text-left transition-colors',
          !onlyOne && 'hover:bg-white',
          pending && 'opacity-60',
        )}
      >
        <CalendarRange className="size-4 shrink-0 text-brand-600" aria-hidden />
        <span className="hidden min-w-0 sm:block">
          <span className="block truncate text-xs font-medium leading-tight text-ink-800">
            {active?.name ?? 'No period'}
          </span>
        </span>
        {active && active.status !== 'OPEN' && (
          <Lock className="size-3 shrink-0 text-warning-600" aria-label={active.status} />
        )}
        {!onlyOne && <ChevronsUpDown className="size-3.5 shrink-0 text-ink-400" aria-hidden />}
      </button>

      {open && (
        <ul
          role="listbox"
          className="glass-strong absolute right-0 top-full z-50 mt-2 max-h-72 w-60 overflow-y-auto rounded-xl p-1"
        >
          {years.map((year) => {
            const selected = year.id === activeYearId;
            return (
              <li key={year.id}>
                <button
                  type="button"
                  role="option"
                  aria-selected={selected}
                  onClick={() => select(year.id)}
                  className={cn(
                    'flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left text-sm transition-colors',
                    selected ? 'bg-brand-50 text-brand-700' : 'text-ink-700 hover:bg-ink-100',
                  )}
                >
                  <span className="min-w-0 flex-1">
                    <span className="block truncate font-medium">{year.name}</span>
                    <span className="block text-xs text-ink-400">
                      {year.startDate} to {year.endDate}
                      {year.status !== 'OPEN' && ` · ${year.status.toLowerCase()}`}
                    </span>
                  </span>
                  {selected && <Check className="size-4 shrink-0 text-brand-600" aria-hidden />}
                </button>
              </li>
            );
          })}
        </ul>
      )}

      {error && (
        <p role="alert" className="absolute right-0 top-full mt-1 text-xs text-danger-600">
          {error}
        </p>
      )}
    </div>
  );
}
