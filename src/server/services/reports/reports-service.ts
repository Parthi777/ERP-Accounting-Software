import 'server-only';

import { requirePermission, type TenantContext } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { scrubRestrictedFields } from '@/lib/permissions';
import { fromDb, type Paise } from '@/lib/money';

/**
 * MIS reporting — spec §41, §43.
 *
 * Every figure is derived from posted documents, so a report can only be wrong if
 * the transactions behind it are.
 *
 * Cost and margin leave this layer through `scrubRestrictedFields()`. Spec §10
 * and §52 want those withheld from the *response*, not merely hidden in the UI:
 * a Cashier who opens dev tools must not find the dealership's margin sitting in
 * a payload. Hence the fields are named `cost` and `margin`, which is what the
 * redaction map keys on.
 */

export interface SalesSummaryRow {
  readonly groupKey: string;
  readonly groupLabel: string;
  readonly units: number;
  readonly gross: Paise;
  readonly tax: Paise;
  readonly cost?: Paise;
  readonly margin?: Paise;
}

export interface FinanceSummaryRow {
  readonly financeCompanyId: string;
  readonly financeCompanyName: string;
  readonly applications: number;
  readonly approved: number;
  readonly rejected: number;
  readonly pending: number;
  readonly loanAmount: Paise;
  readonly disbursed: Paise;
  readonly pendingDisbursement: Paise;
  readonly financeCommission?: Paise;
}

export interface BranchPerformanceRow {
  readonly branchId: string;
  readonly branchCode: string;
  readonly branchName: string;
  readonly vehicleUnits: number;
  readonly vehicleRevenue: Paise;
  readonly cost?: Paise;
  readonly margin?: Paise;
  readonly serviceJobs: number;
  readonly serviceRevenue: Paise;
  readonly bookingsOpen: number;
  readonly bookingAdvances: Paise;
  readonly cashInHand: Paise;
  readonly receivables: Paise;
}

export interface MarginRow {
  readonly stream: string;
  readonly documents: number;
  readonly revenue: Paise;
  readonly cost: Paise;
  readonly margin: Paise;
  readonly marginPercent: number;
}

export interface ConsolidatedRow {
  readonly metric: string;
  readonly category: string;
  readonly value: Paise;
  readonly count: number;
}

export interface VehicleStockRow {
  readonly vehicleId: string;
  readonly chassisNo: string;
  readonly brand: string;
  readonly modelName: string;
  readonly variantName: string | null;
  readonly branchName: string;
  readonly status: string;
  readonly stockDate: string;
  readonly ageDays: number;
  readonly ageBucket: string;
  readonly purchaseCost?: Paise;
}

export interface InventoryStockRow {
  readonly itemId: string;
  readonly itemCode: string;
  readonly itemName: string;
  readonly itemType: string;
  readonly branchName: string;
  readonly localQty: number;
  readonly companyQty: number;
  readonly totalQty: number;
  readonly totalValue: Paise;
}

export interface InventoryMovementRow {
  readonly itemId: string;
  readonly itemCode: string;
  readonly itemName: string;
  readonly itemType: string;
  readonly receivedQty: number;
  readonly issuedQty: number;
  readonly receivedValue: Paise;
  readonly issuedValue: Paise;
  readonly closingQty: number;
  readonly closingValue: Paise;
}

function resolveBranch(context: TenantContext, requested?: string | null): string | null {
  if (requested && requested !== 'ALL' && context.accessibleBranches.some((b) => b.id === requested)) {
    return requested;
  }
  // A user without all-branch access sees their own branch whatever they ask for.
  return context.hasAllBranchAccess ? null : (context.activeBranch?.id ?? null);
}

export async function getSalesSummary(params: {
  readonly from: string;
  readonly to: string;
  readonly groupBy: string;
  readonly branchId?: string | null;
}): Promise<SalesSummaryRow[]> {
  const context = await requirePermission('reports.sales.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('sales_summary', {
    p_from: params.from,
    p_to: params.to,
    p_branch_id: resolveBranch(context, params.branchId),
    p_group_by: params.groupBy,
  });

  if (error) {
    throw new Error(`Failed to load the sales report: ${error.message}`);
  }

  const rows: SalesSummaryRow[] = (data ?? []).map((row) => ({
    groupKey: row.group_key,
    groupLabel: row.group_label,
    units: Number(row.unit_count),
    gross: fromDb(row.gross_amount),
    tax: fromDb(row.tax_amount),
    cost: fromDb(row.cost_amount),
    margin: fromDb(row.margin),
  }));

  return scrubRestrictedFields(rows, context.permissions);
}

export async function getFinanceSummary(params: {
  readonly from: string;
  readonly to: string;
  readonly branchId?: string | null;
}): Promise<FinanceSummaryRow[]> {
  const context = await requirePermission('reports.finance.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('finance_summary', {
    p_from: params.from,
    p_to: params.to,
    p_branch_id: resolveBranch(context, params.branchId),
  });

  if (error) {
    throw new Error(`Failed to load the finance report: ${error.message}`);
  }

  const rows: FinanceSummaryRow[] = (data ?? []).map((row) => ({
    financeCompanyId: row.finance_company_id,
    financeCompanyName: row.finance_company_name,
    applications: Number(row.application_count),
    approved: Number(row.approved_count),
    rejected: Number(row.rejected_count),
    pending: Number(row.pending_count),
    loanAmount: fromDb(row.loan_amount),
    disbursed: fromDb(row.disbursed_amount),
    pendingDisbursement: fromDb(row.pending_disbursement),
    financeCommission: fromDb(row.commission_amount),
  }));

  return scrubRestrictedFields(rows, context.permissions);
}

export async function getBranchPerformance(params: {
  readonly from: string;
  readonly to: string;
}): Promise<BranchPerformanceRow[]> {
  const context = await requirePermission('reports.branch_performance.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('branch_performance', {
    p_from: params.from,
    p_to: params.to,
  });

  if (error) {
    throw new Error(`Failed to load branch performance: ${error.message}`);
  }

  const rows: BranchPerformanceRow[] = (data ?? [])
    .filter(
      // RLS scopes the branches table, but the report joins outward from it, so
      // a user without all-branch access is narrowed here too.
      (row) => context.hasAllBranchAccess || context.accessibleBranches.some((b) => b.id === row.branch_id),
    )
    .map((row) => ({
      branchId: row.branch_id,
      branchCode: row.branch_code,
      branchName: row.branch_name,
      vehicleUnits: Number(row.vehicle_units),
      vehicleRevenue: fromDb(row.vehicle_revenue),
      cost: fromDb(row.vehicle_cost),
      margin: fromDb(row.vehicle_margin),
      serviceJobs: Number(row.service_jobs),
      serviceRevenue: fromDb(row.service_revenue),
      bookingsOpen: Number(row.bookings_open),
      bookingAdvances: fromDb(row.booking_advances),
      cashInHand: fromDb(row.cash_in_hand),
      receivables: fromDb(row.receivables),
    }));

  return scrubRestrictedFields(rows, context.permissions);
}

export async function getMarginReport(params: {
  readonly from: string;
  readonly to: string;
  readonly branchId?: string | null;
}): Promise<MarginRow[]> {
  // The permission is the gate: without it this function is never reached, so
  // the margin columns below are safe to return in full.
  const context = await requirePermission('reports.margin.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('margin_report', {
    p_from: params.from,
    p_to: params.to,
    p_branch_id: resolveBranch(context, params.branchId),
  });

  if (error) {
    throw new Error(`Failed to load the margin report: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    stream: row.stream,
    documents: Number(row.document_count),
    revenue: fromDb(row.revenue),
    cost: fromDb(row.cost),
    margin: fromDb(row.margin),
    marginPercent: Number(row.margin_percent),
  }));
}

export async function getConsolidatedMis(params: {
  readonly from: string;
  readonly to: string;
}): Promise<ConsolidatedRow[]> {
  await requirePermission('reports.consolidated.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('consolidated_mis', {
    p_from: params.from,
    p_to: params.to,
  });

  if (error) {
    throw new Error(`Failed to load the consolidated MIS: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    metric: row.metric,
    category: row.category,
    value: fromDb(row.value),
    count: Number(row.count_value),
  }));
}

export async function getVehicleStockReport(params: {
  readonly branchId?: string | null;
  readonly status?: string | null;
}): Promise<VehicleStockRow[]> {
  const context = await requirePermission('reports.inventory.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('vehicle_stock_report', {
    p_branch_id: resolveBranch(context, params.branchId),
    p_status: params.status && params.status !== 'ALL' ? params.status : null,
  });

  if (error) {
    throw new Error(`Failed to load the vehicle stock report: ${error.message}`);
  }

  const rows: VehicleStockRow[] = (data ?? []).map((row) => ({
    vehicleId: row.vehicle_id,
    chassisNo: row.chassis_no,
    brand: row.brand,
    modelName: row.model_name,
    variantName: row.variant_name,
    branchName: row.branch_name,
    status: row.status,
    stockDate: row.stock_date,
    ageDays: Number(row.age_days),
    ageBucket: row.age_bucket,
    purchaseCost: fromDb(row.purchase_cost),
  }));

  return scrubRestrictedFields(rows, context.permissions);
}

export async function getInventoryStockReport(params: {
  readonly branchId?: string | null;
  readonly itemType?: string | null;
}): Promise<InventoryStockRow[]> {
  const context = await requirePermission('reports.inventory.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('inventory_stock_report', {
    p_branch_id: resolveBranch(context, params.branchId),
    p_item_type: params.itemType && params.itemType !== 'ALL' ? params.itemType : null,
  });

  if (error) {
    throw new Error(`Failed to load the inventory report: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    itemId: row.item_id,
    itemCode: row.item_code,
    itemName: row.item_name,
    itemType: row.item_type,
    branchName: row.branch_name,
    localQty: Number(row.local_qty),
    companyQty: Number(row.company_qty),
    totalQty: Number(row.total_qty),
    totalValue: fromDb(row.total_value),
  }));
}

export async function getInventoryMovement(params: {
  readonly from: string;
  readonly to: string;
  readonly branchId?: string | null;
}): Promise<InventoryMovementRow[]> {
  const context = await requirePermission('reports.inventory.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('inventory_movement_report', {
    p_from: params.from,
    p_to: params.to,
    p_branch_id: resolveBranch(context, params.branchId),
  });

  if (error) {
    throw new Error(`Failed to load stock movement: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    itemId: row.item_id,
    itemCode: row.item_code,
    itemName: row.item_name,
    itemType: row.item_type,
    receivedQty: Number(row.received_qty),
    issuedQty: Number(row.issued_qty),
    receivedValue: fromDb(row.received_value),
    issuedValue: fromDb(row.issued_value),
    closingQty: Number(row.closing_qty),
    closingValue: fromDb(row.closing_value),
  }));
}
