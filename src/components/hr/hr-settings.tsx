'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, Pencil, Plus } from 'lucide-react';

import type { LeaveType, Shift } from '@/server/services/hr/hr-service';
import { saveLeaveTypeAction, saveShiftAction } from '@/server/services/hr/hr-actions';
import { Panel, PanelContent, PanelHeader, PanelTitle, SolidPanel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Input, Label } from '@/components/ui/input';

/**
 * Shifts and leave types — spec §12.
 *
 * Both are configuration a dealer sets once and rarely revisits, so they share
 * one screen rather than each getting a route of their own.
 */
const DAYS = [
  { n: 1, label: 'Mon' }, { n: 2, label: 'Tue' }, { n: 3, label: 'Wed' },
  { n: 4, label: 'Thu' }, { n: 5, label: 'Fri' }, { n: 6, label: 'Sat' },
  { n: 7, label: 'Sun' },
];

export function HrSettings({
  shifts,
  leaveTypes,
  canManage,
}: {
  readonly shifts: readonly Shift[];
  readonly leaveTypes: readonly LeaveType[];
  readonly canManage: boolean;
}) {
  const [notice, setNotice] = React.useState<string | null>(null);

  return (
    <div className="space-y-4">
      {notice && (
        <div role="status" className="rounded-lg border border-positive-200 bg-positive-50 px-3 py-2 text-sm text-positive-700">
          {notice}
        </div>
      )}
      <ShiftsPanel shifts={shifts} canManage={canManage} onSaved={setNotice} />
      <LeavePanel leaveTypes={leaveTypes} canManage={canManage} onSaved={setNotice} />
    </div>
  );
}

function ShiftsPanel({
  shifts,
  canManage,
  onSaved,
}: {
  readonly shifts: readonly Shift[];
  readonly canManage: boolean;
  readonly onSaved: (message: string) => void;
}) {
  const router = useRouter();
  const [editing, setEditing] = React.useState<Shift | 'new' | null>(null);
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);

  const submit = (form: ShiftForm) => {
    setError(null);
    startTransition(async () => {
      const result = await saveShiftAction({
        id: editing && editing !== 'new' ? editing.id : null,
        ...form,
      });
      if (!result.ok) {
        setError(result.error ?? 'The shift could not be saved.');
        return;
      }
      setEditing(null);
      onSaved(result.message ?? 'Saved.');
      router.refresh();
    });
  };

  return (
    <Panel>
      <PanelHeader>
        <PanelTitle>Shifts</PanelTitle>
        {canManage && (
          <Button size="sm" variant="secondary" onClick={() => setEditing('new')}>
            <Plus aria-hidden />Add shift
          </Button>
        )}
      </PanelHeader>
      <PanelContent className="px-0 pb-0">
        {shifts.length === 0 ? (
          <p className="px-5 pb-5 text-sm text-ink-400">
            No shifts yet. Attendance measures each day against one, so it needs at least a general
            shift before it can mark anyone late or absent.
          </p>
        ) : (
          <SolidPanel className="rounded-none border-x-0 border-b-0">
            <div className="overflow-x-auto">
              <table className="w-full border-collapse text-sm">
                <caption className="sr-only">Shifts</caption>
                <thead>
                  <tr className="bg-ink-50">
                    <th scope="col" className="px-4 py-2 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Shift</th>
                    <th scope="col" className="px-4 py-2 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Timing</th>
                    <th scope="col" className="px-4 py-2 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Break</th>
                    <th scope="col" className="px-4 py-2 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Grace</th>
                    <th scope="col" className="px-4 py-2 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Week off</th>
                    {canManage && <th scope="col" className="px-4 py-2" />}
                  </tr>
                </thead>
                <tbody>
                  {shifts.map((s) => (
                    <tr key={s.id} className="border-t border-ink-100">
                      <td className="px-4 py-2">
                        <span className="text-ink-800">{s.name}</span>
                        <span className="ml-2 font-mono text-[11px] text-ink-400">{s.code}</span>
                      </td>
                      <td className="px-4 py-2 text-ink-700">
                        {s.startsAt.slice(0, 5)} – {s.endsAt.slice(0, 5)}
                      </td>
                      <td className="numeric px-4 py-2 text-right text-ink-500">{s.breakMinutes}m</td>
                      <td className="numeric px-4 py-2 text-right text-ink-500">{s.graceMinutes}m</td>
                      <td className="px-4 py-2">
                        <span className="flex flex-wrap gap-1">
                          {s.weekOffDays.length === 0
                            ? <span className="text-ink-300">None</span>
                            : s.weekOffDays.map((d) => (
                                <Badge key={d} variant="neutral">
                                  {DAYS.find((x) => x.n === d)?.label ?? d}
                                </Badge>
                              ))}
                        </span>
                      </td>
                      {canManage && (
                        <td className="px-4 py-2 text-right">
                          <Button variant="ghost" size="sm" onClick={() => setEditing(s)} aria-label={`Edit ${s.name}`}>
                            <Pencil aria-hidden />
                          </Button>
                        </td>
                      )}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </SolidPanel>
        )}
      </PanelContent>

      {editing && (
        <ShiftDialog
          // Keyed by what is being edited: React discards the old form state and
          // mounts a fresh one, which is what an effect would otherwise be
          // simulating badly.
          key={editing === 'new' ? 'new' : editing.id}
          shift={editing === 'new' ? null : editing}
          error={error}
          pending={pending}
          onCancel={() => setEditing(null)}
          onSubmit={submit}
        />
      )}
    </Panel>
  );
}

interface ShiftForm {
  code: string;
  name: string;
  startsAt: string;
  endsAt: string;
  breakMinutes: number;
  graceMinutes: number;
  weekOffDays: number[];
  halfDayMinutes: number;
  fullDayMinutes: number;
}

function ShiftDialog({
  shift,
  error,
  pending,
  onCancel,
  onSubmit,
}: {
  readonly shift: Shift | null;
  readonly error: string | null;
  readonly pending: boolean;
  readonly onCancel: () => void;
  readonly onSubmit: (form: ShiftForm) => void;
}) {
  const [form, setForm] = React.useState<ShiftForm>(() =>
    shift
      ? {
          code: shift.code, name: shift.name,
          startsAt: shift.startsAt.slice(0, 5), endsAt: shift.endsAt.slice(0, 5),
          breakMinutes: shift.breakMinutes, graceMinutes: shift.graceMinutes,
          weekOffDays: [...shift.weekOffDays],
          halfDayMinutes: shift.halfDayMinutes, fullDayMinutes: shift.fullDayMinutes,
        }
      : {
          code: '', name: '', startsAt: '09:30', endsAt: '18:30',
          breakMinutes: 60, graceMinutes: 10, weekOffDays: [7],
          halfDayMinutes: 240, fullDayMinutes: 480,
        },
  );

  return (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
          role="dialog" aria-modal="true" onClick={onCancel}>
          <div className="glass-strong max-h-[90vh] w-full max-w-lg overflow-y-auto rounded-2xl p-6"
            onClick={(e) => e.stopPropagation()}>
            <h2 className="text-sm font-semibold text-ink-900">
              {shift ? `Edit ${shift.name}` : 'Add a shift'}
            </h2>

            {error && (
              <div role="alert" className="mt-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
                {error}
              </div>
            )}

            <div className="mt-4 grid gap-3 sm:grid-cols-2">
              <div>
                <Label htmlFor="s-code" className="mb-1.5 block">Code</Label>
                <Input id="s-code" value={form.code} disabled={shift !== null}
                  onChange={(e) => setForm((f) => ({ ...f, code: e.target.value }))} placeholder="GEN" />
              </div>
              <div>
                <Label htmlFor="s-name" className="mb-1.5 block">Name</Label>
                <Input id="s-name" value={form.name}
                  onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))} placeholder="General shift" />
              </div>
              <div>
                <Label htmlFor="s-start" className="mb-1.5 block">Starts</Label>
                <Input id="s-start" type="time" value={form.startsAt}
                  onChange={(e) => setForm((f) => ({ ...f, startsAt: e.target.value }))} />
              </div>
              <div>
                <Label htmlFor="s-end" className="mb-1.5 block">Ends</Label>
                <Input id="s-end" type="time" value={form.endsAt}
                  onChange={(e) => setForm((f) => ({ ...f, endsAt: e.target.value }))} />
              </div>
              <div>
                <Label htmlFor="s-break" className="mb-1.5 block">Break (minutes)</Label>
                <Input id="s-break" type="number" min="0" max="480" value={form.breakMinutes}
                  onChange={(e) => setForm((f) => ({ ...f, breakMinutes: Number(e.target.value) }))} />
              </div>
              <div>
                <Label htmlFor="s-grace" className="mb-1.5 block">Grace (minutes)</Label>
                <Input id="s-grace" type="number" min="0" max="120" value={form.graceMinutes}
                  onChange={(e) => setForm((f) => ({ ...f, graceMinutes: Number(e.target.value) }))} />
                <p className="mt-1 text-xs text-ink-400">Arriving within this is still on time.</p>
              </div>
              <div>
                <Label htmlFor="s-half" className="mb-1.5 block">Half day after (minutes)</Label>
                <Input id="s-half" type="number" min="1" value={form.halfDayMinutes}
                  onChange={(e) => setForm((f) => ({ ...f, halfDayMinutes: Number(e.target.value) }))} />
              </div>
              <div>
                <Label htmlFor="s-full" className="mb-1.5 block">Full day after (minutes)</Label>
                <Input id="s-full" type="number" min="1" value={form.fullDayMinutes}
                  onChange={(e) => setForm((f) => ({ ...f, fullDayMinutes: Number(e.target.value) }))} />
              </div>
            </div>

            <div className="mt-3">
              <span className="mb-1.5 block text-sm font-medium text-ink-700">Week off</span>
              <div className="flex flex-wrap gap-1.5">
                {DAYS.map((d) => {
                  const on = form.weekOffDays.includes(d.n);
                  return (
                    <Button key={d.n} type="button" size="sm" variant={on ? 'primary' : 'secondary'}
                      onClick={() => setForm((f) => ({
                        ...f,
                        weekOffDays: on ? f.weekOffDays.filter((x) => x !== d.n) : [...f.weekOffDays, d.n],
                      }))}>
                      {d.label}
                    </Button>
                  );
                })}
              </div>
            </div>

            <div className="mt-4 flex justify-end gap-2">
              <Button variant="secondary" size="sm" onClick={onCancel} disabled={pending}>Back</Button>
              <Button size="sm" disabled={pending} onClick={() => onSubmit(form)}>
                {pending && <Loader2 className="animate-spin" aria-hidden />}
                Save shift
              </Button>
            </div>
          </div>
        </div>
  );
}

function LeavePanel({
  leaveTypes,
  canManage,
  onSaved,
}: {
  readonly leaveTypes: readonly LeaveType[];
  readonly canManage: boolean;
  readonly onSaved: (message: string) => void;
}) {
  const router = useRouter();
  const [editing, setEditing] = React.useState<LeaveType | 'new' | null>(null);
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);

  const submit = (form: LeaveForm) => {
    setError(null);
    startTransition(async () => {
      const result = await saveLeaveTypeAction({
        id: editing && editing !== 'new' ? editing.id : null,
        ...form,
      });
      if (!result.ok) {
        setError(result.error ?? 'The leave type could not be saved.');
        return;
      }
      setEditing(null);
      onSaved(result.message ?? 'Saved.');
      router.refresh();
    });
  };

  return (
    <Panel>
      <PanelHeader>
        <PanelTitle>Leave types</PanelTitle>
        {canManage && (
          <Button size="sm" variant="secondary" onClick={() => setEditing('new')}>
            <Plus aria-hidden />Add leave type
          </Button>
        )}
      </PanelHeader>
      <PanelContent className="px-0 pb-0">
        {leaveTypes.length === 0 ? (
          <p className="px-5 pb-5 text-sm text-ink-400">
            No leave types yet. Payroll reads these to know whether a day off is paid.
          </p>
        ) : (
          <SolidPanel className="rounded-none border-x-0 border-b-0">
            <div className="overflow-x-auto">
              <table className="w-full border-collapse text-sm">
                <caption className="sr-only">Leave types</caption>
                <thead>
                  <tr className="bg-ink-50">
                    <th scope="col" className="px-4 py-2 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Leave</th>
                    <th scope="col" className="px-4 py-2 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Quota / year</th>
                    <th scope="col" className="px-4 py-2 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Paid</th>
                    <th scope="col" className="px-4 py-2 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Carry forward</th>
                    {canManage && <th scope="col" className="px-4 py-2" />}
                  </tr>
                </thead>
                <tbody>
                  {leaveTypes.map((t) => (
                    <tr key={t.id} className="border-t border-ink-100">
                      <td className="px-4 py-2">
                        <span className="text-ink-800">{t.name}</span>
                        <span className="ml-2 font-mono text-[11px] text-ink-400">{t.code}</span>
                      </td>
                      <td className="numeric px-4 py-2 text-right">{t.annualQuota}</td>
                      <td className="px-4 py-2">
                        <Badge variant={t.isPaid ? 'positive' : 'warning'}>
                          {t.isPaid ? 'Paid' : 'Unpaid'}
                        </Badge>
                      </td>
                      <td className="px-4 py-2 text-ink-600">
                        {t.carryForward ? `up to ${t.maxCarryForward}` : <span className="text-ink-300">No</span>}
                      </td>
                      {canManage && (
                        <td className="px-4 py-2 text-right">
                          <Button variant="ghost" size="sm" onClick={() => setEditing(t)} aria-label={`Edit ${t.name}`}>
                            <Pencil aria-hidden />
                          </Button>
                        </td>
                      )}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </SolidPanel>
        )}
      </PanelContent>

      {editing && (
        <LeaveDialog
          key={editing === 'new' ? 'new' : editing.id}
          leaveType={editing === 'new' ? null : editing}
          error={error}
          pending={pending}
          onCancel={() => setEditing(null)}
          onSubmit={submit}
        />
      )}
    </Panel>
  );
}

interface LeaveForm {
  code: string;
  name: string;
  annualQuota: number;
  isPaid: boolean;
  carryForward: boolean;
  maxCarryForward: number;
  countsAsWorked: boolean;
}

function LeaveDialog({
  leaveType,
  error,
  pending,
  onCancel,
  onSubmit,
}: {
  readonly leaveType: LeaveType | null;
  readonly error: string | null;
  readonly pending: boolean;
  readonly onCancel: () => void;
  readonly onSubmit: (form: LeaveForm) => void;
}) {
  const [form, setForm] = React.useState<LeaveForm>(() =>
    leaveType
      ? {
          code: leaveType.code, name: leaveType.name, annualQuota: leaveType.annualQuota,
          isPaid: leaveType.isPaid, carryForward: leaveType.carryForward,
          maxCarryForward: leaveType.maxCarryForward, countsAsWorked: leaveType.countsAsWorked,
        }
      : {
          code: '', name: '', annualQuota: 0, isPaid: true,
          carryForward: false, maxCarryForward: 0, countsAsWorked: true,
        },
  );

  return (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
          role="dialog" aria-modal="true" onClick={onCancel}>
          <div className="glass-strong w-full max-w-lg rounded-2xl p-6" onClick={(e) => e.stopPropagation()}>
            <h2 className="text-sm font-semibold text-ink-900">
              {leaveType ? `Edit ${leaveType.name}` : 'Add a leave type'}
            </h2>

            {error && (
              <div role="alert" className="mt-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
                {error}
              </div>
            )}

            <div className="mt-4 grid gap-3 sm:grid-cols-2">
              <div>
                <Label htmlFor="l-code" className="mb-1.5 block">Code</Label>
                <Input id="l-code" value={form.code} disabled={leaveType !== null}
                  onChange={(e) => setForm((f) => ({ ...f, code: e.target.value }))} placeholder="CL" />
              </div>
              <div>
                <Label htmlFor="l-name" className="mb-1.5 block">Name</Label>
                <Input id="l-name" value={form.name}
                  onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))} placeholder="Casual leave" />
              </div>
              <div>
                <Label htmlFor="l-quota" className="mb-1.5 block">Days per year</Label>
                <Input id="l-quota" type="number" step="0.5" min="0" value={form.annualQuota}
                  onChange={(e) => setForm((f) => ({ ...f, annualQuota: Number(e.target.value) }))} />
              </div>
              {form.carryForward && (
                <div>
                  <Label htmlFor="l-carry" className="mb-1.5 block">Max carried forward</Label>
                  <Input id="l-carry" type="number" step="0.5" min="0" value={form.maxCarryForward}
                    onChange={(e) => setForm((f) => ({ ...f, maxCarryForward: Number(e.target.value) }))} />
                </div>
              )}
            </div>

            <div className="mt-3 space-y-2">
              <label className="flex items-center gap-2 text-sm text-ink-700">
                <input type="checkbox" checked={form.isPaid}
                  onChange={(e) => setForm((f) => ({ ...f, isPaid: e.target.checked }))} />
                Paid leave
              </label>
              <label className="flex items-center gap-2 text-sm text-ink-700">
                <input type="checkbox" checked={form.countsAsWorked}
                  onChange={(e) => setForm((f) => ({ ...f, countsAsWorked: e.target.checked }))} />
                Counts as a day worked for payroll
              </label>
              <label className="flex items-center gap-2 text-sm text-ink-700">
                <input type="checkbox" checked={form.carryForward}
                  onChange={(e) => setForm((f) => ({ ...f, carryForward: e.target.checked }))} />
                Unused days carry into next year
              </label>
            </div>

            <div className="mt-4 flex justify-end gap-2">
              <Button variant="secondary" size="sm" onClick={onCancel} disabled={pending}>Back</Button>
              <Button size="sm" disabled={pending} onClick={() => onSubmit(form)}>
                {pending && <Loader2 className="animate-spin" aria-hidden />}
                Save leave type
              </Button>
            </div>
          </div>
        </div>
  );
}
