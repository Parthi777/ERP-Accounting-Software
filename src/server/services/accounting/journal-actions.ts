'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/accounting/journal-entry-service';
import { toAppError } from '@/server/errors';

function refresh(id?: string) {
  revalidatePath('/accounting/journals');
  revalidatePath('/accounting/trial-balance');
  revalidatePath('/accounting/customer-ledger');
  revalidatePath('/accounting/supplier-ledger');
  if (id) revalidatePath(`/accounting/journals/${id}`);
}

export async function postManualJournalAction(input: {
  entryDate: string;
  narration: string;
  lines: readonly service.JournalLineInput[];
  idempotencyKey: string;
}): Promise<service.JournalResult> {
  try {
    const result = await service.postManualJournal(input);
    if (result.ok) refresh(result.id);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function reverseJournalAction(input: {
  journalId: string;
  reason: string;
}): Promise<service.JournalResult> {
  try {
    const result = await service.reverseJournal(input);
    if (result.ok) refresh(input.journalId);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
