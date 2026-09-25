-- =============================================================================
-- TEST — posting authority and the sale workflow (0089)
-- =============================================================================
-- A cashier holds sales.create/submit, cashbook receipts and billing. They must
-- not be able to post opening balances, a sale, a sale return or a booking
-- refund, nor walk their own sale through verification and approval.
-- =============================================================================

\echo '--- posting authority ---'

-- Fixture: a DRAFT sale at MAIN for the cashier to work on.
create temporary table fixture_sale as
select s.id from public.sales s join public.branches b on b.id = s.branch_id
 where b.code = 'MAIN' and s.status = 'DRAFT' and s.dealer_id = (select id from public.dealers where code = 'SBM')
 limit 1;
grant select on fixture_sale to authenticated;

-- The accounts the probes post to, read here because the cashier cannot read
-- the chart — a probe must fail on authority, not on a missing account.
create temporary table fixture_accounts as
select (select c.id from public.chart_of_accounts c join public.dealers d on d.id = c.dealer_id where d.code = 'SBM' and c.code = '4800') as a,
       (select c.id from public.chart_of_accounts c join public.dealers d on d.id = c.dealer_id where d.code = 'SBM' and c.code = '5900') as b;
grant select on fixture_accounts to authenticated;

select app_test.login('33333333-3333-4333-8333-333333333333');
set role authenticated;

do $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_main   uuid := (select id from public.branches where dealer_id = app.current_dealer_id() and code = 'MAIN');
  v_a      uuid;
  v_b      uuid;
  v_sale   uuid := (select id from fixture_sale);
  v_type   text;
begin
  select a, b into v_a, v_b from fixture_accounts;

  foreach v_type in array array['OPENING_BALANCE', 'SALE', 'SALE_RETURN', 'BOOKING_REFUND', 'MANUAL_JOURNAL', 'SOMETHING_NEW'] loop
    perform app_test.assert_raises(
      format($q$select app.post_journal(%L, %L, current_date, 'MANUAL', 'probe', jsonb_build_array(
        jsonb_build_object('account_id', %L::uuid, 'debit', 1, 'credit', 0),
        jsonb_build_object('account_id', %L::uuid, 'debit', 0, 'credit', 1)), %L, null, null)$q$,
        v_dealer, v_main, v_b, v_a, v_type),
      format('a cashier cannot post a %s entry, even calling the engine directly', v_type),
      'You may not post');
  end loop;

  perform app_test.assert_raises(
    format($q$select public.post_opening_balances('CUSTOMER', '[{"code":"X","amount":1}]'::jsonb, current_date, 'x', null, %L)$q$, v_dealer),
    'nor post opening balances through their function');

  if v_sale is not null then
    update public.sales set status = 'SUBMITTED' where id = v_sale;
    perform app_test.assert_equals((select status from public.sales where id = v_sale), 'SUBMITTED',
      'a cashier may submit their sale');
    perform app_test.assert_raises(
      format($q$update public.sales set status = 'ACCOUNTS_VERIFICATION' where id = %L$q$, v_sale),
      'but not move it into accounts verification');
    perform app_test.assert_raises(
      format($q$select public.post_vehicle_sale(%L)$q$, v_sale),
      'nor post it');
    update public.sales set status = 'DRAFT' where id = v_sale;
    perform app_test.assert_equals((select status from public.sales where id = v_sale), 'DRAFT',
      'and may recall a submitted sale to draft');
  end if;
end $$;

reset role;
select app_test.logout();

-- The accountant can do what the cashier could not.
select app_test.login('22222222-2222-4222-8222-222222222222');
set role authenticated;
do $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_main   uuid := (select id from public.branches where dealer_id = app.current_dealer_id() and code = 'MAIN');
begin
  perform app_test.assert_equals(
    (select app.post_journal(v_dealer, v_main, current_date, 'MANUAL', 'accountant probe', jsonb_build_array(
       jsonb_build_object('account_id', (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '5900'), 'debit', 1, 'credit', 0),
       jsonb_build_object('account_id', (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '4800'), 'debit', 0, 'credit', 1)),
       'MANUAL_JOURNAL', null, null) is not null), true,
    'the accountant may post a manual journal');
end $$;
reset role;
select app_test.logout();
