import 'server-only';

import { requirePermission } from '@/server/auth/tenant-context';
import type { Permission } from '@/lib/permissions';
import {
  MASTER_SCHEMAS,
  deriveIgst,
  type MasterKind,
} from '@/lib/validation/masters';
import * as repository from '@/server/repositories/masters-repository';
import { recordAudit } from '@/server/services/audit/record-audit';

export type {
  HsnRow,
  TaxCodeRow,
  VehicleModelRow,
  VehicleModelWithCounts,
  VehicleVariantRow,
  VehicleVariantWithModel,
  InventoryItemRow,
  FinanceCompanyRow,
  SupplierRow,
} from '@/server/repositories/masters-repository';

/**
 * Master data: create, edit, delete.
 *
 * The permission each master requires is declared once, here, so a new screen
 * cannot accidentally gate itself on the wrong one.
 */
const PERMISSIONS: Record<MasterKind, { view: Permission; manage: Permission; label: string }> = {
  hsn: { view: 'masters.hsn.view', manage: 'masters.hsn.manage', label: 'HSN code' },
  tax: { view: 'masters.tax.view', manage: 'masters.tax.manage', label: 'Tax code' },
  vehicle_model: { view: 'vehicles.models.view', manage: 'vehicles.models.manage', label: 'Vehicle model' },
  vehicle_variant: { view: 'vehicles.models.view', manage: 'vehicles.models.manage', label: 'Variant' },
  inventory_item: { view: 'inventory.view', manage: 'inventory.items.manage', label: 'Item' },
  finance_company: { view: 'finance.companies.view', manage: 'finance.companies.manage', label: 'Finance company' },
  supplier: { view: 'masters.suppliers.view', manage: 'masters.suppliers.manage', label: 'Supplier' },
};

export interface MasterResult {
  readonly ok: boolean;
  readonly id?: string;
  readonly error?: string;
  readonly fieldErrors?: Readonly<Record<string, string>>;
  /** Set when a delete was refused because the record is referenced. */
  readonly inUse?: boolean;
}

// ── Reads ────────────────────────────────────────────────────────────────────

export async function getHsnCodes() {
  await requirePermission(PERMISSIONS.hsn.view);
  return repository.listHsn();
}

export async function getTaxCodes() {
  await requirePermission(PERMISSIONS.tax.view);
  return repository.listTaxCodes();
}

export async function getVehicleModels() {
  await requirePermission(PERMISSIONS.vehicle_model.view);
  return repository.listVehicleModels();
}

export async function getVehicleVariants() {
  await requirePermission(PERMISSIONS.vehicle_variant.view);
  return repository.listVehicleVariants();
}

export async function getInventoryItems(itemType?: 'ACCESSORY' | 'SPARE') {
  await requirePermission(PERMISSIONS.inventory_item.view);
  return repository.listInventoryItems(itemType);
}

export async function getFinanceCompanies() {
  await requirePermission(PERMISSIONS.finance_company.view);
  return repository.listFinanceCompanies();
}

export async function getSuppliers() {
  await requirePermission(PERMISSIONS.supplier.view);
  return repository.listSuppliers();
}

export async function getMasterRecord(kind: MasterKind, id: string) {
  await requirePermission(PERMISSIONS[kind].view);
  return repository.getMaster(kind, id);
}

export async function getPickerOptions() {
  await requirePermission('inventory.view');
  return repository.listPickerOptions();
}

// ── Writes ───────────────────────────────────────────────────────────────────

export async function createMaster(
  kind: MasterKind,
  input: unknown,
): Promise<MasterResult> {
  const context = await requirePermission(PERMISSIONS[kind].manage);

  const parsed = MASTER_SCHEMAS[kind].safeParse(input);
  if (!parsed.success) {
    return { ok: false, ...fieldErrorsFrom(parsed.error.issues) };
  }
  if (!context.dealerId) {
    return { ok: false, error: 'Your account is not attached to a dealer.' };
  }

  try {
    const values = prepare(kind, parsed.data as Record<string, unknown>);
    const row = await repository.insertMaster(kind, values, {
      dealerId: context.dealerId,
      userId: context.userId,
    });

    await recordAudit({
      action: 'CREATE',
      entityType: kind,
      entityId: row.id,
      dealerId: context.dealerId,
      branchId: context.activeBranch?.id ?? null,
      userId: context.userId,
      userEmail: context.email,
      newData: values,
    });

    return { ok: true, id: row.id };
  } catch (error) {
    return { ok: false, ...describe(error, PERMISSIONS[kind].label) };
  }
}

export async function updateMaster(
  kind: MasterKind,
  id: string,
  input: unknown,
): Promise<MasterResult> {
  const context = await requirePermission(PERMISSIONS[kind].manage);

  const parsed = MASTER_SCHEMAS[kind].safeParse(input);
  if (!parsed.success) {
    return { ok: false, ...fieldErrorsFrom(parsed.error.issues) };
  }

  try {
    const values = prepare(kind, parsed.data as Record<string, unknown>);
    const row = await repository.updateMaster(kind, id, values, { userId: context.userId });

    await recordAudit({
      action: 'UPDATE',
      entityType: kind,
      entityId: id,
      dealerId: context.dealerId,
      branchId: context.activeBranch?.id ?? null,
      userId: context.userId,
      userEmail: context.email,
      newData: values,
    });

    return { ok: true, id: row.id };
  } catch (error) {
    return { ok: false, ...describe(error, PERMISSIONS[kind].label) };
  }
}

/**
 * Deletes a master record, or explains why it cannot be deleted.
 *
 * A master that transactions already reference must not disappear — the history
 * that points at it would be unreadable. Rather than soft-deleting everything by
 * default, this attempts the real delete and lets the database's foreign keys
 * answer. A refusal comes back as `inUse`, and the caller offers deactivation.
 */
export async function deleteMaster(kind: MasterKind, id: string): Promise<MasterResult> {
  const context = await requirePermission(PERMISSIONS[kind].manage);

  try {
    await repository.deleteMaster(kind, id);

    await recordAudit({
      action: 'DELETE',
      entityType: kind,
      entityId: id,
      dealerId: context.dealerId,
      branchId: context.activeBranch?.id ?? null,
      userId: context.userId,
      userEmail: context.email,
    });

    return { ok: true, id };
  } catch (error) {
    const code = (error as { code?: string })?.code;

    // 23503 — foreign key violation: something still points at this row.
    if (code === '23503') {
      return {
        ok: false,
        inUse: true,
        error: `This ${PERMISSIONS[kind].label.toLowerCase()} is used by existing records, so it cannot be deleted. Deactivate it instead — history stays readable and it stops appearing in new transactions.`,
      };
    }
    return { ok: false, ...describe(error, PERMISSIONS[kind].label) };
  }
}

export async function deactivateMaster(kind: MasterKind, id: string): Promise<MasterResult> {
  const context = await requirePermission(PERMISSIONS[kind].manage);

  // Vehicle models and variants use DISCONTINUED where the others use INACTIVE.
  const status = kind === 'vehicle_model' || kind === 'vehicle_variant' ? 'DISCONTINUED' : 'INACTIVE';

  try {
    await repository.deactivateMaster(kind, id, status, { userId: context.userId });

    await recordAudit({
      action: 'UPDATE',
      entityType: kind,
      entityId: id,
      dealerId: context.dealerId,
      branchId: context.activeBranch?.id ?? null,
      userId: context.userId,
      userEmail: context.email,
      reason: 'Deactivated instead of deleted — referenced by existing records.',
      newData: { status },
    });

    return { ok: true, id };
  } catch (error) {
    return { ok: false, ...describe(error, PERMISSIONS[kind].label) };
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Last shaping before the database.
 *
 * IGST is derived rather than collected: the table constrains it to equal
 * CGST + SGST, so offering it as a field would only let a user contradict a rule
 * the database will enforce anyway.
 */
function prepare(kind: MasterKind, values: Record<string, unknown>): Record<string, unknown> {
  if (kind === 'tax') {
    const cgst = Number(values.cgst_rate ?? 0);
    const sgst = Number(values.sgst_rate ?? 0);
    return { ...values, igst_rate: deriveIgst(cgst, sgst) };
  }
  return values;
}

function fieldErrorsFrom(issues: readonly { path: readonly PropertyKey[]; message: string }[]) {
  const fieldErrors: Record<string, string> = {};
  for (const issue of issues) {
    const key = String(issue.path[0] ?? '');
    if (key && !fieldErrors[key]) {
      fieldErrors[key] = issue.message;
    }
  }
  return { fieldErrors, error: 'Please correct the highlighted fields.' };
}

function describe(error: unknown, label: string): { error: string; fieldErrors?: Record<string, string> } {
  const code = (error as { code?: string })?.code;
  const message = (error as { message?: string })?.message ?? String(error);
  console.error('[masters] write failed', { label, code, message });

  if (code === '23505') {
    return { error: `That ${label.toLowerCase()} code already exists.`, fieldErrors: { code: 'Already in use.' } };
  }
  if (code === '23514') {
    return { error: 'Some of the values entered are not valid. Check the highlighted fields.' };
  }
  if (code === '23503') {
    return { error: 'A referenced record could not be found. Refresh and try again.' };
  }
  if (code === '42501' || message.includes('row-level security')) {
    return { error: `You do not have permission to change this ${label.toLowerCase()}.` };
  }
  return { error: `The ${label.toLowerCase()} could not be saved. Please try again.` };
}
