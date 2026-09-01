'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { ArrowLeftRight, Loader2 } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { transferStockAction } from '@/server/services/inventory/inventory-actions';
import type { StockLotRow } from '@/server/services/inventory/inventory-service';

interface Branch {
  readonly id: string;
  readonly name: string;
}

/** Identifies one lot: an item at a branch, in one source. */
function lotKey(lot: StockLotRow): string {
  return `${lot.itemId}|${lot.branchId}|${lot.source}`;
}

/**
 * Moving accessory or spare stock between branches — spec §35, §60.16.
 *
 * The transfer starts from a lot that exists rather than from an item, because
 * LOCAL and COMPANY stock move separately and arrive as what they were. Picking
 * the lot first is also what makes the available quantity knowable before the
 * quantity is typed.
 */
export function StockTransferForm({
  lots,
  branches,
}: {
  readonly lots: readonly StockLotRow[];
  readonly branches: readonly Branch[];
}) {
  const router = useRouter();
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);
  const [selectedLot, setSelectedLot] = React.useState('');
  const [toBranchId, setToBranchId] = React.useState('');
  const [quantity, setQuantity] = React.useState('');
  const [remarks, setRemarks] = React.useState('');

  const lot = lots.find((l) => lotKey(l) === selectedLot) ?? null;
  const destinations = branches.filter((b) => b.id !== lot?.branchId);
  const entered = Number(quantity) || 0;

  // Changing the lot can invalidate a destination already chosen — the new lot
  // may sit at the very branch that was picked to receive the last one.
  const chooseLot = (key: string) => {
    setSelectedLot(key);
    setToBranchId('');
    setQuantity('');
  };

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);
    setNotice(null);

    if (!lot) return setError('Choose the stock to move.');
    if (!toBranchId) return setError('Choose the branch to move it to.');
    if (!(entered > 0)) return setError('Enter a quantity greater than zero.');
    if (entered > lot.quantity) {
      return setError(`Only ${lot.quantity} in ${lot.source.toLowerCase()} stock at ${lot.branchName}.`);
    }

    startTransition(async () => {
      const result = await transferStockAction({
        itemId: lot.itemId,
        fromBranchId: lot.branchId,
        toBranchId,
        quantity: entered,
        source: lot.source,
        remarks: remarks.trim() || null,
      });

      if (!result.ok) {
        setError(result.error ?? 'The transfer could not be recorded.');
        return;
      }
      setNotice(result.message ?? 'Transferred.');
      setSelectedLot('');
      setToBranchId('');
      setQuantity('');
      setRemarks('');
      router.refresh();
    });
  };

  if (lots.length === 0) {
    return (
      <Panel className="p-5">
        <h2 className="text-sm font-semibold text-ink-900">Transfer stock</h2>
        <p className="mt-1 text-xs text-ink-500">
          There is no stock at your branches to transfer.
        </p>
      </Panel>
    );
  }

  return (
    <Panel className="p-5">
      <h2 className="flex items-center gap-2 text-sm font-semibold text-ink-900">
        <ArrowLeftRight className="text-brand-600" aria-hidden />
        Transfer stock
      </h2>
      <p className="mb-4 text-xs text-ink-500">
        Local stock arrives as local stock and company stock as company stock. Both branches record
        the movement in their ledger.
      </p>

      <form onSubmit={submit} className="space-y-4" noValidate>
        {error && (
          <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
            {error}
          </div>
        )}
        {notice && (
          <div role="status" className="rounded-lg border border-positive-200 bg-positive-50 px-3 py-2 text-sm text-positive-700">
            {notice}
          </div>
        )}

        <div className="grid gap-4 sm:grid-cols-2">
          <div className="sm:col-span-2">
            <Label htmlFor="lot" className="mb-1.5 block">
              Stock to move<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <select
              id="lot"
              value={selectedLot}
              onChange={(e) => chooseLot(e.target.value)}
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            >
              <option value="">Choose an item and lot</option>
              {lots.map((l) => (
                <option key={lotKey(l)} value={lotKey(l)}>
                  {l.itemCode} · {l.itemName} · {l.source} at {l.branchName} · {l.quantity} on hand
                </option>
              ))}
            </select>
          </div>

          <div>
            <Label htmlFor="to-branch" className="mb-1.5 block">
              Move to<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <select
              id="to-branch"
              value={toBranchId}
              onChange={(e) => setToBranchId(e.target.value)}
              disabled={!lot}
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm disabled:bg-ink-50 disabled:text-ink-400"
            >
              <option value="">{lot ? 'Choose a branch' : 'Choose the stock first'}</option>
              {destinations.map((b) => (
                <option key={b.id} value={b.id}>{b.name}</option>
              ))}
            </select>
          </div>

          <div>
            <Label htmlFor="quantity" className="mb-1.5 block">
              Quantity<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <Input
              id="quantity"
              type="number"
              step="0.001"
              min="0"
              max={lot?.quantity}
              value={quantity}
              onChange={(e) => setQuantity(e.target.value)}
              disabled={!lot}
            />
            {lot && (
              <p className="mt-1 text-xs text-ink-400">
                {lot.quantity} available · {lot.quantity - entered >= 0 ? `${lot.quantity - entered} would remain` : 'more than is on hand'}
              </p>
            )}
          </div>

          <div className="sm:col-span-2">
            <Label htmlFor="remarks" className="mb-1.5 block">Remarks</Label>
            <Input
              id="remarks"
              value={remarks}
              onChange={(e) => setRemarks(e.target.value)}
              placeholder="e.g. Branch indent 42"
            />
          </div>
        </div>

        <Button type="submit" size="sm" disabled={pending}>
          {pending ? <Loader2 className="animate-spin" aria-hidden /> : <ArrowLeftRight aria-hidden />}
          Transfer
        </Button>
      </form>
    </Panel>
  );
}
