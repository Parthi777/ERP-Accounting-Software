import 'server-only';

import { add, subtract, formatINR, formatINRShort, percentageOf, ZERO, type Paise } from '@/lib/money';
import { type Permission } from '@/lib/permissions';
import {
  getAccountBalances,
  getDailyRevenue,
  type LedgerBalance,
} from '@/server/repositories/ledger-repository';
import { requirePermission, type TenantContext } from '@/server/auth/tenant-context';

/**
 * Dashboard KPIs — spec §10, §43.
 *
 * Two honesty rules govern this file:
 *
 *  1. Every figure marked `ready` is computed from posted double-entry journals
 *     through `account_balances()`. Nothing is invented to fill a card.
 *  2. A KPI whose source module is not built yet reports `awaiting_module` with
 *     no value at all. Spec §61 is explicit that fake accounting behaviour must
 *     not be used to make the UI look finished — a card that says "Phase 4"
 *     is more useful than a plausible number that means nothing.
 *
 * Unit counts (vehicles sold, bookings taken, deliveries made) genuinely cannot
 * come from a ledger — a journal records value, not units — so they wait for the
 * sales, booking and inventory modules. Value KPIs come from the ledger today.
 */

export type KpiStatus = 'ready' | 'awaiting_module';
export type KpiFormat = 'currency' | 'currency_short' | 'number' | 'percent';

export interface Kpi {
  readonly key: string;
  readonly label: string;
  readonly status: KpiStatus;
  /** Rendered text. Absent when the module has not been built. */
  readonly display: string | null;
  readonly raw: number | null;
  readonly format: KpiFormat;
  /** Development phase from spec §56 that will deliver this figure. */
  readonly phase?: number;
  readonly note?: string;
  /** Cost/margin/profit figures, withheld unless the session holds the permission. */
  readonly sensitive?: boolean;
}

export interface DashboardData {
  readonly period: { readonly from: string; readonly to: string; readonly label: string };
  readonly branchLabel: string;
  readonly primary: readonly Kpi[];
  readonly secondary: readonly Kpi[];
  readonly financial: readonly Kpi[];
  readonly margin: readonly Kpi[];
  readonly revenueTrend: readonly { readonly date: string; readonly amount: number }[];
  readonly revenueMix: readonly { readonly label: string; readonly amount: number }[];
  readonly canSeeMargin: boolean;
  readonly ledgerHasData: boolean;
}

// Account codes seeded by supabase/seed.sql. Referenced by code rather than by id
// so no account UUID is ever hard-coded in application logic (spec §22).
const ACCOUNTS = {
  cash: '1100',
  bank: '1200',
  customerReceivable: '1300',
  financeReceivable: '1400',
  vehicleStock: '1500',
  accessoryStock: '1600',
  spareStock: '1700',
  customerAdvances: '2100',
  supplierPayables: '2200',
  financePayable: '2600',
  otherPayables: '2700',
  vehicleSales: '4100',
  accessorySales: '4200',
  spareSales: '4300',
  serviceLabour: '4400',
  financeCommission: '4500',
  insuranceCommission: '4600',
  forwardingIncome: '4700',
  vehicleCogs: '5100',
  accessoryCogs: '5200',
  spareCogs: '5300',
  serviceCost: '5400',
} as const;

const REVENUE_CODES = [
  ACCOUNTS.vehicleSales,
  ACCOUNTS.accessorySales,
  ACCOUNTS.spareSales,
  ACCOUNTS.serviceLabour,
];

export interface DashboardQuery {
  readonly from: string;
  readonly to: string;
  /** null means "all branches I can see" — the consolidated view (spec §43). */
  readonly branchId: string | null;
}

export async function getDashboard(query: DashboardQuery): Promise<DashboardData> {
  const context = await requirePermission('dashboard.view');
  const canSeeMargin = context.permissions.has('dashboard.view_margin' satisfies Permission);

  const period = { from: query.from, to: query.to, branchId: resolveBranch(context, query.branchId) };

  const [balances, trend] = await Promise.all([
    getAccountBalances(period),
    getDailyRevenue(period, REVENUE_CODES),
  ]);

  const byCode = new Map(balances.map((balance) => [balance.code, balance]));
  const closing = (code: string): Paise => byCode.get(code)?.closingBalance ?? ZERO;
  const movement = (code: string): Paise => byCode.get(code)?.periodMovement ?? ZERO;

  const ledgerHasData = balances.some((b) => b.closingBalance !== 0 || b.periodMovement !== 0);

  const vehicleRevenue = movement(ACCOUNTS.vehicleSales);
  const accessoryRevenue = movement(ACCOUNTS.accessorySales);
  const spareRevenue = movement(ACCOUNTS.spareSales);
  const serviceRevenue = movement(ACCOUNTS.serviceLabour);

  const vehicleCogs = movement(ACCOUNTS.vehicleCogs);
  const accessoryCogs = movement(ACCOUNTS.accessoryCogs);
  const spareCogs = movement(ACCOUNTS.spareCogs);
  const serviceCost = movement(ACCOUNTS.serviceCost);

  const totalRevenue = add(vehicleRevenue, accessoryRevenue, spareRevenue, serviceRevenue);
  const totalCogs = add(vehicleCogs, accessoryCogs, spareCogs, serviceCost);
  const grossMargin = subtract(totalRevenue, totalCogs);

  const totalIncome = sumByType(balances, 'INCOME', 'period');
  const totalExpense = sumByType(balances, 'EXPENSE', 'period');
  const netProfit = subtract(totalIncome, totalExpense);

  // ── Row 1: the six headline cards from the mockup ─────────────────────────
  const primary: Kpi[] = [
    awaiting('vehicle_sales_units', 'Vehicle Sales', 'number', 4,
      'Unit counts arrive with the vehicle sales module.'),
    ready('vehicle_sales_value', 'Vehicle Sales Value', vehicleRevenue, 'currency_short'),
    awaiting('bookings', 'Bookings', 'number', 4, 'Booking counts arrive with the booking module.'),
    ready('booking_advance', 'Booking Advance', closing(ACCOUNTS.customerAdvances), 'currency_short'),
    awaiting('deliveries', 'Deliveries', 'number', 4, 'Delivery counts arrive with the sales module.'),
    ready('service_revenue', 'Service Revenue', serviceRevenue, 'currency_short'),
  ];

  // ── Row 2: stock and finance ──────────────────────────────────────────────
  const secondary: Kpi[] = [
    awaiting('vehicle_stock_qty', 'Vehicle Stock (Qty)', 'number', 2,
      'Chassis-level stock arrives with the vehicle inventory module.'),
    ready('vehicle_stock_value', 'Vehicle Stock Value', closing(ACCOUNTS.vehicleStock), 'currency_short'),
    awaiting('accessory_stock_qty', 'Accessories Stock (Qty)', 'number', 3,
      'Item-level stock arrives with the inventory module.'),
    ready('accessory_stock_value', 'Accessories Stock Value', closing(ACCOUNTS.accessoryStock), 'currency_short'),
    awaiting('spare_stock_qty', 'Spare Stock (Qty)', 'number', 3,
      'Item-level stock arrives with the inventory module.'),
    ready('spare_stock_value', 'Spare Stock Value', closing(ACCOUNTS.spareStock), 'currency_short'),
    awaiting('finance_units', 'Finance Units', 'number', 4,
      'Finance unit counts arrive with the HP sales module.'),
    ready('finance_amount', 'Finance Amount', closing(ACCOUNTS.financeReceivable), 'currency_short'),
  ];

  // ── Row 3: cash, bank and working capital ─────────────────────────────────
  const payables = add(
    closing(ACCOUNTS.supplierPayables),
    closing(ACCOUNTS.financePayable),
    closing(ACCOUNTS.otherPayables),
  );

  const financial: Kpi[] = [
    ready('cash_balance', 'Cash in Hand', closing(ACCOUNTS.cash), 'currency'),
    ready('bank_balance', 'Bank Balance', closing(ACCOUNTS.bank), 'currency'),
    ready('receivables', 'Receivables', closing(ACCOUNTS.customerReceivable), 'currency'),
    ready('payables', 'Payables', payables, 'currency'),
  ];

  // ── Owner / Accounts only (spec §10) ──────────────────────────────────────
  // Built only when the permission is held, so the figures are absent from the
  // payload rather than hidden in the browser (spec §52).
  const margin: Kpi[] = canSeeMargin
    ? [
        sensitive('gross_margin', 'Gross Margin', grossMargin, 'currency_short'),
        sensitive('margin_percent', 'Margin %', percentageOf(grossMargin, totalRevenue), 'percent'),
        sensitive('vehicle_margin', 'Vehicle Margin', subtract(vehicleRevenue, vehicleCogs), 'currency_short'),
        sensitive('accessory_margin', 'Accessories Margin', subtract(accessoryRevenue, accessoryCogs), 'currency_short'),
        sensitive('spare_margin', 'Spare Margin', subtract(spareRevenue, spareCogs), 'currency_short'),
        sensitive('service_margin', 'Service Margin', subtract(serviceRevenue, serviceCost), 'currency_short'),
        sensitive('finance_commission', 'Finance Commission', movement(ACCOUNTS.financeCommission), 'currency_short'),
        sensitive('insurance_income', 'Insurance Income', movement(ACCOUNTS.insuranceCommission), 'currency_short'),
        sensitive('forwarding_income', 'Forwarding Income', movement(ACCOUNTS.forwardingIncome), 'currency_short'),
        sensitive('net_profit', 'Net Profit', netProfit, 'currency_short'),
      ]
    : [];

  return {
    period: { from: query.from, to: query.to, label: '' },
    branchLabel: branchLabel(context, period.branchId),
    primary,
    secondary,
    financial,
    margin,
    revenueTrend: trend.map((point) => ({ date: point.date, amount: point.amount })),
    revenueMix: [
      { label: 'Vehicles', amount: vehicleRevenue },
      { label: 'Accessories', amount: accessoryRevenue },
      { label: 'Spares', amount: spareRevenue },
      { label: 'Service', amount: serviceRevenue },
    ].filter((slice) => slice.amount > 0),
    canSeeMargin,
    ledgerHasData,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

function ready(key: string, label: string, value: Paise, format: KpiFormat): Kpi {
  return { key, label, status: 'ready', display: render(value, format), raw: value, format };
}

function sensitive(
  key: string,
  label: string,
  value: Paise | number | null,
  format: KpiFormat,
): Kpi {
  if (value === null) {
    return { key, label, status: 'ready', display: '—', raw: null, format, sensitive: true };
  }
  return {
    key,
    label,
    status: 'ready',
    display: format === 'percent' ? `${value.toFixed(2)}%` : render(value as Paise, format),
    raw: value,
    format,
    sensitive: true,
  };
}

function awaiting(key: string, label: string, format: KpiFormat, phase: number, note: string): Kpi {
  return { key, label, status: 'awaiting_module', display: null, raw: null, format, phase, note };
}

function render(value: Paise, format: KpiFormat): string {
  return format === 'currency_short' ? formatINRShort(value) : formatINR(value);
}

function sumByType(
  balances: readonly LedgerBalance[],
  type: LedgerBalance['type'],
  which: 'period' | 'closing',
): Paise {
  const total = balances
    .filter((balance) => balance.type === type)
    .reduce<number>(
      (sum, balance) => sum + (which === 'period' ? balance.periodMovement : balance.closingBalance),
      0,
    );
  return total as Paise;
}

/**
 * Resolves the branch filter against what the session may actually see.
 * A branch id the user has no access to is ignored rather than honoured (§47) —
 * and RLS would filter the rows out regardless.
 */
function resolveBranch(context: TenantContext, requested: string | null): string | null {
  if (!requested) {
    // Users without all-branch access are pinned to their active branch.
    return context.hasAllBranchAccess ? null : (context.activeBranch?.id ?? null);
  }
  const allowed = context.accessibleBranches.some((branch) => branch.id === requested);
  return allowed ? requested : (context.activeBranch?.id ?? null);
}

function branchLabel(context: TenantContext, branchId: string | null): string {
  if (!branchId) {
    return 'All Branches';
  }
  return context.accessibleBranches.find((branch) => branch.id === branchId)?.name ?? 'All Branches';
}
