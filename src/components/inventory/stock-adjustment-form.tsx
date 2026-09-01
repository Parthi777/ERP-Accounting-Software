'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, SlidersHorizontal } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { adjustStockAction } from '@/server/services/inventory/inventory-actions';
import type { StockLotRow } from '@/server/services/inventory/inventory-service';

function lotKey(lot: StockLotRow): string {
  return `${lot.itemId}|${lot.branchId}|${lot.source}`;
}

/**
 * Correcting a lot against a physical count — spec §34, §60.22.
 *
 * The form asks for the counted quantity rather than the difference, because
 * that is what the person holding the stock actually knows. The movement posted
 * is the difference, which keeps the ledger a record of changes rather than of
 * overwrites.
 *
 * The reason is required and travels onto the ledger entry. An adjustment
 * nobody can explain later is indistinguishable from shrinkage.
 */
export function StockAdjustmentForm({ lots }: { readonly lots: readonly StockLotRow[] }) {
  const router = useRouter();
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);
  const [selectedLot, setSelectedLot] = React.useState('');
  const [counted, setCounted] = React.useState('');
  const [reason, setReason] = React.useState('');

  const lot = lots.find((l) => lotKey(l) === selectedLot) ?? null;
  const countedValue = counted === '' ? null : Number(counted);
  const difference =
    lot && countedValue !== null && Number.isFinite(countedValue)
      ? Number((countedValue - lot.quantity).toFixed(3))
      : null;

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);
    setNotice(null);

    if (!lot) return setError('Choose the stock to adjust.');
    if (countedValue === null || !Number.isFinite(countedValue)) {
      return setError('Enter the quantity you counted.');
    }
    if (countedValue < 0) return setError('A counted quantity cannot be negative.');
    if (!difference) return setError('The count matches the system. There is nothing to adjust.');
    if (!reason.trim()) return setError('Give a reason. It is recorded on the ledger entry.');

    startTransition(async () => {
      const result = await adjustStockAction({
        itemId: lot.itemId,
        branchId: lot.branchId,
        source: lot.source,
        quantity: difference,
        reason: reason.trim(),
      });

      if (!result.ok) {
        setError(result.error ?? 'The adjustment could not be recorded.');
        return;
      }
      setNotice(result.message ?? 'Adjusted.');
      setSelectedLot('');
      setCounted('');
      setReason('');
      router.refresh();
    });
  };

  if (lots.length === 0) {
    return (
      <Panel className="p-5">
        <h2 className="text-sm font-semibold text-ink-900">Adjust stock</h2>
        <p className="mt-1 text-xs text-ink-500">There is no stock at your branches to adjust.</p>
      </Panel>
    );
  }

  return (
    <Panel className="p-5">
      <h2 className="flex items-center gap-2 text-sm font-semibold text-ink-900">
        <SlidersHorizontal className="text-brand-600" aria-hidden />
        Adjust stock
      </h2>
      <p className="mb-4 text-xs text-ink-500">
        Enter what you counted. The difference is posted as a movement with your reason attached —
        the quantity is never silently overwritten.
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
              Stock to adjust<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <select
              id="lot"
              value={selectedLot}
              onChange={(e) => setSelectedLot(e.target.value)}
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
            <Label htmlFor="counted" className="mb-1.5 block">
              Counted quantity<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <Input
              id="counted"
              type="number"
              step="0.001"
              min="0"
              value={counted}
              onChange={(e) => setCounted(e.target.value)}
              disabled={!lot}
            />
            {lot && (
              <p className="mt-1 text-xs text-ink-400">System shows {lot.quantity}.</p>
            )}
          </div>

          <div>
            <Label className="mb-1.5 block">Adjustment</Label>
            <div className="flex h-9 items-center rounded-lg border border-ink-200 bg-ink-50 px-3 text-sm">
              {difference === null ? (
                <span className="text-ink-400">—</span>
              ) : difference === 0 ? (
                <span className="text-ink-500">No change</span>
              ) : (
                <span className={difference > 0 ? 'font-medium text-positive-700' : 'font-medium text-danger-700'}>
                  {difference > 0 ? '+' : ''}{difference}
                </span>
              )}
            </div>
          </div>

          <div className="sm:col-span-2">
            <Label htmlFor="reason" className="mb-1.5 block">
              Reason<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <Input
              id="reason"
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              placeholder="e.g. Damaged in storage, recount after audit"
              disabled={!lot}
            />
          </div>
        </div>

        <Button type="submit" size="sm" disabled={pending}>
          {pending ? <Loader2 className="animate-spin" aria-hidden /> : <SlidersHorizontal aria-hidden />}
          Post adjustment
        </Button>
      </form>
    </Panel>
  );
}
