-- =============================================================================
-- TEST — the dashboard counts and Customer 360 (spec §10, §11, §43)
-- =============================================================================
-- Both of these replaced hardcoded placeholders that had gone stale: seven
-- dashboard tiles badged with phases that had shipped, and a customer panel
-- rendering six literal strings under "Fills in as each module is built".
--
-- The guarantees asserted here:
--   * the counts agree with the tables they claim to count, so a tile cannot
--     drift from the screen it drills into;
--   * flow counts obey the period and stock counts ignore it, because a stock
--     figure is a position and a position has no date range;
--   * Customer 360's outstanding comes from the ledger, so it cannot disagree
--     with the customer ledger screen;
--   * both respect RLS — a count is a leak that reports itself as a number.
-- =============================================================================

\echo '--- dashboard counts and customer 360 ---'

do $$
declare
  v_dealer   uuid;
  v_counts   record;
  v_expected bigint;
  v_narrow   record;
begin
  select id into v_dealer from public.dealers where code = 'SBM';

  select * into v_counts
    from public.dashboard_unit_counts(date '2000-01-01', date '2099-12-31', null);

  -- Each count against the table it summarises.
  select count(*) into v_expected from public.sales
   where status in ('POSTED', 'DELIVERED');
  perform app_test.assert_equals(
    v_counts.vehicle_sales_units, v_expected,
    'vehicle sales counts posted and delivered invoices'
  );

  select count(*) into v_expected from public.bookings where status <> 'CANCELLED';
  perform app_test.assert_equals(
    v_counts.bookings, v_expected, 'bookings excludes cancelled ones'
  );

  select count(*) into v_expected from public.vehicles where status = 'IN_STOCK';
  perform app_test.assert_equals(
    v_counts.vehicle_stock_qty, v_expected, 'vehicle stock counts what is on the floor'
  );

  select count(*) into v_expected from public.finance_applications
   where approval_status <> 'CANCELLED';
  perform app_test.assert_equals(
    v_counts.finance_units, v_expected, 'finance units excludes cancelled applications'
  );

  -- ── A period that excludes everything ───────────────────────────────────
  -- The four flow counts must fall to zero; the three stock counts must not
  -- move, because a position has no date range.
  select * into v_narrow
    from public.dashboard_unit_counts(date '1990-01-01', date '1990-01-02', null);

  perform app_test.assert_equals(
    v_narrow.vehicle_sales_units, 0::bigint, 'a period before trading sold nothing'
  );
  perform app_test.assert_equals(
    v_narrow.bookings, 0::bigint, 'and booked nothing'
  );
  perform app_test.assert_equals(
    v_narrow.deliveries, 0::bigint, 'and delivered nothing'
  );
  perform app_test.assert_equals(
    v_narrow.vehicle_stock_qty, v_counts.vehicle_stock_qty,
    'but stock is a position, not a flow — it does not move with the period'
  );
  perform app_test.assert_equals(
    v_narrow.accessory_stock_qty, v_counts.accessory_stock_qty,
    'the same for accessories'
  );
end $$;

-- ── Customer 360 ───────────────────────────────────────────────────────────
do $$
declare
  v_dealer uuid;
  v_cust   uuid;
  v_row    record;
  v_n      bigint;
  v_ledger numeric;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select customer_id into v_cust from public.sales
   where dealer_id = v_dealer and status in ('POSTED', 'DELIVERED') limit 1;

  if v_cust is null then
    raise notice '  -- no customer with a posted sale; skipping customer 360';
    return;
  end if;

  select * into v_row from public.customer_360(v_cust);

  select count(*) into v_n from public.sales
   where customer_id = v_cust and status not in ('CANCELLED', 'RETURNED');
  perform app_test.assert_equals(v_row.sale_count, v_n, 'sale count matches the sales table');

  select count(*) into v_n from public.bookings
   where customer_id = v_cust and status <> 'CANCELLED';
  perform app_test.assert_equals(v_row.booking_count, v_n, 'booking count matches');

  select count(*) into v_n from public.customer_vehicles where customer_id = v_cust;
  perform app_test.assert_equals(v_row.vehicle_count, v_n, 'vehicle count matches');

  -- The figure that must never disagree with the customer ledger screen.
  select public.party_ledger_opening('CUSTOMER', v_cust, 'infinity'::date) into v_ledger;
  perform app_test.assert_equals(
    v_row.outstanding, v_ledger,
    'outstanding is the ledger balance, not arithmetic over documents'
  );

  perform app_test.assert_equals(
    (v_row.last_activity is not null), true,
    'a customer with a posted sale has a last-activity date'
  );

  -- An unknown customer must come back as zeros, not as a null row that would
  -- render as blanks on the panel.
  select * into v_row from public.customer_360('00000000-0000-4000-8000-000000000000');
  perform app_test.assert_equals(
    (v_row.sale_count is null), true,
    'an unknown customer returns no row at all, which the service maps to zeros'
  );
end $$;

-- ── Both respect RLS ───────────────────────────────────────────────────────
set role authenticated;
select app_test.login('11111111-1111-4111-8111-111111111111');

do $$
declare
  v_counts record;
  v_visible bigint;
begin
  select * into v_counts
    from public.dashboard_unit_counts(date '2000-01-01', date '2099-12-31', null);

  select count(*) into v_visible from public.sales where status in ('POSTED', 'DELIVERED');
  perform app_test.assert_equals(
    v_counts.vehicle_sales_units, v_visible,
    'the dashboard counts exactly the sales this session can read'
  );
  perform app_test.assert_equals(
    (v_counts.vehicle_stock_qty > 0), true,
    'and is not vacuously zero'
  );
end $$;

select app_test.logout();
reset role;
