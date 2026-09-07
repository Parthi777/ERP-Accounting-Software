import 'server-only';

import PDFDocument from 'pdfkit';

import { loadFonts } from '@/server/export/pdf';
import { amountInWords } from '@/lib/words';
import { toRupees, type Paise } from '@/lib/money';
import type {
  InvoiceLine,
  InvoiceParty,
  TaxInvoiceDocument,
} from '@/server/services/sales/invoice-document-service';

/**
 * The customer's copy of a vehicle tax invoice — spec §20, §51.
 *
 * This is not a report. The report renderer in `export/pdf.ts` draws a table
 * from a column definition and knows nothing about what the rows mean; an
 * invoice is a fixed legal form whose blocks appear in a prescribed order,
 * carry prescribed labels, and must all be present. Rule 46 of the CGST Rules
 * lists what "present" means, and the layout below is that list in the order a
 * reader expects it:
 *
 *     TAX INVOICE heading and the dealer's identity
 *     invoice number and date            Rule 46(a), (c)
 *     supplier name, address, GSTIN      Rule 46(b)
 *     recipient name, address, GSTIN     Rule 46(e), (f)
 *     place of supply                    Rule 46(n)
 *     description, HSN, quantity, value  Rule 46(g)–(j)
 *     rate and amount of tax per head    Rule 46(k)–(m)
 *     total in words
 *     IRN and acknowledgement, if registered
 *     signature block                    Rule 46(q)
 *
 * Two deliberate choices. The chassis and engine numbers get their own block
 * rather than being folded into the line description, because for a vehicle
 * they are what identifies the goods — a registering authority reads them off
 * this document. And amounts print with `formatAmount` below rather than
 * `formatINR`, because pdfkit falls back to Helvetica when the embedded font is
 * unreadable and Helvetica has no ₹ glyph; the fallback prints `INR` instead of
 * an empty box, which is ugly and legible rather than tidy and wrong.
 */

const MARGIN = 36;
const INK = '#0f172a';
const MUTED = '#64748b';
const RULE = '#94a3b8';
const HAIRLINE = '#cbd5e1';
const BAND = '#f1f5f9';

export interface RenderedDocument {
  readonly body: Buffer;
  readonly contentType: string;
  readonly filename: string;
}

export async function renderTaxInvoice(
  invoice: TaxInvoiceDocument,
  generatedAt: Date,
): Promise<RenderedDocument> {
  const fonts = loadFonts();

  const doc = new PDFDocument({
    size: 'A4',
    layout: 'portrait',
    margin: MARGIN,
    bufferPages: true,
    info: {
      Title: `Tax Invoice ${invoice.invoiceNumber}`,
      Author: invoice.supplier.name,
      Creator: 'Two-Wheeler Dealer ERP',
      CreationDate: generatedAt,
    },
  });

  doc.registerFont('body', fonts.regular);
  doc.registerFont('bold', fonts.bold);

  const chunks: Buffer[] = [];
  doc.on('data', (chunk: Buffer) => chunks.push(chunk));
  const finished = new Promise<void>((resolve) => doc.on('end', () => resolve()));

  const left = MARGIN;
  const right = doc.page.width - MARGIN;
  const width = right - left;
  const money = (value: Paise) => formatAmount(value, fonts.hasRupeeGlyph);

  let y = MARGIN;

  // ── Heading ───────────────────────────────────────────────────────────────
  doc.font('bold').fontSize(15).fillColor(INK)
    .text('TAX INVOICE', left, y, { width, align: 'center' });
  y = doc.y + 3;

  doc.font('body').fontSize(7.5).fillColor(MUTED)
    .text('Original for Recipient  ·  Duplicate for Transporter  ·  Triplicate for Supplier', left, y, {
      width,
      align: 'center',
    });
  y = doc.y + 10;

  doc.moveTo(left, y).lineTo(right, y).lineWidth(1).strokeColor(RULE).stroke();
  y += 12;

  // ── Supplier identity ─────────────────────────────────────────────────────
  doc.font('bold').fontSize(13).fillColor(INK).text(invoice.supplier.name, left, y);
  y = doc.y + 2;
  y = partyBlock(doc, invoice.supplier, left, y, width * 0.62);
  y += 8;

  // ── Invoice number / date / place of supply ───────────────────────────────
  const metaTop = y;
  const metaCells: readonly (readonly [string, string])[] = [
    ['Invoice No.', invoice.invoiceNumber],
    ['Invoice Date', formatDate(invoice.invoiceDate)],
    ['Place of Supply', placeOfSupply(invoice)],
    ['Supply Type', invoice.interState ? 'Inter-State (IGST)' : 'Intra-State (CGST + SGST)'],
  ];

  doc.rect(left, metaTop, width, 34).fillColor(BAND).fill();
  const metaWidth = width / metaCells.length;
  metaCells.forEach(([label, value], index) => {
    const x = left + index * metaWidth + 8;
    doc.font('body').fontSize(6.8).fillColor(MUTED)
      .text(label.toUpperCase(), x, metaTop + 6, { width: metaWidth - 16 });
    doc.font('bold').fontSize(9).fillColor(INK)
      .text(value, x, metaTop + 16, { width: metaWidth - 16, lineBreak: false });
  });
  y = metaTop + 34 + 12;

  // ── Recipient ─────────────────────────────────────────────────────────────
  doc.font('bold').fontSize(7.5).fillColor(MUTED).text('BILL TO', left, y);
  y = doc.y + 3;
  doc.font('bold').fontSize(11).fillColor(INK).text(invoice.recipient.name, left, y);
  y = doc.y + 2;
  y = partyBlock(doc, invoice.recipient, left, y, width * 0.62);
  y += 12;

  // ── The goods ─────────────────────────────────────────────────────────────
  // Chassis and engine identify a vehicle the way a serial number never could
  // for ordinary goods; the RTO reads them from this page.
  const vehicleTop = y;
  doc.rect(left, vehicleTop, width, 30).lineWidth(0.6).strokeColor(HAIRLINE).stroke();
  const vehicleCells: readonly (readonly [string, string])[] = [
    ['Model', invoice.modelLabel],
    ['Chassis No.', invoice.chassisNo],
    ['Engine No.', invoice.engineNo],
    ...(invoice.bookingNumber ? ([['Booking Ref.', invoice.bookingNumber]] as const) : []),
  ];
  const vehicleWidth = width / vehicleCells.length;
  vehicleCells.forEach(([label, value], index) => {
    const x = left + index * vehicleWidth + 8;
    doc.font('body').fontSize(6.8).fillColor(MUTED)
      .text(label.toUpperCase(), x, vehicleTop + 5, { width: vehicleWidth - 16 });
    doc.font('bold').fontSize(9).fillColor(INK)
      .text(value || '—', x, vehicleTop + 15, { width: vehicleWidth - 16, lineBreak: false });
  });
  y = vehicleTop + 30 + 12;

  // ── Line table ────────────────────────────────────────────────────────────
  const cols = lineColumns(width, invoice.interState);

  y = tableHeader(doc, cols, left, y);

  for (const line of invoice.lines) {
    // A page break mid-invoice repeats the header so the second page's columns
    // are still labelled.
    if (y > doc.page.height - MARGIN - 150) {
      doc.addPage();
      y = MARGIN;
      y = tableHeader(doc, cols, left, y);
    }
    y = lineRow(doc, cols, line, left, y, money, invoice.interState);
  }

  doc.moveTo(left, y).lineTo(right, y).lineWidth(0.8).strokeColor(RULE).stroke();
  y += 10;

  // ── Totals, right-aligned under the table ─────────────────────────────────
  const totalsWidth = 220;
  const totalsLeft = right - totalsWidth;

  const totals: readonly (readonly [string, string, boolean])[] = [
    ['Taxable Value', money(invoice.taxableValue), false],
    ...(invoice.interState
      ? ([['IGST', money(invoice.igstAmount), false]] as const)
      : ([
          ['CGST', money(invoice.cgstAmount), false],
          ['SGST', money(invoice.sgstAmount), false],
        ] as const)),
    ['Invoice Total', money(invoice.totalAmount), true],
  ];

  for (const [label, value, emphasis] of totals) {
    if (emphasis) {
      doc.moveTo(totalsLeft, y - 2).lineTo(right, y - 2)
        .lineWidth(0.8).strokeColor(RULE).stroke();
      y += 4;
    }
    doc.font(emphasis ? 'bold' : 'body').fontSize(emphasis ? 10.5 : 9).fillColor(INK)
      .text(label, totalsLeft, y, { width: totalsWidth - 100 });
    doc.font('bold').fontSize(emphasis ? 10.5 : 9).fillColor(INK)
      .text(value, right - 100, y, { width: 100, align: 'right' });
    y += emphasis ? 16 : 13;
  }

  y += 4;
  doc.font('body').fontSize(8).fillColor(MUTED).text('Amount in words', left, y);
  y = doc.y + 1;
  doc.font('bold').fontSize(9).fillColor(INK)
    .text(amountInWords(invoice.totalAmount), left, y, { width: width - totalsWidth - 20 });
  y = Math.max(doc.y, y) + 12;

  // ── Settlement ────────────────────────────────────────────────────────────
  // What the customer paid, what the financier is paying, what remains. The
  // dealer is asked this at the counter more often than anything else on the page.
  const settlement: readonly (readonly [string, Paise])[] = [
    ['Received', invoice.paidAmount],
    ['Financed', invoice.financeAmount],
    ['Balance Due', invoice.balanceAmount],
  ];
  const settleWidth = width / 3;
  const settleTop = y;
  doc.rect(left, settleTop, width, 26).fillColor(BAND).fill();
  settlement.forEach(([label, value], index) => {
    const x = left + index * settleWidth + 8;
    doc.font('body').fontSize(6.8).fillColor(MUTED)
      .text(label.toUpperCase(), x, settleTop + 5, { width: settleWidth - 16 });
    doc.font('bold').fontSize(9).fillColor(INK)
      .text(money(value), x, settleTop + 14, { width: settleWidth - 16, lineBreak: false });
  });
  y = settleTop + 26 + 12;

  // ── HSN summary ───────────────────────────────────────────────────────────
  if (invoice.taxSummary.length > 0) {
    y = hsnSummary(doc, invoice, left, width, y, money);
  }

  // ── E-invoice registration ────────────────────────────────────────────────
  if (invoice.einvoice) {
    doc.font('body').fontSize(6.8).fillColor(MUTED).text('E-INVOICE', left, y);
    y = doc.y + 2;
    doc.font('body').fontSize(7.5).fillColor(INK)
      .text(`IRN  ${invoice.einvoice.irn}`, left, y, { width: width - 180 });
    y = doc.y + 1;
    if (invoice.einvoice.ackNumber) {
      doc.text(
        `Ack No.  ${invoice.einvoice.ackNumber}` +
          (invoice.einvoice.ackDate ? `    Ack Date  ${formatDate(invoice.einvoice.ackDate)}` : ''),
        left,
        y,
      );
      y = doc.y;
    }
    y += 10;
  }

  // ── Signature ─────────────────────────────────────────────────────────────
  const signTop = Math.max(y, doc.page.height - MARGIN - 70);
  doc.font('body').fontSize(7.5).fillColor(MUTED)
    .text(
      'Certified that the particulars given above are true and correct, and that the ' +
        'goods described have been supplied at the value stated.',
      left,
      signTop,
      { width: width * 0.55 },
    );

  doc.font('body').fontSize(8).fillColor(MUTED)
    .text(`For ${invoice.supplier.name}`, right - 190, signTop, { width: 190, align: 'right' });
  doc.font('body').fontSize(7.5)
    .text('Authorised Signatory', right - 190, signTop + 44, { width: 190, align: 'right' });
  doc.moveTo(right - 170, signTop + 40).lineTo(right, signTop + 40)
    .lineWidth(0.6).strokeColor(HAIRLINE).stroke();

  doc.end();
  await finished;

  return {
    body: Buffer.concat(chunks),
    contentType: 'application/pdf',
    filename: `Tax-Invoice-${invoice.invoiceNumber.replace(/[^\w.-]+/g, '-')}.pdf`,
  };
}

// ───────────────────────────────────────────────────────────────────────────

type Doc = InstanceType<typeof PDFDocument>;

interface Column {
  readonly key: string;
  readonly header: string;
  readonly x: number;
  readonly width: number;
  readonly align: 'left' | 'right';
}

/**
 * Column geometry.
 *
 * Intra-state invoices need two tax pairs (CGST, SGST) where inter-state needs
 * one (IGST), so the table is genuinely a different shape rather than one shape
 * with blank columns — blank tax columns on an invoice invite the reader to
 * wonder what was left out.
 */
function lineColumns(width: number, interState: boolean): readonly Column[] {
  const shares: readonly (readonly [string, string, number, 'left' | 'right'])[] = interState
    ? [
        ['sn', '#', 0.04, 'left'],
        ['description', 'Description', 0.30, 'left'],
        ['hsn', 'HSN', 0.11, 'left'],
        ['qty', 'Qty', 0.06, 'right'],
        ['rate', 'Rate', 0.13, 'right'],
        ['taxable', 'Taxable', 0.14, 'right'],
        ['igst', 'IGST', 0.11, 'right'],
        ['total', 'Total', 0.11, 'right'],
      ]
    : [
        ['sn', '#', 0.04, 'left'],
        ['description', 'Description', 0.25, 'left'],
        ['hsn', 'HSN', 0.11, 'left'],
        ['qty', 'Qty', 0.05, 'right'],
        ['rate', 'Rate', 0.12, 'right'],
        ['taxable', 'Taxable', 0.13, 'right'],
        ['cgst', 'CGST', 0.10, 'right'],
        ['sgst', 'SGST', 0.10, 'right'],
        ['total', 'Total', 0.10, 'right'],
      ];

  let x = 0;
  // A full HSN is eight digits and a SAC six; both must sit on one line, so the
  // shares above are set from that width rather than from what looks balanced.
  return shares.map(([key, header, share, align]) => {
    const columnWidth = width * share;
    const column: Column = { key, header, x, width: columnWidth, align };
    x += columnWidth;
    return column;
  });
}

function tableHeader(doc: Doc, cols: readonly Column[], left: number, y: number): number {
  const height = 18;
  const total = cols.reduce((sum, column) => sum + column.width, 0);

  doc.rect(left, y, total, height).fillColor(BAND).fill();
  doc.font('bold').fontSize(7.5).fillColor(MUTED);

  for (const column of cols) {
    doc.text(column.header.toUpperCase(), left + column.x + 4, y + 5.5, {
      width: column.width - 8,
      align: column.align,
      lineBreak: false,
    });
  }

  const bottom = y + height;
  doc.moveTo(left, bottom).lineTo(left + total, bottom)
    .lineWidth(0.8).strokeColor(RULE).stroke();
  return bottom + 5;
}

function lineRow(
  doc: Doc,
  cols: readonly Column[],
  line: InvoiceLine,
  left: number,
  y: number,
  money: (value: Paise) => string,
  interState: boolean,
): number {
  const descriptionColumn = cols.find((column) => column.key === 'description')!;

  // Measure first: a long accessory description wraps, and every other cell in
  // the row has to sit on the same top edge and the rule below the tallest one.
  doc.font('body').fontSize(8.5);
  const descriptionHeight = doc.heightOfString(line.description, {
    width: descriptionColumn.width - 8,
  });
  const height = Math.max(descriptionHeight, 11);

  const values: Record<string, string> = {
    sn: String(line.lineNumber),
    description: line.description,
    hsn: line.hsnCode ?? '—',
    qty: formatQuantity(line.quantity),
    rate: money(line.unitRate),
    taxable: money(line.taxableValue),
    total: money(line.totalAmount),
    ...(interState
      ? { igst: `${money(line.igstAmount)}\n${formatRate(line.igstRate)}` }
      : {
          cgst: `${money(line.cgstAmount)}\n${formatRate(line.cgstRate)}`,
          sgst: `${money(line.sgstAmount)}\n${formatRate(line.sgstRate)}`,
        }),
  };

  doc.fillColor(INK);
  for (const column of cols) {
    const value = values[column.key] ?? '';
    // The tax cells carry the rate under the amount, so they are two lines and
    // must be allowed to wrap; everything else is one line and must not.
    const twoLine = value.includes('\n');
    doc.font('body').fontSize(twoLine ? 7.5 : 8.5);
    doc.text(value, left + column.x + 4, y, {
      width: column.width - 8,
      align: column.align,
      lineBreak: twoLine || column.key === 'description',
    });
  }

  const bottom = y + height + 5;
  doc.moveTo(left, bottom - 2.5).lineTo(left + cols.reduce((s, c) => s + c.width, 0), bottom - 2.5)
    .lineWidth(0.4).strokeColor(HAIRLINE).stroke();
  return bottom;
}

function hsnSummary(
  doc: Doc,
  invoice: TaxInvoiceDocument,
  left: number,
  width: number,
  y: number,
  money: (value: Paise) => string,
): number {
  doc.font('body').fontSize(6.8).fillColor(MUTED).text('TAX SUMMARY BY HSN', left, y);
  y = doc.y + 3;

  const headers = invoice.interState
    ? ['HSN', 'Taxable Value', 'IGST Rate', 'IGST Amount']
    : ['HSN', 'Taxable Value', 'CGST Rate', 'CGST Amount', 'SGST Rate', 'SGST Amount'];

  const cellWidth = width / headers.length;

  doc.font('bold').fontSize(7).fillColor(MUTED);
  headers.forEach((header, index) => {
    doc.text(header.toUpperCase(), left + index * cellWidth + 4, y, {
      width: cellWidth - 8,
      align: index === 0 ? 'left' : 'right',
      lineBreak: false,
    });
  });
  y = doc.y + 3;
  doc.moveTo(left, y).lineTo(left + width, y).lineWidth(0.5).strokeColor(HAIRLINE).stroke();
  y += 4;

  for (const row of invoice.taxSummary) {
    const cells = invoice.interState
      ? [row.hsnCode, money(row.taxableValue), formatRate(row.igstRate), money(row.igstAmount)]
      : [
          row.hsnCode,
          money(row.taxableValue),
          formatRate(row.cgstRate),
          money(row.cgstAmount),
          formatRate(row.sgstRate),
          money(row.sgstAmount),
        ];

    doc.font('body').fontSize(8).fillColor(INK);
    cells.forEach((cell, index) => {
      doc.text(cell, left + index * cellWidth + 4, y, {
        width: cellWidth - 8,
        align: index === 0 ? 'left' : 'right',
        lineBreak: false,
      });
    });
    y += 12;
  }

  return y + 8;
}

/** Address, GSTIN and PAN under a party's name. */
function partyBlock(
  doc: Doc,
  party: InvoiceParty,
  left: number,
  y: number,
  width: number,
): number {
  const locality = [party.city, party.state, party.pincode].filter(Boolean).join(', ');
  const lines = [
    ...party.addressLines,
    locality || null,
    party.phone ? `Phone  ${party.phone}` : null,
  ].filter((line): line is string => Boolean(line));

  doc.font('body').fontSize(8.5).fillColor(MUTED);
  for (const line of lines) {
    doc.text(line, left, y, { width });
    y = doc.y;
  }

  // GSTIN is the one identifier that must be unmissable on both sides of the
  // invoice, so it is set in the ink colour rather than the muted grey.
  const identifiers = [
    party.gstin ? `GSTIN  ${party.gstin}` : 'GSTIN  Unregistered',
    party.pan ? `PAN  ${party.pan}` : null,
    party.stateCode ? `State Code  ${party.stateCode}` : null,
  ].filter(Boolean);

  doc.font('bold').fontSize(8.5).fillColor(INK)
    .text(identifiers.join('     '), left, y + 1, { width });

  return doc.y;
}

function placeOfSupply(invoice: TaxInvoiceDocument): string {
  if (!invoice.placeOfSupply) return '—';
  const code = invoice.recipient.stateCode ?? invoice.supplier.stateCode;
  return code ? `${invoice.placeOfSupply} (${code})` : invoice.placeOfSupply;
}

/**
 * Rupees with Indian grouping.
 *
 * `formatINR` in lib/money is the browser's formatter and emits ₹, which the
 * Helvetica fallback cannot draw. This spells the symbol out instead when the
 * embedded font is missing, so an invoice generated on a misconfigured
 * deployment is still readable and still unambiguous about its currency.
 */
function formatAmount(value: Paise, hasRupeeGlyph: boolean): string {
  const rupees = toRupees(value);
  const formatted = new Intl.NumberFormat('en-IN', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(rupees);
  return hasRupeeGlyph ? `₹${formatted}` : `INR ${formatted}`;
}

/** Trailing zeros dropped: "1" not "1.000", but "1.500" stays "1.5". */
function formatQuantity(quantity: number): string {
  return Number.isInteger(quantity) ? String(quantity) : String(Number(quantity.toFixed(3)));
}

function formatRate(rate: number): string {
  return `${Number(rate.toFixed(2))}%`;
}

function formatDate(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat('en-IN', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
  }).format(date);
}
