import 'server-only';

import { requirePermission } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { recordAudit } from '@/server/services/audit/record-audit';
import type { ChartResult } from '@/server/services/accounting/chart-service';

/**
 * TDS on supplier bills (0093, BUSY F61–F67).
 *
 * No rate ships with the product. The accountant enters each section with its
 * Act, reference, rate, thresholds, dates of force and source, and reviews it;
 * only then does a bill deduct under it. Bills deduct when posted
 * (post_purchase_bill → app.tds_compute); a deposit already made at the bank is
 * recorded against the deductions it covers. Nothing here pays or files.
 */

export type PayeeType = 'INDIVIDUAL_HUF' | 'COMPANY' | 'FIRM_LLP' | 'OTHER';
export const PAYEE_TYPES: readonly { value: PayeeType; label: string }[] = [
  { value: 'INDIVIDUAL_HUF', label: 'Individual / HUF' },
  { value: 'COMPANY', label: 'Company' },
  { value: 'FIRM_LLP', label: 'Firm / LLP' },
  { value: 'OTHER', label: 'Other' },
];

export interface TdsDeductor {
  readonly tan: string | null;
  readonly enabled: boolean;
}

export interface TdsSection {
  readonly id: string;
  readonly code: string;
  readonly act: 'IT_1961' | 'IT_2025';
  readonly sectionRef: string;
  readonly description: string;
  readonly payeeTypes: string[] | null;
  readonly rate: number;
  readonly rateWithoutPan: number | null;
  readonly singleThreshold: number | null;
  readonly aggregateThreshold: number | null;
  readonly thresholdBasis: string;
  readonly effectiveFrom: string;
  readonly effectiveTo: string | null;
  readonly sourceNote: string;
  readonly reviewed: boolean;
}

export interface TdsPayee {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly pan: string | null;
  readonly sectionCode: string | null;
  readonly payeeType: PayeeType | null;
  readonly panVerified: boolean;
  readonly ldcNumber: string | null;
  readonly ldcRate: number | null;
  readonly ldcValidFrom: string | null;
  readonly ldcValidTo: string | null;
  readonly ldcLimit: number | null;
}

export interface TdsRegisterRow {
  readonly id: string;
  readonly billDate: string;
  readonly billNumber: string;
  readonly supplierName: string;
  readonly pan: string | null;
  readonly sectionCode: string;
  readonly act: string;
  readonly sectionRef: string;
  readonly base: number;
  readonly deductibleBase: number;
  readonly rate: number;
  readonly rateBasis: string;
  readonly amount: number;
  readonly status: string;
  readonly challan: string | null;
  readonly depositDate: string | null;
}

const num = (v: string | number | null | undefined) => (v === null || v === undefined ? null : Number(v));

export async function getTdsSetup(): Promise<{ deductor: TdsDeductor; sections: TdsSection[]; payees: TdsPayee[] }> {
  await requirePermission('accounting.tds.manage');
  const supabase = await createSupabaseServerClient();
  const [deductor, sections, payees] = await Promise.all([
    supabase.from('tds_deductor').select('tan, enabled').maybeSingle(),
    supabase.from('tds_sections').select('*').order('code').order('effective_from', { ascending: false }),
    supabase
      .from('suppliers')
      .select('id, supplier_code, name, pan, tds_section_code, tds_payee_type, tds_pan_verified, ldc_number, ldc_rate, ldc_valid_from, ldc_valid_to, ldc_limit')
      .eq('status', 'ACTIVE')
      .order('name'),
  ]);
  if (sections.error) throw new Error(`Failed to load TDS sections: ${sections.error.message}`);
  return {
    deductor: { tan: deductor.data?.tan ?? null, enabled: deductor.data?.enabled ?? false },
    sections: (sections.data ?? []).map((s) => ({
      id: s.id,
      code: s.code,
      act: s.act as TdsSection['act'],
      sectionRef: s.section_ref,
      description: s.description,
      payeeTypes: s.payee_types,
      rate: Number(s.rate),
      rateWithoutPan: num(s.rate_without_pan),
      singleThreshold: num(s.single_threshold),
      aggregateThreshold: num(s.aggregate_threshold),
      thresholdBasis: s.threshold_basis,
      effectiveFrom: s.effective_from,
      effectiveTo: s.effective_to,
      sourceNote: s.source_note,
      reviewed: s.reviewed_at !== null,
    })),
    payees: (payees.data ?? []).map((p) => ({
      id: p.id,
      code: p.supplier_code,
      name: p.name,
      pan: p.pan,
      sectionCode: p.tds_section_code,
      payeeType: p.tds_payee_type,
      panVerified: p.tds_pan_verified,
      ldcNumber: p.ldc_number,
      ldcRate: num(p.ldc_rate),
      ldcValidFrom: p.ldc_valid_from,
      ldcValidTo: p.ldc_valid_to,
      ldcLimit: num(p.ldc_limit),
    })),
  };
}

export async function getTdsRegister(from: string, to: string): Promise<{
  rows: TdsRegisterRow[];
  control: { ledger: number; unremitted: number; difference: number };
}> {
  await requirePermission('accounting.tds.manage');
  const supabase = await createSupabaseServerClient();
  const [register, control] = await Promise.all([
    supabase.rpc('tds_register', { p_from: from, p_to: to }),
    supabase.rpc('tds_control_check', {}),
  ]);
  if (register.error) throw new Error(`Failed to load the TDS register: ${register.error.message}`);
  const c = control.data?.[0];
  return {
    rows: (register.data ?? []).map((r) => ({
      id: r.deduction_id,
      billDate: r.bill_date,
      billNumber: r.bill_number,
      supplierName: r.supplier_name,
      pan: r.pan,
      sectionCode: r.section_code,
      act: r.act,
      sectionRef: r.section_ref,
      base: Number(r.base),
      deductibleBase: Number(r.deductible_base),
      rate: Number(r.rate),
      rateBasis: r.rate_basis,
      amount: Number(r.amount),
      status: r.status,
      challan: r.challan_number,
      depositDate: r.deposit_date,
    })),
    control: { ledger: Number(c?.ledger_balance ?? 0), unremitted: Number(c?.unremitted ?? 0), difference: Number(c?.difference ?? 0) },
  };
}

export interface TdsPreview {
  readonly sectionCode: string;
  readonly act: string;
  readonly sectionRef: string;
  readonly base: number;
  readonly deductibleBase: number;
  readonly rate: number;
  readonly rateBasis: string;
  readonly amount: number;
}

/** What a draft bill would deduct, or the reason it cannot post yet. */
export async function getTdsPreview(billId: string): Promise<{ preview: TdsPreview | null; problem: string | null }> {
  await requirePermission('purchases.view');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('tds_preview', { p_bill_id: billId });
  if (error) return { preview: null, problem: error.message };
  const r = data?.[0];
  if (!r) return { preview: null, problem: null };
  return {
    preview: {
      sectionCode: r.section_code, act: r.act, sectionRef: r.section_ref, base: Number(r.base),
      deductibleBase: Number(r.deductible_base), rate: Number(r.rate), rateBasis: r.rate_basis, amount: Number(r.amount),
    },
    problem: null,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Writing
// ─────────────────────────────────────────────────────────────────────────────

const optionalNumber = (v: string | undefined): number | null => {
  if (v === undefined || v.trim() === '') return null;
  const n = Number(v.replace(/,/g, ''));
  return Number.isFinite(n) ? n : NaN;
};

export async function saveDeductor(values: Record<string, string>): Promise<ChartResult> {
  const context = await requirePermission('accounting.tds.manage');
  if (!context.dealerId) return { ok: false, error: 'Sign in as a dealer.' };
  const tan = (values.tan ?? '').trim().toUpperCase() || null;
  const enabled = values.enabled === 'true';
  if (tan && !/^[A-Z]{4}[0-9]{5}[A-Z]$/.test(tan)) return { ok: false, error: 'A TAN is four letters, five digits and a letter — e.g. CHES12345A.' };
  if (enabled && !tan) return { ok: false, error: 'Enter the TAN before switching TDS on.' };
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase
    .from('tds_deductor')
    .upsert({ dealer_id: context.dealerId, tan, enabled, updated_by: context.userId, updated_at: new Date().toISOString() });
  if (error) return { ok: false, error: error.message };
  return { ok: true, message: enabled ? 'TDS is on. Bills deduct under each supplier’s reviewed section.' : 'Saved. Bills do not deduct TDS.' };
}

export async function addSection(values: Record<string, string>): Promise<ChartResult> {
  const context = await requirePermission('accounting.tds.manage');
  if (!context.dealerId) return { ok: false, error: 'Sign in as a dealer.' };
  const code = (values.code ?? '').trim().toUpperCase();
  if (!/^[A-Z0-9][A-Z0-9_-]{1,29}$/.test(code)) return { ok: false, error: 'A code is letters and digits, e.g. CONTRACT or PROF-FEES.' };
  if (!['IT_1961', 'IT_2025'].includes(values.act ?? '')) return { ok: false, error: 'Choose the Act.' };
  const rate = optionalNumber(values.rate);
  const noPan = optionalNumber(values.rateWithoutPan);
  const single = optionalNumber(values.singleThreshold);
  const aggregate = optionalNumber(values.aggregateThreshold);
  if (rate === null || Number.isNaN(rate) || rate < 0 || rate > 100) return { ok: false, error: 'Enter the rate as a percentage.' };
  if ([noPan, single, aggregate].some((n) => Number.isNaN(n))) return { ok: false, error: 'Rates and thresholds are numbers.' };
  if ((values.sourceNote ?? '').trim().length < 5) {
    return { ok: false, error: 'Say where the rate comes from — the Act, section and the notification or page you read.' };
  }
  const payee = values.payeeType ? [values.payeeType] : null;

  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.from('tds_sections').insert({
    dealer_id: context.dealerId,
    code,
    act: values.act as 'IT_1961' | 'IT_2025',
    section_ref: (values.sectionRef ?? '').trim(),
    description: (values.description ?? '').trim() || code,
    payee_types: payee,
    rate: String(rate),
    rate_without_pan: noPan === null ? null : String(noPan),
    single_threshold: single === null ? null : String(single),
    aggregate_threshold: aggregate === null ? null : String(aggregate),
    threshold_basis: (values.thresholdBasis || 'THIS_BILL') as 'THIS_BILL' | 'WHOLE_AGGREGATE' | 'EXCESS_ONLY',
    effective_from: values.effectiveFrom || new Date().toISOString().slice(0, 10),
    effective_to: values.effectiveTo || null,
    source_note: (values.sourceNote ?? '').trim(),
    created_by: context.userId,
  }).select('id').single();
  if (error) return { ok: false, error: error.message };
  return { ok: true, id: data.id, message: `Section ${code} entered. Review it before bills deduct under it.` };
}

export async function reviewSection(id: string): Promise<ChartResult> {
  await requirePermission('accounting.tds.manage');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('review_tds_section', { p_section_id: id });
  if (error) return { ok: false, error: error.message };
  return { ok: true, message: 'Reviewed. Bills now deduct under it.' };
}

export async function endSection(id: string, effectiveTo: string): Promise<ChartResult> {
  await requirePermission('accounting.tds.manage');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('end_tds_section', { p_section_id: id, p_effective_to: effectiveTo });
  if (error) return { ok: false, error: error.message };
  return { ok: true, message: 'Section ended. Enter the next rate from the following day.' };
}

export async function savePayee(values: Record<string, string>): Promise<ChartResult> {
  const context = await requirePermission('accounting.tds.manage');
  const ldcRate = optionalNumber(values.ldcRate);
  const ldcLimit = optionalNumber(values.ldcLimit);
  if (Number.isNaN(ldcRate) || Number.isNaN(ldcLimit)) return { ok: false, error: 'Certificate rate and limit are numbers.' };
  const ldc = (values.ldcNumber ?? '').trim() || null;
  if (ldc && (ldcRate === null || !values.ldcValidFrom || !values.ldcValidTo)) {
    return { ok: false, error: 'A certificate needs its rate and the dates it is valid for.' };
  }
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase
    .from('suppliers')
    .update({
      tds_section_code: (values.sectionCode ?? '').trim().toUpperCase() || null,
      tds_payee_type: (values.payeeType || null) as PayeeType | null,
      tds_pan_verified: values.panVerified === 'true',
      ldc_number: ldc,
      ldc_rate: ldc && ldcRate !== null ? String(ldcRate) : null,
      ldc_valid_from: ldc ? values.ldcValidFrom : null,
      ldc_valid_to: ldc ? values.ldcValidTo : null,
      ldc_limit: ldc && ldcLimit !== null ? String(ldcLimit) : null,
      updated_by: context.userId,
    })
    .eq('id', values.supplierId ?? '');
  if (error) return { ok: false, error: error.message };
  await recordAudit({
    action: 'UPDATE', entityType: 'suppliers', entityId: values.supplierId, dealerId: context.dealerId,
    userId: context.userId, userEmail: context.email, newData: { tds: values }, changedFields: ['tds'],
  });
  return { ok: true, message: 'TDS profile saved.' };
}

export async function recordRemittance(input: {
  readonly bankAccountId: string;
  readonly depositDate: string;
  readonly challanNumber: string;
  readonly bsrCode: string;
  readonly deductionIds: readonly string[];
  readonly idempotencyKey: string;
}): Promise<ChartResult> {
  const context = await requirePermission('accounting.tds.manage');
  if (!/^[0-9]{7}$/.test(input.bsrCode.trim())) return { ok: false, error: 'A BSR code is seven digits.' };
  if (!input.challanNumber.trim()) return { ok: false, error: 'Enter the challan serial number.' };
  if (input.deductionIds.length === 0) return { ok: false, error: 'Tick the deductions this deposit covers.' };
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('record_tds_remittance', {
    p_bank_account_id: input.bankAccountId,
    p_deposit_date: input.depositDate,
    p_challan_number: input.challanNumber.trim(),
    p_bsr_code: input.bsrCode.trim(),
    // A uuid[] argument; PostgREST takes the JSON array, the generated types say string.
    p_deduction_ids: [...input.deductionIds] as unknown as string,
    p_idempotency_key: input.idempotencyKey,
  });
  if (error) return { ok: false, error: error.message };
  await recordAudit({
    action: 'POST', entityType: 'tds_remittances', entityId: String(data), dealerId: context.dealerId,
    userId: context.userId, userEmail: context.email, newData: { challan: input.challanNumber, deductions: input.deductionIds.length },
  });
  return { ok: true, id: String(data), message: 'Deposit recorded against the deductions. The TDS return is filed outside this system.' };
}

export async function setBillTdsMode(billId: string, mode: 'AUTO' | 'NONE'): Promise<ChartResult> {
  await requirePermission('purchases.create');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.from('purchase_bills').update({ tds_mode: mode }).eq('id', billId).eq('status', 'DRAFT');
  if (error) return { ok: false, error: error.message };
  return { ok: true, message: mode === 'NONE' ? 'This bill will bear no TDS.' : 'TDS applies by the supplier’s section.' };
}

/** Bank accounts a deposit can be recorded from. */
export async function getTdsBankOptions(): Promise<{ value: string; label: string }[]> {
  await requirePermission('accounting.tds.manage');
  const supabase = await createSupabaseServerClient();
  const { data } = await supabase.from('bank_accounts').select('id, name, bank_name').eq('status', 'ACTIVE').order('name');
  return (data ?? []).map((b) => ({ value: b.id, label: `${b.name} · ${b.bank_name}` }));
}
