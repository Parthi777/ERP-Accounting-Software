import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import { getServiceInvoices, type ServiceInvoiceRow } from '@/server/services/service/service-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { add, formatINR, paise } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Service billing' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'neutral' | 'danger' | 'warning'> = {
  DRAFT: 'warning',
  POSTED: 'positive',
  CANCELLED: 'danger',
  RETURNED: 'neutral',
};

const STATUSES = ['ALL', 'DRAFT', 'POSTED', 'CANCELLED', 'RETURNED'];

const columns: Column<ServiceInvoiceRow>[] = [
  {
    key: 'number',
    header: 'Invoice',
    render: (row) => (
      <span>
        <Link href={`/service/billing/${row.id}`} className="block font-mono text-xs text-brand-600 hover:underline">
          {row.number}
        </Link>
        <span className="block text-[11px] text-ink-400">{formatDate(row.invoiceDate)}</span>
      </span>
    ),
  },
  {
    key: 'customer',
    header: 'Customer',
    render: (row) => row.customerName ?? <span className="text-ink-300">Counter sale</span>,
  },
  {
    key: 'jobcard',
    header: 'Job card',
    render: (row) =>
      row.jobCardNumber ? (
        <span className="font-mono text-xs text-ink-600">{row.jobCardNumber}</span>
      ) : (
        <span className="text-ink-300">—</span>
      ),
  },
  { key: 'branch', header: 'Branch', render: (row) => row.branchName },
  { key: 'total', header: 'Total', numeric: true, render: (row) => formatINR(row.total) },
  {
    key: 'paid',
    header: 'Received',
    numeric: true,
    render: (row) => <span className="text-positive-700">{formatINR(row.paid)}</span>,
  },
  {
    key: 'balance',
    header: 'Balance',
    numeric: true,
    render: (row) =>
      row.balance > 0 ? (
        <span className="font-medium text-warning-700">{formatINR(row.balance)}</span>
      ) : (
        <span className="text-positive-700">Settled</span>
      ),
  },
  {
    key: 'status',
    header: 'Status',
    render: (row) => <Badge variant={STATUS_TONE[row.status] ?? 'neutral'}>{row.status}</Badge>,
  },
];

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ status?: string }>;
}) {
  await requirePermission('service.jobcards.view');
  const params = await searchParams;
  const status = params.status ?? 'ALL';

  const rows = await getServiceInvoices({ status });

  const billed = rows
    .filter((r) => r.status === 'POSTED')
    .reduce((sum, r) => add(sum, r.total), paise(0));
  const outstanding = rows
    .filter((r) => r.status === 'POSTED')
    .reduce((sum, r) => add(sum, r.balance), paise(0));

  return (
    <>
      <PageHeader
        title="Service billing"
        description="Workshop invoices (spec §32). Posting recognises revenue, GST, cost and stock together."
        count={rows.length}
        action={
          <Button variant="secondary" size="sm" asChild>
            <Link href="/service"><ArrowLeft aria-hidden />Job cards</Link>
          </Button>
        }
      />

      <div className="mb-4 grid gap-3 sm:grid-cols-3">
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Billed (posted)</p>
          <p className="numeric mt-1 text-xl font-semibold text-ink-900">{formatINR(billed)}</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Outstanding</p>
          <p className={`numeric mt-1 text-xl font-semibold ${outstanding > 0 ? 'text-warning-700' : 'text-positive-700'}`}>
            {formatINR(outstanding)}
          </p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Drafts awaiting posting</p>
          <p className="numeric mt-1 text-xl font-semibold text-ink-900">
            {rows.filter((r) => r.status === 'DRAFT').length}
          </p>
        </Panel>
      </div>

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div>
            <label htmlFor="status" className="mb-1.5 block text-xs font-medium text-ink-600">Status</label>
            <select id="status" name="status" defaultValue={status}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
              {STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
            </select>
          </div>
          <Button type="submit" variant="secondary" size="sm">Filter</Button>
        </form>
      </Panel>

      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.id}
        emptyMessage="No service invoices yet. Bill a job card to create one."
        caption="Service invoices"
      />
    </>
  );
}
