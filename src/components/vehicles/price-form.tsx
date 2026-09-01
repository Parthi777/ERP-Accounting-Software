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
import { createPriceVersionAction } from '@/server/services/vehicles/pricing-actions';

interface Option {
  readonly id: string;
  readonly label: string;
  readonly modelId?: string;
}

type FormValues = {
  model_id: string;
  variant_id: string;
  branch_id: string;
  ex_showroom: number;
  insurance: number;
  registration: number;
  mandatory_accessories: number;
  forwarding_charge: number;
  other_charges: number;
  purchase_cost: number;
  max_discount: number;
  tax_code: string;
  effective_from: string;
  notes: string;
};

/**
 * New price version — spec §15.
 *
 * The on-road total is shown live as components are typed, because that is the
 * number a customer is quoted and the one most worth checking before saving. It
 * is computed here for display only; the database generates the stored value, so
 * the two cannot disagree.
 */
export function PriceForm({
  models,
  variants,
  branches,
  taxCodes,
  canSeeCost,
}: {
  readonly models: readonly Option[];
  readonly variants: readonly Option[];
  readonly branches: readonly Option[];
  readonly taxCodes: readonly { readonly code: string; readonly label: string }[];
  readonly canSeeCost: boolean;
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
      model_id: '', variant_id: '', branch_id: '',
      ex_showroom: 0, insurance: 0, registration: 0, mandatory_accessories: 0,
      forwarding_charge: 0, other_charges: 0, purchase_cost: 0, max_discount: 0,
      tax_code: '', effective_from: new Date().toISOString().slice(0, 10), notes: '',
    },
  });

  const values = useWatch({ control });
  const selectedModel = values.model_id;

  const num = (v: unknown) => Number(v ?? 0) || 0;
  const onRoad =
    num(values.ex_showroom) + num(values.insurance) + num(values.registration) +
    num(values.mandatory_accessories) + num(values.forwarding_charge) + num(values.other_charges);
  const margin = num(values.ex_showroom) - num(values.purchase_cost);

  // Only variants of the chosen model can be selected.
  const availableVariants = variants.filter((v) => !selectedModel || v.modelId === selectedModel);

  const onSubmit = handleSubmit((form) => {
    setFormError(null);
    if (!form.model_id) {
      setFormError('Choose a model.');
      return;
    }
    startTransition(async () => {
      const result = await createPriceVersionAction({
        model_id: form.model_id,
        variant_id: form.variant_id || undefined,
        branch_id: form.branch_id || undefined,
        ex_showroom: num(form.ex_showroom),
        insurance: num(form.insurance),
        registration: num(form.registration),
        mandatory_accessories: num(form.mandatory_accessories),
        forwarding_charge: num(form.forwarding_charge),
        other_charges: num(form.other_charges),
        purchase_cost: num(form.purchase_cost),
        max_discount: num(form.max_discount),
        tax_code: form.tax_code || undefined,
        effective_from: form.effective_from,
        notes: form.notes || undefined,
      });

      if (!result.ok) {
        setFormError(result.error ?? 'The price version could not be saved.');
        return;
      }
      router.push('/vehicles/pricing');
      router.refresh();
    });
  });

  const money = (name: keyof FormValues, label: string, help?: string) => (
    <div>
      <Label htmlFor={name} className="mb-1.5 block">{label}</Label>
      <div className="relative">
        <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-ink-400">₹</span>
        <Input
          id={name}
          type="number"
          step="0.01"
          min="0"
          className="pl-7"
          aria-invalid={Boolean(errors[name])}
          {...register(name, { valueAsNumber: true })}
        />
      </div>
      {help && <p className="mt-1 text-xs text-ink-400">{help}</p>}
      <FieldError>{errors[name]?.message as string | undefined}</FieldError>
    </div>
  );

  return (
    <form onSubmit={onSubmit} className="space-y-4" noValidate>
      {formError && (
        <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
          {formError}
        </div>
      )}

      <Panel className="p-5">
        <h2 className="mb-4 text-sm font-semibold text-ink-900">Applies to</h2>
        <div className="grid gap-4 sm:grid-cols-2">
          <div className="sm:col-span-2">
            <Label htmlFor="model_id" className="mb-1.5 block">Model<span className="ml-0.5 text-danger-600">*</span></Label>
            <select id="model_id" className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" {...register('model_id')}>
              <option value="">Choose a model</option>
              {models.map((m) => <option key={m.id} value={m.id}>{m.label}</option>)}
            </select>
          </div>

          <div>
            <Label htmlFor="variant_id" className="mb-1.5 block">Variant</Label>
            <select id="variant_id" className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" {...register('variant_id')}>
              <option value="">All variants of this model</option>
              {availableVariants.map((v) => <option key={v.id} value={v.id}>{v.label}</option>)}
            </select>
            <p className="mt-1 text-xs text-ink-400">A variant price overrides the model price.</p>
          </div>

          <div>
            <Label htmlFor="branch_id" className="mb-1.5 block">Branch</Label>
            <select id="branch_id" className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" {...register('branch_id')}>
              <option value="">All branches</option>
              {branches.map((b) => <option key={b.id} value={b.id}>{b.label}</option>)}
            </select>
            <p className="mt-1 text-xs text-ink-400">A branch price overrides the dealer-wide one.</p>
          </div>

          <div>
            <Label htmlFor="effective_from" className="mb-1.5 block">
              Effective from<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <Input id="effective_from" type="date" {...register('effective_from')} />
            <p className="mt-1 text-xs text-ink-400">
              The current version is closed the day before this date.
            </p>
          </div>

          <div>
            <Label htmlFor="tax_code" className="mb-1.5 block">Tax code</Label>
            <select id="tax_code" className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" {...register('tax_code')}>
              <option value="">Not specified</option>
              {taxCodes.map((t) => <option key={t.code} value={t.code}>{t.label}</option>)}
            </select>
          </div>
        </div>
      </Panel>

      <Panel className="p-5">
        <h2 className="text-sm font-semibold text-ink-900">Price components</h2>
        <p className="mb-4 text-xs text-ink-500">
          Each component posts to a different ledger account at sale, so they are held separately
          rather than as one on-road figure.
        </p>
        <div className="grid gap-4 sm:grid-cols-3">
          {money('ex_showroom', 'Ex-showroom')}
          {money('insurance', 'Insurance')}
          {money('registration', 'Registration (LTRT)')}
          {money('mandatory_accessories', 'Mandatory accessories')}
          {money('forwarding_charge', 'Forwarding')}
          {money('other_charges', 'Other charges')}
        </div>

        <div className="mt-5 flex items-center justify-between rounded-lg border border-brand-200 bg-brand-50 px-4 py-3">
          <span className="text-sm font-medium text-brand-800">On-road total</span>
          <span className="numeric text-lg font-bold text-brand-900">
            {formatINR(fromRupees(onRoad))}
          </span>
        </div>
      </Panel>

      {canSeeCost && (
        <Panel className="p-5">
          <h2 className="text-sm font-semibold text-ink-900">Cost and discount</h2>
          <p className="mb-4 text-xs text-ink-500">
            Restricted — visible only to roles holding vehicles.view_cost.
          </p>
          <div className="grid gap-4 sm:grid-cols-3">
            {money('purchase_cost', 'Purchase cost')}
            {money('max_discount', 'Maximum discount', 'The most a cashier may give away.')}
            <div>
              <Label className="mb-1.5 block">Margin on ex-showroom</Label>
              <div className={`flex h-9 items-center rounded-lg border px-3 text-sm ${
                margin >= 0 ? 'border-positive-200 bg-positive-50 text-positive-700'
                            : 'border-danger-200 bg-danger-50 text-danger-700'}`}>
                <span className="numeric font-semibold">{formatINR(fromRupees(margin))}</span>
              </div>
            </div>
          </div>
        </Panel>
      )}

      <Panel className="p-5">
        <Label htmlFor="notes" className="mb-1.5 block">Notes</Label>
        <textarea
          id="notes"
          rows={2}
          className="w-full rounded-lg border border-ink-200 bg-white px-3 py-2 text-sm shadow-sm"
          placeholder="Why this price changed — useful when someone asks in six months."
          {...register('notes')}
        />
      </Panel>

      {/* Saving no longer publishes. Spec §15 routes a price through approval,
          and a form that silently did something different from what the workflow
          screen shows would be the worst of both. */}
      <Panel className="p-4">
        <p className="text-sm text-ink-700">This saves as a draft. It does not go live yet.</p>
        <p className="mt-1 text-xs text-ink-500">
          Every future invoice is computed from the active price, so a new version is submitted and
          approved before it takes effect. Take it through those steps under{' '}
          <Link href="/masters/pricing" className="text-brand-600 hover:underline">Masters → Pricing</Link>.
        </p>
      </Panel>

      <div className="flex items-center gap-2">
        <Button type="submit" disabled={pending}>
          {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Save aria-hidden />}
          {pending ? 'Saving…' : 'Save as draft'}
        </Button>
        <Button variant="secondary" asChild><Link href="/vehicles/pricing">Cancel</Link></Button>
      </div>
    </form>
  );
}
