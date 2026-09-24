import 'server-only';

import { requirePermission } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { add, fromDb, type Paise } from '@/lib/money';

/** Transfer notes, damaged and consignment stock — checklist §06, §07 (0083). */

export interface TransferNote {
  readonly id: string; readonly number: string; readonly date: string; readonly kind: string;
  readonly from: string; readonly to: string; readonly description: string; readonly quantity: number;
  readonly taxable: Paise; readonly tax: Paise; readonly journalId: string | null;
}

export interface ConditionRow {
  readonly itemId: string; readonly code: string; readonly name: string; readonly branch: string;
  readonly damagedQty: number; readonly damagedValue: Paise; readonly consignmentQty: number;
}

export interface Result { readonly ok: boolean; readonly error?: string; readonly message?: string }

export async function getTransferNotes(): Promise<TransferNote[]> {
  await requirePermission('inventory.view');
  const supabase = await createSupabaseServerClient();
  const [{ data, error }, { data: branches }] = await Promise.all([
    supabase.from('branch_transfer_notes')
      .select('id, note_number, note_date, note_kind, from_branch_id, to_branch_id, description, quantity, taxable_value, cgst_amount, sgst_amount, igst_amount, journal_entry_id, receipt_journal_id')
      .order('note_date', { ascending: false }).limit(300),
    supabase.from('branches').select('id, name'),
  ]);
  if (error) throw new Error(`Failed to load transfer notes: ${error.message}`);
  const name = new Map((branches ?? []).map((b) => [b.id, b.name]));
  return (data ?? []).map((n) => ({
    id: n.id, number: n.note_number, date: n.note_date, kind: n.note_kind,
    from: name.get(n.from_branch_id) ?? '', to: name.get(n.to_branch_id) ?? '',
    description: n.description, quantity: Number(n.quantity), taxable: fromDb(n.taxable_value),
    tax: add(fromDb(n.cgst_amount), fromDb(n.sgst_amount), fromDb(n.igst_amount)),
    journalId: n.receipt_journal_id ?? n.journal_entry_id,
  }));
}

export async function getConditionReport(): Promise<ConditionRow[]> {
  await requirePermission('inventory.view');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('inventory_condition_report', {});
  if (error) throw new Error(`Failed to load the condition report: ${error.message}`);
  return (data ?? []).map((r) => ({
    itemId: r.item_id, code: r.item_code, name: r.item_name, branch: r.branch_name,
    damagedQty: Number(r.damaged_qty), damagedValue: fromDb(r.damaged_value), consignmentQty: Number(r.consignment_qty),
  }));
}

export async function getStockItems(): Promise<{ id: string; label: string }[]> {
  await requirePermission('inventory.view');
  const supabase = await createSupabaseServerClient();
  const { data } = await supabase.from('inventory_items').select('id, item_code, name').eq('status', 'ACTIVE').order('item_code').limit(1000);
  return (data ?? []).map((i) => ({ id: i.id, label: `${i.item_code} · ${i.name}` }));
}

export async function markDamaged(v: {
  readonly itemId: string; readonly branchId: string; readonly source: string; readonly quantity: number;
  readonly realisableUnit: number; readonly reason: string;
}): Promise<Result> {
  await requirePermission('inventory.stock.adjust');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('mark_stock_damaged', {
    p_item_id: v.itemId, p_branch_id: v.branchId, p_source: v.source, p_quantity: v.quantity,
    p_realisable_unit: v.realisableUnit, p_reason: v.reason,
  });
  return error ? { ok: false, error: error.message } : { ok: true, message: 'Moved to damaged stock; any write-down is posted to 5970.' };
}

export async function moveConsignment(v: {
  readonly itemId: string; readonly branchId: string; readonly quantity: number;
  readonly direction: 'RECEIVE' | 'RETURN'; readonly reference: string;
}): Promise<Result> {
  await requirePermission('inventory.stock.adjust');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('move_consignment_stock', {
    p_item_id: v.itemId, p_branch_id: v.branchId, p_quantity: v.quantity, p_direction: v.direction, p_reference: v.reference,
  });
  return error ? { ok: false, error: error.message } : { ok: true, message: v.direction === 'RECEIVE' ? 'Consignment stock received at nil value.' : 'Returned to the consignor.' };
}
