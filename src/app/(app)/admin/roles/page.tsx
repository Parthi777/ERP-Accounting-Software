import type { Metadata } from 'next';
import { Lock } from 'lucide-react';

import { getRoles } from '@/server/services/org/org-service';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Badge } from '@/components/ui/badge';
import { Panel } from '@/components/ui/panel';
import { PERMISSIONS } from '@/lib/permissions/registry';
import type { RoleWithPermissions } from '@/server/services/org/org-service';

export const metadata: Metadata = { title: 'Roles & Permissions' };
export const dynamic = 'force-dynamic';

const columns: Column<RoleWithPermissions>[] = [
  {
    key: 'name',
    header: 'Role',
    render: (row) => (
      <span>
        <span className="flex items-center gap-2 font-medium text-ink-900">
          {row.name}
          {row.is_system && <Badge variant="neutral">System</Badge>}
        </span>
        <span className="block font-mono text-xs text-ink-400">{row.code}</span>
      </span>
    ),
  },
  {
    key: 'description',
    header: 'Description',
    render: (row) => <span className="text-ink-600">{row.description ?? '—'}</span>,
  },
  {
    key: 'permissions',
    header: 'Permissions',
    numeric: true,
    render: (row) => row.permissionCount,
  },
  {
    key: 'sensitive',
    header: 'Restricted',
    numeric: true,
    render: (row) =>
      row.sensitiveCount > 0 ? (
        <span className="inline-flex items-center gap-1 text-warning-700">
          <Lock className="size-3" aria-hidden />
          {row.sensitiveCount}
        </span>
      ) : (
        <span className="text-ink-400">0</span>
      ),
  },
];

export default async function RolesPage() {
  const roles = await getRoles();
  const sensitive = PERMISSIONS.filter((permission) => 'sensitive' in permission);

  return (
    <div className="space-y-5">
      <div>
        <PageHeader
          title="Roles & Permissions"
          description="Authorization is permission-based. Roles bundle permission codes, so a dealer can define its own without a code change."
          count={roles.length}
        />
        <DataTable
          columns={columns}
          rows={roles}
          getRowKey={(row) => row.id}
          caption="Roles"
          emptyMessage="No roles are visible to your account."
        />
      </div>

      <Panel className="p-5">
        <h2 className="flex items-center gap-2 text-sm font-semibold text-ink-900">
          <Lock className="size-4 text-warning-600" aria-hidden />
          Restricted permissions
        </h2>
        <p className="mt-1 text-sm text-ink-600">
          These gate purchase cost, COGS, margin, profit and commission. A role without them does not
          merely have the fields hidden — the server strips them from the response before it is sent.
        </p>
        <ul className="mt-3 grid gap-2 sm:grid-cols-2">
          {sensitive.map((permission) => (
            <li
              key={permission.code}
              className="rounded-lg border border-warning-200 bg-warning-50/60 px-3 py-2"
            >
              <code className="block font-mono text-xs text-warning-700">{permission.code}</code>
              <span className="mt-0.5 block text-xs text-ink-600">{permission.description}</span>
            </li>
          ))}
        </ul>
      </Panel>

      <Panel className="p-5">
        <h2 className="text-sm font-semibold text-ink-900">Permission catalogue</h2>
        <p className="mt-1 text-sm text-ink-600">
          {PERMISSIONS.length} permissions across {new Set(PERMISSIONS.map((p) => p.module)).size}{' '}
          modules. Defined in{' '}
          <code className="rounded bg-ink-100 px-1 py-0.5 text-xs">
            src/lib/permissions/registry.ts
          </code>{' '}
          and seeded into the database; <code className="text-xs">npm run check:permissions</code>{' '}
          fails the build if the two drift apart.
        </p>
      </Panel>
    </div>
  );
}
