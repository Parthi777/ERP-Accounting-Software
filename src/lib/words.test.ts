import { describe, expect, it } from 'vitest';

import { amountInWords } from './words';
import { fromRupees, paise } from './money';

/**
 * This line prints on every tax invoice, and where the figures and the words
 * disagree the words govern. It is also a pure function with no library
 * underneath it, so nothing else will catch a mistake here.
 */

const words = (rupees: number) => amountInWords(fromRupees(rupees));

describe('amountInWords', () => {
  it('spells the small irregular numbers', () => {
    expect(words(0)).toBe('Rupees Zero Only');
    expect(words(1)).toBe('Rupees One Only');
    expect(words(15)).toBe('Rupees Fifteen Only');
    expect(words(19)).toBe('Rupees Nineteen Only');
  });

  it('hyphenates compound tens, and does not hyphenate round ones', () => {
    expect(words(21)).toBe('Rupees Twenty-One Only');
    expect(words(45)).toBe('Rupees Forty-Five Only');
    expect(words(90)).toBe('Rupees Ninety Only');
  });

  it('spells hundreds without an "and" before the remainder', () => {
    expect(words(100)).toBe('Rupees One Hundred Only');
    expect(words(105)).toBe('Rupees One Hundred Five Only');
    expect(words(999)).toBe('Rupees Nine Hundred Ninety-Nine Only');
  });

  /**
   * The assertion the module exists for. Indian grouping is 2-2-3, so this is
   * "Twelve Lakh Fifty Thousand" — never "One Million Two Hundred Fifty
   * Thousand". The customer, the banker and the assessing officer all read the
   * first and none of them reads the second.
   */
  it('groups in lakhs and crores, not millions', () => {
    expect(words(1250000)).toBe('Rupees Twelve Lakh Fifty Thousand Only');
    expect(words(100000)).toBe('Rupees One Lakh Only');
    expect(words(10000000)).toBe('Rupees One Crore Only');
    expect(words(12345678)).toBe(
      'Rupees One Crore Twenty-Three Lakh Forty-Five Thousand Six Hundred Seventy-Eight Only',
    );
  });

  it('carries across the thousand and lakh boundaries', () => {
    expect(words(999)).toBe('Rupees Nine Hundred Ninety-Nine Only');
    expect(words(1000)).toBe('Rupees One Thousand Only');
    expect(words(99999)).toBe('Rupees Ninety-Nine Thousand Nine Hundred Ninety-Nine Only');
    expect(words(100001)).toBe('Rupees One Lakh One Only');
  });

  /** Past 99 crore the unit does not change — it becomes a count of crores. */
  it('keeps counting crores rather than inventing a larger unit', () => {
    expect(words(1000000000)).toBe('Rupees One Hundred Crore Only');
    expect(words(10000000000)).toBe('Rupees One Thousand Crore Only');
  });

  it('names paise separately, as the convention requires', () => {
    expect(words(1000.5)).toBe('Rupees One Thousand and Fifty Paise Only');
    expect(words(0.05)).toBe('Rupees Zero and Five Paise Only');
    expect(words(99.99)).toBe('Rupees Ninety-Nine and Ninety-Nine Paise Only');
  });

  it('omits the paise clause entirely when there are none', () => {
    expect(words(500)).toBe('Rupees Five Hundred Only');
    expect(words(500)).not.toContain('Paise');
  });

  /**
   * A carry out of the paise must reach the rupees. Reading "Ninety-Nine and
   * One Hundred Paise" on an invoice would be both wrong and obviously wrong,
   * which is the kind a customer queries.
   */
  it('carries a rounded-up paise into the rupees', () => {
    expect(amountInWords(paise(9999))).toBe('Rupees Ninety-Nine and Ninety-Nine Paise Only');
    expect(amountInWords(paise(10000))).toBe('Rupees One Hundred Only');
  });

  /**
   * A credit note total is negative. Printing it as though it were a debit
   * would be the quiet kind of error that survives all the way to a dispute.
   */
  it('says Minus rather than dropping the sign', () => {
    expect(words(-1500)).toBe('Minus Rupees One Thousand Five Hundred Only');
    expect(words(-0.5)).toBe('Minus Rupees Zero and Fifty Paise Only');
  });

  it('always opens with Rupees and closes with Only', () => {
    for (const amount of [0, 1, 99.99, 1250000, -75]) {
      const line = words(amount);
      expect(line).toMatch(/Rupees /);
      expect(line.endsWith(' Only')).toBe(true);
    }
  });

  it('agrees with the rounded figure printed above it', () => {
    // 1234.567 rounds to 1234.57 on the invoice, so the words must say 57 paise.
    expect(amountInWords(fromRupees(1234.567))).toBe(
      'Rupees One Thousand Two Hundred Thirty-Four and Fifty-Seven Paise Only',
    );
  });
});
