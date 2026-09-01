import type { Metadata } from 'next';
import Link from 'next/link';
import { FileText, Truck } from 'lucide-react';

import {
  getGstPortalStatus,
  getGstr1Summary,
  getHsnSummary,
  type GstrSection,
  type HsnSummaryRow,
} from '@/server/services/gst/gst-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { add, formatINR, paise } from '@/lib/money';
import { monthRange } from '@/lib/period';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'GST' };
export const dynamic = 'force-dynamic';

const sectionColumns: Column<GstrSection>[] = [
  {
    key: 'section',
    header: 'Section',
    render: (row) => (
      <span>
        <span className="block font-medium">{row.section}</span>
        <span className="block text-[11px] text-ink-400">
          {row.section === 'B2B' ? 'Registered buyers' : 'Unregistered buyers'}
        </span>
      </span>
    ),
  },
  { key: 'count', header: 'Documents', numeric: true, render: (row) => row.documentCount },
  { key: 'taxable', header: 'Taxable value', numeric: true, render: (row) => formatINR(row.taxableValue) },
  { key: 'cgst', header: 'CGST', numeric: true, render: (row) => formatINR(row.cgst) },
  { key: 'sgst', header: 'SGST', numeric: true, render: (row) => formatINR(row.sgst) },
  { key: 'igst', header: 'IGST', numeric: true, render: (row) => formatINR(row.igst) },
  {
    key: 'total',
    header: 'Total tax',
    numeric: true,
    render: (row) => <span className="font-medium">{formatINR(row.totalTax)}</span>,
  },
  { key: 'value', header: 'Invoice value', numeric: true, render: (row) => formatINR(row.invoiceValue) },
];

const hsnColumns: Column<HsnSummaryRow>[] = [
  {
    key: 'hsn',
    header: 'HSN',
    render: (row) => (
      <span>
        <span className="block font-mono text-xs">{row.hsnCode}</span>
        {row.description && <span className="block text-[11px] text-ink-400">{row.description}</span>}
      </span>
    ),
  },
  { key: 'count', header: 'Documents', numeric: true, render: (row) => row.documentCount },
  { key: 'taxable', header: 'Taxable value', numeric: true, render: (row) => formatINR(row.taxableValue) },
  { key: 'cgst', header: 'CGST', numeric: true, render: (row) => formatINR(row.cgst) },
  { key: 'sgst', header: 'SGST', numeric: true, render: (row) => formatINR(row.sgst) },
  { key: 'igst', header: 'IGST', numeric: true, render: (row) => formatINR(row.igst) },
  {
    key: 'total',
    header: 'Total tax',
    numeric: true,
    render: (row) => <span className="font-medium">{formatINR(row.totalTax)}</span>,
  },
];

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ from?: string; to?: string }>;
}) {
  const context = await requirePermission('gst.summary.view');
  const params = await searchParams;
  const range = monthRange(params.from, params.to);

  const [sections, hsn, portal] = await Promise.all([
    getGstr1Summary({ from: range.from, to: range.to }),
    getHsnSummary({ from: range.from, to: range.to }),
    getGstPortalStatus(),
  ]);

  const totalTax = sections.reduce((sum, s) => add(sum, s.totalTax), paise(0));
  const totalTaxable = sections.reduce((sum, s) => add(sum, s.taxableValue), paise(0));
  const b2c = sections.find((s) => s.section === 'B2C');

  return (
    <>
      <PageHeader
        title="GST"
        description={`Outward supplies for ${formatDate(range.from)} – ${formatDate(range.to)} (spec §40).`}
        action={
          <div className="flex flex-wrap gap-2">
            {hasPermission(context, 'gst.reports.view') && (
              <Button variant="secondary" size="sm" asChild>
                <Link href={`/gst/reports?from=${range.from}&to=${range.to}`}>
                  <FileText aria-hidden />Document register
                </Link>
              </Button>
            )}
            <Button variant="secondary" size="sm" asChild>
              <Link href={`/gst/e-invoice?from=${range.from}&to=${range.to}`}>E-invoices</Link>
            </Button>
            <Button variant="secondary" size="sm" asChild>
              <Link href="/gst/e-way-bill"><Truck aria-hidden />E-way bills</Link>
            </Button>
          </div>
        }
      />

      {!portal.configured && (
        <Panel className="mb-4 border-warning-200 bg-warning-50 p-4">
          <p className="text-sm font-medium text-warning-900">
            The GST portal is not connected for this dealer.
          </p>
          <p className="mt-1 text-xs text-warning-800">
            The figures below are computed from your own posted invoices and are accurate. E-invoices
            and e-way bills can be queued, but nothing is transmitted to the IRP until credentials are
            configured — so no IRN will appear against them.
            {portal.gstin ? ` Dealer GSTIN on file: ${portal.gstin}.` : ' No dealer GSTIN is on file yet.'}
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
        </form>
      </Panel>

      <div className="mb-4 grid gap-3 sm:grid-cols-3">
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Taxable value</p>
          <p className="numeric mt-1 text-xl font-semibold text-ink-900">{formatINR(totalTaxable)}</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Output tax</p>
          <p className="numeric mt-1 text-xl font-semibold text-brand-700">{formatINR(totalTax)}</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Documents</p>
          <p className="numeric mt-1 text-xl font-semibold text-ink-900">
            {sections.reduce((n, s) => n + s.documentCount, 0)}
          </p>
        </Panel>
      </div>

      {b2c && b2c.documentCount > 0 && (
        <Panel className="mb-4 p-4">
          <p className="text-sm text-ink-700">
            <Badge variant="info" className="mr-2">B2C</Badge>
            {b2c.documentCount} document{b2c.documentCount === 1 ? '' : 's'} have no customer GSTIN and
            will be reported as unregistered supplies.
          </p>
          <p className="mt-1 text-xs text-ink-500">
            If any of those buyers are registered, capture the GSTIN on the customer before filing —
            they cannot claim input credit otherwise.
          </p>
        </Panel>
      )}

      <h2 className="mb-3 text-sm font-semibold text-ink-900">By section</h2>
      <DataTable
        columns={sectionColumns}
        rows={sections}
        getRowKey={(row) => row.section}
        emptyMessage="No posted invoices in this period."
        caption="GSTR-1 summary by section"
      />

      <h2 className="mb-3 mt-6 text-sm font-semibold text-ink-900">By HSN</h2>
      <DataTable
        columns={hsnColumns}
        rows={hsn}
        getRowKey={(row) => row.hsnCode}
        emptyMessage="No posted invoices in this period."
        caption="GST summary by HSN"
      />
    </>
  );
}
