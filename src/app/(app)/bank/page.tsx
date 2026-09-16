import type { Metadata } from 'next';
import Link from 'next/link';
import { BookOpen, FileUp, Pencil, Plus, Scale } from 'lucide-react';

import { getBankAccounts, type BankAccountSummary } from '@/server/services/bank/bank-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { add, formatINR, paise } from '@/lib/money';

export const metadata: Metadata = { title: 'Bank accounts' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'neutral' | 'danger'> = {
  ACTIVE: 'positive',
  INACTIVE: 'neutral',
  CLOSED: 'danger',
};

const columns: Column<BankAccountSummary>[] = [
  {
    key: 'name',
    header: 'Account',
    render: (row) => (
      <span>
        <Link href={`/bank/book?account=${row.id}`} className="block font-medium text-brand-600 hover:underline">
          {row.name}
        </Link>
        <span className="block text-[11px] text-ink-400">{row.bankName}</span>
      </span>
    ),
  },
  {
    key: 'number',
    header: 'Account number',
    render: (row) => (
      <span>
        <span className="block font-mono text-xs text-ink-700">{row.accountNumber}</span>
        {row.ifsc && <span className="block font-mono text-[11px] text-ink-400">{row.ifsc}</span>}
      </span>
    ),
  },
  { key: 'type', header: 'Type', render: (row) => row.accountType },
  {
    key: 'branch',
    header: 'Branch',
    render: (row) => row.branchName ?? <span className="text-ink-400">Dealer-wide</span>,
  },
  {
    key: 'balance',
    header: 'Balance',
    numeric: true,
    render: (row) => (
      <span className={row.currentBalance < 0 ? 'font-medium text-danger-700' : 'font-medium'}>
        {formatINR(row.currentBalance)}
      </span>
    ),
  },
  {
    key: 'unreconciled',
    header: 'Unreconciled',
    numeric: true,
    render: (row) =>
      row.unreconciled > 0 ? (
        <Link href={`/bank/reconciliation?account=${row.id}`} className="text-warning-700 hover:underline">
          {row.unreconciled} entries
        </Link>
      ) : (
        <span className="text-positive-700">Clear</span>
      ),
  },
  {
    key: 'status',
    header: 'Status',
    render: (row) => <Badge variant={STATUS_TONE[row.status] ?? 'neutral'}>{row.status}</Badge>,
  },
];

const manageColumn: Column<BankAccountSummary> = {
  key: 'edit',
  header: '',
  render: (row) => (
    <Link
      href={`/bank/accounts/${row.id}/edit`}
      className="inline-flex items-center gap-1 text-xs text-brand-600 hover:underline"
    >
      <Pencil className="size-3" aria-hidden />
      Edit
    </Link>
  ),
};

export default async function Page() {
  const context = await requirePermission('bank.accounts.view');
  const accounts = await getBankAccounts();
  const canManage = hasPermission(context, 'bank.accounts.manage');

  const total = accounts
    .filter((a) => a.status === 'ACTIVE')
    .reduce((sum, a) => add(sum, a.currentBalance), paise(0));
  const pending = accounts.reduce((sum, a) => sum + a.unreconciled, 0);

  return (
    <>
      <PageHeader
        title="Bank accounts"
        description="Balances as recorded in the books, not as reported by the bank (spec §38)."
        count={accounts.length}
        action={
          <div className="flex flex-wrap gap-2">
            {canManage && (
              <Button variant="secondary" size="sm" asChild>
                <Link href="/bank/accounts/new"><Plus aria-hidden />New bank account</Link>
              </Button>
            )}
            {hasPermission(context, 'bank.statement.import') && (
              <Button variant="secondary" size="sm" asChild>
                <Link href="/bank/import"><FileUp aria-hidden />Import statement</Link>
              </Button>
            )}
            {hasPermission(context, 'bank.reconcile') && (
              <Button variant="secondary" size="sm" asChild>
                <Link href="/bank/reconciliation"><Scale aria-hidden />Reconcile</Link>
              </Button>
            )}
            {hasPermission(context, 'bank.book.view') && (
              <Button size="sm" asChild>
                <Link href="/bank/book"><BookOpen aria-hidden />Bank book</Link>
              </Button>
            )}
          </div>
        }
      />

      <div className="mb-4 grid gap-3 sm:grid-cols-3">
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Total across active accounts</p>
          <p className="numeric mt-1 text-xl font-semibold text-ink-900">{formatINR(total)}</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Accounts</p>
          <p className="numeric mt-1 text-xl font-semibold text-ink-900">{accounts.length}</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Entries awaiting reconciliation</p>
          <p className={`numeric mt-1 text-xl font-semibold ${pending > 0 ? 'text-warning-700' : 'text-positive-700'}`}>
            {pending}
          </p>
        </Panel>
      </div>

      <DataTable
        columns={canManage ? [...columns, manageColumn] : columns}
        rows={accounts}
        getRowKey={(row) => row.id}
        emptyMessage={
          canManage
            ? "No bank accounts yet. Add the first one to record receipts, import statements and reconcile."
            : "No bank accounts yet. Someone with bank account permissions can add the first one."
        }
        caption="Bank accounts"
      />
    </>
  );
}
