'use server';

import { revalidatePath } from 'next/cache';

import type { CustomerInput } from '@/lib/validation/customer';
import * as service from '@/server/services/customers/customer-service';
import { toAppError } from '@/server/errors';

/**
 * Server actions for the customer forms.
 *
 * Thin wrappers: the service owns the permission check, validation and audit.
 * These exist to give client components a callable entry point and to invalidate
 * the right cached routes afterwards.
 */

export async function createCustomerAction(input: CustomerInput): Promise<service.SaveResult> {
  try {
    const result = await service.createCustomer(input);
    if (result.ok) {
      revalidatePath('/customers');
    }
    return result;
  } catch (error) {
    const appError = toAppError(error);
    return { ok: false, error: appError.userMessage };
  }
}

export async function updateCustomerAction(
  id: string,
  input: CustomerInput,
): Promise<service.SaveResult> {
  try {
    const result = await service.updateCustomer(id, input);
    if (result.ok) {
      revalidatePath('/customers');
      revalidatePath(`/customers/${id}`);
    }
    return result;
  } catch (error) {
    const appError = toAppError(error);
    return { ok: false, error: appError.userMessage };
  }
}
