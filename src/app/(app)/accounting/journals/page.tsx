import type { Metadata } from 'next';
import Link from 'next/link';

import { getJournals, type JournalSummary } from '@/server/services/accounting/accounting-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { ExportButtons } from '@/components/export/export-buttons';
import { formatINR } from '@/lib/money';
import { formatDate } from '@/lib/format';
import { monthRange } from '@/lib/period';
import type { JournalStatus } from '@/types/database.types';
import type { SourceModule } from '@/server/services/accounting/accounting-service';

export const metadata: Metadata = { title: 'Journal Entries' };
export const dynamic = 'force-dynamic';

// Typed against the column's union, so an added module in the migration that is
// missing here becomes a compile error rather than a filter that silently
// matches nothing.
const MODULES: readonly SourceModule[] = [
  'SALES', 'BOOKING', 'SERVICE', 'ACCESSORY', 'SPARE', 'FINANCE',
  'TRADE_ADVANCE', 'CASH', 'BANK', 'EXPENSE', 'INVENTORY', 'MANUAL', 'OPENING',
];

const STATUS_TONE: Record<string, 'positive' | 'neutral' | 'warning'> = {
  POSTED: 'positive',
  DRAFT: 'neutral',
  REVERSED: 'warning',
};

const columns: Column<JournalSummary>[] = [
  {
    key: 'number',
    header: 'Entry',
    render: (row) => (
      <Link href={`/accounting/journals/${row.id}`} className="font-mono text-xs text-brand-600 hover:underline">
        {row.entryNumber}
      </Link>
    ),
  },
  { key: 'date', header: 'Date', render: (row) => formatDate(row.entryDate) },
  {
    key: 'module',
    header: 'Module',
    render: (row) => <Badge variant="info">{row.sourceModule}</Badge>,
  },
  {
    key: 'narration',
    header: 'Narration',
    render: (row) => <span className="text-ink-700">{row.narration ?? '—'}</span>,
  },
  {
    key: 'branch',
    header: 'Branch',
    render: (row) => row.branchName ?? <span className="text-ink-400">—</span>,
  },
  {
    key: 'amount',
    header: 'Amount',
    numeric: true,
    render: (row) => formatINR(row.totalDebit),
  },
  {
    key: 'status',
    header: 'Status',
    render: (row) => (
      <span className="flex items-center gap-1">
        <Badge variant={STATUS_TONE[row.status] ?? 'neutral'}>{row.status}</Badge>
        {row.reversalOfId && <Badge variant="neutral">reversal</Badge>}
      </span>
    ),
  },
];

export default async function JournalsPage({
  searchParams,
}: {
  searchParams: Promise<{ from?: string; to?: string; branch?: string; module?: string; status?: string }>;
}) {
  const context = await requireTenantContext();
  const params = await searchParams;
  const { from, to } = monthRange(params.from, params.to);
  const branchId = params.branch === 'all' ? null : (params.branch ?? null);
  const moduleFilter =
    params.module && (MODULES as readonly string[]).includes(params.module)
      ? (params.module as SourceModule)
      : null;
  const statusFilter = ['DRAFT', 'POSTED', 'REVERSED'].includes(params.status ?? '')
    ? (params.status as JournalStatus)
    : null;

  const rows = await getJournals({ from, to, branchId, module: moduleFilter, status: statusFilter });

  return (
    <div>
      <PageHeader
        title="Journal Entries"
        description="Every module posts into this one ledger. A posted entry is immutable; corrections are reversals."
        count={rows.length}
        action={<ExportButtons report="journal-register" />}
      />

      <Panel className="mb-4 p-3">
        <form method="GET" className="flex flex-wrap items-center gap-2">
          <input type="date" name="from" defaultValue={from} aria-label="From date"
            className="h-9 rounded-lg border border-ink-200 bg-white px-2 text-sm text-ink-700 shadow-sm" />
          <span className="text-ink-300">–</span>
          <input type="date" name="to" defaultValue={to} aria-label="To date"
            className="h-9 rounded-lg border border-ink-200 bg-white px-2 text-sm text-ink-700 shadow-sm" />

          {context.accessibleBranches.length > 0 && (
            <select name="branch" defaultValue={branchId ?? 'all'} aria-label="Branch"
              className="h-9 rounded-lg border border-ink-200 bg-white px-2 text-sm text-ink-700 shadow-sm">
              {context.hasAllBranchAccess && <option value="all">All branches</option>}
              {context.accessibleBranches.map((b) => (
                <option key={b.id} value={b.id}>{b.name}</option>
              ))}
            </select>
          )}

          <select name="module" defaultValue={moduleFilter ?? ''} aria-label="Module"
            className="h-9 rounded-lg border border-ink-200 bg-white px-2 text-sm text-ink-700 shadow-sm">
            <option value="">All modules</option>
            {MODULES.map((m) => <option key={m} value={m}>{m}</option>)}
          </select>

          <select name="status" defaultValue={statusFilter ?? ''} aria-label="Status"
            className="h-9 rounded-lg border border-ink-200 bg-white px-2 text-sm text-ink-700 shadow-sm">
            <option value="">All statuses</option>
            <option value="POSTED">Posted</option>
            <option value="DRAFT">Draft</option>
            <option value="REVERSED">Reversed</option>
          </select>

          <Button type="submit" variant="secondary" size="sm">Apply</Button>
        </form>
      </Panel>

      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.id}
        caption="Journal entries"
        emptyMessage="No journal entries match these filters."
        maxHeight="40rem"
      />

      {rows.length >= 200 && (
        <p className="mt-2 text-xs text-ink-500">
          Showing the most recent 200 entries. Narrow the date range to see older ones.
        </p>
      )}
    </div>
  );
}
