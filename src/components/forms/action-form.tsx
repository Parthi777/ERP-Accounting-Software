'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2 } from 'lucide-react';

import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { cn } from '@/lib/utils';

export interface ActionField {
  readonly name: string;
  readonly label: string;
  readonly type?: 'text' | 'number' | 'date' | 'month' | 'select' | 'checkbox';
  readonly options?: readonly { value: string; label: string }[];
  readonly required?: boolean;
  readonly defaultValue?: string;
  readonly placeholder?: string;
  readonly hint?: string;
  readonly step?: string;
  /** Spans the full row of the grid. */
  readonly wide?: boolean;
}

export type ActionResult = { ok: boolean; error?: string; message?: string };

/**
 * A small form around one server action: labelled fields, the pending state,
 * the error or the confirmation, and a fresh idempotency key per successful
 * submission (spec §50) so a double-click or retry replays rather than repeats.
 * The server re-validates everything; `required` here only saves a round trip.
 */
export function ActionForm({
  fields,
  action,
  submitLabel,
  columns = 3,
  confirm,
  resetOnSuccess = true,
  fixed,
}: {
  readonly fields: readonly ActionField[];
  readonly action: (values: Record<string, string>) => Promise<ActionResult>;
  readonly submitLabel: string;
  readonly columns?: 1 | 2 | 3 | 4;
  /** Asked before a financial action posts (spec §8: confirmation for financial actions). */
  readonly confirm?: string;
  readonly resetOnSuccess?: boolean;
  /** Values sent with every submission — the id of the row this form acts on. */
  readonly fixed?: Readonly<Record<string, string>>;
}) {
  const router = useRouter();
  const initial = React.useMemo(
    () => Object.fromEntries(fields.map((f) => [f.name, f.defaultValue ?? (f.type === 'checkbox' ? 'false' : '')])),
    [fields],
  );
  const [values, setValues] = React.useState<Record<string, string>>(initial);
  const [key, setKey] = React.useState(() => crypto.randomUUID());
  const [error, setError] = React.useState<string | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);
    setNotice(null);
    const missing = fields.find((f) => f.required && !values[f.name]?.trim());
    if (missing) return setError(`${missing.label} is required.`);
    if (confirm && !window.confirm(confirm)) return;

    startTransition(async () => {
      const result = await action({ ...values, ...fixed, idempotencyKey: key });
      if (!result.ok) {
        setError(result.error ?? 'That could not be done.');
        return;
      }
      setKey(crypto.randomUUID());
      setNotice(result.message ?? 'Done.');
      if (resetOnSuccess) setValues(initial);
      router.refresh();
    });
  };

  const grid = { 1: 'sm:grid-cols-1', 2: 'sm:grid-cols-2', 3: 'sm:grid-cols-2 lg:grid-cols-3', 4: 'sm:grid-cols-2 lg:grid-cols-4' }[columns];

  return (
    <form onSubmit={submit} className={cn('grid gap-4', grid)} noValidate>
      {fields.map((f) => {
        const id = `af-${f.name}`;
        const set = (v: string) => setValues((cur) => ({ ...cur, [f.name]: v }));
        return (
          <div key={f.name} className={cn(f.wide && 'sm:col-span-full')}>
            {f.type === 'checkbox' ? (
              <label className="flex items-center gap-2 pt-6 text-sm text-ink-700">
                <input id={id} type="checkbox" checked={values[f.name] === 'true'}
                  onChange={(e) => set(e.target.checked ? 'true' : 'false')} />
                {f.label}
              </label>
            ) : (
              <>
                <Label htmlFor={id} className="mb-1.5 block">
                  {f.label}{f.required && <span className="ml-0.5 text-danger-600">*</span>}
                </Label>
                {f.type === 'select' ? (
                  <select id={id} value={values[f.name]} onChange={(e) => set(e.target.value)}
                    className="field h-10 w-full px-3 text-sm">
                    <option value="">Choose…</option>
                    {f.options?.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
                  </select>
                ) : (
                  <Input id={id} type={f.type ?? 'text'} step={f.step ?? (f.type === 'number' ? '0.01' : undefined)}
                    value={values[f.name]} placeholder={f.placeholder} onChange={(e) => set(e.target.value)}
                    className={f.type === 'number' ? 'numeric' : undefined} />
                )}
              </>
            )}
            {f.hint && <p className="mt-1 text-[11px] text-ink-500">{f.hint}</p>}
          </div>
        );
      })}

      {error && <p role="alert" className="rounded-xl bg-danger-50 px-3 py-2 text-sm text-danger-700 sm:col-span-full">{error}</p>}
      {notice && <p className="rounded-xl bg-positive-50 px-3 py-2 text-sm text-positive-700 sm:col-span-full">{notice}</p>}

      <div className="sm:col-span-full">
        <Button type="submit" disabled={pending}>
          {pending && <Loader2 className="animate-spin" aria-hidden />}
          {submitLabel}
        </Button>
      </div>
    </form>
  );
}
