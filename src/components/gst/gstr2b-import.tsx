'use client';

import { CsvImport, type ImportColumn } from '@/components/forms/csv-import';
import { importGstr2bAction, previewGstr2bAction } from '@/server/services/gst/gst-returns-actions';
import type { Gstr2bRow } from '@/server/services/gst/gstr2b-import';

const COLUMNS: readonly ImportColumn<Gstr2bRow>[] = [
  { header: 'Supplier GSTIN', mono: true, render: (r) => r.supplier_gstin || '—' },
  { header: 'Supplier', render: (r) => r.supplier_name || '—' },
  { header: 'Type', render: (r) => r.document_type },
  { header: 'Document', mono: true, render: (r) => r.document_number || '—' },
  { header: 'Date', render: (r) => r.document_date ?? '—' },
  { header: 'Taxable', numeric: true, render: (r) => r.taxable_value.toFixed(2) },
  { header: 'Tax', numeric: true, render: (r) => (r.igst + r.cgst + r.sgst).toFixed(2) },
  { header: 'ITC', render: (r) => (r.itc_available ? 'Yes' : 'No') },
];

/** Imports one month's GSTR-2B for one GSTIN; a re-import replaces the last one. */
export function Gstr2bImport({
  gstin,
  period,
  template,
}: {
  readonly gstin: string;
  readonly period: string;
  readonly template: string;
}) {
  return (
    <CsvImport<Gstr2bRow>
      noun="2B line"
      pluralNoun="2B lines"
      columnHelp={
        'Required: supplier_gstin, document_number. Optional: supplier_name, document_type ' +
        '(INVOICE / CREDIT_NOTE / DEBIT_NOTE), document_date, taxable_value, igst, cgst, sgst, cess, ' +
        'itc_available (Yes/No), reverse_charge (Yes/No). The portal’s own column names are accepted too.'
      }
      templateFilename="gstr2b-template.csv"
      templateContent={template}
      columns={COLUMNS}
      onPreview={previewGstr2bAction}
      onCommit={(csv) => importGstr2bAction(gstin, period, `GSTR-2B ${period}`, csv)}
      doneHref={`/gst/gstr-2b?gstin=${gstin}&period=${period.slice(0, 7)}`}
      doneLabel="See the matching"
      doneNote="Every line is matched to your purchase bills; the credit that can be claimed follows from it."
    />
  );
}
