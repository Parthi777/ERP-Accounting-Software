import { formatDate, formatDateTime } from '@/lib/format';
import { formatINR, toRupees, type Paise } from '@/lib/money';

import type { CellType, CellValue, ExportColumn } from './types';

/**
 * Turning a column's raw value into something a file can hold.
 *
 * Two renderers, two answers. Excel wants the number so it can be summed and
 * pivoted; PDF wants the string because a page cell is ink. Keeping both here
 * means the two exports of the same report cannot drift apart in how they read
 * a value — only in how they show it.
 */

/**
 * Indian digit grouping: `12,34,56,789.00`, not `123,456,789.00`.
 *
 * Excel's format language handles this with a repeated group before the last
 * three digits — `#,##,##0.00`. Negatives go in brackets, which is what an
 * accountant expects a credit to look like on a statement.
 */
export const MONEY_NUMBER_FORMAT = '#,##,##0.00;(#,##,##0.00)';
export const QUANTITY_NUMBER_FORMAT = '#,##0.###';
export const PERCENT_NUMBER_FORMAT = '0.00"%"';
export const DATE_NUMBER_FORMAT = 'dd-mmm-yyyy';
export const DATETIME_NUMBER_FORMAT = 'dd-mmm-yyyy hh:mm';

const DECIMAL = new Intl.NumberFormat('en-IN', {
  minimumFractionDigits: 0,
  maximumFractionDigits: 3,
});

/** The number format for a column, or undefined when the cell is text. */
export function numberFormatFor(type: CellType | undefined): string | undefined {
  switch (type) {
    case 'money':
      return MONEY_NUMBER_FORMAT;
    case 'quantity':
      return QUANTITY_NUMBER_FORMAT;
    case 'percent':
      return PERCENT_NUMBER_FORMAT;
    case 'date':
      return DATE_NUMBER_FORMAT;
    case 'datetime':
      return DATETIME_NUMBER_FORMAT;
    default:
      return undefined;
  }
}

export function isNumeric(type: CellType | undefined): boolean {
  return type === 'money' || type === 'number' || type === 'quantity' || type === 'percent';
}

/**
 * The value as Excel should hold it.
 *
 * Money arrives as branded paise and leaves as rupees, because a spreadsheet
 * column of paise would be off by a factor of a hundred against every other
 * document the dealer has. Dates leave as Date objects so Excel stores them as
 * dates and can sort and filter them as dates.
 */
export function toSpreadsheetValue(
  raw: CellValue,
  type: CellType | undefined,
): string | number | Date | null {
  if (raw === null || raw === undefined) return null;

  switch (type) {
    case 'money':
      return toRupees(raw as Paise);
    case 'number':
    case 'quantity':
    case 'percent':
      return typeof raw === 'number' ? raw : Number(raw);
    case 'date':
    case 'datetime': {
      if (raw instanceof Date) return raw;
      const parsed = new Date(String(raw));
      // An unparseable date is kept as its original text rather than written as
      // Invalid Date, which Excel renders as a meaningless serial number.
      return Number.isNaN(parsed.getTime()) ? String(raw) : parsed;
    }
    default:
      return String(raw);
  }
}

/** The value as a PDF cell should print it. */
export function toPrintedValue(raw: CellValue, type: CellType | undefined): string {
  if (raw === null || raw === undefined) return '—';

  switch (type) {
    case 'money':
      return formatINR(raw as Paise);
    case 'number':
      return DECIMAL.format(typeof raw === 'number' ? raw : Number(raw));
    case 'quantity':
      return DECIMAL.format(typeof raw === 'number' ? raw : Number(raw));
    case 'percent':
      return `${DECIMAL.format(typeof raw === 'number' ? raw : Number(raw))}%`;
    case 'date':
      return formatDate(raw as string | Date);
    case 'datetime':
      return formatDateTime(raw as string | Date);
    default: {
      const text = String(raw);
      return text.length === 0 ? '—' : text;
    }
  }
}

/**
 * Column totals.
 *
 * Only columns marked `total` are summed, and only over numeric types — summing
 * a column of invoice numbers produces a number, which is worse than producing
 * nothing. Money stays in integer paise while adding, so a long column does not
 * accumulate float error (spec §60.25).
 */
export function totalsFor<T>(
  columns: readonly ExportColumn<T>[],
  rows: readonly T[],
): Map<string, number> {
  const totals = new Map<string, number>();

  for (const column of columns) {
    if (!column.total || !isNumeric(column.type)) continue;

    let sum = 0;
    for (const row of rows) {
      const raw = column.value(row);
      if (raw === null || raw === undefined) continue;
      const numeric = typeof raw === 'number' ? raw : Number(raw);
      if (Number.isFinite(numeric)) sum += numeric;
    }
    totals.set(column.key, sum);
  }

  return totals;
}

/** Formats a computed total the same way its column formats a cell. */
export function printedTotal(sum: number, type: CellType | undefined): string {
  if (type === 'money') return formatINR(sum as Paise);
  if (type === 'percent') return `${DECIMAL.format(sum)}%`;
  return DECIMAL.format(sum);
}

export function spreadsheetTotal(sum: number, type: CellType | undefined): number {
  return type === 'money' ? toRupees(sum as Paise) : sum;
}
