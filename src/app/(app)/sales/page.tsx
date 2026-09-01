import type { Metadata } from 'next';
import Link from 'next/link';
import { Plus, Search } from 'lucide-react';

import { getSales, type SaleListRow } from '@/server/services/sales/sale-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { ExportButtons } from '@/components/export/export-buttons';
import { formatINR } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Vehicle Sales' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'neutral' | 'info' | 'warning' | 'positive' | 'danger' | 'accent'> = {
  DRAFT: 'neutral',
  SUBMITTED: 'info',
  ACCOUNTS_VERIFICATION: 'warning',
  APPROVED: 'accent',
  POSTED: 'positive',
  DELIVERED: 'positive',
  CANCELLED: 'danger',
  RETURNED: 'danger',
};

const columns: Column<SaleListRow>[] = [
  {
    key: 'invoice',
    header: 'Invoice',
    render: (row) => (
      <Link href={`/sales/${row.id}`} className="font-mono text-xs text-brand-600 hover:underline">
        {row.invoiceNumber}
      </Link>
    ),
  },
  { key: 'date', header: 'Date', render: (row) => formatDate(row.invoiceDate) },
  {
    key: 'customer',
    header: 'Customer',
    render: (row) => (
      <span>
        <span className="block font-medium text-ink-900">{row.customerName}</span>
        <span className="block font-mono text-[11px] text-ink-400">{row.customerCode}</span>
      </span>
    ),
  },
  {
    key: 'vehicle',
    header: 'Vehicle',
    render: (row) => (
      <span>
        <span className="block text-ink-800">{row.modelLabel}</span>
        <span className="block font-mono text-[11px] text-ink-400">{row.chassisNo}</span>
      </span>
    ),
  },
  { key: 'branch', header: 'Branch', render: (row) => row.branchName },
  { key: 'total', header: 'Invoice', numeric: true, render: (row) => formatINR(row.totalAmount) },
  { key: 'paid', header: 'Received', numeric: true, render: (row) => formatINR(row.paidAmount) },
  { key: 'finance', header: 'Finance', numeric: true, render: (row) => formatINR(row.financeAmount) },
  {
    key: 'balance',
    header: 'Balance',
    numeric: true,
    render: (row) => (
      <span className={row.balanceAmount > 0 ? 'text-warning-700' : 'text-positive-700'}>
        {formatINR(row.balanceAmount)}
      </span>
    ),
  },
  {
    key: 'status',
    header: 'Status',
    render: (row) => (
      <Badge variant={STATUS_TONE[row.status] ?? 'neutral'}>{row.status.replace(/_/g, ' ')}</Badge>
    ),
  },
];

export default async function SalesPage({
  searchParams,
}: {
  searchParams: Promise<{ status?: string; branch?: string; q?: string }>;
}) {
  const context = await requireTenantContext();
  const params = await searchParams;
  const status = params.status ?? 'ALL';
  const branchId = params.branch === 'all' ? null : (params.branch ?? null);

  const rows = await getSales({ status, branchId, q: params.q });
  const canCreate = context.permissions.has('sales.create');

  // Accounts staff care most about what is waiting on them (spec §53).
  const awaitingVerification = rows.filter((r) => r.status === 'SUBMITTED' || r.status === 'ACCOUNTS_VERIFICATION').length;

  return (
    <div>
      <PageHeader
        title="Vehicle Sales"
        description="Draft → submitted → accounts verification → approved → posted → delivered. Posting happens only after approval."
        count={rows.length}
        action={
          <div className="flex flex-wrap items-center gap-2">
            <ExportButtons report="sales-register" />
            {canCreate && (
              <Button asChild><Link href="/sales/new"><Plus aria-hidden />New sale</Link></Button>
            )}
          </div>
        }
      />

      {awaitingVerification > 0 && context.permissions.has('sales.verify') && (
        <Panel className="mb-4 flex items-center gap-3 p-4">
          <Badge variant="warning">{awaitingVerification} awaiting</Badge>
          <span className="text-sm text-ink-600">
            {awaitingVerification} sale{awaitingVerification === 1 ? '' : 's'} need accounts verification before they can post.
          </span>
          <Link href="/sales?status=SUBMITTED" className="ml-auto text-sm text-brand-600 hover:underline">
            Show them
          </Link>
        </Panel>
      )}

      <Panel className="mb-4 p-3">
        <form method="GET" className="flex flex-wrap items-center gap-2">
          <div className="relative min-w-0 flex-1">
            <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-ink-400" aria-hidden />
            <input type="search" name="q" defaultValue={params.q ?? ''}
              placeholder="Invoice number, customer or chassis…" aria-label="Search sales"
              className="h-9 w-full rounded-lg border border-ink-200 bg-white pl-9 pr-3 text-sm shadow-sm placeholder:text-ink-400 focus:border-brand-400 focus:outline-none focus:ring-2 focus:ring-brand-500/20" />
          </div>
          <select name="status" defaultValue={status} aria-label="Status"
            className="h-9 rounded-lg border border-ink-200 bg-white px-2 text-sm text-ink-700 shadow-sm">
            <option value="ALL">All statuses</option>
            <option value="DRAFT">Draft</option>
            <option value="SUBMITTED">Submitted</option>
            <option value="ACCOUNTS_VERIFICATION">Accounts verification</option>
            <option value="APPROVED">Approved</option>
            <option value="POSTED">Posted</option>
            <option value="DELIVERED">Delivered</option>
            <option value="CANCELLED">Cancelled</option>
          </select>
          {context.accessibleBranches.length > 0 && (
            <select name="branch" defaultValue={params.branch ?? 'all'} aria-label="Branch"
              className="h-9 rounded-lg border border-ink-200 bg-white px-2 text-sm text-ink-700 shadow-sm">
              {context.hasAllBranchAccess && <option value="all">All branches</option>}
              {context.accessibleBranches.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
            </select>
          )}
          <Button type="submit" variant="secondary" size="sm">Search</Button>
        </form>
      </Panel>

      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.id}
        caption="Vehicle sales"
        emptyMessage="No sales yet."
        maxHeight="40rem"
      />
    </div>
  );
}
