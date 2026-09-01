import 'server-only';

import { requirePermission, requireTenantContext } from '@/server/auth/tenant-context';
import { ForbiddenError } from '@/server/errors';
import type { Permission } from '@/lib/permissions';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { fromDb, type Paise } from '@/lib/money';
import { recordAudit } from '@/server/services/audit/record-audit';

/**
 * Vehicle pricing — spec §15, §42, §60.9.
 *
 * A price is never edited. Creating a new version supersedes the current one, and
 * the old row stays exactly as it was so an invoice priced under it remains
 * explainable. `supersedeAndCreate` does both halves in the right order.
 */

export interface PriceVersionRow {
  readonly id: string;
  readonly versionNumber: number;
  readonly modelLabel: string;
  readonly variantName: string | null;
  readonly branchName: string | null;
  readonly exShowroom: Paise;
  readonly insurance: Paise;
  readonly registration: Paise;
  readonly accessories: Paise;
  readonly forwarding: Paise;
  readonly otherCharges: Paise;
  readonly totalOnRoad: Paise;
  readonly purchaseCost: Paise | null;
  readonly effectiveFrom: string;
  readonly effectiveTo: string | null;
  readonly status: string;
}

export async function getPriceVersions(modelId: string | null) {
  const context = await requirePermission('vehicles.pricing.view');
  const supabase = await createSupabaseServerClient();

  let query = supabase
    .from('vehicle_price_versions')
    .select('*, vehicle_models ( brand, name ), vehicle_variants ( name ), branches ( name )')
    .order('effective_from', { ascending: false })
    .order('version_number', { ascending: false });

  if (modelId) {
    query = query.eq('model_id', modelId);
  }

  const { data, error } = await query;
  if (error) {
    throw new Error(`Failed to load price versions: ${error.message}`);
  }

  const canSeeCost = context.permissions.has('vehicles.view_cost');

  return (data ?? []).map((row): PriceVersionRow => ({
    id: row.id,
    versionNumber: row.version_number,
    modelLabel: `${row.vehicle_models.brand} ${row.vehicle_models.name}`,
    variantName: row.vehicle_variants?.name ?? null,
    branchName: row.branches?.name ?? null,
    exShowroom: fromDb(row.ex_showroom),
    insurance: fromDb(row.insurance),
    registration: fromDb(row.registration),
    accessories: fromDb(row.mandatory_accessories),
    forwarding: fromDb(row.forwarding_charge),
    otherCharges: fromDb(row.other_charges),
    totalOnRoad: fromDb(row.total_on_road),
    // Restricted (spec §52): omitted entirely, not blanked.
    purchaseCost: canSeeCost ? fromDb(row.purchase_cost) : null,
    effectiveFrom: row.effective_from,
    effectiveTo: row.effective_to,
    status: row.status,
  }));
}

export interface PriceInput {
  readonly model_id: string;
  readonly variant_id?: string;
  readonly branch_id?: string;
  readonly ex_showroom: number;
  readonly insurance: number;
  readonly registration: number;
  readonly mandatory_accessories: number;
  readonly forwarding_charge: number;
  readonly other_charges: number;
  readonly purchase_cost: number;
  readonly max_discount: number;
  readonly tax_code?: string;
  readonly effective_from: string;
  readonly notes?: string;
}

export interface PriceResult {
  readonly ok: boolean;
  readonly id?: string;
  readonly error?: string;
}

/**
 * Creates the next version for a scope, as a DRAFT.
 *
 * It does not go live on save. Spec §15 wants DRAFT → SUBMITTED → APPROVED →
 * ACTIVE, because a price change is what every future invoice is computed from;
 * `decidePriceVersion` walks it through, and activation supersedes the incumbent
 * there (the partial unique index allows only one ACTIVE version per scope, so
 * the two must happen together).
 */
export async function createPriceVersion(input: PriceInput): Promise<PriceResult> {
  const context = await requirePermission('vehicles.pricing.manage');
  const supabase = await createSupabaseServerClient();

  if (!context.dealerId) {
    return { ok: false, error: 'Your account is not attached to a dealer.' };
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(input.effective_from)) {
    return { ok: false, error: 'Choose a valid effective date.' };
  }

  const scope = supabase
    .from('vehicle_price_versions')
    .select('id, version_number, effective_from')
    .eq('model_id', input.model_id);

  const { data: existing, error: readError } = await (input.variant_id
    ? scope.eq('variant_id', input.variant_id)
    : scope.is('variant_id', null));

  if (readError) {
    return { ok: false, error: `Could not read existing prices: ${readError.message}` };
  }

  const nextVersion = Math.max(0, ...(existing ?? []).map((v) => v.version_number)) + 1;
  try {
    const { data, error } = await supabase
      .from('vehicle_price_versions')
      .insert({
        dealer_id: context.dealerId,
        model_id: input.model_id,
        variant_id: input.variant_id || null,
        branch_id: input.branch_id || null,
        version_number: nextVersion,
        ex_showroom: String(input.ex_showroom),
        insurance: String(input.insurance),
        registration: String(input.registration),
        mandatory_accessories: String(input.mandatory_accessories),
        forwarding_charge: String(input.forwarding_charge),
        other_charges: String(input.other_charges),
        purchase_cost: String(input.purchase_cost),
        max_discount: String(input.max_discount),
        tax_code: input.tax_code || null,
        effective_from: input.effective_from,
        notes: input.notes || null,
        // A draft, with no approval stamps: nothing has been approved yet.
        status: 'DRAFT',
        created_by: context.userId,
      })
      .select('id')
      .single();

    if (error) {
      throw error;
    }

    await recordAudit({
      action: 'PRICE_CHANGE',
      entityType: 'vehicle_price_versions',
      entityId: data.id,
      dealerId: context.dealerId,
      branchId: context.activeBranch?.id ?? null,
      userId: context.userId,
      userEmail: context.email,
      newData: { version: nextVersion, effective_from: input.effective_from, ex_showroom: input.ex_showroom },
    });

    return { ok: true, id: data.id };
  } catch (error) {
    const code = (error as { code?: string })?.code;
    const message = (error as { message?: string })?.message ?? String(error);
    console.error('[pricing] create failed', { code, message });

    if (code === '23505') {
      return {
        ok: false,
        error: 'A price for this model already covers that date. Choose a later effective date.',
      };
    }
    return { ok: false, error: 'The price version could not be saved.' };
  }
}

export type PriceAction = 'SUBMIT' | 'APPROVE' | 'REJECT' | 'ACTIVATE';

export interface PriceApprovalRow extends PriceVersionRow {
  readonly modelId: string;
  readonly submittedAt: string | null;
  readonly approvedAt: string | null;
  readonly notes: string | null;
}

/**
 * The approval queue — spec §15.
 *
 * Reachable by either the Masters permission or the approver's, because the
 * screen serves both halves of the workflow: one person submits, another
 * approves.
 */
export async function getPriceApprovalQueue(status: string): Promise<PriceApprovalRow[]> {
  const context = await requireTenantContext();
  if (
    !context.permissions.has('masters.pricing.manage') &&
    !context.permissions.has('vehicles.pricing.approve') &&
    !context.permissions.has('vehicles.pricing.view')
  ) {
    throw new ForbiddenError('masters.pricing.manage');
  }

  const supabase = await createSupabaseServerClient();

  let query = supabase
    .from('vehicle_price_versions')
    .select(
      'id, version_number, model_id, ex_showroom, insurance, registration, mandatory_accessories, forwarding_charge, other_charges, total_on_road, purchase_cost, effective_from, effective_to, status, submitted_at, approved_at, notes, vehicle_models!inner ( brand, name ), vehicle_variants ( name ), branches ( name )',
    )
    .order('effective_from', { ascending: false })
    .limit(300);

  if (status !== 'ALL') {
    query = query.eq('status', status as 'DRAFT');
  }

  const { data, error } = await query;
  if (error) {
    throw new Error(`Failed to load price versions: ${error.message}`);
  }

  const maySeeCost = context.permissions.has('vehicles.view_cost');

  return (data ?? []).map((row) => ({
    id: row.id,
    modelId: row.model_id,
    versionNumber: row.version_number,
    modelLabel: `${row.vehicle_models.brand} ${row.vehicle_models.name}`,
    variantName: row.vehicle_variants?.name ?? null,
    branchName: row.branches?.name ?? null,
    exShowroom: fromDb(row.ex_showroom),
    insurance: fromDb(row.insurance),
    registration: fromDb(row.registration),
    accessories: fromDb(row.mandatory_accessories),
    forwarding: fromDb(row.forwarding_charge),
    otherCharges: fromDb(row.other_charges),
    totalOnRoad: fromDb(row.total_on_road),
    // Cost is restricted (spec §52): omitted, not blanked.
    purchaseCost: maySeeCost ? fromDb(row.purchase_cost) : null,
    effectiveFrom: row.effective_from,
    effectiveTo: row.effective_to,
    status: row.status,
    submittedAt: row.submitted_at,
    approvedAt: row.approved_at,
    notes: row.notes,
  }));
}

/**
 * Walks a version through the workflow.
 *
 * Submitting and activating are the price owner's steps; approving and
 * rejecting belong to the approver. The database refuses self-approval
 * regardless, so a user holding both cannot quietly take a price live alone.
 */
export async function decidePriceVersion(
  id: string,
  action: PriceAction,
  reason?: string,
): Promise<PriceResult> {
  const needed: Permission =
    action === 'APPROVE' || action === 'REJECT'
      ? 'vehicles.pricing.approve'
      : 'masters.pricing.manage';

  const context = await requireTenantContext();
  if (!context.permissions.has(needed) && !context.permissions.has('vehicles.pricing.manage')) {
    throw new ForbiddenError(needed);
  }

  if (action === 'REJECT' && !reason?.trim()) {
    return { ok: false, error: 'A rejection must say why. The reason is kept on the version.' };
  }

  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc('decide_price_version', {
    p_version_id: id,
    p_action: action,
    p_reason: reason?.trim() || null,
  });

  if (error) {
    console.error('[pricing] decision failed', error.message);
    if (error.message.includes('other than the person who submitted')) {
      return {
        ok: false,
        error: 'A price must be approved by someone other than whoever submitted it.',
      };
    }
    if (error.message.includes('Only a')) {
      return { ok: false, error: error.message };
    }
    return { ok: false, error: `The price could not be updated: ${error.message}` };
  }

  await recordAudit({
    action: action === 'APPROVE' ? 'APPROVE' : action === 'REJECT' ? 'REJECT' : 'PRICE_CHANGE',
    entityType: 'vehicle_price_versions',
    entityId: id,
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { action },
    reason: reason?.trim() || undefined,
  });

  return { ok: true, id };
}
