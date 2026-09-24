'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/assets/asset-service';
import { toAppError } from '@/server/errors';

type R = { ok: boolean; error?: string; message?: string };
const n = (v: string | undefined) => (v ? Number(v) : null);

async function run(fn: () => Promise<R>): Promise<R> {
  try {
    const result = await fn();
    if (result.ok) {
      revalidatePath('/accounting/fixed-assets');
      revalidatePath('/accounting/tie-out');
    }
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function registerAssetAction(v: Record<string, string>): Promise<R> {
  return run(() => service.registerAsset({
    name: v.name ?? '', accountId: v.accountId ?? '', acquiredOn: v.acquiredOn ?? '', cost: n(v.cost) ?? 0,
    method: v.method === 'WDV' ? 'WDV' : 'SLM', lifeMonths: n(v.lifeMonths), wdvRate: n(v.wdvRate),
    salvage: n(v.salvage), category: v.category || null,
  }));
}

export async function runDepreciationAction(v: Record<string, string>): Promise<R> {
  return run(() => service.runDepreciation(`${v.month}-01`));
}

export async function disposeAssetAction(v: Record<string, string>): Promise<R> {
  return run(() => service.disposeAsset({
    assetId: v.assetId ?? '', date: v.date ?? '', proceeds: n(v.proceeds) ?? 0, reason: v.reason ?? '',
  }));
}
