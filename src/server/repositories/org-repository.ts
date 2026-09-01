import 'server-only';

import { createSupabaseServerClient } from '@/lib/supabase/server';
import type { Tables } from '@/types/database.types';

/**
 * Organization, identity and audit reads.
 *
 * Every query here relies on RLS for tenant scoping rather than adding a
 * `dealer_id` filter of its own. That is deliberate: a filter the application
 * forgets is a leak, whereas a policy the application forgets is still enforced
 * (spec §4, §47).
 */

export type BranchRow = Pick<
  Tables<'branches'>,
  'id' | 'code' | 'name' | 'city' | 'state' | 'gstin' | 'is_head_office' | 'status' | 'created_at'
>;

export async function listBranches(): Promise<BranchRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from('branches')
    .select('id, code, name, city, state, gstin, is_head_office, status, created_at')
    .order('is_head_office', { ascending: false })
    .order('name');

  if (error) {
    throw new Error(`Failed to load branches: ${error.message}`);
  }
  return data ?? [];
}

export interface UserListRow {
  readonly id: string;
  readonly full_name: string;
  readonly email: string;
  readonly mobile: string | null;
  readonly status: string;
  readonly has_all_branch_access: boolean;
  readonly is_platform_admin: boolean;
  readonly last_login_at: string | null;
  readonly roles: readonly string[];
}

export async function listUsers(): Promise<UserListRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from('user_profiles')
    .select(
      'id, full_name, email, mobile, status, has_all_branch_access, is_platform_admin, last_login_at, user_roles ( roles ( name ) )',
    )
    .order('full_name');

  if (error) {
    throw new Error(`Failed to load users: ${error.message}`);
  }

  return (data ?? []).map((row) => {
    const assignments = row.user_roles ?? [];
    return {
      id: row.id,
      full_name: row.full_name,
      email: row.email,
      mobile: row.mobile,
      status: row.status,
      has_all_branch_access: row.has_all_branch_access,
      is_platform_admin: row.is_platform_admin,
      last_login_at: row.last_login_at,
      roles: assignments.map((a) => a.roles.name).filter(Boolean),
    };
  });
}

export interface RoleWithPermissions {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly description: string | null;
  readonly is_system: boolean;
  readonly permissionCount: number;
  readonly sensitiveCount: number;
}

export async function listRoles(): Promise<RoleWithPermissions[]> {
  const supabase = await createSupabaseServerClient();

  const [{ data: roles, error: rolesError }, { data: sensitive, error: permError }] =
    await Promise.all([
      supabase
        .from('roles')
        .select('id, code, name, description, is_system, role_permissions ( permission_code )')
        .order('is_system', { ascending: false })
        .order('name'),
      supabase.from('permissions').select('code').eq('is_sensitive', true),
    ]);

  if (rolesError) {
    throw new Error(`Failed to load roles: ${rolesError.message}`);
  }
  if (permError) {
    throw new Error(`Failed to load permissions: ${permError.message}`);
  }

  const sensitiveCodes = new Set((sensitive ?? []).map((row) => row.code));

  return (roles ?? []).map((role) => {
    const grants = role.role_permissions ?? [];
    return {
      id: role.id,
      code: role.code,
      name: role.name,
      description: role.description,
      is_system: role.is_system,
      permissionCount: grants.length,
      sensitiveCount: grants.filter((grant) => sensitiveCodes.has(grant.permission_code)).length,
    };
  });
}

export type EmployeeRow = Pick<
  Tables<'employees'>,
  | 'id'
  | 'employee_code'
  | 'name'
  | 'department'
  | 'designation'
  | 'mobile'
  | 'joining_date'
  | 'status'
> & { readonly branch: string | null };

export async function listEmployees(): Promise<EmployeeRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from('employees')
    .select(
      'id, employee_code, name, department, designation, mobile, joining_date, status, branches ( name )',
    )
    .order('employee_code');

  if (error) {
    throw new Error(`Failed to load employees: ${error.message}`);
  }

  return (data ?? []).map((row) => {
    const branch = row.branches;
    return {
      id: row.id,
      employee_code: row.employee_code,
      name: row.name,
      department: row.department,
      designation: row.designation,
      mobile: row.mobile,
      joining_date: row.joining_date,
      status: row.status,
      branch: branch?.name ?? null,
    };
  });
}

export type AuditRow = Pick<
  Tables<'audit_logs'>,
  'id' | 'action' | 'entity_type' | 'entity_id' | 'changed_fields' | 'reason' | 'created_at'
> & { readonly actor: string | null };

export async function listAuditLogs(limit = 100): Promise<AuditRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from('audit_logs')
    .select('id, action, entity_type, entity_id, changed_fields, reason, created_at, user_id')
    .order('created_at', { ascending: false })
    .limit(limit);

  if (error) {
    throw new Error(`Failed to load audit logs: ${error.message}`);
  }

  const rows = data ?? [];

  // audit_logs.user_id deliberately has no foreign key: an audit row must survive
  // the deletion of the user who caused it, which an FK would prevent. So the
  // actor's name is resolved with a second lookup rather than an embedded join.
  const userIds = [...new Set(rows.map((row) => row.user_id).filter((id): id is string => Boolean(id)))];
  const names = new Map<string, string>();

  if (userIds.length > 0) {
    const { data: profiles } = await supabase
      .from('user_profiles')
      .select('id, full_name')
      .in('id', userIds);
    for (const profile of profiles ?? []) {
      names.set(profile.id, profile.full_name);
    }
  }

  return rows.map((row) => ({
    id: row.id,
    action: row.action,
    entity_type: row.entity_type,
    entity_id: row.entity_id,
    changed_fields: row.changed_fields,
    reason: row.reason,
    created_at: row.created_at,
    actor: row.user_id ? (names.get(row.user_id) ?? null) : null,
  }));
}

export async function listSettings(): Promise<Tables<'system_settings'>[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.from('system_settings').select('*').order('key');

  if (error) {
    throw new Error(`Failed to load settings: ${error.message}`);
  }
  return data ?? [];
}

export async function listDocumentSequences(): Promise<Tables<'document_sequences'>[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from('document_sequences')
    .select('*')
    .order('doc_type')
    .order('financial_year');

  if (error) {
    throw new Error(`Failed to load document sequences: ${error.message}`);
  }
  return data ?? [];
}

export async function getDealer(): Promise<Tables<'dealers'> | null> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.from('dealers').select('*').limit(1).maybeSingle();

  if (error) {
    throw new Error(`Failed to load dealer: ${error.message}`);
  }
  return data;
}
