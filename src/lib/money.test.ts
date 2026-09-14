import { describe, expect, it } from 'vitest';

import {
  ZERO,
  add,
  allocate,
  applyRate,
  compare,
  formatINR,
  fromDb,
  fromRupees,
  multiply,
  paise,
  percentageOf,
  subtract,
  toDb,
  toRupees,
} from './money';

/**
 * Money is the one module where a wrong answer is not a bug report, it is a
 * trial balance that does not balance. These assertions are chosen for what
 * breaking them would cost rather than for coverage.
 *
 * ICU currency spacing has changed between Node majors, so formatted output is
 * compared with the space characters normalised: a Node upgrade should not fail
 * the build over a narrow no-break space.
 */
const spaces = (s: string) => s.replace(/[  ]/g, ' ');

describe('fromDb', () => {
  it('parses what PostgREST actually sends for numeric', () => {
    expect(fromDb('84000.0000')).toBe(8400000);
    expect(fromDb('0.0000')).toBe(0);
    expect(fromDb('-1250.5000')).toBe(-125050);
  });

  it('treats absent values as zero rather than NaN', () => {
    expect(fromDb(null)).toBe(ZERO);
    expect(fromDb(undefined)).toBe(ZERO);
    expect(fromDb('')).toBe(ZERO);
  });

  it('accepts what a person types, commas and rupee sign included', () => {
    expect(fromDb('1,25,000.50')).toBe(12500050);
    expect(fromDb('₹1,25,000.50')).toBe(12500050);
    expect(fromDb(' 500 ')).toBe(50000);
  });

  /**
   * The assertion that justifies parsing digit by digit.
   *
   * `1.005` cannot be represented exactly in binary — the nearest double is
   * slightly *below* it — so `parseFloat('1.005') * 100` is 100.4999…, and
   * rounding gives 100 paise where the correct answer is 101. This is not an
   * exotic value: it is what a 0.5% charge on ₹201 comes to. A ledger out by one
   * paisa is out, there being no tolerance below which a trial balance still
   * balances.
   */
  it('is exact where parseFloat is not', () => {
    expect(fromDb('1.005')).toBe(101);
    expect(Math.round(Number.parseFloat('1.005') * 100)).toBe(100); // the wrong answer

    expect(fromDb('1234567.005')).toBe(123456701);
    expect(Math.round(Number.parseFloat('1234567.005') * 100)).toBe(123456700);

    // And it stays exact at the top of the range the ledger can reach.
    expect(fromDb('9007199254740.99')).toBe(900719925474099);
  });

  /**
   * Scientific notation is not currently produced by PostgREST for `numeric`,
   * but a driver change could start it. This pins that such a value fails loudly
   * instead of parsing as zero and quietly removing an amount from the books.
   */
  it('refuses scientific notation rather than reading it as zero', () => {
    expect(() => fromDb('1e3')).toThrow(RangeError);
    expect(() => fromDb('abc')).toThrow(RangeError);
  });

  it('rounds half away from zero at the third decimal, in both signs', () => {
    expect(fromDb('1.005')).toBe(101);
    expect(fromDb('-1.005')).toBe(-101);
    expect(fromDb('1.004')).toBe(100);
    expect(fromDb('-1.004')).toBe(-100);
  });
});

describe('toDb', () => {
  it('round-trips through the database representation', () => {
    for (const value of ['84000.0000', '-1250.5000', '0.0000', '1.0100']) {
      expect(fromDb(toDb(fromDb(value)))).toBe(fromDb(value));
    }
  });

  /**
   * Two decimals, not four. The column is numeric(18,4) and Postgres pads on
   * storage; sending the paise exactly is what matters, not the trailing zeros.
   */
  it('writes an exact decimal string for the numeric column', () => {
    expect(toDb(paise(8400000))).toBe('84000.00');
    expect(toDb(paise(-125050))).toBe('-1250.50');
    expect(toDb(paise(5))).toBe('0.05');
    expect(toDb(ZERO)).toBe('0.00');
  });
});

describe('arithmetic', () => {
  it('adds without float drift — the 0.1 + 0.2 case in paise', () => {
    expect(add(fromRupees(0.1), fromRupees(0.2))).toBe(fromRupees(0.3));
    expect(add(fromRupees(0.1), fromRupees(0.2))).toBe(30);
  });

  it('sums a long line of invoice values exactly', () => {
    const lines = Array.from({ length: 1000 }, () => fromRupees(0.07));
    expect(add(...lines)).toBe(7000);
  });

  it('subtracts, negates and compares', () => {
    expect(subtract(paise(100), paise(30))).toBe(70);
    expect(compare(paise(1), paise(2))).toBe(-1);
    expect(compare(paise(2), paise(2))).toBe(0);
    expect(compare(paise(3), paise(2))).toBe(1);
  });

  it('multiplies by a quantity without introducing a fraction of a paisa', () => {
    expect(multiply(paise(3333), 3)).toBe(9999);
  });

  it('refuses a non-integer amount rather than storing a fraction of a paisa', () => {
    expect(() => paise(1.5)).toThrow(RangeError);
    expect(() => paise(Number.NaN)).toThrow(RangeError);
  });
});

describe('applyRate', () => {
  it('computes a GST component', () => {
    expect(applyRate(paise(10000), 0.09)).toBe(900);
    expect(applyRate(paise(100000), 0.18)).toBe(18000);
  });

  /**
   * `Math.round(-4.5)` is `-4` in JavaScript — it rounds half *up*, towards
   * positive infinity, not away from zero. A credit note is a negative amount,
   * so without the explicit sign handling in applyRate the tax on a reversal
   * would not mirror the tax on the original, and the two would never net to
   * zero in the GST return.
   */
  it('mirrors exactly on a negative amount, which plain Math.round does not', () => {
    expect(applyRate(paise(-10000), 0.09)).toBe(-900);
    expect(applyRate(paise(-50), 0.09)).toBe(-5);
    expect(Math.round(-4.5)).toBe(-4); // the behaviour being worked around
  });

  it('rounds once, so a tax total is not the sum of rounded halves', () => {
    const taxable = paise(333);
    expect(applyRate(taxable, 0.18)).toBe(60);
    expect(applyRate(taxable, 0.09) + applyRate(taxable, 0.09)).toBe(60);
  });
});

describe('allocate', () => {
  it('splits ₹100 three ways without losing a paisa', () => {
    expect(allocate(paise(10000), 3)).toEqual([3334, 3333, 3333]);
  });

  it('always sums back to exactly the original, across counts and signs', () => {
    for (const amount of [10000, 1, 7, 99999, -10000, -7]) {
      for (let count = 1; count <= 7; count += 1) {
        const parts = allocate(paise(amount), count);
        expect(parts).toHaveLength(count);
        expect(parts.reduce((a, b) => a + b, 0)).toBe(amount);
      }
    }
  });

  it('refuses a count that is not a positive whole number', () => {
    expect(() => allocate(paise(100), 0)).toThrow(RangeError);
    expect(() => allocate(paise(100), -1)).toThrow(RangeError);
    expect(() => allocate(paise(100), 1.5)).toThrow(RangeError);
  });
});

describe('percentageOf', () => {
  it('returns null rather than Infinity when the whole is zero', () => {
    expect(percentageOf(paise(50), ZERO)).toBeNull();
  });

  it('computes a percentage', () => {
    expect(percentageOf(paise(25), paise(100))).toBe(25);
  });
});

describe('formatINR', () => {
  it('groups the Indian way — lakhs and crores, not thousands', () => {
    expect(spaces(formatINR(paise(12500000)))).toContain('1,25,000.00');
    expect(spaces(formatINR(paise(10000000000)))).toContain('10,00,00,000.00');
  });

  it('shows a negative amount as negative', () => {
    expect(spaces(formatINR(paise(-12500000)))).toMatch(/-/);
  });
});

describe('toRupees', () => {
  it('is for display and comparison, not for storing back', () => {
    expect(toRupees(paise(12500050))).toBe(125000.5);
  });
});
