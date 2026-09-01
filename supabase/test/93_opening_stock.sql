-- =============================================================================
-- TEST — opening stock
-- =============================================================================
-- Spec §14, §28, §34, §60.16.
--
-- The guarantees asserted here:
--   * an OPENING movement creates the lot and its quantity follows from the
--     ledger, never from a direct write;
--   * LOCAL and COMPANY arrive as separate lots carrying their own cost;
--   * the balance recorded on the movement is the one the trigger computed, not
--     one the caller supplied;
--   * a movement of nothing is refused.
-- =============================================================================

\echo '--- opening stock ---'

do $$
declare
  v_dealer  uuid;
  v_main    uuid;
  v_north   uuid;
  v_hsn     uuid;
  v_item    uuid;
  v_qty     numeric;
  v_cost    numeric;
  v_value   numeric;
  v_balance numeric;
  v_count   int;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_main  from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_north from public.branches where dealer_id = v_dealer and code = 'NORTH';

  select id into v_hsn from public.hsn_codes where dealer_id = v_dealer limit 1;

  insert into public.inventory_items
    (dealer_id, item_code, name, item_type, hsn_code_id, standard_cost, selling_price)
  values (v_dealer, 'AC-UPL-01', 'Uploaded floor mat', 'ACCESSORY', v_hsn, 400, 650)
  returning id into v_item;

  -- ═══ The upload writes movements, not quantities ═════════════════════════
  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
     reference_type, narration)
  values
    (v_dealer, v_main,  v_item, 'LOCAL',   'OPENING', 12, 380, 'OPENING', 'Opening stock import'),
    (v_dealer, v_main,  v_item, 'COMPANY', 'OPENING', 25, 410, 'OPENING', 'Opening stock import'),
    (v_dealer, v_north, v_item, 'COMPANY', 'OPENING', 40, 295, 'OPENING', 'Opening stock import');

  -- ═══ The lots ════════════════════════════════════════════════════════════
  select count(*)::int into v_count
    from public.inventory_stock where item_id = v_item;
  perform app_test.assert_equals(v_count, 3,
    'three lots exist: one per branch and source');

  select quantity, average_cost, stock_value into v_qty, v_cost, v_value
    from public.inventory_stock
   where item_id = v_item and branch_id = v_main and source = 'LOCAL';

  perform app_test.assert_equals(v_qty, 12::numeric, 'the local lot carries its own quantity');
  perform app_test.assert_equals(v_cost, 380::numeric, 'and its own cost, not the item''s standard cost');
  perform app_test.assert_equals(v_value, 4560::numeric, 'stock value is quantity times cost');

  select average_cost into v_cost
    from public.inventory_stock
   where item_id = v_item and branch_id = v_main and source = 'COMPANY';
  perform app_test.assert_equals(v_cost, 410::numeric,
    'company stock is valued separately from local, never averaged together');

  -- ═══ balance_after belongs to the trigger ════════════════════════════════
  select balance_after into v_balance
    from public.inventory_transactions
   where item_id = v_item and branch_id = v_main and source = 'LOCAL'
     and transaction_type = 'OPENING';
  perform app_test.assert_equals(v_balance, 12::numeric,
    'the movement records the balance it produced');

  -- A second receipt re-averages the cost; opening stock is not a special case
  -- once it is in the ledger.
  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
     reference_type, narration)
  values
    (v_dealer, v_main, v_item, 'LOCAL', 'PURCHASE', 8, 440, 'PURCHASE', 'Top-up');

  select quantity, average_cost into v_qty, v_cost
    from public.inventory_stock
   where item_id = v_item and branch_id = v_main and source = 'LOCAL';
  perform app_test.assert_equals(v_qty, 20::numeric, 'the lot accumulates');
  -- (12 × 380 + 8 × 440) / 20 = 404
  perform app_test.assert_equals(v_cost, 404::numeric,
    'and its cost is the weighted average of what was paid');

  -- ═══ Refusals ════════════════════════════════════════════════════════════
  perform app_test.assert_raises(
    format($f$insert into public.inventory_transactions
             (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost)
             values (%L, %L, %L, 'LOCAL', 'OPENING', 0, 100)$f$, v_dealer, v_main, v_item),
    'an opening movement of nothing is refused');

  perform app_test.assert_raises(
    format($f$insert into public.inventory_transactions
             (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost)
             values (%L, %L, %L, 'BOTH', 'OPENING', 5, 100)$f$, v_dealer, v_main, v_item),
    'a source other than LOCAL or COMPANY is refused');

  -- The ledger is append-only, so a wrong opening is corrected by an adjustment
  -- with a reason, never by editing the row.
  perform app_test.assert_raises(
    format($f$update public.inventory_transactions set quantity = 99
              where item_id = %L and transaction_type = 'OPENING'$f$, v_item),
    'an opening movement cannot be edited after the fact');
end;
$$;
