import Link from 'next/link';
import type { Metadata } from 'next';

import { getChartOfAccounts, getTrialBalance, type ChartAccount } from '@/server/services/accounting/accounting-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { StatementFilters } from '@/components/accounting/statement-filters';
import { ExportButtons } from '@/components/export/export-buttons';
import { add, formatINR, ZERO, type Paise } from '@/lib/money';
import { formatDate } from '@/lib/format';
import { asOnInYear } from '@/lib/period';
import { cn } from '@/lib/utils';

type TbRow = Awaited<ReturnType<typeof getTrialBalance>>[number];
type Line =
  | { readonly kind: 'group'; readonly key: string; readonly name: string; readonly depth: number; readonly debit: Paise; readonly credit: Paise }
  | { readonly kind: 'ledger'; readonly key: string; readonly row: TbRow; readonly depth: number };

/**
 * The trial balance under its groups, as BUSY prints it: each heading and
 * group with the total of the ledgers beneath it, then the ledgers. Groups
 * with nothing in them are left out. Any row the chart cannot place (none,
 * in a healthy book) is listed at the end rather than dropped.
 */
function grouped(rows: readonly TbRow[], chart: readonly ChartAccount[]): Line[] {
  const byCode = new Map(rows.map((r) => [r.code, r]));
  const ids = new Set(chart.map((a) => a.id));
  const children = new Map<string | null, ChartAccount[]>();
  for (const a of chart) {
    const key = a.parentId && ids.has(a.parentId) ? a.parentId : null;
    children.set(key, [...(children.get(key) ?? []), a]);
  }
  const placed = new Set<string>();
  const walk = (parent: string | null, depth: number): { lines: Line[]; debit: Paise; credit: Paise } => {
    const lines: Line[] = [];
    let debit = ZERO;
    let credit = ZERO;
    for (const a of (children.get(parent) ?? []).sort((x, y) => x.code.localeCompare(y.code))) {
      if (a.isGroup) {
        const sub = walk(a.id, depth + 1);
        if (sub.lines.length === 0) continue;
        lines.push({ kind: 'group', key: a.id, name: a.name, depth, debit: sub.debit, credit: sub.credit }, ...sub.lines);
        debit = add(debit, sub.debit);
        credit = add(credit, sub.credit);
      } else {
        const row = byCode.get(a.code);
        if (!row) continue;
        placed.add(a.code);
        lines.push({ kind: 'ledger', key: a.code, row, depth });
        debit = add(debit, row.debit);
        credit = add(credit, row.credit);
      }
    }
    return { lines, debit, credit };
  };
  const { lines } = walk(null, 0);
  for (const row of rows) {
    if (!placed.has(row.code)) lines.push({ kind: 'ledger', key: row.code, row, depth: 0 });
  }
  return lines;
}

export const metadata: Metadata = { title: 'Trial Balance' };
export const dynamic = 'force-dynamic';

export default async function TrialBalancePage({
  searchParams,
}: {
  searchParams: Promise<{ asOn?: string; branch?: string }>;
}) {
  const context = await requireTenantContext();
  const params = await searchParams;

  const asOn = asOnInYear(context.activeFinancialYear, params.asOn);
  const branchId = params.branch === 'all' ? null : (params.branch ?? null);

  const rows = await getTrialBalance(asOn, branchId);
  // Grouped when the chart is readable to this role; flat otherwise.
  const chart = context.permissions.has('accounting.coa.view') ? await getChartOfAccounts() : null;
  const lines: Line[] = chart
    ? grouped(rows, chart)
    : rows.map((row) => ({ kind: 'ledger' as const, key: row.code, row, depth: 0 }));

  const totalDebit = rows.reduce<Paise>((sum, row) => add(sum, row.debit), ZERO);
  const totalCredit = rows.reduce<Paise>((sum, row) => add(sum, row.credit), ZERO);
  const balanced = totalDebit === totalCredit;

  return (
    <div>
      <PageHeader
        title="Trial Balance"
        description={`As at ${formatDate(asOn)}`}
        action={
          <div className="flex flex-wrap items-center gap-2">
            <StatementFilters
              basePath="/accounting/trial-balance"
              branches={context.accessibleBranches.map((b) => ({ id: b.id, name: b.name }))}
              canViewAllBranches={context.hasAllBranchAccess}
              branchId={branchId}
              asOn={asOn}
            />
            <ExportButtons report="trial-balance" />
          </div>
        }
      />

      <SolidPanel className="overflow-hidden">
        <div className="table-sticky overflow-auto" style={{ maxHeight: '40rem' }}>
          <table className="w-full border-collapse text-sm">
            <thead>
              <tr>
                <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Code</th>
                <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Account</th>
                <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Type</th>
                <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Debit</th>
                <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Credit</th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? (
                <tr>
                  <td colSpan={5} className="px-4 py-12 text-center text-sm text-ink-400">
                    No posted entries on or before {formatDate(asOn)}.
                  </td>
                </tr>
              ) : (
                lines.map((line) =>
                  line.kind === 'group' ? (
                    <tr key={line.key} className="border-t border-ink-100 bg-ink-50/60">
                      <td className="px-4 py-2" />
                      <td className={cn('px-4 py-2', line.depth === 0 ? 'font-bold text-ink-900' : 'font-semibold text-ink-800')}
                        style={{ paddingLeft: `${1 + line.depth * 1.25}rem` }}>
                        {line.name}
                      </td>
                      <td className="px-4 py-2" />
                      <td className="numeric px-4 py-2 font-semibold">{line.debit === 0 ? '—' : formatINR(line.debit)}</td>
                      <td className="numeric px-4 py-2 font-semibold">{line.credit === 0 ? '—' : formatINR(line.credit)}</td>
                    </tr>
                  ) : (
                    <tr key={line.key} className="border-t border-ink-100 hover:bg-brand-50/40">
                      <td className="px-4 py-2 font-mono text-xs">
                        {/* Every figure drillable to its transactions (spec §43). */}
                        <Link
                          href={`/accounting/ledger?code=${line.row.code}&to=${asOn}`}
                          className="text-brand-700 hover:underline"
                        >
                          {line.row.code}
                        </Link>
                      </td>
                      <td className="px-4 py-2 text-ink-800" style={{ paddingLeft: `${1 + line.depth * 1.25}rem` }}>{line.row.name}</td>
                      <td className="px-4 py-2 text-xs text-ink-500">{line.row.type}</td>
                      <td className="numeric px-4 py-2">{line.row.debit === 0 ? '—' : formatINR(line.row.debit)}</td>
                      <td className="numeric px-4 py-2">{line.row.credit === 0 ? '—' : formatINR(line.row.credit)}</td>
                    </tr>
                  ),
                )
              )}
            </tbody>
            <tfoot>
              <tr className="border-t-2 border-ink-300 bg-ink-50 font-semibold">
                <td colSpan={3} className="px-4 py-3 text-ink-900">Total</td>
                <td className="numeric px-4 py-3 text-ink-900">{formatINR(totalDebit)}</td>
                <td className="numeric px-4 py-3 text-ink-900">{formatINR(totalCredit)}</td>
              </tr>
            </tfoot>
          </table>
        </div>
      </SolidPanel>

      <div className="mt-3 flex items-center gap-2 text-sm">
        <Badge variant={balanced ? 'positive' : 'danger'}>
          {balanced ? 'Balanced' : 'Out of balance'}
        </Badge>
        <span className="text-ink-500">
          {balanced
            ? 'Debits equal credits — as they must, since the database refuses to post an unbalanced journal.'
            : `Difference of ${formatINR((totalDebit - totalCredit) as Paise)}. This should be impossible; please report it.`}
        </span>
      </div>
    </div>
  );
}
