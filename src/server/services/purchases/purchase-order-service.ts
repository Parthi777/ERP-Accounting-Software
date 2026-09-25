import 'server-only';

import { requirePermission } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { recordAudit } from '@/server/services/audit/record-audit';

/**
 * Purchase order → goods receipt → supplier bill (0092, BUSY F33–F37, F40).
 *
 * The rules live in the database: a receipt cannot exceed what is still to
 * come, a bill cannot bill more of a receipt than arrived, a billed receipt
 * cannot be cancelled, and a receipt's stock is never added again by its bill.
 * This layer shapes input and output.
 */

export interface PurchaseOrderResult {
  readonly ok: boolean;
  readonly id?: string;
  readonly message?: string;
  readonly error?: string;
}

export interface PurchaseOrderRow {
  readonly id: string;
  readonly poNumber: string;
  readonly orderDate: string;
  readonly expectedDate: string | null;
  readonly status: string;
  readonly supplierName: string;
  readonly branchName: string;
  readonly value: number;
}

export interface PurchaseOrderLine {
  readonly id: string;
  readonly lineNumber: number;
  readonly description: string;
  readonly source: string;
  readonly quantity: number;
  readonly unitRate: number;
  readonly gstRate: number;
  readonly received: number;
  readonly billed: number;
  readonly pending: number;
}

export interface GoodsReceiptRow {
  readonly id: string;
  readonly grnNumber: string;
  readonly receiptDate: string;
  readonly status: string;
  readonly totalValue: number;
  readonly challan: string | null;
  readonly transport: string | null;
  readonly journalEntryId: string | null;
  readonly cancelReason: string | null;
}

export interface PurchaseOrderDetail {
  readonly id: string;
  readonly poNumber: string;
  readonly orderDate: string;
  readonly expectedDate: string | null;
  readonly status: string;
  readonly notes: string | null;
  readonly supplierId: string;
  readonly supplierName: string;
  readonly branchName: string;
  readonly lines: PurchaseOrderLine[];
  readonly receipts: GoodsReceiptRow[];
}

const n = (v: string | number | null | undefined) => Number(v ?? 0);

export async function listPurchaseOrders(params: { readonly open?: boolean }): Promise<PurchaseOrderRow[]> {
  await requirePermission('purchases.view');
  const supabase = await createSupabaseServerClient();
  let query = supabase
    .from('purchase_orders')
    .select('id, po_number, order_date, expected_date, status, suppliers ( name ), branches ( name ), purchase_order_lines ( quantity, unit_rate )')
    .order('order_date', { ascending: false })
    .order('po_number', { ascending: false })
    .limit(300);
  if (params.open) query = query.in('status', ['DRAFT', 'APPROVED', 'PARTIAL']);
  const { data, error } = await query;
  if (error) throw new Error(`Failed to load purchase orders: ${error.message}`);
  return (data ?? []).map((po) => ({
    id: po.id,
    poNumber: po.po_number,
    orderDate: po.order_date,
    expectedDate: po.expected_date,
    status: po.status,
    supplierName: po.suppliers?.name ?? '—',
    branchName: po.branches?.name ?? '—',
    value: (po.purchase_order_lines ?? []).reduce((s, l) => s + n(l.quantity) * n(l.unit_rate), 0),
  }));
}

export async function getPurchaseOrder(id: string): Promise<PurchaseOrderDetail | null> {
  await requirePermission('purchases.view');
  const supabase = await createSupabaseServerClient();
  const [po, lines, progress, receipts] = await Promise.all([
    supabase
      .from('purchase_orders')
      .select('id, po_number, order_date, expected_date, status, notes, supplier_id, suppliers ( name ), branches ( name )')
      .eq('id', id)
      .maybeSingle(),
    supabase
      .from('purchase_order_lines')
      .select('id, line_number, description, source, quantity, unit_rate, cgst_rate, sgst_rate, igst_rate')
      .eq('purchase_order_id', id)
      .order('line_number'),
    supabase.rpc('pending_purchase_orders', { p_include_closed: true }),
    supabase
      .from('goods_receipts')
      .select('id, grn_number, receipt_date, status, total_value, supplier_challan_number, transporter, lr_number, vehicle_number, journal_entry_id, cancel_reason')
      .eq('purchase_order_id', id)
      .order('receipt_date'),
  ]);
  if (po.error) throw new Error(`Failed to load the purchase order: ${po.error.message}`);
  if (!po.data) return null;
  const byLine = new Map((progress.data ?? []).filter((p) => p.order_id === id).map((p) => [p.po_line_id, p]));

  return {
    id: po.data.id,
    poNumber: po.data.po_number,
    orderDate: po.data.order_date,
    expectedDate: po.data.expected_date,
    status: po.data.status,
    notes: po.data.notes,
    supplierId: po.data.supplier_id,
    supplierName: po.data.suppliers?.name ?? '—',
    branchName: po.data.branches?.name ?? '—',
    lines: (lines.data ?? []).map((l) => {
      const p = byLine.get(l.id);
      return {
        id: l.id,
        lineNumber: l.line_number,
        description: l.description,
        source: l.source,
        quantity: n(l.quantity),
        unitRate: n(l.unit_rate),
        gstRate: n(l.cgst_rate) + n(l.sgst_rate) + n(l.igst_rate),
        received: n(p?.received),
        billed: n(p?.billed),
        pending: n(p?.pending),
      };
    }),
    receipts: (receipts.data ?? []).map((r) => ({
      id: r.id,
      grnNumber: r.grn_number,
      receiptDate: r.receipt_date,
      status: r.status,
      totalValue: n(r.total_value),
      challan: r.supplier_challan_number,
      transport: [r.transporter, r.lr_number && `LR ${r.lr_number}`, r.vehicle_number].filter(Boolean).join(' · ') || null,
      journalEntryId: r.journal_entry_id,
      cancelReason: r.cancel_reason,
    })),
  };
}

export interface PendingLine {
  readonly orderId: string;
  readonly poNumber: string;
  readonly orderDate: string;
  readonly expectedDate: string | null;
  readonly supplierName: string;
  readonly description: string;
  readonly ordered: number;
  readonly received: number;
  readonly pending: number;
  readonly overdue: boolean;
}

export async function getPendingOrderLines(): Promise<PendingLine[]> {
  await requirePermission('purchases.view');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('pending_purchase_orders', { p_include_closed: false });
  if (error) throw new Error(`Failed to load pending orders: ${error.message}`);
  return (data ?? [])
    .filter((r) => n(r.pending) > 0)
    .map((r) => ({
      orderId: r.order_id,
      poNumber: r.po_number,
      orderDate: r.order_date,
      expectedDate: r.expected_date,
      supplierName: r.supplier_name,
      description: r.description,
      ordered: n(r.ordered),
      received: n(r.received),
      pending: n(r.pending),
      overdue: r.overdue,
    }));
}

export interface GrniLine {
  readonly grnLineId: string;
  readonly grnNumber: string;
  readonly receiptDate: string;
  readonly supplierName: string;
  readonly description: string;
  readonly unbilled: number;
  readonly unitCost: number;
  readonly value: number;
}

export async function getGrniOutstanding(): Promise<GrniLine[]> {
  await requirePermission('purchases.view');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('grni_outstanding');
  if (error) throw new Error(`Failed to load goods received not billed: ${error.message}`);
  return (data ?? []).map((r) => ({
    grnLineId: r.grn_line_id,
    grnNumber: r.grn_number,
    receiptDate: r.receipt_date,
    supplierName: r.supplier_name,
    description: r.description,
    unbilled: n(r.unbilled),
    unitCost: n(r.unit_cost),
    value: n(r.value),
  }));
}

export interface UnbilledReceiptLine {
  readonly grnLineId: string;
  readonly grnNumber: string;
  readonly receiptDate: string;
  readonly poNumber: string;
  readonly description: string;
  readonly unbilled: number;
  readonly unitCost: number;
}

export async function getUnbilledReceiptLines(supplierId: string, branchId: string): Promise<UnbilledReceiptLine[]> {
  await requirePermission('purchases.create');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('unbilled_receipt_lines', { p_supplier_id: supplierId, p_branch_id: branchId });
  if (error) throw new Error(`Failed to load unbilled receipts: ${error.message}`);
  return (data ?? []).map((r) => ({
    grnLineId: r.grn_line_id,
    grnNumber: r.grn_number,
    receiptDate: r.receipt_date,
    poNumber: r.po_number,
    description: r.description,
    unbilled: n(r.unbilled),
    unitCost: n(r.unit_cost),
  }));
}

// ─────────────────────────────────────────────────────────────────────────────
// Writing
// ─────────────────────────────────────────────────────────────────────────────

export interface PurchaseOrderInput {
  readonly supplierId: string;
  readonly orderDate: string;
  readonly expectedDate: string | null;
  readonly notes: string | null;
  readonly lines: readonly {
    readonly itemId: string;
    readonly source: 'LOCAL' | 'COMPANY';
    readonly quantity: number;
    readonly unitRate: number;
    readonly gstRate: number;
    readonly interState: boolean;
    /** Ordered in this pack unit (0094); omitted or the base unit otherwise. */
    readonly unit?: string | null;
  }[];
  readonly idempotencyKey: string;
}

export async function createPurchaseOrder(input: PurchaseOrderInput): Promise<PurchaseOrderResult> {
  const context = await requirePermission('purchases.create');
  if (!context.activeBranch) return { ok: false, error: 'Select a branch before raising an order.' };
  if (!input.supplierId) return { ok: false, error: 'Choose the supplier.' };
  const lines = input.lines.filter((l) => l.itemId);
  if (lines.length === 0) return { ok: false, error: 'Add at least one item.' };
  const bad = lines.findIndex((l) => !(l.quantity > 0) || !(l.unitRate >= 0));
  if (bad >= 0) return { ok: false, error: `Line ${bad + 1}: enter a quantity above zero and a rate.` };

  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('create_purchase_order', {
    p_branch_id: context.activeBranch.id,
    p_supplier_id: input.supplierId,
    p_lines: lines.map((l) => ({
      item_id: l.itemId,
      unit: l.unit || null,
      source: l.source,
      quantity: l.quantity,
      unit_rate: l.unitRate,
      cgst_rate: l.interState ? 0 : l.gstRate / 2,
      sgst_rate: l.interState ? 0 : l.gstRate / 2,
      igst_rate: l.interState ? l.gstRate : 0,
    })),
    p_order_date: input.orderDate,
    p_expected_date: input.expectedDate || undefined,
    p_notes: input.notes?.trim() || undefined,
    p_idempotency_key: input.idempotencyKey,
  });
  if (error) return { ok: false, error: error.message };
  await recordAudit({
    action: 'CREATE', entityType: 'purchase_orders', entityId: String(data),
    dealerId: context.dealerId, branchId: context.activeBranch.id, userId: context.userId, userEmail: context.email,
    newData: { supplierId: input.supplierId, lines: lines.length },
  });
  return { ok: true, id: String(data), message: 'Purchase order raised.' };
}

export async function approvePurchaseOrder(id: string): Promise<PurchaseOrderResult> {
  await requirePermission('purchases.post');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('approve_purchase_order', { p_order_id: id });
  if (error) return { ok: false, error: error.message };
  return { ok: true, id, message: 'Order approved. Goods can now be received against it.' };
}

export async function closePurchaseOrder(id: string, reason: string): Promise<PurchaseOrderResult> {
  await requirePermission('purchases.view');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('close_purchase_order', { p_order_id: id, p_reason: reason.trim() });
  if (error) return { ok: false, error: error.message };
  return { ok: true, id, message: data === 'CLOSED' ? 'Order closed; what was not received is no longer pending.' : 'Order cancelled.' };
}

export interface GoodsReceiptInput {
  readonly orderId: string;
  readonly receiptDate: string;
  readonly lines: readonly { readonly poLineId: string; readonly quantity: number }[];
  readonly transport: {
    readonly supplierChallanNumber?: string;
    readonly transporter?: string;
    readonly lrNumber?: string;
    readonly vehicleNumber?: string;
    readonly origin?: string;
    readonly originPincode?: string;
  };
  readonly idempotencyKey: string;
}

export async function postGoodsReceipt(input: GoodsReceiptInput): Promise<PurchaseOrderResult> {
  const context = await requirePermission('purchases.post');
  const lines = input.lines.filter((l) => l.quantity > 0);
  if (lines.length === 0) return { ok: false, error: 'Enter what was received.' };
  if (input.transport.originPincode && !/^[1-9][0-9]{5}$/.test(input.transport.originPincode)) {
    return { ok: false, error: 'A PIN code is six digits.' };
  }
  const supabase = await createSupabaseServerClient();
  const t = input.transport;
  const { data, error } = await supabase.rpc('post_goods_receipt', {
    p_order_id: input.orderId,
    p_lines: lines.map((l) => ({ po_line_id: l.poLineId, quantity: l.quantity })),
    p_receipt_date: input.receiptDate,
    p_transport: {
      supplier_challan_number: t.supplierChallanNumber ?? null,
      transporter: t.transporter ?? null,
      lr_number: t.lrNumber ?? null,
      vehicle_number: t.vehicleNumber ?? null,
      origin: t.origin ?? null,
      origin_pincode: t.originPincode ?? null,
    },
    p_idempotency_key: input.idempotencyKey,
  });
  if (error) return { ok: false, error: error.message };
  await recordAudit({
    action: 'POST', entityType: 'goods_receipts', entityId: String(data),
    dealerId: context.dealerId, branchId: context.activeBranch?.id ?? null, userId: context.userId, userEmail: context.email,
    newData: { orderId: input.orderId, lines: lines.length },
  });
  return { ok: true, id: String(data), message: 'Goods received into stock. The bill, when it comes, is entered against this receipt.' };
}

export async function cancelGoodsReceipt(id: string, reason: string): Promise<PurchaseOrderResult> {
  const context = await requirePermission('purchases.view');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('cancel_goods_receipt', { p_receipt_id: id, p_reason: reason.trim() });
  if (error) return { ok: false, error: error.message };
  await recordAudit({
    action: 'CANCEL', entityType: 'goods_receipts', entityId: id,
    dealerId: context.dealerId, userId: context.userId, userEmail: context.email, reason: reason.trim(),
  });
  return { ok: true, id, message: 'Receipt cancelled; its stock and journal are reversed.' };
}

export async function addReceiptLinesToBill(
  billId: string,
  lines: readonly { readonly grnLineId: string; readonly quantity: number; readonly unitRate: number }[],
): Promise<PurchaseOrderResult> {
  await requirePermission('purchases.create');
  const chosen = lines.filter((l) => l.quantity > 0);
  if (chosen.length === 0) return { ok: false, error: 'Tick the receipt lines this bill covers.' };
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('add_receipt_lines_to_bill', {
    p_bill_id: billId,
    p_lines: chosen.map((l) => ({ grn_line_id: l.grnLineId, quantity: l.quantity, unit_rate: l.unitRate })),
  });
  if (error) return { ok: false, error: error.message };
  return { ok: true, id: billId, message: `${data} line(s) added from goods receipts.` };
}
