import type { Metadata } from 'next';

import { getBalanceSheet } from '@/server/services/accounting/accounting-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { StatementFilters } from '@/components/accounting/statement-filters';
import { StatementSection } from '@/components/accounting/statement-section';
import { add, formatINR, ZERO, type Paise } from '@/lib/money';
import { formatDate } from '@/lib/format';
import { todayIso } from '@/lib/period';

export const metadata: Metadata = { title: 'Balance Sheet' };
export const dynamic = 'force-dynamic';

export default async function BalanceSheetPage({
  searchParams,
}: {
  searchParams: Promise<{ asOn?: string; branch?: string }>;
}) {
  const context = await requireTenantContext();
  const params = await searchParams;
  const asOn = /^\d{4}-\d{2}-\d{2}$/.test(params.asOn ?? '') ? params.asOn! : todayIso();
  const branchId = params.branch === 'all' ? null : (params.branch ?? null);

  const rows = await getBalanceSheet(asOn, branchId);

  const assets = rows.filter((r) => r.section === 'ASSET');
  const liabilities = rows.filter((r) => r.section === 'LIABILITY');
  const equity = rows.filter((r) => r.section === 'EQUITY');

  const totalAssets = assets.reduce<Paise>((s, r) => add(s, r.amount), ZERO);
  const totalLiabilities = liabilities.reduce<Paise>((s, r) => add(s, r.amount), ZERO);
  const totalEquity = equity.reduce<Paise>((s, r) => add(s, r.amount), ZERO);
  const totalFunding = add(totalLiabilities, totalEquity);
  const balanced = totalAssets === totalFunding;

  return (
    <div>
      <PageHeader
        title="Balance Sheet"
        description={`As at ${formatDate(asOn)}`}
        action={
          <StatementFilters
            basePath="/accounting/balance-sheet"
            branches={context.accessibleBranches.map((b) => ({ id: b.id, name: b.name }))}
            canViewAllBranches={context.hasAllBranchAccess}
            branchId={branchId}
            asOn={asOn}
          />
        }
      />

      <div className="grid gap-4 lg:grid-cols-2">
        <div className="space-y-4">
          <StatementSection title="Assets" rows={assets} total={totalAssets} tone="info" />
        </div>
        <div className="space-y-4">
          <StatementSection title="Liabilities" rows={liabilities} total={totalLiabilities} tone="warning" />
          <StatementSection title="Equity" rows={equity} total={totalEquity} tone="accent" />
        </div>
      </div>

      <SolidPanel className="mt-4 px-5 py-4">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="flex items-center gap-2">
            <Badge variant={balanced ? 'positive' : 'danger'}>
              {balanced ? 'Balanced' : 'Out of balance'}
            </Badge>
            <span className="text-sm text-ink-600">
              Assets = Liabilities + Equity
              {!balanced && ` — out by ${formatINR((totalAssets - totalFunding) as Paise)}`}
            </span>
          </div>
          <div className="numeric flex gap-6 text-sm">
            <span className="text-ink-600">
              Assets <strong className="ml-2 text-ink-900">{formatINR(totalAssets)}</strong>
            </span>
            <span className="text-ink-600">
              Liabilities + Equity <strong className="ml-2 text-ink-900">{formatINR(totalFunding)}</strong>
            </span>
          </div>
        </div>
      </SolidPanel>
    </div>
  );
}
