import { toRupees, type Paise } from '@/lib/money';

/**
 * Amounts spelled out, Indian style — spec §51.
 *
 * Every tax invoice in India carries the total in words under the figures. It is
 * not decoration: where the two disagree the words govern, which is why the line
 * survives on printed invoices long after the arithmetic moved into software.
 *
 * Grouping follows the Indian system, not the international one — crore, lakh,
 * thousand, hundred — so 12,50,000 reads "Twelve Lakh Fifty Thousand" and never
 * "One Million Two Hundred Fifty Thousand". A dealer's customer, banker and
 * assessing officer all read the first and none of them reads the second.
 *
 * Paise are named separately rather than as a fraction, again by convention:
 * "Rupees One Thousand and Fifty Paise Only".
 */

const ONES = [
  '', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine',
  'Ten', 'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen',
  'Seventeen', 'Eighteen', 'Nineteen',
] as const;

const TENS = [
  '', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety',
] as const;

/** 0–99. The teens are irregular in English, so they are a lookup, not a rule. */
function underHundred(n: number): string {
  if (n < 20) return ONES[n]!;
  const tens = TENS[Math.floor(n / 10)]!;
  const ones = ONES[n % 10]!;
  return ones ? `${tens}-${ones}` : tens;
}

/** 0–999. */
function underThousand(n: number): string {
  const hundreds = Math.floor(n / 100);
  const rest = n % 100;
  if (!hundreds) return underHundred(rest);
  const head = `${ONES[hundreds]!} Hundred`;
  return rest ? `${head} ${underHundred(rest)}` : head;
}

/**
 * A whole number in Indian grouping.
 *
 * The groups are 2-2-2-3 from the right rather than 3-3-3, so they are peeled
 * off in that order: the last three digits, then pairs.
 */
function spellWhole(value: number): string {
  if (value === 0) return 'Zero';

  const parts: string[] = [];

  const crore = Math.floor(value / 10_000_000);
  const lakh = Math.floor((value % 10_000_000) / 100_000);
  const thousand = Math.floor((value % 100_000) / 1_000);
  const rest = value % 1_000;

  // Crores past 99 are spoken as a number of crores — "One Thousand Crore" —
  // rather than by inventing a larger unit.
  if (crore) parts.push(`${crore > 999 ? spellWhole(crore) : underThousand(crore)} Crore`);
  if (lakh) parts.push(`${underHundred(lakh)} Lakh`);
  if (thousand) parts.push(`${underHundred(thousand)} Thousand`);
  if (rest) parts.push(underThousand(rest));

  return parts.join(' ');
}

/**
 * The full invoice line: `Rupees … Only`.
 *
 * A negative amount is spelled with "Minus" in front rather than dropped or
 * silently made positive — a credit note total is negative and printing it as
 * though it were a debit would be the worst kind of quiet error.
 */
export function amountInWords(value: Paise): string {
  const rupees = toRupees(value);
  const negative = rupees < 0;
  const absolute = Math.abs(rupees);

  const whole = Math.floor(absolute);
  // Rounded, not truncated: the figure printed above this line is rounded to two
  // places by the same arithmetic, and the two must agree.
  const fraction = Math.round((absolute - whole) * 100);

  // Rounding the fraction can carry into the rupees — 99.999 must read as
  // "One Hundred", not "Ninety-Nine and One Hundred Paise".
  const carried = fraction === 100;
  const finalWhole = carried ? whole + 1 : whole;
  const finalFraction = carried ? 0 : fraction;

  const words = [
    negative ? 'Minus' : null,
    'Rupees',
    spellWhole(finalWhole),
    finalFraction ? `and ${underHundred(finalFraction)} Paise` : null,
    'Only',
  ].filter(Boolean);

  return words.join(' ');
}
