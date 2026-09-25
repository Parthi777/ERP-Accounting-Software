import 'server-only';

import { requirePermission } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import type { ChartResult } from '@/server/services/accounting/chart-service';

/** Item groups (F14) and pack sizes (F18), 0094. */

export interface ItemGroupRow {
  readonly id: string;
  readonly name: string;
  readonly parentName: string | null;
  readonly items: number;
  readonly status: string;
}

export async function listItemGroups(): Promise<ItemGroupRow[]> {
  await requirePermission('inventory.view');
  const supabase = await createSupabaseServerClient();
  const [groups, items] = await Promise.all([
    supabase.from('item_groups').select('id, name, parent_id, status').order('name'),
    supabase.from('inventory_items').select('item_group_id').not('item_group_id', 'is', null),
  ]);
  if (groups.error) throw new Error(`Failed to load item groups: ${groups.error.message}`);
  const names = new Map((groups.data ?? []).map((g) => [g.id, g.name]));
  const counts = new Map<string, number>();
  for (const i of items.data ?? []) if (i.item_group_id) counts.set(i.item_group_id, (counts.get(i.item_group_id) ?? 0) + 1);
  return (groups.data ?? []).map((g) => ({
    id: g.id,
    name: g.name,
    parentName: g.parent_id ? names.get(g.parent_id) ?? null : null,
    items: counts.get(g.id) ?? 0,
    status: g.status,
  }));
}

export async function addItemGroup(values: Record<string, string>): Promise<ChartResult> {
  const context = await requirePermission('inventory.items.manage');
  if (!context.dealerId) return { ok: false, error: 'Sign in as a dealer.' };
  const name = (values.name ?? '').trim();
  if (name.length < 2) return { ok: false, error: 'Name the group.' };
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.from('item_groups').insert({
    dealer_id: context.dealerId, name, parent_id: values.parentId || null, created_by: context.userId,
  });
  if (error) return { ok: false, error: error.code === '23505' ? 'A group of that name exists.' : error.message };
  return { ok: true, message: `Group ${name} added.` };
}

export interface PackSize {
  readonly id: string;
  readonly unit: string;
  readonly factor: number;
}

export async function listPackSizes(itemId: string): Promise<{ base: string; packs: PackSize[] }> {
  await requirePermission('inventory.view');
  const supabase = await createSupabaseServerClient();
  const [item, packs] = await Promise.all([
    supabase.from('inventory_items').select('uom').eq('id', itemId).maybeSingle(),
    supabase.from('item_unit_conversions').select('id, unit_code, factor').eq('item_id', itemId).order('unit_code'),
  ]);
  return {
    base: item.data?.uom ?? 'NOS',
    packs: (packs.data ?? []).map((p) => ({ id: p.id, unit: p.unit_code, factor: Number(p.factor) })),
  };
}

/** Every item's base unit and pack sizes, for order forms. */
export async function getItemUnits(): Promise<Record<string, { base: string; packs: { unit: string; factor: number }[] }>> {
  await requirePermission('inventory.view');
  const supabase = await createSupabaseServerClient();
  const [items, packs] = await Promise.all([
    supabase.from('inventory_items').select('id, uom').eq('status', 'ACTIVE'),
    supabase.from('item_unit_conversions').select('item_id, unit_code, factor'),
  ]);
  const out: Record<string, { base: string; packs: { unit: string; factor: number }[] }> = {};
  for (const i of items.data ?? []) out[i.id] = { base: i.uom, packs: [] };
  for (const p of packs.data ?? []) out[p.item_id]?.packs.push({ unit: p.unit_code, factor: Number(p.factor) });
  return out;
}

export async function addPackSize(values: Record<string, string>): Promise<ChartResult> {
  const context = await requirePermission('inventory.items.manage');
  if (!context.dealerId) return { ok: false, error: 'Sign in as a dealer.' };
  const factor = Number(values.factor);
  if (!(factor > 0)) return { ok: false, error: 'How many of the base unit does one pack hold?' };
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.from('item_unit_conversions').insert({
    dealer_id: context.dealerId, item_id: values.itemId ?? '', unit_code: values.unit ?? '', factor: String(factor), created_by: context.userId,
  });
  if (error) return { ok: false, error: error.code === '23505' ? 'That pack size is already set.' : error.message };
  return { ok: true, message: 'Pack size added.' };
}

export async function removePackSize(values: Record<string, string>): Promise<ChartResult> {
  await requirePermission('inventory.items.manage');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.from('item_unit_conversions').delete().eq('id', values.id ?? '');
  if (error) return { ok: false, error: error.message };
  return { ok: true, message: 'Pack size removed. Orders already raised keep what they were entered in.' };
}
