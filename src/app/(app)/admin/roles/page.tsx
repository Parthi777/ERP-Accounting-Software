import type { Metadata } from 'next';

import { getRoles } from '@/server/services/org/org-service';
import { PERMISSION_CATALOGUE } from '@/server/services/org/admin-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { RoleManager } from '@/components/admin/role-manager';

export const metadata: Metadata = { title: 'Roles & Permissions' };
export const dynamic = 'force-dynamic';

/**
 * Spec §6, §47. Authorization is permission-based, never role-name-based — a
 * role is a bundle of codes, so a dealer can invent their own without a code
 * change and no check anywhere reads "is this user a Cashier?".
 */
export default async function RolesPage() {
  const context = await requirePermission('admin.roles.view');
  const roles = await getRoles();

  return (
    <div>
      <PageHeader
        title="Roles & Permissions"
        description="What each role may do. Assign these to users under Administration → Users."
        count={roles.length}
      />
      <RoleManager
        roles={roles}
        catalogue={PERMISSION_CATALOGUE}
        canManage={hasPermission(context, 'admin.roles.manage')}
      />
    </div>
  );
}
