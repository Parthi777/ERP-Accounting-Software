'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/gst/gst-compliance-service';
import { toAppError } from '@/server/errors';

type R = { ok: boolean; error?: string; message?: string };

async function run(fn: () => Promise<R>): Promise<R> {
  try {
    const result = await fn();
    if (result.ok) revalidatePath('/gst', 'layout');
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function issueNoteAction(v: Record<string, string>): Promise<R> {
  return run(() => service.issueNote({
    noteType: v.noteType === 'DEBIT' ? 'DEBIT' : 'CREDIT',
    original: v.original ?? '', taxable: Number(v.taxable), gstRate: Number(v.gstRate || 0),
    accountId: v.accountId ?? '', reason: v.reason ?? 'OTHER', description: v.description ?? '',
    noteDate: v.noteDate ?? '', partyNoteNumber: v.partyNoteNumber ?? '',
    itcEligible: v.itcEligible !== 'false', hsnSac: (v.hsnSac ?? '').trim(),
    idempotencyKey: v.idempotencyKey ?? crypto.randomUUID(),
  }));
}

export async function cancelNoteAction(v: Record<string, string>): Promise<R> {
  return run(() => service.cancelNote(v.noteId ?? '', v.reason ?? ''));
}

export async function itcAdjustmentAction(v: Record<string, string>): Promise<R> {
  return run(() => service.recordItcAdjustment({
    direction: v.direction === 'RECLAIM' ? 'RECLAIM' : 'REVERSAL', rule: v.rule ?? 'OTHER',
    branchId: v.branchId ?? '', cgst: Number(v.cgst || 0), sgst: Number(v.sgst || 0), igst: Number(v.igst || 0),
    note: v.note ?? '', date: v.date ?? '', billId: v.billId || null,
    idempotencyKey: v.idempotencyKey ?? crypto.randomUUID(),
  }));
}
