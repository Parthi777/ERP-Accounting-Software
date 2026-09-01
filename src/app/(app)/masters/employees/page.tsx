import type { Metadata } from 'next';

import { getEmployees } from '@/server/services/org/org-service';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Badge } from '@/components/ui/badge';
import { formatDate, formatMobile } from '@/lib/format';
import type { EmployeeRow } from '@/server/services/org/org-service';

export const metadata: Metadata = { title: 'Employees' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'warning' | 'danger' | 'neutral'> = {
  ACTIVE: 'positive',
  ON_LEAVE: 'warning',
  RESIGNED: 'neutral',
  TERMINATED: 'danger',
};

const columns: Column<EmployeeRow>[] = [
  {
    key: 'code',
    header: 'Employee ID',
    render: (row) => <span className="font-mono text-xs text-ink-600">{row.employee_code}</span>,
  },
  {
    key: 'name',
    header: 'Name',
    render: (row) => <span className="font-medium text-ink-900">{row.name}</span>,
  },
  { key: 'branch', header: 'Branch', render: (row) => row.branch ?? '—' },
  { key: 'department', header: 'Department', render: (row) => row.department ?? '—' },
  { key: 'designation', header: 'Designation', render: (row) => row.designation ?? '—' },
  { key: 'mobile', header: 'Mobile', render: (row) => formatMobile(row.mobile) },
  { key: 'joined', header: 'Joined', render: (row) => formatDate(row.joining_date) },
  {
    key: 'status',
    header: 'Status',
    render: (row) => (
      <Badge variant={STATUS_TONE[row.status] ?? 'neutral'}>{row.status.replace('_', ' ')}</Badge>
    ),
  },
];

export default async function EmployeesPage() {
  const employees = await getEmployees();

  return (
    <div>
      <PageHeader
        title="Employees"
        description="Employee ID is mandatory and unique per dealer. Operational transactions retain employee attribution."
        count={employees.length}
      />
      <DataTable
        columns={columns}
        rows={employees}
        getRowKey={(row) => row.id}
        caption="Employees"
        emptyMessage="No employees are visible to your account."
      />
    </div>
  );
}
