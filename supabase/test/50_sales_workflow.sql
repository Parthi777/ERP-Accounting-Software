-- =============================================================================
-- TEST — booking through to delivery
-- =============================================================================
-- Spec §18, §19, §48. Drives the whole workflow through the public operations
-- the application actually calls, and asserts the accounting at each step.
-- =============================================================================

\echo '--- sales workflow ---'

do $$
declare
  v_dealer   uuid;
  v_branch   uuid;
  v_customer uuid;
  v_model    uuid;
  v_variant  uuid;
  v_vehicle  uuid;
  v_booking  record;
  v_sale     uuid;
  v_invoice  text;
  v_entry    uuid;
  v_advance  numeric;
  v_receipt  record;
  v_delivery text;
  v_hsn      uuid;
  v_finance_co uuid;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'MAIN';

  -- The default accounting rules from 0027 must be present, or nothing posts.
  -- Assert the specific mapping this test depends on, not merely that some rule
  -- exists — a generic count passes even when the one that matters is missing.
  perform app_test.assert_equals(
    public.resolve_account(v_dealer, 'BOOKING', 'ADVANCE', 'CASH', v_branch) is not null, true,
    'the BOOKING/ADVANCE/CASH rule is installed'
  );
  perform app_test.assert_equals(
    public.resolve_account(v_dealer, 'BOOKING', 'ADVANCE', 'CUSTOMER_ADVANCE', v_branch) is not null, true,
    'the BOOKING/ADVANCE/CUSTOMER_ADVANCE rule is installed'
  );

  insert into public.customers (dealer_id, name, mobile, city, state, state_code)
  values (v_dealer, 'Workflow Test Customer', '9840098001', 'Chennai', 'Tamil Nadu', '33')
  returning id into v_customer;

  insert into public.hsn_codes (dealer_id, code, description)
  values (v_dealer, '87113010', 'Motorcycles 125-250cc') returning id into v_hsn;

  insert into public.vehicle_models (dealer_id, brand, name, model_code, category, hsn_code_id)
  values (v_dealer, 'TVS', 'Raider 125', 'RAIDER125', 'MOTORCYCLE', v_hsn) returning id into v_model;

  insert into public.vehicle_variants (dealer_id, model_id, name, variant_code, engine_cc)
  values (v_dealer, v_model, 'Disc', 'RAIDER125-DISC', 124.8) returning id into v_variant;

  insert into public.vehicle_price_versions
    (dealer_id, model_id, variant_id, version_number, ex_showroom, insurance, registration,
     forwarding_charge, purchase_cost, effective_from, status, approved_at)
  values (v_dealer, v_model, v_variant, 1, 95000, 7000, 9000, 1500, 79000,
          date '2026-04-01', 'ACTIVE', now());

  insert into public.vehicles
    (dealer_id, branch_id, model_id, variant_id, chassis_no, engine_no, purchase_cost, purchase_invoice)
  values (v_dealer, v_branch, v_model, v_variant, 'MD634KE12P1B00001', 'KE1BP1000001', 79000, 'PINV-9001')
  returning id into v_vehicle;

  -- ── Booking (spec §18) ────────────────────────────────────────────────────
  select * into v_booking
    from public.create_booking_with_advance(
      v_customer, v_model, v_branch, 112500, 10000, 'CASH', v_variant, v_vehicle,
      current_date + 7, null, 'UPI-REF-001', 'Test booking');

  perform app_test.assert_equals(
    v_booking.booking_number ~ '^BK-[0-9]{4}-[0-9]{6}$', true,
    'the booking number follows the BK-YYYY-NNNNNN format'
  );
  perform app_test.assert_equals(
    (select received_amount from public.bookings where id = v_booking.booking_id), 10000.0000::numeric(18,4),
    'the receipt updates the booking''s received total'
  );
  perform app_test.assert_equals(
    (select status from public.vehicles where id = v_vehicle), 'BOOKED',
    'reserving a chassis takes it out of available stock'
  );

  -- The advance is a liability, not revenue (spec §18).
  select coalesce(sum(l.credit), 0) into v_advance
    from public.journal_entry_lines l
    join public.chart_of_accounts c on c.id = l.account_id
   where l.journal_entry_id = v_booking.journal_entry_id and c.code = '2100';

  perform app_test.assert_equals(v_advance, 10000.0000::numeric,
    'the advance credits Customer Advances, not a revenue account');

  perform app_test.assert_equals(
    (select coalesce(sum(l.credit), 0) from public.journal_entry_lines l
      join public.chart_of_accounts c on c.id = l.account_id
     where l.journal_entry_id = v_booking.journal_entry_id and c.account_type = 'INCOME'), 0::numeric,
    'no revenue is recognised at booking (spec §18)'
  );

  -- ── The sale (spec §19) ───────────────────────────────────────────────────
  v_invoice := public.next_document_number(v_dealer, v_branch, 'VEHICLE_INVOICE',
                                           app.financial_year_token(v_dealer, current_date));

  insert into public.sales
    (dealer_id, branch_id, invoice_number, customer_id, vehicle_id, booking_id, price_version_id)
  select v_dealer, v_branch, v_invoice, v_customer, v_vehicle, v_booking.booking_id,
         (select price_version_id from public.resolve_vehicle_price(v_dealer, v_model, v_variant, v_branch, current_date))
  returning id into v_sale;

  insert into public.sale_lines
    (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
     taxable_value, cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount, unit_cost, cost_amount)
  values
    (v_sale, v_dealer, 1, 'VEHICLE', 'TVS Raider 125 Disc', 1, 95000, 95000, 14, 14, 13300, 13300, 121600, 79000, 79000),
    (v_sale, v_dealer, 2, 'INSURANCE', 'Insurance', 1, 7000, 7000, 0, 0, 0, 0, 7000, 0, 0),
    (v_sale, v_dealer, 3, 'REGISTRATION', 'LTRT', 1, 9000, 9000, 0, 0, 0, 0, 9000, 0, 0),
    (v_sale, v_dealer, 4, 'FORWARDING', 'Forwarding', 1, 1500, 1500, 0, 0, 0, 0, 1500, 0, 0);

  -- Each workflow step must be taken in order (spec §19).
  perform app_test.assert_raises(
    format('update public.sales set status = ''APPROVED'' where id = %L', v_sale),
    'a DRAFT sale cannot jump straight to APPROVED'
  );

  update public.sales set status = 'SUBMITTED' where id = v_sale;
  update public.sales set status = 'ACCOUNTS_VERIFICATION' where id = v_sale;
  update public.sales set status = 'APPROVED', approved_at = now() where id = v_sale;

  v_entry := public.post_vehicle_sale(v_sale);

  perform app_test.assert_equals(
    (select status from public.sales where id = v_sale), 'POSTED', 'the sale posts');
  perform app_test.assert_equals(
    (select status from public.vehicles where id = v_vehicle), 'SOLD_PENDING_DELIVERY',
    'a booked vehicle moves to SOLD_PENDING_DELIVERY on posting');

  perform app_test.assert_equals(
    (select sum(debit) = sum(credit) from public.journal_entry_lines where journal_entry_id = v_entry),
    true, 'the sale journal balances'
  );

  -- ── Payment (spec §19) ────────────────────────────────────────────────────
  perform app_test.assert_raises(
    format('select public.record_sale_payment(%L, -100, ''CASH'')', v_sale),
    'a negative payment is refused'
  );

  select * into v_receipt from public.record_sale_payment(v_sale, 20000, 'CASH', 'Counter cash');

  perform app_test.assert_equals(
    (select paid_amount from public.sales where id = v_sale), 20000.0000::numeric(18,4),
    'the receipt updates the invoice''s paid total'
  );

  -- A finance payment names the company carrying the debt, so account 1400 has
  -- subsidiary detail behind it rather than one undifferentiated total (spec §25).
  insert into public.finance_companies (dealer_id, code, name)
  values (v_dealer, 'TVSCR-WF', 'TVS Credit (workflow test)')
  returning id into v_finance_co;

  select * into v_receipt
    from public.record_sale_payment(v_sale, 100000, 'FINANCE', 'TVS Credit DD', v_finance_co);

  perform app_test.assert_equals(
    (select count(*)::int from public.journal_entry_lines
      where journal_entry_id = v_receipt.journal_entry_id
        and party_type = 'FINANCE_COMPANY' and party_id = v_finance_co), 1,
    'the finance receivable names the company that owes it'
  );

  perform app_test.assert_equals(
    (select finance_amount from public.sales where id = v_sale), 100000.0000::numeric(18,4),
    'a finance payment is tracked separately from cash'
  );

  perform app_test.assert_equals(
    (select sum(debit) = sum(credit) from public.journal_entry_lines
      where journal_entry_id = v_receipt.journal_entry_id),
    true, 'the receipt journal balances'
  );

  -- ── Delivery (spec §19) ───────────────────────────────────────────────────
  v_delivery := public.deliver_vehicle(v_sale, 'Workflow Test Customer', 12.5, 'Handed over');

  -- A delivery note is its own document series, not a borrowed transfer number
  -- (spec §45). Sharing the STOCK_TRANSFER counter left both series with gaps.
  perform app_test.assert_equals(
    v_delivery ~ '^DN-[0-9]{4}-[0-9]{6}$', true,
    'the delivery note follows the DN-YYYY-NNNNNN format');

  perform app_test.assert_equals(
    (select status from public.sales where id = v_sale), 'DELIVERED', 'the sale is delivered');
  perform app_test.assert_equals(
    (select status from public.vehicles where id = v_vehicle), 'DELIVERED',
    'the vehicle is delivered');
  perform app_test.assert_equals(
    (select count(*)::int from public.deliveries where sale_id = v_sale), 1,
    'a delivery note is recorded');

  -- A delivered vehicle is the customer's: it cannot go back into stock.
  perform app_test.assert_raises(
    format('update public.vehicles set status = ''IN_STOCK'' where id = %L', v_vehicle),
    'a DELIVERED vehicle cannot return to stock'
  );

  perform app_test.assert_raises(
    format('select public.deliver_vehicle(%L)', v_sale),
    'a sale cannot be delivered twice'
  );

  -- A posted invoice's figures are fixed (spec §23).
  perform app_test.assert_raises(
    format('update public.sales set total_amount = 1 where id = %L', v_sale),
    'a delivered invoice''s values are immutable'
  );
end;
$$;

-- The books still balance after a full booking-to-delivery cycle.
do $$
declare v_debit numeric; v_credit numeric;
begin
  select coalesce(sum(l.debit), 0), coalesce(sum(l.credit), 0) into v_debit, v_credit
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where je.status in ('POSTED', 'REVERSED');

  perform app_test.assert_equals(v_debit, v_credit,
    'the ledger balances after booking, sale, payments and delivery');
end;
$$;

\echo '--- sales workflow passed ---'
