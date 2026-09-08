import 'server-only';

import { requirePermission, requireTenantContext } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import * as repository from '@/server/repositories/org-repository';
import { EXPECTED_SCHEMA_VERSION } from '@/config/schema';

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
  const [settings, sequences, schema] = await Promise.all([
    repository.listSettings(),
    repository.listDocumentSequences(),
    getSchemaStatus(),
  ]);
  return { settings, sequences, schema };
}

/**
 * How the database's schema compares to the one this build expects.
 *
 * The application deploys on push while migrations are applied to Supabase by
 * hand, so the two drift, and until now nothing said so. The symptom reached a
 * user as a PostgREST error naming a function signature — no cause, no action,
 * and seen by the person least able to fix it.
 *
 * `tracked: false` is deliberately not folded into `behind`. A database applied
 * before 0059 has no record of itself, and "we cannot tell" is a different
 * answer from "it is current" — reporting the second when the first is true is
 * exactly the reassurance this is meant to remove.
 */
export interface SchemaStatus {
  /** The migration this build was written against. */
  readonly expected: string;
  /** The highest migration the database reports, or null when untracked. */
  readonly applied: string | null;
  /** Whether the database records its own version at all (0059 onwards). */
  readonly tracked: boolean;
  /** Versions the application expects that the database does not report. */
  readonly missing: string[];
  /** When the last recorded migration was applied. */
  readonly appliedAt: string | null;
}

export async function getSchemaStatus(): Promise<SchemaStatus> {
  const rows = await repository.listSchemaMigrations();

  if (rows === null) {
    return {
      expected: EXPECTED_SCHEMA_VERSION,
      applied: null,
      tracked: false,
      missing: [],
      appliedAt: null,
    };
  }

  const present = new Set(rows.map((row) => row.version));
  const applied = rows[0]?.version ?? null;

  // Every version from 0001 up to what this build expects. Names are not known
  // here — the running app ships no copy of the migrations directory — but the
  // numbers are enough to act on, and enough to paste into a search.
  const missing: string[] = [];
  for (let n = 1; n <= Number(EXPECTED_SCHEMA_VERSION); n += 1) {
    const version = String(n).padStart(4, '0');
    if (!present.has(version)) {
      missing.push(version);
    }
  }

  return {
    expected: EXPECTED_SCHEMA_VERSION,
    applied,
    tracked: true,
    missing,
    appliedAt: rows[0]?.applied_at ?? null,
  };
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
