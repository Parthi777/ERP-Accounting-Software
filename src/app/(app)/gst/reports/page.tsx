import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import { getGstDocuments, type GstDocumentRow } from '@/server/services/gst/gst-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { add, formatINR, paise } from '@/lib/money';
import { monthRange } from '@/lib/period';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'GST reports' };
export const dynamic = 'force-dynamic';

const columns: Column<GstDocumentRow>[] = [
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
        <span className="block text-[11px] text-ink-400">{formatDate(row.documentDate)}</span>
      </span>
    ),
  },
  {
    key: 'customer',
    header: 'Customer',
    render: (row) => (
      <span>
        <span className="block">{row.customerName}</span>
        <span className="block font-mono text-[11px] text-ink-400">{row.gstin ?? '—'}</span>
      </span>
    ),
  },
  {
    key: 'section',
    header: 'Section',
    render: (row) => <Badge variant={row.section === 'B2B' ? 'info' : 'neutral'}>{row.section}</Badge>,
  },
  {
    key: 'pos',
    header: 'Place of supply',
    render: (row) => row.placeOfSupply ?? <span className="text-ink-300">—</span>,
  },
  { key: 'taxable', header: 'Taxable', numeric: true, render: (row) => formatINR(row.taxableValue) },
  { key: 'cgst', header: 'CGST', numeric: true, render: (row) => formatINR(row.cgst) },
  { key: 'sgst', header: 'SGST', numeric: true, render: (row) => formatINR(row.sgst) },
  {
    key: 'igst',
    header: 'IGST',
    numeric: true,
    render: (row) => (row.igst > 0 ? formatINR(row.igst) : <span className="text-ink-300">—</span>),
  },
  {
    key: 'value',
    header: 'Invoice value',
    numeric: true,
    render: (row) => <span className="font-medium">{formatINR(row.invoiceValue)}</span>,
  },
  {
    key: 'irn',
    header: 'E-invoice',
    render: (row) =>
      row.irn ? (
        <span className="block max-w-32 truncate font-mono text-[11px] text-positive-700" title={row.irn}>
          {row.irn}
        </span>
      ) : (
        <span className="text-[11px] text-ink-400">
          {row.einvoiceStatus === 'NOT_REQUESTED' ? 'Not queued' : row.einvoiceStatus}
        </span>
      ),
  },
];

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ from?: string; to?: string; section?: string }>;
}) {
  await requirePermission('gst.reports.view');
  const params = await searchParams;
  const range = monthRange(params.from, params.to);
  const section = params.section ?? 'ALL';

  const rows = await getGstDocuments({ from: range.from, to: range.to, section });

  const taxable = rows.reduce((sum, r) => add(sum, r.taxableValue), paise(0));
  const tax = rows.reduce((sum, r) => add(sum, paise(r.cgst + r.sgst + r.igst)), paise(0));
  const value = rows.reduce((sum, r) => add(sum, r.invoiceValue), paise(0));

  return (
    <>
      <PageHeader
        title="GST document register"
        description="Every outward supply behind the return, invoice by invoice (spec §40, §41)."
        count={rows.length}
        action={
          <Button variant="secondary" size="sm" asChild>
            <Link href="/gst"><ArrowLeft aria-hidden />GST summary</Link>
          </Button>
        }
      />

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
          <div>
            <label htmlFor="section" className="mb-1.5 block text-xs font-medium text-ink-600">Section</label>
            <select id="section" name="section" defaultValue={section}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
              <option value="ALL">All</option>
              <option value="B2B">B2B</option>
              <option value="B2C">B2C</option>
            </select>
          </div>
          <Button type="submit" variant="secondary" size="sm">Apply</Button>
        </form>
      </Panel>

      <div className="mb-4 grid gap-3 sm:grid-cols-3">
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Taxable value</p>
          <p className="numeric mt-1 text-xl font-semibold text-ink-900">{formatINR(taxable)}</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Tax</p>
          <p className="numeric mt-1 text-xl font-semibold text-brand-700">{formatINR(tax)}</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Invoice value</p>
          <p className="numeric mt-1 text-xl font-semibold text-ink-900">{formatINR(value)}</p>
        </Panel>
      </div>

      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => `${row.documentType}:${row.documentId}`}
        emptyMessage="No posted invoices in this period."
        caption="GST document register"
      />
    </>
  );
}
