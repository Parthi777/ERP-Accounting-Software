import 'server-only';

import { requirePermission, type TenantContext } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { recordAudit } from '@/server/services/audit/record-audit';

/**
 * Inter-branch vehicle transfers — spec §35.
 *
 * The state that matters is the middle one. Between dispatch and receipt the
 * unit is on a lorry: it belongs to neither branch's sellable stock, or two
 * cashiers in two branches can sell the same chassis. So a dispatch takes the
 * vehicle out of stock (status TRANSFERRED) and only the receipt puts it back
 * in, at the destination.
 *
 * Both ends keep their history: the stock ledger records a TRANSFER_OUT at the
 * source and a TRANSFER_IN at the destination, each pointing at this transfer.
 */

export interface VehicleTransferRow {
  readonly id: string;
  readonly transferNumber: string;
  readonly status: 'IN_TRANSIT' | 'RECEIVED' | 'CANCELLED';
  readonly dispatchedAt: string;
  readonly receivedAt: string | null;
  readonly chassisNo: string;
  readonly modelLabel: string;
  readonly fromBranchId: string;
  readonly fromBranchName: string;
  readonly toBranchId: string;
  readonly toBranchName: string;
  readonly remarks: string | null;
  /** True when the signed-in user may take receipt at the destination. */
  readonly canReceive: boolean;
}

export interface TransferableVehicle {
  readonly id: string;
  readonly chassisNo: string;
  readonly engineNo: string;
  readonly colour: string | null;
  readonly modelLabel: string;
  readonly branchId: string;
  readonly branchName: string;
}

export interface TransferResult {
  readonly ok: boolean;
  readonly error?: string;
  readonly message?: string;
  readonly id?: string;
  readonly number?: string;
}

function resolveBranch(context: TenantContext, requested: string | null): string | null {
  if (!requested) {
    return context.hasAllBranchAccess ? null : (context.activeBranch?.id ?? null);
  }
  return context.accessibleBranches.some((b) => b.id === requested)
    ? requested
    : (context.activeBranch?.id ?? null);
}

export async function getVehicleTransfers(params: {
  readonly status: string;
  readonly branchId: string | null;
  /**
   * Row cap. Defaults to the screen's, which is all anyone scrolls; the
   * report exporter raises it, because a spreadsheet has no such limit and a
   * silently truncated financial extract is worse than none.
   */
  readonly limit?: number;
}): Promise<VehicleTransferRow[]> {
  const context = await requirePermission('vehicles.transfers.view');
  const supabase = await createSupabaseServerClient();

  let query = supabase
    .from('vehicle_transfers')
    .select(
      'id, transfer_number, status, dispatched_at, received_at, remarks, from_branch_id, to_branch_id, vehicles!inner ( chassis_no, vehicle_models ( brand, name ) ), from_branch:branches!vehicle_transfers_from_tenant_fkey ( name ), to_branch:branches!vehicle_transfers_to_tenant_fkey ( name )',
    )
    .order('dispatched_at', { ascending: false })
    .limit(params.limit ?? 200);

  if (params.status !== 'ALL') {
    query = query.eq('status', params.status as VehicleTransferRow['status']);
  }

  // A transfer touches two branches, so a branch-scoped user should see it from
  // either end — filtering on one column alone would hide half their movements.
  const branchId = resolveBranch(context, params.branchId);
  if (branchId) {
    query = query.or(`from_branch_id.eq.${branchId},to_branch_id.eq.${branchId}`);
  }

  const { data, error } = await query;
  if (error) {
    throw new Error(`Failed to load transfers: ${error.message}`);
  }

  const mayManage = context.permissions.has('vehicles.transfers.manage');

  return (data ?? []).map((row) => ({
    id: row.id,
    transferNumber: row.transfer_number,
    status: row.status as VehicleTransferRow['status'],
    dispatchedAt: row.dispatched_at,
    receivedAt: row.received_at,
    chassisNo: row.vehicles.chassis_no,
    modelLabel: `${row.vehicles.vehicle_models?.brand ?? ''} ${row.vehicles.vehicle_models?.name ?? ''}`.trim(),
    fromBranchId: row.from_branch_id,
    fromBranchName: row.from_branch?.name ?? '—',
    toBranchId: row.to_branch_id,
    toBranchName: row.to_branch?.name ?? '—',
    remarks: row.remarks,
    // Receipt belongs to the branch taking delivery. Someone at the despatching
    // branch confirming their own transfer defeats the point of the handover.
    canReceive:
      mayManage &&
      row.status === 'IN_TRANSIT' &&
      (context.hasAllBranchAccess ||
        context.accessibleBranches.some((b) => b.id === row.to_branch_id)),
  }));
}

/** Vehicles that can be sent: in stock, at a branch the user can act for. */
export async function getTransferableVehicles(
  branchId: string | null,
): Promise<TransferableVehicle[]> {
  const context = await requirePermission('vehicles.transfers.manage');
  const supabase = await createSupabaseServerClient();

  let query = supabase
    .from('vehicles')
    .select(
      'id, chassis_no, engine_no, branch_id, branches!inner ( name ), vehicle_models!inner ( brand, name ), vehicle_colours ( name )',
    )
    .eq('status', 'IN_STOCK')
    .order('chassis_no')
    .limit(500);

  const scoped = resolveBranch(context, branchId);
  if (scoped) {
    query = query.eq('branch_id', scoped);
  }

  const { data, error } = await query;
  if (error) {
    throw new Error(`Failed to load vehicles: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    id: row.id,
    chassisNo: row.chassis_no,
    engineNo: row.engine_no,
    colour: row.vehicle_colours?.name ?? null,
    modelLabel: `${row.vehicle_models.brand} ${row.vehicle_models.name}`,
    branchId: row.branch_id,
    branchName: row.branches.name,
  }));
}

export async function dispatchTransfer(input: {
  readonly vehicleId: string;
  readonly toBranchId: string;
  readonly remarks?: string | null;
}): Promise<TransferResult> {
  const context = await requirePermission('vehicles.transfers.manage');
  const supabase = await createSupabaseServerClient();

  if (!input.vehicleId) {
    return { ok: false, error: 'Choose the vehicle to send.' };
  }
  if (!input.toBranchId) {
    return { ok: false, error: 'Choose the branch to send it to.' };
  }
  // The destination must be a real branch of this dealer. RLS would refuse a
  // foreign one anyway; refusing here gives a sentence instead of a constraint.
  if (!context.accessibleBranches.some((b) => b.id === input.toBranchId)) {
    return { ok: false, error: 'That is not a branch you can transfer to.' };
  }

  const { data, error } = await supabase.rpc('dispatch_vehicle_transfer', {
    p_vehicle_id: input.vehicleId,
    p_to_branch_id: input.toBranchId,
    p_remarks: input.remarks?.trim() || null,
  });

  if (error) {
    console.error('[transfers] dispatch failed', error.message);
    return { ok: false, error: describeTransferError(error.message) };
  }

  const row = Array.isArray(data) ? data[0] : data;

  await recordAudit({
    action: 'CREATE',
    entityType: 'vehicle_transfers',
    entityId: row?.transfer_id ?? null,
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { transfer_number: row?.transfer_number, to_branch_id: input.toBranchId },
    reason: input.remarks?.trim() || undefined,
  });

  return {
    ok: true,
    id: row?.transfer_id,
    number: row?.transfer_number,
    message: `Dispatched on ${row?.transfer_number}. The vehicle is in transit until the destination receives it.`,
  };
}

export async function receiveTransfer(
  transferId: string,
  remarks?: string | null,
): Promise<TransferResult> {
  const context = await requirePermission('vehicles.transfers.manage');
  const supabase = await createSupabaseServerClient();

  const { error } = await supabase.rpc('receive_vehicle_transfer', {
    p_transfer_id: transferId,
    p_remarks: remarks?.trim() || null,
  });

  if (error) {
    console.error('[transfers] receive failed', error.message);
    return { ok: false, error: describeTransferError(error.message) };
  }

  await recordAudit({
    action: 'UPDATE',
    entityType: 'vehicle_transfers',
    entityId: transferId,
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { status: 'RECEIVED' },
    reason: remarks?.trim() || undefined,
  });

  return { ok: true, id: transferId, message: 'Received. The vehicle is back in stock at this branch.' };
}

function describeTransferError(message: string): string {
  if (message.includes('only a vehicle in stock')) {
    return 'That vehicle is not in stock — it may be booked, sold, or already in transit.';
  }
  if (message.includes('already at that branch')) {
    return 'The vehicle is already at that branch.';
  }
  if (message.includes('cannot be received again')) {
    return 'This transfer has already been received.';
  }
  if (message.includes('Transfer not found') || message.includes('Vehicle not found')) {
    return 'That record no longer exists.';
  }
  return `The transfer could not be completed: ${message}`;
}
