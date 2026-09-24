import Link from 'next/link';
import type { Metadata } from 'next';

import { getControlTieout, type TieoutRow } from '@/server/services/accounting/accounting-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { StatementFilters } from '@/components/accounting/statement-filters';
import { formatINR } from '@/lib/money';
import { formatDate } from '@/lib/format';
import { asOnInYear } from '@/lib/period';

export const metadata: Metadata = { title: 'Control Tie-out' };
export const dynamic = 'force-dynamic';

const CONTROL_LABEL: Record<string, string> = {
  PARTY: 'Party ledger',
  CASH: 'Cash book',
  BANK: 'Bank book',
  VEHICLE_STOCK: 'Vehicle stock',
  ACCESSORY_STOCK: 'Accessory stock',
  SPARE_STOCK: 'Spare stock',
};

/**
 * Control accounts against their sub-ledgers — spec §41, §43.
 *
 * A balanced trial balance says debits equal credits; it does not say the
 * receivable account agrees with the customers, or the bank account with the
 * bank book. Those are separate records kept beside the ledger, and this is
 * where they are compared. Any non-zero difference names its likely cause.
 */
export default async function TieoutPage({
  searchParams,
}: {
  searchParams: Promise<{ asOn?: string }>;
}) {
  const context = await requireTenantContext();
  const params = await searchParams;
  const asOn = asOnInYear(context.activeFinancialYear, params.asOn);

  const rows: TieoutRow[] = await getControlTieout(asOn);
  const off = rows.filter((r) => r.difference !== 0);
  const today = new Date().toISOString().slice(0, 10);

  return (
    <div>
      <PageHeader
        title="Control Tie-out"
        description={`Ledger against sub-ledger, as at ${formatDate(asOn)}`}
        action={
          <StatementFilters
            basePath="/accounting/tie-out"
            branches={[]}
            canViewAllBranches={false}
            branchId={null}
            asOn={asOn}
          />
        }
      />

      <SolidPanel className="overflow-hidden">
        <table className="w-full border-collapse text-sm">
          <thead>
            <tr>
              {['Control', 'Account', 'Ledger', 'Sub-ledger', 'Difference', ''].map((h, i) => (
                <th key={h || i} scope="col"
                  className={`px-4 py-2.5 text-[11px] font-semibold uppercase tracking-wide text-ink-500 ${i >= 2 && i <= 4 ? 'text-right' : 'text-left'}`}>
                  {h}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 ? (
              <tr>
                <td colSpan={6} className="px-4 py-12 text-center text-sm text-ink-400">Nothing posted yet.</td>
              </tr>
            ) : (
              rows.map((row) => (
                <tr key={`${row.control}-${row.code}`} className="border-t border-ink-100 align-top">
                  <td className="px-4 py-2 text-ink-700">{CONTROL_LABEL[row.control] ?? row.control}</td>
                  <td className="px-4 py-2">
                    <Link href={`/accounting/ledger?code=${row.code}&to=${asOn}`}
                      className="font-mono text-xs text-brand-700 hover:underline">{row.code}</Link>
                    <span className="ml-2 text-ink-800">{row.name}</span>
                  </td>
                  <td className="numeric px-4 py-2">{formatINR(row.ledger)}</td>
                  <td className="numeric px-4 py-2">{formatINR(row.subledger)}</td>
                  <td className={`numeric px-4 py-2 ${row.difference === 0 ? 'text-ink-400' : 'font-semibold text-danger-700'}`}>
                    {row.difference === 0 ? '—' : formatINR(row.difference)}
                  </td>
                  <td className="px-4 py-2 text-xs text-ink-500">
                    {row.difference === 0 ? <Badge variant="positive">Agrees</Badge> : row.explanation}
                  </td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </SolidPanel>

      <p className="mt-3 text-sm text-ink-500">
        {off.length === 0
          ? 'Every control account agrees with its sub-ledger.'
          : `${off.length} control account${off.length === 1 ? '' : 's'} disagree${off.length === 1 ? 's' : ''} with the detail behind ${off.length === 1 ? 'it' : 'them'}.`}{' '}
        Amounts are debit-positive, so payables show as negatives.
        {asOn < today && ' Stock is valued as it stands today, so it is compared only for today’s date.'}
      </p>
    </div>
  );
}
