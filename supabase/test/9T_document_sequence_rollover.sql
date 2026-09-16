-- =============================================================================
-- TEST — document series a dealer is actually given, and the year they turn over
-- =============================================================================
-- Spec §45, §48, §60.3.
--
-- 91_document_numbering.sql asserts the dealer-wide scope rule against the demo
-- dealer. It cannot see what 0072 fixes, because the demo dealer comes from
-- seed.sql, which lists all fifteen series — while app.provision_dealer() listed
-- ten. The tenant every real dealer gets was the one nobody tested.
--
-- So this file provisions its own dealer and asserts against that.
--
-- The guarantees asserted here:
--   * a freshly provisioned dealer has every series any database function asks
--     for — STOCK_TRANSFER, FINANCE_APPLICATION and FINANCE_SETTLEMENT included,
--     which before 0072 it did not, so transfers and finance both raised on a
--     tenant that dealer_readiness() had just called ready;
--   * dealer_readiness() fails, and names the series, when one is missing —
--     the old `count(*) >= 9` could not, since provisioning wrote ten;
--   * a series configured for one financial year carries into another, forward
--     for a year-end and backward for a back-dated opening balance, keeping its
--     prefix and padding and restarting its counter;
--   * a doc_type configured in no year at all still raises, which is the rule
--     0056 set out and 0072 is careful not to weaken.
-- =============================================================================

\echo '--- document series: provisioning and year rollover ---'

-- Provisioning is platform-admin work.
select app_test.login('99999999-9999-4999-8999-999999999999');

do $$
declare
  v_owner    uuid := 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb';
  v_res      record;
  v_dealer   uuid;
  v_branch   uuid;
  v_fy       text;
  v_next     text;
  v_prev     text;
  v_missing  int;
  v_a        text;
  v_b        text;
  v_last     bigint;
  v_ok       boolean;
  v_detail   text;
begin
  -- A platform admin, and an auth account for the incoming owner.
  insert into auth.users (id, email) values
    ('99999999-9999-4999-8999-999999999999', 'platform@example.com'),
    (v_owner, 'owner@rollover.example')
  on conflict (id) do nothing;

  insert into public.user_profiles (id, dealer_id, full_name, email, is_platform_admin, status)
  values ('99999999-9999-4999-8999-999999999999', null, 'Platform Admin', 'platform@example.com', true, 'ACTIVE')
  on conflict (id) do update set is_platform_admin = true;

  select * into v_res from app.provision_dealer(
    p_code          => 'DSR',
    p_legal_name    => 'Rollover Motors Private Limited',
    p_trade_name    => 'Rollover Motors',
    p_state         => 'Tamil Nadu',
    p_state_code    => '33',
    p_owner_email   => 'owner@rollover.example',
    p_owner_name    => 'Owner Raja',
    p_owner_user_id => v_owner,
    p_branch_name   => 'Madurai Main',
    p_gstin         => '33AACCR5678B1ZP',
    p_city          => 'Madurai');

  v_dealer := v_res.new_dealer_id;
  v_branch := v_res.new_branch_id;
  v_fy     := app.financial_year_token(v_dealer, current_date);

  -- ═══ Every series the database asks for, on a tenant nobody hand-fixed ════
  -- Before 0072 this found three missing: the dealer could not dispatch a
  -- transfer, raise a finance application or settle with a finance company.
  select count(*)::int into v_missing
    from app.required_document_series() s
    left join public.document_sequences ds
           on ds.dealer_id = v_dealer
          and ds.doc_type = s.doc_type
          and ds.financial_year = v_fy
          and ds.branch_id is null
   where ds.id is null;

  perform app_test.assert_equals(v_missing, 0,
    'a provisioned dealer has every required series for the current year');

  -- The three that provisioning used to omit, named, so a regression says which.
  foreach v_a in array array['STOCK_TRANSFER', 'FINANCE_APPLICATION', 'FINANCE_SETTLEMENT']
  loop
    v_next := app.next_document_number(v_dealer, v_branch, v_a, v_fy);
    perform app_test.assert_equals(v_next ~ ('^[A-Z]{1,6}-' || v_fy || '-[0-9]{6}$'), true,
      format('%s issues a number on a freshly provisioned dealer', v_a));
  end loop;

  -- ═══ readiness names what is missing ═════════════════════════════════════
  delete from public.document_sequences
   where dealer_id = v_dealer and doc_type = 'BANK_RECONCILIATION'
     and financial_year = v_fy and branch_id is null;

  select r.ok, r.detail into v_ok, v_detail
    from public.dealer_readiness(v_dealer) r
   where r.check_name = 'Document sequences';

  perform app_test.assert_equals(v_ok, false,
    'readiness fails when a required series is missing');
  perform app_test.assert_equals(v_detail like '%BANK_RECONCILIATION%', true,
    'and says which one, rather than counting to nine');

  perform app.ensure_document_sequences(v_dealer, v_fy);

  select r.ok into v_ok
    from public.dealer_readiness(v_dealer) r
   where r.check_name = 'Document sequences';
  perform app_test.assert_equals(v_ok, true,
    'ensure_document_sequences() puts it back');

  -- ═══ The year turning over ═══════════════════════════════════════════════
  -- Take a number in the current year first, so the carried series is provably
  -- a new counter and not the same row.
  v_a := app.next_document_number(v_dealer, v_branch, 'VEHICLE_INVOICE', v_fy);
  v_next := (v_fy::int + 1)::text;

  v_b := app.next_document_number(v_dealer, v_branch, 'VEHICLE_INVOICE', v_next);
  perform app_test.assert_equals(v_b, 'INV-' || v_next || '-000001',
    'the next financial year starts its own counter at one, with the same prefix');

  select last_number into v_last
    from public.document_sequences
   where dealer_id = v_dealer and doc_type = 'VEHICLE_INVOICE'
     and financial_year = v_fy and branch_id is null;
  perform app_test.assert_equals(v_last, right(v_a, 6)::bigint,
    'and the year just ended is left exactly where it was');

  -- Padding carries too, not just the prefix.
  update public.document_sequences set padding = 8
   where dealer_id = v_dealer and doc_type = 'JOURNAL'
     and financial_year = v_fy and branch_id is null;

  v_b := app.next_document_number(v_dealer, null, 'JOURNAL', v_next);
  perform app_test.assert_equals(v_b, 'JE-' || v_next || '-00000001',
    'the carried series keeps its padding, not the default');

  -- ═══ Backward, for a back-dated opening balance (0067's case) ════════════
  v_prev := (v_fy::int - 1)::text;
  v_b := app.next_document_number(v_dealer, null, 'JOURNAL', v_prev);
  perform app_test.assert_equals(v_b, 'JE-' || v_prev || '-00000001',
    'a back-dated document reaches the year it is dated into');

  -- ═══ Nothing is invented ═════════════════════════════════════════════════
  perform app_test.assert_raises(
    format('select app.next_document_number(%L, %L, ''NOT_A_DOC_TYPE'', %L)',
           v_dealer, v_branch, v_fy),
    'a doc_type configured in no year at all is still refused');

  perform app_test.assert_raises(
    format('select app.next_document_number(%L, %L, ''VEHICLE_INVOICE'', ''not-a-year'')',
           v_dealer, v_branch),
    'and a year token that is not a year is refused rather than carried');

  -- ═══ The scope rule from 0039 still decides where a carried row lands ════
  -- A type kept per branch carries into the new year per branch, not dealer-wide.
  insert into public.document_sequences
    (dealer_id, branch_id, doc_type, financial_year, prefix, padding, last_number)
  values (v_dealer, v_branch, 'TEST_BRANCH_CARRY', v_fy, 'TBC', 6, 7);

  v_b := app.next_document_number(v_dealer, v_branch, 'TEST_BRANCH_CARRY', v_next);
  perform app_test.assert_equals(v_b, 'TBC-' || v_next || '-000001',
    'a per-branch series carries into the new year as a per-branch series');

  select count(*)::int into v_missing
    from public.document_sequences
   where dealer_id = v_dealer and doc_type = 'TEST_BRANCH_CARRY'
     and financial_year = v_next and branch_id is null;
  perform app_test.assert_equals(v_missing, 0,
    'and does not quietly become a dealer-wide one');
end;
$$;

select app_test.logout();
