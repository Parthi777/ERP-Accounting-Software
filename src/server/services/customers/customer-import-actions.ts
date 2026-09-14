'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/customers/customer-import';
import { toAppError } from '@/server/errors';

/** Validates an uploaded file and reports what would happen. Writes nothing. */
export async function previewCustomerImportAction(
  csv: string,
): Promise<service.CustomerImportPreview> {
  try {
    return await service.previewCustomerImport(csv);
  } catch (error) {
    // A thrown error here is usually a missing permission or an unreachable
    // database, neither of which is about a particular row — so it is reported
    // as the file's single problem rather than attributed to row 1.
    return {
      rows: [
        {
          rowNumber: 0,
          customer_code: '', name: '', customer_type: '', mobile: '', alternate_mobile: '',
          email: '', address_line1: '', city: '', state: '', state_code: '', pincode: '',
          gstin: '', pan: '',
          errors: [toAppError(error).userMessage],
        },
      ],
      validCount: 0,
      errorCount: 1,
      headers: [],
    };
  }
}

export async function commitCustomerImportAction(
  csv: string,
): Promise<service.CustomerImportResult> {
  try {
    const result = await service.commitCustomerImport(csv);
    if (result.ok) {
      revalidatePath('/customers');
      revalidatePath('/masters/customers');
    }
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

/** The header row plus one example, so nobody has to guess the column names. */
export async function customerImportTemplateAction(): Promise<string> {
  return service.customerImportTemplate();
}
