/**
 * Period helpers shared by the dashboard and the accounting statements.
 *
 * Dates are handled as plain `YYYY-MM-DD` strings rather than Date objects: a
 * financial period is a calendar fact, and putting it through a timezone-aware
 * type is how a report silently shifts by a day for a user in another zone.
 */

export function todayIso(): string {
  return toIso(new Date());
}

export function toIso(date: Date): string {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(
    date.getDate(),
  ).padStart(2, '0')}`;
}

export function isIsoDate(value: string | undefined): value is string {
  return Boolean(value && /^\d{4}-\d{2}-\d{2}$/.test(value));
}

/** The supplied range, or the current calendar month when it is missing or malformed. */
export function monthRange(from?: string, to?: string): { from: string; to: string } {
  if (isIsoDate(from) && isIsoDate(to)) {
    return { from, to };
  }
  const now = new Date();
  return {
    from: toIso(new Date(now.getFullYear(), now.getMonth(), 1)),
    to: toIso(new Date(now.getFullYear(), now.getMonth() + 1, 0)),
  };
}

/** Just enough of an accounting period to bound a report. */
export interface PeriodWindow {
  readonly startDate: string;
  readonly endDate: string;
}

/**
 * The supplied range, or the financial year in context, or the current month.
 *
 * The financial year is a *default*, never a filter: an explicit range in the
 * URL always wins, so a link to a specific fortnight keeps meaning that
 * fortnight whichever year the header is set to.
 *
 * The end is clamped to today when today falls inside the year. The data is the
 * same either way — nothing is posted into the future — but a date input
 * offering 31-03-2027 in September reads as a mistake.
 */
export function rangeInYear(
  year: PeriodWindow | null | undefined,
  from?: string,
  to?: string,
): { from: string; to: string } {
  if (isIsoDate(from) && isIsoDate(to)) {
    return { from, to };
  }
  if (!year) {
    return monthRange(from, to);
  }
  const today = todayIso();
  return {
    from: year.startDate,
    to: today < year.startDate ? year.startDate : today > year.endDate ? year.endDate : today,
  };
}

/**
 * The supplied date, or today brought inside the financial year in context.
 *
 * "As on" a year that has ended means its last day; a year still running means
 * today. Asking for a balance as on a date in the future is never what anyone
 * meant.
 */
export function asOnInYear(year: PeriodWindow | null | undefined, asOn?: string): string {
  if (isIsoDate(asOn)) {
    return asOn;
  }
  const today = todayIso();
  if (!year) {
    return today;
  }
  if (today < year.startDate) {
    return year.startDate;
  }
  return today > year.endDate ? year.endDate : today;
}
