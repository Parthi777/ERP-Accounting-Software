/**
 * Money.
 *
 * Amounts are held as integer paise, never as floating-point rupees. `0.1 + 0.2`
 * is not `0.3` in IEEE-754, and an ERP that adds thousands of invoice lines that
 * way will produce a trial balance that does not balance (spec §60.25).
 *
 * The database stores `numeric(18,4)`, which is exact. Postgres returns numerics
 * to the JS client as strings for the same reason; `fromDb` parses that string
 * digit by digit rather than via `parseFloat`, so no precision is lost in transit.
 */

/** An amount in paise. 1 rupee = 100 paise. */
export type Paise = number & { readonly __brand: 'Paise' };

const PAISE_PER_RUPEE = 100;
/** 2^53 - 1 paise ≈ ₹90,071,992,547,409 — comfortably beyond any dealer's ledger. */
const MAX_SAFE_PAISE = Number.MAX_SAFE_INTEGER;

export const ZERO = 0 as Paise;

function assertSafe(value: number, context: string): void {
  if (!Number.isFinite(value)) {
    throw new RangeError(`${context}: amount is not a finite number.`);
  }
  if (!Number.isInteger(value)) {
    throw new RangeError(`${context}: amount must be a whole number of paise, got ${value}.`);
  }
  if (Math.abs(value) > MAX_SAFE_PAISE) {
    throw new RangeError(`${context}: amount exceeds safe integer range.`);
  }
}

/** Builds a Paise value from a whole number of paise. */
export function paise(value: number): Paise {
  assertSafe(value, 'paise()');
  return value as Paise;
}

/**
 * Converts rupees to paise, rounding half away from zero.
 *
 * Use only at the boundary — parsing a form field or an imported spreadsheet.
 * Internal arithmetic stays in paise.
 */
export function fromRupees(rupees: number): Paise {
  if (!Number.isFinite(rupees)) {
    throw new RangeError('fromRupees(): value is not a finite number.');
  }
  const scaled = rupees * PAISE_PER_RUPEE;
  const rounded = scaled < 0 ? -Math.round(-scaled) : Math.round(scaled);
  assertSafe(rounded, 'fromRupees()');
  return rounded as Paise;
}

/**
 * Parses a decimal string into paise without going through a float.
 *
 * Accepts what Postgres returns for `numeric` ("84000.0000"), what a user types
 * ("1,25,000.50"), and a plain integer string. Rounds half away from zero at two
 * decimal places.
 */
export function fromDb(value: string | number | null | undefined): Paise {
  if (value === null || value === undefined || value === '') {
    return ZERO;
  }
  if (typeof value === 'number') {
    return fromRupees(value);
  }

  const cleaned = value.replace(/[,\s₹]/g, '');
  const match = /^(-)?(\d*)(?:\.(\d*))?$/.exec(cleaned);
  if (!match) {
    throw new RangeError(`fromDb(): cannot parse ${JSON.stringify(value)} as an amount.`);
  }

  const [, sign, whole = '', fraction = ''] = match;
  const rupees = whole === '' ? 0n : BigInt(whole);

  // Two paise digits, with the third used only to decide rounding.
  const padded = `${fraction}000`.slice(0, 3);
  const paiseDigits = BigInt(padded.slice(0, 2));
  const roundUp = Number(padded[2]) >= 5;

  let total = rupees * BigInt(PAISE_PER_RUPEE) + paiseDigits + (roundUp ? 1n : 0n);
  if (sign === '-') {
    total = -total;
  }

  const asNumber = Number(total);
  assertSafe(asNumber, 'fromDb()');
  return asNumber as Paise;
}

/** Renders paise as the exact decimal string the database column expects. */
export function toDb(value: Paise): string {
  const negative = value < 0;
  const absolute = Math.abs(value);
  const rupees = Math.trunc(absolute / PAISE_PER_RUPEE);
  const remainder = absolute % PAISE_PER_RUPEE;
  return `${negative ? '-' : ''}${rupees}.${String(remainder).padStart(2, '0')}`;
}

/** Paise as a rupee number. For display and charts only — never for arithmetic. */
export function toRupees(value: Paise): number {
  return value / PAISE_PER_RUPEE;
}

// ─────────────────────────────────────────────────────────────────────────────
// Arithmetic
// ─────────────────────────────────────────────────────────────────────────────

export function add(...values: readonly Paise[]): Paise {
  const total = values.reduce<number>((sum, value) => sum + value, 0);
  assertSafe(total, 'add()');
  return total as Paise;
}

export function subtract(a: Paise, b: Paise): Paise {
  const result = a - b;
  assertSafe(result, 'subtract()');
  return result as Paise;
}

export function negate(value: Paise): Paise {
  return -value as Paise;
}

/** Multiplies by a whole quantity — line amount from a unit rate. */
export function multiply(value: Paise, quantity: number): Paise {
  if (!Number.isInteger(quantity)) {
    throw new RangeError('multiply(): quantity must be a whole number. Use applyRate for fractions.');
  }
  const result = value * quantity;
  assertSafe(result, 'multiply()');
  return result as Paise;
}

/**
 * Applies a fractional rate, rounding half away from zero.
 *
 * This is the GST primitive: `applyRate(taxable, 0.09)` for a 9% CGST component.
 * Rounding happens once, here, so a tax total is never the sum of independently
 * rounded halves.
 */
export function applyRate(value: Paise, rate: number): Paise {
  if (!Number.isFinite(rate)) {
    throw new RangeError('applyRate(): rate is not a finite number.');
  }
  const scaled = value * rate;
  const rounded = scaled < 0 ? -Math.round(-scaled) : Math.round(scaled);
  assertSafe(rounded, 'applyRate()');
  return rounded as Paise;
}

/** Percentage of `part` in `whole`, or null when `whole` is zero. */
export function percentageOf(part: Paise, whole: Paise): number | null {
  if (whole === 0) {
    return null;
  }
  return (part / whole) * 100;
}

/**
 * Splits an amount into `count` parts that sum exactly back to the original.
 *
 * The remainder is distributed one paisa at a time across the leading parts, so
 * splitting ₹100 three ways gives 33.34 / 33.33 / 33.33 rather than losing a paisa.
 */
export function allocate(value: Paise, count: number): Paise[] {
  if (!Number.isInteger(count) || count <= 0) {
    throw new RangeError('allocate(): count must be a positive whole number.');
  }
  const base = Math.trunc(value / count);
  const remainder = value - base * count;
  const step = remainder < 0 ? -1 : 1;
  let left = Math.abs(remainder);

  return Array.from({ length: count }, () => {
    const extra = left > 0 ? step : 0;
    if (left > 0) {
      left -= 1;
    }
    return (base + extra) as Paise;
  });
}

export function isZero(value: Paise): boolean {
  return value === 0;
}

export function compare(a: Paise, b: Paise): -1 | 0 | 1 {
  return a < b ? -1 : a > b ? 1 : 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// Formatting — Indian digit grouping (spec §51)
// ─────────────────────────────────────────────────────────────────────────────

const INR_FORMATTER = new Intl.NumberFormat('en-IN', {
  style: 'currency',
  currency: 'INR',
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

const INR_COMPACT_FORMATTER = new Intl.NumberFormat('en-IN', {
  style: 'currency',
  currency: 'INR',
  minimumFractionDigits: 0,
  maximumFractionDigits: 0,
});

/** `₹1,25,000.00` — lakh/crore grouping, two decimals. */
export function formatINR(value: Paise): string {
  return INR_FORMATTER.format(toRupees(value));
}

/** `₹1,25,000` — no decimals, for KPI tiles where paise are noise. */
export function formatINRWhole(value: Paise): string {
  return INR_COMPACT_FORMATTER.format(toRupees(value));
}

/**
 * `₹3.28 Cr` / `₹26.75 L` — for dashboard tiles where the full number would not
 * fit. Falls back to the whole-rupee format below a lakh.
 */
export function formatINRShort(value: Paise): string {
  const rupees = toRupees(value);
  const absolute = Math.abs(rupees);
  const sign = rupees < 0 ? '-' : '';

  if (absolute >= 10_000_000) {
    return `${sign}₹${(absolute / 10_000_000).toFixed(2)} Cr`;
  }
  if (absolute >= 100_000) {
    return `${sign}₹${(absolute / 100_000).toFixed(2)} L`;
  }
  return INR_COMPACT_FORMATTER.format(rupees);
}
