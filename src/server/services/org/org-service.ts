import 'server-only';

import { requirePermission, requireTenantContext } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import * as repository from '@/server/repositories/org-repository';

/**
 * Row shapes re-exported so pages can type their columns without importing the
 * repository directly — the ESLint boundary in `eslint.config.mjs` forbids that,
 * and an exception for type-only imports would erode a rule worth keeping sharp.
 */
export type {
  AuditRow,
  BranchRow,
  EmployeeRow,
  RoleWithPermissions,
  UserListRow,
} from '@/server/repositories/org-repository';

/**
 * Administration reads.
 *
 * Thin by design: each function asserts the permission, then delegates. The
 * permission check lives here rather than in the page so that a future route
 * handler or server action calling the same data cannot forget it (spec §57.3).
 */

export async function getBranches() {
  await requirePermission('admin.branches.view');
  return repository.listBranches();
}

export async function getUsers() {
  await requirePermission('admin.users.view');
  return repository.listUsers();
}

export async function getRoles() {
  await requirePermission('admin.roles.view');
  return repository.listRoles();
}

export async function getEmployees() {
  await requirePermission('masters.employees.view');
  return repository.listEmployees();
}

export async function getAuditLogs(limit?: number) {
  await requirePermission('admin.audit.view');
  return repository.listAuditLogs(limit);
}

export async function getSettings() {
  await requirePermission('admin.settings.view');
  const [settings, sequences] = await Promise.all([
    repository.listSettings(),
    repository.listDocumentSequences(),
  ]);
  return { settings, sequences };
}

export async function getDealerProfile() {
  await requirePermission('admin.dealers.view');
  return repository.getDealer();
}

/**
 * Reads one boolean setting that the application itself needs to behave
 * correctly, such as whether a counter sale requires a customer (spec §33).
 *
 * Deliberately not gated on `admin.settings.view`: a counter clerk has to know
 * the rule they are being held to, and these rows are flagged `is_public`
 * precisely so they can be read without administering anything.
 */
export async function getSetting(key: string): Promise<boolean> {
  await requireTenantContext();
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase
    .from('system_settings')
    .select('value')
    .eq('key', key)
    .eq('is_public', true)
    .maybeSingle();

  if (error) {
    console.error('[settings] read failed', error.message);
    return false;
  }
  return data?.value === true;
}
