import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';

import PDFDocument from 'pdfkit';

import type { TenantContext } from '@/server/auth/tenant-context';

import type { AnyExportReport, ExportColumn, ExportData, RenderedExport } from './types';
import { facts, filenameStem, truncationNotice } from './excel';
import { isNumeric, printedTotal, toPrintedValue, totalsFor } from './values';

/**
 * PDF export.
 *
 * Built with pdfkit rather than by printing a page in a headless browser: a
 * browser is three hundred megabytes of Chromium in the Railway image to lay out
 * a table, and it fails in ways that are hard to see from a server log. This is
 * more code, but it is deterministic and it renders identically wherever it runs.
 *
 * The layout is the ordinary one for a financial statement — a title block, a
 * ruled table with a header that repeats on every page, a totals row, and a
 * footer carrying the page number and who generated it. Landscape for wide
 * reports, which the registry decides per report.
 *
 * ── On the font ──
 * pdfkit's built-in fonts are the PDF base fourteen, which are WinAnsi-encoded
 * and have no ₹ (U+20B9). Every amount in this application is rupees, so the
 * built-ins are unusable and DejaVu Sans Condensed is embedded instead — it
 * carries the glyph, and Condensed fits more columns across a page than any
 * normal-width face. If the file cannot be read for any reason we fall back to
 * Helvetica and switch the amount format to `INR`, so an export still succeeds
 * with a legible number rather than failing or printing a black box.
 */

const PAGE_MARGIN = 32;
const FONT_DIR = 'src/server/export/fonts';
const REGULAR = 'DejaVuSansCondensed.ttf';
const BOLD = 'DejaVuSansCondensed-Bold.ttf';

const INK = '#1e293b';
const MUTED = '#64748b';
const RULE = '#cbd5e1';
const HEADER_BG = '#eff4fe';
const STRIPE = '#f8fafc';
const WARN_BG = '#fef3c7';
const WARN_INK = '#92400e';

interface Fonts {
  readonly regular: Buffer | 'Helvetica';
  readonly bold: Buffer | 'Helvetica-Bold';
  /** False when we fell back, so amounts print as `INR` rather than a tofu box. */
  readonly hasRupeeGlyph: boolean;
}

let cachedFonts: Fonts | null = null;

/**
 * Locates the embedded fonts.
 *
 * Two candidate roots because the app runs two ways: from the project directory
 * in development, and from `.next/standalone` on Railway, where Next copies
 * traced files preserving their paths. next.config names this directory in
 * `outputFileTracingIncludes` so the copy actually happens.
 */
function loadFonts(): Fonts {
  if (cachedFonts) return cachedFonts;

  const roots = [process.cwd(), path.join(process.cwd(), '..', '..')];

  // createRequire lets us also find the directory relative to this module when
  // the working directory is something unexpected.
  try {
    const require = createRequire(import.meta.url);
    const here = path.dirname(require.resolve('./types.ts'));
    roots.push(path.join(here, '..', '..', '..'));
  } catch {
    // Resolution is a convenience; the cwd candidates are the real path.
  }

  for (const root of roots) {
    const dir = path.join(root, FONT_DIR);
    try {
      const regular = fs.readFileSync(path.join(dir, REGULAR));
      const bold = fs.readFileSync(path.join(dir, BOLD));
      cachedFonts = { regular, bold, hasRupeeGlyph: true };
      return cachedFonts;
    } catch {
      // Try the next candidate root.
    }
  }

  console.warn('[export] embedded PDF font not found; falling back to Helvetica with INR amounts');
  cachedFonts = { regular: 'Helvetica', bold: 'Helvetica-Bold', hasRupeeGlyph: false };
  return cachedFonts;
}

export async function renderPdf(
  report: AnyExportReport,
  data: ExportData<unknown>,
  context: TenantContext,
  generatedAt: Date,
): Promise<RenderedExport> {
  const columns = report.columns(context);
  const fonts = loadFonts();
  const landscape = report.orientation === 'landscape';

  const doc = new PDFDocument({
    size: 'A4',
    layout: landscape ? 'landscape' : 'portrait',
    margin: PAGE_MARGIN,
    bufferPages: true, // page numbers need the total, known only at the end
    info: {
      Title: report.title,
      Author: context.fullName || context.email,
      Creator: context.dealerName ?? 'Two-Wheeler Dealer ERP',
      CreationDate: generatedAt,
    },
  });

  doc.registerFont('body', fonts.regular);
  doc.registerFont('bold', fonts.bold);

  const chunks: Buffer[] = [];
  doc.on('data', (chunk: Buffer) => chunks.push(chunk));
  const finished = new Promise<void>((resolve) => doc.on('end', () => resolve()));

  const left = PAGE_MARGIN;
  const right = doc.page.width - PAGE_MARGIN;
  const available = right - left;

  const widths = resolveWidths(columns, available, doc);

  // ── Title block ───────────────────────────────────────────────────────────
  doc.font('bold').fontSize(16).fillColor(INK).text(report.title, left, PAGE_MARGIN);

  if (report.description) {
    doc.font('body').fontSize(9).fillColor(MUTED).text(report.description, { width: available });
  }

  doc.moveDown(0.4);
  doc.font('body').fontSize(8.5).fillColor(MUTED);
  for (const fact of facts(data, context, generatedAt)) {
    doc.text(`${fact.label}:  ${fact.value}`, { width: available });
  }

  if (data.truncatedAt !== undefined) {
    doc.moveDown(0.4);
    const noticeY = doc.y;
    const noticeHeight = 20;
    doc.rect(left, noticeY, available, noticeHeight).fill(WARN_BG);
    doc
      .font('bold')
      .fontSize(8.5)
      .fillColor(WARN_INK)
      .text(truncationNotice(data.truncatedAt), left + 6, noticeY + 6, { width: available - 12 });
    doc.y = noticeY + noticeHeight;
  }

  doc.moveDown(0.6);

  // ── Table ─────────────────────────────────────────────────────────────────
  const rowHeight = 16;
  const headerHeight = 20;
  const bottomLimit = doc.page.height - PAGE_MARGIN - 26; // leave room for the footer

  const drawHeader = () => {
    const y = doc.y;
    doc.rect(left, y, available, headerHeight).fill(HEADER_BG);
    doc.font('bold').fontSize(7.5).fillColor(INK);

    let x = left;
    columns.forEach((column, index) => {
      const width = widths[index] ?? 0;
      doc.text(column.header.toUpperCase(), x + 4, y + 6, {
        width: width - 8,
        align: isNumeric(column.type) ? 'right' : 'left',
        lineBreak: false,
        ellipsis: true,
      });
      x += width;
    });

    doc
      .moveTo(left, y + headerHeight)
      .lineTo(right, y + headerHeight)
      .strokeColor(RULE)
      .lineWidth(0.75)
      .stroke();

    doc.y = y + headerHeight;
  };

  drawHeader();

  doc.font('body').fontSize(8).fillColor(INK);

  data.rows.forEach((row, rowIndex) => {
    if (doc.y + rowHeight > bottomLimit) {
      doc.addPage({ layout: landscape ? 'landscape' : 'portrait', margin: PAGE_MARGIN });
      doc.y = PAGE_MARGIN;
      drawHeader();
      doc.font('body').fontSize(8).fillColor(INK);
    }

    const y = doc.y;

    // Banding, so the eye tracks across a wide row without a ruler.
    if (rowIndex % 2 === 1) {
      doc.rect(left, y, available, rowHeight).fill(STRIPE);
      doc.fillColor(INK);
    }

    let x = left;
    columns.forEach((column, index) => {
      const width = widths[index] ?? 0;
      const text = printed(column, row, fonts.hasRupeeGlyph);
      doc.text(text, x + 4, y + 4.5, {
        width: width - 8,
        align: isNumeric(column.type) ? 'right' : 'left',
        lineBreak: false,
        ellipsis: true,
      });
      x += width;
    });

    doc.y = y + rowHeight;
  });

  if (data.rows.length === 0) {
    doc.font('body').fontSize(9).fillColor(MUTED).text('Nothing to report for this selection.', left, doc.y + 8, {
      width: available,
      align: 'center',
    });
    doc.y += 24;
  }

  // ── Totals ────────────────────────────────────────────────────────────────
  const totals = totalsFor(columns, data.rows);
  if (totals.size > 0 && data.rows.length > 0) {
    if (doc.y + rowHeight + 4 > bottomLimit) {
      doc.addPage({ layout: landscape ? 'landscape' : 'portrait', margin: PAGE_MARGIN });
      doc.y = PAGE_MARGIN;
      drawHeader();
    }

    const y = doc.y;
    doc.moveTo(left, y).lineTo(right, y).strokeColor(RULE).lineWidth(0.75).stroke();
    doc.font('bold').fontSize(8).fillColor(INK);

    let x = left;
    columns.forEach((column, index) => {
      const width = widths[index] ?? 0;
      const sum = totals.get(column.key);
      const text =
        sum !== undefined
          ? withCurrency(printedTotal(sum, column.type), column, fonts.hasRupeeGlyph)
          : index === 0
            ? `Total — ${data.rows.length} rows`
            : '';
      doc.text(text, x + 4, y + 5, {
        width: width - 8,
        align: isNumeric(column.type) ? 'right' : 'left',
        lineBreak: false,
        ellipsis: true,
      });
      x += width;
    });

    doc.y = y + rowHeight + 2;
  }

  // ── Notes ─────────────────────────────────────────────────────────────────
  if (data.notes && data.notes.length > 0) {
    doc.moveDown(0.6);
    doc.font('body').fontSize(7.5).fillColor(MUTED);
    for (const note of data.notes) {
      if (doc.y + 12 > bottomLimit) {
        doc.addPage({ layout: landscape ? 'landscape' : 'portrait', margin: PAGE_MARGIN });
        doc.y = PAGE_MARGIN;
      }
      doc.text(note, left, doc.y, { width: available });
    }
  }

  // ── Footer on every page ──────────────────────────────────────────────────
  const range = doc.bufferedPageRange();
  const stamp = `${context.dealerName ?? ''}${context.dealerName ? ' · ' : ''}${report.title}`;

  for (let i = range.start; i < range.start + range.count; i += 1) {
    doc.switchToPage(i);

    // The footer sits below the bottom margin, and pdfkit adds a page whenever
    // the text cursor crosses it — which would append a blank page and make the
    // count it is printing wrong. Dropping the margin for the footer pass is the
    // documented way round it; the range was captured before this loop, so the
    // count stays correct.
    doc.page.margins.bottom = 0;

    const footerY = doc.page.height - PAGE_MARGIN - 10;
    doc
      .font('body')
      .fontSize(7.5)
      .fillColor(MUTED)
      .text(stamp, left, footerY, {
        width: doc.page.width - PAGE_MARGIN * 2,
        align: 'left',
        lineBreak: false,
      })
      .text(`Page ${i - range.start + 1} of ${range.count}`, left, footerY, {
        width: doc.page.width - PAGE_MARGIN * 2,
        align: 'right',
        lineBreak: false,
      });
  }

  doc.end();
  await finished;

  return {
    body: Buffer.concat(chunks),
    contentType: 'application/pdf',
    filename: `${filenameStem(report.title, generatedAt)}.pdf`,
  };
}

function printed(
  column: ExportColumn<unknown>,
  row: unknown,
  hasRupeeGlyph: boolean,
): string {
  return withCurrency(toPrintedValue(column.value(row), column.type), column, hasRupeeGlyph);
}

/** Swaps ₹ for INR when the fallback font cannot draw the glyph. */
function withCurrency(
  text: string,
  column: ExportColumn<unknown>,
  hasRupeeGlyph: boolean,
): string {
  if (hasRupeeGlyph || column.type !== 'money') return text;
  return text.replace('₹', 'INR ');
}

/**
 * Fits the columns to the page.
 *
 * Declared widths are treated as ratios rather than absolutes: the page is a
 * fixed width and the report does not know whether it is being drawn portrait or
 * landscape. Scaling keeps the proportions the report asked for while always
 * filling the page exactly, so nothing is cut off and nothing floats.
 */
function resolveWidths(
  columns: readonly ExportColumn<unknown>[],
  available: number,
  doc: PDFKit.PDFDocument,
): number[] {
  if (columns.length === 0) return [];

  const declared = columns.map((column) => column.width ?? defaultRatio(column.type));
  const total = declared.reduce((sum, width) => sum + width, 0);

  // A minimum so a narrow column still shows a few characters rather than an
  // ellipsis on its own.
  const minimum = Math.min(38, available / columns.length);
  const widths = declared.map((width) => Math.max(minimum, (width / total) * available));

  // Scaling up to the minimum can overshoot the page; take the excess back off
  // the widest columns, which have the most slack.
  let overflow = widths.reduce((sum, width) => sum + width, 0) - available;
  while (overflow > 0.5) {
    const widest = widths.indexOf(Math.max(...widths));
    const current = widths[widest] ?? 0;
    const take = Math.min(overflow, current - minimum);
    if (take <= 0) break;
    widths[widest] = current - take;
    overflow -= take;
  }

  void doc;
  return widths;
}

function defaultRatio(type: string | undefined): number {
  if (type === 'money') return 16;
  if (type === 'datetime') return 17;
  if (type === 'date') return 12;
  if (type === 'number' || type === 'quantity' || type === 'percent') return 10;
  return 20;
}
