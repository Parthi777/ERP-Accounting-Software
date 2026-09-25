import Link from 'next/link';
import type { Metadata } from 'next';
import { Plus } from 'lucide-react';

import { getChart, getGroupOptions, listLedgers, type LedgerRow } from '@/server/services/accounting/ledger-master-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { formatDrCr } from '@/lib/format';

export const metadata: Metadata = { title: 'Ledgers' };
export const dynamic = 'force-dynamic';

const KIND_LABEL: Record<LedgerRow['kind'], string | null> = {
  ACCOUNT: null,
  CUSTOMER: 'Customer',
  SUPPLIER: 'Supplier',
  FINANCE_COMPANY: 'Financier',
};

/** Where a ledger's statement lives — the account ledger or the party's. */
function statementHref(row: LedgerRow): string {
  switch (row.kind) {
    case 'CUSTOMER': return `/accounting/customer-ledger?customer=${row.id}`;
    case 'SUPPLIER': return `/accounting/supplier-ledger?supplier=${row.id}`;
    case 'FINANCE_COMPANY': return `/finance/ledger?company=${row.id}`;
    default: return `/accounting/ledger?account=${row.id}`;
  }
}

function modifyHref(row: LedgerRow): string {
  return `/accounting/ledgers/${row.kind.toLowerCase().replace('_', '-')}/${row.id}`;
}

const columns: Column<LedgerRow>[] = [
  {
    key: 'name',
    header: 'Ledger',
    render: (row) => (
      <span className="flex flex-col">
        <Link href={statementHref(row)} className="font-medium text-brand-700 hover:underline">{row.name}</Link>
        <span className="text-[11px] text-ink-400">
          <span className="font-mono">{row.code}</span>
          {row.alias && <> · {row.alias}</>}
          {row.contact && <> · {row.contact}</>}
        </span>
      </span>
    ),
  },
  {
    key: 'group',
    header: 'Group',
    render: (row) => (
      <span className="flex items-center gap-1.5 text-ink-600">
        {row.groupName ?? '—'}
        {KIND_LABEL[row.kind] && <Badge variant="neutral">{KIND_LABEL[row.kind]}</Badge>}
      </span>
    ),
  },
  { key: 'opening', header: 'Opening', numeric: true, render: (row) => formatDrCr(row.opening) },
  { key: 'closing', header: 'Closing', numeric: true, render: (row) => formatDrCr(row.closing) },
  {
    key: 'status',
    header: '',
    render: (row) => (row.status !== 'ACTIVE' ? <Badge variant="warning">{row.status.toLowerCase()}</Badge> : null),
  },
  {
    key: 'modify',
    header: '',
    render: (row) => (
      <Link href={modifyHref(row)} className="text-xs font-medium text-brand-700 hover:underline">Modify</Link>
    ),
  },
];

/**
 * The ledger master — BUSY's Masters → Account list. Every ledger, parties
 * included, under its group, with its opening and closing balance, and a
 * Modify on each.
 */
export default async function LedgersPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string; group?: string }>;
}) {
  const params = await searchParams;
  const context = await requireTenantContext();
  const chart = await getChart();
  const [rows, groups] = await Promise.all([
    listLedgers({ search: params.q, groupId: params.group, limit: 1000 }),
    getGroupOptions(chart),
  ]);
  const canAdd = context.permissions.has('accounting.coa.manage');

  return (
    <div>
      <PageHeader
        title="Ledgers"
        description="Every ledger under its group — accounts, customers, suppliers and financiers. Open a name for its statement; Modify to change it."
        count={rows.length}
        action={
          canAdd ? (
            <div className="flex gap-2">
              <Button asChild variant="secondary" size="sm">
                <Link href="/accounting/ledger-groups">Groups</Link>
              </Button>
              <Button asChild size="sm">
                <Link href="/accounting/ledgers/new"><Plus aria-hidden />Add ledger</Link>
              </Button>
            </div>
          ) : undefined
        }
      />

      <form className="mb-4 flex flex-wrap items-center gap-2" role="search">
        <Input name="q" defaultValue={params.q ?? ''} placeholder="Name, code, alias or mobile" className="w-72" />
        <select name="group" defaultValue={params.group ?? ''} className="field h-10 px-3 text-sm" aria-label="Group">
          <option value="">All groups</option>
          {groups.map((g) => (
            <option key={g.id} value={g.id}>{'  '.repeat(g.depth)}{g.name}</option>
          ))}
        </select>
        <Button type="submit" variant="secondary" size="sm">Show</Button>
        {(params.q || params.group) && (
          <Link href="/accounting/ledgers" className="text-xs text-ink-500 hover:underline">Clear</Link>
        )}
      </form>

      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => `${row.kind}:${row.id}`}
        caption="Ledgers"
        emptyMessage="No ledgers match."
        maxHeight="44rem"
      />
      {rows.length >= 1000 && (
        <p className="mt-2 text-xs text-ink-500">Showing the first 1,000 — search or pick a group to narrow the list.</p>
      )}
    </div>
  );
}
