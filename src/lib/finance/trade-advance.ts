/**
 * Trade advance vocabulary — spec §26.
 *
 * Deliberately outside the service. The form needs these at runtime to build its
 * type selector, and the service is `server-only`; importing values from it into
 * a client component drags `next/headers` into the browser bundle and the build
 * fails. Types alone would be erased, but these are real values.
 */

export const TRADE_ADVANCE_TYPES = [
  'ADVANCE_RECEIVED',
  'VEHICLE_ADJUSTMENT',
  'SETTLEMENT',
  'REFUND',
  'COMMISSION',
  'MANUAL_ADJUSTMENT',
] as const;

export type TradeAdvanceType = (typeof TRADE_ADVANCE_TYPES)[number];

/**
 * The types that move real money, and therefore need the bank account it moved
 * through — the database refuses them without one.
 */
export const BANK_BACKED_TYPES: readonly TradeAdvanceType[] = [
  'ADVANCE_RECEIVED',
  'SETTLEMENT',
  'REFUND',
];
