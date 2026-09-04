import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ArrowLeft, TriangleAlert } from 'lucide-react';

import { getEmployee, getShifts } from '@/server/services/hr/hr-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { SalaryPanel } from '@/components/hr/salary-panel';
import { Panel, PanelContent, PanelHeader, PanelTitle, SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatDate, formatMobile } from '@/lib/format';

export const metadata: Metadata = { title: 'Employee' };
export const dynamic = 'force-dynamic';

const TONE: Record<string, 'positive' | 'warning' | 'neutral' | 'danger'> = {
  ACTIVE: 'positive',
  ON_LEAVE: 'warning',
  RESIGNED: 'neutral',
  TERMINATED: 'danger',
};

export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  await requirePermission('masters.employees.view');
  const { id } = await params;

  const [employee, shifts] = await Promise.all([getEmployee(id), getShifts()]);
  if (!employee) {
    notFound();
  }

  const shift = shifts.find((s) => s.id === employee.shiftId) ?? null;
  const expiring = employee.documents.filter(
    (d) => d.expiresInDays !== null && d.expiresInDays <= 60,
  );

  return (
    <div>
      <Button variant="ghost" size="sm" asChild className="-ml-2 mb-2">
        <Link href="/hr"><ArrowLeft aria-hidden />Employees</Link>
      </Button>

      <div className="mb-4 flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <h1 className="text-xl font-bold tracking-tight text-ink-900">{employee.name}</h1>
            <Badge variant={TONE[employee.status] ?? 'neutral'}>{employee.status.replace(/_/g, ' ')}</Badge>
            <Badge variant="neutral">{employee.employmentType.replace(/_/g, ' ')}</Badge>
          </div>
          <p className="mt-0.5 text-sm text-ink-500">
            <span className="font-mono">{employee.employeeCode}</span>
            {employee.designation ? ` · ${employee.designation}` : ''}
            {employee.department ? ` · ${employee.department}` : ''} · {employee.branchName}
          </p>
        </div>
      </div>

      {expiring.length > 0 && (
        // The column that earns the document register: a lapsed licence is a
        // liability nobody notices until someone looks.
        <Panel className="mb-4 flex flex-wrap items-center gap-3 p-4">
          <Badge variant="danger">
            <TriangleAlert aria-hidden className="size-3.5" />
            {expiring.length} document{expiring.length === 1 ? '' : 's'} expiring
          </Badge>
          <span className="text-sm text-ink-600">
            {expiring.map((d) => d.documentName).join(', ')} —{' '}
            {expiring.some((d) => (d.expiresInDays ?? 0) < 0) ? 'some have already lapsed.' : 'due within 60 days.'}
          </span>
        </Panel>
      )}

      <div className="grid gap-4 lg:grid-cols-3">
        <div className="space-y-4 lg:col-span-2">
          <SalaryPanel
            employeeId={employee.id}
            history={employee.salaryHistory}
            canSee={employee.canSeeSalary}
            canManage={employee.canManageSalary}
          />

          <Panel>
            <PanelHeader><PanelTitle>Leave balances</PanelTitle></PanelHeader>
            <PanelContent className="px-0 pb-0">
              {employee.leaveBalances.length === 0 ? (
                <p className="px-5 pb-5 text-sm text-ink-400">
                  No leave has been allotted yet. Attendance will draw on these balances when leave
                  is approved.
                </p>
              ) : (
                <SolidPanel className="rounded-none border-x-0 border-b-0">
                  <table className="w-full border-collapse text-sm">
                    <caption className="sr-only">Leave balances</caption>
                    <thead>
                      <tr className="bg-ink-50">
                        <th scope="col" className="px-4 py-2 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Leave</th>
                        <th scope="col" className="px-4 py-2 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Year</th>
                        <th scope="col" className="px-4 py-2 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Opening</th>
                        <th scope="col" className="px-4 py-2 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Accrued</th>
                        <th scope="col" className="px-4 py-2 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Used</th>
                        <th scope="col" className="px-4 py-2 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Balance</th>
                      </tr>
                    </thead>
                    <tbody>
                      {employee.leaveBalances.map((b) => (
                        <tr key={b.id} className="border-t border-ink-100">
                          <td className="px-4 py-2">
                            <span className="text-ink-800">{b.leaveTypeName}</span>
                            <span className="ml-2 font-mono text-[11px] text-ink-400">{b.leaveTypeCode}</span>
                          </td>
                          <td className="numeric px-4 py-2 text-right text-ink-500">{b.financialYear}</td>
                          <td className="numeric px-4 py-2 text-right">{b.opening}</td>
                          <td className="numeric px-4 py-2 text-right">{b.accrued}</td>
                          <td className="numeric px-4 py-2 text-right text-ink-500">{b.used}</td>
                          <td className="numeric px-4 py-2 text-right font-medium text-ink-900">{b.balance}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </SolidPanel>
              )}
            </PanelContent>
          </Panel>

          <Panel>
            <PanelHeader><PanelTitle>Documents</PanelTitle></PanelHeader>
            <PanelContent>
              {employee.documents.length === 0 ? (
                <p className="text-sm text-ink-400">Nothing on file.</p>
              ) : (
                <ul className="space-y-2">
                  {employee.documents.map((d) => (
                    <li key={d.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-ink-200 px-3 py-2">
                      <span className="min-w-0">
                        <span className="block text-sm text-ink-800">{d.documentName}</span>
                        <span className="block text-[11px] text-ink-400">
                          {d.documentType.replace(/_/g, ' ')}
                          {d.documentNo ? ` · ${d.documentNo}` : ''}
                          {d.issuedOn ? ` · issued ${formatDate(d.issuedOn)}` : ''}
                        </span>
                      </span>
                      {d.expiresOn && (
                        <Badge
                          variant={
                            (d.expiresInDays ?? 0) < 0 ? 'danger'
                            : (d.expiresInDays ?? 0) <= 60 ? 'warning'
                            : 'neutral'
                          }
                        >
                          {(d.expiresInDays ?? 0) < 0 ? 'Lapsed ' : 'Expires '}
                          {formatDate(d.expiresOn)}
                        </Badge>
                      )}
                    </li>
                  ))}
                </ul>
              )}
            </PanelContent>
          </Panel>
        </div>

        <div className="space-y-4">
          <Panel>
            <PanelHeader><PanelTitle>Employment</PanelTitle></PanelHeader>
            <PanelContent>
              <dl className="space-y-2.5">
                <Row label="Joined" value={employee.joiningDate ? formatDate(employee.joiningDate) : '—'} />
                <Row label="Shift" value={shift ? `${shift.name} · ${shift.startsAt.slice(0, 5)}–${shift.endsAt.slice(0, 5)}` : 'Not assigned'} />
                <Row label="Reports to" value={employee.reportsToName ?? '—'} />
                <Row label="Probation until" value={employee.probationUntil ? formatDate(employee.probationUntil) : '—'} />
                <Row label="Confirmed" value={employee.confirmedOn ? formatDate(employee.confirmedOn) : '—'} />
                {employee.leavingDate && (
                  <Row label="Left" value={`${formatDate(employee.leavingDate)}${employee.exitType ? ` · ${employee.exitType.replace(/_/g, ' ')}` : ''}`} />
                )}
              </dl>
            </PanelContent>
          </Panel>

          <Panel>
            <PanelHeader><PanelTitle>Personal</PanelTitle></PanelHeader>
            <PanelContent>
              <dl className="space-y-2.5">
                <Row label="Mobile" value={employee.mobile ? formatMobile(employee.mobile) : '—'} />
                <Row label="Email" value={employee.email ?? employee.personalEmail ?? '—'} />
                <Row label="Date of birth" value={employee.dateOfBirth ? formatDate(employee.dateOfBirth) : '—'} />
                <Row label="Blood group" value={employee.bloodGroup ?? '—'} />
                <Row
                  label="Emergency"
                  value={
                    employee.emergencyContact
                      ? `${employee.emergencyContact}${employee.emergencyMobile ? ` · ${formatMobile(employee.emergencyMobile)}` : ''}`
                      : '—'
                  }
                />
                <Row label="City" value={[employee.city, employee.state].filter(Boolean).join(', ') || '—'} />
              </dl>
            </PanelContent>
          </Panel>

          <Panel>
            <PanelHeader><PanelTitle>Statutory</PanelTitle></PanelHeader>
            <PanelContent>
              <dl className="space-y-2.5">
                <Row label="PAN" value={employee.pan ?? '—'} />
                {/* Only the last four are held: the full number is not the
                    dealer's to keep, and four digits confirm a sighted document. */}
                <Row label="Aadhaar" value={employee.aadhaarLast4 ? `•••• •••• ${employee.aadhaarLast4}` : '—'} />
                <Row label="UAN" value={employee.uan ?? '—'} />
                <Row label="ESI" value={employee.esiNumber ?? '—'} />
                <Row label="Bank" value={employee.bankIfsc ? `${employee.bankAccountNo ?? '—'} · ${employee.bankIfsc}` : '—'} />
              </dl>
            </PanelContent>
          </Panel>
        </div>
      </div>
    </div>
  );
}

function Row({ label, value }: { readonly label: string; readonly value: string }) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <dt className="shrink-0 text-xs text-ink-500">{label}</dt>
      <dd className="text-right text-sm text-ink-800">{value}</dd>
    </div>
  );
}
