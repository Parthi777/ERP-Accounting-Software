'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/vehicles/transfer-service';
import { toAppError } from '@/server/errors';

function refresh() {
  revalidatePath('/vehicles/transfers');
  revalidatePath('/vehicles');
  revalidatePath('/dashboard');
}

export async function dispatchTransferAction(input: {
  vehicleId: string;
  toBranchId: string;
  remarks?: string | null;
}): Promise<service.TransferResult> {
  try {
    const result = await service.dispatchTransfer(input);
    if (result.ok) refresh();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function receiveTransferAction(
  transferId: string,
  remarks?: string | null,
): Promise<service.TransferResult> {
  try {
    const result = await service.receiveTransfer(transferId, remarks);
    if (result.ok) refresh();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
