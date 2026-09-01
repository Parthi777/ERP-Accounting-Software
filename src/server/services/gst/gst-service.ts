import 'server-only';

import { requirePermission, type TenantContext } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { fromDb, type Paise } from '@/lib/money';
import { recordAudit } from '@/server/services/audit/record-audit';
import { isConfigured, submitToIrp } from '@/server/services/gst/irp-client';

/**
 * GST — spec §40.
 *
 * The returns side is derived from the invoices themselves, so it cannot drift
 * from them. The portal side is a queue: this product records what it intends to
 * file and what the portal said, and never lets a portal failure disturb an
 * accounting transaction that has already happened.
 *
 * Nothing here calls the GST portal. Until real IRP credentials are configured,
 * generating an e-invoice means queueing it — and the screens say so rather than
 * inventing an IRN that would look real and reconcile to nothing.
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
