import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import {
  getBankAccounts,
  getMatchSuggestions,
  getReconciliationStatement,
  getReconciliations,
  getStatementLines,
  type ReconciliationRow,
  type ReconciliationStatement,
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
    header: 'Unexplained',
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

const ITEM_LABEL: Record<ReconciliationStatement['items'][number]['kind'], string> = {
  BANK_CREDIT: 'Credited by bank, not in books',
  BANK_DEBIT: 'Debited by bank, not in books',
  UNPRESENTED: 'Issued, not yet presented',
  IN_TRANSIT: 'Deposited, not yet credited',
};

/**
 * The bank reconciliation statement (0077). Timing differences and bank-only
 * items are listed, not netted away: an unpresented cheque is a normal thing to
 * have, and the one figure that needs chasing is what remains after them.
 */
function StatementPanel({
  brs,
  asOn,
  statement,
  accountId,
}: {
  readonly brs: ReconciliationStatement;
  readonly asOn: string;
  readonly statement: string;
  readonly accountId: string;
}) {
  const line = (label: string, value: number, sign = '', strong = false) => (
    <div className={`flex justify-between py-1 ${strong ? 'border-t border-ink-200 font-semibold text-ink-900' : 'text-ink-700'}`}>
      <span>{sign && <span className="mr-2 inline-block w-3 text-ink-400">{sign}</span>}{label}</span>
      <span className="numeric">{formatINR(paise(value))}</span>
    </div>
  );

  return (
    <Panel className="mb-4 p-5">
      <div className="mb-4 flex flex-wrap items-end justify-between gap-3">
        <h2 className="text-sm font-semibold text-ink-900">Reconciliation statement</h2>
        <form method="get" className="flex flex-wrap items-end gap-2">
          <input type="hidden" name="account" value={accountId} />
          <div>
            <label htmlFor="asOn" className="mb-1 block text-xs text-ink-600">As on</label>
            <input id="asOn" name="asOn" type="date" defaultValue={asOn}
              className="h-9 field px-3 text-sm" />
          </div>
          <div>
            <label htmlFor="statement" className="mb-1 block text-xs text-ink-600">Statement closing</label>
            <input id="statement" name="statement" type="number" step="0.01" defaultValue={statement}
              placeholder="per bank"
              className="numeric h-9 w-40 field px-3 text-sm" />
          </div>
          <Button type="submit" variant="secondary" size="sm">Update</Button>
        </form>
      </div>

      <div className="grid gap-6 lg:grid-cols-2">
        <div className="text-sm">
          {line('Balance as per books', brs.bookBalance, '', true)}
          {line('Credits in the bank not yet in the books', brs.bankOnlyCredits, '+')}
          {line('Debits in the bank not yet in the books', brs.bankOnlyDebits, '−')}
          {line('Adjusted book balance', brs.adjustedBookBalance, '', true)}
          {line('Cheques and payments not yet presented', brs.unpresentedPayments, '+')}
          {line('Deposits not yet credited', brs.depositsInTransit, '−')}
          {line('Balance expected on the statement', brs.expectedStatementBalance, '', true)}
          {brs.statementClosing !== null && line('Balance per statement', brs.statementClosing)}
          {brs.unexplainedDifference !== null && (
            <div className={`mt-2 flex justify-between rounded-lg px-3 py-2 font-semibold ${
              brs.unexplainedDifference === 0 ? 'bg-positive-50 text-positive-700' : 'bg-danger-50 text-danger-700'}`}>
              <span>{brs.unexplainedDifference === 0 ? 'Reconciled — nothing unexplained' : 'Unexplained difference'}</span>
              <span className="numeric">{formatINR(brs.unexplainedDifference)}</span>
            </div>
          )}
          {brs.statementClosing === null && (
            <p className="mt-2 text-xs text-ink-500">Enter the statement&apos;s closing balance to see what is left unexplained.</p>
          )}
        </div>

        <div className="max-h-80 overflow-auto text-sm">
          {brs.items.length === 0 ? (
            <p className="text-ink-500">No reconciling items: every book entry is through the bank, and every bank line is in the books.</p>
          ) : (
            <table className="w-full">
              <thead>
                <tr className="text-left text-[11px] uppercase tracking-wide text-ink-500">
                  <th className="py-1">Item</th><th className="py-1">Date</th><th className="py-1 text-right">Amount</th>
                </tr>
              </thead>
              <tbody>
                {brs.items.map((item, i) => (
                  <tr key={i} className="border-t border-ink-100 align-top">
                    <td className="py-1.5 pr-2">
                      <span className="block text-ink-800">{item.particular}</span>
                      <span className="block text-[11px] text-ink-400">
                        {ITEM_LABEL[item.kind]}{item.reference ? ` · ${item.reference}` : ''}
                      </span>
                    </td>
                    <td className="py-1.5 pr-2 text-xs text-ink-600">{formatDate(item.date)}</td>
                    <td className="numeric py-1.5">{formatINR(item.amount)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </div>
    </Panel>
  );
}

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ account?: string; asOn?: string; statement?: string }>;
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

  const asOn = /^\d{4}-\d{2}-\d{2}$/.test(params.asOn ?? '') ? params.asOn! : new Date().toISOString().slice(0, 10);
  const statementClosing = params.statement && Number.isFinite(Number(params.statement))
    ? Number(params.statement)
    : null;

  const [lines, suggestions, history, brs] = await Promise.all([
    getStatementLines({ bankAccountId: account.id }),
    getMatchSuggestions(account.id),
    getReconciliations(),
    getReconciliationStatement({ bankAccountId: account.id, asOn, statementClosing }),
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
              className="h-9 field px-3 text-sm">
              {accounts.map((a) => <option key={a.id} value={a.id}>{a.name} · {a.accountNumber}</option>)}
            </select>
          </div>
          <Button type="submit" variant="secondary" size="sm">Switch</Button>
        </form>
      </Panel>

      <StatementPanel brs={brs} asOn={asOn} statement={params.statement ?? ''} accountId={account.id} />

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
