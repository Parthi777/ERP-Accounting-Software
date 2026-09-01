import { redirect } from 'next/navigation';

import { getTenantContext } from '@/server/auth/tenant-context';
import { visibleNavigation } from '@/config/navigation';
import { AppShell } from '@/components/layout/app-shell';

/**
 * Nothing under this layout can be statically generated: every page depends on
 * who is asking. Declaring it here covers the whole segment, so a new module page
 * cannot accidentally be prerendered — which would either bake one tenant's data
 * into the build output or fail the build outright.
 */
export const dynamic = 'force-dynamic';

/**
 * Authenticated layout.
 *
 * Navigation is filtered here, on the server, before any of it reaches the
 * browser. The client never receives the full menu and hides parts of it — it
 * receives only what this session is entitled to see (spec §6, §47).
 */
export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const context = await getTenantContext();

  if (!context) {
    redirect('/login');
  }

  const sections = visibleNavigation((permission) => context.permissions.has(permission));

  return (
    <AppShell
      user={{
        name: context.fullName,
        email: context.email,
        roleLabel: roleLabel(context.roles, context.isPlatformAdmin),
      }}
      dealerName={context.dealerName}
      sections={sections}
      branches={context.accessibleBranches.map((branch) => ({
        id: branch.id,
        code: branch.code,
        name: branch.name,
      }))}
      activeBranchId={context.activeBranch?.id ?? null}
    >
      {children}
    </AppShell>
  );
}

/** Human-readable role for the user chip. Multiple roles show the first plus a count. */
function roleLabel(roles: readonly string[], isPlatformAdmin: boolean): string {
  if (isPlatformAdmin) {
    return 'Platform Admin';
  }
  if (roles.length === 0) {
    return 'No role assigned';
  }

  const pretty = (code: string) =>
    code
      .toLowerCase()
      .split('_')
      .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
      .join(' ');

  return roles.length === 1
    ? pretty(roles[0]!)
    : `${pretty(roles[0]!)} +${roles.length - 1}`;
}
