import { describe, expect, it } from 'vitest';

import { parseAmount, parseCsv, parseStatementDate, splitCsvLine } from './csv';

/**
 * Three importers and a bank statement reader sit on this module. A parsing
 * mistake here does not throw — it produces plausible wrong rows, which is the
 * expensive kind.
 */

describe('splitCsvLine', () => {
  it('splits a plain line', () => {
    expect(splitCsvLine('a,b,c')).toEqual(['a', 'b', 'c']);
  });

  /** The reason this function exists: addresses and narrations contain commas. */
  it('keeps a quoted field with commas in one piece', () => {
    expect(splitCsvLine('"12, Gandhi Street, Coimbatore",641001')).toEqual([
      '12, Gandhi Street, Coimbatore',
      '641001',
    ]);
  });

  it('reads a doubled quote as a literal quote', () => {
    expect(splitCsvLine('"He said ""yes""",next')).toEqual(['He said "yes"', 'next']);
  });

  it('preserves empty cells, including trailing ones', () => {
    expect(splitCsvLine('a,,c')).toEqual(['a', '', 'c']);
    expect(splitCsvLine('a,b,')).toEqual(['a', 'b', '']);
    expect(splitCsvLine('')).toEqual(['']);
  });

  it('handles a quoted empty field', () => {
    expect(splitCsvLine('a,"",c')).toEqual(['a', '', 'c']);
  });
});

describe('parseCsv', () => {
  /**
   * Punctuation collapses too, not only whitespace. HDFC writes "Chq/Ref No"
   * and ICICI writes "Dr/Cr"; leaving the slash in place meant neither matched
   * its alias in the statement parser, which silently lost every reference
   * number and rejected every row of a single-amount statement.
   */
  it('normalises headers to lower_snake_case, punctuation included', () => {
    const { headers } = parseCsv('Value Date,NARRATION,Chq/Ref No,Dr/Cr\n01/02/2026,x,y,Cr');
    expect(headers).toEqual(['value_date', 'narration', 'chq_ref_no', 'dr_cr']);
  });

  it('does not leave an underscore dangling off a trailing symbol', () => {
    expect(parseCsv('Amount (₹),Balance.\n1,2').headers).toEqual(['amount', 'balance']);
  });

  it('keys rows by header and trims cells', () => {
    const { rows } = parseCsv('name,mobile\n  Ramesh  , 9876543210 ');
    expect(rows).toEqual([{ name: 'Ramesh', mobile: '9876543210' }]);
  });

  it('gives every row every header, even when a line is short', () => {
    const { rows } = parseCsv('a,b,c\n1,2');
    expect(rows[0]).toEqual({ a: '1', b: '2', c: '' });
  });

  it('ignores blank lines, which trailing newlines always produce', () => {
    const { rows } = parseCsv('a\n1\n\n2\n');
    expect(rows).toHaveLength(2);
  });

  it('returns nothing for a header with no data, rather than a phantom row', () => {
    expect(parseCsv('a,b')).toEqual({ headers: [], rows: [] });
    expect(parseCsv('')).toEqual({ headers: [], rows: [] });
  });

  it('accepts CRLF, which is what a Windows spreadsheet writes', () => {
    const { rows } = parseCsv('a,b\r\n1,2\r\n');
    expect(rows).toEqual([{ a: '1', b: '2' }]);
  });
});

describe('parseStatementDate', () => {
  /**
   * The assertion this module exists for. `new Date('01/02/2026')` is 2 January
   * in the American convention; every Indian bank means 1 February. Getting it
   * wrong dates entries to the wrong month for eleven days in every twelve, and
   * a reconciliation would then fail for reasons nobody could see.
   */
  it('reads a slashed date day-first, not month-first', () => {
    expect(parseStatementDate('01/02/2026')).toBe('2026-02-01');
    expect(parseStatementDate('01-02-2026')).toBe('2026-02-01');
    expect(parseStatementDate('15/08/2026')).toBe('2026-08-15');
  });

  it('passes an ISO date through', () => {
    expect(parseStatementDate('2026-02-01')).toBe('2026-02-01');
    expect(parseStatementDate('2026-02-01T10:30:00Z')).toBe('2026-02-01');
  });

  it('reads the named-month form HDFC and ICICI export', () => {
    expect(parseStatementDate('15-Aug-2026')).toBe('2026-08-15');
    expect(parseStatementDate('5 Sep 2026')).toBe('2026-09-05');
    expect(parseStatementDate('15-August-2026')).toBe('2026-08-15');
  });

  it('expands a two-digit year into this century', () => {
    expect(parseStatementDate('01/02/26')).toBe('2026-02-01');
  });

  /** Rejected, not approximated: a guessed date reconciles against nothing. */
  it('returns null for anything it cannot read exactly', () => {
    expect(parseStatementDate('not a date')).toBeNull();
    expect(parseStatementDate('01/13/2026')).toBeNull(); // month 13 — an American date
    expect(parseStatementDate('15-Xyz-2026')).toBeNull();
    expect(parseStatementDate('')).toBeNull();
    expect(parseStatementDate(null)).toBeNull();
  });
});

describe('parseAmount', () => {
  it('reads Indian grouping and a rupee sign', () => {
    expect(parseAmount('1,25,000.00')).toBe(125000);
    expect(parseAmount('₹1,25,000.50')).toBe(125000.5);
  });

  it('treats a blank column as zero, not NaN', () => {
    expect(parseAmount('')).toBe(0);
    expect(parseAmount(null)).toBe(0);
    expect(parseAmount(undefined)).toBe(0);
    expect(parseAmount('   ')).toBe(0);
  });

  it('strips a trailing Cr/Dr marker', () => {
    expect(parseAmount('5000.00 Cr')).toBe(5000);
    expect(parseAmount('5000.00Dr')).toBe(5000);
  });

  /**
   * Two behaviours worth writing down rather than discovering during a
   * reconciliation.
   *
   * The sign is discarded deliberately: direction comes from which column the
   * value sits in, or from an explicit Cr/Dr marker, never from a minus sign —
   * see statement-parser.ts, which refuses to infer direction at all.
   *
   * Accounting parentheses are *not* understood. "(500)" means -500 in many
   * exports and comes back as 0 here, so such a statement silently loses rows.
   * Not a bug to fix blind — a bank that writes them needs its format confirmed
   * before the meaning is assumed — but a real import risk, recorded.
   */
  it('discards a minus sign, because direction never comes from one', () => {
    expect(parseAmount('-500')).toBe(500);
  });

  it('does not understand accounting parentheses — known gap', () => {
    expect(parseAmount('(500)')).toBe(0);
  });

  it('returns zero for text rather than NaN', () => {
    expect(parseAmount('n/a')).toBe(0);
  });
});
