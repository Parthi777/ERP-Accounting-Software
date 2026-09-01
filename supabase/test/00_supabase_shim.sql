-- =============================================================================
-- LOCAL TEST SHIM — never deployed to Supabase
-- =============================================================================
-- Supabase provides an `auth` schema, an `auth.users` table, an `auth.uid()`
-- function reading the request JWT, and the roles anon / authenticated /
-- service_role. Vanilla Postgres has none of that.
--
-- This file recreates just enough of it to run the real migrations against a
-- throwaway local database, so schema, constraints, triggers and RLS policy
-- expressions are all exercised before the Supabase project exists.
--
-- The impersonation mechanism: auth.uid() reads a session GUC instead of a JWT.
--   select app_test.login('<uuid>');   -- become that user
--   select app_test.logout();          -- become anonymous
-- =============================================================================

create schema if not exists auth;
create schema if not exists app_test;

-- Supabase's client-facing roles.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end;
$$;

grant usage on schema public to anon, authenticated, service_role;
grant usage on schema auth   to anon, authenticated, service_role;

-- Minimal stand-in for auth.users. Only the columns the ERP references.
create table if not exists auth.users (
  id         uuid primary key default gen_random_uuid(),
  email      text unique,
  created_at timestamptz not null default now()
);

-- auth.uid(): in Supabase this decodes the JWT. Here it reads a session variable.
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('app_test.current_user_id', true), '')::uuid;
$$;

create or replace function auth.role()
returns text
language sql
stable
as $$
  select coalesce(nullif(current_setting('app_test.current_role', true), ''), 'anon');
$$;

grant execute on function auth.uid()  to anon, authenticated, service_role;
grant execute on function auth.role() to anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Impersonation helpers used by the RLS tests
-- -----------------------------------------------------------------------------
create or replace function app_test.login(p_user_id uuid)
returns void
language plpgsql
as $$
begin
  perform set_config('app_test.current_user_id', p_user_id::text, false);
  perform set_config('app_test.current_role', 'authenticated', false);
end;
$$;

create or replace function app_test.logout()
returns void
language plpgsql
as $$
begin
  perform set_config('app_test.current_user_id', '', false);
  perform set_config('app_test.current_role', 'anon', false);
end;
$$;

-- Assertion helper so the test files fail loudly rather than printing a table.
create or replace function app_test.assert_equals(
  p_actual   anyelement,
  p_expected anyelement,
  p_message  text
)
returns void
language plpgsql
as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'ASSERTION FAILED: % (expected %, got %)',
      p_message, coalesce(p_expected::text, 'NULL'), coalesce(p_actual::text, 'NULL');
  end if;
  raise notice '  ok  %', p_message;
end;
$$;

-- Asserts that a statement raises. Used for immutability / constraint tests.
create or replace function app_test.assert_raises(p_sql text, p_message text)
returns void
language plpgsql
as $$
begin
  begin
    execute p_sql;
  exception
    when others then
      raise notice '  ok  % (rejected: %)', p_message, replace(sqlerrm, E'\n', ' ');
      return;
  end;
  raise exception 'ASSERTION FAILED: % — statement was accepted but should have been rejected.', p_message;
end;
$$;

-- The RLS tests run as `authenticated`, so that role needs to reach these helpers.
grant usage on schema app_test to anon, authenticated, service_role;
grant execute on all functions in schema app_test to anon, authenticated, service_role;
