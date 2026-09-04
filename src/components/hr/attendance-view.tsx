'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { CloudOff, Loader2, RefreshCw, TriangleAlert } from 'lucide-react';

import type { AttendanceOverview } from '@/server/services/hr/attendance-service';
import { mapEmployeeAction, syncAttendanceAction } from '@/server/services/hr/attendance-actions';
import { Panel, PanelContent, PanelHeader, PanelTitle, SolidPanel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Input, Label } from '@/components/ui/input';
import { formatDateTime, formatRelative } from '@/lib/format';

/**
 * The attendance register, mirrored from the external system — spec §12, §40.
 *
 * Two things are shown before the numbers, on purpose:
 *
 *   how stale the mirror is — because every figure below is only as good as the
 *   last successful pull, and a page that hides that invites someone to run
 *   payroll off a week-old register;
 *
 *   who is not mapped — because an unmapped employee's attendance can never
 *   arrive at all. They read as absent for the whole month, and nothing else on
 *   this screen would tell you why.
 */
export function AttendanceView({ overview }: { readonly overview: AttendanceOverview }) {
  const router = useRouter();
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);

  const sync = () => {
    setError(null);
    setNotice(null);
    startTransition(async () => {
      const result = await syncAttendanceAction({ from: overview.from, to: overview.to });
      if (!result.ok) {
        setError(result.error ?? 'The sync failed.');
      } else {
        setNotice(result.message ?? 'Synced.');
      }
      router.refresh();
    });
  };

  const run = overview.lastRun;

  return (
    <div className="space-y-4">
      {!overview.connected && (
        <Panel className="p-4">
          <p className="flex items-start gap-2 text-sm text-ink-700">
            <CloudOff className="mt-0.5 size-4 shrink-0 text-ink-400" aria-hidden />
            <span>
              <span className="font-medium">No attendance system is connected.</span> Set{' '}
              <code className="rounded bg-ink-100 px-1 text-xs">ATTENDANCE_API_BASE_URL</code> and{' '}
              <code className="rounded bg-ink-100 px-1 text-xs">ATTENDANCE_API_KEY</code> in the
              environment. Days already mirrored stay readable; nothing new arrives until then.
            </span>
          </p>
        </Panel>
      )}

      {error && (
        <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
          {error}
        </div>
      )}
      {notice && (
        <div role="status" className="rounded-lg border border-positive-200 bg-positive-50 px-3 py-2 text-sm text-positive-700">
          {notice}
        </div>
      )}

      <Panel className="p-4">
        <div className="flex flex-wrap items-center gap-x-6 gap-y-3">
          <div>
            <p className="text-xs text-ink-500">Mirror last updated</p>
            <p className="mt-0.5 text-sm font-semibold text-ink-800">
              {run?.finishedAt
                ? `${formatRelative(run.finishedAt)} · ${formatDateTime(run.finishedAt)}`
                : 'Never synced'}
            </p>
          </div>

          {run && (
            <div>
              <p className="text-xs text-ink-500">Last run</p>
              <p className="mt-0.5">
                <Badge
                  variant={
                    run.status === 'SUCCESS' ? 'positive'
                    : run.status === 'PARTIAL' ? 'warning'
                    : run.status === 'FAILED' ? 'danger'
                    : 'info'
                  }
                >
                  {run.status}
                </Badge>
                <span className="ml-2 text-xs text-ink-500">
                  {run.writtenCount} written · {run.unmatchedCount} unmatched
                  {run.skippedManualCount > 0 ? ` · ${run.skippedManualCount} kept as corrected` : ''}
                </span>
              </p>
            </div>
          )}

          {overview.canSync && (
            <Button className="ml-auto" size="sm" disabled={pending || !overview.connected} onClick={sync}>
              {pending ? <Loader2 className="animate-spin" aria-hidden /> : <RefreshCw aria-hidden />}
              {pending ? 'Syncing…' : 'Sync this period'}
            </Button>
          )}
        </div>

        {run?.lastError && (
          <p className="mt-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-xs text-danger-700">
            Last error: {run.lastError} — the figures below are from the sync before it.
          </p>
        )}
      </Panel>

      {overview.unmapped.length > 0 && (
        <UnmappedPanel employees={overview.unmapped} canMap={overview.canMap} />
      )}

      <SolidPanel className="overflow-hidden">
        <div className="table-sticky overflow-auto" style={{ maxHeight: '40rem' }}>
          <table className="w-full border-collapse text-sm">
            <caption className="sr-only">Attendance register</caption>
            <thead>
              <tr>
                <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Employee</th>
                <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Present</th>
                <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Leave</th>
                <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Absent</th>
                <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Off / holiday</th>
                <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Late</th>
                <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">OT</th>
                <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Payable days</th>
              </tr>
            </thead>
            <tbody>
              {overview.summary.length === 0 ? (
                <tr>
                  <td colSpan={8} className="px-4 py-12 text-center text-sm text-ink-400">
                    No employees to show for this period.
                  </td>
                </tr>
              ) : (
                overview.summary.map((row) => (
                  <tr key={row.employeeId} className="border-t border-ink-100 hover:bg-brand-50/40">
                    <td className="px-4 py-2">
                      <span className="block text-ink-800">{row.employeeName}</span>
                      <span className="block font-mono text-[11px] text-ink-400">
                        {row.employeeCode} · {row.branchName}
                      </span>
                    </td>
                    <td className="numeric px-4 py-2 text-right">{row.presentDays}</td>
                    <td className="numeric px-4 py-2 text-right text-ink-600">
                      {row.leaveDays > 0 ? row.leaveDays : <span className="text-ink-300">—</span>}
                    </td>
                    <td className="numeric px-4 py-2 text-right">
                      {row.absentDays > 0
                        ? <span className="font-medium text-danger-700">{row.absentDays}</span>
                        : <span className="text-ink-300">—</span>}
                    </td>
                    <td className="numeric px-4 py-2 text-right text-ink-500">
                      {row.weekOffDays + row.holidayDays}
                    </td>
                    <td className="numeric px-4 py-2 text-right text-ink-500">
                      {row.lateCount > 0 ? row.lateCount : <span className="text-ink-300">—</span>}
                    </td>
                    <td className="numeric px-4 py-2 text-right text-ink-500">
                      {row.overtimeMinutes > 0 ? `${Math.round(row.overtimeMinutes / 60)}h` : <span className="text-ink-300">—</span>}
                    </td>
                    <td className="numeric px-4 py-2 text-right font-medium text-ink-900">
                      {/* Nothing recorded at all is not "zero days worked" — it is
                          a gap, and payroll must not silently pay nothing for it. */}
                      {row.recordedDays === 0
                        ? <span className="text-warning-700" title="No attendance recorded for this period">No data</span>
                        : row.payableDays}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </SolidPanel>

      {overview.recentRuns.length > 0 && (
        <Panel>
          <PanelHeader><PanelTitle>Recent syncs</PanelTitle></PanelHeader>
          <PanelContent>
            <ul className="space-y-1.5">
              {overview.recentRuns.map((r) => (
                <li key={r.id} className="flex flex-wrap items-center gap-2 text-xs">
                  <Badge
                    variant={
                      r.status === 'SUCCESS' ? 'positive'
                      : r.status === 'PARTIAL' ? 'warning'
                      : r.status === 'FAILED' ? 'danger'
                      : 'info'
                    }
                  >
                    {r.status}
                  </Badge>
                  <span className="text-ink-600">{r.fromDate} → {r.toDate}</span>
                  <span className="text-ink-400">
                    {r.writtenCount} written, {r.unmatchedCount} unmatched
                  </span>
                  <span className="ml-auto text-ink-400">
                    {r.finishedAt ? formatRelative(r.finishedAt) : 'running'}
                  </span>
                </li>
              ))}
            </ul>
          </PanelContent>
        </Panel>
      )}
    </div>
  );
}

/**
 * Employees the external system cannot be matched to.
 *
 * Worth its own panel because the failure is silent: an unmapped employee simply
 * has no attendance, which reads as a month of absence rather than as a missing
 * mapping.
 */
function UnmappedPanel({
  employees,
  canMap,
}: {
  readonly employees: AttendanceOverview['unmapped'];
  readonly canMap: boolean;
}) {
  const router = useRouter();
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [refs, setRefs] = React.useState<Record<string, string>>({});

  const save = (employeeId: string) => {
    setError(null);
    startTransition(async () => {
      const result = await mapEmployeeAction({
        employeeId,
        externalRef: refs[employeeId] ?? null,
      });
      if (!result.ok) {
        setError(result.error ?? 'The mapping could not be saved.');
        return;
      }
      router.refresh();
    });
  };

  return (
    <Panel>
      <PanelHeader>
        <PanelTitle>
          <span className="flex items-center gap-2">
            <TriangleAlert className="size-4 text-warning-600" aria-hidden />
            {employees.length} employee{employees.length === 1 ? '' : 's'} not mapped
          </span>
        </PanelTitle>
      </PanelHeader>
      <PanelContent>
        <p className="mb-3 text-xs text-ink-500">
          Attendance is matched by the id the external system uses for each person — never by name,
          because a near-match would attribute one person&rsquo;s attendance to another. Until these
          are mapped they will show as absent for every day.
        </p>

        {error && (
          <div role="alert" className="mb-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
            {error}
          </div>
        )}

        <ul className="space-y-2">
          {employees.slice(0, 25).map((e) => (
            <li key={e.id} className="flex flex-wrap items-center gap-2 rounded-lg border border-ink-200 px-3 py-2">
              <span className="min-w-0 flex-1">
                <span className="block text-sm text-ink-800">{e.name}</span>
                <span className="block font-mono text-[11px] text-ink-400">
                  {e.employeeCode} · {e.branchName}
                </span>
              </span>
              {canMap && (
                <>
                  <Label htmlFor={`ref-${e.id}`} className="sr-only">
                    External reference for {e.name}
                  </Label>
                  <Input
                    id={`ref-${e.id}`}
                    className="h-8 w-48"
                    placeholder="Their id in the attendance app"
                    value={refs[e.id] ?? ''}
                    onChange={(event) => setRefs((c) => ({ ...c, [e.id]: event.target.value }))}
                  />
                  <Button
                    size="sm"
                    variant="secondary"
                    disabled={pending || !(refs[e.id] ?? '').trim()}
                    onClick={() => save(e.id)}
                  >
                    Map
                  </Button>
                </>
              )}
            </li>
          ))}
        </ul>

        {employees.length > 25 && (
          <p className="mt-2 text-[11px] text-ink-400">
            {employees.length - 25} more not shown.
          </p>
        )}
      </PanelContent>
    </Panel>
  );
}
