import type { Metadata } from 'next';
import Link from 'next/link';
import { History, Plus } from 'lucide-react';

import { getJobCards, type JobCardRow } from '@/server/services/service/service-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { JobCardActions } from '@/components/service/job-card-actions';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { ExportButtons } from '@/components/export/export-buttons';
import { formatINR } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Job cards' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'info' | 'neutral' | 'warning' | 'danger'> = {
  OPEN: 'warning',
  IN_PROGRESS: 'info',
  READY: 'positive',
  INVOICED: 'positive',
  CLOSED: 'neutral',
  CANCELLED: 'danger',
};

const STATUSES = ['ALL', 'OPEN', 'IN_PROGRESS', 'READY', 'INVOICED', 'CLOSED', 'CANCELLED'];

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ status?: string; q?: string }>;
}) {
  const context = await requirePermission('service.jobcards.view');
  const params = await searchParams;
  const status = params.status ?? 'OPEN';

  const rows = await getJobCards({ status, q: params.q });

  const canBill = hasPermission(context, 'service.billing.create');
  const canEdit = hasPermission(context, 'service.jobcards.create');

  const columns: Column<JobCardRow>[] = [
    {
      key: 'number',
      header: 'Job card',
      render: (row) => (
        <span>
          <span className="block font-mono text-xs text-ink-700">{row.number}</span>
          <span className="block text-[11px] text-ink-400">{formatDate(row.jobDate)}</span>
        </span>
      ),
    },
    {
      key: 'customer',
      header: 'Customer',
      render: (row) => (
        <span>
          <Link href={`/customers/${row.customerId}`} className="block font-medium text-brand-600 hover:underline">
            {row.customerName}
          </Link>
          {row.registrationNo && (
            <span className="block font-mono text-[11px] text-ink-400">{row.registrationNo}</span>
          )}
        </span>
      ),
    },
    { key: 'type', header: 'Type', render: (row) => row.serviceType.replace('_', ' ') },
    {
      key: 'complaint',
      header: 'Complaint',
      render: (row) =>
        row.complaint ? (
          <span className="line-clamp-2 max-w-xs text-ink-600">{row.complaint}</span>
        ) : (
          <span className="text-ink-300">—</span>
        ),
    },
    { key: 'branch', header: 'Branch', render: (row) => row.branchName },
    {
      key: 'advisor',
      header: 'Advisor',
      render: (row) => row.advisorName ?? <span className="text-ink-300">—</span>,
    },
    {
      key: 'invoice',
      header: 'Invoice',
      render: (row) =>
        row.invoiceId ? (
          <Link href={`/service/billing/${row.invoiceId}`} className="font-mono text-xs text-brand-600 hover:underline">
            {row.invoiceNumber}
          </Link>
        ) : (
          <span className="text-ink-300">Not billed</span>
        ),
    },
    {
      key: 'total',
      header: 'Value',
      numeric: true,
      render: (row) => (row.invoiceTotal > 0 ? formatINR(row.invoiceTotal) : <span className="text-ink-300">—</span>),
    },
    {
      key: 'status',
      header: 'Status',
      render: (row) => <Badge variant={STATUS_TONE[row.status] ?? 'neutral'}>{row.status.replace('_', ' ')}</Badge>,
    },
    {
      key: 'actions',
      header: '',
      render: (row) => (
        <JobCardActions
          jobCardId={row.id}
          status={row.status}
          invoiceId={row.invoiceId}
          canBill={canBill}
          canEdit={canEdit}
        />
      ),
    },
  ];

  return (
    <>
      <PageHeader
        title="Job cards"
        description="Workshop jobs from booking-in to billing (spec §32)."
        count={rows.length}
        action={
          <div className="flex flex-wrap gap-2">
            <ExportButtons report="job-cards" />
            {hasPermission(context, 'service.history.view') && (
              <Button variant="secondary" size="sm" asChild>
                <Link href="/service/history"><History aria-hidden />History</Link>
              </Button>
            )}
            {canEdit && (
              <Button size="sm" asChild>
                <Link href="/service/new"><Plus aria-hidden />New job card</Link>
              </Button>
            )}
          </div>
        }
      />

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div>
            <label htmlFor="status" className="mb-1.5 block text-xs font-medium text-ink-600">Status</label>
            <select id="status" name="status" defaultValue={status}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
              {STATUSES.map((s) => <option key={s} value={s}>{s.replace('_', ' ')}</option>)}
            </select>
          </div>
          <div className="flex-1 min-w-48">
            <label htmlFor="q" className="mb-1.5 block text-xs font-medium text-ink-600">Search</label>
            <input id="q" name="q" defaultValue={params.q ?? ''}
              placeholder="Job card, customer or registration"
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" />
          </div>
          <Button type="submit" variant="secondary" size="sm">Filter</Button>
        </form>
      </Panel>

      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.id}
        emptyMessage={status === 'OPEN' ? 'No open job cards.' : 'No job cards match this filter.'}
        caption="Job cards"
      />
    </>
  );
}
