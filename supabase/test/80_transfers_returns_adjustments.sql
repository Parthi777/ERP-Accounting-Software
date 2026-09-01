-- =============================================================================
-- TEST — branch transfers, stock adjustments, and sales returns
-- =============================================================================
-- Spec §21, §34, §35, §60.22.
--
-- The guarantees asserted here:
--   * a vehicle in transit belongs to neither branch, so it cannot be sold
--     twice, and it cannot be dispatched or received twice;
--   * a transferred accessory lot keeps its LOCAL/COMPANY identity across the
--     move (spec §60.16) — the distinction survives the journey;
--   * stock never goes negative and an adjustment without a reason is refused;
--   * a return reverses the journal rather than editing the invoice, restores
--     the vehicle and the fitted accessories, and leaves the ledger balanced.
-- =============================================================================

\echo '--- transfers, returns and adjustments ---'

do $$
declare
  v_dealer    uuid;
  v_main      uuid;
  v_north     uuid;
  v_customer  uuid;
  v_hsn       uuid;
  v_model     uuid;
  v_variant   uuid;
  v_vehicle   uuid;
  v_item      uuid;
  v_sale      uuid;
  v_invoice   text;
  v_entry     uuid;
  v_reversal  uuid;
  v_transfer  uuid;
  v_trf_no    text;
  v_status    text;
  v_branch    uuid;
  v_qty       numeric;
  v_local     numeric;
  v_company   numeric;
  v_count     int;
  v_debit     numeric;
  v_credit    numeric;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_main  from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_north from public.branches where dealer_id = v_dealer and code = 'NORTH';

  -- The seed may already carry this HSN; reuse it rather than collide with it.
  select id into v_hsn from public.hsn_codes where dealer_id = v_dealer and code = '87112019';
  if v_hsn is null then
    insert into public.hsn_codes (dealer_id, code, description)
    values (v_dealer, '87112019', 'Scooters 110cc') returning id into v_hsn;
  end if;

  insert into public.vehicle_models (dealer_id, brand, name, model_code, category, hsn_code_id)
  values (v_dealer, 'TVS', 'Jupiter 110', 'JUPITER110X', 'SCOOTER', v_hsn) returning id into v_model;

  insert into public.vehicle_variants (dealer_id, model_id, name, variant_code, engine_cc)
  values (v_dealer, v_model, 'Sheet Metal', 'JUPITER110X-SM', 109.7) returning id into v_variant;

  insert into public.vehicle_price_versions
    (dealer_id, model_id, variant_id, version_number, ex_showroom, insurance, registration,
     forwarding_charge, purchase_cost, effective_from, status, approved_at)
  values (v_dealer, v_model, v_variant, 1, 80000, 6000, 7000, 1200, 66000,
          date '2026-04-01', 'ACTIVE', now());

  insert into public.vehicles
    (dealer_id, branch_id, model_id, variant_id, chassis_no, engine_no, purchase_cost, purchase_invoice)
  values (v_dealer, v_main, v_model, v_variant, 'MD625TF80P2C00001', 'TF8CP2000001', 66000, 'PINV-8001')
  returning id into v_vehicle;

  -- ═══ Vehicle transfer, MAIN → NORTH (spec §35) ═══════════════════════════
  select transfer_id, transfer_number into v_transfer, v_trf_no
    from public.dispatch_vehicle_transfer(v_vehicle, v_north, 'Stock rebalancing');

  perform app_test.assert_equals(v_trf_no ~ '^TRF-[0-9]{4}-[0-9]{6}$', true,
    'the transfer number follows the TRF-YYYY-NNNNNN format');

  select status into v_status from public.vehicle_transfers where id = v_transfer;
  perform app_test.assert_equals(v_status, 'IN_TRANSIT', 'the transfer document opens IN_TRANSIT');

  -- The vehicle carries TRANSFERRED while the document carries IN_TRANSIT.
  -- TRANSFERRED is the status spec §13 defines and the only one the status
  -- guard will accept out of IN_STOCK.
  select status, branch_id into v_status, v_branch from public.vehicles where id = v_vehicle;
  perform app_test.assert_equals(v_status, 'TRANSFERRED',
    'a dispatched vehicle leaves stock so it cannot be sold from either branch');
  perform app_test.assert_equals(v_branch, v_main,
    'the vehicle still belongs to the source branch until it is received');

  -- Exactly one row: the trigger is the sole writer, so a function that also
  -- logged by hand would show the movement twice.
  select count(*) into v_count from public.vehicle_stock_transactions
   where vehicle_id = v_vehicle and transaction_type = 'TRANSFER_OUT' and branch_id = v_main;
  perform app_test.assert_equals(v_count, 1, 'the dispatch is written to the source branch stock ledger once');

  perform app_test.assert_equals(
    (select reference_id from public.vehicle_stock_transactions
      where vehicle_id = v_vehicle and transaction_type = 'TRANSFER_OUT'), v_transfer,
    'the ledger row points back at the transfer document that caused it');

  perform app_test.assert_raises(
    format('select public.dispatch_vehicle_transfer(%L, %L)', v_vehicle, v_north),
    'a vehicle already in transit cannot be dispatched again');

  -- ── Receipt at the destination ────────────────────────────────────────────
  perform public.receive_vehicle_transfer(v_transfer, 'Received in good order');

  select status, branch_id into v_status, v_branch from public.vehicles where id = v_vehicle;
  perform app_test.assert_equals(v_status, 'IN_STOCK', 'the received vehicle is back in stock');
  perform app_test.assert_equals(v_branch, v_north, 'and now belongs to the destination branch');

  select status into v_status from public.vehicle_transfers where id = v_transfer;
  perform app_test.assert_equals(v_status, 'RECEIVED', 'the transfer is closed');

  select count(*) into v_count from public.vehicle_stock_transactions
   where vehicle_id = v_vehicle and transaction_type = 'TRANSFER_IN' and branch_id = v_north;
  perform app_test.assert_equals(v_count, 1, 'the receipt is written to the destination stock ledger once');

  perform app_test.assert_equals(
    (select reference_id from public.vehicle_stock_transactions
      where vehicle_id = v_vehicle and transaction_type = 'TRANSFER_IN' and branch_id = v_north),
    v_transfer, 'the receipt row points back at the same transfer document');

  perform app_test.assert_raises(
    format('select public.receive_vehicle_transfer(%L)', v_transfer),
    'a transfer cannot be received twice');

  -- Send it back so the return test below has a vehicle at MAIN to sell.
  -- This second dispatch leaves from NORTH, so it is also the check that two
  -- branches do not both allocate TRF-<year>-000001 and collide on the
  -- dealer-wide unique constraint (spec §45, §60.3).
  select transfer_id, transfer_number into v_transfer, v_trf_no
    from public.dispatch_vehicle_transfer(v_vehicle, v_main, 'Returning to main');

  perform app_test.assert_equals(
    (select count(*)::int from public.vehicle_transfers
      where dealer_id = v_dealer and transfer_number = v_trf_no), 1,
    'a transfer dispatched from a second branch gets its own number, not a repeat');

  perform public.receive_vehicle_transfer(v_transfer);

  perform app_test.assert_raises(
    format('select public.dispatch_vehicle_transfer(%L, %L)', v_vehicle, v_main),
    'a vehicle cannot be transferred to the branch it is already at');

  -- ═══ Accessory transfer — the lot identity survives (spec §60.16) ═════════
  insert into public.inventory_items
    (dealer_id, item_code, name, item_type, hsn_code_id, standard_cost, selling_price)
  values (v_dealer, 'AC-MAT-01', 'Floor mat', 'ACCESSORY', v_hsn, 400, 650)
  returning id into v_item;

  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
     reference_type, narration)
  values
    (v_dealer, v_main, v_item, 'LOCAL',   'OPENING', 10, 380, 'OPENING', 'Local purchase'),
    (v_dealer, v_main, v_item, 'COMPANY', 'OPENING', 20, 400, 'OPENING', 'Company supply');

  perform public.transfer_inventory_stock(v_item, v_main, v_north, 4, 'LOCAL', 'Branch indent');

  select quantity into v_qty from public.inventory_stock
   where item_id = v_item and branch_id = v_main and source = 'LOCAL';
  perform app_test.assert_equals(v_qty, 6::numeric, 'the source branch is relieved of the transferred quantity');

  select quantity into v_qty from public.inventory_stock
   where item_id = v_item and branch_id = v_north and source = 'LOCAL';
  perform app_test.assert_equals(v_qty, 4::numeric,
    'local stock arrives at the destination as local stock, never merged into company');

  select count(*) into v_count from public.inventory_stock
   where item_id = v_item and branch_id = v_north and source = 'COMPANY';
  perform app_test.assert_equals(v_count, 0,
    'transferring a local lot creates no company stock at the destination');

  perform app_test.assert_raises(
    format('select public.transfer_inventory_stock(%L, %L, %L, 999, ''LOCAL'')', v_item, v_main, v_north),
    'a branch cannot transfer out more than it holds');

  perform app_test.assert_raises(
    format('select public.transfer_inventory_stock(%L, %L, %L, 1, ''LOCAL'')', v_item, v_main, v_main),
    'a transfer to the same branch is refused');

  perform app_test.assert_raises(
    format('select public.transfer_inventory_stock(%L, %L, %L, 0, ''LOCAL'')', v_item, v_main, v_north),
    'a transfer of nothing is refused');

  -- ═══ Stock adjustment (spec §34, §60.22) ═════════════════════════════════
  perform public.adjust_inventory_stock(v_item, v_main, 'COMPANY', -3, 'Damaged in storage');

  select quantity into v_qty from public.inventory_stock
   where item_id = v_item and branch_id = v_main and source = 'COMPANY';
  perform app_test.assert_equals(v_qty, 17::numeric, 'a negative adjustment reduces the lot');

  select reason into v_status from public.inventory_transactions
   where item_id = v_item and transaction_type = 'ADJUSTMENT' order by id desc limit 1;
  perform app_test.assert_equals(v_status, 'Damaged in storage',
    'the reason is recorded on the movement, not merely required at the door');

  perform public.adjust_inventory_stock(v_item, v_main, 'COMPANY', 2, 'Recount after audit');
  select quantity into v_qty from public.inventory_stock
   where item_id = v_item and branch_id = v_main and source = 'COMPANY';
  perform app_test.assert_equals(v_qty, 19::numeric, 'a positive adjustment restores the lot');

  perform app_test.assert_raises(
    format('select public.adjust_inventory_stock(%L, %L, ''COMPANY'', -500, ''Shrinkage'')', v_item, v_main),
    'an adjustment cannot drive stock negative');

  perform app_test.assert_raises(
    format('select public.adjust_inventory_stock(%L, %L, ''COMPANY'', -1, '''')', v_item, v_main),
    'an adjustment without a reason is refused (spec §60.22)');

  perform app_test.assert_raises(
    format('select public.adjust_inventory_stock(%L, %L, ''COMPANY'', 0, ''Nothing'')', v_item, v_main),
    'an adjustment of zero is refused');

  -- ═══ Sales return — a reversal, never an edit (spec §21, §23) ════════════
  insert into public.customers (dealer_id, name, mobile, city, state, state_code)
  values (v_dealer, 'Return Test Customer', '9840099211', 'Chennai', 'Tamil Nadu', '33')
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
    (v_sale, v_dealer, 1, 'VEHICLE', 'TVS Jupiter 110 Sheet Metal', 1, 80000, 80000,
     14, 14, 11200, 11200, 102400, 66000, 66000);

  -- Two floor mats fitted, drawn local-first, so the return has a lot to restore.
  perform public.consume_fitting_stock(v_sale, v_item, 2, 650);

  select quantity into v_local from public.inventory_stock
   where item_id = v_item and branch_id = v_main and source = 'LOCAL';
  perform app_test.assert_equals(v_local, 4::numeric, 'fitting the accessory relieves local stock first');

  update public.sales set status = 'SUBMITTED'             where id = v_sale;
  update public.sales set status = 'ACCOUNTS_VERIFICATION' where id = v_sale;
  update public.sales set status = 'APPROVED', approved_at = now() where id = v_sale;

  v_entry := public.post_vehicle_sale(v_sale);
  perform app_test.assert_equals(
    (select status from public.sales where id = v_sale), 'POSTED', 'the sale posts');

  perform app_test.assert_raises(
    format('select public.return_vehicle_sale(%L, '''')', v_sale),
    'a return without a reason is refused (spec §21)');

  v_reversal := public.return_vehicle_sale(v_sale, 'Customer rejected delivery — colour mismatch');

  perform app_test.assert_equals(v_reversal is not null, true, 'the return posts a reversal entry');
  perform app_test.assert_equals(
    (select status from public.journal_entries where id = v_entry), 'REVERSED',
    'the original journal is marked reversed, not edited (spec §23)');

  perform app_test.assert_equals(
    (select sum(debit) = sum(credit) from public.journal_entry_lines where journal_entry_id = v_reversal),
    true, 'the reversal journal balances');

  perform app_test.assert_equals(
    (select status from public.sales where id = v_sale), 'RETURNED', 'the sale is marked returned');
  perform app_test.assert_equals(
    (select status from public.vehicles where id = v_vehicle), 'IN_STOCK',
    'the returned vehicle comes back into stock');

  -- The mats go back into the lot they came out of, not into company stock.
  select quantity into v_local from public.inventory_stock
   where item_id = v_item and branch_id = v_main and source = 'LOCAL';
  perform app_test.assert_equals(v_local, 6::numeric,
    'the fitted accessories return to the lot they were drawn from');

  select count(*) into v_count from public.vehicle_stock_transactions
   where vehicle_id = v_vehicle and transaction_type = 'RETURN';
  perform app_test.assert_equals(v_count, 1, 'the return is written to the vehicle stock ledger once');

  perform app_test.assert_equals(
    (select reference_id from public.vehicle_stock_transactions
      where vehicle_id = v_vehicle and transaction_type = 'RETURN'), v_sale,
    'the return row points back at the invoice it reverses');

  -- The reference is cleared by each caller, so an ordinary status change that
  -- follows one carries no borrowed document reference.
  update public.vehicles set status = 'CANCELLED', updated_by = null where id = v_vehicle;
  perform app_test.assert_equals(
    (select reference_id from public.vehicle_stock_transactions
      where vehicle_id = v_vehicle and transaction_type = 'STATUS_CHANGE'
      order by id desc limit 1), null::uuid,
    'the document reference does not leak onto a later, unrelated movement');

  perform app_test.assert_raises(
    format('select public.return_vehicle_sale(%L, ''Changed my mind again'')', v_sale),
    'a sale that is already returned cannot be returned twice');

  -- ── And the books still balance ───────────────────────────────────────────
  select sum(l.debit), sum(l.credit) into v_debit, v_credit
    from public.journal_entry_lines l
    join public.journal_entries e on e.id = l.journal_entry_id
   where e.dealer_id = v_dealer and e.status in ('POSTED', 'REVERSED');

  perform app_test.assert_equals(v_debit, v_credit,
    'the ledger balances after transfers, adjustments and a return');
end;
$$;
