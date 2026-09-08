-- =============================================================================
-- TEST — the database can say which migration it is on
-- =============================================================================
-- Spec §59, §60.20.
--
-- The guarantees asserted here:
--   * every migration on disk is recorded, so the version the application
--     compares against is the whole truth and not the part someone remembered;
--   * the record is release-managed — a logged-in session can read it and
--     cannot write it, the same treatment public.permissions gets;
--   * the table carries RLS like every other public table, and the policy is an
--     explicit "any session may read", not an absence of one;
--   * re-applying 0059 is harmless, because a bundle is meant to be safe to
--     re-run against a database that already has part of it.
-- =============================================================================

\echo '--- schema version ---'

do $$
declare
  v_count   int;
  v_latest  text;
  v_dupe    int;
  v_user    uuid;
begin
  -- ── Every migration is recorded ─────────────────────────────────────────
  -- Deliberately derived rather than hardcoded. An earlier draft asserted
  -- '0059' and broke the moment 0060 was written, which is a test failing for
  -- being out of date rather than for finding anything.
  select max(version) into v_latest from public.schema_migrations;
  select count(*) into v_count from public.schema_migrations;

  perform app_test.assert_equals(
    v_count, v_latest::int,
    'every version from 0001 to the latest is recorded, and none twice'
  );

  -- The application reads max(version) and trusts it, so a gap would make a
  -- half-applied database look current — the one failure this table exists to
  -- prevent.
  select count(*) into v_count
    from generate_series(1, v_latest::int) g
   where not exists (
     select 1 from public.schema_migrations
      where version = lpad(g::text, 4, '0')
   );
  perform app_test.assert_equals(
    v_count, 0,
    'there are no gaps below the latest — a gap would read as current'
  );

  -- ── Names travel with the versions ──────────────────────────────────────
  perform app_test.assert_equals(
    (select name from public.schema_migrations where version = '0058'),
    'gst_input_tax',
    'each row names its migration, not just its number'
  );

  select count(*) into v_dupe
    from (select version from public.schema_migrations
           group by version having count(*) > 1) d;
  perform app_test.assert_equals(
    v_dupe, 0, 'a version is recorded once — the primary key sees to it'
  );

  -- ── Re-applying is harmless ─────────────────────────────────────────────
  -- Both bundles are one transaction and are meant to be safe to re-run; an
  -- ON CONFLICT that did not hold would abort the whole thing.
  insert into public.schema_migrations (version, name)
  values (v_latest, 'restamped')
  on conflict (version) do nothing;

  select count(*) into v_count
    from public.schema_migrations where version = v_latest;
  perform app_test.assert_equals(
    v_count, 1, 'stamping the same version twice does not duplicate it'
  );

  -- ── RLS is on, like every other public table ────────────────────────────
  perform app_test.assert_equals(
    (select relrowsecurity from pg_class where relname = 'schema_migrations'),
    true,
    'row level security is enabled on schema_migrations'
  );
end $$;

-- ── Release-managed: readable by a session, not writable by one ────────────
--
-- `set role authenticated` is the part that matters. app_test.login() only sets
-- the GUCs auth.uid() reads; the session stays the table owner, and an owner
-- bypasses RLS and holds every privilege. A test that skips this asserts nothing
-- — it passed against a table with no policies at all before this line was added.
set role authenticated;
select app_test.login((select id from public.user_profiles limit 1));

do $$
begin
  perform app_test.assert_equals(
    (select count(*) > 0 from public.schema_migrations), true,
    'a logged-in session can read the schema version'
  );

  perform app_test.assert_raises(
    $q$insert into public.schema_migrations (version, name) values ('9999', 'forged')$q$,
    'a session cannot forge a migration record'
  );
  perform app_test.assert_raises(
    $q$update public.schema_migrations set name = 'tampered' where version = '0001'$q$,
    'a session cannot rewrite one'
  );
  perform app_test.assert_raises(
    $q$delete from public.schema_migrations where version = '0001'$q$,
    'a session cannot delete one'
  );
end $$;

select app_test.logout();
reset role;
