'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/gst/gst-returns-service';
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

export async function previewGstr2bAction(csv: string) {
  return service.previewGstr2b(csv);
}

export async function importGstr2bAction(gstin: string, period: string, fileName: string | null, csv: string) {
  try {
    const result = await service.importGstr2b(gstin, period, csv, fileName);
    if (result.ok) revalidatePath('/gst', 'layout');
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function prepareReturnAction(v: Record<string, string>): Promise<R> {
  return run(() => service.prepareReturn(v.returnType === 'GSTR3B' ? 'GSTR3B' : 'GSTR1', v.gstin ?? '', v.period ?? ''));
}

export async function signOffReturnAction(v: Record<string, string>): Promise<R> {
  return run(() => service.signOffReturn(v.returnId ?? ''));
}

const num = (v: string | undefined) => (v === undefined || v === '' ? null : Number(v));

export async function recordFilingAction(v: Record<string, string>): Promise<R> {
  return run(() => service.recordFiling({
    returnId: v.returnId ?? '', arn: v.arn ?? '', filedOn: v.filedOn ?? '', taxable: Number(v.taxable || 0),
    igst: Number(v.igst || 0), cgst: Number(v.cgst || 0), sgst: Number(v.sgst || 0),
    itcIgst: num(v.itcIgst), itcCgst: num(v.itcCgst), itcSgst: num(v.itcSgst),
    cpin: v.cpin ?? '', cin: v.cin ?? '', challanAmount: num(v.challanAmount),
  }));
}

export async function postSetoffAction(v: Record<string, string>): Promise<R> {
  return run(() => service.postSetoff(v.returnId ?? '', v.bankAccountId ?? ''));
}
