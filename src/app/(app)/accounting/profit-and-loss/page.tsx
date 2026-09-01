import type { Metadata } from 'next';

import { getProfitAndLoss } from '@/server/services/accounting/accounting-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { SolidPanel } from '@/components/ui/panel';
import { StatementFilters } from '@/components/accounting/statement-filters';
import { StatementSection } from '@/components/accounting/statement-section';
import { ExportButtons } from '@/components/export/export-buttons';
import { add, formatINR, subtract, ZERO, type Paise } from '@/lib/money';
import { formatDateRange } from '@/lib/format';
import { monthRange } from '@/lib/period';

export const metadata: Metadata = { title: 'Profit & Loss' };
export const dynamic = 'force-dynamic';

export default async function ProfitAndLossPage({
  searchParams,
}: {
  searchParams: Promise<{ from?: string; to?: string; branch?: string }>;
}) {
  const context = await requireTenantContext();
  const params = await searchParams;
  const { from, to } = monthRange(params.from, params.to);
  const branchId = params.branch === 'all' ? null : (params.branch ?? null);

  const rows = await getProfitAndLoss(from, to, branchId);

  const income = rows.filter((r) => r.section === 'INCOME');
  const expense = rows.filter((r) => r.section === 'EXPENSE');
  const totalIncome = income.reduce<Paise>((s, r) => add(s, r.amount), ZERO);
  const totalExpense = expense.reduce<Paise>((s, r) => add(s, r.amount), ZERO);
  const result = subtract(totalIncome, totalExpense);

  return (
    <div>
      <PageHeader
        title="Profit & Loss"
        description={formatDateRange(from, to)}
        action={
          <div className="flex flex-wrap items-center gap-2">
            <StatementFilters
              basePath="/accounting/profit-and-loss"
              branches={context.accessibleBranches.map((b) => ({ id: b.id, name: b.name }))}
              canViewAllBranches={context.hasAllBranchAccess}
              branchId={branchId}
              from={from}
              to={to}
            />
            <ExportButtons report="profit-and-loss" />
          </div>
        }
      />

      <div className="grid gap-4 lg:grid-cols-2">
        <StatementSection title="Income" rows={income} total={totalIncome} tone="positive" />
        <StatementSection title="Expenses" rows={expense} total={totalExpense} tone="danger" />
      </div>

      <SolidPanel className="mt-4 flex items-center justify-between px-5 py-4">
        <span className="text-sm font-semibold text-ink-900">
          {result >= 0 ? 'Net profit' : 'Net loss'}
        </span>
        <span
          className={`numeric text-xl font-bold ${result >= 0 ? 'text-positive-700' : 'text-danger-700'}`}
        >
          {formatINR(result)}
        </span>
      </SolidPanel>

      {rows.length === 0 && (
        <p className="mt-3 text-sm text-ink-500">
          No income or expense was posted in this period.
        </p>
      )}
    </div>
  );
}
