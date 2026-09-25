'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/accounting/narration-service';
import type { ChartResult } from '@/server/services/accounting/chart-service';
import { toAppError } from '@/server/errors';

export async function addNarrationTemplateAction(values: Record<string, string>): Promise<ChartResult> {
  try {
    const result = await service.addNarrationTemplate(values.voucherType ?? '', values.text ?? '');
    if (result.ok) revalidatePath('/admin/settings');
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function setNarrationTemplateStatusAction(values: Record<string, string>): Promise<ChartResult> {
  try {
    const result = await service.setNarrationTemplateStatus(values.id ?? '', values.status === 'ACTIVE' ? 'ACTIVE' : 'INACTIVE');
    if (result.ok) revalidatePath('/admin/settings');
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
