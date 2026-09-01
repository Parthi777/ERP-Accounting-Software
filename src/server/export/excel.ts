import ExcelJS from 'exceljs';

import { formatDateTime } from '@/lib/format';
import type { TenantContext } from '@/server/auth/tenant-context';

import type { AnyExportReport, ExportData, RenderedExport } from './types';
import {
  isNumeric,
  numberFormatFor,
  spreadsheetTotal,
  toSpreadsheetValue,
  totalsFor,
} from './values';

/**
 * Excel export.
 *
 * Written for someone who will keep working in the file rather than only read
 * it: values land as numbers and dates rather than as formatted strings, the
 * header row freezes, and an autofilter is set so the sheet can be sorted and
 * sliced immediately. The cosmetic parts are deliberately restrained — this is
 * an accounting extract, not a dashboard.
 *
 * The header block above the table records who exported what, from which dealer
 * and branch, over which period. A spreadsheet outlives the screen it came from
 * and gets mailed on; it has to explain itself without the sender.
 */

const INK = 'FF1E293B';
const MUTED = 'FF64748B';
const HEADER_FILL = 'FFEFF4FE';
const RULE = 'FFCBD5E1';
const WARN_FILL = 'FFFEF3C7';
const WARN_INK = 'FF92400E';

const FONT = 'Calibri';

export async function renderExcel(
  report: AnyExportReport,
  data: ExportData<unknown>,
  context: TenantContext,
  generatedAt: Date,
): Promise<RenderedExport> {
  const columns = report.columns(context);

  const workbook = new ExcelJS.Workbook();
  workbook.creator = context.fullName || context.email;
  workbook.company = context.dealerName ?? 'Two-Wheeler Dealer ERP';
  workbook.created = generatedAt;

  // Excel refuses sheet names over 31 characters or containing : \ / ? * [ ]
  const sheet = workbook.addWorksheet(safeSheetName(report.title), {
    views: [{ state: 'frozen', ySplit: 0 }],
    pageSetup: {
      orientation: report.orientation === 'landscape' ? 'landscape' : 'portrait',
      fitToPage: true,
      fitToWidth: 1,
      fitToHeight: 0,
      paperSize: 9, // A4
      margins: { left: 0.4, right: 0.4, top: 0.6, bottom: 0.6, header: 0.3, footer: 0.3 },
    },
  });

  const lastColumn = Math.max(columns.length, 1);

  // ── Title block ───────────────────────────────────────────────────────────
  const titleRow = sheet.addRow([report.title]);
  titleRow.font = { name: FONT, size: 15, bold: true, color: { argb: INK } };
  titleRow.height = 21;
  sheet.mergeCells(titleRow.number, 1, titleRow.number, lastColumn);

  if (report.description) {
    const descriptionRow = sheet.addRow([report.description]);
    descriptionRow.font = { name: FONT, size: 10, color: { argb: MUTED } };
    sheet.mergeCells(descriptionRow.number, 1, descriptionRow.number, lastColumn);
  }

  for (const fact of facts(data, context, generatedAt)) {
    const row = sheet.addRow([`${fact.label}:  ${fact.value}`]);
    row.font = { name: FONT, size: 10, color: { argb: MUTED } };
    sheet.mergeCells(row.number, 1, row.number, lastColumn);
  }

  if (data.truncatedAt !== undefined) {
    const row = sheet.addRow([truncationNotice(data.truncatedAt)]);
    row.font = { name: FONT, size: 10, bold: true, color: { argb: WARN_INK } };
    row.eachCell((cell) => {
      cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: WARN_FILL } };
    });
    sheet.mergeCells(row.number, 1, row.number, lastColumn);
  }

  sheet.addRow([]);

  // ── Header ────────────────────────────────────────────────────────────────
  const headerRow = sheet.addRow(columns.map((column) => column.header));
  headerRow.font = { name: FONT, size: 10, bold: true, color: { argb: INK } };
  headerRow.alignment = { vertical: 'middle', wrapText: true };
  headerRow.height = 22;
  headerRow.eachCell((cell, index) => {
    cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: HEADER_FILL } };
    cell.border = { bottom: { style: 'thin', color: { argb: RULE } } };
    if (isNumeric(columns[index - 1]?.type)) {
      cell.alignment = { vertical: 'middle', horizontal: 'right', wrapText: true };
    }
  });

  const headerRowNumber = headerRow.number;

  // ── Body ──────────────────────────────────────────────────────────────────
  for (const row of data.rows) {
    const excelRow = sheet.addRow(
      columns.map((column) => toSpreadsheetValue(column.value(row), column.type)),
    );
    excelRow.font = { name: FONT, size: 10, color: { argb: INK } };

    excelRow.eachCell({ includeEmpty: true }, (cell, index) => {
      const column = columns[index - 1];
      if (!column) return;
      const format = numberFormatFor(column.type);
      if (format) cell.numFmt = format;
      if (isNumeric(column.type)) cell.alignment = { horizontal: 'right' };
    });
  }

  // ── Totals ────────────────────────────────────────────────────────────────
  const totals = totalsFor(columns, data.rows);
  if (totals.size > 0 && data.rows.length > 0) {
    const totalRow = sheet.addRow(
      columns.map((column, index) => {
        const sum = totals.get(column.key);
        if (sum !== undefined) return spreadsheetTotal(sum, column.type);
        return index === 0 ? `Total — ${data.rows.length} rows` : null;
      }),
    );
    totalRow.font = { name: FONT, size: 10, bold: true, color: { argb: INK } };
    totalRow.eachCell({ includeEmpty: true }, (cell, index) => {
      const column = columns[index - 1];
      cell.border = { top: { style: 'thin', color: { argb: RULE } } };
      if (!column) return;
      const format = numberFormatFor(column.type);
      if (format) cell.numFmt = format;
      if (isNumeric(column.type)) cell.alignment = { horizontal: 'right' };
    });
  }

  // ── Notes ─────────────────────────────────────────────────────────────────
  if (data.notes && data.notes.length > 0) {
    sheet.addRow([]);
    for (const note of data.notes) {
      const row = sheet.addRow([note]);
      row.font = { name: FONT, size: 9, italic: true, color: { argb: MUTED } };
      sheet.mergeCells(row.number, 1, row.number, lastColumn);
    }
  }

  // ── Geometry ──────────────────────────────────────────────────────────────
  columns.forEach((column, index) => {
    sheet.getColumn(index + 1).width = column.width ?? defaultWidth(column.type);
  });

  // Freeze everything above and including the header, so scrolling a long
  // extract keeps the column names — and the title block — in view.
  sheet.views = [{ state: 'frozen', ySplit: headerRowNumber }];

  if (data.rows.length > 0) {
    sheet.autoFilter = {
      from: { row: headerRowNumber, column: 1 },
      to: { row: headerRowNumber + data.rows.length, column: lastColumn },
    };
  }

  // Repeat the header on every printed page.
  sheet.pageSetup.printTitlesRow = `${headerRowNumber}:${headerRowNumber}`;

  const buffer = await workbook.xlsx.writeBuffer();

  return {
    body: Buffer.from(buffer),
    contentType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    filename: `${filenameStem(report.title, generatedAt)}.xlsx`,
  };
}

function defaultWidth(type: string | undefined): number {
  if (type === 'money') return 16;
  if (type === 'date') return 14;
  if (type === 'datetime') return 19;
  if (type === 'number' || type === 'quantity' || type === 'percent') return 12;
  return 22;
}

/** Excel rejects : \ / ? * [ ] in a sheet name, and truncates past 31 characters. */
function safeSheetName(title: string): string {
  const cleaned = title.replace(/[:\\/?*[\]]/g, ' ').trim();
  return cleaned.length > 31 ? cleaned.slice(0, 31).trim() : cleaned || 'Report';
}

export function facts(
  data: ExportData<unknown>,
  context: TenantContext,
  generatedAt: Date,
): { label: string; value: string }[] {
  const scope = context.activeBranch?.name ?? 'All branches';
  return [
    ...(context.dealerName ? [{ label: 'Dealer', value: context.dealerName }] : []),
    { label: 'Branch', value: scope },
    ...(data.facts ?? []).map((fact) => ({ label: fact.label, value: fact.value })),
    { label: 'Rows', value: String(data.rows.length) },
    {
      label: 'Generated',
      value: `${formatDateTime(generatedAt)} by ${context.fullName || context.email}`,
    },
  ];
}

export function truncationNotice(cap: number): string {
  return `INCOMPLETE — this export stopped at ${cap.toLocaleString('en-IN')} rows. Narrow the date range or filters to get the full set.`;
}

export function filenameStem(title: string, generatedAt: Date): string {
  const slug = title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '');
  const stamp = generatedAt.toISOString().slice(0, 10);
  return `${slug}-${stamp}`;
}
