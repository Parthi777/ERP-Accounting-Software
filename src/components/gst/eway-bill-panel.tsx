'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, Truck } from 'lucide-react';

import { Panel, PanelContent, PanelHeader, PanelTitle } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Input, Label } from '@/components/ui/input';
import { formatINR } from '@/lib/money';
import { formatDateTime } from '@/lib/format';
import { raiseEwayBillAction, fileEwayBillAction } from '@/server/services/gst/gst-actions';
import type { EwayRequirement } from '@/server/services/gst/gst-service';

const MODES = ['ROAD', 'RAIL', 'AIR', 'SHIP'] as const;

const STATUS_TONE: Record<string, 'positive' | 'warning' | 'danger' | 'neutral'> = {
  GENERATED: 'positive',
  PENDING: 'warning',
  FAILED: 'danger',
  CANCELLED: 'neutral',
  EXPIRED: 'danger',
};

/**
 * The e-way bill for a sale — spec §40.
 *
 * On the sale screen rather than only in the GST section, because this is the
 * one piece of GST paperwork that decides whether a vehicle may leave the
 * premises. Goods above the notified value may not move without it, and a
 * vehicle stopped without one is detained along with its consignment.
 *
 * So the panel answers the question in the order it gets asked: is one needed,
 * has one been raised, and if not — raise it now.
 */
export function EwayBillPanel({
  saleId,
  requirement,
  canFile,
}: {
  readonly saleId: string;
  readonly requirement: EwayRequirement;
  readonly canFile: boolean;
}) {
  const router = useRouter();
  const [open, setOpen] = React.useState(false);
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);

  const [mode, setMode] = React.useState<(typeof MODES)[number]>('ROAD');
  const [vehicle, setVehicle] = React.useState('');
  const [distance, setDistance] = React.useState('');
  const [transporter, setTransporter] = React.useState('');

  const existing = requirement.existing;

  const raise = () => {
    setError(null);
    setNotice(null);
    startTransition(async () => {
      const result = await raiseEwayBillAction({
        saleId,
        transportMode: mode,
        vehicleNumber: vehicle.trim() || null,
        distanceKm: Number(distance) || null,
        transporterName: transporter.trim() || null,
      });
      if (!result.ok) {
        setError(result.error ?? 'The e-way bill could not be raised.');
        // Still refresh: a failed attempt is recorded and worth seeing.
        router.refresh();
        return;
      }
      setNotice(result.message ?? 'Raised.');
      setOpen(false);
      router.refresh();
    });
  };

  const retry = () => {
    if (!existing) return;
    setError(null);
    setNotice(null);
    startTransition(async () => {
      const result = await fileEwayBillAction(existing.id);
      if (!result.ok) setError(result.error ?? 'Filing failed.');
      else setNotice(result.message ?? 'Filed.');
      router.refresh();
    });
  };

  return (
    <Panel>
      <PanelHeader>
        <div className="flex items-center gap-2">
          <PanelTitle>E-way bill</PanelTitle>
          {existing ? (
            <Badge variant={STATUS_TONE[existing.status] ?? 'neutral'}>{existing.status}</Badge>
          ) : requirement.required ? (
            <Badge variant="warning">Required</Badge>
          ) : (
            <Badge variant="neutral">Not required</Badge>
          )}
        </div>
      </PanelHeader>

      <PanelContent>
        {error && (
          <div role="alert" className="mb-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
            {error}
          </div>
        )}
        {notice && (
          <div className="mb-3 rounded-lg border border-positive-200 bg-positive-50 px-3 py-2 text-sm text-positive-700">
            {notice}
          </div>
        )}

        {/* The reasoning, not just the verdict: "not required" is a claim the
            dealer is relying on, and they should be able to check it. */}
        <p className="text-sm text-ink-600">
          Consignment <span className="numeric font-medium">{formatINR(requirement.consignmentValue)}</span>
          {' · '}
          {requirement.interstate ? 'inter-state' : 'within the state'}, threshold{' '}
          <span className="numeric">{formatINR(requirement.threshold)}</span>.
        </p>

        {existing?.status === 'GENERATED' && (
          <div className="mt-3 rounded-lg border border-positive-200 bg-positive-50 p-3">
            <p className="font-mono text-sm font-semibold text-positive-800">{existing.number}</p>
            {existing.validUntil && (
              <p className="mt-0.5 text-xs text-positive-700">
                Valid until {formatDateTime(existing.validUntil)}
              </p>
            )}
          </div>
        )}

        {existing && existing.status !== 'GENERATED' && (
          <div className="mt-3 rounded-lg border border-warning-200 bg-warning-50 p-3">
            <p className="text-sm text-warning-900">
              {existing.error ?? 'Raised but not yet filed with the portal.'}
            </p>
            <p className="mt-1 text-xs text-warning-800">
              The sale is unaffected. The goods may not move until the bill carries a number.
            </p>
            {canFile && (
              <Button size="sm" variant="secondary" className="mt-2" onClick={retry} disabled={pending}>
                {pending && <Loader2 className="animate-spin" aria-hidden />}
                Try filing again
              </Button>
            )}
          </div>
        )}

        {!existing && requirement.required && !open && canFile && (
          <Button size="sm" className="mt-3" onClick={() => setOpen(true)}>
            <Truck aria-hidden />
            Raise e-way bill
          </Button>
        )}

        {!existing && !requirement.required && (
          <p className="mt-2 text-xs text-ink-500">
            Below the threshold, so Rule 138 does not require one for this consignment.
          </p>
        )}

        {open && (
          <div className="mt-3 space-y-3 rounded-lg border border-ink-200 p-3">
            <div className="grid gap-3 sm:grid-cols-2">
              <div>
                <Label htmlFor="ew-mode" className="mb-1.5 block">Mode</Label>
                <select
                  id="ew-mode" value={mode}
                  onChange={(e) => setMode(e.target.value as (typeof MODES)[number])}
                  className="h-9 w-full field px-3 text-sm"
                >
                  {MODES.map((m) => <option key={m} value={m}>{m}</option>)}
                </select>
              </div>
              <div>
                <Label htmlFor="ew-vehicle" className="mb-1.5 block">
                  Vehicle number {mode === 'ROAD' && <span className="text-danger-600">*</span>}
                </Label>
                <Input
                  id="ew-vehicle" value={vehicle} placeholder="TN 37 AB 1234"
                  onChange={(e) => setVehicle(e.target.value.toUpperCase())}
                />
              </div>
              <div>
                <Label htmlFor="ew-distance" className="mb-1.5 block">Distance (km)</Label>
                <Input
                  id="ew-distance" type="number" min="0" value={distance}
                  onChange={(e) => setDistance(e.target.value)}
                />
                <p className="mt-1 text-[11px] text-ink-500">
                  Sets how long the bill lasts — one day per 200km.
                </p>
              </div>
              <div>
                <Label htmlFor="ew-transporter" className="mb-1.5 block">Transporter (optional)</Label>
                <Input
                  id="ew-transporter" value={transporter}
                  onChange={(e) => setTransporter(e.target.value)}
                />
              </div>
            </div>

            <div className="flex justify-end gap-2">
              <Button variant="secondary" size="sm" onClick={() => setOpen(false)} disabled={pending}>
                Cancel
              </Button>
              <Button size="sm" onClick={raise} disabled={pending || (mode === 'ROAD' && !vehicle.trim())}>
                {pending && <Loader2 className="animate-spin" aria-hidden />}
                Raise and file
              </Button>
            </div>
          </div>
        )}
      </PanelContent>
    </Panel>
  );
}
