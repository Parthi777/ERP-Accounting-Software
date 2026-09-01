-- =============================================================================
-- TEST — booking advances, applied and refunded
-- =============================================================================
-- Spec §18, §23.
--
-- The guarantees asserted here:
--   * an advance is a liability when taken, and stops being one when the sale it
--     was taken for is invoiced — the defect this closes is that it never did;
--   * applying is idempotent, so posting twice does not release it twice;
--   * a refund needs a cancelled booking and a reason, writes the money out
--     through cash or bank, and reverses the receipts so the booking's received
--     total follows;
--   * a refund cannot exceed what was received.
-- =============================================================================

\echo '--- booking advances ---'

do $$
declare
  v_dealer   uuid;
  v_branch   uuid;
  v_customer uuid;
  v_hsn      uuid;
  v_model    uuid;
  v_variant  uuid;
  v_vehicle  uuid;
  v_booking  record;
  v_sale     uuid;
  v_invoice  text;
  v_advance  uuid;
  v_bank     uuid;
  v_count    int;
  v_balance  numeric;
  v_received numeric;
  v_entry    uuid;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_bank   from public.bank_accounts where dealer_id = v_dealer limit 1;
  select id into v_hsn    from public.hsn_codes where dealer_id = v_dealer limit 1;
  select id into v_advance from public.chart_of_accounts where dealer_id = v_dealer and code = '2100';

  insert into public.customers (dealer_id, name, mobile, city, state, state_code)
  values (v_dealer, 'Advance Test Customer', '9840094001', 'Chennai', 'Tamil Nadu', '33')
  returning id into v_customer;

  insert into public.vehicle_models (dealer_id, brand, name, model_code, category, hsn_code_id)
  values (v_dealer, 'TVS', 'Radeon', 'RADEON110', 'MOTORCYCLE', v_hsn) returning id into v_model;

  insert into public.vehicle_variants (dealer_id, model_id, name, variant_code, engine_cc)
  values (v_dealer, v_model, 'Drum', 'RADEON110-DRM', 109.7) returning id into v_variant;

  insert into public.vehicle_price_versions
    (dealer_id, model_id, variant_id, version_number, ex_showroom, insurance, registration,
     forwarding_charge, purchase_cost, effective_from, status, approved_at)
  values (v_dealer, v_model, v_variant, 1, 65000, 5000, 6000, 1000, 54000,
          date '2026-04-01', 'ACTIVE', now());

  insert into public.vehicles
    (dealer_id, branch_id, model_id, variant_id, chassis_no, engine_no, purchase_cost, purchase_invoice)
  values (v_dealer, v_branch, v_model, v_variant, 'MD690RD11N4E00001', 'RD1EN4000001', 54000, 'PINV-6601')
  returning id into v_vehicle;

  -- ═══ The advance is a liability when taken ═══════════════════════════════
  select * into v_booking
    from public.create_booking_with_advance(
      v_customer, v_model, v_branch, 80000, 10000, 'CASH', v_variant, v_vehicle,
      current_date + 7, null, 'REF-ADV-1', 'Advance test booking');

  select coalesce(sum(l.credit - l.debit), 0) into v_balance
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.account_id = v_advance and l.party_id = v_customer
     and je.status in ('POSTED', 'REVERSED');

  perform app_test.assert_equals(v_balance, 10000::numeric,
    'the advance sits in Customer Advances as a liability');

  -- ═══ …and stops being one when the sale is invoiced ══════════════════════
  v_invoice := public.next_document_number(v_dealer, v_branch, 'VEHICLE_INVOICE',
                                           app.financial_year_token(v_dealer, current_date));

  insert into public.sales
    (dealer_id, branch_id, invoice_number, customer_id, vehicle_id, booking_id, price_version_id)
  select v_dealer, v_branch, v_invoice, v_customer, v_vehicle, v_booking.booking_id,
         (select price_version_id from public.resolve_vehicle_price(
            v_dealer, v_model, v_variant, v_branch, current_date))
  returning id into v_sale;

  insert into public.sale_lines
    (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
     taxable_value, cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount,
     unit_cost, cost_amount)
  values
    (v_sale, v_dealer, 1, 'VEHICLE', 'TVS Radeon Drum', 1, 65000, 65000,
     14, 14, 9100, 9100, 83200, 54000, 54000);

  update public.sales set status = 'SUBMITTED'             where id = v_sale;
  update public.sales set status = 'ACCOUNTS_VERIFICATION' where id = v_sale;
  update public.sales set status = 'APPROVED', approved_at = now() where id = v_sale;

  perform public.post_vehicle_sale(v_sale);

  select coalesce(sum(l.credit - l.debit), 0) into v_balance
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.account_id = v_advance and l.party_id = v_customer
     and je.status in ('POSTED', 'REVERSED');

  -- Before this migration the advance stayed on 2100 forever. This is the
  -- assertion that would have failed.
  perform app_test.assert_equals(v_balance, 0::numeric,
    'posting the invoice releases the advance from Customer Advances');

  select count(*)::int into v_count
    from public.journal_entries
   where idempotency_key = 'booking-apply:' || v_sale::text;
  perform app_test.assert_equals(v_count, 1, 'the release posted exactly one journal');

  -- Applying again must not release it a second time. Called directly, because
  -- the sale itself refuses to post twice — the idempotency being tested is the
  -- release's own, not the sale's.
  perform app.apply_booking_advance(v_sale);
  select count(*)::int into v_count
    from public.journal_entries
   where idempotency_key = 'booking-apply:' || v_sale::text;
  perform app_test.assert_equals(v_count, 1, 'and applying again does not release it twice');

  select coalesce(sum(l.credit - l.debit), 0) into v_balance
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.account_id = v_advance and l.party_id = v_customer
     and je.status in ('POSTED', 'REVERSED');
  perform app_test.assert_equals(v_balance, 0::numeric,
    'so the liability is not driven negative by a repeat');

  -- ═══ Refund ═════════════════════════════════════════════════════════════
  select * into v_booking
    from public.create_booking_with_advance(
      v_customer, v_model, v_branch, 80000, 15000, 'CASH', v_variant, null,
      current_date + 7, null, 'REF-ADV-2', 'To be cancelled');

  perform app_test.assert_raises(
    format('select public.refund_booking_advance(%L, 5000, ''CASH'', ''Changed mind'')',
           v_booking.booking_id),
    'a live booking cannot be refunded before it is cancelled');

  update public.bookings
     set status = 'CANCELLED', cancelled_reason = 'Customer changed their mind'
   where id = v_booking.booking_id;

  perform app_test.assert_raises(
    format('select public.refund_booking_advance(%L, 5000, ''CASH'', '''')', v_booking.booking_id),
    'a refund must say why');

  perform app_test.assert_raises(
    format('select public.refund_booking_advance(%L, 99000, ''CASH'', ''Too much'')',
           v_booking.booking_id),
    'a refund cannot exceed what was received');

  select journal_entry_id into v_entry
    from public.refund_booking_advance(
      v_booking.booking_id, 15000, 'CASH', 'Booking cancelled at customer request');

  perform app_test.assert_equals(
    (select sum(debit) = sum(credit) from public.journal_entry_lines where journal_entry_id = v_entry),
    true, 'the refund journal balances');

  select count(*)::int into v_count
    from public.cash_transactions where journal_entry_id = v_entry and direction = 'PAYMENT';
  perform app_test.assert_equals(v_count, 1, 'the money leaves through the cash book');

  select count(*)::int into v_count
    from public.booking_payments where booking_id = v_booking.booking_id and status = 'REVERSED';
  perform app_test.assert_equals(v_count, 1, 'the receipt is marked reversed');

  select received_amount into v_received from public.bookings where id = v_booking.booking_id;
  perform app_test.assert_equals(v_received, 0::numeric,
    'so the booking''s received total falls to nil by trigger');

  -- The liability the refund cleared is gone from the customer's account.
  select coalesce(sum(l.credit - l.debit), 0) into v_balance
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.account_id = v_advance and l.party_id = v_customer
     and je.status in ('POSTED', 'REVERSED');
  perform app_test.assert_equals(v_balance, 0::numeric,
    'and nothing is left held against the customer');

  -- ═══ And the books still balance ═════════════════════════════════════════
  select sum(l.debit), sum(l.credit) into v_balance, v_received
    from public.journal_entry_lines l
    join public.journal_entries e on e.id = l.journal_entry_id
   where e.dealer_id = v_dealer and e.status in ('POSTED', 'REVERSED');

  perform app_test.assert_equals(v_balance, v_received,
    'the ledger balances after advances are applied and refunded');
end;
$$;
