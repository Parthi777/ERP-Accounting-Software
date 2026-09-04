-- =============================================================================
-- TEST — a sales return that gives the money back
-- =============================================================================
-- Spec §21, §23, §28, §31, §34, §36, §37, §48.
--
-- The guarantees asserted here:
--   * a paid invoice can be returned at all — before 0051 it could not, because
--     the refund it demanded had nowhere to be recorded;
--   * the customer's ledger closes to nil: reversal leaves them in credit and
--     the refund clears it;
--   * the money leaves the cash book, not merely the general ledger;
--   * the receipts are marked reversed, never deleted, and paid_amount follows;
--   * the vehicle and its fitted accessories go back into stock, each accessory
--     to the lot it came out of;
--   * a partial refund leaves the balance as a customer credit rather than
--     silently becoming income;
--   * pressing the button twice does not pay twice;
--   * a refund larger than what was received is refused.
-- =============================================================================

\echo '--- sales return with refund ---'

do $$
declare
  v_dealer   uuid;
  v_main     uuid;
  v_model    uuid;
  v_variant  uuid;
  v_vehicle  uuid;
  v_item     uuid;
  v_customer uuid;
  v_sale     uuid;
  v_invoice  text;
  v_entry    uuid;
  v_result   record;
  v_second   record;
  v_local    numeric;
  v_cash_before numeric;
  v_cash_after  numeric;
  v_balance  numeric;
  v_count    int;
  v_debit    numeric;
  v_credit   numeric;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_main   from public.branches where dealer_id = v_dealer and code = 'MAIN';

  select id into v_model   from public.vehicle_models   where dealer_id = v_dealer limit 1;
  select id into v_variant from public.vehicle_variants where model_id = v_model limit 1;

  insert into public.vehicles
    (dealer_id, branch_id, model_id, variant_id, chassis_no, engine_no,
     purchase_invoice, purchase_date, purchase_cost)
  values
    (v_dealer, v_main, v_model, v_variant, 'REFUNDCHASSIS0001', 'REFUNDENGINE0001',
     'PINV-REFUND-1', current_date, 66000)
  returning id into v_vehicle;

  -- An accessory to fit, so the return has stock to put back.
  insert into public.inventory_items
    (dealer_id, item_code, name, item_type, standard_cost, selling_price)
  values (v_dealer, 'REFUND-MAT-01', 'Refund Test Floor Mat', 'ACCESSORY', 500, 650)
  returning id into v_item;

  -- Stock arrives through a movement, never by writing the quantity (spec §34).
  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
     reference_type, narration)
  values (v_dealer, v_main, v_item, 'LOCAL', 'OPENING', 6, 500, 'OPENING', 'Local purchase');

  insert into public.customers (dealer_id, name, mobile, city, state, state_code)
  values (v_dealer, 'Refund Test Customer', '9840099311', 'Chennai', 'Tamil Nadu', '33')
  returning id into v_customer;

  v_invoice := public.next_document_number(v_dealer, v_main, 'VEHICLE_INVOICE',
                                           app.financial_year_token(v_dealer, current_date));

  insert into public.sales
    (dealer_id, branch_id, invoice_number, customer_id, vehicle_id, price_version_id)
  select v_dealer, v_main, v_invoice, v_customer, v_vehicle,
         (select price_version_id
            from public.resolve_vehicle_price(v_dealer, v_model, v_variant, v_main, current_date))
  returning id into v_sale;

  insert into public.sale_lines
    (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
     taxable_value, cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount,
     unit_cost, cost_amount)
  values
    (v_sale, v_dealer, 1, 'VEHICLE', 'Refund test vehicle', 1, 80000, 80000,
     14, 14, 11200, 11200, 102400, 66000, 66000);

  perform public.consume_fitting_stock(v_sale, v_item, 2, 650);

  update public.sales set status = 'SUBMITTED'             where id = v_sale;
  update public.sales set status = 'ACCOUNTS_VERIFICATION' where id = v_sale;
  update public.sales set status = 'APPROVED', approved_at = now() where id = v_sale;

  v_entry := public.post_vehicle_sale(v_sale);

  -- ═══ The customer pays ═══════════════════════════════════════════════════
  perform public.record_sale_payment(v_sale, 50000, 'CASH', 'Counter receipt');

  perform app_test.assert_equals(
    (select paid_amount from public.sales where id = v_sale), 50000.0000::numeric,
    'the receipt is recorded against the invoice');

  select coalesce(sum(case when direction = 'RECEIPT' then amount else -amount end), 0)
    into v_cash_before
    from public.cash_transactions where branch_id = v_main;

  -- ═══ What is still refused ═══════════════════════════════════════════════
  perform app_test.assert_raises(
    format('select public.return_vehicle_sale(%L, ''No reason given'', ''CASH'', 90000)', v_sale),
    'a refund larger than what was received is refused');

  perform app_test.assert_raises(
    format('select public.return_vehicle_sale(%L, ''Customer changed mind'')', v_sale),
    'a paid invoice cannot be returned without saying how the money goes back');

  perform app_test.assert_raises(
    format('select public.return_vehicle_sale(%L, ''Customer changed mind'', ''CHEQUE'', 50000)', v_sale),
    'a refund mode other than cash or bank is refused');

  -- ═══ The return, refunded in cash ════════════════════════════════════════
  select * into v_result from public.return_vehicle_sale(
    v_sale, 'Customer rejected the vehicle at delivery', 'CASH', 50000, null, 'VCH-9001');

  perform app_test.assert_equals(v_result.refunded, 50000.0000::numeric,
    'the whole receipt is refunded');
  perform app_test.assert_equals(v_result.credit_left, 0.0000::numeric,
    'and nothing is left owing to the customer');
  perform app_test.assert_equals(v_result.refund_entry_id is not null, true,
    'the refund posts a journal of its own, separate from the reversal');

  perform app_test.assert_equals(
    (select status from public.journal_entries where id = v_entry), 'REVERSED',
    'the original invoice journal is reversed, not edited (spec §23)');

  -- ═══ The customer ends up square ═════════════════════════════════════════
  -- Reversal alone would leave them 50,000 in credit; the refund clears it.
  v_balance := public.party_ledger_opening('CUSTOMER', v_customer, 'infinity'::date);
  perform app_test.assert_equals(v_balance, 0.0000::numeric,
    'the customer ledger closes to nil: invoice reversed, money returned');

  -- ═══ The money actually left the drawer ══════════════════════════════════
  select coalesce(sum(case when direction = 'RECEIPT' then amount else -amount end), 0)
    into v_cash_after
    from public.cash_transactions where branch_id = v_main;

  perform app_test.assert_equals(v_cash_before - v_cash_after, 50000.0000::numeric,
    'the refund leaves the cash book, not only the general ledger (spec §37)');

  select count(*)::int into v_count
    from public.cash_transactions
   where branch_id = v_main and direction = 'PAYMENT' and reference_number = 'VCH-9001';
  perform app_test.assert_equals(v_count, 1,
    'the voucher number the cashier was given is on the cash book row');

  -- ═══ The receipts, and the figure derived from them ══════════════════════
  perform app_test.assert_equals(
    (select status from public.sale_payments where sale_id = v_sale), 'REVERSED',
    'the receipt is marked reversed, not deleted');
  perform app_test.assert_equals(
    (select paid_amount from public.sales where id = v_sale), 0.0000::numeric,
    'and paid_amount falls out of the trigger rather than being written by hand');

  -- ═══ The stock comes back ════════════════════════════════════════════════
  perform app_test.assert_equals(
    (select status from public.vehicles where id = v_vehicle), 'IN_STOCK',
    'the vehicle is back in stock and can be sold again');

  select quantity into v_local from public.inventory_stock
   where item_id = v_item and branch_id = v_main and source = 'LOCAL';
  perform app_test.assert_equals(v_local, 6::numeric,
    'the fitted accessories return to the lot they were drawn from (spec §31)');

  select count(*)::int into v_count from public.vehicle_stock_transactions
   where vehicle_id = v_vehicle and transaction_type = 'RETURN';
  perform app_test.assert_equals(v_count, 1,
    'the return is written to the vehicle stock ledger once');

  -- ═══ And the books balance ═══════════════════════════════════════════════
  select sum(l.debit), sum(l.credit) into v_debit, v_credit
    from public.journal_entry_lines l
    join public.journal_entries e on e.id = l.journal_entry_id
   where e.dealer_id = v_dealer and e.status in ('POSTED', 'REVERSED');
  perform app_test.assert_equals(v_debit, v_credit,
    'the dealer''s ledger still balances after a refunded return (spec §22)');
end;
$$;

-- -----------------------------------------------------------------------------
-- A partial refund, and pressing the button twice
-- -----------------------------------------------------------------------------
do $$
declare
  v_dealer   uuid;
  v_main     uuid;
  v_model    uuid;
  v_variant  uuid;
  v_vehicle  uuid;
  v_customer uuid;
  v_sale     uuid;
  v_invoice  text;
  v_result   record;
  v_balance  numeric;
  v_open     numeric;
  v_count    int;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_main   from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_model   from public.vehicle_models   where dealer_id = v_dealer limit 1;
  select id into v_variant from public.vehicle_variants where model_id = v_model limit 1;

  insert into public.vehicles
    (dealer_id, branch_id, model_id, variant_id, chassis_no, engine_no,
     purchase_invoice, purchase_date, purchase_cost)
  values
    (v_dealer, v_main, v_model, v_variant, 'REFUNDCHASSIS0002', 'REFUNDENGINE0002',
     'PINV-REFUND-2', current_date, 66000)
  returning id into v_vehicle;

  insert into public.customers (dealer_id, name, mobile, city, state, state_code)
  values (v_dealer, 'Partial Refund Customer', '9840099312', 'Chennai', 'Tamil Nadu', '33')
  returning id into v_customer;

  v_invoice := public.next_document_number(v_dealer, v_main, 'VEHICLE_INVOICE',
                                           app.financial_year_token(v_dealer, current_date));

  insert into public.sales
    (dealer_id, branch_id, invoice_number, customer_id, vehicle_id, price_version_id)
  select v_dealer, v_main, v_invoice, v_customer, v_vehicle,
         (select price_version_id
            from public.resolve_vehicle_price(v_dealer, v_model, v_variant, v_main, current_date))
  returning id into v_sale;

  insert into public.sale_lines
    (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
     taxable_value, cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount,
     unit_cost, cost_amount)
  values
    (v_sale, v_dealer, 1, 'VEHICLE', 'Partial refund test vehicle', 1, 80000, 80000,
     14, 14, 11200, 11200, 102400, 66000, 66000);

  update public.sales set status = 'SUBMITTED'             where id = v_sale;
  update public.sales set status = 'ACCOUNTS_VERIFICATION' where id = v_sale;
  update public.sales set status = 'APPROVED', approved_at = now() where id = v_sale;
  perform public.post_vehicle_sale(v_sale);

  perform public.record_sale_payment(v_sale, 50000, 'CASH', 'Counter receipt');

  -- The dealer keeps ₹5,000 against the cancellation.
  select * into v_result from public.return_vehicle_sale(
    v_sale, 'Cancelled after booking; retention agreed', 'CASH', 45000);

  perform app_test.assert_equals(v_result.refunded, 45000.0000::numeric,
    'a partial refund pays back what was agreed');
  perform app_test.assert_equals(v_result.credit_left, 5000.0000::numeric,
    'and reports what the dealer is still holding');

  -- The retained amount stays a liability to the customer until someone decides
  -- to recognise it. It is visible, not absorbed.
  v_balance := public.party_ledger_opening('CUSTOMER', v_customer, 'infinity'::date);
  perform app_test.assert_equals(v_balance, -5000.0000::numeric,
    'the retention remains a credit on the customer ledger, not silent income');

  -- Four party lines are left open — invoice, receipt, reversal, refund — and
  -- none of them is allocated against another yet. What matters is that they net
  -- to what the dealer is holding, so the bill-wise view (0050) agrees with the
  -- ledger rather than telling a second story about the same money.
  select coalesce(sum(outstanding) filter (where side = 'DEBIT'), 0)
       - coalesce(sum(outstanding) filter (where side = 'CREDIT'), 0)
    into v_open
    from public.party_open_items('CUSTOMER', v_customer);
  perform app_test.assert_equals(v_open, -5000.0000::numeric,
    'and the open items net to the retention, so settlement and ledger agree');

  -- Returning again is refused outright, which is also what stops a second
  -- refund: the sale is no longer POSTED.
  perform app_test.assert_raises(
    format('select public.return_vehicle_sale(%L, ''Again'', ''CASH'', 5000)', v_sale),
    'a returned sale cannot be returned — or refunded — a second time');

  select count(*)::int into v_count
    from public.cash_transactions
   where journal_entry_id in (
     select id from public.journal_entries
      where source_document_type = 'SALE_RETURN' and source_document_id = v_sale
   );
  perform app_test.assert_equals(v_count, 1, 'exactly one refund left the cash book');
end;
$$;
