import type { Metadata } from 'next';

import { getChartOfAccounts, type ChartAccount } from '@/server/services/accounting/accounting-service';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Badge } from '@/components/ui/badge';
import { ExportButtons } from '@/components/export/export-buttons';
import { cn } from '@/lib/utils';

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
    render: (row) => <span className="font-mono text-xs text-ink-600">{row.code}</span>,
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
    render: (row) => (row.isSystem ? <Badge variant="neutral">System</Badge> : null),
  },
];

export default async function ChartOfAccountsPage() {
  const accounts = await getChartOfAccounts();

  return (
    <div>
      <PageHeader
        title="Chart of Accounts"
        description="Every module posts into these accounts. Mappings are configured as accounting rules, never hard-coded."
        count={accounts.length}
        action={<ExportButtons report="chart-of-accounts" />}
      />
      <DataTable
        columns={columns}
        rows={accounts}
        getRowKey={(row) => row.id}
        caption="Chart of accounts"
        emptyMessage="No accounts are visible to your account."
        maxHeight="44rem"
      />
    </div>
  );
}
