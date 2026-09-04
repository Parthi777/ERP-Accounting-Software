import type { Metadata } from 'next';
import Link from 'next/link';
import { Settings2 } from 'lucide-react';

import { getEmployees, type EmployeeListRow } from '@/server/services/hr/hr-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatDate, formatMobile } from '@/lib/format';

export const metadata: Metadata = { title: 'Employees' };
export const dynamic = 'force-dynamic';

const VIEWS = [
  { value: 'ACTIVE', label: 'Active' },
  { value: 'ON_LEAVE', label: 'On leave' },
  { value: 'RESIGNED', label: 'Resigned' },
  { value: 'TERMINATED', label: 'Terminated' },
  { value: 'ALL', label: 'Everyone' },
];

const TONE: Record<string, 'positive' | 'warning' | 'neutral' | 'danger'> = {
  ACTIVE: 'positive',
  ON_LEAVE: 'warning',
  RESIGNED: 'neutral',
  TERMINATED: 'danger',
};

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ status?: string; q?: string }>;
}) {
  const context = await requirePermission('masters.employees.view');
  const params = await searchParams;
  const status = params.status ?? 'ACTIVE';

  const rows = await getEmployees({ status, q: params.q });
  const canConfigure = hasPermission(context, 'hr.settings.manage');

  const columns: Column<EmployeeListRow>[] = [
    {
      key: 'employee',
      header: 'Employee',
      render: (row) => (
        <span>
          <Link href={`/hr/${row.id}`} className="block font-medium text-brand-600 hover:underline">
            {row.name}
          </Link>
          <span className="block font-mono text-[11px] text-ink-400">{row.employeeCode}</span>
        </span>
      ),
    },
    {
      key: 'role',
      header: 'Role',
      render: (row) => (
        <span>
          <span className="block text-ink-700">{row.designation ?? '—'}</span>
          <span className="block text-[11px] text-ink-400">{row.department ?? '—'}</span>
        </span>
      ),
    },
    { key: 'branch', header: 'Branch', render: (row) => row.branchName },
    {
      key: 'shift',
      header: 'Shift',
      render: (row) => row.shiftName ?? <span className="text-ink-300">Not assigned</span>,
    },
    {
      key: 'type',
      header: 'Type',
      render: (row) => <Badge variant="neutral">{row.employmentType.replace(/_/g, ' ')}</Badge>,
    },
    {
      key: 'joined',
      header: 'Joined',
      render: (row) => (row.joiningDate ? formatDate(row.joiningDate) : <span className="text-ink-300">—</span>),
    },
    {
      key: 'mobile',
      header: 'Mobile',
      render: (row) => (row.mobile ? formatMobile(row.mobile) : <span className="text-ink-300">—</span>),
    },
    {
      key: 'status',
      header: 'Status',
      render: (row) => <Badge variant={TONE[row.status] ?? 'neutral'}>{row.status.replace(/_/g, ' ')}</Badge>,
    },
  ];

  const unassigned = rows.filter((r) => !r.shiftName).length;

  return (
    <>
      <PageHeader
        title="Employees"
        description="The HR record behind the employee master: shifts, pay, leave and documents (spec §12)."
        count={rows.length}
        action={
          canConfigure ? (
            <Button variant="secondary" asChild>
              <Link href="/hr/settings"><Settings2 aria-hidden />Shifts &amp; leave</Link>
            </Button>
          ) : null
        }
      />

      {unassigned > 0 && status === 'ACTIVE' && (
        // Attendance measures a day against a shift, so this is the thing to fix
        // before that module can do anything useful.
        <Panel className="mb-4 flex flex-wrap items-center gap-3 p-4">
          <Badge variant="warning">{unassigned} without a shift</Badge>
          <span className="text-sm text-ink-600">
            Attendance measures each day against the employee&rsquo;s shift, so anyone without one
            cannot be marked late, early or absent.
          </span>
        </Panel>
      )}

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div>
            <label htmlFor="status" className="mb-1.5 block text-xs font-medium text-ink-600">Showing</label>
            <select id="status" name="status" defaultValue={status}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
              {VIEWS.map((v) => <option key={v.value} value={v.value}>{v.label}</option>)}
            </select>
          </div>
          <div className="min-w-48 flex-1">
            <label htmlFor="q" className="mb-1.5 block text-xs font-medium text-ink-600">Search</label>
            <input id="q" name="q" defaultValue={params.q ?? ''}
              placeholder="Name, code, mobile or department"
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" />
          </div>
          <Button type="submit" variant="secondary" size="sm">Filter</Button>
        </form>
      </Panel>

      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.id}
        emptyMessage="No employees match. Add them under Masters → Employees."
        caption="Employees"
      />
    </>
  );
}
