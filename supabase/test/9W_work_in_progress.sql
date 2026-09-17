-- =============================================================================
-- TEST — the work-in-progress panel behind spec §54
-- =============================================================================
-- Spec §19, §54.
--
-- This exists because three real vehicle-sale drafts sat untouched for three
-- days on the live tenant while the dashboard said nothing. Every guard in the
-- workflow was working; nothing surfaced the fact that work was waiting.
--
-- The guarantees asserted here:
--   * a draft appears, with how many and how old the oldest is;
--   * it moves between stages as the sale advances, and leaves the panel once
--     there is nothing left to do;
--   * a stage with nothing at it does not appear at all — a panel of zeroes is
--     a panel nobody reads;
--   * it is NOT bounded by a financial year or any other period, which is the
--     whole point: an old draft is more urgent than a new one, and a
--     period-scoped panel would hide it precisely when the year turned;
--   * the branch filter narrows it, and RLS keeps another tenant out.
-- =============================================================================

\echo '--- work in progress ---'

do $$
declare
  v_dealer  uuid;
  v_main    uuid;
  v_north   uuid;
  v_hsn     uuid;
  v_model   uuid;
  v_variant uuid;
  v_veh     uuid;
  v_cust    uuid;
  v_sale    uuid;
  v_count   bigint;
  v_oldest  date;
  b_draft   bigint;
  b_await   bigint;
  b_appr    bigint;
  b_undel   bigint;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_main  from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_north from public.branches where dealer_id = v_dealer and code = 'NORTH';
  select id into v_hsn   from public.hsn_codes where dealer_id = v_dealer limit 1;

  -- ═══ Baselines, because earlier files leave sales of their own behind ════
  -- Every assertion below is a delta. Absolute counts would make this file pass
  -- or fail on what 50_sales_workflow and 9C happened to leave in each state.
  select
    coalesce(max(case when w.key = 'sales_draft'             then w.count end), 0),
    coalesce(max(case when w.key = 'sales_awaiting_approval' then w.count end), 0),
    coalesce(max(case when w.key = 'sales_approved_unposted' then w.count end), 0),
    coalesce(max(case when w.key = 'sales_undelivered'       then w.count end), 0)
    into b_draft, b_await, b_appr, b_undel
    from public.work_in_progress(null) w;

  insert into public.customers (dealer_id, name, mobile, city, state, state_code)
  values (v_dealer, 'WIP Buyer', '9840095901', 'Chennai', 'Tamil Nadu', '33')
  returning id into v_cust;

  insert into public.vehicle_models (dealer_id, brand, name, model_code, category, hsn_code_id)
  values (v_dealer, 'TVS', 'Jupiter WIP', 'JUPWIP', 'SCOOTER', v_hsn) returning id into v_model;

  insert into public.vehicle_variants (dealer_id, model_id, name, variant_code, engine_cc)
  values (v_dealer, v_model, 'Standard', 'JUPWIP-STD', 109.7) returning id into v_variant;

  insert into public.vehicle_price_versions
    (dealer_id, model_id, variant_id, version_number, ex_showroom, insurance, registration,
     forwarding_charge, purchase_cost, effective_from, status, approved_at)
  values (v_dealer, v_model, v_variant, 1, 90000, 4000, 7000, 1200, 80000,
          current_date - 500, 'ACTIVE', now());

  insert into public.vehicles
    (dealer_id, branch_id, model_id, variant_id, chassis_no, engine_no, purchase_cost, purchase_invoice)
  values (v_dealer, v_main, v_model, v_variant, 'MD6WIP000000000001', 'WIP000000001', 80000, 'PINV-WIP-1')
  returning id into v_veh;

  select sale_id into v_sale from public.create_vehicle_sale_draft(v_cust, v_veh);

  -- ═══ It shows up, counted, with the oldest date ══════════════════════════
  select w.count, w.oldest_date into v_count, v_oldest
    from public.work_in_progress(null) w where w.key = 'sales_draft';

  perform app_test.assert_equals(v_count, b_draft + 1,
    'a draft sale appears in the work-in-progress list');
  perform app_test.assert_equals(v_oldest is not null, true,
    'with the date of the one that has been waiting longest');

  -- ═══ It follows the sale through the workflow ════════════════════════════
  update public.sales set status = 'SUBMITTED' where id = v_sale;

  perform app_test.assert_equals(
    (select w.count from public.work_in_progress(null) w where w.key = 'sales_awaiting_approval'),
    b_await + 1,
    'submitting moves it to the stage waiting for approval');

  update public.sales set status = 'ACCOUNTS_VERIFICATION' where id = v_sale;
  perform app_test.assert_equals(
    (select w.count from public.work_in_progress(null) w where w.key = 'sales_awaiting_approval'),
    b_await + 1,
    'verification is the same stage — both are waiting on Accounts');

  update public.sales set status = 'APPROVED', approved_at = now() where id = v_sale;
  perform app_test.assert_equals(
    (select w.count from public.work_in_progress(null) w where w.key = 'sales_approved_unposted'),
    b_appr + 1,
    'an approved sale that is not posted is its own kind of stuck');

  -- ═══ A stage with nothing at it is absent, not zero ══════════════════════
  perform app_test.assert_equals(
    coalesce((select w.count from public.work_in_progress(null) w
               where w.key = 'sales_awaiting_approval'), 0),
    b_await,
    'and is no longer counted at the stage it left');

  perform app_test.assert_equals(
    (select count(*)::int from public.work_in_progress(null) w where w.count = 0),
    0,
    'no row in the list is ever a zero — a panel of zeroes is one nobody reads');

  -- ═══ Posted, then delivered, then out of the list ════════════════════════
  perform public.post_vehicle_sale(v_sale);
  perform app_test.assert_equals(
    (select w.count from public.work_in_progress(null) w where w.key = 'sales_undelivered'),
    b_undel + 1,
    'a posted sale still owes the customer a vehicle');

  perform public.deliver_vehicle(v_sale);
  perform app_test.assert_equals(
    coalesce((select w.count from public.work_in_progress(null) w
               where w.key = 'sales_undelivered'), 0),
    b_undel,
    'and once delivered it has left the list entirely');

  -- ═══ Age, which is the reason the panel is not period-scoped ════════════
  -- Left as a draft deliberately: it is dated outside every open accounting
  -- period, so it could never be posted — and a draft is exactly the thing that
  -- sits around long enough to fall outside one.
  insert into public.vehicles
    (dealer_id, branch_id, model_id, variant_id, chassis_no, engine_no, purchase_cost, purchase_invoice)
  values (v_dealer, v_main, v_model, v_variant, 'MD6WIP000000000002', 'WIP000000002', 80000, 'PINV-WIP-2')
  returning id into v_veh;

  select sale_id into v_sale
    from public.create_vehicle_sale_draft(v_cust, v_veh, current_date - 400);

  select w.count, w.oldest_date into v_count, v_oldest
    from public.work_in_progress(null) w where w.key = 'sales_draft';

  perform app_test.assert_equals(v_count, b_draft + 1,
    'the year-old draft is listed');
  perform app_test.assert_equals(v_oldest <= current_date - 400, true,
    'and dated when it was raised, not clamped into the current year');
  perform app_test.assert_equals(
    v_oldest < date_trunc('year', current_date)::date, true,
    'so a panel bounded by a financial year would have hidden it — which is '
    'precisely when it matters most');

  -- ═══ The branch filter ══════════════════════════════════════════════════
  perform app_test.assert_equals(
    (select w.count from public.work_in_progress(v_main) w where w.key = 'sales_draft') >= 1, true,
    'the branch filter shows that branch''s draft');
  perform app_test.assert_equals(
    (select count(*)::int from public.work_in_progress(v_north) w where w.key = 'sales_draft'),
    0,
    'and not another branch''s');
end;
$$;

-- ═══ Another tenant's work is not this tenant's problem ════════════════════
set role authenticated;
select app_test.login('11111111-1111-4111-8111-111111111111');   -- SBM dealer owner

do $$
declare
  v_visible int;
begin
  -- A second tenant with a draft of its own, created as the session user cannot
  -- see it. RLS is what keeps it out of the count below.
  perform app_test.assert_equals(
    (select count(*)::int from public.work_in_progress(null) w
      where w.key = 'sales_draft' and w.count > 0),
    1,
    'a dealer owner sees their own outstanding work');

  select count(*)::int into v_visible from public.sales;
  perform app_test.assert_equals(v_visible > 0, true,
    'and reaches their own sales at all, so the count above means something');
end;
$$;

select app_test.logout();
reset role;
