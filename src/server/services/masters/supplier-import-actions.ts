'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/masters/supplier-import';
import { toAppError } from '@/server/errors';

export async function previewSupplierImportAction(
  csv: string,
): Promise<service.SupplierImportPreview> {
  try {
    return await service.previewSupplierImport(csv);
  } catch (error) {
    return {
      rows: [
        {
          rowNumber: 0,
          supplier_code: '', name: '', supplier_type: '', contact_person: '', mobile: '',
          email: '', city: '', state: '', gstin: '', credit_days: '',
          errors: [toAppError(error).userMessage],
        },
      ],
      validCount: 0,
      errorCount: 1,
      headers: [],
    };
  }
}

export async function commitSupplierImportAction(
  csv: string,
): Promise<service.SupplierImportResult> {
  try {
    const result = await service.commitSupplierImport(csv);
    if (result.ok) revalidatePath('/masters/suppliers');
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
