import type { Metadata } from 'next';

import { getBranches } from '@/server/services/org/org-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { BranchManager } from '@/components/admin/branch-manager';

export const metadata: Metadata = { title: 'Branches' };
export const dynamic = 'force-dynamic';

/**
 * Spec §5, §36. Branch-level operational data — stock, sales, cash — is scoped
 * to these, so a branch is a boundary rather than a label.
 *
 * A platform administrator manages a tenant's branches from
 * Administration → Dealers instead, since they have no dealer of their own.
 */
export default async function BranchesPage() {
  const context = await requirePermission('admin.branches.view');
  const branches = await getBranches();

  return (
    <div>
      <PageHeader
        title="Branches"
        description="Each branch keeps its own stock, cash book and day close. A new one gets its cash account immediately."
        count={branches.length}
      />
      <BranchManager
        branches={branches}
        canManage={hasPermission(context, 'admin.branches.manage')}
      />
    </div>
  );
}
