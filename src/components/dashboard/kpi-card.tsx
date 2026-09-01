import * as React from 'react';
import type { LucideIcon } from 'lucide-react';
import { Lock } from 'lucide-react';

import { cn } from '@/lib/utils';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import type { Kpi } from '@/server/services/dashboard/dashboard-service';

/**
 * KPI card — glass, per spec §7.
 *
 * Two states matter here. A `ready` KPI shows a figure computed from posted
 * journals. An `awaiting_module` KPI shows no figure at all and says which phase
 * will deliver it, because spec §61 forbids inventing accounting behaviour to
 * make the dashboard look complete. A dash with an explanation is honest; a
 * plausible number that means nothing is not.
 */
export function KpiCard({
  kpi,
  icon: Icon,
  tone = 'brand',
  className,
}: {
  readonly kpi: Kpi;
  readonly icon?: LucideIcon;
  readonly tone?: 'brand' | 'positive' | 'warning' | 'danger' | 'accent';
  readonly className?: string;
}) {
  const pending = kpi.status === 'awaiting_module';

  return (
    <Panel
      className={cn('flex flex-col gap-3 p-4', pending && 'opacity-75', className)}
      aria-busy={undefined}
    >
      <div className="flex items-start gap-3">
        {Icon && (
          <span
            className={cn(
              'flex size-10 shrink-0 items-center justify-center rounded-xl',
              pending ? 'bg-ink-100 text-ink-400' : TONE_CLASSES[tone],
            )}
          >
            <Icon className="size-5" aria-hidden />
          </span>
        )}

        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-1.5">
            <p className="truncate text-[13px] font-medium text-ink-500">{kpi.label}</p>
            {kpi.sensitive && (
              <Lock
                className="size-3 shrink-0 text-ink-400"
                aria-label="Restricted to Accounts and Owner roles"
              />
            )}
          </div>

          {pending ? (
            <p className="mt-1 text-2xl font-semibold tracking-tight text-ink-300" aria-label="Not yet available">
              —
            </p>
          ) : (
            <p className="numeric mt-1 text-left text-2xl font-semibold tracking-tight text-ink-900">
              {kpi.display}
            </p>
          )}
        </div>
      </div>

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

const TONE_CLASSES: Record<string, string> = {
  brand: 'bg-brand-50 text-brand-600',
  positive: 'bg-positive-50 text-positive-600',
  warning: 'bg-warning-50 text-warning-600',
  danger: 'bg-danger-50 text-danger-600',
  accent: 'bg-accent-50 text-accent-600',
};
