'use server';

import { revalidatePath } from 'next/cache';

import type { MasterKind } from '@/lib/validation/masters';
import * as service from '@/server/services/masters/masters-service';
import { toAppError } from '@/server/errors';

/**
 * Server actions for the master screens.
 *
 * Thin: the service owns permissions, validation and audit. These exist so client
 * components have something callable, and so the right routes are revalidated.
 */

/** Which list pages show each master, so a change refreshes all of them. */
const AFFECTED_PATHS: Record<MasterKind, readonly string[]> = {
  hsn: ['/masters/hsn'],
  tax: ['/masters/tax'],
  vehicle_model: ['/vehicles/models', '/vehicles/variants'],
  vehicle_variant: ['/vehicles/variants', '/vehicles/models'],
  inventory_item: ['/masters/accessories', '/masters/spares', '/inventory/accessories', '/inventory/spares'],
  finance_company: ['/finance/companies', '/masters/finance-companies'],
  supplier: ['/masters/suppliers', '/accounting/supplier-ledger'],
};

function revalidate(kind: MasterKind) {
  for (const path of AFFECTED_PATHS[kind]) {
    revalidatePath(path);
  }
}

export async function createMasterAction(kind: MasterKind, input: unknown): Promise<service.MasterResult> {
  try {
    const result = await service.createMaster(kind, input);
    if (result.ok) revalidate(kind);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function updateMasterAction(
  kind: MasterKind,
  id: string,
  input: unknown,
): Promise<service.MasterResult> {
  try {
    const result = await service.updateMaster(kind, id, input);
    if (result.ok) revalidate(kind);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function deleteMasterAction(kind: MasterKind, id: string): Promise<service.MasterResult> {
  try {
    const result = await service.deleteMaster(kind, id);
    if (result.ok) revalidate(kind);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function deactivateMasterAction(kind: MasterKind, id: string): Promise<service.MasterResult> {
  try {
    const result = await service.deactivateMaster(kind, id);
    if (result.ok) revalidate(kind);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
