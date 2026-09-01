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
