import * as React from 'react';
import type { LucideIcon } from 'lucide-react';
import { Lock } from 'lucide-react';

import { cn } from '@/lib/utils';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import type { Kpi } from '@/server/services/dashboard/dashboard-service';

/**
 * KPI card — spec §7, §10, §54.
 *
 * The shape is a stack, not a row: a small tinted icon beside a quiet uppercase
 * label, the figure large underneath, and an optional breakdown under that. It
 * reads in one downward glance, which is what a wall of twelve tiles needs —
 * an icon sitting to the left of the number competes with it for the eye.
 *
 * The coloured bar down the left edge is the only strong colour on the card. It
 * groups the tiles by what they are about — money, stock, things that need
 * attention — so a dealer scanning the row finds the red ones without reading a
 * single label.
 *
 * Two states matter. A `ready` KPI shows a figure computed from posted journals.
 * An `awaiting_module` KPI shows no figure at all and says which phase will
 * deliver it, because spec §61 forbids inventing accounting behaviour to make
 * the dashboard look complete. A dash with an explanation is honest; a plausible
 * number that means nothing is not.
 */
export function KpiCard({
  kpi,
  icon: Icon,
  tone = 'brand',
  detail,
  className,
}: {
  readonly kpi: Kpi;
  readonly icon?: LucideIcon;
  readonly tone?: KpiTone;
  /** Breakdown under the figure — the split behind the total. */
  readonly detail?: string;
  readonly className?: string;
}) {
  const pending = kpi.status === 'awaiting_module';
  const palette = TONES[pending ? 'muted' : tone];

  return (
    <Panel
      interactive={!pending}
      className={cn(
        // The accent bar is the card's left border, so it runs the full height
        // whatever the content does. overflow-hidden keeps it inside the radius.
        'relative flex flex-col gap-2.5 overflow-hidden rounded-2xl p-[18px] pl-[22px]',
        pending && 'opacity-80',
        className,
      )}
    >
      <span className={cn('absolute inset-y-0 left-0 w-[5px]', palette.bar)} aria-hidden />

      <div className="flex items-center gap-2">
        {Icon && (
          <span
            className={cn(
              'flex size-6 shrink-0 items-center justify-center rounded-md',
              palette.chip,
            )}
          >
            <Icon className="size-[15px]" aria-hidden />
          </span>
        )}
        <p className="truncate text-[10.5px] font-semibold uppercase tracking-[0.07em] text-ink-500">
          {kpi.label}
        </p>
        {kpi.sensitive && (
          <Lock
            className="size-3 shrink-0 text-ink-400"
            aria-label="Restricted to Accounts and Owner roles"
          />
        )}
      </div>

      {pending ? (
        <p className="text-2xl font-bold tracking-tight text-ink-300" aria-label="Not yet available">
          —
        </p>
      ) : (
        <p
          className={cn(
            'numeric text-left text-[26px] font-bold leading-none tracking-tight',
            palette.figure,
          )}
        >
          {kpi.display}
        </p>
      )}

      {!pending && detail && (
        <p className="truncate text-[11px] text-ink-500" title={detail}>
          {detail}
        </p>
      )}

      {pending && (
        <div className="flex items-center gap-2">
          <Badge variant="neutral">Phase {kpi.phase ?? '—'}</Badge>
          <span className="truncate text-[11px] text-ink-400" title={kpi.note}>
            {kpi.note}
          </span>
        </div>
      )}
    </Panel>
  );
}

export type KpiTone = 'brand' | 'positive' | 'warning' | 'danger' | 'accent' | 'info';

/**
 * The figure is left in near-black for every tone but danger.
 *
 * Colouring a number is a claim that it is good or bad, and most of these are
 * neither — stock value is not good news, it is just the stock value. Red is
 * reserved for the tiles that are a queue of work, where the figure being large
 * genuinely is the point.
 */
const TONES: Record<KpiTone | 'muted', { bar: string; chip: string; figure: string }> = {
  brand:    { bar: 'bg-brand-500',    chip: 'bg-brand-50 text-brand-600',       figure: 'text-ink-900' },
  positive: { bar: 'bg-positive-500', chip: 'bg-positive-50 text-positive-600', figure: 'text-positive-700' },
  warning:  { bar: 'bg-warning-500',  chip: 'bg-warning-50 text-warning-600',   figure: 'text-ink-900' },
  danger:   { bar: 'bg-danger-500',   chip: 'bg-danger-50 text-danger-600',     figure: 'text-danger-600' },
  accent:   { bar: 'bg-accent-500',   chip: 'bg-accent-50 text-accent-600',     figure: 'text-ink-900' },
  info:     { bar: 'bg-sky-400',      chip: 'bg-sky-50 text-sky-600',           figure: 'text-ink-900' },
  muted:    { bar: 'bg-ink-200',      chip: 'bg-ink-100 text-ink-400',          figure: 'text-ink-300' },
};
