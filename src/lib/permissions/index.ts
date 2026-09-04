/**
 * Permission checks and field-level redaction.
 *
 * Both halves of spec §47 live here: "can this session do X" and "may this
 * session even see field Y". The second half matters because §10 and §52 require
 * cost and margin to be absent from the API response for a Cashier, not merely
 * hidden by the UI.
 */

import { SENSITIVE_PERMISSIONS, type Permission } from './registry';

export * from './registry';

/** The permissions held by the current session, as resolved server-side. */
export type PermissionSet = ReadonlySet<Permission>;

export function createPermissionSet(codes: readonly string[]): PermissionSet {
  return new Set(codes as readonly Permission[]);
}

/** True when the session holds every listed permission. */
export function can(permissions: PermissionSet, ...required: readonly Permission[]): boolean {
  return required.every((code) => permissions.has(code));
}

/** True when the session holds at least one of the listed permissions. */
export function canAny(permissions: PermissionSet, ...required: readonly Permission[]): boolean {
  return required.some((code) => permissions.has(code));
}

/**
 * Fields that must never reach a client lacking the matching permission.
 *
 * Keyed by field name rather than by shape, so a new module that names its column
 * `gross_margin` is covered the moment it is added to this map — the redaction
 * does not have to be reimplemented per endpoint.
 */
const RESTRICTED_FIELDS: Readonly<Record<string, Permission>> = {
  purchase_cost: 'sales.view_cost',
  purchaseCost: 'sales.view_cost',
  cogs: 'sales.view_cost',
  unit_cost: 'inventory.view_cost',
  unitCost: 'inventory.view_cost',
  cost_price: 'inventory.view_cost',
  costPrice: 'inventory.view_cost',
  stock_value_at_cost: 'inventory.view_cost',
  gross_margin: 'reports.margin.view',
  grossMargin: 'reports.margin.view',
  margin: 'reports.margin.view',
  margin_percent: 'reports.margin.view',
  marginPercent: 'reports.margin.view',
  net_profit: 'reports.profitability.view',
  netProfit: 'reports.profitability.view',
  profit: 'reports.profitability.view',
  finance_commission: 'finance.commission.view',
  financeCommission: 'finance.commission.view',
  internal_commission: 'finance.commission.view',
  // Pay is personal data about a colleague, so it is stripped on the way out
  // exactly as margin is — hidden by the UI is not the same as absent from the
  // response (spec §52).
  basic: 'hr.salary.view',
  hra: 'hr.salary.view',
  gross_earnings: 'hr.salary.view',
  grossEarnings: 'hr.salary.view',
  net_payable: 'hr.salary.view',
  netPayable: 'hr.salary.view',
  cost_to_company: 'hr.salary.view',
  costToCompany: 'hr.salary.view',
  total_deductions: 'hr.salary.view',
  totalDeductions: 'hr.salary.view',
  special_allowance: 'hr.salary.view',
  specialAllowance: 'hr.salary.view',
};

/**
 * Removes restricted fields the session is not allowed to see.
 *
 * Call this at the service boundary, on the way out. Recurses through nested
 * objects and arrays so a redacted field cannot survive inside a related record.
 */
export function scrubRestrictedFields<T>(value: T, permissions: PermissionSet): T {
  return scrub(value, permissions) as T;
}

function scrub(value: unknown, permissions: PermissionSet): unknown {
  if (Array.isArray(value)) {
    return value.map((item) => scrub(item, permissions));
  }

  // Dates, null and primitives pass through untouched.
  if (value === null || typeof value !== 'object' || value instanceof Date) {
    return value;
  }

  const result: Record<string, unknown> = {};
  for (const [key, nested] of Object.entries(value as Record<string, unknown>)) {
    const required = RESTRICTED_FIELDS[key];
    if (required && !permissions.has(required)) {
      continue;
    }
    result[key] = scrub(nested, permissions);
  }
  return result;
}

/** The sensitive permissions this session holds — useful for shaping a response. */
export function heldSensitivePermissions(permissions: PermissionSet): readonly Permission[] {
  return SENSITIVE_PERMISSIONS.filter((code) => permissions.has(code));
}
