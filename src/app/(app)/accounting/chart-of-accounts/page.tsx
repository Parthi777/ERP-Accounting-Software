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

type ChartRow = ChartAccount & { readonly depth: number };

const columns: Column<ChartRow>[] = [
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
      // Indented by depth: heading, group, sub-group, ledger.
      <span
        className={cn(row.isGroup ? 'font-semibold text-ink-900' : 'text-ink-700')}
        style={{ paddingLeft: `${row.depth * 1.25}rem` }}
      >
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
const statusColumn: Column<ChartRow> = {
  key: 'manage',
  header: '',
  render: (row) => (
    <span className="flex items-center justify-end gap-2">
      <Link href={`/accounting/ledgers/account/${row.id}`} className="text-xs font-medium text-brand-700 hover:underline">
        Modify
      </Link>
      {!row.isGroup && <AccountStatusToggle accountId={row.id} status={row.status} />}
    </span>
  ),
};

/** Tree order — each heading or group followed by what sits beneath it. */
function inTreeOrder(accounts: readonly ChartAccount[]): ChartRow[] {
  const ids = new Set(accounts.map((a) => a.id));
  const children = new Map<string | null, ChartAccount[]>();
  for (const a of accounts) {
    const key = a.parentId && ids.has(a.parentId) ? a.parentId : null;
    children.set(key, [...(children.get(key) ?? []), a]);
  }
  const out: ChartRow[] = [];
  const walk = (parent: string | null, depth: number) => {
    for (const a of (children.get(parent) ?? []).sort((x, y) => x.code.localeCompare(y.code))) {
      out.push({ ...a, depth });
      walk(a.id, depth + 1);
    }
  };
  walk(null, 0);
  return out;
}

export default async function ChartOfAccountsPage() {
  const [chart, context] = await Promise.all([getChartOfAccounts(), requireTenantContext()]);
  const accounts = inTreeOrder(chart);
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
