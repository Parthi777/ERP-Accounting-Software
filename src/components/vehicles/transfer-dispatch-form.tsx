'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, Truck } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { dispatchTransferAction } from '@/server/services/vehicles/transfer-actions';
import type { TransferableVehicle } from '@/server/services/vehicles/transfer-service';

interface Branch {
  readonly id: string;
  readonly name: string;
}

/**
 * Sending a chassis to another branch — spec §35.
 *
 * The destination list excludes the branch the chosen vehicle is standing at,
 * because a transfer to itself is the one mistake this form can prevent
 * outright rather than reporting after the fact.
 */
export function TransferDispatchForm({
  vehicles,
  branches,
}: {
  readonly vehicles: readonly TransferableVehicle[];
  readonly branches: readonly Branch[];
}) {
  const router = useRouter();
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);
  const [vehicleId, setVehicleId] = React.useState('');
  const [toBranchId, setToBranchId] = React.useState('');
  const [remarks, setRemarks] = React.useState('');

  const selected = vehicles.find((v) => v.id === vehicleId) ?? null;
  const destinations = branches.filter((b) => b.id !== selected?.branchId);

  // Changing the vehicle can invalidate a destination already chosen — a branch
  // that was valid for the last vehicle may be where this one already stands.
  const chooseVehicle = (id: string) => {
    setVehicleId(id);
    setToBranchId('');
  };

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);
    setNotice(null);

    if (!vehicleId) return setError('Choose the vehicle to send.');
    if (!toBranchId) return setError('Choose the branch to send it to.');

    startTransition(async () => {
      const result = await dispatchTransferAction({
        vehicleId,
        toBranchId,
        remarks: remarks.trim() || null,
      });

      if (!result.ok) {
        setError(result.error ?? 'The transfer could not be dispatched.');
        return;
      }
      setNotice(result.message ?? 'Dispatched.');
      setVehicleId('');
      setToBranchId('');
      setRemarks('');
      router.refresh();
    });
  };

  if (vehicles.length === 0) {
    return (
      <Panel className="p-5">
        <h2 className="text-sm font-semibold text-ink-900">Dispatch a vehicle</h2>
        <p className="mt-1 text-xs text-ink-500">
          No vehicles are in stock at your branches. Only a vehicle in stock can be transferred — a
          booked or sold unit stays where it is.
        </p>
      </Panel>
    );
  }

  return (
    <Panel className="p-5">
      <h2 className="flex items-center gap-2 text-sm font-semibold text-ink-900">
        <Truck className="text-brand-600" aria-hidden />
        Dispatch a vehicle
      </h2>
      <p className="mb-4 text-xs text-ink-500">
        The vehicle leaves stock immediately and is in transit until the destination receives it, so
        neither branch can sell it on the way.
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
            <Label htmlFor="vehicle" className="mb-1.5 block">
              Vehicle<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <select
              id="vehicle"
              value={vehicleId}
              onChange={(e) => chooseVehicle(e.target.value)}
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            >
              <option value="">Choose a vehicle in stock</option>
              {vehicles.map((v) => (
                <option key={v.id} value={v.id}>
                  {v.chassisNo} · {v.modelLabel}
                  {v.colour ? ` · ${v.colour}` : ''} · at {v.branchName}
                </option>
              ))}
            </select>
          </div>

          <div>
            <Label htmlFor="to-branch" className="mb-1.5 block">
              Send to<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <select
              id="to-branch"
              value={toBranchId}
              onChange={(e) => setToBranchId(e.target.value)}
              disabled={!selected}
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm disabled:bg-ink-50 disabled:text-ink-400"
            >
              <option value="">{selected ? 'Choose a branch' : 'Choose a vehicle first'}</option>
              {destinations.map((b) => (
                <option key={b.id} value={b.id}>{b.name}</option>
              ))}
            </select>
            {selected && (
              <p className="mt-1 text-xs text-ink-400">Currently at {selected.branchName}.</p>
            )}
          </div>

          <div>
            <Label htmlFor="remarks" className="mb-1.5 block">Remarks</Label>
            <Input
              id="remarks"
              value={remarks}
              onChange={(e) => setRemarks(e.target.value)}
              placeholder="e.g. Stock rebalancing, lorry TN01AA1234"
            />
          </div>
        </div>

        <Button type="submit" size="sm" disabled={pending}>
          {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Truck aria-hidden />}
          Dispatch
        </Button>
      </form>
    </Panel>
  );
}
