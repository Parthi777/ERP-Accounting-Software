import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft, Check } from 'lucide-react';

import { getBankAccounts, getBankBook, type BankEntry } from '@/server/services/bank/bank-service';
import { getContraAccounts } from '@/server/services/cash/cash-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { BankEntryForm } from '@/components/bank/bank-entry-form';
import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { ExportButtons } from '@/components/export/export-buttons';
import { formatINR } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Bank book' };
export const dynamic = 'force-dynamic';

const columns: Column<BankEntry>[] = [
  { key: 'date', header: 'Date', render: (row) => formatDate(row.date) },
  { key: 'particular', header: 'Particulars', render: (row) => row.particular },
  {
    key: 'reference',
    header: 'Reference',
    render: (row) => {
      const value = row.utr ?? row.reference;
      return value ? <span className="font-mono text-xs text-ink-600">{value}</span> : <span className="text-ink-300">—</span>;
    },
  },
  {
    key: 'receipt',
    header: 'Receipt',
    numeric: true,
    render: (row) => (row.receipt > 0 ? <span className="text-positive-700">{formatINR(row.receipt)}</span> : <span className="text-ink-300">—</span>),
  },
  {
    key: 'payment',
    header: 'Payment',
    numeric: true,
    render: (row) => (row.payment > 0 ? <span className="text-danger-700">{formatINR(row.payment)}</span> : <span className="text-ink-300">—</span>),
  },
  { key: 'balance', header: 'Balance', numeric: true, render: (row) => <span className="font-medium">{formatINR(row.balance)}</span> },
  {
    key: 'reconciled',
    header: 'Reconciled',
    render: (row) =>
      row.reconciled ? (
        <span className="inline-flex items-center gap-1 text-xs text-positive-700"><Check className="size-3.5" aria-hidden />Yes</span>
      ) : (
        <span className="text-xs text-ink-400">Pending</span>
      ),
  },
  {
    key: 'journal',
    header: '',
    render: (row) =>
      row.journalEntryId ? (
        <Link href={`/accounting/journals/${row.journalEntryId}`} className="text-xs text-brand-600 hover:underline">
          Journal
        </Link>
      ) : null,
  },
];

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ account?: string; from?: string; to?: string }>;
}) {
  const context = await requirePermission('bank.book.view');
  const params = await searchParams;

  const accounts = await getBankAccounts();
  const accountId = params.account ?? accounts[0]?.id ?? null;
  const account = accounts.find((a) => a.id === accountId) ?? null;

  if (!account) {
    return (
      <>
        <PageHeader title="Bank book" />
        <Panel className="p-6">
          <p className="text-sm text-ink-700">
            No bank accounts exist yet. An administrator can add one under Administration → Settings.
          </p>
        </Panel>
      </>
    );
  }

  const [entries, contraAccounts] = await Promise.all([
    getBankBook({ bankAccountId: account.id, from: params.from, to: params.to }),
    hasPermission(context, 'bank.book.record') ? getContraAccounts('RECEIPT') : Promise.resolve([]),
  ]);

  return (
    <>
      <PageHeader
        title="Bank book"
        description={`${account.name} · ${account.bankName} · ${account.accountNumber}`}
        count={entries.length}
        action={
          <div className="flex flex-wrap items-center gap-2">
            <ExportButtons report="bank-book" extra={{ account: account.id }} />
            <Button variant="secondary" size="sm" asChild>
              <Link href="/bank"><ArrowLeft aria-hidden />Accounts</Link>
            </Button>
          </div>
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
          <div>
            <label htmlFor="from" className="mb-1.5 block text-xs font-medium text-ink-600">From</label>
            <input id="from" name="from" type="date" defaultValue={params.from ?? ''}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" />
          </div>
          <div>
            <label htmlFor="to" className="mb-1.5 block text-xs font-medium text-ink-600">To</label>
            <input id="to" name="to" type="date" defaultValue={params.to ?? ''}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" />
          </div>
          <Button type="submit" variant="secondary" size="sm">Apply</Button>
          <div className="ml-auto text-right">
            <p className="text-xs text-ink-500">Balance as per books</p>
            <p className="numeric text-lg font-semibold text-ink-900">{formatINR(account.currentBalance)}</p>
          </div>
        </form>
      </Panel>

      {hasPermission(context, 'bank.book.record') && (
        <div className="mb-4">
          <BankEntryForm bankAccountId={account.id} accountName={account.name} accounts={contraAccounts} />
        </div>
      )}

      <DataTable
        columns={columns}
        rows={entries}
        getRowKey={(row) => String(row.id)}
        emptyMessage="No entries in this account for the selected period."
        caption={`Bank book — ${account.name}`}
      />
    </>
  );
}
