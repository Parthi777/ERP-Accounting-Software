import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import {
  getBankAccounts,
  getMatchSuggestions,
  getReconciliations,
  getStatementLines,
  type ReconciliationRow,
} from '@/server/services/bank/bank-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { ReconciliationWorkbench } from '@/components/bank/reconciliation-workbench';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatINR, paise } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Bank reconciliation' };
export const dynamic = 'force-dynamic';

const historyColumns: Column<ReconciliationRow>[] = [
  { key: 'number', header: 'Number', render: (row) => <span className="font-mono text-xs">{row.number}</span> },
  { key: 'account', header: 'Account', render: (row) => row.accountName },
  {
    key: 'period',
    header: 'Period',
    render: (row) => `${formatDate(row.fromDate)} – ${formatDate(row.toDate)}`,
  },
  { key: 'statement', header: 'Per statement', numeric: true, render: (row) => formatINR(row.statementClosing) },
  { key: 'book', header: 'Per books', numeric: true, render: (row) => formatINR(row.bookClosing) },
  {
    key: 'difference',
    header: 'Difference',
    numeric: true,
    render: (row) =>
      row.difference === 0 ? (
        <span className="text-positive-700">Agreed</span>
      ) : (
        <span className="font-medium text-danger-700">{formatINR(paise(Math.abs(row.difference)))}</span>
      ),
  },
  {
    key: 'lines',
    header: 'Lines',
    render: (row) => (
      <span className="text-xs">
        <span className="text-positive-700">{row.matched} matched</span>
        {row.unmatched > 0 && <span className="text-warning-700"> · {row.unmatched} open</span>}
      </span>
    ),
  },
  {
    key: 'status',
    header: 'Status',
    render: (row) => (
      <Badge variant={row.status === 'COMPLETED' ? 'positive' : row.status === 'CANCELLED' ? 'danger' : 'neutral'}>
        {row.status}
      </Badge>
    ),
  },
];

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ account?: string }>;
}) {
  await requirePermission('bank.reconcile');
  const params = await searchParams;

  const accounts = await getBankAccounts();
  const accountId = params.account ?? accounts[0]?.id ?? null;
  const account = accounts.find((a) => a.id === accountId) ?? null;

  if (!account) {
    return (
      <>
        <PageHeader title="Bank reconciliation" />
        <Panel className="p-6">
          <p className="text-sm text-ink-700">
            No bank accounts exist yet. One must be created before anything can be reconciled.
          </p>
        </Panel>
      </>
    );
  }

  const [lines, suggestions, history] = await Promise.all([
    getStatementLines({ bankAccountId: account.id }),
    getMatchSuggestions(account.id),
    getReconciliations(),
  ]);

  return (
    <>
      <PageHeader
        title="Bank reconciliation"
        description="Matching the bank's version of events against ours (spec §39)."
        action={
          <Button variant="secondary" size="sm" asChild>
            <Link href="/bank"><ArrowLeft aria-hidden />Accounts</Link>
          </Button>
        }
      />

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div>
            <label htmlFor="account" className="mb-1.5 block text-xs font-medium text-ink-600">Account</label>
            <select id="account" name="account" defaultValue={account.id}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
              {accounts.map((a) => <option key={a.id} value={a.id}>{a.name} · {a.accountNumber}</option>)}
            </select>
          </div>
          <Button type="submit" variant="secondary" size="sm">Switch</Button>
        </form>
      </Panel>

      <ReconciliationWorkbench
        bankAccountId={account.id}
        accountName={account.name}
        bookBalance={account.currentBalance}
        lines={lines}
        suggestions={suggestions}
      />

      <h2 className="mb-3 mt-6 text-sm font-semibold text-ink-900">Completed reconciliations</h2>
      <DataTable
        columns={historyColumns}
        rows={history}
        getRowKey={(row) => row.id}
        emptyMessage="No reconciliations have been completed yet."
        caption="Reconciliation history"
      />
    </>
  );
}
