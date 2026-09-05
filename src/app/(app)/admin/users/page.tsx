import type { Metadata } from 'next';

import { getUsers, getRoles, getBranches } from '@/server/services/org/org-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { UserManager } from '@/components/admin/user-manager';

export const metadata: Metadata = { title: 'Users' };
export const dynamic = 'force-dynamic';

/**
 * Spec §5, §6, §47. A login carries roles, which carry permissions; and branch
 * reach, which decides which branches' records it can see at all.
 */
export default async function UsersPage() {
  const context = await requirePermission('admin.users.view');

  const [users, roles, branches] = await Promise.all([getUsers(), getRoles(), getBranches()]);

  return (
    <div>
      <PageHeader
        title="Users"
        description="Logins, the roles that decide what they may do, and the branches they can reach."
        count={users.length}
      />
      <UserManager
        users={users}
        roles={roles.map((role) => ({ id: role.id, name: role.name, isSystem: role.is_system }))}
        branches={branches.map((branch) => ({ id: branch.id, code: branch.code, name: branch.name }))}
        canManage={hasPermission(context, 'admin.users.manage')}
        currentUserId={context.userId}
      />
    </div>
  );
}
