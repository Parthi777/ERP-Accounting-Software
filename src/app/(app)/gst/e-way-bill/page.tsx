import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import {
  getEwayBills,
  getGstPortalStatus,
  type EwayBillRow,
} from '@/server/services/gst/gst-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatDate, formatDateTime } from '@/lib/format';

export const metadata: Metadata = { title: 'E-way bills' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'warning' | 'danger' | 'neutral' | 'info'> = {
  GENERATED: 'positive',
  PENDING: 'info',
  FAILED: 'danger',
  CANCELLED: 'neutral',
  EXPIRED: 'warning',
};

const columns: Column<EwayBillRow>[] = [
  {
    key: 'document',
    header: 'Document',
    render: (row) => (
      <span>
        <span className="block font-mono text-xs text-ink-700">{row.documentNumber}</span>
        <span className="block text-[11px] text-ink-400">{row.documentType.replace('_', ' ')}</span>
      </span>
    ),
  },
  {
    key: 'number',
    header: 'E-way bill',
    render: (row) =>
      row.ewayBillNumber ? (
        <span className="font-mono text-xs">{row.ewayBillNumber}</span>
      ) : (
        <span className="text-ink-300">Not issued</span>
      ),
  },
  {
    key: 'transport',
    header: 'Transport',
    render: (row) => (
      <span>
        <span className="block">{row.transportMode ?? '—'}</span>
        {row.vehicleNumber && (
          <span className="block font-mono text-[11px] text-ink-400">{row.vehicleNumber}</span>
        )}
      </span>
    ),
  },
  {
    key: 'generated',
    header: 'Generated',
    render: (row) => (row.generatedAt ? formatDateTime(row.generatedAt) : <span className="text-ink-300">—</span>),
  },
  {
    key: 'valid',
    header: 'Valid until',
    render: (row) => {
      if (!row.validUntil) return <span className="text-ink-300">—</span>;
      const expired = new Date(row.validUntil) < new Date();
      return <span className={expired ? 'text-danger-700' : ''}>{formatDate(row.validUntil)}</span>;
    },
  },
  {
    key: 'status',
    header: 'Status',
    render: (row) => (
      <span>
        <Badge variant={STATUS_TONE[row.status] ?? 'neutral'}>{row.status}</Badge>
        {row.errorMessage && (
          <span className="mt-0.5 block max-w-48 text-[11px] text-danger-700" title={row.errorMessage}>
            {row.errorMessage}
          </span>
        )}
      </span>
    ),
  },
];

export default async function Page() {
  await requirePermission('gst.summary.view');

  const [rows, portal] = await Promise.all([getEwayBills(), getGstPortalStatus()]);

  return (
    <>
      <PageHeader
        title="E-way bills"
        description="Movement documents raised against invoices and stock transfers (spec §40)."
        count={rows.length}
        action={
          <Button variant="secondary" size="sm" asChild>
            <Link href="/gst"><ArrowLeft aria-hidden />GST</Link>
          </Button>
        }
      />

      {!portal.configured && (
        <Panel className="mb-4 border-warning-200 bg-warning-50 p-4">
          <p className="text-sm font-medium text-warning-900">The GST portal is not connected.</p>
          <p className="mt-1 text-xs text-warning-800">
            E-way bills queued here are recorded locally. No bill number will be issued until portal
            credentials are configured for this dealer.
          </p>
        </Panel>
      )}

      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.id}
        emptyMessage="No e-way bills raised yet. They are queued from a sale or a stock transfer."
        caption="E-way bills"
      />
    </>
  );
}
