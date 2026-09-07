import 'server-only';

import { requirePermission } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { add, fromDb, type Paise } from '@/lib/money';

/**
 * The data behind a vehicle tax invoice — spec §20, §51; Rule 46 of the CGST
 * Rules.
 *
 * Separate from `getSale()` on purpose, and the differences are the point:
 *
 *   - `getSale()` answers "what is the state of this transaction" for someone
 *     working on it, and carries cost and margin for those allowed to see them.
 *     This answers "what does the customer's copy say", and never selects cost
 *     at all — there is no permission under which a purchase price belongs on a
 *     document handed to the buyer.
 *
 *   - It refuses anything that is not POSTED or DELIVERED. A tax invoice for a
 *     draft is a fabricated document; an invoice number exists on the row from
 *     creation, so nothing but this check stands between a half-finished sale
 *     and a printable invoice bearing a real serial number.
 *
 *   - It loads the fields Rule 46 makes mandatory and `getSale()` has no reason
 *     to: both parties' addresses and state codes, per-line HSN and tax rates,
 *     and the IRN block once an e-invoice has been registered.
 *
 * Place of supply decides CGST+SGST against IGST, and that decision was already
 * made and frozen when the sale posted. It is read back from the amounts rather
 * than recomputed here — the invoice must state what was charged, not what
 * today's configuration would charge.
 */

export interface InvoiceParty {
  readonly name: string;
  readonly addressLines: readonly string[];
  readonly city: string | null;
  readonly state: string | null;
  readonly stateCode: string | null;
  readonly pincode: string | null;
  readonly gstin: string | null;
  readonly pan: string | null;
  readonly phone: string | null;
}

export interface InvoiceLine {
  readonly lineNumber: number;
  readonly description: string;
  readonly hsnCode: string | null;
  readonly quantity: number;
  readonly unitRate: Paise;
  readonly discount: Paise;
  readonly taxableValue: Paise;
  readonly cgstRate: number;
  readonly sgstRate: number;
  readonly igstRate: number;
  readonly cgstAmount: Paise;
  readonly sgstAmount: Paise;
  readonly igstAmount: Paise;
  readonly totalAmount: Paise;
}

/** One row of the HSN-wise tax summary printed under the lines. */
export interface TaxSummaryRow {
  readonly hsnCode: string;
  readonly taxableValue: Paise;
  readonly cgstRate: number;
  readonly cgstAmount: Paise;
  readonly sgstRate: number;
  readonly sgstAmount: Paise;
  readonly igstRate: number;
  readonly igstAmount: Paise;
}

export interface EinvoiceBlock {
  readonly irn: string;
  readonly ackNumber: string | null;
  readonly ackDate: string | null;
  readonly signedQr: string | null;
}

export interface TaxInvoiceDocument {
  readonly invoiceNumber: string;
  readonly invoiceDate: string;
  readonly status: string;
  readonly supplier: InvoiceParty;
  readonly recipient: InvoiceParty;
  /** Recipient's state, or the supplier's when the buyer gave no address. */
  readonly placeOfSupply: string | null;
  readonly interState: boolean;
  readonly chassisNo: string;
  readonly engineNo: string;
  readonly modelLabel: string;
  readonly bookingNumber: string | null;
  readonly lines: readonly InvoiceLine[];
  readonly taxSummary: readonly TaxSummaryRow[];
  readonly taxableValue: Paise;
  readonly cgstAmount: Paise;
  readonly sgstAmount: Paise;
  readonly igstAmount: Paise;
  readonly totalAmount: Paise;
  readonly paidAmount: Paise;
  readonly financeAmount: Paise;
  readonly balanceAmount: Paise;
  readonly einvoice: EinvoiceBlock | null;
}

/** Statuses that have a real invoice behind them. */
const PRINTABLE = new Set(['POSTED', 'DELIVERED']);

export async function getTaxInvoiceDocument(
  saleId: string,
): Promise<TaxInvoiceDocument | null> {
  await requirePermission('sales.view');
  const supabase = await createSupabaseServerClient();

  const { data: sale, error } = await supabase
    .from('sales')
    .select(
      `id, invoice_number, invoice_date, status,
       taxable_value, cgst_amount, sgst_amount, igst_amount, total_amount,
       paid_amount, finance_amount,
       dealers ( legal_name, trade_name, gstin, pan, address_line1, address_line2,
                 city, state, state_code, pincode, phone ),
       branches ( name, gstin, address_line1, address_line2,
                  city, state, state_code, pincode, phone ),
       customers ( name, mobile, gstin, pan, address_line1, address_line2,
                   city, state, state_code, pincode ),
       vehicles ( chassis_no, engine_no, vehicle_models ( brand, name ) ),
       bookings ( booking_number )`,
    )
    .eq('id', saleId)
    .maybeSingle();

  if (error) {
    throw new Error(`Failed to load the invoice: ${error.message}`);
  }
  if (!sale) {
    return null;
  }

  // RLS already scoped the row to this tenant. This is the business gate: an
  // invoice number without a posted journal behind it is not an invoice.
  if (!PRINTABLE.has(sale.status)) {
    return null;
  }

  const { data: lineRows } = await supabase
    .from('sale_lines')
    .select(
      `line_number, description, hsn_code, quantity, unit_rate, discount,
       taxable_value, cgst_rate, sgst_rate, igst_rate,
       cgst_amount, sgst_amount, igst_amount, total_amount`,
    )
    .eq('sale_id', saleId)
    .order('line_number');

  // An e-invoice may not exist, may be pending, or may have failed. Only a
  // GENERATED one prints — an IRN block on an unregistered invoice would claim
  // a registration that never happened.
  const { data: einvoiceRow } = await supabase
    .from('einvoices')
    .select('irn, ack_number, ack_date, signed_qr_code, status')
    .eq('document_id', saleId)
    .eq('status', 'GENERATED')
    .maybeSingle();

  const dealer = sale.dealers;
  const branch = sale.branches;
  const customer = sale.customers;

  const lines: InvoiceLine[] = (lineRows ?? []).map((row) => ({
    lineNumber: row.line_number,
    description: row.description,
    hsnCode: row.hsn_code,
    quantity: Number(row.quantity),
    unitRate: fromDb(row.unit_rate),
    discount: fromDb(row.discount),
    taxableValue: fromDb(row.taxable_value),
    cgstRate: Number(row.cgst_rate),
    sgstRate: Number(row.sgst_rate),
    igstRate: Number(row.igst_rate),
    cgstAmount: fromDb(row.cgst_amount),
    sgstAmount: fromDb(row.sgst_amount),
    igstAmount: fromDb(row.igst_amount),
    totalAmount: fromDb(row.total_amount),
  }));

  const totalAmount = fromDb(sale.total_amount);
  const paidAmount = fromDb(sale.paid_amount);
  const financeAmount = fromDb(sale.finance_amount);

  const model = sale.vehicles?.vehicle_models;

  return {
    invoiceNumber: sale.invoice_number,
    invoiceDate: sale.invoice_date,
    status: sale.status,

    supplier: {
      // The branch trades under the dealer's legal name; the address is the
      // branch's own, because that is the place of business the GSTIN belongs to.
      name: dealer?.trade_name ?? dealer?.legal_name ?? '',
      addressLines: addressLines(
        branch?.address_line1 ?? dealer?.address_line1 ?? null,
        branch?.address_line2 ?? dealer?.address_line2 ?? null,
        branch?.name ?? null,
      ),
      city: branch?.city ?? dealer?.city ?? null,
      state: branch?.state ?? dealer?.state ?? null,
      stateCode: branch?.state_code ?? dealer?.state_code ?? null,
      pincode: branch?.pincode ?? dealer?.pincode ?? null,
      gstin: branch?.gstin ?? dealer?.gstin ?? null,
      pan: dealer?.pan ?? null,
      phone: branch?.phone ?? dealer?.phone ?? null,
    },

    recipient: {
      name: customer?.name ?? '',
      addressLines: addressLines(
        customer?.address_line1 ?? null,
        customer?.address_line2 ?? null,
        null,
      ),
      city: customer?.city ?? null,
      state: customer?.state ?? null,
      stateCode: customer?.state_code ?? null,
      pincode: customer?.pincode ?? null,
      gstin: customer?.gstin ?? null,
      pan: customer?.pan ?? null,
      phone: customer?.mobile ?? null,
    },

    placeOfSupply: customer?.state ?? branch?.state ?? dealer?.state ?? null,
    // Read from what was charged, not recomputed. The two agree on a correct
    // invoice, and where they would not, the charged figure is the true one.
    interState: fromDb(sale.igst_amount) > 0,

    chassisNo: sale.vehicles?.chassis_no ?? '',
    engineNo: sale.vehicles?.engine_no ?? '',
    modelLabel: model ? `${model.brand} ${model.name}` : '',
    bookingNumber: sale.bookings?.booking_number ?? null,

    lines,
    taxSummary: summariseByHsn(lines),

    taxableValue: fromDb(sale.taxable_value),
    cgstAmount: fromDb(sale.cgst_amount),
    sgstAmount: fromDb(sale.sgst_amount),
    igstAmount: fromDb(sale.igst_amount),
    totalAmount,
    paidAmount,
    financeAmount,
    balanceAmount: (totalAmount - paidAmount - financeAmount) as Paise,

    einvoice: einvoiceRow?.irn
      ? {
          irn: einvoiceRow.irn,
          ackNumber: einvoiceRow.ack_number,
          ackDate: einvoiceRow.ack_date,
          signedQr: einvoiceRow.signed_qr_code,
        }
      : null,
  };
}

/** Drops the blanks so a missing second line does not print an empty row. */
function addressLines(
  line1: string | null,
  line2: string | null,
  suffix: string | null,
): readonly string[] {
  return [line1, line2, suffix].filter((line): line is string => Boolean(line?.trim()));
}

/**
 * The HSN-wise summary that sits under the line table.
 *
 * Grouped by HSN *and rate together*: the same HSN can legitimately appear at
 * two rates across a financial year, and collapsing those into one row would
 * print a rate that applies to only part of the value beside it.
 */
function summariseByHsn(lines: readonly InvoiceLine[]): readonly TaxSummaryRow[] {
  const groups = new Map<string, TaxSummaryRow>();

  for (const line of lines) {
    const hsn = line.hsnCode ?? '—';
    const key = `${hsn}|${line.cgstRate}|${line.sgstRate}|${line.igstRate}`;
    const existing = groups.get(key);

    if (existing) {
      groups.set(key, {
        ...existing,
        taxableValue: add(existing.taxableValue, line.taxableValue),
        cgstAmount: add(existing.cgstAmount, line.cgstAmount),
        sgstAmount: add(existing.sgstAmount, line.sgstAmount),
        igstAmount: add(existing.igstAmount, line.igstAmount),
      });
    } else {
      groups.set(key, {
        hsnCode: hsn,
        taxableValue: line.taxableValue,
        cgstRate: line.cgstRate,
        cgstAmount: line.cgstAmount,
        sgstRate: line.sgstRate,
        sgstAmount: line.sgstAmount,
        igstRate: line.igstRate,
        igstAmount: line.igstAmount,
      });
    }
  }

  return [...groups.values()].sort((a, b) => a.hsnCode.localeCompare(b.hsnCode));
}
