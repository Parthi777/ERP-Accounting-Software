import 'server-only';

import { requirePermission, type TenantContext } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { fromDb, type Paise } from '@/lib/money';
import { recordAudit } from '@/server/services/audit/record-audit';
import { isConfigured, submitEwayBill, submitToIrp } from '@/server/services/gst/irp-client';

/**
 * GST — spec §40.
 *
 * The returns side is derived from the invoices themselves, so it cannot drift
 * from them. The portal side is a queue: this product records what it intends to
 * file and what the portal said, and never lets a portal failure disturb an
 * accounting transaction that has already happened.
 *
 * `submitEinvoice()` below does call the portal, through irp-client.ts — which
 * is the only file that knows the portal exists, so swapping GSP is a change to
 * that file and nothing above it. Everything else here queues and reports.
 *
 * Without IRP credentials configured, submission returns NOT_CONFIGURED and the
 * invoice stays queued. The screens say so rather than inventing an IRN that
 * would look real and reconcile to nothing.
 */

export interface GstrSection {
  readonly section: string;
  readonly documentCount: number;
  readonly taxableValue: Paise;
  readonly cgst: Paise;
  readonly sgst: Paise;
  readonly igst: Paise;
  readonly totalTax: Paise;
  readonly invoiceValue: Paise;
}

export interface HsnSummaryRow {
  readonly hsnCode: string;
  readonly description: string;
  readonly taxableValue: Paise;
  readonly cgst: Paise;
  readonly sgst: Paise;
  readonly igst: Paise;
  readonly totalTax: Paise;
  readonly documentCount: number;
}

export interface GstDocumentRow {
  readonly documentType: string;
  readonly documentId: string;
  readonly documentNumber: string;
  readonly documentDate: string;
  readonly customerName: string;
  readonly gstin: string | null;
  readonly placeOfSupply: string | null;
  readonly section: string;
  readonly taxableValue: Paise;
  readonly cgst: Paise;
  readonly sgst: Paise;
  readonly igst: Paise;
  readonly invoiceValue: Paise;
  readonly einvoiceStatus: string;
  readonly irn: string | null;
}

export interface EinvoiceQueueRow {
  readonly einvoiceId: string | null;
  readonly documentType: string;
  readonly documentId: string;
  readonly documentNumber: string;
  readonly documentDate: string;
  readonly customerName: string;
  readonly gstin: string | null;
  readonly invoiceValue: Paise;
  readonly status: string;
  readonly irn: string | null;
  readonly ackNumber: string | null;
  readonly errorMessage: string | null;
  readonly attemptCount: number;
}

export interface EwayBillRow {
  readonly id: string;
  readonly documentType: string;
  readonly documentNumber: string;
  readonly status: string;
  readonly ewayBillNumber: string | null;
  readonly generatedAt: string | null;
  readonly validUntil: string | null;
  readonly transportMode: string | null;
  readonly vehicleNumber: string | null;
  readonly errorMessage: string | null;
}

export interface GstResult {
  readonly ok: boolean;
  readonly error?: string;
  readonly message?: string;
}

function resolveBranch(context: TenantContext, requested?: string | null): string | null {
  if (requested && context.accessibleBranches.some((b) => b.id === requested)) {
    return requested;
  }
  return context.hasAllBranchAccess ? null : (context.activeBranch?.id ?? null);
}

export async function getGstr1Summary(params: {
  readonly from: string;
  readonly to: string;
  readonly branchId?: string | null;
}): Promise<GstrSection[]> {
  const context = await requirePermission('gst.summary.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('gstr1_summary', {
    p_from: params.from,
    p_to: params.to,
    p_branch_id: resolveBranch(context, params.branchId),
  });

  if (error) {
    throw new Error(`Failed to load the GST summary: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    section: row.section,
    documentCount: Number(row.document_count),
    taxableValue: fromDb(row.taxable_value),
    cgst: fromDb(row.cgst_amount),
    sgst: fromDb(row.sgst_amount),
    igst: fromDb(row.igst_amount),
    totalTax: fromDb(row.total_tax),
    invoiceValue: fromDb(row.invoice_value),
  }));
}

export async function getHsnSummary(params: {
  readonly from: string;
  readonly to: string;
  readonly branchId?: string | null;
}): Promise<HsnSummaryRow[]> {
  const context = await requirePermission('gst.summary.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('gst_summary', {
    p_from: params.from,
    p_to: params.to,
    p_branch_id: resolveBranch(context, params.branchId),
  });

  if (error) {
    throw new Error(`Failed to load the HSN summary: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    hsnCode: row.hsn_code,
    description: row.description,
    taxableValue: fromDb(row.taxable_value),
    cgst: fromDb(row.cgst_amount),
    sgst: fromDb(row.sgst_amount),
    igst: fromDb(row.igst_amount),
    totalTax: fromDb(row.total_tax),
    documentCount: Number(row.document_count),
  }));
}

/**
 * Input tax credit for a period — spec §40, §41.
 *
 * The counterpart to getHsnSummary(). Output tax is what the dealer collected
 * and owes; this is what they paid on purchases and may set against it. Reported
 * separately and never netted here, because the two are declared separately on a
 * return and a single blended figure would hide which side moved.
 */
export async function getInputTaxSummary(params: {
  readonly from: string;
  readonly to: string;
  readonly branchId?: string | null;
}): Promise<HsnSummaryRow[]> {
  const context = await requirePermission('gst.summary.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('gst_input_summary', {
    p_from: params.from,
    p_to: params.to,
    p_branch_id: resolveBranch(context, params.branchId),
  });

  if (error) {
    throw new Error(`Failed to load input tax credit: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    hsnCode: row.hsn_code,
    description: row.description,
    taxableValue: fromDb(row.taxable_value),
    cgst: fromDb(row.cgst_amount),
    sgst: fromDb(row.sgst_amount),
    igst: fromDb(row.igst_amount),
    totalTax: fromDb(row.total_tax),
    documentCount: Number(row.document_count),
  }));
}

export async function getGstDocuments(params: {
  readonly from: string;
  readonly to: string;
  readonly branchId?: string | null;
  readonly section?: string | null;
}): Promise<GstDocumentRow[]> {
  const context = await requirePermission('gst.reports.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('gst_document_register', {
    p_from: params.from,
    p_to: params.to,
    p_branch_id: resolveBranch(context, params.branchId),
    p_section: params.section && params.section !== 'ALL' ? params.section : null,
  });

  if (error) {
    throw new Error(`Failed to load the document register: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    documentType: row.document_type,
    documentId: row.document_id,
    documentNumber: row.document_number,
    documentDate: row.document_date,
    customerName: row.customer_name,
    gstin: row.gstin,
    placeOfSupply: row.place_of_supply,
    section: row.section,
    taxableValue: fromDb(row.taxable_value),
    cgst: fromDb(row.cgst_amount),
    sgst: fromDb(row.sgst_amount),
    igst: fromDb(row.igst_amount),
    invoiceValue: fromDb(row.invoice_value),
    einvoiceStatus: row.einvoice_status,
    irn: row.irn,
  }));
}

export async function getEinvoiceQueue(params: {
  readonly from: string;
  readonly to: string;
  readonly branchId?: string | null;
}): Promise<EinvoiceQueueRow[]> {
  const context = await requirePermission('gst.summary.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('einvoice_queue', {
    p_from: params.from,
    p_to: params.to,
    p_branch_id: resolveBranch(context, params.branchId),
  });

  if (error) {
    throw new Error(`Failed to load the e-invoice queue: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    einvoiceId: row.einvoice_id,
    documentType: row.document_type,
    documentId: row.document_id,
    documentNumber: row.document_number,
    documentDate: row.document_date,
    customerName: row.customer_name,
    gstin: row.gstin,
    invoiceValue: fromDb(row.invoice_value),
    status: row.status,
    irn: row.irn,
    ackNumber: row.ack_number,
    errorMessage: row.error_message,
    attemptCount: Number(row.attempt_count),
  }));
}

export async function queueEinvoice(documentType: string, documentId: string): Promise<GstResult> {
  const context = await requirePermission('gst.einvoice.generate');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('queue_einvoice', {
    p_document_type: documentType,
    p_document_id: documentId,
  });

  if (error) {
    return { ok: false, error: describeGstError(error.message) };
  }

  await recordAudit({
    action: 'CREATE',
    entityType: 'einvoices',
    entityId: data ?? '',
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { document_type: documentType, document_id: documentId, status: 'PENDING' },
  });

  return {
    ok: true,
    message:
      'Queued for filing. It will be submitted once IRP credentials are configured for this dealer.',
  };
}

export async function getEwayBills(): Promise<EwayBillRow[]> {
  await requirePermission('gst.summary.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase
    .from('eway_bills')
    .select(
      'id, document_type, document_number, status, eway_bill_number, generated_at, valid_until, transport_mode, vehicle_number, error_message',
    )
    .order('created_at', { ascending: false })
    .limit(200);

  if (error) {
    throw new Error(`Failed to load e-way bills: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    id: row.id,
    documentType: row.document_type,
    documentNumber: row.document_number,
    status: row.status,
    ewayBillNumber: row.eway_bill_number,
    generatedAt: row.generated_at,
    validUntil: row.valid_until,
    transportMode: row.transport_mode,
    vehicleNumber: row.vehicle_number,
    errorMessage: row.error_message,
  }));
}

export async function queueEwayBill(input: {
  readonly documentType: string;
  readonly documentId: string;
  readonly transportMode?: string;
  readonly vehicleNumber?: string | null;
  readonly distanceKm?: number | null;
  readonly transporterId?: string | null;
  readonly transporterName?: string | null;
}): Promise<GstResult> {
  const context = await requirePermission('gst.ewaybill.generate');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('queue_eway_bill', {
    p_document_type: input.documentType,
    p_document_id: input.documentId,
    p_transport_mode: input.transportMode ?? 'ROAD',
    p_vehicle_number: input.vehicleNumber || null,
    p_distance_km: input.distanceKm ?? null,
    p_transporter_id: input.transporterId || null,
    p_transporter_name: input.transporterName || null,
  });

  if (error) {
    return { ok: false, error: describeGstError(error.message) };
  }

  await recordAudit({
    action: 'CREATE',
    entityType: 'eway_bills',
    entityId: data ?? '',
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { document_type: input.documentType, vehicle_number: input.vehicleNumber },
  });

  return { ok: true, message: 'Queued. It will be submitted once portal credentials are configured.' };
}

/**
 * Whether this dealer can actually reach the IRP.
 *
 * The screens use this to say "queued, not filed" honestly rather than implying
 * a submission that never happened.
 */
export async function getGstPortalStatus(): Promise<{
  readonly configured: boolean;
  readonly gstin: string | null;
}> {
  const context = await requirePermission('gst.summary.view');
  const supabase = await createSupabaseServerClient();

  const [dealer, setting] = await Promise.all([
    context.dealerId
      ? supabase.from('dealers').select('gstin').eq('id', context.dealerId).maybeSingle()
      : Promise.resolve({ data: null, error: null }),
    supabase.from('system_settings').select('value').eq('key', 'gst.irp_configured').maybeSingle(),
  ]);

  return {
    configured: setting.data?.value === true,
    gstin: dealer.data?.gstin ?? null,
  };
}

function describeGstError(message: string): string {
  if (message.includes('only a posted invoice')) {
    return 'Only a posted invoice can be filed. Post it first.';
  }
  if (message.includes('Document not found')) {
    return 'That document no longer exists.';
  }
  if (message.includes('Unsupported document type')) {
    return 'That kind of document cannot be filed.';
  }
  return message;
}

// ── Transmission to the portal — spec §40 ────────────────────────────────────

/**
 * Files one queued e-invoice with the IRP.
 *
 * The order is the point. The payload is built and stored *before* the request
 * leaves, so a lost reply still leaves evidence of what was sent; the portal is
 * then called; and whatever comes back is recorded — success or failure — as a
 * separate step.
 *
 * Nothing here touches the ledger. Spec §40 is explicit that an external failure
 * must not corrupt the accounting transaction: the invoice stays posted, the
 * e-invoice goes FAILED, and the queue offers a retry.
 */
export async function submitEinvoice(einvoiceId: string): Promise<GstResult> {
  const context = await requirePermission('gst.einvoice.generate');
  const supabase = await createSupabaseServerClient();

  // Build first. A document that cannot be represented — no seller GSTIN, no
  // lines — is our problem, not the portal's, and is worth saying before a
  // request goes out.
  const { data: payload, error: buildError } = await supabase.rpc('einvoice_payload', {
    p_einvoice_id: einvoiceId,
  });

  if (buildError) {
    console.error('[gst] payload build failed', buildError.message);
    return { ok: false, error: describeGstError(buildError.message) };
  }

  const { error: requestError } = await supabase.rpc('record_einvoice_request', {
    p_einvoice_id: einvoiceId,
    p_payload: payload as never,
  });

  if (requestError) {
    console.error('[gst] request record failed', requestError.message);
    if (requestError.message.includes('already generated')) {
      return { ok: false, error: 'This document has already been filed.' };
    }
    return { ok: false, error: describeGstError(requestError.message) };
  }

  const outcome = await submitToIrp(payload);

  // Record the result whichever way it went. A FAILED row with the portal's own
  // code is what makes the next attempt informed rather than hopeful.
  const { error: resultError } = await supabase.rpc('record_einvoice_result', {
    p_einvoice_id: einvoiceId,
    p_status: outcome.ok ? 'GENERATED' : 'FAILED',
    p_irn: outcome.ok ? outcome.irn : null,
    p_ack_number: outcome.ok ? outcome.ackNumber : null,
    p_ack_date: outcome.ok ? outcome.ackDate : null,
    p_qr_code: outcome.ok ? outcome.signedQr : null,
    p_error_code: outcome.ok ? null : outcome.code,
    p_error: outcome.ok ? null : outcome.message,
    p_response: (outcome.raw ?? null) as never,
  });

  if (resultError) {
    // The portal may well have accepted it. Say so rather than implying failure.
    console.error('[gst] result record failed', resultError.message);
    return {
      ok: false,
      error:
        'The portal responded but the result could not be saved. Check the queue before filing again.',
    };
  }

  await recordAudit({
    action: 'POST',
    entityType: 'einvoices',
    entityId: einvoiceId,
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: outcome.ok
      ? { status: 'GENERATED', irn: outcome.irn }
      : { status: 'FAILED', code: outcome.code },
  });

  if (!outcome.ok) {
    return { ok: false, error: outcome.message };
  }
  return { ok: true, message: `Filed. IRN ${outcome.irn.slice(0, 16)}…` };
}

/** Whether a provider is wired up, so the UI can offer filing or explain why not. */
export async function getIrpConfiguration(): Promise<{
  readonly configured: boolean;
}> {
  await requirePermission('gst.summary.view');
  return { configured: isConfigured() };
}

// ─────────────────────────────────────────────────────────────────────────────
// E-way bills — spec §40
// ─────────────────────────────────────────────────────────────────────────────

export interface EwayRequirement {
  readonly required: boolean;
  readonly consignmentValue: Paise;
  readonly threshold: Paise;
  readonly interstate: boolean;
  /** The bill already raised against this document, if there is one. */
  readonly existing: {
    readonly id: string;
    readonly status: string;
    readonly number: string | null;
    readonly validUntil: string | null;
    readonly error: string | null;
  } | null;
}

/**
 * Whether Rule 138 requires an e-way bill for a sale, and whether one exists.
 *
 * Asked by the sale screen so the answer is in front of whoever is about to hand
 * over a vehicle. "No" is a claim the dealer relies on, so the value and the
 * threshold it was judged against come back too — a warning nobody can check is
 * a warning nobody believes.
 */
export async function getEwayRequirement(saleId: string): Promise<EwayRequirement | null> {
  await requirePermission('sales.view');
  const supabase = await createSupabaseServerClient();

  const [{ data, error }, { data: existing }] = await Promise.all([
    supabase.rpc('eway_bill_required', { p_document_type: 'SALE', p_document_id: saleId }),
    supabase
      .from('eway_bills')
      .select('id, status, eway_bill_number, valid_until, error_message')
      .eq('document_type', 'SALE')
      .eq('document_id', saleId)
      .maybeSingle(),
  ]);

  if (error) {
    // Never block a sale screen on a GST question. The panel disappears and the
    // reason is in the log; the invoice itself is unaffected.
    console.error('[gst] e-way requirement failed', error.message);
    return null;
  }

  const row = Array.isArray(data) ? data[0] : data;
  if (!row) return null;

  return {
    required: Boolean(row.required),
    consignmentValue: fromDb(row.consignment_value),
    threshold: fromDb(row.threshold),
    interstate: Boolean(row.interstate),
    existing: existing
      ? {
          id: existing.id,
          status: existing.status,
          number: existing.eway_bill_number,
          validUntil: existing.valid_until,
          error: existing.error_message,
        }
      : null,
  };
}

export interface EwayTransportInput {
  readonly saleId: string;
  readonly transportMode: 'ROAD' | 'RAIL' | 'AIR' | 'SHIP';
  readonly vehicleNumber?: string | null;
  readonly distanceKm?: number | null;
  readonly transporterId?: string | null;
  readonly transporterName?: string | null;
}

/**
 * Raises an e-way bill for a sale and files it, in that order.
 *
 * The same shape as submitEinvoice, and the same rule: the payload is stored
 * before the request leaves, so a lost reply still leaves evidence of what was
 * sent, and whatever comes back is recorded as a separate step.
 *
 * A portal failure never touches the ledger (spec §40). The sale stays posted
 * and the bill stays retryable — what it does mean is that the goods cannot
 * lawfully move yet, which is why the message says so rather than reporting a
 * generic error.
 */
export async function raiseEwayBill(input: EwayTransportInput): Promise<GstResult> {
  // The audit is written by fileEwayBill below, which this delegates to.
  await requirePermission('gst.einvoice.generate');
  const supabase = await createSupabaseServerClient();

  if (input.transportMode === 'ROAD' && !input.vehicleNumber?.trim()) {
    return { ok: false, error: 'Road movement needs the vehicle number that will carry it.' };
  }

  const { data: ewayId, error: queueError } = await supabase.rpc('queue_eway_bill', {
    p_document_type: 'SALE',
    p_document_id: input.saleId,
    p_transport_mode: input.transportMode,
    p_vehicle_number: input.vehicleNumber?.trim() || null,
    p_distance_km: input.distanceKm ?? null,
    p_transporter_id: input.transporterId?.trim() || null,
    p_transporter_name: input.transporterName?.trim() || null,
  });

  if (queueError || !ewayId) {
    console.error('[gst] e-way queue failed', queueError?.message);
    return { ok: false, error: describeGstError(queueError?.message ?? 'Could not raise the e-way bill.') };
  }

  return fileEwayBill(String(ewayId));
}

/**
 * Files an e-way bill that is already queued. Also the retry path.
 */
export async function fileEwayBill(ewayId: string): Promise<GstResult> {
  const context = await requirePermission('gst.einvoice.generate');
  const supabase = await createSupabaseServerClient();

  // Build first: a consignment that cannot be represented is our problem, not
  // the portal's, and is worth saying before a request goes out.
  const { data: payload, error: buildError } = await supabase.rpc('eway_bill_payload', {
    p_eway_id: ewayId,
  });

  if (buildError) {
    console.error('[gst] e-way payload build failed', buildError.message);
    return { ok: false, error: describeGstError(buildError.message) };
  }

  const { error: requestError } = await supabase.rpc('record_eway_request', {
    p_eway_id: ewayId,
    p_payload: payload as never,
  });

  if (requestError) {
    if (requestError.message.includes('already generated')) {
      return { ok: false, error: 'This consignment already has an e-way bill.' };
    }
    return { ok: false, error: describeGstError(requestError.message) };
  }

  const outcome = await submitEwayBill(payload);

  const { error: resultError } = await supabase.rpc('record_eway_result', {
    p_eway_id: ewayId,
    p_status: outcome.ok ? 'GENERATED' : 'FAILED',
    p_number: outcome.ok ? outcome.ewayBillNumber : null,
    p_valid_until: outcome.ok ? outcome.validUntil : null,
    p_error: outcome.ok ? null : outcome.message,
    p_response: (outcome.raw ?? null) as never,
  });

  if (resultError) {
    console.error('[gst] e-way result record failed', resultError.message);
    return {
      ok: false,
      error:
        'The portal responded but the result could not be saved. Check GST → E-Way Bill before filing again.',
    };
  }

  await recordAudit({
    action: 'POST',
    entityType: 'eway_bills',
    entityId: ewayId,
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: outcome.ok
      ? { status: 'GENERATED', number: outcome.ewayBillNumber }
      : { status: 'FAILED', code: outcome.code },
  });

  if (!outcome.ok) {
    return {
      ok: false,
      error:
        outcome.code === 'NOT_CONFIGURED'
          ? 'Recorded, but not filed: no GST provider is configured. The goods may not move until the bill is raised on the portal.'
          : `${outcome.message} The sale is unaffected — but the goods may not move until this is filed.`,
    };
  }

  return { ok: true, message: `E-way bill ${outcome.ewayBillNumber} generated.` };
}
