'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/service/service-service';
import { toAppError } from '@/server/errors';

function refreshService(invoiceId?: string) {
  revalidatePath('/service');
  revalidatePath('/service/billing');
  revalidatePath('/service/history');
  if (invoiceId) revalidatePath(`/service/billing/${invoiceId}`);
  revalidatePath('/dashboard');
}

export async function createJobCardAction(
  input: service.CreateJobCardInput,
): Promise<service.ServiceResult> {
  try {
    const result = await service.createJobCard(input);
    if (result.ok) refreshService();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function updateJobCardStatusAction(
  id: string,
  status: string,
): Promise<service.ServiceResult> {
  try {
    const result = await service.updateJobCardStatus(id, status);
    if (result.ok) refreshService();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function createServiceInvoiceAction(jobCardId: string): Promise<service.ServiceResult> {
  try {
    const result = await service.createServiceInvoice(jobCardId);
    if (result.ok) refreshService(result.id);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function addServiceLineAction(
  input: service.ServiceLineInput,
): Promise<service.ServiceResult> {
  try {
    const result = await service.addServiceLine(input);
    if (result.ok) refreshService(input.invoiceId);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function removeServiceLineAction(
  lineId: string,
  invoiceId: string,
): Promise<service.ServiceResult> {
  try {
    const result = await service.removeServiceLine(lineId);
    if (result.ok) refreshService(invoiceId);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function postServiceInvoiceAction(invoiceId: string): Promise<service.ServiceResult> {
  try {
    const result = await service.postServiceInvoice(invoiceId);
    if (result.ok) refreshService(invoiceId);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function recordServicePaymentAction(input: {
  invoiceId: string;
  amount: number;
  mode: string;
  reference?: string | null;
}): Promise<service.ServiceResult> {
  try {
    const result = await service.recordServicePayment(input);
    if (result.ok) refreshService(input.invoiceId);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function createCounterInvoiceAction(
  customerId?: string | null,
): Promise<service.ServiceResult> {
  try {
    const result = await service.createCounterInvoice(customerId);
    if (result.ok) {
      revalidatePath('/inventory/counter-sales');
      revalidatePath('/inventory/ledger');
      revalidatePath('/dashboard');
    }
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
