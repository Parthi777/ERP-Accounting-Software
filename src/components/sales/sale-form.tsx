'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { useForm, useWatch } from 'react-hook-form';
import { Loader2, Save } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { createSaleDraftAction } from '@/server/services/sales/sale-actions';

interface Option {
  readonly id: string;
  readonly label: string;
  readonly sub?: string;
}

type FormValues = {
  customer_id: string;
  vehicle_id: string;
  invoice_date: string;
  sales_executive_id: string;
  discount: number;
  notes: string;
};

/**
 * New vehicle sale — spec §19.
 *
 * Deliberately short. The invoice lines are not typed here: they are built from
 * the price version in force on the invoice date, so the figures come from
 * configuration rather than from whatever the cashier remembers. The draft can
 * then be adjusted before submission.
 */
export function SaleForm({
  customers,
  vehicles,
  employees,
  branchName,
  booking,
}: {
  readonly customers: readonly Option[];
  readonly vehicles: readonly Option[];
  readonly employees: readonly Option[];
  readonly branchName: string;
  readonly booking?: { readonly id: string; readonly number: string; readonly customerId: string } | null;
}) {
  const router = useRouter();
  const [formError, setFormError] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  const {
    register,
    handleSubmit,
    control,
  } = useForm<FormValues>({
    defaultValues: {
      customer_id: booking?.customerId ?? '',
      vehicle_id: '',
      invoice_date: new Date().toISOString().slice(0, 10),
      sales_executive_id: '',
      discount: 0,
      notes: '',
    },
  });

  const values = useWatch({ control });

  const onSubmit = handleSubmit((form) => {
    setFormError(null);
    if (!form.customer_id) return setFormError('Choose a customer.');
    if (!form.vehicle_id) return setFormError('Choose a vehicle.');

    startTransition(async () => {
      const result = await createSaleDraftAction({
        customer_id: form.customer_id,
        vehicle_id: form.vehicle_id,
        invoice_date: form.invoice_date,
        booking_id: booking?.id,
        sales_executive_id: form.sales_executive_id || undefined,
        discount: Number(form.discount) || 0,
        notes: form.notes || undefined,
      });

      if (!result.ok) {
        setFormError(result.error ?? 'The invoice could not be drafted.');
        return;
      }
      router.push(`/sales/${result.id}`);
      router.refresh();
    });
  });

  return (
    <form onSubmit={onSubmit} className="space-y-4" noValidate>
      {formError && (
        <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
          {formError}
        </div>
      )}

      {booking && (
        <Panel className="flex items-center gap-3 p-4">
          <span className="rounded-md bg-brand-50 px-2 py-1 text-xs font-medium text-brand-700">
            From booking {booking.number}
          </span>
          <span className="text-sm text-ink-600">
            The booking closes when this invoice is drafted.
          </span>
        </Panel>
      )}

      <Panel className="p-5">
        <h2 className="text-sm font-semibold text-ink-900">Sale</h2>
        <p className="mb-4 text-xs text-ink-500">Invoicing at {branchName}.</p>

        <div className="grid gap-4 sm:grid-cols-2">
          <div className="sm:col-span-2">
            <Label htmlFor="customer_id" className="mb-1.5 block">
              Customer<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <select id="customer_id" className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" {...register('customer_id')}>
              <option value="">Choose a customer</option>
              {customers.map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}
            </select>
          </div>

          <div className="sm:col-span-2">
            <Label htmlFor="vehicle_id" className="mb-1.5 block">
              Vehicle<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <select id="vehicle_id" className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" {...register('vehicle_id')}>
              <option value="">Choose a chassis</option>
              {vehicles.map((v) => (
                <option key={v.id} value={v.id}>{v.label}{v.sub ? ` — ${v.sub}` : ''}</option>
              ))}
            </select>
            <p className="mt-1 text-xs text-ink-400">
              Selecting a vehicle reserves it immediately, so two cashiers cannot invoice the same chassis.
            </p>
          </div>

          <div>
            <Label htmlFor="invoice_date" className="mb-1.5 block">Invoice date</Label>
            <Input id="invoice_date" type="date" {...register('invoice_date')} />
            <p className="mt-1 text-xs text-ink-400">
              The price and tax in force on <em>this</em> date are used, not today&rsquo;s.
            </p>
          </div>

          <div>
            <Label htmlFor="sales_executive_id" className="mb-1.5 block">Sales executive</Label>
            <select id="sales_executive_id" className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" {...register('sales_executive_id')}>
              <option value="">Not assigned</option>
              {employees.map((e) => <option key={e.id} value={e.id}>{e.label}</option>)}
            </select>
          </div>

          <div>
            <Label htmlFor="discount" className="mb-1.5 block">Discount</Label>
            <div className="relative">
              <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-ink-400">₹</span>
              <Input id="discount" type="number" step="0.01" min="0" className="pl-7" {...register('discount', { valueAsNumber: true })} />
            </div>
            <p className="mt-1 text-xs text-ink-400">
              Refused if it exceeds the maximum on the price version.
            </p>
          </div>

          <div className="sm:col-span-2">
            <Label htmlFor="notes" className="mb-1.5 block">Notes</Label>
            <textarea id="notes" rows={2}
              className="w-full rounded-lg border border-ink-200 bg-white px-3 py-2 text-sm shadow-sm"
              {...register('notes')} />
          </div>
        </div>
      </Panel>

      <Panel className="p-4">
        <p className="text-sm text-ink-600">
          The invoice is created as a <strong>draft</strong> with lines built from the price version —
          ex-showroom, insurance, registration, forwarding and GST. Review it, add any fittings, then
          submit it for accounts verification.
        </p>
      </Panel>

      <div className="flex items-center gap-2">
        <Button type="submit" disabled={pending || !values.customer_id || !values.vehicle_id}>
          {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Save aria-hidden />}
          {pending ? 'Drafting…' : 'Draft invoice'}
        </Button>
        <Button variant="secondary" asChild><Link href="/sales">Cancel</Link></Button>
      </div>
    </form>
  );
}
