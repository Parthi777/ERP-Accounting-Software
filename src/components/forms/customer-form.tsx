'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { useForm, useWatch } from 'react-hook-form';
import { Loader2, Save } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { FieldError, Input, Label } from '@/components/ui/input';
import { customerSchema, type CustomerInput } from '@/lib/validation/customer';
import { createCustomerAction, updateCustomerAction } from '@/server/services/customers/actions';

/** Indian states with their GST state codes — the GSTIN's first two digits. */
const STATES: readonly { readonly code: string; readonly name: string }[] = [
  { code: '33', name: 'Tamil Nadu' },
  { code: '29', name: 'Karnataka' },
  { code: '32', name: 'Kerala' },
  { code: '36', name: 'Telangana' },
  { code: '37', name: 'Andhra Pradesh' },
  { code: '27', name: 'Maharashtra' },
  { code: '24', name: 'Gujarat' },
  { code: '07', name: 'Delhi' },
  { code: '09', name: 'Uttar Pradesh' },
  { code: '19', name: 'West Bengal' },
  { code: '08', name: 'Rajasthan' },
  { code: '23', name: 'Madhya Pradesh' },
  { code: '03', name: 'Punjab' },
  { code: '06', name: 'Haryana' },
  { code: '10', name: 'Bihar' },
  { code: '21', name: 'Odisha' },
];

export interface CustomerFormProps {
  readonly mode: 'create' | 'edit';
  readonly customerId?: string;
  readonly customerCode?: string;
  readonly branches: readonly { readonly id: string; readonly name: string }[];
  readonly defaultValues?: Partial<CustomerInput>;
}

export function CustomerForm({
  mode,
  customerId,
  customerCode,
  branches,
  defaultValues,
}: CustomerFormProps) {
  const router = useRouter();
  const [formError, setFormError] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  const {
    register,
    handleSubmit,
    setError,
    control,
    setValue,
    formState: { errors },
  } = useForm<CustomerInput>({
    defaultValues: {
      customer_type: 'INDIVIDUAL',
      status: 'ACTIVE',
      state: 'Tamil Nadu',
      state_code: '33',
      ...defaultValues,
    },
  });

  // useWatch subscribes via the stable `control` object; watch() cannot be
  // memoized safely and trips the React Compiler lint.
  const customerType = useWatch({ control, name: 'customer_type' });
  const selectedState = useWatch({ control, name: 'state' });

  const onSubmit = handleSubmit((values) => {
    setFormError(null);

    // Validate here too so obvious mistakes never reach the network. The server
    // re-validates regardless — this is for speed of feedback, not for safety.
    const parsed = customerSchema.safeParse(values);
    if (!parsed.success) {
      for (const issue of parsed.error.issues) {
        const field = String(issue.path[0] ?? '') as keyof CustomerInput;
        if (field) {
          setError(field, { message: issue.message });
        }
      }
      setFormError('Please correct the highlighted fields.');
      return;
    }

    startTransition(async () => {
      const result =
        mode === 'create'
          ? await createCustomerAction(values)
          : await updateCustomerAction(customerId!, values);

      if (!result.ok) {
        if (result.fieldErrors) {
          for (const [field, message] of Object.entries(result.fieldErrors)) {
            setError(field as keyof CustomerInput, { message });
          }
        }
        setFormError(result.error ?? 'The customer could not be saved.');
        return;
      }

      router.push(`/customers/${result.id}`);
      router.refresh();
    });
  });

  return (
    <form onSubmit={onSubmit} className="space-y-4" noValidate>
      {formError && (
        <div
          role="alert"
          className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700"
        >
          {formError}
        </div>
      )}

      {/* Identity ------------------------------------------------------------ */}
      <Panel className="p-5">
        <h2 className="mb-4 text-sm font-semibold text-ink-900">Identity</h2>

        {mode === 'edit' && customerCode && (
          <div className="mb-4 rounded-lg border border-ink-200 bg-ink-50 px-3 py-2">
            <span className="text-xs text-ink-500">Customer ID</span>
            <span className="ml-2 font-mono text-sm font-medium text-ink-900">{customerCode}</span>
            <span className="ml-2 text-xs text-ink-400">issued by the system, cannot be changed</span>
          </div>
        )}

        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Name" required error={errors.name?.message} className="sm:col-span-2">
            <Input
              autoFocus
              placeholder="Full name, or registered business name"
              aria-invalid={Boolean(errors.name)}
              {...register('name')}
            />
          </Field>

          <Field label="Customer type" error={errors.customer_type?.message}>
            <select
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm text-ink-900 shadow-sm focus:border-brand-400 focus:outline-none focus:ring-2 focus:ring-brand-500/20"
              {...register('customer_type')}
            >
              <option value="INDIVIDUAL">Individual</option>
              <option value="BUSINESS">Business (GST registered)</option>
            </select>
          </Field>

          <Field label="Status" error={errors.status?.message}>
            <select
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm text-ink-900 shadow-sm focus:border-brand-400 focus:outline-none focus:ring-2 focus:ring-brand-500/20"
              {...register('status')}
            >
              <option value="ACTIVE">Active</option>
              <option value="INACTIVE">Inactive</option>
              <option value="BLOCKED">Blocked</option>
            </select>
          </Field>
        </div>
      </Panel>

      {/* Contact ------------------------------------------------------------- */}
      <Panel className="p-5">
        <h2 className="mb-4 text-sm font-semibold text-ink-900">Contact</h2>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Mobile" required error={errors.mobile?.message}>
            <Input
              inputMode="numeric"
              maxLength={10}
              placeholder="9840012345"
              aria-invalid={Boolean(errors.mobile)}
              {...register('mobile')}
            />
          </Field>

          <Field label="Alternate mobile" error={errors.alternate_mobile?.message}>
            <Input
              inputMode="numeric"
              maxLength={10}
              placeholder="Optional"
              aria-invalid={Boolean(errors.alternate_mobile)}
              {...register('alternate_mobile')}
            />
          </Field>

          <Field label="Email" error={errors.email?.message} className="sm:col-span-2">
            <Input
              type="email"
              placeholder="Optional"
              aria-invalid={Boolean(errors.email)}
              {...register('email')}
            />
          </Field>
        </div>
      </Panel>

      {/* Address ------------------------------------------------------------- */}
      <Panel className="p-5">
        <h2 className="mb-4 text-sm font-semibold text-ink-900">Address</h2>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Address line 1" error={errors.address_line1?.message} className="sm:col-span-2">
            <Input {...register('address_line1')} />
          </Field>
          <Field label="Address line 2" error={errors.address_line2?.message} className="sm:col-span-2">
            <Input {...register('address_line2')} />
          </Field>
          <Field label="City" error={errors.city?.message}>
            <Input {...register('city')} />
          </Field>
          <Field label="PIN code" error={errors.pincode?.message}>
            <Input inputMode="numeric" maxLength={6} {...register('pincode')} />
          </Field>
          <Field label="State" error={errors.state?.message} className="sm:col-span-2">
            <select
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm text-ink-900 shadow-sm focus:border-brand-400 focus:outline-none focus:ring-2 focus:ring-brand-500/20"
              value={selectedState ?? ''}
              onChange={(event) => {
                const state = STATES.find((s) => s.name === event.target.value);
                setValue('state', event.target.value);
                // The GST state code must track the state, since the GSTIN's
                // first two digits are checked against it.
                setValue('state_code', state?.code ?? '');
              }}
            >
              <option value="">Select a state</option>
              {STATES.map((state) => (
                <option key={state.code} value={state.name}>
                  {state.name} ({state.code})
                </option>
              ))}
            </select>
            <input type="hidden" {...register('state_code')} />
          </Field>
        </div>
      </Panel>

      {/* Tax ----------------------------------------------------------------- */}
      <Panel className="p-5">
        <h2 className="mb-1 text-sm font-semibold text-ink-900">Tax details</h2>
        <p className="mb-4 text-xs text-ink-500">
          {customerType === 'BUSINESS'
            ? 'A business customer must have a GSTIN.'
            : 'Optional for an individual customer.'}
        </p>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field
            label="GSTIN"
            required={customerType === 'BUSINESS'}
            error={errors.gstin?.message}
          >
            <Input
              maxLength={15}
              placeholder="33AABCS1429B1ZQ"
              className="font-mono uppercase"
              aria-invalid={Boolean(errors.gstin)}
              {...register('gstin')}
            />
          </Field>
          <Field label="PAN" error={errors.pan?.message}>
            <Input
              maxLength={10}
              placeholder="AABCS1429B"
              className="font-mono uppercase"
              aria-invalid={Boolean(errors.pan)}
              {...register('pan')}
            />
          </Field>
        </div>
      </Panel>

      {/* Other --------------------------------------------------------------- */}
      <Panel className="p-5">
        <h2 className="mb-4 text-sm font-semibold text-ink-900">Other</h2>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Registered at branch" error={errors.origin_branch_id?.message}>
            <select
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm text-ink-900 shadow-sm focus:border-brand-400 focus:outline-none focus:ring-2 focus:ring-brand-500/20"
              {...register('origin_branch_id')}
            >
              <option value="">Not specified</option>
              {branches.map((branch) => (
                <option key={branch.id} value={branch.id}>
                  {branch.name}
                </option>
              ))}
            </select>
            <p className="mt-1 text-xs text-ink-400">
              Informational. The customer remains visible to every branch.
            </p>
          </Field>

          <Field label="Notes" error={errors.notes?.message}>
            <textarea
              rows={3}
              className="w-full rounded-lg border border-ink-200 bg-white px-3 py-2 text-sm text-ink-900 shadow-sm focus:border-brand-400 focus:outline-none focus:ring-2 focus:ring-brand-500/20"
              {...register('notes')}
            />
          </Field>
        </div>
      </Panel>

      <div className="flex items-center gap-2">
        <Button type="submit" disabled={pending}>
          {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Save aria-hidden />}
          {pending ? 'Saving…' : mode === 'create' ? 'Create customer' : 'Save changes'}
        </Button>
        <Button variant="secondary" asChild>
          <Link href={customerId ? `/customers/${customerId}` : '/customers'}>Cancel</Link>
        </Button>
      </div>
    </form>
  );
}

function Field({
  label,
  required,
  error,
  className,
  children,
}: {
  readonly label: string;
  readonly required?: boolean;
  readonly error?: string;
  readonly className?: string;
  readonly children: React.ReactNode;
}) {
  return (
    <div className={className}>
      <Label className="mb-1.5 block">
        {label}
        {required && <span className="ml-0.5 text-danger-600">*</span>}
      </Label>
      {children}
      <FieldError>{error}</FieldError>
    </div>
  );
}
