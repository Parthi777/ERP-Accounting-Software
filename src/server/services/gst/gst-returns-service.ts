import 'server-only';

import { requirePermission, requireTenantContext } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { add, fromDb, type Paise } from '@/lib/money';
import { parseGstr2b } from '@/server/services/gst/gstr2b-import';

/**
 * GST returns — checklist §08, §09 (0085). GSTR-2B import and matching, the
 * credit that may be claimed, the GSTR-3B working and set-off, the checks
 * across returns and the ledger, and the record of what was filed.
 */

type Result = { ok: boolean; error?: string; message?: string };

/** The GSTINs this dealer files under: each branch's, or the dealer's where a branch has none. */
export async function getFilingGstins(): Promise<string[]> {
  const context = await requireTenantContext();
  const supabase = await createSupabaseServerClient();
  const [{ data: branches }, { data: dealer }] = await Promise.all([
    supabase.from('branches').select('gstin'),
    supabase.from('dealers').select('gstin').eq('id', context.dealerId!).maybeSingle(),
  ]);
  const set = new Set<string>();
  for (const b of branches ?? []) {
    const g = (b.gstin ?? '').trim() || (dealer?.gstin ?? '').trim();
    if (g) set.add(g);
  }
  return [...set].sort();
}

export interface Gstr2bImportRow {
  readonly id: string; readonly period: string; readonly fileName: string | null;
  readonly lineCount: number; readonly importedAt: string;
}

export async function getGstr2bImports(gstin: string): Promise<Gstr2bImportRow[]> {
  await requirePermission('gst.reports.view');
  const supabase = await createSupabaseServerClient();
  const { data } = await supabase.from('gstr2b_imports')
    .select('id, period, file_name, line_count, imported_at')
    .eq('gstin', gstin).eq('status', 'ACTIVE').order('period', { ascending: false });
  return (data ?? []).map((i) => ({
    id: i.id, period: i.period, fileName: i.file_name, lineCount: i.line_count, importedAt: i.imported_at,
  }));
}

export interface ReconRow {
  readonly side: '2B' | 'BOOKS';
  readonly status: string;
  readonly supplierGstin: string;
  readonly supplierName: string | null;
  readonly documentNumber: string;
  readonly documentDate: string | null;
  readonly tax2b: Paise | null;
  readonly taxBooks: Paise | null;
  readonly difference: Paise;
  readonly billId: string | null;
  readonly key: string;
}

export async function getGstr2bReconciliation(importId: string): Promise<ReconRow[]> {
  await requirePermission('gst.reports.view');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('gstr2b_reconciliation', { p_import_id: importId });
  if (error) throw new Error(`Failed to load the 2B reconciliation: ${error.message}`);
  return (data ?? []).map((r, i) => ({
    side: r.side as '2B' | 'BOOKS', status: r.match_status, supplierGstin: r.supplier_gstin,
    supplierName: r.supplier_name, documentNumber: r.document_number, documentDate: r.document_date,
    tax2b: r.tax_2b === null ? null : fromDb(r.tax_2b), taxBooks: r.tax_books === null ? null : fromDb(r.tax_books),
    difference: fromDb(r.difference ?? '0'), billId: r.purchase_bill_id, key: `${r.line_id ?? r.purchase_bill_id}-${i}`,
  }));
}

export interface ClaimRow {
  readonly kind: string; readonly documentNumber: string; readonly documentDate: string;
  readonly supplier: string; readonly tax: Paise; readonly claimable: boolean; readonly reason: string;
  readonly billId: string | null; readonly key: string;
}

export async function getItcClaimable(gstin: string, period: string): Promise<ClaimRow[]> {
  await requirePermission('gst.reports.view');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('itc_claimable', { p_gstin: gstin, p_period: period });
  if (error) throw new Error(`Failed to load claimable credit: ${error.message}`);
  return (data ?? []).map((r, i) => ({
    kind: r.claim_kind, documentNumber: r.document_number, documentDate: r.document_date,
    supplier: r.supplier_name, tax: add(fromDb(r.igst_amount), fromDb(r.cgst_amount), fromDb(r.sgst_amount)),
    claimable: r.claimable, reason: r.reason, billId: r.purchase_bill_id, key: `${r.claim_kind}-${r.purchase_bill_id ?? r.gst_note_id}-${i}`,
  }));
}

export interface WorkingRow {
  readonly section: string; readonly description: string; readonly taxable: Paise | null;
  readonly igst: Paise; readonly cgst: Paise; readonly sgst: Paise;
}

export async function getGstr3bWorking(gstin: string, period: string): Promise<WorkingRow[]> {
  await requirePermission('gst.reports.view');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('gstr3b_working', { p_gstin: gstin, p_period: period });
  if (error) throw new Error(`Failed to load the GSTR-3B working: ${error.message}`);
  return (data ?? []).map((r) => ({
    section: r.section, description: r.description,
    taxable: r.taxable_value === null ? null : fromDb(r.taxable_value),
    igst: fromDb(r.igst_amount), cgst: fromDb(r.cgst_amount), sgst: fromDb(r.sgst_amount),
  }));
}

export interface SetoffRow {
  readonly head: string; readonly liability: Paise; readonly rcm: Paise; readonly opening: Paise;
  readonly credit: Paise; readonly byIgst: Paise; readonly byCgst: Paise; readonly bySgst: Paise;
  readonly cash: Paise; readonly closing: Paise;
}

export async function getGstr3bSetoff(gstin: string, period: string): Promise<SetoffRow[]> {
  await requirePermission('gst.reports.view');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('gstr3b_setoff', { p_gstin: gstin, p_period: period });
  if (error) throw new Error(`Failed to load the set-off: ${error.message}`);
  return (data ?? []).map((r) => ({
    head: r.tax_head, liability: fromDb(r.liability), rcm: fromDb(r.rcm_liability),
    opening: fromDb(r.opening_credit), credit: fromDb(r.period_credit), byIgst: fromDb(r.paid_by_igst),
    byCgst: fromDb(r.paid_by_cgst), bySgst: fromDb(r.paid_by_sgst), cash: fromDb(r.cash_payable),
    closing: fromDb(r.closing_credit),
  }));
}

export interface CrossCheckRow {
  readonly code: string; readonly description: string; readonly leftLabel: string; readonly left: Paise | null;
  readonly rightLabel: string; readonly right: Paise | null; readonly difference: Paise | null; readonly status: string;
}

export async function getCrossChecks(gstin: string, period: string): Promise<CrossCheckRow[]> {
  await requirePermission('gst.reports.view');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('gst_cross_checks', { p_gstin: gstin, p_period: period });
  if (error) throw new Error(`Failed to load cross-checks: ${error.message}`);
  return (data ?? []).map((r) => ({
    code: r.check_code, description: r.description, leftLabel: r.left_label,
    left: r.left_value === null ? null : fromDb(r.left_value), rightLabel: r.right_label,
    right: r.right_value === null ? null : fromDb(r.right_value),
    difference: r.difference === null ? null : fromDb(r.difference), status: r.status,
  }));
}

export interface AmendmentRow {
  readonly kind: string; readonly filedPeriod: string; readonly documentNumber: string; readonly documentDate: string;
  readonly filedTax: Paise | null; readonly currentTax: Paise | null; readonly detail: string; readonly key: string;
}

export async function getGstr1Amendments(gstin: string, period: string): Promise<AmendmentRow[]> {
  await requirePermission('gst.reports.view');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('gstr1_amendments', { p_gstin: gstin, p_period: period });
  if (error) throw new Error(`Failed to load amendments: ${error.message}`);
  return (data ?? []).map((r, i) => ({
    kind: r.kind, filedPeriod: r.filed_period, documentNumber: r.document_number, documentDate: r.document_date,
    filedTax: r.filed_tax === null ? null : fromDb(r.filed_tax),
    currentTax: r.current_tax === null ? null : fromDb(r.current_tax), detail: r.detail, key: `${r.document_id}-${i}`,
  }));
}

export interface GstReturnRow {
  readonly id: string; readonly returnType: 'GSTR1' | 'GSTR3B'; readonly status: string;
  readonly preparedBy: string | null; readonly preparedAt: string; readonly signedOffBy: string | null;
  readonly arn: string | null; readonly filedOn: string | null; readonly filedTax: Paise | null;
  readonly challanCin: string | null; readonly challanAmount: Paise | null; readonly setoffJournalId: string | null;
  readonly computed: Record<string, unknown>; readonly isPreparer: boolean;
}

export async function getGstReturns(gstin: string, period: string): Promise<GstReturnRow[]> {
  const context = await requirePermission('gst.reports.view');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.from('gst_returns')
    .select('id, return_type, status, prepared_by, prepared_at, signed_off_by, arn, filed_on, filed_igst, filed_cgst, filed_sgst, challan_cin, challan_amount, setoff_journal_id, computed')
    .eq('gstin', gstin).eq('period', period);
  if (error) throw new Error(`Failed to load returns: ${error.message}`);
  return (data ?? []).map((r) => ({
    id: r.id, returnType: r.return_type as 'GSTR1' | 'GSTR3B', status: r.status, preparedBy: r.prepared_by,
    preparedAt: r.prepared_at, signedOffBy: r.signed_off_by, arn: r.arn, filedOn: r.filed_on,
    filedTax: r.filed_igst === null ? null : add(fromDb(r.filed_igst), fromDb(r.filed_cgst), fromDb(r.filed_sgst)),
    challanCin: r.challan_cin, challanAmount: r.challan_amount === null ? null : fromDb(r.challan_amount),
    setoffJournalId: r.setoff_journal_id, computed: (r.computed ?? {}) as Record<string, unknown>,
    isPreparer: r.prepared_by === context.userId,
  }));
}

// ── Writes ──────────────────────────────────────────────────────────────────

export async function previewGstr2b(csv: string) {
  await requirePermission('gst.returns.prepare');
  return parseGstr2b(csv);
}

export async function importGstr2b(gstin: string, period: string, csv: string, fileName: string | null) {
  await requirePermission('gst.returns.prepare');
  const preview = parseGstr2b(csv);
  if (preview.rows.length === 0) return { ok: false, error: 'The file contains no rows.' };
  if (preview.errorCount > 0) {
    return { ok: false, error: `${preview.errorCount} row(s) have errors. Nothing was imported — fix the file and try again.` };
  }
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('import_gstr2b', {
    p_gstin: gstin, p_period: period, p_file_name: fileName ?? undefined,
    p_lines: preview.rows.map(({ rowNumber: _r, errors: _e, ...line }) => line),
  });
  return error ? { ok: false, error: error.message } : { ok: true, imported: preview.rows.length };
}

export async function prepareReturn(type: 'GSTR1' | 'GSTR3B', gstin: string, period: string): Promise<Result> {
  await requirePermission('gst.returns.prepare');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('prepare_gst_return', { p_type: type, p_gstin: gstin, p_period: period });
  return error ? { ok: false, error: error.message }
    : { ok: true, message: 'Prepared. Someone else now signs it off before it is filed.' };
}

export async function signOffReturn(returnId: string): Promise<Result> {
  await requirePermission('gst.returns.file');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('sign_off_gst_return', { p_return_id: returnId });
  return error ? { ok: false, error: error.message } : { ok: true, message: 'Signed off.' };
}

export async function recordFiling(input: {
  readonly returnId: string; readonly arn: string; readonly filedOn: string; readonly taxable: number;
  readonly igst: number; readonly cgst: number; readonly sgst: number;
  readonly itcIgst: number | null; readonly itcCgst: number | null; readonly itcSgst: number | null;
  readonly cpin: string; readonly cin: string; readonly challanAmount: number | null;
}): Promise<Result> {
  await requirePermission('gst.returns.file');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('record_gst_filing', {
    p_return_id: input.returnId, p_arn: input.arn, p_filed_on: input.filedOn, p_taxable: input.taxable,
    p_igst: input.igst, p_cgst: input.cgst, p_sgst: input.sgst,
    p_itc_igst: input.itcIgst ?? undefined, p_itc_cgst: input.itcCgst ?? undefined, p_itc_sgst: input.itcSgst ?? undefined,
    p_challan_cpin: input.cpin || undefined, p_challan_cin: input.cin || undefined,
    p_challan_amount: input.challanAmount ?? undefined,
  });
  return error ? { ok: false, error: error.message } : { ok: true, message: 'Filing recorded. Attach the acknowledgement below.' };
}

export async function postSetoff(returnId: string, bankAccountId: string): Promise<Result> {
  await requirePermission('gst.returns.file');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('post_gst_setoff', { p_return_id: returnId, p_bank_account_id: bankAccountId });
  return error ? { ok: false, error: error.message } : { ok: true, message: 'Set-off and payment posted.' };
}

export async function getBankAccountOptions(): Promise<{ value: string; label: string }[]> {
  await requirePermission('gst.reports.view');
  const supabase = await createSupabaseServerClient();
  const { data } = await supabase.from('bank_accounts').select('id, name, bank_name').eq('status', 'ACTIVE').order('name');
  return (data ?? []).map((b) => ({ value: b.id, label: `${b.name} · ${b.bank_name}` }));
}
