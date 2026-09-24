'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/attachments/attachment-service';
import { toAppError } from '@/server/errors';

export async function recordAttachmentAction(
  input: Parameters<typeof service.recordAttachment>[0],
  revalidate: string,
): Promise<{ ok: boolean; error?: string }> {
  try {
    const result = await service.recordAttachment(input);
    if (result.ok) revalidatePath(revalidate);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
