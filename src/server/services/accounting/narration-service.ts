import 'server-only';

import { requirePermission, requireTenantContext } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import type { ChartResult } from '@/server/services/accounting/chart-service';

/**
 * Narration templates (0091, BUSY F13): a list of the sentences the dealer's
 * accountant writes again and again, offered as suggestions in each voucher.
 * The posted narration is a copy — editing a template never changes history.
 */

export type VoucherType = 'PAYMENT' | 'RECEIPT' | 'JOURNAL' | 'CONTRA' | 'ANY';
export const VOUCHER_TYPES: readonly VoucherType[] = ['PAYMENT', 'RECEIPT', 'JOURNAL', 'CONTRA', 'ANY'];

export interface NarrationTemplate {
  readonly id: string;
  readonly voucherType: VoucherType;
  readonly text: string;
  readonly status: string;
}

export async function listNarrationTemplates(): Promise<NarrationTemplate[]> {
  await requireTenantContext();
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from('narration_templates')
    .select('id, voucher_type, text, status')
    .order('voucher_type')
    .order('text');
  if (error) throw new Error(`Failed to load narration templates: ${error.message}`);
  return (data ?? []).map((t) => ({ id: t.id, voucherType: t.voucher_type as VoucherType, text: t.text, status: t.status }));
}

/** The active narrations for one voucher type, plus those for any type. */
export async function narrationsFor(type: Exclude<VoucherType, 'ANY'>): Promise<string[]> {
  const all = await listNarrationTemplates();
  return all.filter((t) => t.status === 'ACTIVE' && (t.voucherType === type || t.voucherType === 'ANY')).map((t) => t.text);
}

export async function addNarrationTemplate(voucherType: string, text: string): Promise<ChartResult> {
  const context = await requirePermission('admin.settings.manage');
  if (!context.dealerId) return { ok: false, error: 'Templates belong to a dealer; sign in as one.' };
  if (!VOUCHER_TYPES.includes(voucherType as VoucherType)) return { ok: false, error: 'Choose the voucher type.' };
  if (text.trim().length < 2) return { ok: false, error: 'Write the narration.' };
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase
    .from('narration_templates')
    .insert({ dealer_id: context.dealerId, voucher_type: voucherType as VoucherType, text: text.trim(), created_by: context.userId });
  if (error) {
    return { ok: false, error: error.code === '23505' ? 'That narration is already in the list.' : error.message };
  }
  return { ok: true, message: 'Narration added.' };
}

export async function setNarrationTemplateStatus(id: string, status: 'ACTIVE' | 'INACTIVE'): Promise<ChartResult> {
  const context = await requirePermission('admin.settings.manage');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase
    .from('narration_templates')
    .update({ status, updated_by: context.userId })
    .eq('id', id);
  if (error) return { ok: false, error: error.message };
  return { ok: true, message: status === 'ACTIVE' ? 'Narration restored.' : 'Narration retired.' };
}
