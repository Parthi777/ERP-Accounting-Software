import 'server-only';

import { requirePermission, requireTenantContext, type TenantContext } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { formatINR, fromDb, type Paise } from '@/lib/money';
import { recordAudit } from '@/server/services/audit/record-audit';

/**
 * The service workshop — spec §32, §33.
 *
 * Job card → work → bill → post → collect. Parts consumed on a job leave stock
 * LOCAL before COMPANY, the same rule as a vehicle fitting (spec §31), and the
 * source is recorded on the line so the bill stays explainable afterwards.
 */

export interface JobCardRow {
  readonly id: string;
  readonly number: string;
  readonly jobDate: string;
  readonly customerName: string;
  readonly customerId: string;
  readonly registrationNo: string | null;
  readonly serviceType: string;
  readonly complaint: string | null;
  readonly status: string;
  readonly branchName: string;
  readonly advisorName: string | null;
  readonly invoiceId: string | null;
  readonly invoiceNumber: string | null;
  readonly invoiceTotal: Paise;
}

export interface ServiceLine {
  readonly id: string;
  readonly lineNumber: number;
  readonly lineType: string;
  readonly description: string;
  readonly quantity: number;
  readonly unitRate: Paise;
  readonly discount: Paise;
  readonly taxableValue: Paise;
  readonly cgst: Paise;
  readonly sgst: Paise;
  readonly total: Paise;
  readonly stockSource: string | null;
}

export interface ServiceInvoiceDetail {
  readonly id: string;
  readonly number: string;
  readonly invoiceDate: string;
  readonly status: string;
  readonly customerName: string | null;
  readonly jobCardNumber: string | null;
  readonly jobCardId: string | null;
  readonly taxableValue: Paise;
  readonly cgst: Paise;
  readonly sgst: Paise;
  readonly igst: Paise;
  readonly total: Paise;
  readonly paid: Paise;
  readonly balance: Paise;
  readonly journalEntryId: string | null;
  readonly lines: readonly ServiceLine[];
}

export interface ServiceResult {
  readonly ok: boolean;
  readonly error?: string;
  readonly message?: string;
  readonly id?: string;
  readonly number?: string;
}

function branchFilter(context: TenantContext, requested?: string | null): string | null {
  if (requested && context.accessibleBranches.some((b) => b.id === requested)) {
    return requested;
  }
  return context.hasAllBranchAccess ? null : (context.activeBranch?.id ?? null);
}

function describeServiceError(message: string): string {
  if (message.includes('Not enough stock')) {
    return message.replace('Not enough stock:', 'Not enough stock at this branch:');
  }
  if (message.includes('already has an invoice')) {
    return 'This job card has already been billed.';
  }
  if (message.includes('can no longer be edited')) {
    return 'This invoice has been posted and can no longer be edited.';
  }
  if (message.includes('No accounting rule')) {
    return 'A ledger account for this invoice is not configured. Set it under Administration → Accounting rules.';
  }
  if (message.includes('period') && message.includes('closed')) {
    return 'The accounting period for this date is closed.';
  }
  if (message.includes('No document sequence')) {
    return 'No document number sequence is configured for this financial year.';
  }
  return message;
}

export async function getJobCards(params: {
  readonly status: string;
  readonly branchId?: string | null;
  readonly q?: string;
  /**
   * Row cap. Defaults to the screen's, which is all anyone scrolls; the
   * report exporter raises it, because a spreadsheet has no such limit and a
   * silently truncated financial extract is worse than none.
   */
  readonly limit?: number;
}): Promise<JobCardRow[]> {
  const context = await requirePermission('service.jobcards.view');
  const supabase = await createSupabaseServerClient();

  let query = supabase
    .from('job_cards')
    .select(
      'id, job_card_number, job_date, registration_no, service_type, complaint, status, customer_id, customers!inner ( name ), branches!inner ( name ), employees!jc_advisor_tenant_fkey ( name ), service_invoices ( id, invoice_number, total_amount, status )',
    )
    .order('job_date', { ascending: false })
    .limit(params.limit ?? 200);

  if (params.status !== 'ALL') {
    query = query.eq('status', params.status as 'OPEN');
  }
  const branchId = branchFilter(context, params.branchId);
  if (branchId) {
    query = query.eq('branch_id', branchId);
  }

  const { data, error } = await query;
  if (error) {
    throw new Error(`Failed to load job cards: ${error.message}`);
  }

  const term = params.q?.trim().toLowerCase();

  return (data ?? [])
    .map((row) => {
      // A cancelled bill does not represent the job card any more.
      const invoice = (row.service_invoices ?? []).find((i) => i.status !== 'CANCELLED') ?? null;
      return {
        id: row.id,
        number: row.job_card_number,
        jobDate: row.job_date,
        customerName: row.customers.name,
        customerId: row.customer_id,
        registrationNo: row.registration_no,
        serviceType: row.service_type,
        complaint: row.complaint,
        status: row.status,
        branchName: row.branches.name,
        advisorName: row.employees?.name ?? null,
        invoiceId: invoice?.id ?? null,
        invoiceNumber: invoice?.invoice_number ?? null,
        invoiceTotal: fromDb(invoice?.total_amount ?? 0),
      };
    })
    .filter((row) =>
      !term ||
      row.number.toLowerCase().includes(term) ||
      row.customerName.toLowerCase().includes(term) ||
      (row.registrationNo ?? '').toLowerCase().includes(term),
    );
}

export async function getServiceInvoice(id: string): Promise<ServiceInvoiceDetail | null> {
  await requirePermission('service.jobcards.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase
    .from('service_invoices')
    .select(
      'id, invoice_number, invoice_date, status, taxable_value, cgst_amount, sgst_amount, igst_amount, total_amount, paid_amount, journal_entry_id, job_card_id, customers ( name ), job_cards ( job_card_number ), service_lines ( id, line_number, line_type, description, quantity, unit_rate, discount, taxable_value, cgst_amount, sgst_amount, total_amount, stock_source )',
    )
    .eq('id', id)
    .maybeSingle();

  if (error) {
    throw new Error(`Failed to load the invoice: ${error.message}`);
  }
  if (!data) return null;

  const total = fromDb(data.total_amount);
  const paid = fromDb(data.paid_amount);

  return {
    id: data.id,
    number: data.invoice_number,
    invoiceDate: data.invoice_date,
    status: data.status,
    customerName: data.customers?.name ?? null,
    jobCardNumber: data.job_cards?.job_card_number ?? null,
    jobCardId: data.job_card_id,
    taxableValue: fromDb(data.taxable_value),
    cgst: fromDb(data.cgst_amount),
    sgst: fromDb(data.sgst_amount),
    igst: fromDb(data.igst_amount),
    total,
    paid,
    balance: (total - paid) as Paise,
    journalEntryId: data.journal_entry_id,
    lines: (data.service_lines ?? [])
      .map((line) => ({
        id: line.id,
        lineNumber: line.line_number,
        lineType: line.line_type,
        description: line.description,
        quantity: Number(line.quantity),
        unitRate: fromDb(line.unit_rate),
        discount: fromDb(line.discount),
        taxableValue: fromDb(line.taxable_value),
        cgst: fromDb(line.cgst_amount),
        sgst: fromDb(line.sgst_amount),
        total: fromDb(line.total_amount),
        stockSource: line.stock_source,
      }))
      .sort((a, b) => a.lineNumber - b.lineNumber),
  };
}

export interface CreateJobCardInput {
  readonly customerId: string;
  readonly serviceType: string;
  readonly registrationNo?: string | null;
  readonly odometer?: number | null;
  readonly complaint?: string | null;
  readonly serviceAdvisorId?: string | null;
  readonly technicianId?: string | null;
  readonly promisedAt?: string | null;
}

export async function createJobCard(input: CreateJobCardInput): Promise<ServiceResult> {
  const context = await requirePermission('service.jobcards.create');
  const supabase = await createSupabaseServerClient();

  if (!context.activeBranch) {
    return { ok: false, error: 'Select a branch before opening a job card.' };
  }
  if (!input.customerId) {
    return { ok: false, error: 'Choose a customer.' };
  }

  const { data, error } = await supabase.rpc('create_job_card', {
    p_branch_id: context.activeBranch.id,
    p_customer_id: input.customerId,
    p_service_type: input.serviceType,
    p_registration_no: input.registrationNo || null,
    p_odometer: input.odometer ?? null,
    p_complaint: input.complaint || null,
    p_service_advisor_id: input.serviceAdvisorId || null,
    p_technician_id: input.technicianId || null,
    p_promised_at: input.promisedAt || null,
  });

  if (error) {
    console.error('[service] job card failed', error.message);
    return { ok: false, error: describeServiceError(error.message) };
  }

  const row = Array.isArray(data) ? data[0] : data;

  await recordAudit({
    action: 'CREATE',
    entityType: 'job_cards',
    entityId: row?.job_card_id ?? '',
    dealerId: context.dealerId,
    branchId: context.activeBranch.id,
    userId: context.userId,
    userEmail: context.email,
    newData: { job_card_number: row?.job_card_number, registration_no: input.registrationNo },
  });

  return { ok: true, id: row?.job_card_id, number: row?.job_card_number };
}

export async function updateJobCardStatus(id: string, status: string): Promise<ServiceResult> {
  const context = await requirePermission('service.jobcards.create');
  const supabase = await createSupabaseServerClient();

  const { error } = await supabase
    .from('job_cards')
    .update({ status: status as 'OPEN', updated_by: context.userId })
    .eq('id', id);

  if (error) {
    return { ok: false, error: describeServiceError(error.message) };
  }

  await recordAudit({
    action: 'UPDATE',
    entityType: 'job_cards',
    entityId: id,
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { status },
  });

  return { ok: true, message: `Job card marked ${status.toLowerCase().replace('_', ' ')}.` };
}

export async function createServiceInvoice(jobCardId: string): Promise<ServiceResult> {
  const context = await requirePermission('service.billing.create');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('create_service_invoice', {
    p_job_card_id: jobCardId,
  });

  if (error) {
    return { ok: false, error: describeServiceError(error.message) };
  }

  const row = Array.isArray(data) ? data[0] : data;

  await recordAudit({
    action: 'CREATE',
    entityType: 'service_invoices',
    entityId: row?.invoice_id ?? '',
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { invoice_number: row?.invoice_number, job_card_id: jobCardId },
  });

  return { ok: true, id: row?.invoice_id, number: row?.invoice_number };
}

export interface ServiceLineInput {
  readonly invoiceId: string;
  readonly lineType: string;
  readonly description: string;
  readonly quantity: number;
  readonly unitRate: number;
  readonly itemId?: string | null;
  readonly taxCode?: string | null;
  readonly discount?: number;
}

export async function addServiceLine(input: ServiceLineInput): Promise<ServiceResult> {
  await requirePermission('service.billing.create');
  const supabase = await createSupabaseServerClient();

  if (!input.description.trim()) {
    return { ok: false, error: 'Describe the line.' };
  }
  if (!(input.quantity > 0)) {
    return { ok: false, error: 'Quantity must be greater than zero.' };
  }

  const { data, error } = await supabase.rpc('add_service_line', {
    p_invoice_id: input.invoiceId,
    p_line_type: input.lineType,
    p_description: input.description.trim(),
    p_quantity: input.quantity,
    p_unit_rate: input.unitRate,
    p_item_id: input.itemId || null,
    p_tax_code: input.taxCode || null,
    p_discount: input.discount ?? 0,
  });

  if (error) {
    return { ok: false, error: describeServiceError(error.message) };
  }

  return { ok: true, id: data ?? undefined };
}

export async function removeServiceLine(lineId: string): Promise<ServiceResult> {
  await requirePermission('service.billing.create');
  const supabase = await createSupabaseServerClient();

  const { error } = await supabase.rpc('remove_service_line', { p_line_id: lineId });
  if (error) {
    return { ok: false, error: describeServiceError(error.message) };
  }
  return { ok: true };
}

export async function postServiceInvoice(invoiceId: string): Promise<ServiceResult> {
  const context = await requirePermission('service.billing.create');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('post_service_invoice', {
    p_invoice_id: invoiceId,
    p_idempotency_key: `service:${invoiceId}`,
  });

  if (error) {
    console.error('[service] posting failed', error.message);
    return { ok: false, error: describeServiceError(error.message) };
  }

  await recordAudit({
    action: 'POST',
    entityType: 'service_invoices',
    entityId: invoiceId,
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { journal_entry_id: data },
  });

  return { ok: true, message: 'Posted. Revenue, GST, cost and stock all moved together.' };
}

export async function recordServicePayment(input: {
  readonly invoiceId: string;
  readonly amount: number;
  readonly mode: string;
  readonly reference?: string | null;
}): Promise<ServiceResult> {
  const context = await requirePermission('service.payments.collect');
  const supabase = await createSupabaseServerClient();

  if (!(input.amount > 0)) {
    return { ok: false, error: 'Enter an amount greater than zero.' };
  }

  const { data, error } = await supabase.rpc('record_service_payment', {
    p_invoice_id: input.invoiceId,
    p_amount: input.amount,
    p_payment_mode: input.mode,
    p_reference: input.reference?.trim() || null,
  });

  if (error) {
    return { ok: false, error: describeServiceError(error.message) };
  }

  const row = Array.isArray(data) ? data[0] : data;
  const balance = fromDb(row?.balance_due ?? 0);

  await recordAudit({
    action: 'CREATE',
    entityType: 'service_payments',
    entityId: row?.payment_id ?? '',
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { receipt_number: row?.receipt_number, amount: input.amount, mode: input.mode },
  });

  return {
    ok: true,
    number: row?.receipt_number,
    message:
      balance === 0
        ? `Receipt ${row?.receipt_number}. The invoice is settled in full.`
        : `Receipt ${row?.receipt_number}. ${formatINR(balance)} still outstanding.`,
  };
}

export interface ServiceHistoryRow {
  readonly jobCardId: string;
  readonly number: string;
  readonly jobDate: string;
  readonly customerName: string;
  readonly registrationNo: string | null;
  readonly odometer: number | null;
  readonly serviceType: string;
  readonly complaint: string | null;
  readonly status: string;
  readonly invoiceNumber: string | null;
  readonly invoiceTotal: Paise;
  readonly paid: Paise;
}

export async function getServiceHistory(params: {
  readonly customerId?: string | null;
  readonly registrationNo?: string | null;
}): Promise<ServiceHistoryRow[]> {
  await requirePermission('service.history.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('service_history', {
    p_customer_id: params.customerId || null,
    p_registration_no: params.registrationNo?.trim() || null,
  });

  if (error) {
    throw new Error(`Failed to load service history: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    jobCardId: row.job_card_id,
    number: row.job_card_number,
    jobDate: row.job_date,
    customerName: row.customer_name,
    registrationNo: row.registration_no,
    odometer: row.odometer != null ? Number(row.odometer) : null,
    serviceType: row.service_type,
    complaint: row.complaint,
    status: row.status,
    invoiceNumber: row.invoice_number,
    invoiceTotal: fromDb(row.invoice_total),
    paid: fromDb(row.paid_amount),
  }));
}

/** Spare and accessory items a service line can draw on, with stock at the branch. */
export async function getServiceItems(): Promise<
  { id: string; code: string; name: string; rate: Paise; taxCode: string | null; onHand: number }[]
> {
  const context = await requirePermission('service.billing.create');
  const supabase = await createSupabaseServerClient();

  const [items, stock] = await Promise.all([
    supabase
      .from('inventory_items')
      .select('id, item_code, name, selling_price, tax_code')
      .eq('status', 'ACTIVE')
      .order('name')
      .limit(1000),
    context.activeBranch
      ? supabase
          .from('inventory_stock')
          .select('item_id, quantity')
          .eq('branch_id', context.activeBranch.id)
      : Promise.resolve({ data: [], error: null }),
  ]);

  if (items.error) {
    throw new Error(`Failed to load items: ${items.error.message}`);
  }

  // LOCAL and COMPANY are separate lots; the picker shows the total available.
  const onHand = new Map<string, number>();
  for (const row of stock.data ?? []) {
    onHand.set(row.item_id, (onHand.get(row.item_id) ?? 0) + Number(row.quantity));
  }

  return (items.data ?? []).map((row) => ({
    id: row.id,
    code: row.item_code,
    name: row.name,
    rate: fromDb(row.selling_price),
    taxCode: row.tax_code,
    onHand: onHand.get(row.id) ?? 0,
  }));
}

export interface ServiceInvoiceRow {
  readonly id: string;
  readonly number: string;
  readonly invoiceDate: string;
  readonly customerName: string | null;
  readonly jobCardNumber: string | null;
  readonly branchName: string;
  readonly total: Paise;
  readonly paid: Paise;
  readonly balance: Paise;
  readonly status: string;
}

export async function getServiceInvoices(params: {
  readonly status: string;
  readonly branchId?: string | null;
  /**
   * Row cap. Defaults to the screen's, which is all anyone scrolls; the
   * report exporter raises it, because a spreadsheet has no such limit and a
   * silently truncated financial extract is worse than none.
   */
  readonly limit?: number;
}): Promise<ServiceInvoiceRow[]> {
  const context = await requirePermission('service.jobcards.view');
  const supabase = await createSupabaseServerClient();

  let query = supabase
    .from('service_invoices')
    .select(
      'id, invoice_number, invoice_date, total_amount, paid_amount, status, customers ( name ), job_cards ( job_card_number ), branches!inner ( name )',
    )
    // Counter sales share this table but are their own screen (spec §33).
    .eq('invoice_type', 'SERVICE')
    .order('invoice_date', { ascending: false })
    .limit(params.limit ?? 200);

  if (params.status !== 'ALL') {
    query = query.eq('status', params.status as 'DRAFT');
  }
  const branchId = branchFilter(context, params.branchId);
  if (branchId) {
    query = query.eq('branch_id', branchId);
  }

  const { data, error } = await query;
  if (error) {
    throw new Error(`Failed to load service invoices: ${error.message}`);
  }

  return (data ?? []).map((row) => {
    const total = fromDb(row.total_amount);
    const paid = fromDb(row.paid_amount);
    return {
      id: row.id,
      number: row.invoice_number,
      invoiceDate: row.invoice_date,
      customerName: row.customers?.name ?? null,
      jobCardNumber: row.job_cards?.job_card_number ?? null,
      branchName: row.branches.name,
      total,
      paid,
      balance: (total - paid) as Paise,
      status: row.status,
    };
  });
}

// ── Per-customer service rollup — spec §33 ───────────────────────────────────

export interface CustomerServiceRollup {
  readonly customerId: string;
  readonly customerCode: string;
  readonly customerName: string;
  readonly mobile: string | null;
  readonly vehicleCount: number;
  readonly visitCount: number;
  readonly firstVisit: string | null;
  readonly lastVisit: string | null;
  readonly daysSinceLastVisit: number | null;
  readonly lifetimeValue: Paise;
  readonly openJobs: number;
  /** Nothing for six months. The dealer's cue to call them. */
  readonly serviceDue: boolean;
}

/** Roughly two services a year, so half a year of silence is worth chasing. */
const SERVICE_DUE_DAYS = 180;

/**
 * Who has been in, how often, what they are worth, and who has stopped coming.
 *
 * Deliberately not another per-visit list — `/service/history` already answers
 * "what happened on this job". This answers the questions a per-visit list
 * cannot: which customers are lapsing, and which are worth the most.
 */
export async function getCustomerServiceRollup(params: {
  readonly customerId?: string | null;
  readonly branchId?: string | null;
  readonly dueOnly?: boolean;
}): Promise<CustomerServiceRollup[]> {
  const context = await requirePermission('service.history.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('customer_service_summary', {
    p_customer_id: params.customerId || null,
    p_branch_id: branchFilter(context, params.branchId ?? null),
  });

  if (error) {
    throw new Error(`Failed to load the service rollup: ${error.message}`);
  }

  return (data ?? [])
    .map((row) => ({
      customerId: row.customer_id,
      customerCode: row.customer_code,
      customerName: row.customer_name,
      mobile: row.mobile,
      vehicleCount: row.vehicle_count,
      visitCount: row.visit_count,
      firstVisit: row.first_visit,
      lastVisit: row.last_visit,
      daysSinceLastVisit: row.days_since_last,
      lifetimeValue: fromDb(row.lifetime_value),
      openJobs: row.open_jobs,
      serviceDue: (row.days_since_last ?? 0) >= SERVICE_DUE_DAYS,
    }))
    .filter((row) => !params.dueOnly || row.serviceDue);
}

// ── Counter sales — spec §33 ─────────────────────────────────────────────────

/**
 * Over-the-counter accessory and spare sales.
 *
 * They live in `service_invoices` with `invoice_type = 'COUNTER'` and no job
 * card, so lines, posting, stock allocation and payment all reuse the service
 * billing engine above. Spec §60.18 wants one accounting path, not two.
 */
export async function getCounterInvoices(params: {
  readonly status: string;
  readonly branchId?: string | null;
  /**
   * Row cap. Defaults to the screen's, which is all anyone scrolls; the
   * report exporter raises it, because a spreadsheet has no such limit and a
   * silently truncated financial extract is worse than none.
   */
  readonly limit?: number;
}): Promise<ServiceInvoiceRow[]> {
  const context = await requirePermission('inventory.counter_sale.create');
  const supabase = await createSupabaseServerClient();

  let query = supabase
    .from('service_invoices')
    .select(
      'id, invoice_number, invoice_date, total_amount, paid_amount, status, customers ( name ), job_cards ( job_card_number ), branches!inner ( name )',
    )
    .eq('invoice_type', 'COUNTER')
    .order('invoice_date', { ascending: false })
    .limit(params.limit ?? 200);

  if (params.status !== 'ALL') {
    query = query.eq('status', params.status as 'DRAFT');
  }
  const branchId = branchFilter(context, params.branchId ?? null);
  if (branchId) {
    query = query.eq('branch_id', branchId);
  }

  const { data, error } = await query;
  if (error) {
    throw new Error(`Failed to load counter sales: ${error.message}`);
  }

  return (data ?? []).map((row) => {
    const total = fromDb(row.total_amount);
    const paid = fromDb(row.paid_amount);
    return {
      id: row.id,
      number: row.invoice_number,
      invoiceDate: row.invoice_date,
      customerName: row.customers?.name ?? null,
      jobCardNumber: null,
      branchName: row.branches.name,
      total,
      paid,
      balance: (total - paid) as Paise,
      status: row.status,
    };
  });
}

export async function createCounterInvoice(customerId?: string | null): Promise<ServiceResult> {
  const context = await requirePermission('inventory.counter_sale.create');
  const supabase = await createSupabaseServerClient();

  if (!context.activeBranch) {
    return { ok: false, error: 'Select a branch before starting a counter sale.' };
  }

  const { data, error } = await supabase.rpc('create_counter_invoice', {
    p_branch_id: context.activeBranch.id,
    p_customer_id: customerId || null,
  });

  if (error) {
    console.error('[counter] invoice failed', error.message);
    if (error.message.includes('requires a customer')) {
      return { ok: false, error: 'This dealer requires a customer on every counter sale.' };
    }
    return { ok: false, error: describeServiceError(error.message) };
  }

  const row = Array.isArray(data) ? data[0] : data;

  await recordAudit({
    action: 'CREATE',
    entityType: 'service_invoices',
    entityId: row?.invoice_id ?? null,
    dealerId: context.dealerId,
    branchId: context.activeBranch.id,
    userId: context.userId,
    userEmail: context.email,
    newData: { invoice_number: row?.invoice_number, invoice_type: 'COUNTER' },
  });

  return { ok: true, id: row?.invoice_id, number: row?.invoice_number };
}

/** Tax codes for the billing screens, so a page need not query the table itself. */
export async function getTaxCodeOptions(): Promise<readonly { code: string; label: string }[]> {
  await requireTenantContext();
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase
    .from('tax_codes')
    .select('code, name')
    .eq('status', 'ACTIVE')
    .order('code');

  if (error) {
    throw new Error(`Failed to load tax codes: ${error.message}`);
  }
  return (data ?? []).map((t) => ({ code: t.code, label: `${t.code} · ${t.name}` }));
}
