'use client';

import { CsvImport, type ImportColumn } from '@/components/forms/csv-import';
import {
  commitCustomerImportAction,
  previewCustomerImportAction,
} from '@/server/services/customers/customer-import-actions';
import type { CustomerImportRow } from '@/server/services/customers/customer-import';

/**
 * Customer bulk import (spec §11, §14).
 *
 * Only the columns worth scanning are shown in the preview. The file may carry
 * more — address, notes — but a preview is for spotting what is wrong, and a
 * table wide enough to need horizontal scrolling is one nobody reads.
 */
const COLUMNS: readonly ImportColumn<CustomerImportRow>[] = [
  { header: 'Code', mono: true, render: (r) => r.customer_code || 'auto' },
  { header: 'Name', render: (r) => r.name || '—' },
  { header: 'Mobile', mono: true, render: (r) => r.mobile || '—' },
  { header: 'Type', render: (r) => r.customer_type || '—' },
  { header: 'City', render: (r) => r.city || '—' },
  { header: 'GSTIN', mono: true, render: (r) => r.gstin || '—' },
];

export function CustomerImport({ template }: { readonly template: string }) {
  return (
    <CsvImport<CustomerImportRow>
      noun="customer"
      pluralNoun="customers"
      columnHelp={
        'Required: name, mobile. Optional: customer_code, customer_type, alternate_mobile, ' +
        'email, address_line1, address_line2, city, state, state_code, pincode, gstin, pan, notes.'
      }
      templateFilename="customer-import-template.csv"
      templateContent={template}
      columns={COLUMNS}
      onPreview={previewCustomerImportAction}
      onCommit={commitCustomerImportAction}
      doneHref="/customers"
      doneLabel="View customers"
      doneNote="Each one has a Customer ID and can take bookings, sales and service from now on."
    />
  );
}
