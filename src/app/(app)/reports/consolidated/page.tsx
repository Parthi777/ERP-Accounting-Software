import type { Metadata } from 'next';
import Link from 'next/link';

import { getConsolidatedMis, type ConsolidatedRow } from '@/server/services/reports/reports-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { formatINR } from '@/lib/money';
import { monthRange } from '@/lib/period';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Consolidated MIS' };
export const dynamic = 'force-dynamic';

const CATEGORY_ORDER = ['Sales', 'Service', 'Collections', 'Position'];

const CATEGORY_NOTE: Record<string, string> = {
  Sales: 'Vehicles invoiced and bookings taken in the period.',
  Service: 'Workshop invoices posted in the period.',
  Collections: 'Money that actually moved through cash and bank.',
  Position: 'Where the dealership stands right now, not for the period.',
};

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ from?: string; to?: string }>;
}) {
  await requirePermission('reports.consolidated.view');
  const params = await searchParams;
  const range = monthRange(params.from, params.to);

  const rows = await getConsolidatedMis({ from: range.from, to: range.to });

  const byCategory = new Map<string, ConsolidatedRow[]>();
  for (const row of rows) {
    const list = byCategory.get(row.category) ?? [];
    list.push(row);
    byCategory.set(row.category, list);
  }

  const categories = CATEGORY_ORDER.filter((c) => byCategory.has(c));

  return (
    <>
      <PageHeader
        title="Consolidated MIS"
        description={`The whole dealership, ${formatDate(range.from)} – ${formatDate(range.to)} (spec §43).`}
        action={
          <div className="flex gap-2">
            <Button variant="secondary" size="sm" asChild>
              <Link href={`/reports/branch-performance?from=${range.from}&to=${range.to}`}>By branch</Link>
            </Button>
          </div>
        }
      />

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div>
            <label htmlFor="from" className="mb-1.5 block text-xs font-medium text-ink-600">From</label>
            <input id="from" name="from" type="date" defaultValue={range.from}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" />
          </div>
          <div>
            <label htmlFor="to" className="mb-1.5 block text-xs font-medium text-ink-600">To</label>
            <input id="to" name="to" type="date" defaultValue={range.to}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" />
          </div>
          <Button type="submit" variant="secondary" size="sm">Apply</Button>
        </form>
      </Panel>

      {categories.length === 0 && (
        <Panel className="p-8 text-center text-sm text-ink-600">
          Nothing has been posted in this period.
        </Panel>
      )}

      {categories.map((category) => (
        <section key={category} className="mb-6">
          <h2 className="text-sm font-semibold text-ink-900">{category}</h2>
          <p className="mb-3 text-xs text-ink-500">{CATEGORY_NOTE[category]}</p>

          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            {(byCategory.get(category) ?? []).map((row) => (
              <Panel key={row.metric} className="p-4">
                <p className="text-xs text-ink-500">{row.metric}</p>
                <p className="numeric mt-1 text-xl font-semibold text-ink-900">{formatINR(row.value)}</p>
                <p className="mt-0.5 text-[11px] text-ink-400">
                  {row.count} {row.count === 1 ? 'document' : 'documents'}
                </p>
              </Panel>
            ))}
          </div>
        </section>
      ))}
    </>
  );
}
