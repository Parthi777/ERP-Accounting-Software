'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, Plus } from 'lucide-react';

import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/input';
import { createCounterInvoiceAction } from '@/server/services/service/service-actions';

/**
 * Starting an over-the-counter sale — spec §33.
 *
 * The customer is optional unless the dealer has configured otherwise, so the
 * dialog offers the picker without demanding it: someone buying a helmet for
 * cash is not worth a customer record, and forcing one produces junk data.
 */
export function CounterSaleStart({
  customers,
  requireCustomer,
}: {
  readonly customers: readonly { id: string; label: string }[];
  readonly requireCustomer: boolean;
}) {
  const router = useRouter();
  const [open, setOpen] = React.useState(false);
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [customerId, setCustomerId] = React.useState('');

  const submit = () => {
    setError(null);
    startTransition(async () => {
      const result = await createCounterInvoiceAction(customerId || null);
      if (!result.ok || !result.id) {
        setError(result.error ?? 'The counter sale could not be started.');
        return;
      }
      setOpen(false);
      setCustomerId('');
      router.push(`/inventory/counter-sales/${result.id}`);
    });
  };

  return (
    <>
      <Button size="sm" onClick={() => setOpen(true)}>
        <Plus aria-hidden />
        New counter sale
      </Button>

      {open && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
          role="dialog" aria-modal="true" onClick={() => setOpen(false)}
        >
          <div className="glass-strong w-full max-w-md rounded-2xl p-6" onClick={(e) => e.stopPropagation()}>
            <h2 className="text-sm font-semibold text-ink-900">Start a counter sale</h2>
            <p className="mt-1 text-sm text-ink-600">
              This opens a draft invoice. Add the items on the next screen, then post it — stock is
              relieved and the accounting is written at that point, not before.
            </p>

            {error && (
              <div role="alert" className="mt-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
                {error}
              </div>
            )}

            <div className="mt-4">
              <Label htmlFor="counter-customer" className="mb-1.5 block">
                Customer{requireCustomer && <span className="ml-0.5 text-danger-600">*</span>}
              </Label>
              <select
                id="counter-customer"
                value={customerId}
                onChange={(e) => setCustomerId(e.target.value)}
                className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
              >
                <option value="">
                  {requireCustomer ? 'Choose a customer' : 'Walk-in — no customer'}
                </option>
                {customers.map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}
              </select>
              <p className="mt-1 text-xs text-ink-400">
                {requireCustomer
                  ? 'This dealer requires a customer on every counter sale.'
                  : 'Optional. Name one when the sale should appear on their history.'}
              </p>
            </div>

            <div className="mt-4 flex justify-end gap-2">
              <Button variant="secondary" size="sm" onClick={() => setOpen(false)} disabled={pending}>
                Back
              </Button>
              <Button
                size="sm"
                disabled={pending || (requireCustomer && !customerId)}
                onClick={submit}
              >
                {pending && <Loader2 className="animate-spin" aria-hidden />}
                Start sale
              </Button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
