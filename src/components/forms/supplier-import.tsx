'use client';

import { CsvImport, type ImportColumn } from '@/components/forms/csv-import';
import {
  commitSupplierImportAction,
  previewSupplierImportAction,
} from '@/server/services/masters/supplier-import-actions';
import type { SupplierImportRow } from '@/server/services/masters/supplier-import';

const COLUMNS: readonly ImportColumn<SupplierImportRow>[] = [
  { header: 'Code', mono: true, render: (r) => r.supplier_code || 'auto' },
  { header: 'Name', render: (r) => r.name || '—' },
  { header: 'Type', render: (r) => r.supplier_type || '—' },
  { header: 'Contact', render: (r) => r.contact_person || '—' },
  { header: 'Mobile', mono: true, render: (r) => r.mobile || '—' },
  { header: 'GSTIN', mono: true, render: (r) => r.gstin || '—' },
  { header: 'Credit days', numeric: true, render: (r) => r.credit_days || '0' },
];

export function SupplierImport({ template }: { readonly template: string }) {
  return (
    <CsvImport<SupplierImportRow>
      noun="supplier"
      pluralNoun="suppliers"
      columnHelp={
        'Required: name. Optional: supplier_code, supplier_type (GOODS/SERVICE/OEM), ' +
        'contact_person, mobile, email, address_line1, city, state, state_code, pincode, ' +
        'gstin, pan, credit_days, notes.'
      }
      templateFilename="supplier-import-template.csv"
      templateContent={template}
      columns={COLUMNS}
      onPreview={previewSupplierImportAction}
      onCommit={commitSupplierImportAction}
      doneHref="/masters/suppliers"
      doneLabel="View suppliers"
      doneNote="Each one can now take purchase bills, payments and a payable ledger."
    />
  );
}
