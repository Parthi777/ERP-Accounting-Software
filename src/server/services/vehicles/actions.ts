'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/vehicles/vehicle-service';
import { toAppError } from '@/server/errors';

/** Validates an uploaded file and reports what would happen. Writes nothing. */
export async function previewVehicleImportAction(csv: string) {
  try {
    return await service.previewImport(csv);
  } catch (error) {
    return {
      rows: [
        {
          rowNumber: 0,
          chassis_no: '', engine_no: '', model_code: '', variant_code: '', branch_code: '',
          colour: '', key_no: '', purchase_invoice: '', purchase_date: '', purchase_cost: '',
          errors: [toAppError(error).userMessage],
        },
      ],
      validCount: 0,
      errorCount: 1,
      headers: [] as string[],
    };
  }
}

export async function commitVehicleImportAction(csv: string): Promise<service.ImportResult> {
  try {
    const result = await service.commitImport(csv);
    if (result.ok) {
      revalidatePath('/vehicles');
    }
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
