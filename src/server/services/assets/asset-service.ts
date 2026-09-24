import 'server-only';

import { requirePermission } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { fromDb, type Paise } from '@/lib/money';

/**
 * The fixed asset register — spec §24, §41; checklist §02, §09 (0082).
 * Registering posts nothing (the cost is in the ledger from the bill);
 * depreciation and disposal post, through the one engine.
 */

export interface AssetRow {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly category: string | null;
  readonly branch: string;
  readonly account: string;
  readonly acquiredOn: string;
  readonly method: string;
  readonly cost: Paise;
  readonly accumulated: Paise;
  readonly netBookValue: Paise;
  readonly status: string;
  readonly lastPeriod: string | null;
}

export interface Result { readonly ok: boolean; readonly error?: string; readonly message?: string }

export async function getAssetRegister(asOn: string): Promise<AssetRow[]> {
  await requirePermission('assets.view');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('fixed_asset_register', { p_as_on: asOn });
  if (error) throw new Error(`Failed to load the asset register: ${error.message}`);
  return (data ?? []).map((r) => ({
    id: r.asset_id, code: r.asset_code, name: r.name, category: r.category, branch: r.branch_name,
    account: r.account_code, acquiredOn: r.acquired_on, method: r.method,
    cost: fromDb(r.cost), accumulated: fromDb(r.accumulated), netBookValue: fromDb(r.net_book_value),
    status: r.status, lastPeriod: r.last_period,
  }));
}

export async function getAssetAccounts(): Promise<{ id: string; label: string }[]> {
  await requirePermission('assets.view');
  const supabase = await createSupabaseServerClient();
  const { data } = await supabase.from('chart_of_accounts')
    .select('id, code, name').eq('account_type', 'ASSET').eq('is_group', false).eq('status', 'ACTIVE')
    .gte('code', '1950').lt('code', '1959').order('code');
  return (data ?? []).map((a) => ({ id: a.id, label: `${a.code} · ${a.name}` }));
}

export async function registerAsset(input: {
  readonly name: string; readonly accountId: string; readonly acquiredOn: string; readonly cost: number;
  readonly method: 'SLM' | 'WDV'; readonly lifeMonths?: number | null; readonly wdvRate?: number | null;
  readonly salvage?: number | null; readonly category?: string | null;
}): Promise<Result> {
  await requirePermission('assets.manage');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('register_fixed_asset', {
    p_name: input.name, p_asset_account_id: input.accountId, p_acquired_on: input.acquiredOn,
    p_cost: input.cost, p_method: input.method,
    p_useful_life_months: input.method === 'SLM' ? (input.lifeMonths ?? undefined) : undefined,
    p_wdv_rate: input.method === 'WDV' ? (input.wdvRate ?? undefined) : undefined,
    p_salvage_value: input.salvage ?? 0, p_category: input.category ?? undefined,
  });
  return error ? { ok: false, error: error.message } : { ok: true, message: 'Asset registered.' };
}

export async function runDepreciation(month: string): Promise<Result> {
  await requirePermission('assets.manage');
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('run_depreciation', { p_month: month });
  if (error) return { ok: false, error: error.message };
  const row = Array.isArray(data) ? data[0] : data;
  return {
    ok: true,
    message: row && row.assets > 0
      ? `Depreciation posted for ${row.assets} asset(s), ₹${Number(row.total).toLocaleString('en-IN')} in ${row.journals} journal(s).`
      : 'Nothing to charge: every asset is already depreciated for that month.',
  };
}

export async function disposeAsset(input: {
  readonly assetId: string; readonly date: string; readonly proceeds: number; readonly reason: string;
}): Promise<Result> {
  await requirePermission('assets.manage');
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('dispose_fixed_asset', {
    p_asset_id: input.assetId, p_date: input.date, p_proceeds: input.proceeds, p_reason: input.reason,
  });
  return error ? { ok: false, error: error.message } : { ok: true, message: 'Disposed; the gain or loss is posted.' };
}
