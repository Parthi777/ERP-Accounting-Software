import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import {
  getEinvoiceQueue,
  getGstPortalStatus,
  getIrpConfiguration,
  type EinvoiceQueueRow,
} from '@/server/services/gst/gst-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { EinvoiceActions } from '@/components/gst/einvoice-actions';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatINR } from '@/lib/money';
import { monthRange } from '@/lib/period';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'E-invoices' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'warning' | 'danger' | 'neutral' | 'info'> = {
  GENERATED: 'positive',
  PENDING: 'info',
  FAILED: 'danger',
  CANCELLED: 'neutral',
  NOT_REQUESTED: 'warning',
};

const STATUS_LABEL: Record<string, string> = {
  GENERATED: 'Filed',
  PENDING: 'Queued',
  FAILED: 'Failed',
  CANCELLED: 'Cancelled',
  NOT_REQUESTED: 'Not queued',
};

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ from?: string; to?: string }>;
}) {
  const context = await requirePermission('gst.summary.view');
  const params = await searchParams;
  const range = monthRange(params.from, params.to);

  const [rows, portal, irp] = await Promise.all([
    getEinvoiceQueue({ from: range.from, to: range.to }),
    getGstPortalStatus(),
    getIrpConfiguration(),
  ]);

  const canGenerate = hasPermission(context, 'gst.einvoice.generate');
  const canRetry = hasPermission(context, 'gst.einvoice.retry');

  const columns: Column<EinvoiceQueueRow>[] = [
    {
      key: 'document',
      header: 'Document',
      render: (row) => (
        <span>
          <Link
            href={row.documentType === 'SALE' ? `/sales/${row.documentId}` : `/service/billing/${row.documentId}`}
            className="block font-mono text-xs text-brand-600 hover:underline"
          >
            {row.documentNumber}
          </Link>
          <span className="block text-[11px] text-ink-400">
            {formatDate(row.documentDate)} · {row.documentType === 'SALE' ? 'Vehicle' : 'Service'}
          </span>
        </span>
      ),
    },
    {
      key: 'customer',
      header: 'Customer',
      render: (row) => (
        <span>
          <span className="block">{row.customerName}</span>
          <span className="block font-mono text-[11px] text-ink-400">
            {row.gstin ?? 'No GSTIN — B2C'}
          </span>
        </span>
      ),
    },
    { key: 'value', header: 'Invoice value', numeric: true, render: (row) => formatINR(row.invoiceValue) },
    {
      key: 'status',
      header: 'Status',
      render: (row) => (
        <span>
          <Badge variant={STATUS_TONE[row.status] ?? 'neutral'}>
            {STATUS_LABEL[row.status] ?? row.status}
          </Badge>
          {row.attemptCount > 0 && (
            <span className="ml-1 text-[11px] text-ink-400">{row.attemptCount} attempts</span>
          )}
        </span>
      ),
    },
    {
      key: 'irn',
      header: 'IRN',
      render: (row) =>
        row.irn ? (
          <span className="block max-w-48 truncate font-mono text-[11px] text-ink-600" title={row.irn}>
            {row.irn}
          </span>
        ) : row.errorMessage ? (
          <span className="block max-w-48 text-[11px] text-danger-700" title={row.errorMessage}>
            {row.errorMessage}
          </span>
        ) : (
          <span className="text-ink-300">—</span>
        ),
    },
    {
      key: 'actions',
      header: '',
      render: (row) => (
        <EinvoiceActions
          einvoiceId={row.einvoiceId}
          documentType={row.documentType}
          documentId={row.documentId}
          status={row.status}
          attemptCount={row.attemptCount}
          canGenerate={canGenerate}
          canRetry={canRetry}
          portalConfigured={irp.configured}
        />
      ),
    },
  ];

  const notQueued = rows.filter((r) => r.status === 'NOT_REQUESTED').length;
  const failed = rows.filter((r) => r.status === 'FAILED').length;
  const filed = rows.filter((r) => r.status === 'GENERATED').length;

  return (
    <>
      <PageHeader
        title="E-invoices"
        description={`Posted invoices for ${formatDate(range.from)} – ${formatDate(range.to)} and where each stands with the IRP (spec §40).`}
        count={rows.length}
        action={
          <Button variant="secondary" size="sm" asChild>
            <Link href="/gst"><ArrowLeft aria-hidden />GST</Link>
          </Button>
        }
      />

      {/* The environment is what actually gates transmission; the dealer flag is
          a statement of intent. Both are reported, because they fail differently. */}
      {!irp.configured && (
        <Panel className="mb-4 border-warning-200 bg-warning-50 p-4">
          <p className="text-sm font-medium text-warning-900">
            No e-invoice provider is configured, so nothing can be sent to the portal.
          </p>
          <p className="mt-1 text-xs text-warning-800">
            Queueing still records what is due to be filed, and none of it is lost. Filing becomes
            available once <code>GST_API_BASE_URL</code> and the API credentials are set — see
            <code className="ml-1">.env.example</code>. Credentials are all-or-nothing on purpose: a
            half-configured provider would fail mid-filing.
          </p>
        </Panel>
      )}

      {irp.configured && !portal.configured && (
        <Panel className="mb-4 border-warning-200 bg-warning-50 p-4">
          <p className="text-sm font-medium text-warning-900">
            A provider is configured, but this dealer is not marked live on the IRP.
          </p>
          <p className="mt-1 text-xs text-warning-800">
            Filing will be attempted and the portal&rsquo;s own reply recorded. If the GSTIN is not
            registered for e-invoicing, expect a rejection rather than an IRN.
          </p>
        </Panel>
      )}

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div>
            <label htmlFor="from" className="mb-1.5 block text-xs font-medium text-ink-600">From</label>
            <input id="from" name="from" type="date" defaultValue={range.from}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" />
          </div>
          <div>
            <label htmlFor="to" className="mb-1.5 block text-xs font-medium text-ink-600">To</label>
            <input id="to" name="to" type="date" defaultValue={range.to}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" />
          </div>
          <Button type="submit" variant="secondary" size="sm">Apply</Button>

          <div className="ml-auto flex gap-4 text-xs">
            <span><span className="font-semibold text-positive-700">{filed}</span> filed</span>
            <span><span className="font-semibold text-danger-700">{failed}</span> failed</span>
            <span><span className="font-semibold text-warning-700">{notQueued}</span> not queued</span>
          </div>
        </form>
      </Panel>

      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => `${row.documentType}:${row.documentId}`}
        emptyMessage="No posted invoices in this period."
        caption="E-invoice queue"
      />
    </>
  );
}
