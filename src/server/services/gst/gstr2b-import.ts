import 'server-only';

import { parseAmount, parseCsv, parseStatementDate } from '@/lib/csv';

/**
 * GSTR-2B as a CSV — checklist §08. The portal's Excel is flattened to one row
 * per document; headers are matched loosely because the portal and every GSP
 * name them differently ("GSTIN of supplier", "Supplier GSTIN", …).
 */

export interface Gstr2bRow {
  readonly rowNumber: number;
  readonly errors: readonly string[];
  readonly supplier_gstin: string;
  readonly supplier_name: string;
  readonly document_type: string;
  readonly document_number: string;
  readonly document_date: string | null;
  readonly taxable_value: number;
  readonly igst: number;
  readonly cgst: number;
  readonly sgst: number;
  readonly cess: number;
  readonly itc_available: boolean;
  readonly reverse_charge: boolean;
}

export interface Gstr2bPreview {
  readonly rows: readonly Gstr2bRow[];
  readonly validCount: number;
  readonly errorCount: number;
  readonly headers: readonly string[];
}

const ALIASES: Record<keyof Omit<Gstr2bRow, 'rowNumber' | 'errors'>, readonly string[]> = {
  supplier_gstin: ['supplier_gstin', 'gstin_of_supplier', 'gstin', 'ctin'],
  supplier_name: ['supplier_name', 'trade_legal_name', 'trade_name', 'legal_name', 'name_of_supplier'],
  document_type: ['document_type', 'note_type', 'type'],
  document_number: ['document_number', 'invoice_number', 'note_number', 'invoice_no', 'inum'],
  document_date: ['document_date', 'invoice_date', 'note_date', 'idt'],
  taxable_value: ['taxable_value', 'taxable_value_rs', 'txval'],
  igst: ['igst', 'integrated_tax', 'integrated_tax_rs', 'iamt'],
  cgst: ['cgst', 'central_tax', 'central_tax_rs', 'camt'],
  sgst: ['sgst', 'state_ut_tax', 'state_ut_tax_rs', 'samt'],
  cess: ['cess', 'cess_rs', 'csamt'],
  itc_available: ['itc_available', 'itc_availability'],
  reverse_charge: ['reverse_charge', 'supply_attract_reverse_charge', 'rev'],
};

export const GSTR2B_TEMPLATE =
  'supplier_gstin,supplier_name,document_type,document_number,document_date,taxable_value,igst,cgst,sgst,cess,itc_available,reverse_charge\n' +
  '33AAAFA1111A1Z1,Alpha Traders,INVOICE,AT/STOCK/001,05/09/2026,500000,0,45000,45000,0,Yes,No\n';

const GSTIN = /^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z]Z[0-9A-Z]$/;

function yes(value: string | undefined, fallback: boolean): boolean {
  if (!value) return fallback;
  return /^(y|yes|true|1)$/i.test(value.trim());
}

export function parseGstr2b(csv: string): Gstr2bPreview {
  const { headers, rows } = parseCsv(csv);
  const pick = (row: Record<string, string>, key: keyof typeof ALIASES) =>
    ALIASES[key].map((a) => row[a]).find((v) => v !== undefined && v !== '') ?? '';

  const missing = (['supplier_gstin', 'document_number'] as const)
    .filter((key) => !ALIASES[key].some((a) => headers.includes(a)));
  if (missing.length > 0) {
    return {
      rows: [{
        rowNumber: 1, errors: [`The file is missing required columns: ${missing.join(', ')}.`],
        supplier_gstin: '', supplier_name: '', document_type: '', document_number: '', document_date: null,
        taxable_value: 0, igst: 0, cgst: 0, sgst: 0, cess: 0, itc_available: true, reverse_charge: false,
      }],
      validCount: 0, errorCount: 1, headers,
    };
  }

  const parsed = rows.map((row, index): Gstr2bRow => {
    const errors: string[] = [];
    const gstin = pick(row, 'supplier_gstin').toUpperCase();
    if (!GSTIN.test(gstin)) errors.push('supplier_gstin: not a valid GSTIN.');
    const number = pick(row, 'document_number');
    if (!number) errors.push('document_number: required.');
    const rawType = pick(row, 'document_type').toUpperCase();
    const type = rawType.startsWith('C') ? 'CREDIT_NOTE' : rawType.startsWith('D') ? 'DEBIT_NOTE' : 'INVOICE';
    const rawDate = pick(row, 'document_date');
    const date = parseStatementDate(rawDate);
    if (rawDate && !date) errors.push('document_date: not a date (use DD/MM/YYYY).');
    return {
      rowNumber: index + 2, errors,
      supplier_gstin: gstin, supplier_name: pick(row, 'supplier_name'), document_type: type,
      document_number: number, document_date: date,
      taxable_value: parseAmount(pick(row, 'taxable_value')), igst: parseAmount(pick(row, 'igst')),
      cgst: parseAmount(pick(row, 'cgst')), sgst: parseAmount(pick(row, 'sgst')), cess: parseAmount(pick(row, 'cess')),
      itc_available: yes(pick(row, 'itc_available'), true), reverse_charge: yes(pick(row, 'reverse_charge'), false),
    };
  });

  const errorCount = parsed.filter((r) => r.errors.length > 0).length;
  return { rows: parsed, validCount: parsed.length - errorCount, errorCount, headers };
}
