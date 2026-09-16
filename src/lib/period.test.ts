import { describe, expect, test } from 'vitest';

import { asOnInYear, isIsoDate, monthRange, rangeInYear, todayIso } from './period';

/**
 * The financial-year default, which decides where every dated screen lands.
 *
 * The cases that matter are the boundaries: a year that has ended, a year still
 * running, and a year that has not started. Getting the clamp wrong shows a
 * dealer a balance as on a date in the future, or an empty report for a year
 * full of transactions.
 */
const PAST = { startDate: '2024-04-01', endDate: '2025-03-31' };
const FUTURE = { startDate: '2099-04-01', endDate: '2100-03-31' };
const FOREVER = { startDate: '2000-01-01', endDate: '2999-12-31' };

describe('rangeInYear', () => {
  test('an explicit range always wins, whichever year is selected', () => {
    expect(rangeInYear(PAST, '2026-05-01', '2026-05-31')).toEqual({
      from: '2026-05-01',
      to: '2026-05-31',
    });
  });

  test('a half-supplied range is not half-honoured', () => {
    // One date without the other cannot bound anything; falling through to the
    // year is better than inventing the missing end.
    expect(rangeInYear(PAST, '2026-05-01', undefined)).toEqual({
      from: PAST.startDate,
      to: PAST.endDate,
    });
  });

  test('a year that has ended gives the whole year', () => {
    expect(rangeInYear(PAST)).toEqual({ from: '2024-04-01', to: '2025-03-31' });
  });

  test('a year still running ends today, not on a future date', () => {
    const range = rangeInYear(FOREVER);
    expect(range.from).toBe(FOREVER.startDate);
    expect(range.to).toBe(todayIso());
  });

  test('a year that has not started collapses to its first day', () => {
    expect(rangeInYear(FUTURE)).toEqual({ from: '2099-04-01', to: '2099-04-01' });
  });

  test('with no year at all it falls back to the calendar month', () => {
    expect(rangeInYear(null)).toEqual(monthRange());
  });
});

describe('asOnInYear', () => {
  test('an explicit date wins', () => {
    expect(asOnInYear(PAST, '2026-01-31')).toBe('2026-01-31');
  });

  test('a malformed date is ignored rather than passed to the database', () => {
    expect(asOnInYear(PAST, '31-01-2026')).toBe(PAST.endDate);
  });

  test('a year that has ended is as on its last day', () => {
    expect(asOnInYear(PAST)).toBe('2025-03-31');
  });

  test('a year still running is as on today', () => {
    expect(asOnInYear(FOREVER)).toBe(todayIso());
  });

  test('with no year at all it is today', () => {
    expect(asOnInYear(null)).toBe(todayIso());
  });
});

describe('isIsoDate', () => {
  test('accepts only YYYY-MM-DD', () => {
    expect(isIsoDate('2026-04-01')).toBe(true);
    expect(isIsoDate('2026-4-1')).toBe(false);
    expect(isIsoDate(undefined)).toBe(false);
  });
});
