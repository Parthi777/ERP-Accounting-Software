-- =============================================================================
-- TEST — the figures above a list describe the period, not the page
-- =============================================================================
-- Spec §27, §41, §51.
--
-- This test only means anything above the row cap. Below it every version of
-- this code agrees, which is exactly why the bug survived: with demo data the
-- screens were right, and they stayed right until a dealer's 201st finance
-- application, at which point the tiles began quietly describing the most recent
-- 200 while presenting themselves as the period.
--
-- So it seeds past the cap on purpose.
--
-- The guarantees asserted here:
--   * the totals count every matching row, however many the list drew;
--   * summing the capped page gives a *different, smaller* answer — the bug is
--     reproduced here so a regression cannot pass by making both wrong;
--   * search reaches rows beyond the cap, which it could not when it ran in the
--     application over an already-truncated page;
--   * the list and the totals always agree about what "matching" means;
--   * service invoice totals exclude counter sales, matching their list.
-- =============================================================================

\echo '--- list totals ---'

do $$
declare
  v_dealer   uuid;
  v_main     uuid;
  v_customer uuid;
  v_company  uuid;
  v_needle   uuid;
  v_listed   bigint;
  v_counted  bigint;
  v_page_sum numeric;
  v_all_sum  numeric;
  v_found    bigint;
  i          int;
begin
  select id into v_dealer from public.dealers  where code = 'SBM';
  select id into v_main   from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_customer from public.customers where dealer_id = v_dealer limit 1;
  select id into v_company  from public.finance_companies where dealer_id = v_dealer limit 1;

  -- ── Seed past the cap ───────────────────────────────────────────────────
  -- Dated forward so these are the *most recent* and therefore the ones the
  -- capped page would show.
  for i in 1..250 loop
    -- approved_amount is required when the status is APPROVED
    -- (fa_approved_amount_check) — an approval with no figure is not one.
    insert into public.finance_applications
      (dealer_id, branch_id, application_number, application_date,
       customer_id, finance_company_id, loan_amount, approval_status,
       approved_amount)
    values
      (v_dealer, v_main, 'BULK-' || lpad(i::text, 4, '0'),
       date '2026-03-01' + i,
       v_customer, v_company, 1000, 'APPROVED', 1000);
  end loop;

  -- One deliberately old row, so it falls outside any recent-first page.
  insert into public.finance_applications
    (dealer_id, branch_id, application_number, application_date,
     customer_id, finance_company_id, loan_amount, approval_status,
     approved_amount)
  values
    (v_dealer, v_main, 'NEEDLE-0001', date '2020-01-01',
     v_customer, v_company, 7777, 'APPROVED', 7777)
  returning id into v_needle;

  -- ── The list is capped; the totals are not ──────────────────────────────
  select count(*) into v_listed  from public.finance_applications_list('ALL', null, null, 200);
  select applications into v_counted from public.finance_application_totals();

  perform app_test.assert_equals(
    v_listed, 200::bigint,
    'the list stops at the cap it was given'
  );
  perform app_test.assert_equals(
    (v_counted >= 251), true,
    'the totals count every matching application, not the page'
  );

  -- ── Reproduce the bug, so a regression cannot pass ──────────────────────
  -- This is what the screen used to do: sum the rows it drew.
  select coalesce(sum(loan_amount), 0) into v_page_sum
    from public.finance_applications_list('ALL', null, null, 200);
  select loan_amount into v_all_sum from public.finance_application_totals();

  perform app_test.assert_equals(
    (v_all_sum > v_page_sum), true,
    'summing the page understates the period — the defect this replaces'
  );

  -- ── Search reaches past the cap ─────────────────────────────────────────
  -- The old code filtered in TypeScript after the limit, so this row — 251st
  -- most recent — was never fetched and could not be found.
  select count(*) into v_found
    from public.finance_applications_list('ALL', null, 'NEEDLE', 200);
  perform app_test.assert_equals(
    v_found, 1::bigint,
    'search finds a row that lies beyond the page cap'
  );

  select applications into v_counted
    from public.finance_application_totals('ALL', null, 'NEEDLE');
  perform app_test.assert_equals(
    v_counted, 1::bigint,
    'and the totals narrow to the same one row'
  );

  select loan_amount into v_all_sum
    from public.finance_application_totals('ALL', null, 'NEEDLE');
  perform app_test.assert_equals(
    v_all_sum, 7777::numeric,
    'the searched total is that row, not the unfiltered sum'
  );

  -- ── A status filter narrows both the same way ───────────────────────────
  select count(*) into v_listed
    from public.finance_applications_list('PENDING', null, null, 500);
  select applications into v_counted
    from public.finance_application_totals('PENDING');
  perform app_test.assert_equals(
    v_listed, v_counted,
    'list and totals agree under a status filter'
  );

  -- ── An unmatched search returns nothing, not everything ─────────────────
  select applications into v_counted
    from public.finance_application_totals('ALL', null, 'no-such-applicant-xyz');
  perform app_test.assert_equals(
    v_counted, 0::bigint,
    'a search matching nothing totals zero, not the whole table'
  );
end $$;

-- ── Service invoices: the same shape, and counter sales stay out ───────────
do $$
declare
  v_billed  numeric;
  v_direct  numeric;
  v_count   bigint;
  v_service bigint;
begin
  select total_amount, invoices into v_billed, v_count
    from public.service_invoice_totals();

  select coalesce(sum(total_amount), 0), count(*) into v_direct, v_service
    from public.service_invoices where invoice_type = 'SERVICE';

  perform app_test.assert_equals(
    v_billed, v_direct,
    'service totals match the table they claim to summarise'
  );
  perform app_test.assert_equals(
    v_count, v_service,
    'and count the same invoices'
  );

  -- Counter sales share the table and are a different screen (spec §33).
  perform app_test.assert_equals(
    (select count(*) from public.service_invoices where invoice_type <> 'SERVICE') >= 0, true,
    'counter sales live in the same table'
  );
  perform app_test.assert_equals(
    v_count = (select count(*) from public.service_invoices), false,
    'and are excluded from the service totals'
  );
end $$;

-- ── Tenant isolation: an aggregate must not count what you cannot read ─────
--
-- These functions are SECURITY INVOKER and `stable`, so RLS decides what they
-- see. That is the whole reason they are not SECURITY DEFINER: a total computed
-- over rows the reader may not open is a leak that reports itself as a number,
-- and a number is harder to notice than a row.
--
-- The blocks above run as the table owner, who bypasses RLS — so none of them
-- test this. `set role authenticated` is what makes the assertion real.
set role authenticated;
select app_test.login('11111111-1111-4111-8111-111111111111');

do $$
declare
  v_visible bigint;
  v_total   bigint;
begin
  select applications into v_visible from public.finance_application_totals();
  select count(*) into v_total from public.finance_applications;

  perform app_test.assert_equals(
    v_visible, v_total,
    'the totals count exactly the applications this session can read'
  );

  perform app_test.assert_equals(
    (v_visible > 0), true,
    'and that is not zero — an empty result would pass the check above vacuously'
  );

  perform app_test.assert_equals(
    (select count(*) from public.finance_applications_list('ALL', null, null, 1000)),
    v_visible,
    'the list and the totals see the same rows under RLS'
  );
end $$;

select app_test.logout();
reset role;
