'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, Lock, Plus } from 'lucide-react';

import type { SalaryStructure } from '@/server/services/hr/hr-service';
import { addSalaryStructureAction } from '@/server/services/hr/hr-actions';
import { Panel, PanelContent, PanelHeader, PanelTitle, SolidPanel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Input, Label } from '@/components/ui/input';
import { add, formatINR, fromRupees, subtract, toRupees, ZERO, type Paise } from '@/lib/money';
import { formatDate } from '@/lib/format';

/**
 * Pay — spec §15, §52.
 *
 * A revision is added, never an edit: the row it supersedes keeps its figures so
 * a payslip re-run for a past month reproduces that month. The form therefore
 * offers "revise from a date", not "change the salary".
 *
 * When the session cannot see pay the panel says so plainly rather than
 * rendering an empty table — an empty table reads as "he is paid nothing".
 */
const EARNINGS = [
  { key: 'basic', label: 'Basic' },
  { key: 'hra', label: 'HRA' },
  { key: 'conveyance', label: 'Conveyance' },
  { key: 'medicalAllowance', label: 'Medical' },
  { key: 'specialAllowance', label: 'Special allowance' },
  { key: 'otherAllowance', label: 'Other allowance' },
] as const;

const DEDUCTIONS = [
  { key: 'pfEmployee', label: 'PF (employee)' },
  { key: 'esiEmployee', label: 'ESI (employee)' },
  { key: 'professionalTax', label: 'Professional tax' },
  { key: 'otherDeduction', label: 'Other deduction' },
] as const;

const EMPLOYER = [
  { key: 'pfEmployer', label: 'PF (employer)' },
  { key: 'esiEmployer', label: 'ESI (employer)' },
] as const;

type FieldKey =
  | (typeof EARNINGS)[number]['key']
  | (typeof DEDUCTIONS)[number]['key']
  | (typeof EMPLOYER)[number]['key'];

export function SalaryPanel({
  employeeId,
  history,
  canSee,
  canManage,
}: {
  readonly employeeId: string;
  readonly history: readonly SalaryStructure[];
  readonly canSee: boolean;
  readonly canManage: boolean;
}) {
  const router = useRouter();
  const [open, setOpen] = React.useState(false);
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [effectiveFrom, setEffectiveFrom] = React.useState('');
  const [note, setNote] = React.useState('');
  const [amounts, setAmounts] = React.useState<Record<string, string>>({});

  const current = history.find((s) => s.current) ?? history[0] ?? null;

  const value = (key: FieldKey): Paise => {
    const n = Number(amounts[key] ?? '');
    return Number.isFinite(n) && n > 0 ? fromRupees(n) : ZERO;
  };

  const gross = EARNINGS.reduce((sum, f) => add(sum, value(f.key)), ZERO);
  const deductions = DEDUCTIONS.reduce((sum, f) => add(sum, value(f.key)), ZERO);
  const employer = EMPLOYER.reduce((sum, f) => add(sum, value(f.key)), ZERO);
  const net = subtract(gross, deductions);

  /** Seeds the form from the structure in force, so a revision is an edit of what is. */
  const prefill = () => {
    if (!current) return setAmounts({});
    setAmounts({
      basic: String(toRupees(current.basic)),
      hra: String(toRupees(current.hra)),
      conveyance: String(toRupees(current.conveyance)),
      medicalAllowance: String(toRupees(current.medicalAllowance)),
      specialAllowance: String(toRupees(current.specialAllowance)),
      otherAllowance: String(toRupees(current.otherAllowance)),
      pfEmployee: String(toRupees(current.pfEmployee)),
      esiEmployee: String(toRupees(current.esiEmployee)),
      professionalTax: String(toRupees(current.professionalTax)),
      otherDeduction: String(toRupees(current.otherDeduction)),
      pfEmployer: String(toRupees(current.pfEmployer)),
      esiEmployer: String(toRupees(current.esiEmployer)),
    });
  };

  const submit = () => {
    setError(null);
    if (!effectiveFrom) return setError('Say from which date this pay applies.');
    if (!(value('basic') > 0)) return setError('Basic pay has to be greater than zero.');
    if (net < 0) return setError('The deductions come to more than the earnings.');

    startTransition(async () => {
      const num = (key: FieldKey) => toRupees(value(key));
      const result = await addSalaryStructureAction({
        employeeId,
        effectiveFrom,
        basic: num('basic'),
        hra: num('hra'),
        conveyance: num('conveyance'),
        medicalAllowance: num('medicalAllowance'),
        specialAllowance: num('specialAllowance'),
        otherAllowance: num('otherAllowance'),
        pfEmployee: num('pfEmployee'),
        esiEmployee: num('esiEmployee'),
        professionalTax: num('professionalTax'),
        otherDeduction: num('otherDeduction'),
        pfEmployer: num('pfEmployer'),
        esiEmployer: num('esiEmployer'),
        revisionNote: note.trim() || null,
      });

      if (!result.ok) {
        setError(result.error ?? 'The revision could not be saved.');
        return;
      }
      setOpen(false);
      setNote('');
      setEffectiveFrom('');
      router.refresh();
    });
  };

  if (!canSee) {
    return (
      <Panel>
        <PanelHeader><PanelTitle>Salary</PanelTitle></PanelHeader>
        <PanelContent>
          <p className="flex items-start gap-2 text-sm text-ink-600">
            <Lock className="mt-0.5 size-4 shrink-0 text-ink-400" aria-hidden />
            Pay is restricted. This session does not hold the permission to see it, and the figures
            are withheld from the response rather than merely hidden here.
          </p>
        </PanelContent>
      </Panel>
    );
  }

  return (
    <Panel>
      <PanelHeader>
        <PanelTitle>Salary</PanelTitle>
        {canManage && (
          <Button size="sm" variant="secondary" onClick={() => { setOpen(true); prefill(); }}>
            <Plus aria-hidden />
            Revise
          </Button>
        )}
      </PanelHeader>

      <PanelContent>
        {history.length === 0 ? (
          <p className="text-sm text-ink-400">
            No pay has been set for this employee yet. Payroll needs a structure before it can
            compute anything.
          </p>
        ) : (
          <>
            {current && (
              <div className="mb-4 grid gap-3 sm:grid-cols-3">
                <Figure label="Gross" value={current.grossEarnings} />
                <Figure label="Net payable" value={current.netPayable} emphasis />
                <Figure label="Cost to company" value={current.costToCompany} />
              </div>
            )}

            <SolidPanel className="overflow-hidden">
              <div className="overflow-x-auto">
                <table className="w-full border-collapse text-sm">
                  <caption className="sr-only">Salary history</caption>
                  <thead>
                    <tr className="bg-ink-50">
                      <th scope="col" className="px-3 py-2 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Effective</th>
                      <th scope="col" className="px-3 py-2 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Gross</th>
                      <th scope="col" className="px-3 py-2 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Deductions</th>
                      <th scope="col" className="px-3 py-2 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Net</th>
                      <th scope="col" className="px-3 py-2 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">CTC</th>
                    </tr>
                  </thead>
                  <tbody>
                    {history.map((s) => (
                      <tr key={s.id} className="border-t border-ink-100">
                        <td className="px-3 py-2">
                          <span className="flex flex-wrap items-center gap-2">
                            <span className="text-ink-800">{formatDate(s.effectiveFrom)}</span>
                            {s.current && <Badge variant="positive">Current</Badge>}
                          </span>
                          <span className="block text-[11px] text-ink-400">
                            {s.effectiveTo ? `until ${formatDate(s.effectiveTo)}` : 'no end date'}
                            {s.revisionNote ? ` · ${s.revisionNote}` : ''}
                          </span>
                        </td>
                        <td className="numeric px-3 py-2 text-right">{formatINR(s.grossEarnings)}</td>
                        <td className="numeric px-3 py-2 text-right text-ink-500">{formatINR(s.totalDeductions)}</td>
                        <td className="numeric px-3 py-2 text-right font-medium">{formatINR(s.netPayable)}</td>
                        <td className="numeric px-3 py-2 text-right text-ink-500">{formatINR(s.costToCompany)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </SolidPanel>

            <p className="mt-2 text-[11px] text-ink-400">
              A revision never edits what came before it, so a payslip re-run for any past month
              reproduces that month exactly.
            </p>
          </>
        )}
      </PanelContent>

      {open && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
          role="dialog" aria-modal="true" onClick={() => setOpen(false)}>
          <div className="glass-strong max-h-[90vh] w-full max-w-2xl overflow-y-auto rounded-2xl p-6"
            onClick={(e) => e.stopPropagation()}>
            <h2 className="text-sm font-semibold text-ink-900">Revise pay</h2>
            <p className="mt-1 text-sm text-ink-600">
              This adds a structure from the date you give. The one in force keeps its figures and is
              closed the day before.
            </p>

            {error && (
              <div role="alert" className="mt-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
                {error}
              </div>
            )}

            <div className="mt-4 grid gap-3 sm:grid-cols-2">
              <div>
                <Label htmlFor="eff-from" className="mb-1.5 block">
                  Effective from<span className="ml-0.5 text-danger-600">*</span>
                </Label>
                <Input id="eff-from" type="date" value={effectiveFrom}
                  onChange={(e) => setEffectiveFrom(e.target.value)} />
              </div>
              <div>
                <Label htmlFor="rev-note" className="mb-1.5 block">Note</Label>
                <Input id="rev-note" value={note} onChange={(e) => setNote(e.target.value)}
                  placeholder="e.g. Annual increment" />
              </div>
            </div>

            <Group title="Earnings" fields={EARNINGS} amounts={amounts} setAmounts={setAmounts} />
            <Group title="Deductions from pay" fields={DEDUCTIONS} amounts={amounts} setAmounts={setAmounts} />
            <Group title="Employer contribution — a cost, not a deduction"
              fields={EMPLOYER} amounts={amounts} setAmounts={setAmounts} />

            <div className="mt-4 flex flex-wrap gap-x-6 gap-y-1 rounded-lg border border-brand-200 bg-brand-50 px-4 py-2.5 text-xs text-brand-800">
              <span>Gross <span className="numeric font-semibold">{formatINR(gross)}</span></span>
              <span>Deductions <span className="numeric font-semibold">{formatINR(deductions)}</span></span>
              <span className={net < 0 ? 'text-danger-700' : ''}>
                Net <span className="numeric font-semibold">{formatINR(net)}</span>
              </span>
              <span>CTC <span className="numeric font-semibold">{formatINR(add(gross, employer))}</span></span>
            </div>

            <div className="mt-4 flex justify-end gap-2">
              <Button variant="secondary" size="sm" onClick={() => setOpen(false)} disabled={pending}>Back</Button>
              <Button size="sm" disabled={pending} onClick={submit}>
                {pending && <Loader2 className="animate-spin" aria-hidden />}
                Save revision
              </Button>
            </div>
          </div>
        </div>
      )}
    </Panel>
  );
}

function Group({
  title,
  fields,
  amounts,
  setAmounts,
}: {
  readonly title: string;
  readonly fields: readonly { readonly key: string; readonly label: string }[];
  readonly amounts: Record<string, string>;
  readonly setAmounts: React.Dispatch<React.SetStateAction<Record<string, string>>>;
}) {
  return (
    <div className="mt-4">
      <h3 className="mb-2 text-[11px] font-semibold uppercase tracking-wide text-ink-500">{title}</h3>
      <div className="grid gap-3 sm:grid-cols-3">
        {fields.map((f) => (
          <div key={f.key}>
            <Label htmlFor={`pay-${f.key}`} className="mb-1.5 block text-xs">{f.label}</Label>
            <div className="relative">
              <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-ink-400">₹</span>
              <Input id={`pay-${f.key}`} type="number" step="0.01" min="0" className="pl-7"
                value={amounts[f.key] ?? ''}
                onChange={(e) => setAmounts((c) => ({ ...c, [f.key]: e.target.value }))} />
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function Figure({
  label,
  value,
  emphasis = false,
}: {
  readonly label: string;
  readonly value: Paise;
  readonly emphasis?: boolean;
}) {
  return (
    <div className="rounded-lg border border-ink-100 bg-white px-3 py-2">
      <p className="text-xs text-ink-500">{label}</p>
      <p className={emphasis ? 'numeric mt-0.5 text-lg font-bold text-ink-900' : 'numeric mt-0.5 text-lg font-semibold text-ink-800'}>
        {formatINR(value)}
      </p>
    </div>
  );
}
