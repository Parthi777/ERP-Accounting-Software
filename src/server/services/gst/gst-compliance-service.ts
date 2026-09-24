import 'server-only';

import { requirePermission } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { add, fromDb, type Paise } from '@/lib/money';

/**
 * Credit and debit notes, input tax credit adjustments and supply categories
 * (0084). The posting rules live in the database functions; this layer shapes
 * input and output.
 */

type Result = { ok: boolean; error?: string; message?: string };

export interface GstNoteRow {
  readonly id: string;
  readonly number: string;
  readonly noteType: 'CREDIT' | 'DEBIT';
  readonly partyType: 'CUSTOMER' | 'SUPPLIER';
  readonly partyName: string;
  readonly partyNoteNumber: string | null;
  readonly originalNumber: string;
  readonly noteDate: string;
  readonly reason: string;
  readonly description: string;
  readonly taxable: Paise;
  readonly tax: Paise;
  readonly total: Paise;
  readonly status: 'POSTED' | 'CANCELLED';
  readonly journalId: string | null;
}

export interface NoteOriginal { readonly value: string; readonly label: string; readonly party: 'CUSTOMER' | 'SUPPLIER' }

export interface ItcAdjustmentRow {
  readonly id: string;
  readonly date: string;
  readonly direction: 'REVERSAL' | 'RECLAIM';
  readonly rule: string;
  readonly billNumber: string | null;
  readonly total: Paise;
  readonly note: string;
  readonly journalId: string | null;
}

export interface Rule37Row {
  readonly billId: string;
  readonly billNumber: string;
  readonly supplierBillNumber: string;
  readonly supplier: string;
  readonly branchId: string;
  readonly billDate: string;
  readonly days: number;
  readonly unpaid: Paise;
  readonly cgst: number;
  readonly sgst: number;
  readonly igst: number;
}

export interface SupplyCategoryRow {
  readonly direction: 'OUTWARD' | 'INWARD';
  readonly category: string;
  readonly documentCount: number;
  readonly taxable: Paise;
  readonly tax: Paise;
}

export async function getGstNotes(): Promise<GstNoteRow[]> {
  await requirePermission('gst.reports.view');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from('gst_notes')
    .select('id, note_number, note_type, party_type, party_note_number, original_document_number, note_date, reason, description, taxable_value, cgst_amount, sgst_amount, igst_amount, total_amount, status, journal_entry_id, customers ( name ), suppliers ( name )')
    .order('note_date', { ascending: false })
    .order('note_number', { ascending: false })
    .limit(500);
  if (error) throw new Error(`Failed to load notes: ${error.message}`);
  return (data ?? []).map((n) => ({
    id: n.id,
    number: n.note_number,
    noteType: n.note_type as 'CREDIT' | 'DEBIT',
    partyType: n.party_type as 'CUSTOMER' | 'SUPPLIER',
    partyName: n.customers?.name ?? n.suppliers?.name ?? '',
    partyNoteNumber: n.party_note_number,
    originalNumber: n.original_document_number,
    noteDate: n.note_date,
    reason: n.reason,
    description: n.description,
    taxable: fromDb(n.taxable_value),
    tax: add(fromDb(n.cgst_amount), fromDb(n.sgst_amount), fromDb(n.igst_amount)),
    total: fromDb(n.total_amount),
    status: n.status as 'POSTED' | 'CANCELLED',
    journalId: n.journal_entry_id,
  }));
}

/** Posted documents a note can amend, most recent first. */
export async function getNoteOriginals(): Promise<NoteOriginal[]> {
  await requirePermission('gst.notes.manage');
  const supabase = await createSupabaseServerClient();
  const [sales, service, bills] = await Promise.all([
    supabase.from('sales').select('id, invoice_number, invoice_date, customers ( name )')
      .in('status', ['POSTED', 'DELIVERED']).not('customer_id', 'is', null)
      .order('invoice_date', { ascending: false }).limit(200),
    supabase.from('service_invoices').select('id, invoice_number, invoice_date, customers ( name )')
      .eq('status', 'POSTED').not('customer_id', 'is', null)
      .order('invoice_date', { ascending: false }).limit(200),
    supabase.from('purchase_bills').select('id, bill_number, supplier_bill_number, bill_date, suppliers ( name )')
      .eq('status', 'POSTED').order('bill_date', { ascending: false }).limit(200),
  ]);
  return [
    ...(sales.data ?? []).map((s) => ({
      value: `SALE:${s.id}`, party: 'CUSTOMER' as const,
      label: `${s.invoice_number} · ${s.customers?.name ?? ''} · ${s.invoice_date}`,
    })),
    ...(service.data ?? []).map((s) => ({
      value: `SERVICE_INVOICE:${s.id}`, party: 'CUSTOMER' as const,
      label: `${s.invoice_number} · ${s.customers?.name ?? ''} · ${s.invoice_date}`,
    })),
    ...(bills.data ?? []).map((b) => ({
      value: `PURCHASE_BILL:${b.id}`, party: 'SUPPLIER' as const,
      label: `${b.bill_number} (${b.supplier_bill_number}) · ${b.suppliers?.name ?? ''} · ${b.bill_date}`,
    })),
  ];
}

/** Leaf accounts a note's value may go to: income, expense or asset, never cash or bank. */
export async function getNoteAccounts(): Promise<{ value: string; label: string }[]> {
  await requirePermission('gst.notes.manage');
  const supabase = await createSupabaseServerClient();
  const { data } = await supabase.from('chart_of_accounts')
    .select('id, code, name, account_type')
    .eq('is_group', false).eq('status', 'ACTIVE')
    .in('account_type', ['INCOME', 'EXPENSE', 'ASSET'])
    .not('code', 'in', '(1100,1200,1300,1900,1910,1920)')
    .order('code');
  return (data ?? []).map((a) => ({ value: a.id, label: `${a.code} ${a.name}` }));
}

export async function issueNote(input: {
  readonly noteType: 'CREDIT' | 'DEBIT';
  readonly original: string;
  readonly taxable: number;
  readonly gstRate: number;
  readonly accountId: string;
  readonly reason: string;
  readonly description: string;
  readonly noteDate: string;
  readonly partyNoteNumber: string;
  readonly itcEligible: boolean;
  readonly hsnSac: string;
  readonly idempotencyKey: string;
}): Promise<Result> {
  await requirePermission('gst.notes.manage');
  const [type, id] = input.original.split(':');
  if (!type || !id) return { ok: false, error: 'Choose the invoice or bill this note amends.' };
  if (!(input.taxable > 0)) return { ok: false, error: 'Enter the value of the note.' };
  if (!input.accountId) return { ok: false, error: 'Choose the account the value goes to.' };
  if (input.hsnSac && !/^[0-9]{4,8}$/.test(input.hsnSac)) return { ok: false, error: 'An HSN or SAC is 4 to 8 digits.' };

  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('issue_gst_note', {
    p_note_type: input.noteType,
    p_original_type: type,
    p_original_id: id,
    p_taxable_value: input.taxable,
    p_gst_rate: input.gstRate,
    p_account_id: input.accountId,
    p_reason: input.reason || 'OTHER',
    p_description: input.description,
    p_note_date: input.noteDate || undefined,
    p_party_note_number: input.partyNoteNumber || undefined,
    p_itc_eligible: input.itcEligible,
    p_hsn_sac: input.hsnSac || undefined,
    p_idempotency_key: input.idempotencyKey,
  });
  if (error) return { ok: false, error: error.message };
  const { data: note } = await supabase.from('gst_notes').select('note_number').eq('id', data).single();
  return { ok: true, message: `${note?.note_number ?? 'Note'} issued and posted.` };
}

export async function cancelNote(noteId: string, reason: string): Promise<Result> {
  await requirePermission('gst.notes.manage');
  if (!reason.trim()) return { ok: false, error: 'Say why the note is being cancelled.' };
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('cancel_gst_note', { p_note_id: noteId, p_reason: reason.trim() });
  return error ? { ok: false, error: error.message } : { ok: true, message: 'Cancelled; the journal is reversed.' };
}

export async function getItcAdjustments(): Promise<ItcAdjustmentRow[]> {
  await requirePermission('gst.reports.view');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.from('itc_adjustments')
    .select('id, adjustment_date, direction, rule, total_amount, note, journal_entry_id, purchase_bills ( bill_number )')
    .order('adjustment_date', { ascending: false }).limit(500);
  if (error) throw new Error(`Failed to load ITC adjustments: ${error.message}`);
  return (data ?? []).map((a) => ({
    id: a.id, date: a.adjustment_date, direction: a.direction as 'REVERSAL' | 'RECLAIM', rule: a.rule,
    billNumber: a.purchase_bills?.bill_number ?? null, total: fromDb(a.total_amount),
    note: a.note, journalId: a.journal_entry_id,
  }));
}

export async function getRule37Candidates(asOn: string): Promise<Rule37Row[]> {
  await requirePermission('gst.reports.view');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('itc_rule37_candidates', { p_as_on: asOn });
  if (error) throw new Error(`Failed to load rule 37 candidates: ${error.message}`);
  return (data ?? []).map((r) => ({
    billId: r.purchase_bill_id, billNumber: r.bill_number, supplierBillNumber: r.supplier_bill_number,
    supplier: r.supplier_name, branchId: r.branch_id, billDate: r.bill_date, days: r.days_outstanding,
    unpaid: fromDb(r.unpaid), cgst: Number(r.cgst_due), sgst: Number(r.sgst_due), igst: Number(r.igst_due),
  }));
}

export async function recordItcAdjustment(input: {
  readonly direction: 'REVERSAL' | 'RECLAIM';
  readonly rule: string;
  readonly branchId: string;
  readonly cgst: number;
  readonly sgst: number;
  readonly igst: number;
  readonly note: string;
  readonly date: string;
  readonly billId: string | null;
  readonly idempotencyKey: string;
}): Promise<Result> {
  await requirePermission('gst.itc.manage');
  if (!(input.cgst + input.sgst + input.igst > 0)) return { ok: false, error: 'Enter the tax being adjusted.' };
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('record_itc_adjustment', {
    p_direction: input.direction, p_rule: input.rule, p_branch_id: input.branchId,
    p_cgst: input.cgst, p_sgst: input.sgst, p_igst: input.igst, p_note: input.note,
    p_date: input.date || undefined, p_purchase_bill_id: input.billId ?? undefined,
    p_idempotency_key: input.idempotencyKey,
  });
  return error ? { ok: false, error: error.message }
    : { ok: true, message: input.direction === 'REVERSAL' ? 'Credit reversed and posted to 5990.' : 'Credit re-claimed.' };
}

export async function getSupplyCategories(from: string, to: string): Promise<SupplyCategoryRow[]> {
  await requirePermission('gst.summary.view');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('gst_supply_categories', { p_from: from, p_to: to });
  if (error) throw new Error(`Failed to load supply categories: ${error.message}`);
  return (data ?? []).map((r) => ({
    direction: r.direction as 'OUTWARD' | 'INWARD', category: r.tax_category,
    documentCount: Number(r.document_count), taxable: fromDb(r.taxable_value), tax: fromDb(r.total_tax),
  }));
}
