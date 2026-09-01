-- =============================================================================
-- remove-demo-dealer.sql — delete the demo dealer and everything under it
-- =============================================================================
-- The seed ships one demo dealer ("Sri Balaji Motors", code SBM) with three
-- branches, eight employees, a chart of accounts and a small ledger, so a fresh
-- deployment has something to look at. Run this before real data goes in.
--
--   psql "$DATABASE_URL" -f scripts/remove-demo-dealer.sql
--
-- Must be run as the database owner (Supabase's `postgres` role). See below.
--
-- The permission catalogue and the seven system roles are NOT demo data and are
-- deliberately kept — the application cannot authorize anything without them.
-- The audit trail is kept too; see the note at the end.
--
-- ⚠ If you have attached a REAL login to the demo dealer — which is the normal
-- way to look around before your own dealer exists — this takes its profile and
-- role with the dealer. The Supabase Auth account itself survives, because it is
-- matched on an @sribalajimotors.example address that a real login does not have,
-- so the password still works; but until the profile is recreated the person can
-- sign in and be authorized for nothing.
--
-- The way back is scripts/link-auth-users.sql, which matches auth accounts by
-- email and reprovisions profile, role and branch access. Put your own address
-- in its list BEFORE running this, and run it again afterwards.
--
-- Why this is not the one-liner seed.sql used to suggest
-- ------------------------------------------------------
-- `delete from public.dealers where code = 'SBM'` fails immediately:
--
--   ERROR: update or delete on table "dealers" violates foreign key constraint
--          "branches_dealer_id_fkey" on table "branches"
--
-- and deleting the children first fails too, because the ledgers defend
-- themselves:
--
--   ERROR: inventory_transactions is append-only; DELETE is not permitted.
--
-- Both are the schema working as intended. Financial history is `on delete
-- restrict` so a posted journal cannot vanish with its parent (spec §23), and
-- the stock and finance ledgers carry append-only triggers (spec §34, §46).
--
-- Removing a whole dealer is the one legitimate exception, and it is an
-- administrative act rather than something the application can do — which is why
-- this is a script run by hand, and why the application's own service role still
-- cannot do any of it. `session_replication_role = replica` suspends triggers
-- and foreign keys for this session only, and is restored at the end.
-- =============================================================================

\set ON_ERROR_STOP on

begin;

-- Suspends user triggers (the append-only guards) and FK checks for this
-- session. Nothing outside this transaction is affected, and it is restored
-- below whichever way the transaction ends.
set local session_replication_role = 'replica';

do $$
declare
  v_dealer  uuid;
  v_users   uuid[];
  v_table   text;
  v_removed bigint;
  v_total   bigint := 0;
begin
  select id into v_dealer from public.dealers where code = 'SBM';

  if v_dealer is null then
    raise notice 'No demo dealer (code SBM) found — nothing to remove.';
    return;
  end if;

  -- Collected BEFORE the sweep below, which deletes user_profiles along with
  -- every other dealer_id table. Reading the ids afterwards finds nothing, and
  -- the role grants — which are keyed on the user, not the dealer — would be
  -- left behind pointing at profiles that no longer exist. There is no foreign
  -- key to catch that, and re-seeding reuses these same fixed demo uuids, so the
  -- new users would silently inherit the old grants.
  select coalesce(array_agg(id), '{}') into v_users
    from public.user_profiles where dealer_id = v_dealer;

  -- Every table carrying a dealer_id, discovered rather than hardcoded, so a
  -- table added later is covered without editing this script.
  --
  -- audit_logs is excluded on purpose. Spec §46 makes the audit trail
  -- append-only precisely so that removing records cannot remove the evidence
  -- that they existed; erasing it here would defeat the point of keeping one.
  -- Its dealer_id carries no foreign key, so the rows are harmless once the
  -- dealer is gone.
  for v_table in
    select format('%I.%I', table_schema, table_name)
      from information_schema.columns
     where table_schema = 'public'
       and column_name = 'dealer_id'
       and table_name not in ('dealers', 'audit_logs')
     order by table_name
  loop
    execute format('delete from %s where dealer_id = $1', v_table) using v_dealer;
    get diagnostics v_removed = row_count;
    v_total := v_total + v_removed;
  end loop;

  -- Role grants, using the ids captured before the sweep. user_profiles itself
  -- was already removed by the loop, since it carries a dealer_id.
  delete from public.user_roles where user_id = any (v_users);
  get diagnostics v_removed = row_count;
  v_total := v_total + v_removed;

  delete from public.user_profiles where dealer_id = v_dealer;
  delete from public.dealers where id = v_dealer;

  -- The demo logins live in Supabase Auth, which owns its own schema.
  if to_regclass('auth.users') is not null then
    delete from auth.users where email like '%@sribalajimotors.example';
  end if;

  raise notice 'Demo dealer removed (% rows). Permissions, system roles and the audit trail kept.',
    v_total;
end;
$$;

commit;
