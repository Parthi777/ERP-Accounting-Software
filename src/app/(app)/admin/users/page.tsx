import type { Metadata } from 'next';

import { getUsers } from '@/server/services/org/org-service';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Badge } from '@/components/ui/badge';
import { formatMobile, formatRelative } from '@/lib/format';
import type { UserListRow } from '@/server/services/org/org-service';

export const metadata: Metadata = { title: 'Users' };
export const dynamic = 'force-dynamic';

const columns: Column<UserListRow>[] = [
  {
    key: 'name',
    header: 'Name',
    render: (row) => (
      <span>
        <span className="block font-medium text-ink-900">{row.full_name}</span>
        <span className="block text-xs text-ink-500">{row.email}</span>
      </span>
    ),
  },
  {
    key: 'roles',
    header: 'Roles',
    render: (row) =>
      row.roles.length === 0 ? (
        <Badge variant="warning">No role</Badge>
      ) : (
        <span className="flex flex-wrap gap-1">
          {row.roles.map((role) => (
            <Badge key={role} variant="info">
              {role}
            </Badge>
          ))}
        </span>
      ),
  },
  { key: 'mobile', header: 'Mobile', render: (row) => formatMobile(row.mobile) },
  {
    key: 'branch_access',
    header: 'Branch access',
    render: (row) =>
      row.has_all_branch_access || row.is_platform_admin ? (
        <span className="text-ink-600">All branches</span>
      ) : (
        <span className="text-ink-500">Assigned only</span>
      ),
  },
  {
    key: 'status',
    header: 'Status',
    render: (row) => (
      <Badge variant={row.status === 'ACTIVE' ? 'positive' : 'danger'}>{row.status}</Badge>
    ),
  },
  {
    key: 'last_login',
    header: 'Last sign-in',
    render: (row) => (row.last_login_at ? formatRelative(row.last_login_at) : 'Never'),
  },
];

export default async function UsersPage() {
  const users = await getUsers();

  return (
    <div>
      <PageHeader
        title="Users"
        description="People with access to this dealer. Permissions come from the roles assigned here."
        count={users.length}
      />
      <DataTable
        columns={columns}
        rows={users}
        getRowKey={(row) => row.id}
        caption="Users"
        emptyMessage="No users are visible to your account."
      />
    </div>
  );
}
