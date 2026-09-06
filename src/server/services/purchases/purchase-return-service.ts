import 'server-only';

import { requirePermission, type TenantContext } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { recordAudit } from '@/server/services/audit/record-audit';
import { add, formatINR, fromDb, toRupees, type Paise } from '@/lib/money';
import type { PurchaseLineType, StockSource } from '@/server/services/purchases/purchase-service';

/**
 * Purchase returns — spec §21, §23, §24, §28, §34, §41, §48, §50.
 *
 * The debit note: part of a consignment goes back to the supplier. Cancelling a
 * bill says the purchase never happened; this says it happened and some of it is
 * being sent back, which is the case a dealer actually meets — three mats
 * damaged out of a carton of ten, one chassis with a cracked fairing.
 *
 * Everything of consequence happens inside post_purchase_return() in one
 * database transaction: the note, its lines, the stock movements and the
 * journal. This layer validates what it can before calling, translates what
 * comes back, and writes the audit row.
 *
 * The money is deliberately not here. A debit note reduces what is owed; if the
 * supplier sends cash back it is a receipt in the cash or bank book tagged to
 * them, allocated against this note in the supplier settlement screen.
 */

export type PurchaseReturnStatus = 'DRAFT' | 'POSTED' | 'CANCELLED';

export interface PurchaseReturnListRow {
  readonly id: string;
  readonly returnNumber: string;
  readonly returnDate: string;
  readonly billId: string;
  readonly billNumber: string;
  readonly supplierBillNumber: string;
  readonly supplierName: string;
  readonly supplierCode: string;
  readonly branchName: string;
  readonly status: PurchaseReturnStatus;
  readonly reason: string;
  readonly supplierRef: string | null;
  readonly lineCount: number;
  readonly taxableValue: Paise;
  readonly taxAmount: Paise;
  readonly totalAmount: Paise;
}

export interface PurchaseReturnLine {
  readonly id: string;
  readonly lineNumber: number;
  readonly lineType: PurchaseLineType;
  readonly description: string;
  readonly source: StockSource | null;
  readonly chassisNo: string | null;
  readonly itemCode: string | null;
  readonly quantity: number;
  readonly unitRate: Paise;
  readonly taxableValue: Paise;
  readonly cgstAmount: Paise;
  readonly sgstAmount: Paise;
  readonly igstAmount: Paise;
  readonly totalAmount: Paise;
}

export interface PurchaseReturn extends PurchaseReturnListRow {
  readonly branchId: string;
  readonly supplierId: string;
  readonly notes: string | null;
  readonly journalEntryId: string | null;
  readonly postedAt: string | null;
  readonly cgstAmount: Paise;
  readonly sgstAmount: Paise;
  readonly igstAmount: Paise;
  readonly lines: readonly PurchaseReturnLine[];
}

/** A bill line with how much of it is still eligible to go back. */
export interface ReturnableLine {
  readonly billLineId: string;
  readonly lineNumber: number;
  readonly lineType: PurchaseLineType;
  readonly description: string;
  readonly source: StockSource | null;
  readonly chassisNo: string | null;
  readonly itemCode: string | null;
  readonly vehicleStatus: string | null;
  readonly billedQuantity: number;
  readonly returnedQuantity: number;
  readonly returnableQuantity: number;
  readonly unitRate: Paise;
  readonly taxRate: number;
}

export interface PurchaseReturnResult {
  readonly ok: boolean;
  readonly id?: string;
  readonly error?: string;
  readonly message?: string;
}

const TAX = (row: { cgst_amount: string; sgst_amount: string; igst_amount: string }): Paise =>
  add(fromDb(row.cgst_amount), fromDb(row.sgst_amount), fromDb(row.igst_amount));

function resolveBranch(context: TenantContext, requested: string | null): string | null {
  if (!requested) {
    return context.hasAllBranchAccess ? null : (context.activeBranch?.id ?? null);
  }
  return context.accessibleBranches.some((b) => b.id === requested)
    ? requested
    : (context.activeBranch?.id ?? null);
}

/**
 * The database messages name lines and constraints. These say what the person
 * raising the note can do about it.
 */
function describeReturnError(message: string): string {
  if (message.includes('left to return')) {
    return `${message} Refresh the bill — someone may have raised a note against it already.`;
  }
  if (message.includes('only a posted bill')) {
    return 'Only a posted bill has stock on the books to send back. Post the bill first.';
  }
  if (message.includes('only a vehicle still in stock')) {
    return 'That chassis has been booked, sold or transferred since the bill was posted, so it is not the dealer’s to send back.';
  }
  if (message.includes('purchase_return_lines_vehicle_key')) {
    return 'That chassis is already on a debit note. A vehicle goes back once.';
  }
  if (message.includes('Insufficient')) {
    return `${message} The stock has been sold or consumed since it arrived, so it cannot be returned.`;
  }
  if (message.includes('goes back whole')) {
    return 'A vehicle goes back whole. Leave the quantity at one.';
  }
  if (message.includes('No accounting rule')) {
    return 'The purchase accounts are not fully configured. Set them under Administration → Accounting rules. Nothing was posted.';
  }
  if (message.includes('period covering')) {
    return 'The accounting period for the return date is closed.';
  }
  if (message.includes('is POSTED and immutable') || message.includes('cannot be reversed')) {
    return 'This note has already been posted or reversed. Raise a new one rather than editing it.';
  }
  return message;
}

const LIST_COLUMNS =
  'id, return_number, return_date, purchase_bill_id, status, reason, supplier_ref, taxable_value, cgst_amount, sgst_amount, igst_amount, total_amount, purchase_bills!inner ( bill_number, supplier_bill_number ), suppliers!inner ( name, supplier_code ), branches!inner ( name )';

type ListRow = {
  id: string;
  return_number: string;
  return_date: string;
  purchase_bill_id: string;
  status: string;
  reason: string;
  supplier_ref: string | null;
  taxable_value: string;
  cgst_amount: string;
  sgst_amount: string;
  igst_amount: string;
  total_amount: string;
  purchase_bills: { bill_number: string; supplier_bill_number: string };
  suppliers: { name: string; supplier_code: string };
  branches: { name: string };
};

function toListRow(row: ListRow, lineCount: number): PurchaseReturnListRow {
  return {
    id: row.id,
    returnNumber: row.return_number,
    returnDate: row.return_date,
    billId: row.purchase_bill_id,
    billNumber: row.purchase_bills.bill_number,
    supplierBillNumber: row.purchase_bills.supplier_bill_number,
    supplierName: row.suppliers.name,
    supplierCode: row.suppliers.supplier_code,
    branchName: row.branches.name,
    status: row.status as PurchaseReturnStatus,
    reason: row.reason,
    supplierRef: row.supplier_ref,
    lineCount,
    taxableValue: fromDb(row.taxable_value),
    taxAmount: TAX(row),
    totalAmount: fromDb(row.total_amount),
  };
}

/** How many lines each of these notes has, in one query rather than one each. */
async function countLines(
  supabase: Awaited<ReturnType<typeof createSupabaseServerClient>>,
  ids: readonly string[],
): Promise<Map<string, number>> {
  const counts = new Map<string, number>();
  if (ids.length === 0) {
    return counts;
  }
  const { data } = await supabase
    .from('purchase_return_lines')
    .select('purchase_return_id')
    .in('purchase_return_id', [...ids]);
  for (const line of data ?? []) {
    counts.set(line.purchase_return_id, (counts.get(line.purchase_return_id) ?? 0) + 1);
  }
  return counts;
}

export async function getPurchaseReturns(params: {
  readonly status?: string;
  readonly q?: string;
  readonly branchId?: string | null;
}): Promise<PurchaseReturnListRow[]> {
  const context = await requirePermission('purchases.view');
  const supabase = await createSupabaseServerClient();

  let query = supabase
    .from('purchase_returns')
    .select(LIST_COLUMNS)
    .order('return_date', { ascending: false })
    .limit(300);

  const branchId = resolveBranch(context, params.branchId ?? null);
  if (branchId) {
    query = query.eq('branch_id', branchId);
  }
  if (params.status && params.status !== 'ALL') {
    query = query.eq('status', params.status as PurchaseReturnStatus);
  }
  const term = params.q?.trim();
  if (term) {
    query = query.or(`return_number.ilike.%${term}%,supplier_ref.ilike.%${term}%`);
  }

  const { data, error } = await query;
  if (error) {
    throw new Error(`Failed to load purchase returns: ${error.message}`);
  }

  const rows = (data ?? []) as ListRow[];
  const counts = await countLines(supabase, rows.map((r) => r.id));
  return rows.map((row) => toListRow(row, counts.get(row.id) ?? 0));
}

/** The notes raised against one bill, for the bill's own page. */
export async function getReturnsForBill(billId: string): Promise<PurchaseReturnListRow[]> {
  await requirePermission('purchases.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase
    .from('purchase_returns')
    .select(LIST_COLUMNS)
    .eq('purchase_bill_id', billId)
    .order('return_date', { ascending: false });

  if (error) {
    throw new Error(`Failed to load the bill's returns: ${error.message}`);
  }

  const rows = (data ?? []) as ListRow[];
  const counts = await countLines(supabase, rows.map((r) => r.id));
  return rows.map((row) => toListRow(row, counts.get(row.id) ?? 0));
}

export async function getPurchaseReturn(id: string): Promise<PurchaseReturn | null> {
  await requirePermission('purchases.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase
    .from('purchase_returns')
    .select(
      'id, branch_id, supplier_id, return_number, return_date, purchase_bill_id, status, reason, supplier_ref, notes, journal_entry_id, posted_at, taxable_value, cgst_amount, sgst_amount, igst_amount, total_amount, purchase_bills!inner ( bill_number, supplier_bill_number ), suppliers!inner ( name, supplier_code ), branches!inner ( name )',
    )
    .eq('id', id)
    .maybeSingle();

  if (error) {
    throw new Error(`Failed to load the purchase return: ${error.message}`);
  }
  if (!data) {
    return null;
  }

  const { data: rawLines, error: lineError } = await supabase
    .from('purchase_return_lines')
    .select(
      'id, line_number, line_type, description, source, quantity, unit_rate, taxable_value, cgst_amount, sgst_amount, igst_amount, total_amount, vehicle_id, item_id',
    )
    .eq('purchase_return_id', id)
    .order('line_number');

  if (lineError) {
    throw new Error(`Failed to load the note's lines: ${lineError.message}`);
  }

  const vehicleIds = (rawLines ?? []).map((l) => l.vehicle_id).filter((v): v is string => !!v);
  const itemIds = (rawLines ?? []).map((l) => l.item_id).filter((v): v is string => !!v);

  const [vehicles, items] = await Promise.all([
    vehicleIds.length > 0
      ? supabase.from('vehicles').select('id, chassis_no').in('id', vehicleIds)
      : Promise.resolve({ data: [] as { id: string; chassis_no: string }[] }),
    itemIds.length > 0
      ? supabase.from('inventory_items').select('id, item_code').in('id', itemIds)
      : Promise.resolve({ data: [] as { id: string; item_code: string }[] }),
  ]);

  const chassisById = new Map((vehicles.data ?? []).map((v) => [v.id, v.chassis_no]));
  const codeById = new Map((items.data ?? []).map((i) => [i.id, i.item_code]));

  const lines: PurchaseReturnLine[] = (rawLines ?? []).map((line) => ({
    id: line.id,
    lineNumber: line.line_number,
    lineType: line.line_type as PurchaseLineType,
    description: line.description,
    source: (line.source as StockSource | null) ?? null,
    chassisNo: line.vehicle_id ? (chassisById.get(line.vehicle_id) ?? null) : null,
    itemCode: line.item_id ? (codeById.get(line.item_id) ?? null) : null,
    quantity: Number(line.quantity),
    unitRate: fromDb(line.unit_rate),
    taxableValue: fromDb(line.taxable_value),
    cgstAmount: fromDb(line.cgst_amount),
    sgstAmount: fromDb(line.sgst_amount),
    igstAmount: fromDb(line.igst_amount),
    totalAmount: fromDb(line.total_amount),
  }));

  return {
    ...toListRow(data as ListRow, lines.length),
    branchId: data.branch_id,
    supplierId: data.supplier_id,
    notes: data.notes,
    journalEntryId: data.journal_entry_id,
    postedAt: data.posted_at,
    cgstAmount: fromDb(data.cgst_amount),
    sgstAmount: fromDb(data.sgst_amount),
    igstAmount: fromDb(data.igst_amount),
    lines,
  };
}

/** What is still eligible to go back off a bill — spec §34. */
export async function getReturnableLines(billId: string): Promise<ReturnableLine[]> {
  await requirePermission('purchases.return');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('returnable_purchase_lines', { p_bill_id: billId });

  if (error) {
    throw new Error(`Failed to load what can be returned: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    billLineId: row.bill_line_id,
    lineNumber: row.line_number,
    lineType: row.line_type as PurchaseLineType,
    description: row.description,
    source: (row.source as StockSource | null) ?? null,
    chassisNo: row.chassis_no,
    itemCode: row.item_code,
    vehicleStatus: row.vehicle_status,
    billedQuantity: Number(row.billed_quantity),
    returnedQuantity: Number(row.returned_quantity),
    returnableQuantity: Number(row.returnable_quantity),
    unitRate: fromDb(row.unit_rate),
    // The rate the bill charged, whichever way it was split (spec §16).
    taxRate: Number(row.cgst_rate) + Number(row.sgst_rate) + Number(row.igst_rate),
  }));
}

export interface PostPurchaseReturnInput {
  readonly billId: string;
  readonly lines: readonly { billLineId: string; quantity: number }[];
  readonly reason: string;
  readonly returnDate: string;
  readonly supplierRef?: string | null;
  /**
   * One per dialog, generated in the browser. Two submissions of the same note
   * share it and the second returns the first note rather than sending the
   * goods back twice (spec §50).
   */
  readonly idempotencyKey: string;
}

export async function postPurchaseReturn(
  input: PostPurchaseReturnInput,
): Promise<PurchaseReturnResult> {
  const context = await requirePermission('purchases.return');
  const supabase = await createSupabaseServerClient();

  const reason = input.reason.trim();
  if (!reason) {
    return { ok: false, error: 'Say why the goods are going back — it goes onto the note.' };
  }

  const lines = input.lines.filter((line) => line.quantity > 0);
  if (lines.length === 0) {
    return { ok: false, error: 'Choose at least one line, with a quantity above zero.' };
  }

  const { data, error } = await supabase.rpc('post_purchase_return', {
    p_bill_id: input.billId,
    p_lines: lines.map((line) => ({ bill_line_id: line.billLineId, quantity: line.quantity })),
    p_reason: reason,
    p_return_date: input.returnDate,
    p_supplier_ref: input.supplierRef?.trim() || null,
    p_idempotency_key: input.idempotencyKey,
  });

  if (error) {
    console.error('[purchase-returns] post failed', error.message);
    return { ok: false, error: describeReturnError(error.message) };
  }

  const posted = data?.[0];
  if (!posted) {
    return { ok: false, error: 'The return did not come back from the database. Nothing was posted.' };
  }

  await recordAudit({
    action: 'POST',
    entityType: 'purchase_returns',
    entityId: posted.return_id,
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    reason,
    newData: {
      return_number: posted.return_number,
      purchase_bill_id: input.billId,
      total: toRupees(fromDb(posted.total)),
      lines: lines.length,
    },
  });

  return {
    ok: true,
    id: posted.return_id,
    message: `${posted.return_number} posted. ${formatINR(fromDb(posted.total))} has come off the supplier's account and the stock is out of the books.`,
  };
}

export async function cancelPurchaseReturn(
  returnId: string,
  reason: string,
): Promise<PurchaseReturnResult> {
  const context = await requirePermission('purchases.cancel');
  const supabase = await createSupabaseServerClient();

  const trimmed = reason.trim();
  if (!trimmed) {
    return { ok: false, error: 'Reversing a note needs a reason — it goes onto the reversal.' };
  }

  const before = await getPurchaseReturn(returnId);
  const { error } = await supabase.rpc('cancel_purchase_return', {
    p_return_id: returnId,
    p_reason: trimmed,
  });

  if (error) {
    console.error('[purchase-returns] cancel failed', error.message);
    return { ok: false, error: describeReturnError(error.message) };
  }

  await recordAudit({
    action: 'REVERSE',
    entityType: 'purchase_returns',
    entityId: returnId,
    dealerId: context.dealerId,
    branchId: before?.branchId ?? context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    reason: trimmed,
  });

  return {
    ok: true,
    id: returnId,
    message: 'The note is reversed and the stock is back where it was.',
  };
}
