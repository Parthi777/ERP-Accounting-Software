import Link from 'next/link';
import { ArrowLeft, Construction } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { navEntryFor } from '@/config/navigation';

/**
 * Placeholder for a module that Phase 1 has not built.
 *
 * The route exists and is permission-gated so navigation is complete and each
 * module has a home to land in, but the page says plainly that it is not built
 * rather than showing an empty table that looks broken. Spec §61: mock behaviour
 * must be clearly isolated, never dressed up as a finished feature.
 */

const PHASE_NAMES: Record<number, string> = {
  1: 'Foundation',
  2: 'Masters',
  3: 'Pricing & Inventory',
  4: 'Sales & Booking',
  5: 'Accounting',
  6: 'Service',
  7: 'Reconciliation & GST',
  8: 'MIS',
};

export function ModulePlaceholder({
  pathname,
  summary,
  delivers,
}: {
  readonly pathname: string;
  readonly summary: string;
  readonly delivers?: readonly string[];
}) {
  const entry = navEntryFor(pathname);
  const title = entry?.label ?? 'Module';
  const phase = entry?.phase;

  return (
    <div className="mx-auto max-w-3xl">
      <div className="mb-5 flex items-center gap-3">
        <h1 className="text-xl font-bold tracking-tight text-ink-900">{title}</h1>
        {phase && (
          <Badge variant="info">
            Phase {phase} · {PHASE_NAMES[phase] ?? 'Planned'}
          </Badge>
        )}
      </div>

      <Panel className="p-6">
        <div className="flex gap-4">
          <div className="flex size-11 shrink-0 items-center justify-center rounded-xl bg-warning-50 text-warning-600">
            <Construction className="size-5" aria-hidden />
          </div>

          <div className="min-w-0 flex-1">
            <h2 className="text-sm font-semibold text-ink-900">Not built yet</h2>
            <p className="mt-1.5 text-sm leading-relaxed text-ink-600">{summary}</p>

            {delivers && delivers.length > 0 && (
              <>
                <p className="mt-4 text-xs font-medium uppercase tracking-wide text-ink-400">
                  This screen will provide
                </p>
                <ul className="mt-2 space-y-1.5">
                  {delivers.map((item) => (
                    <li key={item} className="flex items-start gap-2 text-sm text-ink-600">
                      <span className="mt-1.5 size-1.5 shrink-0 rounded-full bg-brand-400" aria-hidden />
                      {item}
                    </li>
                  ))}
                </ul>
              </>
            )}

            <p className="mt-5 text-xs text-ink-500">
              The route, its permission gate and its place in the navigation exist today. Phase 1
              delivered the foundation these modules build on: tenant isolation, roles and
              permissions, the audit trail, document numbering and the accounting core.
            </p>

            <div className="mt-5">
              <Button variant="secondary" size="sm" asChild>
                <Link href="/dashboard">
                  <ArrowLeft aria-hidden />
                  Back to dashboard
                </Link>
              </Button>
            </div>
          </div>
        </div>
      </Panel>
    </div>
  );
}
