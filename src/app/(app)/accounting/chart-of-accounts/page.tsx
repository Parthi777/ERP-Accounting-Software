import Link from 'next/link';
import type { Metadata } from 'next';

import { getChartOfAccounts, type ChartAccount } from '@/server/services/accounting/accounting-service';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Badge } from '@/components/ui/badge';
import { ExportButtons } from '@/components/export/export-buttons';
import { cn } from '@/lib/utils';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { AccountForm, AccountStatusToggle } from '@/components/accounting/account-form';

export const metadata: Metadata = { title: 'Chart of Accounts' };
export const dynamic = 'force-dynamic';

const TYPE_TONE: Record<string, 'info' | 'warning' | 'accent' | 'positive' | 'danger'> = {
  ASSET: 'info',
  LIABILITY: 'warning',
  EQUITY: 'accent',
  INCOME: 'positive',
  EXPENSE: 'danger',
};

const columns: Column<ChartAccount>[] = [
  {
    key: 'code',
    header: 'Code',
    // Drillable: spec §43 asks that every number reach its transactions, and a
    // chart of accounts that cannot be opened is a list of names.
    render: (row) =>
      row.isGroup ? (
        <span className="font-mono text-xs text-ink-400">{row.code}</span>
      ) : (
        <Link
          href={`/accounting/ledger?account=${row.id}`}
          className="font-mono text-xs text-brand-700 hover:underline"
        >
          {row.code}
        </Link>
      ),
  },
  {
    key: 'name',
    header: 'Account',
    render: (row) => (
      // Group headers sit flush; postable leaves are indented beneath them.
      <span className={cn(row.isGroup ? 'font-semibold text-ink-900' : 'pl-5 text-ink-700')}>
        {row.name}
      </span>
    ),
  },
  {
    key: 'type',
    header: 'Type',
    render: (row) => <Badge variant={TYPE_TONE[row.type] ?? 'neutral'}>{row.type}</Badge>,
  },
  {
    key: 'normal',
    header: 'Normal balance',
    render: (row) => <span className="text-ink-600">{row.normalBalance}</span>,
  },
  {
    key: 'postable',
    header: 'Postable',
    render: (row) =>
      row.isGroup ? (
        <span className="text-ink-400">Header</span>
      ) : (
        <span className="text-positive-700">Yes</span>
      ),
  },
  {
    key: 'system',
    header: '',
    render: (row) => (
      <span className="flex items-center gap-1">
        {row.isSystem && <Badge variant="neutral">System</Badge>}
        {row.status !== 'ACTIVE' && <Badge variant="warning">Inactive</Badge>}
      </span>
    ),
  },
];

// Only people who may change the chart see the switch; the database refuses
// the rest regardless (0076), including deactivating an account in use.
const statusColumn: Column<ChartAccount> = {
  key: 'manage',
  header: '',
  render: (row) =>
    row.isGroup ? null : <AccountStatusToggle accountId={row.id} status={row.status} />,
};

export default async function ChartOfAccountsPage() {
  const [accounts, context] = await Promise.all([getChartOfAccounts(), requireTenantContext()]);
  const canManage = context.permissions.has('accounting.coa.manage');
  const headings = accounts
    .filter((a) => a.isGroup && a.status === 'ACTIVE')
    .map((a) => ({ id: a.id, code: a.code, name: a.name, type: a.type }));

  return (
    <div>
      <PageHeader
        title="Chart of Accounts"
        description="Every module posts into these accounts. Mappings are configured as accounting rules, never hard-coded."
        count={accounts.length}
        action={<ExportButtons report="chart-of-accounts" />}
      />
      {canManage && (
        <div className="mb-4">
          <AccountForm headings={headings} />
        </div>
      )}
      <DataTable
        columns={canManage ? [...columns, statusColumn] : columns}
        rows={accounts}
        getRowKey={(row) => row.id}
        caption="Chart of accounts"
        emptyMessage="No accounts are visible to your account."
        maxHeight="44rem"
      />
    </div>
  );
}
