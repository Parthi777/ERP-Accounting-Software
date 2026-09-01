-- =============================================================================
-- 0004 — RLS helper functions
-- =============================================================================
-- Every policy in 0009 is written in terms of these five functions.
--
-- All of them are SECURITY DEFINER. This is not optional: a policy on
-- user_profiles that reads user_profiles to decide visibility would re-enter its
-- own policy and recurse until Postgres aborts the query. SECURITY DEFINER makes
-- the lookup run as the function owner, bypassing RLS for that read only.
--
-- Each function pins `search_path` so a caller cannot shadow `public` with a
-- temp-schema table and trick a definer-rights function into reading forged data.
--
-- Rollback: drop the functions; policies in 0009 depend on them.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- app.is_platform_admin() — spec §6, platform admins sit above the tenant model
-- -----------------------------------------------------------------------------
create or replace function app.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select up.is_platform_admin
       from public.user_profiles up
      where up.id = auth.uid()
        and up.status = 'ACTIVE'),
    false
  );
$$;

-- -----------------------------------------------------------------------------
-- app.current_dealer_id() — the tenant of the authenticated user
-- -----------------------------------------------------------------------------
create or replace function app.current_dealer_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select up.dealer_id
    from public.user_profiles up
   where up.id = auth.uid()
     and up.status = 'ACTIVE';
$$;

comment on function app.current_dealer_id() is
  'Tenant of the current session, resolved from the JWT. Returns NULL for platform '
  'admins and unauthenticated callers, so `dealer_id = app.current_dealer_id()` is '
  'false for both — deny by default (spec §4).';

-- -----------------------------------------------------------------------------
-- app.has_all_branch_access() — dealer owners and accounts see every branch
-- -----------------------------------------------------------------------------
create or replace function app.has_all_branch_access()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select up.has_all_branch_access or up.is_platform_admin
       from public.user_profiles up
      where up.id = auth.uid()
        and up.status = 'ACTIVE'),
    false
  );
$$;

-- -----------------------------------------------------------------------------
-- app.can_access_branch(uuid) — branch-level narrowing (spec §60.5)
-- -----------------------------------------------------------------------------
create or replace function app.can_access_branch(p_branch_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select app.has_all_branch_access()
      or exists (
           select 1
             from public.user_branches ub
            where ub.user_id = auth.uid()
              and ub.branch_id = p_branch_id
         );
$$;

-- -----------------------------------------------------------------------------
-- app.has_permission(text) — the single authorization primitive
-- -----------------------------------------------------------------------------
create or replace function app.has_permission(p_code text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select app.is_platform_admin()
      or exists (
           select 1
             from public.user_roles ur
             join public.role_permissions rp on rp.role_id = ur.role_id
            where ur.user_id = auth.uid()
              and rp.permission_code = p_code
         );
$$;

comment on function app.has_permission(text) is
  'True when the session holds the given permission code through any assigned role. '
  'Policies gate writes on permissions, never on role names, so roles stay data (spec §6).';

-- -----------------------------------------------------------------------------
-- Grants: executable by logged-in users only. `anon` gets nothing.
-- -----------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function app.is_platform_admin()          to authenticated';
    execute 'grant execute on function app.current_dealer_id()          to authenticated';
    execute 'grant execute on function app.has_all_branch_access()      to authenticated';
    execute 'grant execute on function app.can_access_branch(uuid)      to authenticated';
    execute 'grant execute on function app.has_permission(text)         to authenticated';
  end if;
end;
$$;

revoke execute on function app.is_platform_admin()     from public;
revoke execute on function app.current_dealer_id()     from public;
revoke execute on function app.has_all_branch_access() from public;
revoke execute on function app.can_access_branch(uuid) from public;
revoke execute on function app.has_permission(text)    from public;
