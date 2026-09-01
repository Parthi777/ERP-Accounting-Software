'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, PackageCheck } from 'lucide-react';

import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { deliverSaleAction } from '@/server/services/sales/sale-actions';

/**
 * Handing the vehicle over — spec §19, the last step of the sale.
 *
 * Who received it is asked for rather than assumed. The delivery note is the
 * document a dispute turns on months later, and "the customer" is not an answer
 * when the person who collected the vehicle was their driver.
 */
export function DeliverAction({
  saleId,
  invoiceNumber,
  customerName,
}: {
  readonly saleId: string;
  readonly invoiceNumber: string;
  readonly customerName: string;
}) {
  const router = useRouter();
  const [open, setOpen] = React.useState(false);
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [receivedBy, setReceivedBy] = React.useState('');
  const [odometer, setOdometer] = React.useState('');
  const [remarks, setRemarks] = React.useState('');

  const submit = () => {
    setError(null);
    startTransition(async () => {
      const result = await deliverSaleAction(
        saleId,
        receivedBy.trim() || undefined,
        odometer ? Number(odometer) : undefined,
        remarks.trim() || undefined,
      );
      if (!result.ok) {
        setError(result.error ?? 'The delivery could not be recorded.');
        return;
      }
      setOpen(false);
      setReceivedBy('');
      setOdometer('');
      setRemarks('');
      router.refresh();
    });
  };

  return (
    <>
      <div className="flex justify-end">
        <Button size="sm" variant="secondary" onClick={() => setOpen(true)}>
          <PackageCheck aria-hidden />
          Deliver
        </Button>
      </div>

      {open && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
          role="dialog"
          aria-modal="true"
          onClick={() => setOpen(false)}
        >
          <div className="glass-strong w-full max-w-md rounded-2xl p-6" onClick={(e) => e.stopPropagation()}>
            <h2 className="text-sm font-semibold text-ink-900">Record delivery for {invoiceNumber}?</h2>
            <p className="mt-1 text-sm text-ink-600">
              This issues a delivery note and closes the sale. The vehicle moves to delivered, which
              is a terminal state — it cannot be returned to stock afterwards.
            </p>

            {error && (
              <div role="alert" className="mt-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
                {error}
              </div>
            )}

            <div className="mt-4 space-y-3">
              <div>
                <Label htmlFor="received-by" className="mb-1.5 block">Received by</Label>
                <Input
                  id="received-by"
                  value={receivedBy}
                  onChange={(e) => setReceivedBy(e.target.value)}
                  placeholder={customerName}
                />
                <p className="mt-1 text-xs text-ink-400">
                  The person actually collecting, if not {customerName}.
                </p>
              </div>

              <div>
                <Label htmlFor="odometer" className="mb-1.5 block">Odometer</Label>
                <Input
                  id="odometer"
                  type="number"
                  step="0.1"
                  min="0"
                  value={odometer}
                  onChange={(e) => setOdometer(e.target.value)}
                  placeholder="km at handover"
                />
              </div>

              <div>
                <Label htmlFor="delivery-remarks" className="mb-1.5 block">Remarks</Label>
                <Input
                  id="delivery-remarks"
                  value={remarks}
                  onChange={(e) => setRemarks(e.target.value)}
                  placeholder="e.g. Documents and both keys handed over"
                />
              </div>
            </div>

            <div className="mt-4 flex justify-end gap-2">
              <Button variant="secondary" size="sm" onClick={() => setOpen(false)} disabled={pending}>
                Back
              </Button>
              <Button size="sm" disabled={pending} onClick={submit}>
                {pending && <Loader2 className="animate-spin" aria-hidden />}
                Record delivery
              </Button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
