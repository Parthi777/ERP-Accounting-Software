-- =============================================================================
-- 0009 — Row Level Security
-- =============================================================================
-- Spec §4, §47, §60.20. RLS is the second line of defense: even if a service-layer
-- check is missed, a query issued with a user's JWT cannot reach another dealer's
-- rows.
--
-- Policy shape, applied uniformly:
--   SELECT  — platform admin, or row belongs to my dealer (and my branch, if the
--             row is branch-specific)
--   WRITE   — the same tenant test AND an explicit permission code
--
-- Two things worth noting:
--   * ENABLE, deliberately not FORCE. The helper functions in 0004 are SECURITY
--     DEFINER and owned by the migration role, which is also the table owner —
--     forcing RLS would subject those lookups to the very policies they exist to
--     answer, and `app.current_dealer_id()` would recurse into the user_profiles
--     policy. Client sessions connect as `authenticated`, never as the owner, so
--     policies still apply to every request that comes from a browser.
--   * The service_role key bypasses RLS entirely by design. It is server-only and
--     must never reach the browser (spec §47).
--
-- Rollback: drop the policies, then `alter table ... disable row level security`.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Enable on every table
-- -----------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array[
    'dealers', 'branches',
    'permissions', 'roles', 'role_permissions',
    'user_profiles', 'user_roles', 'user_branches', 'employees',
    'audit_logs', 'document_sequences',
    'chart_of_accounts', 'accounting_periods', 'journal_entries', 'journal_entry_lines',
    'system_settings'
  ]
  loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end;
$$;

-- =============================================================================
-- dealers — a user sees only their own dealer; only platform admins create them
-- =============================================================================
create policy dealers_select on public.dealers
  for select to authenticated
  using (app.is_platform_admin() or id = app.current_dealer_id());

create policy dealers_update on public.dealers
  for update to authenticated
  using (
    app.is_platform_admin()
    or (id = app.current_dealer_id() and app.has_permission('admin.dealers.manage'))
  )
  with check (
    app.is_platform_admin()
    or (id = app.current_dealer_id() and app.has_permission('admin.dealers.manage'))
  );

create policy dealers_insert on public.dealers
  for insert to authenticated
  with check (app.is_platform_admin());

create policy dealers_delete on public.dealers
  for delete to authenticated
  using (app.is_platform_admin());

-- =============================================================================
-- branches
-- =============================================================================
create policy branches_select on public.branches
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.can_access_branch(id))
  );

create policy branches_insert on public.branches
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.branches.manage'))
  );

create policy branches_update on public.branches
  for update to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.branches.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.branches.manage'))
  );

create policy branches_delete on public.branches
  for delete to authenticated
  using (app.is_platform_admin());

-- =============================================================================
-- permissions — global read-only catalogue
-- =============================================================================
create policy permissions_select on public.permissions
  for select to authenticated
  using (true);

create policy permissions_write on public.permissions
  for all to authenticated
  using (app.is_platform_admin())
  with check (app.is_platform_admin());

-- =============================================================================
-- roles — system roles readable by all; dealer roles scoped to the dealer
-- =============================================================================
create policy roles_select on public.roles
  for select to authenticated
  using (
    app.is_platform_admin()
    or dealer_id is null
    or dealer_id = app.current_dealer_id()
  );

create policy roles_insert on public.roles
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and not is_system
        and app.has_permission('admin.roles.manage'))
  );

create policy roles_update on public.roles
  for update to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and not is_system
        and app.has_permission('admin.roles.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and not is_system
        and app.has_permission('admin.roles.manage'))
  );

create policy roles_delete on public.roles
  for delete to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and not is_system
        and app.has_permission('admin.roles.manage'))
  );

-- =============================================================================
-- role_permissions — visible for roles you can see, writable with the permission
-- =============================================================================
create policy role_permissions_select on public.role_permissions
  for select to authenticated
  using (
    exists (
      select 1 from public.roles r
       where r.id = role_permissions.role_id
         and (app.is_platform_admin() or r.dealer_id is null or r.dealer_id = app.current_dealer_id())
    )
  );

create policy role_permissions_write on public.role_permissions
  for all to authenticated
  using (
    app.is_platform_admin()
    or (app.has_permission('admin.roles.manage')
        and exists (
          select 1 from public.roles r
           where r.id = role_permissions.role_id
             and r.dealer_id = app.current_dealer_id()
             and not r.is_system
        ))
  )
  with check (
    app.is_platform_admin()
    or (app.has_permission('admin.roles.manage')
        and exists (
          select 1 from public.roles r
           where r.id = role_permissions.role_id
             and r.dealer_id = app.current_dealer_id()
             and not r.is_system
        ))
  );

-- =============================================================================
-- user_profiles — always see yourself; see colleagues with the users permission
-- =============================================================================
create policy user_profiles_select on public.user_profiles
  for select to authenticated
  using (
    id = auth.uid()
    or app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.users.view'))
  );

create policy user_profiles_insert on public.user_profiles
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.users.manage'))
  );

-- A user may update their own profile, but not their tenant, admin flag or branch
-- reach — those are privilege escalation vectors and require admin.users.manage.
create policy user_profiles_update on public.user_profiles
  for update to authenticated
  using (
    id = auth.uid()
    or app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.users.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.users.manage'))
    or (
      id = auth.uid()
      and dealer_id is not distinct from app.current_dealer_id()
      and not is_platform_admin
      -- Read the current value through the SECURITY DEFINER helper rather than a
      -- subquery on this same table, which would re-enter this policy.
      and has_all_branch_access = app.has_all_branch_access()
    )
  );

create policy user_profiles_delete on public.user_profiles
  for delete to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.users.manage'))
  );

-- =============================================================================
-- user_roles / user_branches — your own grants are readable; changes need admin
-- =============================================================================
create policy user_roles_select on public.user_roles
  for select to authenticated
  using (
    user_id = auth.uid()
    or app.is_platform_admin()
    or (app.has_permission('admin.users.view')
        and exists (
          select 1 from public.user_profiles up
           where up.id = user_roles.user_id and up.dealer_id = app.current_dealer_id()
        ))
  );

create policy user_roles_write on public.user_roles
  for all to authenticated
  using (
    app.is_platform_admin()
    or (app.has_permission('admin.users.manage')
        and exists (
          select 1 from public.user_profiles up
           where up.id = user_roles.user_id and up.dealer_id = app.current_dealer_id()
        ))
  )
  with check (
    app.is_platform_admin()
    or (app.has_permission('admin.users.manage')
        and exists (
          select 1 from public.user_profiles up
           where up.id = user_roles.user_id and up.dealer_id = app.current_dealer_id()
        ))
  );

create policy user_branches_select on public.user_branches
  for select to authenticated
  using (
    user_id = auth.uid()
    or app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.users.view'))
  );

create policy user_branches_write on public.user_branches
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.users.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.users.manage'))
  );

-- =============================================================================
-- employees
-- =============================================================================
create policy employees_select on public.employees
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and app.has_permission('masters.employees.view'))
  );

create policy employees_write on public.employees
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('masters.employees.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('masters.employees.manage'))
  );

-- =============================================================================
-- audit_logs — readable with the permission, never writable from a session.
-- Inserts come from SECURITY DEFINER triggers and the service role only, so there
-- is deliberately no INSERT policy here (spec §46).
-- =============================================================================
create policy audit_logs_select on public.audit_logs
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.audit.view'))
  );

-- =============================================================================
-- document_sequences — read to preview the next number, manage to reconfigure
-- =============================================================================
create policy document_sequences_select on public.document_sequences
  for select to authenticated
  using (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy document_sequences_write on public.document_sequences
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.settings.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.settings.manage'))
  );

-- =============================================================================
-- chart_of_accounts
-- =============================================================================
create policy chart_of_accounts_select on public.chart_of_accounts
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.coa.view'))
  );

create policy chart_of_accounts_write on public.chart_of_accounts
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.coa.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.coa.manage'))
  );

-- =============================================================================
-- accounting_periods
-- =============================================================================
create policy accounting_periods_select on public.accounting_periods
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.journals.view'))
  );

create policy accounting_periods_write on public.accounting_periods
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.periods.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.periods.manage'))
  );

-- =============================================================================
-- journal_entries / journal_entry_lines
-- Note there is no DELETE policy: journals are corrected by reversal, and the
-- 0007 trigger refuses to delete anything already posted (spec §23, §60.12).
-- =============================================================================
create policy journal_entries_select on public.journal_entries
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and app.has_permission('accounting.journals.view'))
  );

create policy journal_entries_insert on public.journal_entries
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and app.has_permission('accounting.journals.create'))
  );

create policy journal_entries_update on public.journal_entries
  for update to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and app.has_permission('accounting.journals.post'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and app.has_permission('accounting.journals.post'))
  );

create policy journal_entry_lines_select on public.journal_entry_lines
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and exists (
          select 1 from public.journal_entries je
           where je.id = journal_entry_lines.journal_entry_id
             and app.can_access_branch(je.branch_id)
        )
        and app.has_permission('accounting.journals.view'))
  );

create policy journal_entry_lines_write on public.journal_entry_lines
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.journals.create'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.journals.create'))
  );

-- =============================================================================
-- system_settings — public settings readable by all; secrets stay server-side
-- =============================================================================
create policy system_settings_select on public.system_settings
  for select to authenticated
  using (
    app.is_platform_admin()
    or (
      (dealer_id is null or dealer_id = app.current_dealer_id())
      and (is_public or app.has_permission('admin.settings.view'))
    )
  );

create policy system_settings_write on public.system_settings
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.settings.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.settings.manage'))
  );
