'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/approvals/approval-service';
import { toAppError } from '@/server/errors';

function refresh() {
  revalidatePath('/accounting/approvals');
  revalidatePath('/accounting/journals');
  revalidatePath('/inventory');
  revalidatePath('/dashboard');
}

export async function decideApprovalAction(
  input: Parameters<typeof service.decideApproval>[0],
): Promise<service.ApprovalResult> {
  try {
    const result = await service.decideApproval(input);
    if (result.ok) refresh();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function withdrawApprovalAction(requestId: string): Promise<service.ApprovalResult> {
  try {
    const result = await service.withdrawApproval(requestId);
    if (result.ok) refresh();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
