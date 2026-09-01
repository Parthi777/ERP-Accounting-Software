'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/gst/gst-service';
import { toAppError } from '@/server/errors';

function refreshGst() {
  revalidatePath('/gst');
  revalidatePath('/gst/e-invoice');
  revalidatePath('/gst/e-way-bill');
  revalidatePath('/gst/reports');
}

export async function queueEinvoiceAction(
  documentType: string,
  documentId: string,
): Promise<service.GstResult> {
  try {
    const result = await service.queueEinvoice(documentType, documentId);
    if (result.ok) refreshGst();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function queueEwayBillAction(input: {
  documentType: string;
  documentId: string;
  transportMode?: string;
  vehicleNumber?: string | null;
  distanceKm?: number | null;
  transporterId?: string | null;
  transporterName?: string | null;
}): Promise<service.GstResult> {
  try {
    const result = await service.queueEwayBill(input);
    if (result.ok) refreshGst();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

/**
 * Files a queued document with the portal — spec §40.
 *
 * Separate from queueing on purpose: queueing decides *what* to file and is
 * instant; this reaches an external system and can fail without anything
 * accounting-side being wrong.
 */
export async function submitEinvoiceAction(einvoiceId: string): Promise<service.GstResult> {
  try {
    const result = await service.submitEinvoice(einvoiceId);
    // Refresh either way: a failure updates the row's error and attempt count,
    // which is exactly what the operator needs to see.
    refreshGst();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
