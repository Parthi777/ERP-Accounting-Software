'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/inventory/inventory-service';
import { toAppError } from '@/server/errors';

function refresh() {
  revalidatePath('/inventory/transfers');
  revalidatePath('/inventory/adjustments');
  revalidatePath('/inventory/ledger');
  revalidatePath('/masters/accessories');
  revalidatePath('/masters/spares');
  revalidatePath('/dashboard');
}

export async function transferStockAction(input: {
  itemId: string;
  fromBranchId: string;
  toBranchId: string;
  quantity: number;
  source: service.StockSource;
  remarks?: string | null;
}): Promise<service.InventoryResult> {
  try {
    const result = await service.transferStock(input);
    if (result.ok) refresh();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function adjustStockAction(input: {
  itemId: string;
  branchId: string;
  source: service.StockSource;
  quantity: number;
  reason: string;
}): Promise<service.InventoryResult> {
  try {
    const result = await service.adjustStock(input);
    if (result.ok) refresh();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

/** Validates an uploaded opening-stock file and reports what would happen. */
export async function previewOpeningStockAction(
  csv: string,
): Promise<service.OpeningStockPreview> {
  try {
    return await service.previewOpeningStock(csv);
  } catch (error) {
    return {
      rows: [
        {
          rowNumber: 0,
          item_code: '', branch_code: '', source: '', quantity: '', unit_cost: '',
          errors: [toAppError(error).userMessage],
        },
      ],
      validCount: 0,
      errorCount: 1,
      headers: [],
    };
  }
}

export async function commitOpeningStockAction(csv: string): Promise<service.OpeningStockResult> {
  try {
    const result = await service.commitOpeningStock(csv);
    if (result.ok) {
      refresh();
      revalidatePath('/inventory/upload');
    }
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
