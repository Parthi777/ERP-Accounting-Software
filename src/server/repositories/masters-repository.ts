import 'server-only';

import { createSupabaseServerClient } from '@/lib/supabase/server';
import type { MasterKind } from '@/lib/validation/masters';
import type { Tables } from '@/types/database.types';

/**
 * Master data access.
 *
 * The six masters share the same shape of operation — list, read one, insert,
 * update, delete — so they share one repository keyed by `MasterKind` rather than
 * six near-identical files. RLS scopes every query, as everywhere else.
 */

/** Which table each master kind lives in, and how its list is ordered. */
const TABLES = {
  hsn: { table: 'hsn_codes', order: 'code' },
  tax: { table: 'tax_codes', order: 'code' },
  vehicle_model: { table: 'vehicle_models', order: 'model_code' },
  vehicle_variant: { table: 'vehicle_variants', order: 'variant_code' },
  inventory_item: { table: 'inventory_items', order: 'item_code' },
  finance_company: { table: 'finance_companies', order: 'code' },
  supplier: { table: 'suppliers', order: 'name' },
} as const satisfies Record<MasterKind, { table: string; order: string }>;

export type HsnRow = Tables<'hsn_codes'>;
export type TaxCodeRow = Tables<'tax_codes'>;
export type VehicleModelRow = Tables<'vehicle_models'>;
export type VehicleVariantRow = Tables<'vehicle_variants'>;
export type InventoryItemRow = Tables<'inventory_items'>;
export type FinanceCompanyRow = Tables<'finance_companies'>;
export type SupplierRow = Tables<'suppliers'>;

export async function listHsn(): Promise<HsnRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.from('hsn_codes').select('*').order('code');
  if (error) throw new Error(`Failed to load HSN codes: ${error.message}`);
  return data ?? [];
}

export async function listTaxCodes(): Promise<TaxCodeRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from('tax_codes')
    .select('*')
    .order('code')
    .order('effective_from', { ascending: false });
  if (error) throw new Error(`Failed to load tax codes: ${error.message}`);
  return data ?? [];
}

export interface VehicleModelWithCounts extends VehicleModelRow {
  readonly variant_count: number;
}

export async function listVehicleModels(): Promise<VehicleModelWithCounts[]> {
  const supabase = await createSupabaseServerClient();
  const [{ data, error }, { data: variants, error: variantError }] = await Promise.all([
    supabase.from('vehicle_models').select('*').order('brand').order('name'),
    supabase.from('vehicle_variants').select('model_id'),
  ]);
  if (error) throw new Error(`Failed to load vehicle models: ${error.message}`);
  if (variantError) throw new Error(`Failed to count variants: ${variantError.message}`);

  const counts = new Map<string, number>();
  for (const row of variants ?? []) {
    counts.set(row.model_id, (counts.get(row.model_id) ?? 0) + 1);
  }

  return (data ?? []).map((model) => ({ ...model, variant_count: counts.get(model.id) ?? 0 }));
}

export interface VehicleVariantWithModel extends VehicleVariantRow {
  readonly model_label: string;
}

export async function listVehicleVariants(): Promise<VehicleVariantWithModel[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from('vehicle_variants')
    .select('*, vehicle_models ( brand, name )')
    .order('variant_code');
  if (error) throw new Error(`Failed to load variants: ${error.message}`);

  return (data ?? []).map((row) => {
    const { vehicle_models, ...variant } = row;
    return { ...variant, model_label: `${vehicle_models.brand} ${vehicle_models.name}` };
  });
}

export async function listInventoryItems(itemType?: 'ACCESSORY' | 'SPARE'): Promise<InventoryItemRow[]> {
  const supabase = await createSupabaseServerClient();
  let query = supabase.from('inventory_items').select('*').order('item_code');
  if (itemType) {
    query = query.eq('item_type', itemType);
  }
  const { data, error } = await query;
  if (error) throw new Error(`Failed to load items: ${error.message}`);
  return data ?? [];
}

export async function listFinanceCompanies(): Promise<FinanceCompanyRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.from('finance_companies').select('*').order('name');
  if (error) throw new Error(`Failed to load finance companies: ${error.message}`);
  return data ?? [];
}

export async function listSuppliers(): Promise<SupplierRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.from('suppliers').select('*').order('name');
  if (error) throw new Error(`Failed to load suppliers: ${error.message}`);
  return data ?? [];
}

/** Reads one row of any master, for the edit form. */
export async function getMaster(kind: MasterKind, id: string): Promise<Record<string, unknown> | null> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from(TABLES[kind].table as 'hsn_codes')
    .select('*')
    .eq('id', id)
    .maybeSingle();
  if (error) throw new Error(`Failed to load the record: ${error.message}`);
  return data as Record<string, unknown> | null;
}

export async function insertMaster(
  kind: MasterKind,
  values: Record<string, unknown>,
  context: { readonly dealerId: string; readonly userId: string },
): Promise<{ id: string }> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from(TABLES[kind].table as 'hsn_codes')
    .insert({ ...values, dealer_id: context.dealerId, created_by: context.userId } as never)
    .select('id')
    .single();
  if (error) throw error;
  return data;
}

export async function updateMaster(
  kind: MasterKind,
  id: string,
  values: Record<string, unknown>,
  context: { readonly userId: string },
): Promise<{ id: string }> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from(TABLES[kind].table as 'hsn_codes')
    .update({ ...values, updated_by: context.userId } as never)
    .eq('id', id)
    .select('id')
    .single();
  if (error) throw error;
  return data;
}

export async function deleteMaster(kind: MasterKind, id: string): Promise<void> {
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.from(TABLES[kind].table as 'hsn_codes').delete().eq('id', id);
  if (error) throw error;
}

/** Sets status without touching anything else — the fallback when delete is blocked. */
export async function deactivateMaster(
  kind: MasterKind,
  id: string,
  status: string,
  context: { readonly userId: string },
): Promise<void> {
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase
    .from(TABLES[kind].table as 'hsn_codes')
    .update({ status, updated_by: context.userId } as never)
    .eq('id', id);
  if (error) throw error;
}

/** Options for the HSN and account pickers on the master forms. */
export async function listPickerOptions(): Promise<{
  hsn: { id: string; label: string }[];
  accounts: { id: string; label: string }[];
  models: { id: string; label: string }[];
  taxCodes: { code: string; label: string }[];
}> {
  const supabase = await createSupabaseServerClient();

  const [hsn, accounts, models, taxes] = await Promise.all([
    supabase.from('hsn_codes').select('id, code, description').eq('status', 'ACTIVE').order('code'),
    supabase
      .from('chart_of_accounts')
      .select('id, code, name')
      .eq('is_group', false)
      .eq('status', 'ACTIVE')
      .order('code'),
    supabase.from('vehicle_models').select('id, brand, name').eq('status', 'ACTIVE').order('brand'),
    supabase.from('tax_codes').select('code, name').eq('status', 'ACTIVE').order('code'),
  ]);

  return {
    hsn: (hsn.data ?? []).map((r) => ({ id: r.id, label: `${r.code} — ${r.description}` })),
    accounts: (accounts.data ?? []).map((r) => ({ id: r.id, label: `${r.code} — ${r.name}` })),
    models: (models.data ?? []).map((r) => ({ id: r.id, label: `${r.brand} ${r.name}` })),
    // Distinct by code: a code has many effective-dated versions but is one choice.
    taxCodes: [
      ...new Map((taxes.data ?? []).map((r) => [r.code, { code: r.code, label: `${r.code} — ${r.name}` }])).values(),
    ],
  };
}
