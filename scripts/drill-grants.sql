-- =============================================================================
-- drill-grants.sql — Supabase's default privileges, on a restored copy
-- =============================================================================
-- The drill restores with --no-privileges (owners and grants differ between a
-- Supabase project and a local server). Supabase grants the API roles access to
-- everything in public and relies on RLS to decide what each user sees; this
-- puts the copy in the same position so the app's functions can be run on it as
-- a signed-in user, under RLS.
-- =============================================================================
grant usage on schema public, app to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema public to authenticated, service_role;
grant usage, select on all sequences in schema public to authenticated, service_role;
grant execute on all functions in schema public, app to authenticated, service_role;
