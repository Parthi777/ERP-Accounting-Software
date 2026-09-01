-- =============================================================================
-- 0011 — Role grants
-- =============================================================================
-- RLS narrows what a privilege can reach; it does not grant the privilege. A
-- table with perfect policies and no GRANT is unreadable, and a table with a
-- GRANT and no policy is wide open. Both halves are set here explicitly rather
-- than relying on Supabase's default privileges, so the same result holds on a
-- plain Postgres server.
--
-- `anon` (unauthenticated) receives nothing at all. Every read in this product
-- requires a session.
--
-- Rollback: revoke the grants below.
-- =============================================================================

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  grant usage on schema public to authenticated, anon, service_role;

  -- Baseline: logged-in users may attempt any DML. Policies decide the outcome.
  execute 'grant select, insert, update, delete on all tables in schema public to authenticated';
  execute 'grant usage, select on all sequences in schema public to authenticated';

  -- Audit trail is written by SECURITY DEFINER triggers and the service role only.
  -- Removing INSERT here means a compromised session cannot forge log entries even
  -- if an INSERT policy is added by mistake later (spec §46).
  execute 'revoke insert, update, delete on public.audit_logs from authenticated';

  -- Journals are corrected by reversal, never deleted (spec §23, §60.12). The
  -- trigger in 0007 enforces this too; withholding the privilege makes it two
  -- independent barriers rather than one.
  execute 'revoke delete on public.journal_entries from authenticated';
  execute 'revoke delete on public.journal_entry_lines from authenticated';

  -- Only platform administration creates or removes tenants, and it does so
  -- through the service role.
  execute 'revoke delete on public.dealers from authenticated';

  -- The permission catalogue is release-managed, not user-editable.
  execute 'revoke insert, update, delete on public.permissions from authenticated';

  -- Unauthenticated callers get nothing.
  execute 'revoke all on all tables in schema public from anon';

  -- The service role is the server-side escape hatch: it bypasses RLS by design
  -- and must never be exposed to the browser (spec §47).
  execute 'grant all on all tables in schema public to service_role';
  execute 'grant all on all sequences in schema public to service_role';
end;
$$;

-- Future tables inherit the same baseline, so a migration that forgets its grants
-- still produces a table that authenticated users can reach under RLS.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'alter default privileges in schema public grant select, insert, update, delete on tables to authenticated';
    execute 'alter default privileges in schema public grant usage, select on sequences to authenticated';
    execute 'alter default privileges in schema public grant all on tables to service_role';
    execute 'alter default privileges in schema public grant all on sequences to service_role';
  end if;
end;
$$;
