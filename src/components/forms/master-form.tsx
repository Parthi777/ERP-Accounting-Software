'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { useForm } from 'react-hook-form';
import { Loader2, Save } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { FieldError, Input, Label } from '@/components/ui/input';
import { cn } from '@/lib/utils';
import type { MasterKind } from '@/lib/validation/masters';
import { createMasterAction, updateMasterAction } from '@/server/services/masters/actions';

/**
 * One form for all six masters.
 *
 * They differ only in their fields, so the shape is described as data and
 * rendered by one component. Six near-identical form files would drift: one
 * would get an accessibility fix, another a better error message, and the screens
 * would slowly stop behaving alike.
 */

export interface FieldOption {
  readonly value: string;
  readonly label: string;
}

export interface FieldDef {
  readonly name: string;
  readonly label: string;
  readonly type: 'text' | 'number' | 'select' | 'checkbox' | 'date' | 'textarea';
  readonly required?: boolean;
  readonly options?: readonly FieldOption[];
  readonly placeholder?: string;
  readonly help?: string;
  readonly wide?: boolean;
  readonly mono?: boolean;
  readonly maxLength?: number;
  readonly step?: string;
  readonly suffix?: string;
}

export interface FieldGroup {
  readonly title: string;
  readonly description?: string;
  readonly fields: readonly FieldDef[];
}

export function MasterForm({
  kind,
  mode,
  recordId,
  groups,
  defaultValues,
  returnTo,
  title,
}: {
  readonly kind: MasterKind;
  readonly mode: 'create' | 'edit';
  readonly recordId?: string;
  readonly groups: readonly FieldGroup[];
  readonly defaultValues?: Readonly<Record<string, unknown>>;
  readonly returnTo: string;
  readonly title?: string;
}) {
  const router = useRouter();
  const [formError, setFormError] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  const {
    register,
    handleSubmit,
    setError,
    formState: { errors },
  } = useForm<Record<string, unknown>>({ defaultValues: defaultValues as Record<string, unknown> });

  const onSubmit = handleSubmit((values) => {
    setFormError(null);
    startTransition(async () => {
      const result =
        mode === 'create'
          ? await createMasterAction(kind, values)
          : await updateMasterAction(kind, recordId!, values);

      if (!result.ok) {
        if (result.fieldErrors) {
          for (const [field, message] of Object.entries(result.fieldErrors)) {
            setError(field, { message });
          }
        }
        setFormError(result.error ?? 'The record could not be saved.');
        return;
      }

      router.push(returnTo);
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

      {groups.map((group) => (
        <Panel key={group.title} className="p-5">
          <h2 className="text-sm font-semibold text-ink-900">{group.title}</h2>
          {group.description && <p className="mt-0.5 mb-4 text-xs text-ink-500">{group.description}</p>}
          {!group.description && <div className="mb-4" />}

          <div className="grid gap-4 sm:grid-cols-2">
            {group.fields.map((field) => (
              <div key={field.name} className={cn(field.wide && 'sm:col-span-2')}>
                {field.type === 'checkbox' ? (
                  <label className="flex items-center gap-2 pt-6">
                    <input
                      type="checkbox"
                      className="size-4 rounded border-ink-300 text-brand-600 focus:ring-2 focus:ring-brand-500/20"
                      {...register(field.name)}
                    />
                    <span className="text-sm text-ink-700">{field.label}</span>
                  </label>
                ) : (
                  <>
                    <Label htmlFor={field.name} className="mb-1.5 block">
                      {field.label}
                      {field.required && <span className="ml-0.5 text-danger-600">*</span>}
                    </Label>

                    {field.type === 'select' ? (
                      <select
                        id={field.name}
                        aria-invalid={Boolean(errors[field.name])}
                        className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm text-ink-900 shadow-sm focus:border-brand-400 focus:outline-none focus:ring-2 focus:ring-brand-500/20"
                        {...register(field.name)}
                      >
                        {!field.required && <option value="">Not specified</option>}
                        {field.options?.map((option) => (
                          <option key={option.value} value={option.value}>
                            {option.label}
                          </option>
                        ))}
                      </select>
                    ) : field.type === 'textarea' ? (
                      <textarea
                        id={field.name}
                        rows={3}
                        className="w-full rounded-lg border border-ink-200 bg-white px-3 py-2 text-sm text-ink-900 shadow-sm focus:border-brand-400 focus:outline-none focus:ring-2 focus:ring-brand-500/20"
                        {...register(field.name)}
                      />
                    ) : (
                      <div className="relative">
                        <Input
                          id={field.name}
                          type={field.type === 'number' ? 'number' : field.type === 'date' ? 'date' : 'text'}
                          step={field.step}
                          maxLength={field.maxLength}
                          placeholder={field.placeholder}
                          aria-invalid={Boolean(errors[field.name])}
                          className={cn(field.mono && 'font-mono uppercase', field.suffix && 'pr-10')}
                          {...register(field.name)}
                        />
                        {field.suffix && (
                          <span className="pointer-events-none absolute right-3 top-1/2 -translate-y-1/2 text-xs text-ink-400">
                            {field.suffix}
                          </span>
                        )}
                      </div>
                    )}

                    {field.help && <p className="mt-1 text-xs text-ink-400">{field.help}</p>}
                    <FieldError>{errors[field.name]?.message as string | undefined}</FieldError>
                  </>
                )}
              </div>
            ))}
          </div>
        </Panel>
      ))}

      <div className="flex items-center gap-2">
        <Button type="submit" disabled={pending}>
          {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Save aria-hidden />}
          {pending ? 'Saving…' : mode === 'create' ? `Create ${title ?? 'record'}` : 'Save changes'}
        </Button>
        <Button variant="secondary" asChild>
          <Link href={returnTo}>Cancel</Link>
        </Button>
      </div>
    </form>
  );
}
