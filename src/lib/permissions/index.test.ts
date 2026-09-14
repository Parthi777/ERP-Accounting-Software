import { describe, expect, it } from 'vitest';

import { can, canAny, createPermissionSet, heldSensitivePermissions, scrubRestrictedFields } from './index';

/**
 * Redaction is the last thing standing between a cashier's browser and the
 * dealer's purchase costs (spec §52). Its failure mode is silent — a leaked
 * field looks exactly like a working response — so these assertions test the
 * property that matters rather than the happy path.
 */

const cashier = createPermissionSet(['sales.view', 'customers.view']);
const accounts = createPermissionSet([
  'sales.view_cost',
  'dashboard.view_margin',
  'finance.commission.view',
  'hr.salary.view',
  'reports.margin.view',
]);

describe('scrubRestrictedFields', () => {
  /**
   * `toBeUndefined()` would pass against an implementation that sets the key to
   * undefined — and `JSON.stringify` drops undefined, so it would even look
   * right over the wire until something serialised differently. The field has to
   * be *absent*.
   */
  it('removes the key entirely, not merely its value', () => {
    const scrubbed = scrubRestrictedFields({ id: 'x', purchase_cost: 84000 }, cashier);

    expect(Object.hasOwn(scrubbed, 'purchase_cost')).toBe(false);
    expect(Object.keys(scrubbed)).toEqual(['id']);
  });

  it('keeps restricted fields for a session that holds the permission', () => {
    const scrubbed = scrubRestrictedFields({ id: 'x', purchase_cost: 84000 }, accounts);
    expect(scrubbed).toEqual({ id: 'x', purchase_cost: 84000 });
  });

  it('recurses into nested objects, so a cost cannot hide inside a related record', () => {
    const scrubbed = scrubRestrictedFields(
      { id: 'sale', vehicle: { chassis_no: 'ABC', purchase_cost: 84000 } },
      cashier,
    );
    expect(Object.hasOwn(scrubbed.vehicle, 'purchase_cost')).toBe(false);
    expect(scrubbed.vehicle.chassis_no).toBe('ABC');
  });

  it('recurses into arrays, including arrays of nested objects', () => {
    const scrubbed = scrubRestrictedFields(
      { lines: [{ description: 'a', unit_cost: 100 }, { description: 'b', unit_cost: 200 }] },
      cashier,
    );
    expect(scrubbed.lines).toHaveLength(2);
    for (const line of scrubbed.lines) {
      expect(Object.hasOwn(line, 'unit_cost')).toBe(false);
      expect(line.description).toBeTypeOf('string');
    }
  });

  it('covers both casings, since PostgREST and the service layer disagree', () => {
    const scrubbed = scrubRestrictedFields(
      { gross_margin: 1, grossMargin: 1, net_profit: 1, netProfit: 1 },
      cashier,
    );
    expect(Object.keys(scrubbed)).toEqual([]);
  });

  /** A Date reaching the client as `{}` would be a subtler bug than a leak. */
  it('passes dates, nulls and primitives through untouched', () => {
    const when = new Date('2026-04-01T00:00:00Z');
    const scrubbed = scrubRestrictedFields(
      { created_at: when, notes: null, count: 3, ok: true },
      cashier,
    );
    expect(scrubbed.created_at).toBeInstanceOf(Date);
    expect(scrubbed.created_at.toISOString()).toBe(when.toISOString());
    expect(scrubbed.notes).toBeNull();
    expect(scrubbed.count).toBe(3);
    expect(scrubbed.ok).toBe(true);
  });

  /**
   * The lookup is a plain object, so an unguarded `RESTRICTED_FIELDS[key]`
   * resolves through Object.prototype: a payload key called `constructor` or
   * `toString` returns a *function*, which is truthy, fails the permission
   * check, and silently drops the field — for every session, whatever they
   * hold.
   *
   * No column is named that today. But the failure would be invisible, would
   * affect privileged sessions too, and the guard costs one call.
   */
  it('does not treat inherited Object keys as restricted', () => {
    const payload = {
      constructor: 'Maruti',
      toString: 'ABC-123',
      valueOf: 7,
      hasOwnProperty: 'yes',
      keep: 'me',
    };

    for (const set of [cashier, accounts]) {
      const scrubbed = scrubRestrictedFields(payload, set);
      expect(Object.keys(scrubbed).sort()).toEqual(
        ['constructor', 'hasOwnProperty', 'keep', 'toString', 'valueOf'].sort(),
      );
    }
  });

  it('handles an empty object and an empty array', () => {
    expect(scrubRestrictedFields({}, cashier)).toEqual({});
    expect(scrubRestrictedFields([], cashier)).toEqual([]);
  });

  it('scrubs a top-level array of records', () => {
    const scrubbed = scrubRestrictedFields([{ id: 1, gross_margin: 5 }], cashier);
    expect(scrubbed).toHaveLength(1);
    expect(Object.hasOwn(scrubbed[0]!, 'gross_margin')).toBe(false);
    expect(scrubbed[0]!.id).toBe(1);
  });
});

describe('can', () => {
  it('requires every listed permission', () => {
    expect(can(accounts, 'sales.view_cost', 'dashboard.view_margin')).toBe(true);
    expect(can(cashier, 'sales.view', 'sales.view_cost')).toBe(false);
  });

  /**
   * Pinned deliberately: a call site spreading an empty array — `can(set, ...codes)`
   * where `codes` came back empty — allows everything. That is the correct reading
   * of "holds every listed permission", and it is worth having written down so a
   * future caller does not discover it by accident.
   */
  it('is vacuously true with no required codes', () => {
    expect(can(cashier)).toBe(true);
  });

  it('canAny needs only one', () => {
    expect(canAny(cashier, 'sales.view_cost', 'sales.view')).toBe(true);
    expect(canAny(cashier, 'sales.view_cost')).toBe(false);
    expect(canAny(cashier)).toBe(false);
  });
});

describe('heldSensitivePermissions', () => {
  it('reports only what the session actually holds', () => {
    expect(heldSensitivePermissions(cashier)).toEqual([]);
    expect(heldSensitivePermissions(accounts)).toContain('sales.view_cost');
  });
});
