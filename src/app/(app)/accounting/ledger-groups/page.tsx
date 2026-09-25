import Link from 'next/link';
import type { Metadata } from 'next';

import { getChart, getGroupOptions, groupsInTreeOrder, type LedgerGroup } from '@/server/services/accounting/ledger-master-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Badge } from '@/components/ui/badge';
import { NewLedgerForm } from '@/components/accounting/ledger-master-forms';
import { cn } from '@/lib/utils';

export const metadata: Metadata = { title: 'Ledger Groups' };
export const dynamic = 'force-dynamic';

type GroupRow = LedgerGroup & { readonly ledgers: number; readonly subGroups: number };

/**
 * Ledger groups — BUSY's account groups. The five type headings at the top,
 * the standard groups beneath them (Sundry Debtors, Duties & Taxes, Indirect
 * Expenses …), and any sub-group the accountant adds. Reports read an
 * account's type, so moving a ledger between groups of one type moves no figure.
 */
export default async function LedgerGroupsPage() {
  const context = await requireTenantContext();
  const chart = await getChart();
  const tree = groupsInTreeOrder(chart);
  const canManage = context.permissions.has('accounting.coa.manage');
  const options = canManage ? await getGroupOptions(chart) : [];

  const rows: GroupRow[] = tree.map((g) => ({
    ...g,
    ledgers: chart.filter((a) => a.parentId === g.id && !a.isGroup).length,
    subGroups: chart.filter((a) => a.parentId === g.id && a.isGroup).length,
  }));

  const columns: Column<GroupRow>[] = [
    {
      key: 'name',
      header: 'Group',
      render: (row) => (
        <span
          className={cn(row.depth === 0 ? 'font-semibold text-ink-900' : 'text-ink-700')}
          style={{ paddingLeft: `${row.depth * 1.25}rem` }}
        >
          {row.name}
          {row.alias && <span className="ml-1.5 text-[11px] text-ink-400">({row.alias})</span>}
        </span>
      ),
    },
    { key: 'code', header: 'Code', render: (row) => <span className="font-mono text-xs text-ink-500">{row.code}</span> },
    { key: 'type', header: 'Type', render: (row) => <span className="text-ink-600">{row.type.toLowerCase()}</span> },
    {
      key: 'ledgers',
      header: 'Ledgers',
      numeric: true,
      render: (row) =>
        row.ledgers ? (
          <Link href={`/accounting/ledgers?group=${row.id}`} className="text-brand-700 hover:underline">{row.ledgers}</Link>
        ) : (
          <span className="text-ink-400">—</span>
        ),
    },
    { key: 'sub', header: 'Sub-groups', numeric: true, render: (row) => row.subGroups || <span className="text-ink-400">—</span> },
    {
      key: 'flags',
      header: '',
      render: (row) => (
        <span className="flex gap-1">
          {row.isSystem && <Badge variant="neutral">System</Badge>}
          {row.status !== 'ACTIVE' && <Badge variant="warning">Inactive</Badge>}
        </span>
      ),
    },
    {
      key: 'modify',
      header: '',
      render: (row) => (
        <Link href={`/accounting/ledgers/account/${row.id}`} className="text-xs font-medium text-brand-700 hover:underline">
          Modify
        </Link>
      ),
    },
  ];

  return (
    <div className="space-y-4">
      <PageHeader
        title="Ledger Groups"
        description="Groups gather ledgers for the trial balance and statements. A group can sit under another group of the same type."
        count={rows.length}
      />
      {canManage && (
        <details className="group">
          <summary className="mb-3 cursor-pointer text-sm font-medium text-brand-700">Add a group</summary>
          <NewLedgerForm groups={options} isGroup />
        </details>
      )}
      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.id}
        caption="Ledger groups"
        emptyMessage="No groups are visible to your account."
        maxHeight="44rem"
      />
    </div>
  );
}
