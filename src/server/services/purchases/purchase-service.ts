import 'server-only';

import { requirePermission, type TenantContext } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { recordAudit } from '@/server/services/audit/record-audit';
import { add, formatINR, fromDb, fromRupees, toDb, toRupees, ZERO, type Paise } from '@/lib/money';

/**
 * Purchase bills — spec §24, §28, §29, §34, §41, §48.
 *
 * The document that puts bought stock onto the balance sheet and the payable
 * onto the supplier's ledger. Before it there was no purchase anything: stock
 * arrived through the CSV uploads with no journal at all, so the inventory
 * accounts were only ever credited by COGS and account 2200 only ever debited
 * by payments.
 *
 * Vehicle lines point at a chassis the upload already created (spec §14) rather
 * than creating one, so there is a single door into vehicle stock and a vehicle
 * can be capitalised exactly once. Accessory and spare lines are the mirror:
 * those are counted rather than identified, so the bill creates the movement
 * and the quantity follows from it (spec §34).
 */

export type PurchaseStatus = 'DRAFT' | 'POSTED' | 'CANCELLED';
export type PurchaseLineType = 'VEHICLE' | 'ACCESSORY' | 'SPARE';
export type StockSource = 'LOCAL' | 'COMPANY';

export interface PurchaseListRow {
  readonly id: string;
  readonly billNumber: string;
  readonly supplierBillNumber: string;
  readonly billDate: string;
  readonly dueDate: string | null;
  readonly supplierName: string;
  readonly supplierCode: string;
  readonly branchName: string;
  readonly status: PurchaseStatus;
  readonly lineCount: number;
  readonly taxableValue: Paise;
  readonly taxAmount: Paise;
  readonly totalAmount: Paise;
}

export interface PurchaseLine {
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

export interface PurchaseBill extends PurchaseListRow {
  readonly branchId: string;
  readonly supplierId: string;
  readonly notes: string | null;
  readonly journalEntryId: string | null;
  readonly postedAt: string | null;
  readonly cgstAmount: Paise;
  readonly sgstAmount: Paise;
  readonly igstAmount: Paise;
  readonly lines: readonly PurchaseLine[];
}

export interface UnbilledVehicle {
  readonly vehicleId: string;
  readonly chassisNo: string;
  readonly engineNo: string;
  readonly modelLabel: string;
  readonly branchName: string;
  readonly purchaseCost: Paise;
  readonly stockDate: string | null;
}

export interface PurchaseResult {
  readonly ok: boolean;
  readonly id?: string;
  readonly error?: string;
  readonly message?: string;
}

function resolveBranch(context: TenantContext, requested: string | null): string | null {
  if (!requested) {
    return context.hasAllBranchAccess ? null : (context.activeBranch?.id ?? null);
  }
  return context.accessibleBranches.some((b) => b.id === requested)
    ? requested
    : (context.activeBranch?.id ?? null);
}

/**
 * The database messages name constraints and accounts. These name what the
 * person entering the bill can do about it.
 */
function describePurchaseError(message: string): string {
  if (message.includes('purchase_bill_lines_vehicle_key')) {
    return 'That chassis is already on another purchase bill. A vehicle can only be bought once.';
  }
  if (message.includes('purchase_bills_supplier_ref_key')) {
    return 'This supplier bill number has already been entered. Open the existing bill rather than keying it twice.';
  }
  if (message.includes('pbl_shape_check')) {
    return 'A line is either a chassis or a counted item with a lot — not both, and not neither.';
  }
  if (message.includes('pbl_tax_split_check')) {
    return 'A line carries CGST and SGST, or IGST — never both (spec §16).';
  }
  if (message.includes('No accounting rule')) {
    return 'The purchase accounts are not fully configured. Set them under Administration → Accounting rules. Nothing was posted.';
  }
  if (message.includes('period covering')) {
    return 'The accounting period for the bill date is closed.';
  }
  if (message.includes('and cannot be posted') || message.includes('is POSTED and immutable')) {
    return 'This bill has already been posted. Cancel it to reverse, and enter a corrected one.';
  }
  if (message.includes('has no lines')) {
    return 'Add at least one line before posting.';
  }
  if (message.includes('cannot be put on a purchase bill')) {
    return 'One of the chassis on this bill has left stock since the draft was built. Remove that line and try again.';
  }
  if (message.includes('comes to nothing')) {
    return 'This bill comes to zero. Check the rates before posting.';
  }
  return message;
}

const TAX = (row: { cgst_amount: string; sgst_amount: string; igst_amount: string }): Paise =>
  add(fromDb(row.cgst_amount), fromDb(row.sgst_amount), fromDb(row.igst_amount));

export async function getPurchaseBills(params: {
  readonly status?: string;
  readonly q?: string;
  readonly branchId?: string | null;
}): Promise<PurchaseListRow[]> {
  const context = await requirePermission('purchases.view');
  const supabase = await createSupabaseServerClient();

  // Parent and children are read separately, as everywhere else in this
  // codebase: a PostgREST embed defeats the generated types, and the failure
  // mode is a query that compiles and returns nothing.
  let query = supabase
    .from('purchase_bills')
    // One string literal, not a concatenation: the generated types read the
    // select as a literal type, and `+` widens it to `string`, which silently
    // turns every column below into an error.
    .select(
      'id, bill_number, supplier_bill_number, bill_date, due_date, status, taxable_value, cgst_amount, sgst_amount, igst_amount, total_amount, suppliers!inner ( name, supplier_code ), branches!inner ( name )',
    )
    .order('bill_date', { ascending: false })
    .limit(300);

  const branchId = resolveBranch(context, params.branchId ?? null);
  if (branchId) {
    query = query.eq('branch_id', branchId);
  }
  if (params.status && params.status !== 'ALL') {
    query = query.eq('status', params.status as PurchaseStatus);
  }
  const term = params.q?.trim();
  if (term) {
    query = query.or(`bill_number.ilike.%${term}%,supplier_bill_number.ilike.%${term}%`);
  }

  const { data, error } = await query;
  if (error) {
    throw new Error(`Failed to load purchase bills: ${error.message}`);
  }

  const bills = data ?? [];
  const counts = new Map<string, number>();
  if (bills.length > 0) {
    const { data: lines } = await supabase
      .from('purchase_bill_lines')
      .select('purchase_bill_id')
      .in('purchase_bill_id', bills.map((b) => b.id));
    for (const line of lines ?? []) {
      counts.set(line.purchase_bill_id, (counts.get(line.purchase_bill_id) ?? 0) + 1);
    }
  }

  return bills.map((row) => ({
    id: row.id,
    billNumber: row.bill_number,
    supplierBillNumber: row.supplier_bill_number,
    billDate: row.bill_date,
    dueDate: row.due_date,
    supplierName: row.suppliers.name,
    supplierCode: row.suppliers.supplier_code,
    branchName: row.branches.name,
    status: row.status as PurchaseStatus,
    lineCount: counts.get(row.id) ?? 0,
    taxableValue: fromDb(row.taxable_value),
    taxAmount: TAX(row),
    totalAmount: fromDb(row.total_amount),
  }));
}

export async function getPurchaseBill(id: string): Promise<PurchaseBill | null> {
  await requirePermission('purchases.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase
    .from('purchase_bills')
    .select(
      'id, branch_id, supplier_id, bill_number, supplier_bill_number, bill_date, due_date, status, taxable_value, cgst_amount, sgst_amount, igst_amount, total_amount, notes, journal_entry_id, posted_at, suppliers!inner ( name, supplier_code ), branches!inner ( name )',
    )
    .eq('id', id)
    .maybeSingle();

  if (error) {
    throw new Error(`Failed to load the purchase bill: ${error.message}`);
  }
  if (!data) {
    return null;
  }

  const { data: rawLines, error: lineError } = await supabase
    .from('purchase_bill_lines')
    .select(
      'id, line_number, line_type, description, source, quantity, unit_rate, taxable_value, cgst_amount, sgst_amount, igst_amount, total_amount, vehicle_id, item_id',
    )
    .eq('purchase_bill_id', id)
    .order('line_number');

  if (lineError) {
    throw new Error(`Failed to load the bill lines: ${lineError.message}`);
  }

  // The chassis and item codes a line points at, resolved in one query each
  // rather than one per line.
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

  const lines: PurchaseLine[] = (rawLines ?? []).map((line) => ({
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
    id: data.id,
    branchId: data.branch_id,
    supplierId: data.supplier_id,
    billNumber: data.bill_number,
    supplierBillNumber: data.supplier_bill_number,
    billDate: data.bill_date,
    dueDate: data.due_date,
    supplierName: data.suppliers.name,
    supplierCode: data.suppliers.supplier_code,
    branchName: data.branches.name,
    status: data.status as PurchaseStatus,
    lineCount: lines.length,
    notes: data.notes,
    journalEntryId: data.journal_entry_id,
    postedAt: data.posted_at,
    taxableValue: fromDb(data.taxable_value),
    cgstAmount: fromDb(data.cgst_amount),
    sgstAmount: fromDb(data.sgst_amount),
    igstAmount: fromDb(data.igst_amount),
    taxAmount: TAX(data),
    totalAmount: fromDb(data.total_amount),
    lines,
  };
}

/** Chassis in stock that no bill has claimed — spec §13, §14. */
export async function getUnbilledVehicles(params: {
  readonly branchId?: string | null;
  readonly search?: string;
}): Promise<UnbilledVehicle[]> {
  const context = await requirePermission('purchases.create');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('unbilled_vehicles', {
    p_branch_id: resolveBranch(context, params.branchId ?? null),
    p_search: params.search?.trim() || null,
  });

  if (error) {
    throw new Error(`Failed to load unbilled vehicles: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    vehicleId: row.vehicle_id,
    chassisNo: row.chassis_no,
    engineNo: row.engine_no,
    modelLabel: row.model_label,
    branchName: row.branch_name,
    purchaseCost: fromDb(row.purchase_cost),
    stockDate: row.stock_date,
  }));
}

export interface PurchasePickers {
  readonly suppliers: readonly { id: string; label: string }[];
  readonly items: readonly {
    id: string;
    label: string;
    type: PurchaseLineType;
    standardCost: number;
  }[];
}

export async function getPurchasePickers(): Promise<PurchasePickers> {
  await requirePermission('purchases.create');
  const supabase = await createSupabaseServerClient();

  const [suppliers, items] = await Promise.all([
    supabase
      .from('suppliers')
      .select('id, name, supplier_code')
      .eq('status', 'ACTIVE')
      .order('name'),
    supabase
      .from('inventory_items')
      .select('id, item_code, name, item_type, standard_cost')
      .eq('status', 'ACTIVE')
      .in('item_type', ['ACCESSORY', 'SPARE'])
      .order('name')
      .limit(1000),
  ]);

  if (suppliers.error) throw new Error(`Failed to load suppliers: ${suppliers.error.message}`);
  if (items.error) throw new Error(`Failed to load items: ${items.error.message}`);

  return {
    suppliers: (suppliers.data ?? []).map((s) => ({
      id: s.id,
      label: `${s.supplier_code} · ${s.name}`,
    })),
    items: (items.data ?? []).map((i) => ({
      id: i.id,
      label: `${i.item_code} · ${i.name}`,
      type: i.item_type as PurchaseLineType,
      standardCost: toRupees(fromDb(i.standard_cost)),
    })),
  };
}

export interface CreatePurchaseInput {
  readonly supplierId: string;
  readonly supplierBillNumber: string;
  readonly billDate: string;
  readonly dueDate?: string | null;
  readonly notes?: string | null;
}

export async function createPurchaseBill(input: CreatePurchaseInput): Promise<PurchaseResult> {
  const context = await requirePermission('purchases.create');
  const supabase = await createSupabaseServerClient();

  if (!context.activeBranch) {
    return { ok: false, error: 'Select a branch before entering a purchase bill.' };
  }
  if (!input.supplierId) {
    return { ok: false, error: 'Choose the supplier this bill is from.' };
  }
  if (!input.supplierBillNumber.trim()) {
    return { ok: false, error: "Enter the supplier's own bill number." };
  }

  const { data, error } = await supabase
    .from('purchase_bills')
    .insert({
      dealer_id: context.dealerId!,
      branch_id: context.activeBranch.id,
      supplier_id: input.supplierId,
      supplier_bill_number: input.supplierBillNumber.trim(),
      bill_date: input.billDate,
      due_date: input.dueDate || null,
      notes: input.notes?.trim() || null,
      created_by: context.userId,
    })
    .select('id, bill_number')
    .single();

  if (error) {
    console.error('[purchases] create failed', error.message);
    return { ok: false, error: describePurchaseError(error.message) };
  }

  await recordAudit({
    action: 'CREATE',
    entityType: 'purchase_bills',
    entityId: data.id,
    dealerId: context.dealerId,
    branchId: context.activeBranch.id,
    userId: context.userId,
    userEmail: context.email,
    newData: { bill_number: data.bill_number, supplier_bill_number: input.supplierBillNumber },
  });

  return { ok: true, id: data.id, message: `Draft ${data.bill_number} created.` };
}

export interface PurchaseLineInput {
  readonly billId: string;
  readonly lineType: PurchaseLineType;
  /** VEHICLE lines only. */
  readonly vehicleId?: string | null;
  /** ACCESSORY and SPARE lines only. */
  readonly itemId?: string | null;
  readonly source?: StockSource | null;
  readonly description: string;
  readonly quantity: number;
  /** Rupees, per unit, before tax. */
  readonly unitRate: number;
  readonly cgstRate: number;
  readonly sgstRate: number;
  readonly igstRate: number;
}

/**
 * Adds one line, computing the tax here rather than trusting the browser.
 *
 * Spec §16: tax is derived from the transaction values and the configured rates.
 * A client-supplied tax amount is a number the dealer would have to defend to
 * an assessing officer without knowing where it came from.
 */
export async function addPurchaseLine(input: PurchaseLineInput): Promise<PurchaseResult> {
  const context = await requirePermission('purchases.create');
  const supabase = await createSupabaseServerClient();

  if (!(input.quantity > 0)) {
    return { ok: false, error: 'Enter a quantity greater than zero.' };
  }
  if (!(input.unitRate >= 0)) {
    return { ok: false, error: 'Enter a rate of zero or more.' };
  }
  if (input.lineType === 'VEHICLE' && !input.vehicleId) {
    return { ok: false, error: 'Choose the chassis this line is for.' };
  }
  if (input.lineType !== 'VEHICLE' && (!input.itemId || !input.source)) {
    return { ok: false, error: 'Choose the item and which lot it joins.' };
  }
  if (input.igstRate > 0 && (input.cgstRate > 0 || input.sgstRate > 0)) {
    return { ok: false, error: 'A line carries CGST and SGST, or IGST — never both.' };
  }

  const quantity = input.lineType === 'VEHICLE' ? 1 : input.quantity;
  const taxable = fromRupees(input.unitRate * quantity);
  const rate = (percent: number): Paise => fromRupees((toRupees(taxable) * percent) / 100);
  const cgst = rate(input.cgstRate);
  const sgst = rate(input.sgstRate);
  const igst = rate(input.igstRate);

  // Next line number, read rather than counted: a removed line leaves a gap and
  // reusing its number would collide with the unique key.
  const { data: existing } = await supabase
    .from('purchase_bill_lines')
    .select('line_number')
    .eq('purchase_bill_id', input.billId)
    .order('line_number', { ascending: false })
    .limit(1);

  // numeric columns cross the wire as strings, so they stay exact — a JS number
  // cannot hold them (see src/lib/money.ts).
  const { error } = await supabase.from('purchase_bill_lines').insert({
    purchase_bill_id: input.billId,
    dealer_id: context.dealerId!,
    line_number: (existing?.[0]?.line_number ?? 0) + 1,
    line_type: input.lineType,
    vehicle_id: input.lineType === 'VEHICLE' ? input.vehicleId! : null,
    item_id: input.lineType === 'VEHICLE' ? null : input.itemId!,
    source: input.lineType === 'VEHICLE' ? null : input.source!,
    description: input.description.trim() || 'Purchase line',
    quantity: String(quantity),
    unit_rate: String(input.unitRate),
    taxable_value: toDb(taxable),
    cgst_rate: String(input.cgstRate),
    sgst_rate: String(input.sgstRate),
    igst_rate: String(input.igstRate),
    cgst_amount: toDb(cgst),
    sgst_amount: toDb(sgst),
    igst_amount: toDb(igst),
    total_amount: toDb(add(taxable, cgst, sgst, igst)),
  });

  if (error) {
    console.error('[purchases] add line failed', error.message);
    return { ok: false, error: describePurchaseError(error.message) };
  }
  return { ok: true, id: input.billId };
}

export async function removePurchaseLine(lineId: string): Promise<PurchaseResult> {
  await requirePermission('purchases.create');
  const supabase = await createSupabaseServerClient();

  const { error } = await supabase.from('purchase_bill_lines').delete().eq('id', lineId);
  if (error) {
    return { ok: false, error: describePurchaseError(error.message) };
  }
  return { ok: true };
}

export async function postPurchaseBill(billId: string): Promise<PurchaseResult> {
  const context = await requirePermission('purchases.post');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('post_purchase_bill', { p_bill_id: billId });

  if (error) {
    console.error('[purchases] post failed', error.message);
    return { ok: false, error: describePurchaseError(error.message) };
  }

  const bill = await getPurchaseBill(billId);

  await recordAudit({
    action: 'POST',
    entityType: 'purchase_bills',
    entityId: billId,
    dealerId: context.dealerId,
    branchId: bill?.branchId ?? context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { status: 'POSTED', journal_entry_id: data, total: toRupees(bill?.totalAmount ?? ZERO) },
  });

  return {
    ok: true,
    id: billId,
    message: bill
      ? `Posted. ${formatINR(bill.taxableValue)} of stock is on the books and ${formatINR(bill.totalAmount)} is owed to ${bill.supplierName}.`
      : 'The bill is posted.',
  };
}

export async function cancelPurchaseBill(
  billId: string,
  reason: string,
): Promise<PurchaseResult> {
  const context = await requirePermission('purchases.cancel');
  const supabase = await createSupabaseServerClient();

  const trimmed = reason.trim();
  if (!trimmed) {
    return { ok: false, error: 'Cancelling a bill needs a reason — it goes onto the reversal.' };
  }

  const before = await getPurchaseBill(billId);
  const { error } = await supabase.rpc('cancel_purchase_bill', {
    p_bill_id: billId,
    p_reason: trimmed,
  });

  if (error) {
    console.error('[purchases] cancel failed', error.message);
    return { ok: false, error: describePurchaseError(error.message) };
  }

  await recordAudit({
    action: before?.status === 'POSTED' ? 'REVERSE' : 'DELETE',
    entityType: 'purchase_bills',
    entityId: billId,
    dealerId: context.dealerId,
    branchId: before?.branchId ?? context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    reason: trimmed,
  });

  return {
    ok: true,
    message:
      before?.status === 'POSTED'
        ? 'The bill is reversed and its stock has been taken back out.'
        : 'The draft was discarded. Its chassis are available to bill again.',
  };
}
