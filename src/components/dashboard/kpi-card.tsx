import * as React from 'react';
import type { LucideIcon } from 'lucide-react';
import { Lock } from 'lucide-react';

import { cn } from '@/lib/utils';
import { Panel } from '@/components/ui/panel';
import type { Kpi } from '@/server/services/dashboard/dashboard-service';

/**
 * KPI card — spec §7, §10, §54.
 *
 * The shape is a stack, not a row: a clay icon tile, a quiet uppercase label,
 * the figure large underneath, and an optional breakdown under that. It
 * reads in one downward glance, which is what a wall of twelve tiles needs —
 * an icon sitting to the left of the number competes with it for the eye.
 *
 * The raised pastel tile holding the icon is the only colour on the card. It
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
  const palette = TONES[tone];

  return (
    <Panel interactive className={cn('flex flex-col gap-3 rounded-[1.25rem] p-[18px]', className)}>
      <div className="flex items-start justify-between gap-2">
        {Icon ? (
          <span className={cn('clay-pebble flex size-11 shrink-0 items-center justify-center rounded-[14px]', palette.chip)}>
            <Icon className="size-5" aria-hidden />
          </span>
        ) : (
          <span />
        )}
        {kpi.sensitive && (
          <span
            className="inline-flex items-center gap-1 rounded-full bg-accent-50 px-2 py-0.5 text-[10.5px] font-semibold text-accent-600"
            title="Restricted to Accounts and Owner roles"
          >
            <Lock className="size-3" aria-hidden />
            Owner
          </span>
        )}
      </div>

      <p className="truncate text-[11px] font-bold uppercase tracking-[0.06em] text-ink-500">{kpi.label}</p>

      <p
        className={cn(
          'numeric text-left text-[24px] font-extrabold leading-none tracking-tight',
          palette.figure,
        )}
      >
        {kpi.display}
      </p>

      {detail && (
        <p className="truncate text-[11.5px] text-ink-500" title={detail}>
          {detail}
        </p>
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
const TONES: Record<KpiTone, { chip: string; figure: string }> = {
  brand:    { chip: 'bg-brand-100 text-brand-700',       figure: 'text-ink-900' },
  positive: { chip: 'bg-positive-50 text-positive-700',  figure: 'text-positive-700' },
  warning:  { chip: 'bg-warning-50 text-warning-700',    figure: 'text-ink-900' },
  danger:   { chip: 'bg-danger-50 text-danger-700',      figure: 'text-danger-600' },
  accent:   { chip: 'bg-accent-50 text-accent-600',      figure: 'text-ink-900' },
  info:     { chip: 'bg-sky-100 text-sky-700',           figure: 'text-ink-900' },
};
