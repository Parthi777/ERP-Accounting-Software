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

/**
 * Raises an e-way bill for a sale and files it — spec §40.
 *
 * One action rather than queue-then-file, because from the counter it is one
 * decision: the vehicle is leaving and it needs its paperwork. The two steps
 * stay separate underneath so a failure is retryable without re-entering the
 * transport details.
 */
export async function raiseEwayBillAction(
  input: service.EwayTransportInput,
): Promise<service.GstResult> {
  try {
    const result = await service.raiseEwayBill(input);
    // Refresh either way: a failure records its reason and attempt count, which
    // is what the operator needs in front of them.
    refreshGst();
    revalidatePath(`/sales/${input.saleId}`);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

/** Retries a bill that is queued or failed. */
export async function fileEwayBillAction(ewayId: string): Promise<service.GstResult> {
  try {
    const result = await service.fileEwayBill(ewayId);
    refreshGst();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
