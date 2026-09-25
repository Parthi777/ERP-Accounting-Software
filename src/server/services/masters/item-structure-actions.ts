'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/masters/item-structure-service';
import type { ChartResult } from '@/server/services/accounting/chart-service';
import { toAppError } from '@/server/errors';

async function run(work: () => Promise<ChartResult>, path: string): Promise<ChartResult> {
  try {
    const result = await work();
    if (result.ok) revalidatePath(path, 'layout');
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function addItemGroupAction(values: Record<string, string>) { return run(() => service.addItemGroup(values), '/masters'); }
export async function addPackSizeAction(values: Record<string, string>) { return run(() => service.addPackSize(values), '/masters'); }
export async function removePackSizeAction(values: Record<string, string>) { return run(() => service.removePackSize(values), '/masters'); }
