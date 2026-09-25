import 'server-only';

import { requireTenantContext, type TenantContext } from '@/server/auth/tenant-context';
import { ForbiddenError } from '@/server/errors';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { add, fromDb, type Paise } from '@/lib/money';

/**
 * Quick service and counter bills (0088).
 *
 * The cashier types the customer's name, mobile and vehicle number and a value
 * per head; create_quick_bill() finds or adds the customer, splits the GST out
 * of each value, posts the bill and records the money received — one
 * transaction. No job card, no item, no stock.
 */

export type BillKind = 'SERVICE' | 'COUNTER';
export type BillHead = 'SPARES' | 'ACCESSORIES' | 'LABOUR' | 'WATERWASH' | 'CONSUMABLES' | 'OTHER';
export type PaymentMode = 'CASH' | 'UPI' | 'CARD' | 'NEFT' | 'CHEQUE';

export const SERVICE_HEADS: readonly { head: BillHead; label: string }[] = [
  { head: 'SPARES', label: 'Spares' },
  { head: 'LABOUR', label: 'Labour' },
  { head: 'WATERWASH', label: 'Water wash' },
  { head: 'CONSUMABLES', label: 'Other consumables' },
];

export const HEAD_LABEL: Record<BillHead, string> = {
  SPARES: 'Spares', ACCESSORIES: 'Accessories', LABOUR: 'Labour', WATERWASH: 'Water wash',
  CONSUMABLES: 'Other consumables', OTHER: 'Other charges',
};

export interface QuickBillLine {
  readonly head: BillHead;
  /** Rupees, GST included. */
  readonly amount: number;
  readonly description?: string | null;
}

export interface QuickBillResult {
  readonly ok: boolean;
  readonly error?: string;
  readonly invoiceId?: string;
  readonly invoiceNumber?: string;
  readonly receiptNumber?: string | null;
}

async function requireBilling(kind: BillKind | 'ANY'): Promise<TenantContext> {
  const context = await requireTenantContext();
  const p = context.permissions;
  const ok = kind === 'SERVICE' ? p.has('service.billing.create')
    : kind === 'COUNTER' ? p.has('inventory.counter_sale.create') || p.has('service.billing.create')
    : p.has('service.billing.create') || p.has('inventory.counter_sale.create');
  if (!ok) throw new ForbiddenError(kind === 'COUNTER' ? 'inventory.counter_sale.create' : 'service.billing.create');
  return context;
}

const MOBILE = /^[6-9][0-9]{9}$/;

export async function createQuickBill(input: {
  readonly kind: BillKind;
  readonly branchId?: string | null;
  readonly customerName: string;
  readonly mobile: string;
  readonly vehicleNo: string;
  readonly lines: readonly QuickBillLine[];
  readonly paymentMode: PaymentMode;
  /** Rupees; null takes the whole bill. */
  readonly amountReceived: number | null;
  readonly reference?: string | null;
  readonly idempotencyKey: string;
}): Promise<QuickBillResult> {
  const context = await requireBilling(input.kind);
  const lines = input.lines.filter((l) => l.amount > 0);
  const mobile = input.mobile.replace(/\D/g, '').slice(-10);

  if (lines.length === 0) return { ok: false, error: 'Enter at least one amount.' };
  if (mobile && !MOBILE.test(mobile)) return { ok: false, error: 'Enter a 10-digit mobile number starting 6–9.' };
  if (input.kind === 'SERVICE' && !input.vehicleNo.trim()) return { ok: false, error: 'Enter the vehicle number.' };
  if (input.kind === 'COUNTER' && lines.some((l) => !l.description?.trim())) {
    return { ok: false, error: 'Type the product name on every line.' };
  }
  const branchId = input.branchId || context.activeBranch?.id;
  if (!branchId) return { ok: false, error: 'Choose your branch first.' };

  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('create_quick_bill', {
    p_kind: input.kind,
    p_branch_id: branchId,
    p_customer_name: input.customerName.trim(),
    p_mobile: mobile,
    p_vehicle_no: input.vehicleNo.trim(),
    p_lines: lines.map((l) => ({ head: l.head, amount: l.amount, description: l.description?.trim() || null })) as never,
    p_payment_mode: input.paymentMode,
    p_amount_received: input.amountReceived ?? undefined,
    p_reference: input.reference?.trim() || undefined,
    p_idempotency_key: input.idempotencyKey,
  });
  if (error) {
    console.error('[billing] quick bill failed', error.message);
    return { ok: false, error: error.message };
  }
  const row = Array.isArray(data) ? data[0] : data;
  return {
    ok: true,
    invoiceId: row?.invoice_id,
    invoiceNumber: row?.invoice_number,
    receiptNumber: row?.receipt_number ?? null,
  };
}

export interface BillCustomerMatch {
  readonly id: string;
  readonly name: string;
  readonly mobile: string | null;
  readonly customerCode: string;
  readonly vehicles: readonly string[];
  readonly matchedBy: 'MOBILE' | 'VEHICLE';
}

/** Someone who has been here before: by mobile, else by vehicle number. */
export async function findBillCustomer(input: { readonly mobile?: string; readonly vehicleNo?: string }): Promise<BillCustomerMatch | null> {
  await requireBilling('ANY');
  const supabase = await createSupabaseServerClient();
  const mobile = (input.mobile ?? '').replace(/\D/g, '').slice(-10);
  const vehicle = (input.vehicleNo ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');

  let customerId: string | null = null;
  let matchedBy: 'MOBILE' | 'VEHICLE' = 'MOBILE';
  if (MOBILE.test(mobile)) {
    const { data } = await supabase.from('customers').select('id').eq('mobile', mobile).maybeSingle();
    customerId = data?.id ?? null;
  }
  if (!customerId && vehicle.length >= 4) {
    const { data } = await supabase.from('customer_vehicles').select('customer_id, registration_no')
      .ilike('registration_no', `%${vehicle.slice(-4)}%`).limit(50);
    const hit = (data ?? []).find((v) => (v.registration_no ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '') === vehicle);
    customerId = hit?.customer_id ?? null;
    matchedBy = 'VEHICLE';
  }
  if (!customerId) return null;

  const [{ data: customer }, { data: vehicles }] = await Promise.all([
    supabase.from('customers').select('id, name, mobile, customer_code').eq('id', customerId).maybeSingle(),
    supabase.from('customer_vehicles').select('registration_no').eq('customer_id', customerId),
  ]);
  if (!customer) return null;
  return {
    id: customer.id, name: customer.name, mobile: customer.mobile, customerCode: customer.customer_code,
    vehicles: (vehicles ?? []).map((v) => v.registration_no).filter((v): v is string => !!v),
    matchedBy,
  };
}

export interface BillRow {
  readonly id: string;
  readonly number: string;
  readonly date: string;
  readonly customerName: string | null;
  readonly mobile: string | null;
  readonly vehicleNo: string | null;
  readonly total: Paise;
  readonly paid: Paise;
  readonly balance: Paise;
  readonly status: string;
}

export async function getRecentBills(kind: BillKind, limit = 100): Promise<BillRow[]> {
  await requireBilling(kind);
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.from('service_invoices')
    .select('id, invoice_number, invoice_date, vehicle_registration, total_amount, paid_amount, status, customers ( name, mobile )')
    .eq('invoice_type', kind)
    .order('created_at', { ascending: false })
    .limit(limit);
  if (error) throw new Error(`Failed to load bills: ${error.message}`);
  return (data ?? []).map((b) => ({
    id: b.id, number: b.invoice_number, date: b.invoice_date,
    customerName: b.customers?.name ?? null, mobile: b.customers?.mobile ?? null,
    vehicleNo: b.vehicle_registration, total: fromDb(b.total_amount), paid: fromDb(b.paid_amount),
    balance: (fromDb(b.total_amount) - fromDb(b.paid_amount)) as Paise, status: b.status,
  }));
}

export interface PrintableBill {
  readonly kind: BillKind;
  readonly number: string;
  readonly date: string;
  readonly seller: { name: string; address: string; gstin: string | null; phone: string | null };
  readonly customer: { name: string; mobile: string | null; code: string | null } | null;
  readonly vehicleNo: string | null;
  readonly lines: readonly { description: string; amount: Paise }[];
  readonly taxable: Paise;
  readonly cgst: Paise;
  readonly sgst: Paise;
  readonly igst: Paise;
  readonly total: Paise;
  readonly receipts: readonly { number: string; date: string; mode: string; amount: Paise; reference: string | null }[];
  readonly paid: Paise;
  readonly balance: Paise;
  readonly billOfSupply: boolean;
}

export async function getPrintableBill(id: string): Promise<PrintableBill | null> {
  await requireBilling('ANY');
  const supabase = await createSupabaseServerClient();
  const { data: bill } = await supabase.from('service_invoices')
    .select('id, invoice_type, invoice_number, invoice_date, vehicle_registration, taxable_value, cgst_amount, sgst_amount, igst_amount, total_amount, paid_amount, dealer_id, branch_id, customers ( name, mobile, customer_code ), job_cards ( registration_no )')
    .eq('id', id).maybeSingle();
  if (!bill) return null;

  const [{ data: lines }, { data: pays }, { data: branch }, { data: dealer }] = await Promise.all([
    supabase.from('service_lines').select('description, total_amount, line_number').eq('invoice_id', id).order('line_number'),
    supabase.from('service_payments').select('receipt_number, payment_date, payment_mode, amount, reference, status')
      .eq('invoice_id', id).order('created_at'),
    supabase.from('branches').select('name, gstin, address_line1, address_line2, city, pincode, phone').eq('id', bill.branch_id).maybeSingle(),
    supabase.from('dealers').select('legal_name, trade_name, gstin, phone').eq('id', bill.dealer_id).maybeSingle(),
  ]);
  const tax = add(fromDb(bill.cgst_amount), fromDb(bill.sgst_amount), fromDb(bill.igst_amount));
  const receipts = (pays ?? []).filter((p) => p.status !== 'REVERSED').map((p) => ({
    number: p.receipt_number, date: p.payment_date, mode: p.payment_mode, amount: fromDb(p.amount), reference: p.reference,
  }));
  return {
    kind: bill.invoice_type as BillKind,
    number: bill.invoice_number,
    date: bill.invoice_date,
    seller: {
      name: dealer?.trade_name || dealer?.legal_name || '',
      address: [branch?.address_line1, branch?.address_line2, branch?.city, branch?.pincode].filter(Boolean).join(', '),
      gstin: branch?.gstin || dealer?.gstin || null,
      phone: branch?.phone || dealer?.phone || null,
    },
    customer: bill.customers ? { name: bill.customers.name, mobile: bill.customers.mobile, code: bill.customers.customer_code } : null,
    vehicleNo: bill.vehicle_registration ?? bill.job_cards?.registration_no ?? null,
    lines: (lines ?? []).map((l) => ({ description: l.description, amount: fromDb(l.total_amount) })),
    taxable: fromDb(bill.taxable_value),
    cgst: fromDb(bill.cgst_amount), sgst: fromDb(bill.sgst_amount), igst: fromDb(bill.igst_amount),
    total: fromDb(bill.total_amount),
    receipts,
    paid: fromDb(bill.paid_amount),
    balance: (fromDb(bill.total_amount) - fromDb(bill.paid_amount)) as Paise,
    billOfSupply: tax === 0,
  };
}

// ── Settings: the GST code for each head ─────────────────────────────────────

export async function getQuickBillTaxCodes(): Promise<{ codes: Record<BillHead, string>; options: { value: string; label: string }[] }> {
  const context = await requireTenantContext();
  if (!context.permissions.has('admin.settings.manage')) throw new ForbiddenError('admin.settings.manage');
  const supabase = await createSupabaseServerClient();
  const [{ data: setting }, { data: codes }] = await Promise.all([
    supabase.from('system_settings').select('value').eq('key', 'quick_bill.tax_codes').eq('dealer_id', context.dealerId!).maybeSingle(),
    supabase.from('tax_codes').select('code, name').eq('status', 'ACTIVE').is('effective_to', null).order('code'),
  ]);
  const value = (setting?.value ?? {}) as Partial<Record<BillHead, string>>;
  const heads: BillHead[] = ['SPARES', 'ACCESSORIES', 'LABOUR', 'WATERWASH', 'CONSUMABLES', 'OTHER'];
  return {
    codes: Object.fromEntries(heads.map((h) => [h, value[h] ?? 'GST18'])) as Record<BillHead, string>,
    options: (codes ?? []).map((c) => ({ value: c.code, label: `${c.code} · ${c.name}` })),
  };
}

export async function setQuickBillTaxCodes(codes: Record<BillHead, string>): Promise<{ ok: boolean; error?: string; message?: string }> {
  const context = await requireTenantContext();
  if (!context.permissions.has('admin.settings.manage')) return { ok: false, error: 'You may not change settings.' };
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.from('system_settings').upsert({
    dealer_id: context.dealerId!, key: 'quick_bill.tax_codes', value: codes as never, value_type: 'json',
    description: 'GST code applied to each head of a quick service or counter bill (values entered are GST-inclusive).',
    is_public: true, updated_by: context.userId,
  }, { onConflict: 'dealer_id,key' });
  return error ? { ok: false, error: error.message } : { ok: true, message: 'Saved. New bills use these rates.' };
}
