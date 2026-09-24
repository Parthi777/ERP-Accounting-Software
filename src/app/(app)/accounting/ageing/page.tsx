import Link from 'next/link';
import type { Metadata } from 'next';

import {
  getPartyAgeing,
  type AgeingPartyType,
  type AgeingRow,
} from '@/server/services/accounting/accounting-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { SolidPanel } from '@/components/ui/panel';
import { StatementFilters } from '@/components/accounting/statement-filters';
import { ExportButtons } from '@/components/export/export-buttons';
import { add, formatINR, ZERO, type Paise } from '@/lib/money';
import { formatDate } from '@/lib/format';
import { asOnInYear } from '@/lib/period';
import { cn } from '@/lib/utils';

export const metadata: Metadata = { title: 'Ageing' };
export const dynamic = 'force-dynamic';

const TABS: { type: AgeingPartyType; label: string; ledger: string }[] = [
  { type: 'CUSTOMER', label: 'Customers', ledger: '/accounting/customer-ledger?customer=' },
  { type: 'SUPPLIER', label: 'Suppliers', ledger: '/accounting/supplier-ledger?supplier=' },
  { type: 'FINANCE_COMPANY', label: 'Finance companies', ledger: '' },
];

const BUCKETS: { key: keyof AgeingRow; label: string }[] = [
  { key: 'current', label: '0–30 days' },
  { key: 'days31to60', label: '31–60' },
  { key: 'days61to90', label: '61–90' },
  { key: 'over90', label: 'Over 90' },
];

/**
 * Receivables and payables ageing — spec §41; audit checklist §04.
 *
 * Bill-wise allocations settle their own bills; a receipt nobody allocated
 * settles the oldest first. Advances are held on another account and shown in
 * their own column: netting them into what is owed would hide both.
 */
export default async function AgeingPage({
  searchParams,
}: {
  searchParams: Promise<{ asOn?: string; type?: string }>;
}) {
  const context = await requireTenantContext();
  const params = await searchParams;
  const asOn = asOnInYear(context.activeFinancialYear, params.asOn);
  const tab = TABS.find((t) => t.type === params.type) ?? TABS[0]!;

  const rows = await getPartyAgeing(tab.type, asOn);
  const total = (key: keyof AgeingRow) =>
    rows.reduce<Paise>((sum, row) => add(sum, row[key] as Paise), ZERO);

  const th = 'px-4 py-2.5 text-[11px] font-semibold uppercase tracking-wide text-ink-500';

  return (
    <div>
      <PageHeader
        title="Ageing"
        description={`Who owes what, and for how long — as at ${formatDate(asOn)}`}
        action={
          <div className="flex flex-wrap items-center gap-2">
            <StatementFilters basePath="/accounting/ageing" branches={[]} canViewAllBranches={false}
              branchId={null} asOn={asOn} />
            <ExportButtons report="party-ageing" extra={{ type: tab.type }} />
          </div>
        }
      />

      <nav aria-label="Party type" className="mb-4 flex flex-wrap gap-2">
        {TABS.map((t) => (
          <Link key={t.type} href={`/accounting/ageing?type=${t.type}&asOn=${asOn}`}
            aria-current={t.type === tab.type ? 'page' : undefined}
            className={cn(
              'rounded-lg border px-3 py-1.5 text-sm font-medium',
              t.type === tab.type
                ? 'border-brand-300 bg-brand-50 text-brand-800'
                : 'border-ink-200 bg-white text-ink-600 hover:bg-ink-50',
            )}>
            {t.label}
          </Link>
        ))}
      </nav>

      <SolidPanel className="overflow-hidden">
        <div className="table-sticky overflow-auto" style={{ maxHeight: '40rem' }}>
          <table className="w-full border-collapse text-sm">
            <thead>
              <tr>
                <th scope="col" className={cn(th, 'text-left')}>Party</th>
                {BUCKETS.map((b) => <th key={b.key} scope="col" className={cn(th, 'text-right')}>{b.label}</th>)}
                <th scope="col" className={cn(th, 'text-right')}>Unallocated</th>
                <th scope="col" className={cn(th, 'text-right')}>Balance</th>
                <th scope="col" className={cn(th, 'text-right')}>Advance held</th>
                <th scope="col" className={cn(th, 'text-left')}>Oldest open</th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? (
                <tr>
                  <td colSpan={9} className="px-4 py-12 text-center text-sm text-ink-400">
                    Nothing outstanding on {formatDate(asOn)}.
                  </td>
                </tr>
              ) : (
                rows.map((row) => (
                  <tr key={row.partyId} className="border-t border-ink-100 hover:bg-brand-50/40">
                    <td className="px-4 py-2 text-ink-800">
                      {tab.ledger ? (
                        <Link href={`${tab.ledger}${row.partyId}`} className="text-brand-700 hover:underline">
                          {row.partyName}
                        </Link>
                      ) : row.partyName}
                    </td>
                    {BUCKETS.map((b) => {
                      const value = row[b.key] as Paise;
                      return (
                        <td key={b.key} className={cn('numeric px-4 py-2',
                          b.key === 'over90' && value > 0 && 'font-semibold text-danger-700')}>
                          {value === 0 ? '—' : formatINR(value)}
                        </td>
                      );
                    })}
                    <td className="numeric px-4 py-2 text-ink-500">
                      {row.unallocatedCredit === 0 ? '—' : formatINR(row.unallocatedCredit)}
                    </td>
                    <td className="numeric px-4 py-2 font-medium">{formatINR(row.balance)}</td>
                    <td className="numeric px-4 py-2 text-ink-500">
                      {row.advance === 0 ? '—' : formatINR(row.advance)}
                    </td>
                    <td className="px-4 py-2 text-xs text-ink-500">
                      {row.oldestOpenDate ? formatDate(row.oldestOpenDate) : '—'}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
            {rows.length > 0 && (
              <tfoot>
                <tr className="border-t-2 border-ink-300 bg-ink-50 font-semibold">
                  <td className="px-4 py-3 text-ink-900">Total</td>
                  {BUCKETS.map((b) => <td key={b.key} className="numeric px-4 py-3">{formatINR(total(b.key))}</td>)}
                  <td className="numeric px-4 py-3">{formatINR(total('unallocatedCredit'))}</td>
                  <td className="numeric px-4 py-3">{formatINR(total('balance'))}</td>
                  <td className="numeric px-4 py-3">{formatINR(total('advance'))}</td>
                  <td />
                </tr>
              </tfoot>
            )}
          </table>
        </div>
      </SolidPanel>

      <p className="mt-3 text-sm text-ink-500">
        Aged from the document date. Receipts allocated to a bill settle that bill; unallocated ones
        settle the oldest bills first. Advances sit on their own account and are shown apart, never
        netted into what is owed.
      </p>
    </div>
  );
}
