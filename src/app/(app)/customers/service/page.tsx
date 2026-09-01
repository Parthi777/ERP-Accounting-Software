import type { Metadata } from 'next';
import Link from 'next/link';

import {
  getCustomerServiceRollup,
  type CustomerServiceRollup,
} from '@/server/services/service/service-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { add, formatINR, ZERO } from '@/lib/money';
import { formatDate, formatMobile } from '@/lib/format';

export const metadata: Metadata = { title: 'Service history' };
export const dynamic = 'force-dynamic';

/**
 * Spec §33, and deliberately not a second copy of `/service/history`.
 *
 * That screen answers "what happened on this job". This one answers what a
 * per-visit list cannot: who has stopped coming, and who is worth the most.
 * One row per customer, ordered by how recently they were last in.
 */
export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ due?: string; q?: string }>;
}) {
  await requirePermission('service.history.view');
  const params = await searchParams;
  const dueOnly = params.due === '1';

  const all = await getCustomerServiceRollup({ branchId: null, dueOnly });

  const term = params.q?.trim().toLowerCase();
  const rows = term
    ? all.filter(
        (r) =>
          r.customerName.toLowerCase().includes(term) ||
          r.customerCode.toLowerCase().includes(term) ||
          (r.mobile?.includes(term) ?? false),
      )
    : all;

  const lifetime = rows.reduce((sum, r) => add(sum, r.lifetimeValue), ZERO);
  const dueCount = rows.filter((r) => r.serviceDue).length;
  const openJobs = rows.reduce((sum, r) => sum + r.openJobs, 0);

  const columns: Column<CustomerServiceRollup>[] = [
    {
      key: 'customer',
      header: 'Customer',
      render: (row) => (
        <span>
          <Link href={`/customers/${row.customerId}`} className="block font-medium text-brand-600 hover:underline">
            {row.customerName}
          </Link>
          <span className="block font-mono text-[11px] text-ink-400">{row.customerCode}</span>
        </span>
      ),
    },
    { key: 'mobile', header: 'Mobile', render: (row) => formatMobile(row.mobile) },
    { key: 'vehicles', header: 'Vehicles', numeric: true, render: (row) => row.vehicleCount },
    { key: 'visits', header: 'Visits', numeric: true, render: (row) => row.visitCount },
    {
      key: 'lifetime',
      header: 'Lifetime value',
      numeric: true,
      render: (row) => formatINR(row.lifetimeValue),
    },
    {
      key: 'last',
      header: 'Last visit',
      render: (row) => (
        <span>
          <span className="block text-ink-700">
            {row.lastVisit ? formatDate(row.lastVisit) : '—'}
          </span>
          {row.daysSinceLastVisit !== null && (
            <span className="block text-[11px] text-ink-400">
              {row.daysSinceLastVisit === 0 ? 'today' : `${row.daysSinceLastVisit} days ago`}
            </span>
          )}
        </span>
      ),
    },
    {
      key: 'open',
      header: 'Open',
      numeric: true,
      render: (row) =>
        row.openJobs > 0 ? (
          <span className="font-medium text-warning-700">{row.openJobs}</span>
        ) : (
          <span className="text-ink-300">—</span>
        ),
    },
    {
      key: 'due',
      header: 'Status',
      render: (row) =>
        row.serviceDue ? <Badge variant="warning">Due</Badge> : <Badge variant="positive">Current</Badge>,
    },
    {
      key: 'actions',
      header: '',
      render: (row) => (
        <div className="flex justify-end">
          <Button size="sm" variant="ghost" asChild>
            <Link href={`/service/history?customer=${row.customerId}`}>Visits</Link>
          </Button>
        </div>
      ),
    },
  ];

  return (
    <>
      <PageHeader
        title="Service history"
        description="One row per customer: how often they come, what they are worth, and who has stopped coming (spec §33)."
        count={rows.length}
      />

      <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Customers served</p>
          <p className="mt-0.5 text-lg font-semibold text-ink-800">{rows.length}</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Lifetime service value</p>
          <p className="mt-0.5 text-lg font-semibold text-ink-800">{formatINR(lifetime)}</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Due a service</p>
          <p className="mt-0.5 text-lg font-semibold text-warning-700">{dueCount}</p>
          <p className="mt-0.5 text-[11px] text-ink-400">Nothing in six months</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Open jobs</p>
          <p className="mt-0.5 text-lg font-semibold text-ink-800">{openJobs}</p>
        </Panel>
      </div>

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div>
            <label htmlFor="due" className="mb-1.5 block text-xs font-medium text-ink-600">Showing</label>
            <select
              id="due" name="due" defaultValue={dueOnly ? '1' : ''}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            >
              <option value="">Everyone who has been in</option>
              <option value="1">Due a service</option>
            </select>
          </div>
          <div className="min-w-48 flex-1">
            <label htmlFor="q" className="mb-1.5 block text-xs font-medium text-ink-600">Search</label>
            <input
              id="q" name="q" defaultValue={params.q ?? ''}
              placeholder="Customer name, code or mobile"
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            />
          </div>
          <Button type="submit" variant="secondary" size="sm">Filter</Button>
        </form>
      </Panel>

      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.customerId}
        emptyMessage={
          dueOnly ? 'Nobody is overdue a service.' : 'No customer has been in for service yet.'
        }
        caption="Customer service rollup"
        maxHeight="40rem"
      />
    </>
  );
}
