-- =============================================================================
-- TEST — provisioning a second dealer
-- =============================================================================
-- Spec §4, §6, §22, §24, §44, §45, §47, §48, §60.3.
--
-- This is the first test in the suite with TWO real tenants, which makes it the
-- one that actually proves the isolation the other 133 policies claim.
--
-- The guarantees asserted here:
--   * one call produces a tenant that can trade — accounts, rules, sequences,
--     cash account, period, owner — and says so through dealer_readiness();
--   * a tenant that would not work never commits;
--   * duplicate codes and GSTINs are refused at the door;
--   * the new tenant sees none of the existing dealer's data, and the existing
--     dealer sees none of the new tenant's;
--   * a suspended dealer loses access everywhere at once (0055);
--   * a mis-created tenant can be purged, and one that has posted cannot.
-- =============================================================================

\echo '--- dealer provisioning ---'

-- Provisioning is platform-admin work, so the session is one. RLS stays out of
-- the way for the fixture; the isolation assertions below switch role properly.
select app_test.login('99999999-9999-4999-8999-999999999999');

do $$
declare
  v_owner  uuid := 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
  v_res    record;
  v_new    uuid;
  v_branch uuid;
  v_count  int;
  v_failed int;
begin
  -- A platform admin, and an auth account for the incoming owner.
  insert into auth.users (id, email) values
    ('99999999-9999-4999-8999-999999999999', 'platform@example.com'),
    (v_owner, 'owner@newdealer.example')
  on conflict (id) do nothing;

  insert into public.user_profiles (id, dealer_id, full_name, email, is_platform_admin, status)
  values ('99999999-9999-4999-8999-999999999999', null, 'Platform Admin', 'platform@example.com', true, 'ACTIVE')
  on conflict (id) do update set is_platform_admin = true;

  -- ═══ The call ════════════════════════════════════════════════════════════
  select * into v_res from app.provision_dealer(
    p_code          => 'NDM',
    p_legal_name    => 'New Dealer Motors Private Limited',
    p_trade_name    => 'New Dealer Motors',
    p_state         => 'Tamil Nadu',
    p_state_code    => '33',
    p_owner_email   => 'owner@newdealer.example',
    p_owner_name    => 'Owner Kumar',
    p_owner_user_id => v_owner,
    p_branch_name   => 'Coimbatore Main',
    p_gstin         => '33AACCN1234A1ZQ',
    p_city          => 'Coimbatore');

  v_new := v_res.new_dealer_id;
  v_branch := v_res.new_branch_id;

  perform app_test.assert_equals(v_new is not null, true, 'provisioning returns the new dealer');
  perform app_test.assert_equals(v_res.accounts_created, 42, 'the full chart of accounts is seeded');
  perform app_test.assert_equals(v_res.rules_created > 0, true, 'and the accounting rules with it');

  -- ═══ It can actually trade ═══════════════════════════════════════════════
  select count(*)::int into v_failed from public.dealer_readiness(v_new) where not ok;
  perform app_test.assert_equals(v_failed, 0,
    'every readiness check passes — the tenant can raise an invoice');

  select count(*)::int into v_count from public.cash_accounts where dealer_id = v_new;
  perform app_test.assert_equals(v_count, 1,
    'the branch has a cash account, so the first counter receipt will not fail');

  select count(*)::int into v_count
    from public.document_sequences where dealer_id = v_new;
  perform app_test.assert_equals(v_count, 10, 'ten financial document series exist');

  select count(*)::int into v_count
    from public.accounting_periods where dealer_id = v_new and status = 'OPEN';
  perform app_test.assert_equals(v_count, 1, 'and an open accounting period covers today');

  -- The owner resolves the whole permission catalogue through a global role.
  select count(*)::int into v_count
    from public.user_roles ur join public.roles r on r.id = ur.role_id
   where ur.user_id = v_owner and r.code = 'DEALER_OWNER' and r.dealer_id is null;
  perform app_test.assert_equals(v_count, 1,
    'the owner holds the global DEALER_OWNER role — no per-tenant role was created');

  -- ═══ What is refused at the door ═════════════════════════════════════════
  perform app_test.assert_raises(
    'select app.provision_dealer(''NDM'', ''Duplicate'', ''Dup'', ''Tamil Nadu'', ''33'','
    || ' ''x@y.example'', ''X'', ''bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb''::uuid)',
    'a dealer code cannot be reused');

  perform app_test.assert_raises(
    'select app.provision_dealer(''OTH'', ''Other'', ''Other'', ''Tamil Nadu'', ''33'','
    || ' ''z@y.example'', ''Z'', ''bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb''::uuid,'
    || ' ''Head Office'', ''33AACCN1234A1ZQ'')',
    'two dealers cannot share a GSTIN — they would file each other''s returns');

  perform app_test.assert_raises(
    'select app.provision_dealer(''BAD'', ''Bad State'', ''Bad'', ''Tamil Nadu'', ''3'','
    || ' ''b@y.example'', ''B'', ''bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb''::uuid)',
    'a malformed state code is refused: it decides CGST+SGST versus IGST');

  perform app_test.assert_raises(
    'select app.provision_dealer(''NOU'', ''No Owner'', ''No Owner'', ''Tamil Nadu'', ''33'','
    || ' ''n@y.example'', ''N'', null)',
    'provisioning without an owner auth account is refused');

  -- Nothing above left a partial tenant behind.
  select count(*)::int into v_count from public.dealers where code in ('OTH', 'BAD', 'NOU');
  perform app_test.assert_equals(v_count, 0,
    'a refused provisioning writes nothing at all (spec §48)');
end;
$$;

-- -----------------------------------------------------------------------------
-- Isolation, in both directions — the point of having two tenants
-- -----------------------------------------------------------------------------
reset role;
set role authenticated;
select app_test.login('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa');   -- the NEW dealer's owner

do $$
declare v_count int;
begin
  select count(*)::int into v_count from public.customers;
  perform app_test.assert_equals(v_count, 0,
    'the new tenant sees none of the existing dealer''s customers');

  select count(*)::int into v_count from public.journal_entries;
  perform app_test.assert_equals(v_count, 0, 'nor any of their journals');

  select count(*)::int into v_count from public.vehicles;
  perform app_test.assert_equals(v_count, 0, 'nor their stock');

  -- Their own chart of accounts, however, is there and complete.
  select count(*)::int into v_count from public.chart_of_accounts;
  perform app_test.assert_equals(v_count, 42,
    'but their own chart of accounts is fully visible to them');
end;
$$;

reset role;
set role authenticated;
select app_test.login('11111111-1111-4111-8111-111111111111');   -- the EXISTING dealer's owner

do $$
declare
  v_count int;
  v_new   uuid;
begin
  select count(*)::int into v_count from public.dealers;
  perform app_test.assert_equals(v_count, 1,
    'the existing dealer sees only their own dealer row, not the new tenant');

  select count(*)::int into v_count from public.branches where name = 'Coimbatore Main';
  perform app_test.assert_equals(v_count, 0, 'nor the new tenant''s branch');

  select count(*)::int into v_count from public.chart_of_accounts c
    join public.dealers d on d.id = c.dealer_id where d.code = 'NDM';
  perform app_test.assert_equals(v_count, 0, 'nor a single one of their accounts');
end;
$$;

-- -----------------------------------------------------------------------------
-- Suspending a dealer actually suspends them (0055)
-- -----------------------------------------------------------------------------
reset role;
select app_test.logout();

do $$
begin
  update public.dealers set status = 'SUSPENDED' where code = 'NDM';
end;
$$;

set role authenticated;
select app_test.login('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa');

do $$
declare v_count int;
begin
  select count(*)::int into v_count from public.chart_of_accounts;
  perform app_test.assert_equals(v_count, 0,
    'a suspended dealer''s users lose access everywhere at once (0055)');

  select count(*)::int into v_count from public.branches;
  perform app_test.assert_equals(v_count, 0, 'including their own branches');
end;
$$;

reset role;
select app_test.logout();

do $$
begin
  update public.dealers set status = 'ACTIVE' where code = 'NDM';
end;
$$;

set role authenticated;
select app_test.login('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa');

do $$
declare v_count int;
begin
  select count(*)::int into v_count from public.chart_of_accounts;
  perform app_test.assert_equals(v_count, 42,
    'and reactivating restores it — suspension is a switch, not a deletion');
end;
$$;

-- -----------------------------------------------------------------------------
-- Rollback: purge while nothing is posted, refuse once something is
-- -----------------------------------------------------------------------------
reset role;
select app_test.login('99999999-9999-4999-8999-999999999999');

do $$
declare
  v_new    uuid;
  v_branch uuid;
  v_recv   uuid;
  v_sales  uuid;
  v_count  int;
begin
  select id into v_new from public.dealers where code = 'NDM';
  select id into v_branch from public.branches where dealer_id = v_new;
  select id into v_recv  from public.chart_of_accounts where dealer_id = v_new and code = '1300';
  select id into v_sales from public.chart_of_accounts where dealer_id = v_new and code = '4100';

  -- Nothing posted yet, so a purge is honest.
  perform app_test.assert_equals(
    (select count(*)::int from public.journal_entries where dealer_id = v_new), 0,
    'the new tenant has posted nothing yet');

  -- Post something, and the purge must refuse from then on.
  perform app.post_journal(
    v_new, v_branch, current_date, 'SALES', 'First invoice',
    jsonb_build_array(
      jsonb_build_object('account_id', v_recv,  'debit', 1000, 'credit', 0),
      jsonb_build_object('account_id', v_sales, 'debit', 0, 'credit', 1000)
    ));

  perform app_test.assert_raises(
    format('select public.purge_dealer(%L, ''Created by mistake'')', v_new),
    'a tenant that has posted a journal cannot be purged — that ledger is theirs');

  perform app_test.assert_raises(
    format('select public.purge_dealer(%L, '''')', v_new),
    'and a purge always requires a reason');

  select count(*)::int into v_count from public.dealers where id = v_new;
  perform app_test.assert_equals(v_count, 1, 'the refused purge changed nothing');
end;
$$;

-- A second tenant, provisioned and then purged before it trades.
do $$
declare
  v_throwaway uuid;
  v_res       record;
  v_count     int;
  v_sbm_before int;
  v_sbm_after  int;
begin
  select count(*)::int into v_sbm_before
    from public.chart_of_accounts c join public.dealers d on d.id = c.dealer_id
   where d.code = 'SBM';

  insert into auth.users (id, email)
  values ('cccccccc-1111-4111-8111-cccccccccccc', 'owner@throwaway.example')
  on conflict (id) do nothing;

  select * into v_res from app.provision_dealer(
    p_code => 'TRW', p_legal_name => 'Throwaway Motors', p_trade_name => 'Throwaway',
    p_state => 'Tamil Nadu', p_state_code => '33',
    p_owner_email => 'owner@throwaway.example', p_owner_name => 'Temp Owner',
    p_owner_user_id => 'cccccccc-1111-4111-8111-cccccccccccc');

  v_throwaway := v_res.new_dealer_id;

  perform public.purge_dealer(v_throwaway, 'Wrong GSTIN, re-onboarding');

  select count(*)::int into v_count from public.dealers where id = v_throwaway;
  perform app_test.assert_equals(v_count, 0, 'a tenant that never traded can be purged');

  select count(*)::int into v_count from public.chart_of_accounts where dealer_id = v_throwaway;
  perform app_test.assert_equals(v_count, 0, 'and its accounts go with it');

  -- The whole point: purging one tenant must not touch another.
  select count(*)::int into v_sbm_after
    from public.chart_of_accounts c join public.dealers d on d.id = c.dealer_id
   where d.code = 'SBM';
  perform app_test.assert_equals(v_sbm_after, v_sbm_before,
    'and the existing dealer is untouched by it');
end;
$$;

select app_test.logout();
