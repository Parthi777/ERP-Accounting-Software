'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/purchases/purchase-order-service';
import { toAppError } from '@/server/errors';

type Result = service.PurchaseOrderResult;

async function run(work: () => Promise<Result>, paths: string[]): Promise<Result> {
  try {
    const result = await work();
    if (result.ok) for (const p of paths) revalidatePath(p);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function createPurchaseOrderAction(input: service.PurchaseOrderInput): Promise<Result> {
  return run(() => service.createPurchaseOrder(input), ['/purchases/orders']);
}

export async function approvePurchaseOrderAction(values: Record<string, string>): Promise<Result> {
  const id = values.orderId ?? '';
  return run(() => service.approvePurchaseOrder(id), ['/purchases/orders', `/purchases/orders/${id}`]);
}

export async function closePurchaseOrderAction(values: Record<string, string>): Promise<Result> {
  const id = values.orderId ?? '';
  return run(() => service.closePurchaseOrder(id, values.reason ?? ''), ['/purchases/orders', `/purchases/orders/${id}`]);
}

export async function postGoodsReceiptAction(input: service.GoodsReceiptInput): Promise<Result> {
  return run(() => service.postGoodsReceipt(input), [
    '/purchases/orders', `/purchases/orders/${input.orderId}`, '/inventory/accessories', '/inventory/spares',
  ]);
}

export async function cancelGoodsReceiptAction(values: Record<string, string>): Promise<Result> {
  return run(() => service.cancelGoodsReceipt(values.receiptId ?? '', values.reason ?? ''), [
    '/purchases/orders', `/purchases/orders/${values.orderId ?? ''}`,
  ]);
}

export async function addReceiptLinesToBillAction(
  billId: string,
  lines: readonly { grnLineId: string; quantity: number; unitRate: number }[],
): Promise<Result> {
  return run(() => service.addReceiptLinesToBill(billId, lines), [`/purchases/${billId}`]);
}
