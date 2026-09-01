import type { Metadata } from 'next';
import Link from 'next/link';
import { Plus, Search, Users } from 'lucide-react';

import { searchCustomers, getCustomerStats } from '@/server/services/customers/customer-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { customerSearchSchema } from '@/lib/validation/customer';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatDate, formatMobile, formatNumber } from '@/lib/format';
import type { Customer } from '@/server/services/customers/customer-service';

export const metadata: Metadata = { title: 'Customers' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'neutral' | 'danger'> = {
  ACTIVE: 'positive',
  INACTIVE: 'neutral',
  BLOCKED: 'danger',
};

const columns: Column<Customer>[] = [
  {
    key: 'code',
    header: 'Customer ID',
    render: (row) => (
      <Link href={`/customers/${row.id}`} className="font-mono text-xs text-brand-600 hover:underline">
        {row.customer_code}
      </Link>
    ),
  },
  {
    key: 'name',
    header: 'Name',
    render: (row) => (
      <Link href={`/customers/${row.id}`} className="block hover:underline">
        <span className="font-medium text-ink-900">{row.name}</span>
        {row.customer_type === 'BUSINESS' && (
          <Badge variant="info" className="ml-2">Business</Badge>
        )}
      </Link>
    ),
  },
  { key: 'mobile', header: 'Mobile', render: (row) => formatMobile(row.mobile) },
  {
    key: 'city',
    header: 'City',
    render: (row) => row.city ?? <span className="text-ink-400">—</span>,
  },
  {
    key: 'gstin',
    header: 'GSTIN',
    render: (row) =>
      row.gstin ? (
        <span className="font-mono text-xs">{row.gstin}</span>
      ) : (
        <span className="text-ink-400">—</span>
      ),
  },
  {
    key: 'status',
    header: 'Status',
    render: (row) => <Badge variant={STATUS_TONE[row.status] ?? 'neutral'}>{row.status}</Badge>,
  },
  { key: 'created', header: 'Added', render: (row) => formatDate(row.created_at) },
];

export default async function CustomersPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string; status?: string; page?: string }>;
}) {
  const context = await requireTenantContext();
  const params = customerSearchSchema.parse(await searchParams);

  const [result, stats] = await Promise.all([
    searchCustomers({ q: params.q, status: params.status, page: params.page }),
    getCustomerStats(),
  ]);

  const canCreate = context.permissions.has('customers.create');

  const pageHref = (page: number) => {
    const next = new URLSearchParams();
    if (params.q) next.set('q', params.q);
    if (params.status !== 'ACTIVE') next.set('status', params.status);
    next.set('page', String(page));
    return `/customers?${next.toString()}`;
  };

  return (
    <div>
      <PageHeader
        title="Customers"
        description="Dealer-wide master. Every customer carries a system-issued Customer ID."
        count={result.total}
        action={
          canCreate ? (
            <Button asChild>
              <Link href="/customers/new">
                <Plus aria-hidden />
                New customer
              </Link>
            </Button>
          ) : undefined
        }
      />

      <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Stat label="Total customers" value={formatNumber(stats.total)} />
        <Stat label="Active" value={formatNumber(stats.active)} />
        <Stat label="Business (GST)" value={formatNumber(stats.business)} />
        <Stat label="Added this month" value={formatNumber(stats.addedThisMonth)} />
      </div>

      <Panel className="mb-4 p-3">
        <form method="GET" className="flex flex-wrap items-center gap-2">
          <div className="relative min-w-0 flex-1">
            <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-ink-400" aria-hidden />
            <input
              type="search"
              name="q"
              defaultValue={params.q ?? ''}
              placeholder="Customer ID, mobile, name or GSTIN…"
              aria-label="Search customers"
              className="h-9 w-full rounded-lg border border-ink-200 bg-white pl-9 pr-3 text-sm text-ink-900 shadow-sm placeholder:text-ink-400 focus:border-brand-400 focus:outline-none focus:ring-2 focus:ring-brand-500/20"
            />
          </div>
          <select
            name="status"
            defaultValue={params.status}
            aria-label="Status"
            className="h-9 rounded-lg border border-ink-200 bg-white px-2 text-sm text-ink-700 shadow-sm"
          >
            <option value="ACTIVE">Active</option>
            <option value="ALL">All statuses</option>
            <option value="INACTIVE">Inactive</option>
            <option value="BLOCKED">Blocked</option>
          </select>
          <Button type="submit" variant="secondary" size="sm">Search</Button>
          {(params.q || params.status !== 'ACTIVE') && (
            <Button variant="ghost" size="sm" asChild>
              <Link href="/customers">Clear</Link>
            </Button>
          )}
        </form>
      </Panel>

      <DataTable
        columns={columns}
        rows={result.rows}
        getRowKey={(row) => row.id}
        caption="Customers"
        emptyMessage={
          params.q
            ? `No customer matches “${params.q}”.`
            : 'No customers yet. Create the first one to get started.'
        }
      />

      {result.pageCount > 1 && (
        <div className="mt-3 flex items-center justify-between text-sm text-ink-500">
          <span>
            Page {result.page} of {result.pageCount} · {formatNumber(result.total)} customers
          </span>
          <div className="flex gap-2">
            <Button variant="secondary" size="sm" disabled={result.page <= 1} asChild={result.page > 1}>
              {result.page > 1 ? <Link href={pageHref(result.page - 1)}>Previous</Link> : <span>Previous</span>}
            </Button>
            <Button
              variant="secondary"
              size="sm"
              disabled={result.page >= result.pageCount}
              asChild={result.page < result.pageCount}
            >
              {result.page < result.pageCount ? (
                <Link href={pageHref(result.page + 1)}>Next</Link>
              ) : (
                <span>Next</span>
              )}
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}

function Stat({ label, value }: { readonly label: string; readonly value: string }) {
  return (
    <Panel className="flex items-center gap-3 p-4">
      <span className="flex size-9 shrink-0 items-center justify-center rounded-xl bg-brand-50 text-brand-600">
        <Users className="size-4" aria-hidden />
      </span>
      <span className="min-w-0">
        <span className="block truncate text-[12px] text-ink-500">{label}</span>
        <span className="numeric block text-left text-lg font-semibold text-ink-900">{value}</span>
      </span>
    </Panel>
  );
}
