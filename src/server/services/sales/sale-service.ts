import 'server-only';

import { requirePermission, type TenantContext } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { fromDb, type Paise } from '@/lib/money';
import { recordAudit } from '@/server/services/audit/record-audit';
import type { Permission } from '@/lib/permissions';
import type { Tables } from '@/types/database.types';

/**
 * Vehicle sales — spec §19, §20, §48, §53.
 *
 * The workflow is DRAFT → SUBMITTED → ACCOUNTS_VERIFICATION → APPROVED → POSTED
 * → DELIVERED, and each step needs its own permission. The database enforces the
 * order regardless; this layer enforces *who* may take each step, and gives a
 * useful message when they may not.
 */

export type SaleStatus =
  | 'DRAFT' | 'SUBMITTED' | 'ACCOUNTS_VERIFICATION' | 'APPROVED'
  | 'POSTED' | 'DELIVERED' | 'CANCELLED' | 'RETURNED';

/** Which permission each transition needs, and what to call it in the UI. */
export const TRANSITIONS: Readonly<
  Record<string, { readonly to: SaleStatus; readonly permission: Permission; readonly label: string; readonly tone: 'primary' | 'secondary' | 'danger' }>
> = {
  submit:  { to: 'SUBMITTED',             permission: 'sales.submit',  label: 'Submit for verification', tone: 'primary' },
  verify:  { to: 'ACCOUNTS_VERIFICATION', permission: 'sales.verify',  label: 'Begin verification',      tone: 'primary' },
  approve: { to: 'APPROVED',              permission: 'sales.approve', label: 'Approve',                 tone: 'primary' },
  reject:  { to: 'DRAFT',                 permission: 'sales.verify',  label: 'Return for correction',   tone: 'secondary' },
  cancel:  { to: 'CANCELLED',             permission: 'sales.cancel',  label: 'Cancel',                  tone: 'danger' },
};

export interface SaleListRow {
  readonly id: string;
  readonly invoiceNumber: string;
  readonly invoiceDate: string;
  readonly customerName: string;
  readonly customerCode: string;
  readonly chassisNo: string;
  readonly modelLabel: string;
  readonly branchName: string;
  readonly totalAmount: Paise;
  readonly paidAmount: Paise;
  readonly financeAmount: Paise;
  readonly balanceAmount: Paise;
  readonly status: SaleStatus;
}

function resolveBranch(context: TenantContext, requested: string | null): string | null {
  if (!requested) {
    return context.hasAllBranchAccess ? null : (context.activeBranch?.id ?? null);
  }
  return context.accessibleBranches.some((b) => b.id === requested)
    ? requested
    : (context.activeBranch?.id ?? null);
}

export async function getSales(params: {
  readonly status: string;
  readonly branchId: string | null;
  readonly q?: string;
  /**
   * Row cap. Defaults to the screen's, which is all anyone scrolls; the
   * report exporter raises it, because a spreadsheet has no such limit and a
   * silently truncated financial extract is worse than none.
   */
  readonly limit?: number;
}): Promise<SaleListRow[]> {
  const context = await requirePermission('sales.view');
  const supabase = await createSupabaseServerClient();

  let query = supabase
    .from('sales')
    .select(
      'id, invoice_number, invoice_date, total_amount, paid_amount, finance_amount, balance_amount, status, customers!inner ( name, customer_code ), vehicles!inner ( chassis_no, vehicle_models ( brand, name ) ), branches!inner ( name )',
    )
    .order('invoice_date', { ascending: false })
    .limit(params.limit ?? 200);

  if (params.status !== 'ALL') {
    query = query.eq('status', params.status as SaleStatus);
  }
  const branchId = resolveBranch(context, params.branchId);
  if (branchId) {
    query = query.eq('branch_id', branchId);
  }

  const { data, error } = await query;
  if (error) {
    throw new Error(`Failed to load sales: ${error.message}`);
  }

  const term = params.q?.trim().toLowerCase();

  return (data ?? [])
    .map((row) => ({
      id: row.id,
      invoiceNumber: row.invoice_number,
      invoiceDate: row.invoice_date,
      customerName: row.customers.name,
      customerCode: row.customers.customer_code,
      chassisNo: row.vehicles.chassis_no,
      modelLabel: `${row.vehicles.vehicle_models.brand} ${row.vehicles.vehicle_models.name}`,
      branchName: row.branches.name,
      totalAmount: fromDb(row.total_amount),
      paidAmount: fromDb(row.paid_amount),
      financeAmount: fromDb(row.finance_amount),
      balanceAmount: fromDb(row.balance_amount),
      status: row.status,
    }))
    .filter(
      (row) =>
        !term ||
        row.invoiceNumber.toLowerCase().includes(term) ||
        row.customerName.toLowerCase().includes(term) ||
        row.chassisNo.toLowerCase().includes(term),
    );
}

export interface SaleLine {
  readonly lineNumber: number;
  readonly lineType: string;
  readonly description: string;
  readonly quantity: number;
  readonly unitRate: Paise;
  readonly taxableValue: Paise;
  readonly cgstAmount: Paise;
  readonly sgstAmount: Paise;
  readonly igstAmount: Paise;
  readonly totalAmount: Paise;
  readonly stockSource: string | null;
  /** Null when the session lacks sales.view_cost (spec §52). */
  readonly costAmount: Paise | null;
}

export interface SaleDetail {
  readonly id: string;
  readonly invoiceNumber: string;
  readonly invoiceDate: string;
  readonly status: SaleStatus;
  readonly customerName: string;
  readonly customerCode: string;
  readonly customerMobile: string;
  readonly customerGstin: string | null;
  readonly chassisNo: string;
  readonly engineNo: string;
  readonly modelLabel: string;
  readonly branchName: string;
  readonly bookingId: string | null;
  readonly bookingNumber: string | null;
  readonly journalEntryId: string | null;
  readonly priceVersionNumber: number | null;
  readonly taxableValue: Paise;
  readonly cgstAmount: Paise;
  readonly sgstAmount: Paise;
  readonly igstAmount: Paise;
  readonly totalAmount: Paise;
  readonly paidAmount: Paise;
  readonly financeAmount: Paise;
  readonly balanceAmount: Paise;
  /** Null without sales.view_cost. */
  readonly totalCost: Paise | null;
  readonly margin: Paise | null;
  readonly lines: readonly SaleLine[];
  readonly payments: readonly {
    readonly id: string;
    readonly receiptNumber: string;
    readonly paymentDate: string;
    readonly amount: Paise;
    readonly mode: string;
    readonly journalEntryId: string | null;
  }[];
  readonly canSeeCost: boolean;
}

export async function getSale(id: string): Promise<SaleDetail | null> {
  const context = await requirePermission('sales.view');
  const supabase = await createSupabaseServerClient();

  const [{ data, error }, { data: lines }, { data: payments }] = await Promise.all([
    supabase
      .from('sales')
      .select(
        '*, customers ( name, customer_code, mobile, gstin ), vehicles ( chassis_no, engine_no, vehicle_models ( brand, name ) ), branches ( name ), bookings ( booking_number ), vehicle_price_versions ( version_number )',
      )
      .eq('id', id)
      .maybeSingle(),
    supabase.from('sale_lines').select('*').eq('sale_id', id).order('line_number'),
    supabase
      .from('sale_payments')
      .select('id, receipt_number, payment_date, amount, payment_mode, journal_entry_id')
      .eq('sale_id', id)
      .order('payment_date'),
  ]);

  if (error) {
    throw new Error(`Failed to load the sale: ${error.message}`);
  }
  if (!data) {
    return null;
  }

  // Cost and margin are restricted (spec §52). Building them as null rather than
  // filtering later means they are never in the object at all for a Cashier.
  const canSeeCost = context.permissions.has('sales.view_cost');
  const totalCost = canSeeCost ? fromDb(data.total_cost) : null;
  const taxable = fromDb(data.taxable_value);

  return {
    id: data.id,
    invoiceNumber: data.invoice_number,
    invoiceDate: data.invoice_date,
    status: data.status,
    customerName: data.customers.name,
    customerCode: data.customers.customer_code,
    customerMobile: data.customers.mobile,
    customerGstin: data.customers.gstin,
    chassisNo: data.vehicles.chassis_no,
    engineNo: data.vehicles.engine_no,
    modelLabel: `${data.vehicles.vehicle_models.brand} ${data.vehicles.vehicle_models.name}`,
    branchName: data.branches.name,
    bookingId: data.booking_id,
    bookingNumber: data.bookings?.booking_number ?? null,
    journalEntryId: data.journal_entry_id,
    priceVersionNumber: data.vehicle_price_versions?.version_number ?? null,
    taxableValue: taxable,
    cgstAmount: fromDb(data.cgst_amount),
    sgstAmount: fromDb(data.sgst_amount),
    igstAmount: fromDb(data.igst_amount),
    totalAmount: fromDb(data.total_amount),
    paidAmount: fromDb(data.paid_amount),
    financeAmount: fromDb(data.finance_amount),
    balanceAmount: fromDb(data.balance_amount),
    totalCost,
    margin: totalCost === null ? null : ((taxable - totalCost) as Paise),
    canSeeCost,
    lines: (lines ?? []).map((l) => ({
      lineNumber: l.line_number,
      lineType: l.line_type,
      description: l.description,
      quantity: Number(l.quantity),
      unitRate: fromDb(l.unit_rate),
      taxableValue: fromDb(l.taxable_value),
      cgstAmount: fromDb(l.cgst_amount),
      sgstAmount: fromDb(l.sgst_amount),
      igstAmount: fromDb(l.igst_amount),
      totalAmount: fromDb(l.total_amount),
      stockSource: l.stock_source,
      costAmount: canSeeCost ? fromDb(l.cost_amount) : null,
    })),
    payments: (payments ?? []).map((p) => ({
      id: p.id,
      receiptNumber: p.receipt_number,
      paymentDate: p.payment_date,
      amount: fromDb(p.amount),
      mode: p.payment_mode,
      journalEntryId: p.journal_entry_id,
    })),
  };
}

export interface SaleResult {
  readonly ok: boolean;
  readonly id?: string;
  readonly error?: string;
}

/** Moves a sale one step along the workflow. */
export async function transitionSale(
  id: string,
  action: keyof typeof TRANSITIONS,
  reason?: string,
): Promise<SaleResult> {
  const transition = TRANSITIONS[action];
  if (!transition) {
    return { ok: false, error: 'Unknown action.' };
  }

  const context = await requirePermission(transition.permission);
  const supabase = await createSupabaseServerClient();

  if (transition.to === 'CANCELLED' && !reason?.trim()) {
    return { ok: false, error: 'A cancellation reason is required.' };
  }

  // Typed against the row so a mistyped column is a compile error rather than a
  // silently ignored field.
  const patch: Partial<Tables<'sales'>> = { status: transition.to, updated_by: context.userId };
  if (transition.to === 'SUBMITTED') {
    patch.submitted_at = new Date().toISOString();
    patch.submitted_by = context.userId;
  }
  if (transition.to === 'ACCOUNTS_VERIFICATION') {
    patch.verified_at = new Date().toISOString();
    patch.verified_by = context.userId;
  }
  if (transition.to === 'APPROVED') {
    patch.approved_at = new Date().toISOString();
    patch.approved_by = context.userId;
  }
  if (transition.to === 'CANCELLED') {
    patch.cancelled_at = new Date().toISOString();
    patch.cancelled_by = context.userId;
    patch.cancelled_reason = reason;
  }
  if (action === 'reject') {
    patch.rejection_reason = reason ?? null;
  }

  const { error } = await supabase.from('sales').update(patch).eq('id', id);

  if (error) {
    console.error('[sales] transition failed', { action, message: error.message });
    // The workflow guard's message names the states, which is more useful than
    // anything this layer could invent.
    if (error.message.includes('cannot move from')) {
      return { ok: false, error: error.message.replace(/^.*?ERROR:\s*/, '') };
    }
    return { ok: false, error: `The sale could not be ${transition.label.toLowerCase()}.` };
  }

  await recordAudit({
    action: transition.to === 'APPROVED' ? 'APPROVE' : transition.to === 'CANCELLED' ? 'CANCEL' : 'UPDATE',
    entityType: 'sales',
    entityId: id,
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    reason,
    newData: { status: transition.to },
  });

  return { ok: true, id };
}

/** Posts an approved sale through the database engine (spec §48). */
export async function postSale(id: string): Promise<SaleResult> {
  const context = await requirePermission('sales.post');
  const supabase = await createSupabaseServerClient();

  const { error } = await supabase.rpc('post_vehicle_sale', { p_sale_id: id });

  if (error) {
    console.error('[sales] post failed', error.message);
    if (error.message.includes('No accounting rule')) {
      return {
        ok: false,
        error: 'Accounting rules for vehicle sales are not fully configured. Nothing was posted.',
      };
    }
    if (error.message.includes('only an APPROVED sale')) {
      return { ok: false, error: 'Only an approved sale can be posted.' };
    }
    if (error.message.includes('period covering')) {
      return { ok: false, error: 'The accounting period for this invoice date is closed.' };
    }
    return { ok: false, error: `The sale could not be posted: ${error.message}` };
  }

  await recordAudit({
    action: 'POST',
    entityType: 'sales',
    entityId: id,
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
  });

  return { ok: true, id };
}

export async function recordPayment(
  saleId: string,
  amount: number,
  mode: string,
  reference?: string,
): Promise<SaleResult> {
  const context = await requirePermission('sales.create');
  const supabase = await createSupabaseServerClient();

  if (amount <= 0) {
    return { ok: false, error: 'Enter an amount greater than zero.' };
  }

  const { error } = await supabase.rpc('record_sale_payment', {
    p_sale_id: saleId,
    p_amount: amount,
    p_payment_mode: mode,
    p_reference: reference ?? null,
    p_finance_company_id: null,
  });

  if (error) {
    console.error('[sales] payment failed', error.message);
    if (error.message.includes('posted invoice')) {
      return { ok: false, error: 'Payments can only be recorded against a posted invoice.' };
    }
    if (error.message.includes('No accounting rule')) {
      return { ok: false, error: 'Accounting rules for receipts are not configured. Nothing was recorded.' };
    }
    return { ok: false, error: 'The payment could not be recorded.' };
  }

  await recordAudit({
    action: 'CREATE',
    entityType: 'sale_payments',
    entityId: saleId,
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { amount, mode },
  });

  return { ok: true, id: saleId };
}

export async function deliverSale(
  saleId: string,
  receivedBy?: string,
  odometer?: number,
  remarks?: string,
): Promise<SaleResult> {
  const context = await requirePermission('sales.deliver');
  const supabase = await createSupabaseServerClient();

  const { error } = await supabase.rpc('deliver_vehicle', {
    p_sale_id: saleId,
    p_received_by: receivedBy ?? null,
    p_odometer: odometer ?? null,
    p_remarks: remarks ?? null,
  });

  if (error) {
    console.error('[sales] delivery failed', error.message);
    if (error.message.includes('Only a POSTED sale')) {
      return { ok: false, error: 'Only a posted sale can be delivered.' };
    }
    return { ok: false, error: 'The delivery could not be recorded.' };
  }

  await recordAudit({
    action: 'UPDATE',
    entityType: 'deliveries',
    entityId: saleId,
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { received_by: receivedBy },
  });

  return { ok: true, id: saleId };
}

export interface CreateSaleInput {
  readonly customer_id: string;
  readonly vehicle_id: string;
  readonly invoice_date: string;
  readonly booking_id?: string;
  readonly sales_executive_id?: string;
  readonly discount?: number;
  readonly notes?: string;
}

/**
 * Drafts an invoice from the price version in force on the invoice date.
 *
 * One RPC so the header and its lines land together — a header with no lines is
 * an invoice for zero that looks real.
 */
export async function createSaleDraft(input: CreateSaleInput): Promise<SaleResult> {
  const context = await requirePermission('sales.create');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('create_vehicle_sale_draft', {
    p_customer_id: input.customer_id,
    p_vehicle_id: input.vehicle_id,
    p_invoice_date: input.invoice_date,
    p_booking_id: input.booking_id ?? null,
    p_sales_executive_id: input.sales_executive_id ?? null,
    p_discount: input.discount ?? 0,
    p_notes: input.notes ?? null,
  });

  if (error) {
    console.error('[sales] draft failed', error.message);
    if (error.message.includes('No price is configured')) {
      return {
        ok: false,
        error: 'No price is configured for this model on that date. Add a price version first.',
      };
    }
    if (error.message.includes('is not available for sale')) {
      return { ok: false, error: 'That vehicle is no longer available — it may already be on another invoice.' };
    }
    if (error.message.includes('exceeds the maximum')) {
      return { ok: false, error: error.message.replace(/^.*?ERROR:\s*/, '') };
    }
    if (error.message.includes('No document sequence')) {
      return {
        ok: false,
        error: 'No invoice number sequence is configured for this branch and year. Add one under Administration → Settings.',
      };
    }
    return { ok: false, error: 'The invoice could not be drafted.' };
  }

  const row = Array.isArray(data) ? data[0] : data;
  if (!row) {
    return { ok: false, error: 'The invoice could not be drafted.' };
  }

  await recordAudit({
    action: 'CREATE',
    entityType: 'sales',
    entityId: row.sale_id,
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { invoice_number: row.invoice_number },
  });

  return { ok: true, id: row.sale_id };
}

/**
 * Reverses a posted sale — spec §21, §23.
 *
 * Not an edit and not a delete. The invoice stays exactly as it was issued, its
 * journal is reversed by a second journal carrying the reason, the vehicle comes
 * back into stock and the fitted accessories return to the lot they were drawn
 * from. All of that happens inside `return_vehicle_sale` so it cannot half-apply.
 */
export async function returnSale(saleId: string, reason: string): Promise<SaleResult> {
  const context = await requirePermission('sales.return');
  const supabase = await createSupabaseServerClient();

  const trimmed = reason.trim();
  if (!trimmed) {
    return {
      ok: false,
      error: 'A return needs a reason — it is recorded on the reversal, not just asked for here.',
    };
  }

  const { error } = await supabase.rpc('return_vehicle_sale', {
    p_sale_id: saleId,
    p_reason: trimmed,
  });

  if (error) {
    console.error('[sales] return failed', error.message);
    if (error.message.includes('received against it')) {
      return {
        ok: false,
        error:
          'Money has been received against this invoice. Refund it first — a return cannot ' +
          'silently leave the customer in credit.',
      };
    }
    if (error.message.includes('only a posted, undelivered sale')) {
      return {
        ok: false,
        error: 'Only a posted sale that has not been delivered can be returned.',
      };
    }
    if (error.message.includes('period covering')) {
      return { ok: false, error: 'The accounting period for the reversal date is closed.' };
    }
    return { ok: false, error: `The sale could not be returned: ${error.message}` };
  }

  await recordAudit({
    action: 'REVERSE',
    entityType: 'sales',
    entityId: saleId,
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    reason: trimmed,
  });

  return { ok: true, id: saleId };
}

export interface DeliveryRow {
  readonly id: string;
  readonly deliveryNumber: string;
  readonly deliveredAt: string;
  readonly saleId: string;
  readonly invoiceNumber: string;
  readonly customerName: string;
  readonly chassisNo: string;
  readonly modelLabel: string;
  readonly branchName: string;
  readonly receivedBy: string | null;
  readonly odometer: number | null;
  readonly remarks: string | null;
}

/**
 * Handovers already made — spec §19.
 *
 * The delivery is a document in its own right, not just a status on the sale:
 * it records who took the vehicle away and when, which is the part a dispute
 * later turns on.
 */
export async function getDeliveries(params: {
  readonly branchId: string | null;
  readonly q?: string;
  /**
   * Row cap. Defaults to the screen's, which is all anyone scrolls; the
   * report exporter raises it, because a spreadsheet has no such limit and a
   * silently truncated financial extract is worse than none.
   */
  readonly limit?: number;
}): Promise<DeliveryRow[]> {
  const context = await requirePermission('sales.view');
  const supabase = await createSupabaseServerClient();

  let query = supabase
    .from('deliveries')
    .select(
      'id, delivery_number, delivered_at, sale_id, received_by_name, odometer, remarks, sales!inner ( invoice_number, customers!inner ( name ) ), vehicles!inner ( chassis_no, vehicle_models ( brand, name ) ), branches!inner ( name )',
    )
    .order('delivered_at', { ascending: false })
    .limit(params.limit ?? 200);

  const branchId = resolveBranch(context, params.branchId);
  if (branchId) {
    query = query.eq('branch_id', branchId);
  }

  const { data, error } = await query;
  if (error) {
    throw new Error(`Failed to load deliveries: ${error.message}`);
  }

  const term = params.q?.trim().toLowerCase();

  return (data ?? [])
    .map((row) => ({
      id: row.id,
      deliveryNumber: row.delivery_number,
      deliveredAt: row.delivered_at,
      saleId: row.sale_id,
      invoiceNumber: row.sales.invoice_number,
      customerName: row.sales.customers.name,
      chassisNo: row.vehicles.chassis_no,
      modelLabel: `${row.vehicles.vehicle_models?.brand ?? ''} ${row.vehicles.vehicle_models?.name ?? ''}`.trim(),
      branchName: row.branches.name,
      receivedBy: row.received_by_name,
      odometer: row.odometer === null ? null : Number(row.odometer),
      remarks: row.remarks,
    }))
    .filter(
      (row) =>
        !term ||
        row.deliveryNumber.toLowerCase().includes(term) ||
        row.invoiceNumber.toLowerCase().includes(term) ||
        row.customerName.toLowerCase().includes(term) ||
        row.chassisNo.toLowerCase().includes(term),
    );
}
