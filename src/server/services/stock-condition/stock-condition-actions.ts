'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/stock-condition/stock-condition-service';
import { toAppError } from '@/server/errors';

type R = { ok: boolean; error?: string; message?: string };

async function run(fn: () => Promise<R>): Promise<R> {
  try {
    const result = await fn();
    if (result.ok) revalidatePath('/inventory', 'layout');
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function markDamagedAction(v: Record<string, string>): Promise<R> {
  return run(() => service.markDamaged({
    itemId: v.itemId ?? '', branchId: v.branchId ?? '', source: v.source ?? 'COMPANY',
    quantity: Number(v.quantity), realisableUnit: Number(v.realisableUnit || 0), reason: v.reason ?? '',
  }));
}

export async function moveConsignmentAction(v: Record<string, string>): Promise<R> {
  return run(() => service.moveConsignment({
    itemId: v.itemId ?? '', branchId: v.branchId ?? '', quantity: Number(v.quantity),
    direction: v.direction === 'RETURN' ? 'RETURN' : 'RECEIVE', reference: v.reference ?? '',
  }));
}
