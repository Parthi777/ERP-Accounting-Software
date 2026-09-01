import type { Metadata } from 'next';

import { getTrialBalance } from '@/server/services/accounting/accounting-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { StatementFilters } from '@/components/accounting/statement-filters';
import { add, formatINR, ZERO, type Paise } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Trial Balance' };
export const dynamic = 'force-dynamic';

export default async function TrialBalancePage({
  searchParams,
}: {
  searchParams: Promise<{ asOn?: string; branch?: string }>;
}) {
  const context = await requireTenantContext();
  const params = await searchParams;

  const asOn = /^\d{4}-\d{2}-\d{2}$/.test(params.asOn ?? '') ? params.asOn! : today();
  const branchId = params.branch === 'all' ? null : (params.branch ?? null);

  const rows = await getTrialBalance(asOn, branchId);

  const totalDebit = rows.reduce<Paise>((sum, row) => add(sum, row.debit), ZERO);
  const totalCredit = rows.reduce<Paise>((sum, row) => add(sum, row.credit), ZERO);
  const balanced = totalDebit === totalCredit;

  return (
    <div>
      <PageHeader
        title="Trial Balance"
        description={`As at ${formatDate(asOn)}`}
        action={
          <StatementFilters
            basePath="/accounting/trial-balance"
            branches={context.accessibleBranches.map((b) => ({ id: b.id, name: b.name }))}
            canViewAllBranches={context.hasAllBranchAccess}
            branchId={branchId}
            asOn={asOn}
          />
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
                rows.map((row) => (
                  <tr key={row.code} className="border-t border-ink-100 hover:bg-brand-50/40">
                    <td className="px-4 py-2 font-mono text-xs text-ink-600">{row.code}</td>
                    <td className="px-4 py-2 text-ink-800">{row.name}</td>
                    <td className="px-4 py-2 text-xs text-ink-500">{row.type}</td>
                    <td className="numeric px-4 py-2">{row.debit === 0 ? '—' : formatINR(row.debit)}</td>
                    <td className="numeric px-4 py-2">{row.credit === 0 ? '—' : formatINR(row.credit)}</td>
                  </tr>
                ))
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

function today(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}
