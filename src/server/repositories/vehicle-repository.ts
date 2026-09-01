import 'server-only';

import { createSupabaseServerClient } from '@/lib/supabase/server';
import { fromDb, type Paise } from '@/lib/money';
import type { Tables } from '@/types/database.types';

/**
 * Vehicle stock data access.
 *
 * Stock is chassis-level (spec §60.8): every query returns rows, one per physical
 * vehicle, and a count is `rows.length` rather than a quantity column.
 */

export type Vehicle = Tables<'vehicles'>;
export type VehicleStatus = Vehicle['status'];

export interface VehicleListRow {
  readonly id: string;
  readonly chassis_no: string;
  readonly engine_no: string;
  readonly key_no: string | null;
  readonly status: VehicleStatus;
  readonly stock_date: string;
  readonly purchase_cost: Paise;
  readonly purchase_invoice: string | null;
  readonly registration_no: string | null;
  readonly brand: string;
  readonly model_name: string;
  readonly variant_name: string | null;
  readonly branch_name: string;
  readonly age_days: number;
}

export const VEHICLES_PAGE_SIZE = 30;

export interface VehicleListResult {
  readonly rows: readonly VehicleListRow[];
  readonly total: number;
  readonly page: number;
  readonly pageCount: number;
}

export async function listVehicles(params: {
  readonly q?: string;
  readonly status: string;
  readonly branchId: string | null;
  readonly modelId: string | null;
  readonly page: number;
}): Promise<VehicleListResult> {
  const supabase = await createSupabaseServerClient();
  const from = (params.page - 1) * VEHICLES_PAGE_SIZE;

  let query = supabase
    .from('vehicles')
    .select(
      'id, chassis_no, engine_no, key_no, status, stock_date, purchase_cost, purchase_invoice, registration_no, vehicle_models!inner ( brand, name ), vehicle_variants ( name ), branches!inner ( name )',
      { count: 'exact' },
    )
    .order('stock_date', { ascending: true })
    .range(from, from + VEHICLES_PAGE_SIZE - 1);

  if (params.status !== 'ALL') {
    query = query.eq('status', params.status as VehicleStatus);
  }
  if (params.branchId) {
    query = query.eq('branch_id', params.branchId);
  }
  if (params.modelId) {
    query = query.eq('model_id', params.modelId);
  }

  const term = params.q?.trim();
  if (term) {
    // Commas and parentheses are PostgREST filter syntax; strip them from the term.
    const safe = term.replace(/[(),*]/g, ' ').trim();
    if (safe) {
      query = query.or(
        [`chassis_no.ilike.*${safe}*`, `engine_no.ilike.*${safe}*`, `registration_no.ilike.*${safe}*`].join(','),
      );
    }
  }

  const { data, error, count } = await query;
  if (error) {
    throw new Error(`Failed to load vehicle stock: ${error.message}`);
  }

  const today = new Date();
  const total = count ?? 0;

  return {
    rows: (data ?? []).map((row) => ({
      id: row.id,
      chassis_no: row.chassis_no,
      engine_no: row.engine_no,
      key_no: row.key_no,
      status: row.status,
      stock_date: row.stock_date,
      purchase_cost: fromDb(row.purchase_cost),
      purchase_invoice: row.purchase_invoice,
      registration_no: row.registration_no,
      brand: row.vehicle_models.brand,
      model_name: row.vehicle_models.name,
      variant_name: row.vehicle_variants?.name ?? null,
      branch_name: row.branches.name,
      age_days: Math.max(
        0,
        Math.floor((today.getTime() - new Date(row.stock_date).getTime()) / 86_400_000),
      ),
    })),
    total,
    page: params.page,
    pageCount: Math.max(1, Math.ceil(total / VEHICLES_PAGE_SIZE)),
  };
}

export interface VehicleDetail {
  readonly vehicle: Vehicle;
  readonly modelLabel: string;
  readonly variantName: string | null;
  readonly branchName: string;
  readonly movements: readonly {
    readonly id: number;
    readonly type: string;
    readonly fromStatus: string | null;
    readonly toStatus: string | null;
    readonly narration: string | null;
    readonly createdAt: string;
  }[];
}

export async function getVehicle(id: string): Promise<VehicleDetail | null> {
  const supabase = await createSupabaseServerClient();

  const [{ data, error }, { data: movements }] = await Promise.all([
    supabase
      .from('vehicles')
      .select('*, vehicle_models ( brand, name ), vehicle_variants ( name ), branches ( name )')
      .eq('id', id)
      .maybeSingle(),
    supabase
      .from('vehicle_stock_transactions')
      .select('id, transaction_type, from_status, to_status, narration, created_at')
      .eq('vehicle_id', id)
      .order('created_at', { ascending: false }),
  ]);

  if (error) {
    throw new Error(`Failed to load the vehicle: ${error.message}`);
  }
  if (!data) {
    return null;
  }

  const { vehicle_models, vehicle_variants, branches, ...vehicle } = data;

  return {
    vehicle,
    modelLabel: `${vehicle_models.brand} ${vehicle_models.name}`,
    variantName: vehicle_variants?.name ?? null,
    branchName: branches.name,
    movements: (movements ?? []).map((m) => ({
      id: m.id,
      type: m.transaction_type,
      fromStatus: m.from_status,
      toStatus: m.to_status,
      narration: m.narration,
      createdAt: m.created_at,
    })),
  };
}

export interface StockSummary {
  readonly inStock: number;
  readonly booked: number;
  readonly soldPending: number;
  readonly stockValue: Paise;
  readonly ageing: Readonly<Record<string, number>>;
}

export async function getStockSummary(branchId: string | null): Promise<StockSummary> {
  const supabase = await createSupabaseServerClient();

  // The whole stock is one dealer's worth of rows; counting in the application
  // keeps this to a single round trip rather than five counting queries.
  let query = supabase.from('vehicles').select('status, stock_date, purchase_cost');
  if (branchId) {
    query = query.eq('branch_id', branchId);
  }

  const { data, error } = await query;
  if (error) {
    throw new Error(`Failed to summarise stock: ${error.message}`);
  }

  const today = new Date();
  const ageing: Record<string, number> = { '0-30': 0, '31-60': 0, '61-90': 0, '91-180': 0, '180+': 0 };
  let inStock = 0;
  let booked = 0;
  let soldPending = 0;
  let value = 0;

  for (const row of data ?? []) {
    if (row.status === 'IN_STOCK') {
      inStock += 1;
      value += fromDb(row.purchase_cost);
      const days = Math.floor((today.getTime() - new Date(row.stock_date).getTime()) / 86_400_000);
      const bucket = days <= 30 ? '0-30' : days <= 60 ? '31-60' : days <= 90 ? '61-90' : days <= 180 ? '91-180' : '180+';
      ageing[bucket] = (ageing[bucket] ?? 0) + 1;
    } else if (row.status === 'BOOKED') {
      booked += 1;
      value += fromDb(row.purchase_cost);
    } else if (row.status === 'SOLD_PENDING_DELIVERY') {
      soldPending += 1;
    }
  }

  return { inStock, booked, soldPending, stockValue: value as Paise, ageing };
}

/** Chassis and engine numbers already on file, for import duplicate detection. */
export async function getExistingIdentifiers(): Promise<{
  chassis: Set<string>;
  engine: Set<string>;
}> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.from('vehicles').select('chassis_no, engine_no');
  if (error) {
    throw new Error(`Failed to read existing vehicles: ${error.message}`);
  }
  return {
    chassis: new Set((data ?? []).map((r) => r.chassis_no)),
    engine: new Set((data ?? []).map((r) => r.engine_no)),
  };
}

export async function insertVehicles(
  rows: readonly Record<string, unknown>[],
  context: { readonly dealerId: string; readonly userId: string },
): Promise<number> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from('vehicles')
    .insert(
      rows.map((row) => ({ ...row, dealer_id: context.dealerId, created_by: context.userId })) as never,
    )
    .select('id');

  if (error) {
    throw error;
  }
  return data?.length ?? 0;
}

/** Model and variant lookups keyed by code, for resolving import rows. */
export async function getCatalogueLookup(): Promise<{
  models: Map<string, { id: string; label: string }>;
  variants: Map<string, { id: string; modelId: string }>;
  branches: Map<string, string>;
}> {
  const supabase = await createSupabaseServerClient();

  const [models, variants, branches] = await Promise.all([
    supabase.from('vehicle_models').select('id, model_code, brand, name').eq('status', 'ACTIVE'),
    supabase.from('vehicle_variants').select('id, variant_code, model_id').eq('status', 'ACTIVE'),
    supabase.from('branches').select('id, code').eq('status', 'ACTIVE'),
  ]);

  return {
    models: new Map(
      (models.data ?? []).map((m) => [m.model_code.toUpperCase(), { id: m.id, label: `${m.brand} ${m.name}` }]),
    ),
    variants: new Map(
      (variants.data ?? []).map((v) => [v.variant_code.toUpperCase(), { id: v.id, modelId: v.model_id }]),
    ),
    branches: new Map((branches.data ?? []).map((b) => [b.code.toUpperCase(), b.id])),
  };
}
