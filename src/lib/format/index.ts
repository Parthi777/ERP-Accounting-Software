/**
 * Display formatting. Indian conventions throughout (spec §51).
 */

import { format, formatDistanceToNowStrict, isValid, parseISO } from 'date-fns';

const NUMBER_FORMATTER = new Intl.NumberFormat('en-IN');

/** `1,25,000` — Indian digit grouping for counts and quantities. */
export function formatNumber(value: number): string {
  return NUMBER_FORMATTER.format(value);
}

/** `18.6%`, or an em dash when the value is unknown. */
export function formatPercent(value: number | null | undefined, fractionDigits = 1): string {
  if (value === null || value === undefined || !Number.isFinite(value)) {
    return '—';
  }
  return `${value.toFixed(fractionDigits)}%`;
}

/** `+18.6%` / `-4.2%` — signed, for period-on-period deltas. */
export function formatDelta(value: number | null | undefined, fractionDigits = 1): string {
  if (value === null || value === undefined || !Number.isFinite(value)) {
    return '—';
  }
  const sign = value > 0 ? '+' : '';
  return `${sign}${value.toFixed(fractionDigits)}%`;
}

function toDate(value: string | Date | null | undefined): Date | null {
  if (!value) {
    return null;
  }
  const date = typeof value === 'string' ? parseISO(value) : value;
  return isValid(date) ? date : null;
}

/** `30 Aug 2026` */
export function formatDate(value: string | Date | null | undefined): string {
  const date = toDate(value);
  return date ? format(date, 'dd MMM yyyy') : '—';
}

/** `30 Aug 2026, 01:16 AM` */
export function formatDateTime(value: string | Date | null | undefined): string {
  const date = toDate(value);
  return date ? format(date, 'dd MMM yyyy, hh:mm a') : '—';
}

/** `01:16 AM` */
export function formatTime(value: string | Date | null | undefined): string {
  const date = toDate(value);
  return date ? format(date, 'hh:mm a') : '—';
}

/** `2 hours ago` — for audit trails and activity feeds. */
export function formatRelative(value: string | Date | null | undefined): string {
  const date = toDate(value);
  return date ? `${formatDistanceToNowStrict(date)} ago` : '—';
}

/** `01 May 2026 – 31 May 2026` */
export function formatDateRange(from: string | Date, to: string | Date): string {
  return `${formatDate(from)} – ${formatDate(to)}`;
}

/** The Indian financial year containing a date, e.g. `2026-27`. */
export function financialYear(value: string | Date = new Date(), startMonth = 4): string {
  const date = toDate(value) ?? new Date();
  const year = date.getFullYear();
  const startYear = date.getMonth() + 1 >= startMonth ? year : year - 1;
  return `${startYear}-${String((startYear + 1) % 100).padStart(2, '0')}`;
}

/** The year token used inside document numbers, e.g. `2026` in `INV-2026-000001`. */
export function financialYearToken(value: string | Date = new Date(), startMonth = 4): string {
  const date = toDate(value) ?? new Date();
  const year = date.getFullYear();
  return String(date.getMonth() + 1 >= startMonth ? year : year - 1);
}

/** `RK` — initials for an avatar fallback. */
export function initials(name: string): string {
  return name
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part[0]?.toUpperCase() ?? '')
    .join('');
}

/** `+91 98400 12001` when the shape is recognisable, otherwise unchanged. */
export function formatMobile(value: string | null | undefined): string {
  if (!value) {
    return '—';
  }
  const digits = value.replace(/\D/g, '');
  if (digits.length === 10) {
    return `${digits.slice(0, 5)} ${digits.slice(5)}`;
  }
  if (digits.length === 12 && digits.startsWith('91')) {
    return `+91 ${digits.slice(2, 7)} ${digits.slice(7)}`;
  }
  return value;
}
