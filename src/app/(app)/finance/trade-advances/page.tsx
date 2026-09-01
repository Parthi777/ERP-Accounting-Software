import type { Metadata } from 'next';

import {
  getFinanceCompanyBalances,
  getFinanceCompanyLedger,
  getFinancePickers,
  type FinanceLedgerLine,
} from '@/server/services/finance/finance-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { TradeAdvanceForm } from '@/components/finance/trade-advance-form';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { ExportButtons } from '@/components/export/export-buttons';
import { formatINR, negate, type Paise } from '@/lib/money';
import { formatDate } from '@/lib/format';
import { monthRange } from '@/lib/period';

export const metadata: Metadata = { title: 'Trade advances' };
export const dynamic = 'force-dynamic';

/**
 * Positive means the company owes the dealer. A negative balance is money the
 * dealer is holding on their behalf, which reads as Cr on a statement.
 */
function formatPosition(balance: Paise): string {
  return balance < 0 ? `${formatINR(negate(balance))} Cr` : formatINR(balance);
}

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ company?: string; from?: string; to?: string }>;
}) {
  const context = await requirePermission('finance.trade_advance.view');
  const params = await searchParams;
  const { from, to } = monthRange(params.from, params.to);
  const companyId = params.company ?? '';

  const canManage = hasPermission(context, 'finance.trade_advance.manage');

  const [balances, ledger, pickers] = await Promise.all([
    getFinanceCompanyBalances(),
    companyId ? getFinanceCompanyLedger({ companyId, from, to }) : Promise.resolve(null),
    canManage ? getFinancePickers() : Promise.resolve({ companies: [], bankAccounts: [] }),
  ]);

  const columns: Column<FinanceLedgerLine>[] = [
    { key: 'date', header: 'Date', render: (row) => formatDate(row.date) },
    {
      key: 'type',
      header: 'Type',
      render: (row) => <Badge variant="neutral">{row.type.replace(/_/g, ' ')}</Badge>,
    },
    {
      key: 'reference',
      header: 'Reference',
      render: (row) =>
        row.referenceNumber ? (
          <span className="font-mono text-[11px] text-ink-600">{row.referenceNumber}</span>
        ) : (
          <span className="text-ink-300">—</span>
        ),
    },
    {
      key: 'narration',
      header: 'Particulars',
      render: (row) => <span className="block max-w-md text-ink-700">{row.narration ?? '—'}</span>,
    },
    {
      key: 'debit',
      header: 'Debit',
      numeric: true,
      render: (row) => (row.debit > 0 ? formatINR(row.debit) : <span className="text-ink-300">—</span>),
    },
    {
      key: 'credit',
      header: 'Credit',
      numeric: true,
      render: (row) => (row.credit > 0 ? formatINR(row.credit) : <span className="text-ink-300">—</span>),
    },
    {
      key: 'balance',
      header: 'Position',
      numeric: true,
      render: (row) => <span className="font-medium text-ink-800">{formatPosition(row.balance)}</span>,
    },
  ];

  return (
    <>
      <PageHeader
        title="Trade advances"
        description="One running account per finance company — spec §25 keeps them apart, never pooled into a single balance."
        count={ledger?.lines.length}
        action={
          <div className="flex flex-wrap items-center gap-2">
            <ExportButtons report="finance-balances" label={false} />
            <ExportButtons report="finance-company-ledger" />
          </div>
        }
      />

      {/* Every company, always visible: a combined figure would hide which one is owed. */}
      <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {balances.length === 0 ? (
          <Panel className="p-4 sm:col-span-2 lg:col-span-4">
            <p className="text-sm text-ink-600">No active finance companies yet.</p>
          </Panel>
        ) : (
          balances.map((b) => (
            <Panel key={b.id} className="p-4">
              <p className="text-xs text-ink-500">{b.name}</p>
              <p
                className={
                  b.balance > 0
                    ? 'mt-0.5 text-lg font-semibold text-positive-700'
                    : b.balance < 0
                      ? 'mt-0.5 text-lg font-semibold text-warning-700'
                      : 'mt-0.5 text-lg font-semibold text-ink-800'
                }
              >
                {formatPosition(b.balance)}
              </p>
              <p className="mt-0.5 text-[11px] text-ink-400">
                {b.balance > 0 ? 'Owed to the dealer' : b.balance < 0 ? 'Held for the company' : 'Square'}
              </p>
            </Panel>
          ))
        )}
      </div>

      {canManage && (
        <div className="mb-4">
          <TradeAdvanceForm
            companies={pickers.companies}
            bankAccounts={pickers.bankAccounts}
            selectedCompanyId={companyId}
          />
        </div>
      )}

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div className="min-w-56 flex-1">
            <label htmlFor="company" className="mb-1.5 block text-xs font-medium text-ink-600">
              Company
            </label>
            <select
              id="company" name="company" defaultValue={companyId}
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            >
              <option value="">Choose a company</option>
              {balances.map((b) => (
                <option key={b.id} value={b.id}>{b.code} · {b.name}</option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="from" className="mb-1.5 block text-xs font-medium text-ink-600">From</label>
            <input
              id="from" name="from" type="date" defaultValue={from}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            />
          </div>
          <div>
            <label htmlFor="to" className="mb-1.5 block text-xs font-medium text-ink-600">To</label>
            <input
              id="to" name="to" type="date" defaultValue={to}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            />
          </div>
          <Button type="submit" variant="secondary" size="sm">Show ledger</Button>
        </form>
      </Panel>

      {!ledger ? (
        <Panel className="p-8 text-center">
          <p className="text-sm text-ink-600">
            {companyId ? 'That company could not be found.' : 'Choose a company to see its ledger.'}
          </p>
        </Panel>
      ) : (
        <>
          <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <Panel className="p-4">
              <p className="text-xs text-ink-500">Opening</p>
              <p className="mt-0.5 text-lg font-semibold text-ink-800">{formatPosition(ledger.opening)}</p>
            </Panel>
            <Panel className="p-4">
              <p className="text-xs text-ink-500">Debits</p>
              <p className="mt-0.5 text-lg font-semibold text-ink-800">{formatINR(ledger.totalDebit)}</p>
            </Panel>
            <Panel className="p-4">
              <p className="text-xs text-ink-500">Credits</p>
              <p className="mt-0.5 text-lg font-semibold text-ink-800">{formatINR(ledger.totalCredit)}</p>
            </Panel>
            <Panel className="p-4">
              <p className="text-xs text-ink-500">Closing</p>
              <p className="mt-0.5 text-lg font-semibold text-ink-800">{formatPosition(ledger.closing)}</p>
            </Panel>
          </div>

          <p className="mb-3 text-sm text-ink-600">
            <span className="font-medium text-ink-800">{ledger.companyName}</span>
          </p>

          <DataTable
            columns={columns}
            rows={ledger.lines}
            getRowKey={(row, index) => `${row.date}-${index}`}
            emptyMessage={`No movements between ${formatDate(ledger.from)} and ${formatDate(ledger.to)}. The position shown is carried forward.`}
            caption="Finance company ledger"
            maxHeight="40rem"
          />
        </>
      )}
    </>
  );
}
