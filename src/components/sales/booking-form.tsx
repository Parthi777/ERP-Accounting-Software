'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { useForm, useWatch } from 'react-hook-form';
import { Loader2, Save } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { FieldError, Input, Label } from '@/components/ui/input';
import { formatINR, fromRupees } from '@/lib/money';
import { createBookingAction } from '@/server/services/sales/booking-actions';

interface Option {
  readonly id: string;
  readonly label: string;
  readonly modelId?: string;
  readonly sub?: string;
}

type FormValues = {
  customer_id: string;
  model_id: string;
  variant_id: string;
  vehicle_id: string;
  booking_amount: number;
  advance_amount: number;
  payment_mode: string;
  reference: string;
  expected_delivery: string;
  sales_executive_id: string;
  notes: string;
};

/**
 * New booking — spec §18.
 *
 * The cashier's flow: customer → model → booking amount → advance → receipt.
 * The balance is shown live because it is the number the customer asks about,
 * and because an advance larger than the booking is a data-entry slip the
 * database will reject anyway.
 */
export function BookingForm({
  customers,
  models,
  variants,
  vehicles,
  employees,
  branchName,
}: {
  readonly customers: readonly Option[];
  readonly models: readonly Option[];
  readonly variants: readonly Option[];
  readonly vehicles: readonly Option[];
  readonly employees: readonly Option[];
  readonly branchName: string;
}) {
  const router = useRouter();
  const [formError, setFormError] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  const {
    register,
    handleSubmit,
    control,
    formState: { errors },
  } = useForm<FormValues>({
    defaultValues: {
      customer_id: '', model_id: '', variant_id: '', vehicle_id: '',
      booking_amount: 0, advance_amount: 0, payment_mode: 'CASH',
      reference: '', expected_delivery: '', sales_executive_id: '', notes: '',
    },
  });

  const values = useWatch({ control });
  const num = (v: unknown) => Number(v ?? 0) || 0;
  const balance = num(values.booking_amount) - num(values.advance_amount);
  const selectedModel = values.model_id;

  // Only variants and in-stock vehicles of the chosen model are offered.
  const availableVariants = variants.filter((v) => !selectedModel || v.modelId === selectedModel);
  const availableVehicles = vehicles.filter((v) => !selectedModel || v.modelId === selectedModel);

  const onSubmit = handleSubmit((form) => {
    setFormError(null);

    if (!form.customer_id) return setFormError('Choose a customer.');
    if (!form.model_id) return setFormError('Choose a model.');
    if (num(form.advance_amount) <= 0) return setFormError('Enter the advance amount received.');
    if (num(form.booking_amount) > 0 && num(form.advance_amount) > num(form.booking_amount)) {
      return setFormError('The advance cannot exceed the booking amount.');
    }

    startTransition(async () => {
      const result = await createBookingAction({
        customer_id: form.customer_id,
        model_id: form.model_id,
        variant_id: form.variant_id || undefined,
        vehicle_id: form.vehicle_id || undefined,
        booking_amount: num(form.booking_amount),
        advance_amount: num(form.advance_amount),
        payment_mode: form.payment_mode,
        reference: form.reference || undefined,
        expected_delivery: form.expected_delivery || undefined,
        sales_executive_id: form.sales_executive_id || undefined,
        notes: form.notes || undefined,
      });

      if (!result.ok) {
        setFormError(result.error ?? 'The booking could not be created.');
        return;
      }
      router.push(`/bookings/${result.id}`);
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

      <Panel className="p-5">
        <h2 className="text-sm font-semibold text-ink-900">Customer and vehicle</h2>
        <p className="mb-4 text-xs text-ink-500">Booking at {branchName}.</p>

        <div className="grid gap-4 sm:grid-cols-2">
          <div className="sm:col-span-2">
            <Label htmlFor="customer_id" className="mb-1.5 block">
              Customer<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <select id="customer_id" className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" {...register('customer_id')}>
              <option value="">Choose a customer</option>
              {customers.map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}
            </select>
            <p className="mt-1 text-xs text-ink-400">
              Not listed?{' '}
              <Link href="/customers/new" className="text-brand-600 hover:underline">Create the customer first</Link>.
            </p>
          </div>

          <div>
            <Label htmlFor="model_id" className="mb-1.5 block">
              Model<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <select id="model_id" className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" {...register('model_id')}>
              <option value="">Choose a model</option>
              {models.map((m) => <option key={m.id} value={m.id}>{m.label}</option>)}
            </select>
          </div>

          <div>
            <Label htmlFor="variant_id" className="mb-1.5 block">Variant</Label>
            <select id="variant_id" className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" {...register('variant_id')}>
              <option value="">Not specified</option>
              {availableVariants.map((v) => <option key={v.id} value={v.id}>{v.label}</option>)}
            </select>
          </div>

          <div className="sm:col-span-2">
            <Label htmlFor="vehicle_id" className="mb-1.5 block">Reserve a specific chassis</Label>
            <select id="vehicle_id" className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" {...register('vehicle_id')}>
              <option value="">No — book against the model</option>
              {availableVehicles.map((v) => (
                <option key={v.id} value={v.id}>{v.label}{v.sub ? ` · ${v.sub}` : ''}</option>
              ))}
            </select>
            <p className="mt-1 text-xs text-ink-400">
              Reserving takes that vehicle out of available stock immediately.
            </p>
          </div>
        </div>
      </Panel>

      <Panel className="p-5">
        <h2 className="text-sm font-semibold text-ink-900">Amount and advance</h2>
        <p className="mb-4 text-xs text-ink-500">
          The advance posts to Customer Advances. No revenue is recognised until the sale is raised.
        </p>

        <div className="grid gap-4 sm:grid-cols-2">
          <div>
            <Label htmlFor="booking_amount" className="mb-1.5 block">Booking value (on-road)</Label>
            <div className="relative">
              <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-ink-400">₹</span>
              <Input id="booking_amount" type="number" step="0.01" min="0" className="pl-7" {...register('booking_amount', { valueAsNumber: true })} />
            </div>
          </div>

          <div>
            <Label htmlFor="advance_amount" className="mb-1.5 block">
              Advance received<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <div className="relative">
              <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-ink-400">₹</span>
              <Input id="advance_amount" type="number" step="0.01" min="0" className="pl-7"
                aria-invalid={Boolean(errors.advance_amount)}
                {...register('advance_amount', { valueAsNumber: true })} />
            </div>
            <FieldError>{errors.advance_amount?.message}</FieldError>
          </div>

          <div>
            <Label htmlFor="payment_mode" className="mb-1.5 block">Payment mode</Label>
            <select id="payment_mode" className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" {...register('payment_mode')}>
              {['CASH', 'UPI', 'CARD', 'NEFT', 'RTGS', 'IMPS', 'CHEQUE', 'DD'].map((m) => (
                <option key={m} value={m}>{m}</option>
              ))}
            </select>
          </div>

          <div>
            <Label htmlFor="reference" className="mb-1.5 block">Reference</Label>
            <Input id="reference" placeholder="UPI ID, cheque number…" {...register('reference')} />
          </div>
        </div>

        <div className="mt-5 flex items-center justify-between rounded-lg border border-brand-200 bg-brand-50 px-4 py-3">
          <span className="text-sm font-medium text-brand-800">Balance after this advance</span>
          <span className={`numeric text-lg font-bold ${balance < 0 ? 'text-danger-700' : 'text-brand-900'}`}>
            {formatINR(fromRupees(balance))}
          </span>
        </div>
      </Panel>

      <Panel className="p-5">
        <h2 className="mb-4 text-sm font-semibold text-ink-900">Other details</h2>
        <div className="grid gap-4 sm:grid-cols-2">
          <div>
            <Label htmlFor="expected_delivery" className="mb-1.5 block">Expected delivery</Label>
            <Input id="expected_delivery" type="date" {...register('expected_delivery')} />
          </div>
          <div>
            <Label htmlFor="sales_executive_id" className="mb-1.5 block">Sales executive</Label>
            <select id="sales_executive_id" className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" {...register('sales_executive_id')}>
              <option value="">Not assigned</option>
              {employees.map((e) => <option key={e.id} value={e.id}>{e.label}</option>)}
            </select>
          </div>
          <div className="sm:col-span-2">
            <Label htmlFor="notes" className="mb-1.5 block">Notes</Label>
            <textarea id="notes" rows={2}
              className="w-full rounded-lg border border-ink-200 bg-white px-3 py-2 text-sm shadow-sm"
              {...register('notes')} />
          </div>
        </div>
      </Panel>

      <div className="flex items-center gap-2">
        <Button type="submit" disabled={pending}>
          {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Save aria-hidden />}
          {pending ? 'Creating…' : 'Create booking and receipt'}
        </Button>
        <Button variant="secondary" asChild><Link href="/bookings">Cancel</Link></Button>
      </div>
    </form>
  );
}
