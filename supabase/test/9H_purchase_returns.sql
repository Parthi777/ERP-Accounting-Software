-- =============================================================================
-- TEST — purchase returns (debit notes)
-- =============================================================================
-- Spec §13, §21, §22, §23, §28, §34, §41, §48, §49, §50.
--
-- The guarantees asserted here:
--   * part of a bill can go back without reversing the rest of it;
--   * the credit is at the price the bill charged, not at today's cost;
--   * input GST goes back with the goods, so ITC is not overclaimed;
--   * counted stock leaves the lot it joined, and a chassis leaves stock as
--     RETURNED rather than as CANCELLED, so the reversal can bring it back;
--   * the debit note lands on the supplier's ledger as an open debit that
--     bill-wise settlement can knock off the bill it came from;
--   * more than arrived can never go back, however many notes are raised;
--   * a repeated submission returns the first note (spec §50);
--   * a posted note is immutable, and reversing it undoes stock and ledger.
-- =============================================================================

\echo '--- purchase returns ---'

do $$
declare
  v_dealer   uuid;
  v_main     uuid;
  v_supplier uuid;
  v_model    uuid;
  v_variant  uuid;
  v_v1       uuid;
  v_v2       uuid;
  v_item     uuid;
  v_spare    uuid;
  v_hsn      uuid;
  v_bill     uuid;
  v_draft    uuid;
  v_bl_v2    uuid;
  v_bl_mat   uuid;
  v_bl_spare uuid;
  v_ret      uuid;
  v_ret2     uuid;
  v_num      text;
  v_entry    uuid;
  v_rev      uuid;
  v_total    numeric;
  v_qty      numeric;
  v_bal      numeric;
  v_debit    numeric;
  v_credit   numeric;
  v_count    int;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_main   from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_model   from public.vehicle_models   where dealer_id = v_dealer limit 1;
  select id into v_variant from public.vehicle_variants where model_id = v_model limit 1;
  select id into v_hsn from public.hsn_codes limit 1;

  insert into public.suppliers (dealer_id, name, supplier_type, mobile, city, state)
  values (v_dealer, 'Return Test Motors', 'OEM', '9840077201', 'Chennai', 'Tamil Nadu')
  returning id into v_supplier;

  insert into public.vehicles
    (dealer_id, branch_id, model_id, variant_id, chassis_no, engine_no, purchase_cost)
  values
    (v_dealer, v_main, v_model, v_variant, 'RETTEST00000001', 'RETENG00000001', 0),
    (v_dealer, v_main, v_model, v_variant, 'RETTEST00000002', 'RETENG00000002', 0);

  select id into v_v1 from public.vehicles where chassis_no = 'RETTEST00000001';
  select id into v_v2 from public.vehicles where chassis_no = 'RETTEST00000002';

  insert into public.inventory_items
    (dealer_id, item_code, name, item_type, hsn_code_id, standard_cost, selling_price)
  values (v_dealer, 'RT-MAT-01', 'Return Test Mat', 'ACCESSORY', v_hsn, 400, 650)
  returning id into v_item;

  insert into public.inventory_items
    (dealer_id, item_code, name, item_type, hsn_code_id, standard_cost, selling_price)
  values (v_dealer, 'RT-SHOE-01', 'Return Test Brake Shoe', 'SPARE', v_hsn, 200, 320)
  returning id into v_spare;

  -- ═══ A consignment: two chassis, ten mats, twenty shoes ══════════════════
  insert into public.purchase_bills
    (dealer_id, branch_id, supplier_id, supplier_bill_number, bill_date)
  values (v_dealer, v_main, v_supplier, 'TVS/2026/9901', current_date)
  returning id into v_bill;

  insert into public.purchase_bill_lines
    (purchase_bill_id, dealer_id, line_number, line_type, vehicle_id, description,
     quantity, unit_rate, taxable_value, cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount)
  values
    (v_bill, v_dealer, 1, 'VEHICLE', v_v1, 'Jupiter 110 — RETTEST00000001',
     1, 60000, 60000, 14, 14, 8400, 8400, 76800),
    (v_bill, v_dealer, 2, 'VEHICLE', v_v2, 'Jupiter 110 — RETTEST00000002',
     1, 60000, 60000, 14, 14, 8400, 8400, 76800);

  insert into public.purchase_bill_lines
    (purchase_bill_id, dealer_id, line_number, line_type, item_id, source, description,
     quantity, unit_rate, taxable_value, cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount)
  values
    (v_bill, v_dealer, 3, 'ACCESSORY', v_item, 'LOCAL', 'Return Test Mat',
     10, 400, 4000, 9, 9, 360, 360, 4720),
    (v_bill, v_dealer, 4, 'SPARE', v_spare, 'COMPANY', 'Return Test Brake Shoe',
     20, 200, 4000, 9, 9, 360, 360, 4720);

  select id into v_bl_v2    from public.purchase_bill_lines where purchase_bill_id = v_bill and line_number = 2;
  select id into v_bl_mat   from public.purchase_bill_lines where purchase_bill_id = v_bill and line_number = 3;
  select id into v_bl_spare from public.purchase_bill_lines where purchase_bill_id = v_bill and line_number = 4;

  -- ═══ Nothing goes back off a bill that was never posted ══════════════════
  insert into public.purchase_bills
    (dealer_id, branch_id, supplier_id, supplier_bill_number, bill_date)
  values (v_dealer, v_main, v_supplier, 'TVS/2026/9902', current_date)
  returning id into v_draft;

  perform app_test.assert_raises(
    format('select public.post_purchase_return(%L, %L::jsonb, ''Damaged'')',
           v_draft, jsonb_build_array(jsonb_build_object('bill_line_id', v_bl_mat, 'quantity', 1))::text),
    'a draft bill has nothing on the books to send back');

  v_entry := public.post_purchase_bill(v_bill);
  perform app_test.assert_equals(v_entry is not null, true, 'the consignment posts');

  select count(*)::int into v_count from public.returnable_purchase_lines(v_bill);
  perform app_test.assert_equals(v_count, 4, 'every line of the bill is returnable to begin with');

  select returnable_quantity into v_qty
    from public.returnable_purchase_lines(v_bill) where bill_line_id = v_bl_mat;
  perform app_test.assert_equals(v_qty, 10::numeric, 'all ten mats, none returned yet');

  -- ═══ A reason and something to return are both required ══════════════════
  perform app_test.assert_raises(
    format('select public.post_purchase_return(%L, %L::jsonb, '''')',
           v_bill, jsonb_build_array(jsonb_build_object('bill_line_id', v_bl_mat, 'quantity', 1))::text),
    'a debit note without a reason is refused (spec §23)');

  perform app_test.assert_raises(
    format('select public.post_purchase_return(%L, ''[]''::jsonb, ''Damaged'')', v_bill),
    'and so is one with nothing on it');

  perform app_test.assert_raises(
    format('select public.post_purchase_return(%L, %L::jsonb, ''Damaged'')',
           v_bill, jsonb_build_array(jsonb_build_object('bill_line_id', v_bl_mat, 'quantity', 11))::text),
    'more than arrived cannot go back');

  perform app_test.assert_raises(
    format('select public.post_purchase_return(%L, %L::jsonb, ''Half a scooter'')',
           v_bill, jsonb_build_array(jsonb_build_object('bill_line_id', v_bl_v2, 'quantity', 0.5))::text),
    'and a vehicle goes back whole or not at all');

  -- ═══ Three mats and one chassis go back ══════════════════════════════════
  select r.return_id, r.return_number, r.entry_id, r.total
    into v_ret, v_num, v_entry, v_total
    from public.post_purchase_return(
      v_bill,
      jsonb_build_array(
        jsonb_build_object('bill_line_id', v_bl_mat, 'quantity', 3),
        jsonb_build_object('bill_line_id', v_bl_v2,  'quantity', 1)),
      'Three mats water damaged; one chassis has a cracked fairing',
      current_date, 'TVS/CN/2026/41', 'test-key-1') r;

  perform app_test.assert_equals(
    (select return_number ~ '^PR-[0-9]{4}-[0-9]{6}$' from public.purchase_returns where id = v_ret),
    true, 'the note number is issued by the database as PR-YYYY-NNNNNN (spec §45)');

  -- 3 mats at 400 = 1200 + 216 GST; one chassis at 60000 + 16800 GST.
  perform app_test.assert_equals(v_total, 78216.0000::numeric,
    'the note is valued at the bill''s own rates, not at today''s cost');

  select sum(l.debit), sum(l.credit) into v_debit, v_credit
    from public.journal_entry_lines l where l.journal_entry_id = v_entry;
  perform app_test.assert_equals(v_debit, v_credit, 'the debit note balances (spec §22)');

  select sum(l.credit) into v_credit
    from public.journal_entry_lines l
    join public.chart_of_accounts c on c.id = l.account_id
   where l.journal_entry_id = v_entry and c.code = '1500';
  perform app_test.assert_equals(v_credit, 60000.0000::numeric,
    'the chassis comes off Vehicle Inventory at what it cost');

  select sum(l.credit) into v_credit
    from public.journal_entry_lines l
    join public.chart_of_accounts c on c.id = l.account_id
   where l.journal_entry_id = v_entry and c.code = '1600';
  perform app_test.assert_equals(v_credit, 1200.0000::numeric,
    'and three of ten mats come off Accessories Inventory, not all ten');

  select sum(l.credit) into v_credit
    from public.journal_entry_lines l
    join public.chart_of_accounts c on c.id = l.account_id
   where l.journal_entry_id = v_entry and c.code in ('1900', '1910');
  perform app_test.assert_equals(v_credit, 17016.0000::numeric,
    'input GST goes back with the goods, so ITC is not overclaimed');

  select sum(l.debit) into v_debit
    from public.journal_entry_lines l
    join public.chart_of_accounts c on c.id = l.account_id
   where l.journal_entry_id = v_entry and c.code = '2200';
  perform app_test.assert_equals(v_debit, 78216.0000::numeric,
    'and the whole of it comes off what is owed to the supplier');

  -- ═══ Stock ═══════════════════════════════════════════════════════════════
  select quantity into v_qty from public.inventory_stock
   where item_id = v_item and branch_id = v_main and source = 'LOCAL';
  perform app_test.assert_equals(v_qty, 7::numeric,
    'seven mats remain, and they leave the lot they joined (spec §28)');

  select count(*)::int into v_count from public.inventory_transactions
   where reference_type = 'PURCHASE_RETURN' and reference_id = v_ret
     and transaction_type = 'RETURN' and quantity < 0;
  perform app_test.assert_equals(v_count, 1,
    'the quantity falls through a movement, never by overwriting (spec §34)');

  perform app_test.assert_equals(
    (select status from public.vehicles where id = v_v2), 'RETURNED',
    'the chassis leaves stock as RETURNED — it was sent back, not cancelled');

  perform app_test.assert_equals(
    (select count(*)::int from public.vehicle_stock_transactions
      where vehicle_id = v_v2 and transaction_type = 'RETURN'
        and reference_type = 'PURCHASE_RETURN' and reference_id = v_ret),
    1, 'and the vehicle ledger records the movement and what caused it');

  perform app_test.assert_equals(
    (select count(*)::int from public.unbilled_vehicles(v_main)
      where chassis_no = 'RETTEST00000002'),
    0, 'a returned chassis is not offered for billing again');

  -- ═══ The supplier's ledger ═══════════════════════════════════════════════
  -- Bill 163,040 less the note 78,216 = 84,824 still owed.
  v_bal := public.party_ledger_opening('SUPPLIER', v_supplier, 'infinity'::date);
  perform app_test.assert_equals(v_bal, -84824.0000::numeric,
    'the supplier is owed the bill less the note (spec §41)');

  select count(*)::int into v_count
    from public.party_open_items('SUPPLIER', v_supplier)
   where side = 'DEBIT';
  perform app_test.assert_equals(v_count, 1,
    'and the note is an open debit that settlement can knock off the bill (0050)');

  select returnable_quantity into v_qty
    from public.returnable_purchase_lines(v_bill) where bill_line_id = v_bl_mat;
  perform app_test.assert_equals(v_qty, 7::numeric, 'seven mats are still returnable');

  select returnable_quantity into v_qty
    from public.returnable_purchase_lines(v_bill) where bill_line_id = v_bl_v2;
  perform app_test.assert_equals(v_qty, 0::numeric, 'and the chassis line has nothing left');

  -- ═══ Idempotency and immutability ════════════════════════════════════════
  select r.return_id into v_ret2
    from public.post_purchase_return(
      v_bill,
      jsonb_build_array(
        jsonb_build_object('bill_line_id', v_bl_mat, 'quantity', 3),
        jsonb_build_object('bill_line_id', v_bl_v2,  'quantity', 1)),
      'Three mats water damaged; one chassis has a cracked fairing',
      current_date, 'TVS/CN/2026/41', 'test-key-1') r;

  perform app_test.assert_equals(v_ret2, v_ret,
    'submitting the same note twice returns the first one (spec §50)');

  select quantity into v_qty from public.inventory_stock
   where item_id = v_item and branch_id = v_main and source = 'LOCAL';
  perform app_test.assert_equals(v_qty, 7::numeric,
    'and does not send the goods back a second time');

  perform app_test.assert_raises(
    format('select public.post_purchase_return(%L, %L::jsonb, ''Same chassis again'')',
           v_bill, jsonb_build_array(jsonb_build_object('bill_line_id', v_bl_v2, 'quantity', 1))::text),
    'a chassis already sent back cannot go back twice');

  perform app_test.assert_raises(
    format('insert into public.purchase_returns (dealer_id, branch_id, purchase_bill_id, '
           'supplier_id, reason, status, posted_at, journal_entry_id) '
           'values (%L, %L, %L, %L, ''By hand'', ''POSTED'', now(), %L)',
           v_dealer, v_main, v_bill, v_supplier, v_entry),
    'a note cannot be declared posted by hand — it would carry no stock movements');

  perform app_test.assert_raises(
    format('update public.purchase_returns set reason = ''Changed'' where id = %L', v_ret),
    'a posted note cannot be edited (spec §23)');

  perform app_test.assert_raises(
    format('delete from public.purchase_returns where id = %L', v_ret),
    'nor deleted');

  perform app_test.assert_raises(
    format('update public.purchase_return_lines set quantity = 9 where purchase_return_id = %L', v_ret),
    'and its lines are append-only');

  -- ═══ A second note takes the rest of the mats, exactly ═══════════════════
  select r.total into v_total
    from public.post_purchase_return(
      v_bill,
      jsonb_build_array(jsonb_build_object('bill_line_id', v_bl_mat, 'quantity', 7)),
      'The rest of the batch was damaged too', current_date, null, 'test-key-2') r;

  perform app_test.assert_equals(v_total, 3304.0000::numeric,
    'the last return of a line takes the exact remainder, so no paise are stranded');

  select sum(rl.taxable_value) into v_debit
    from public.purchase_return_lines rl
    join public.purchase_returns pr on pr.id = rl.purchase_return_id
   where rl.purchase_bill_line_id = v_bl_mat and pr.status = 'POSTED';
  perform app_test.assert_equals(v_debit, 4000.0000::numeric,
    'and the two notes together give back exactly what the line cost');

  select quantity into v_qty from public.inventory_stock
   where item_id = v_item and branch_id = v_main and source = 'LOCAL';
  perform app_test.assert_equals(v_qty, 0::numeric, 'no mats are left');

  perform app_test.assert_raises(
    format('select public.post_purchase_return(%L, %L::jsonb, ''One more'')',
           v_bill, jsonb_build_array(jsonb_build_object('bill_line_id', v_bl_mat, 'quantity', 1))::text),
    'and an exhausted line refuses a third note');

  -- ═══ Reversing a note ════════════════════════════════════════════════════
  v_rev := public.cancel_purchase_return(v_ret, 'The supplier would not accept the chassis back');
  perform app_test.assert_equals(v_rev is not null, true, 'reversing posts a second journal');

  perform app_test.assert_equals(
    (select status from public.purchase_returns where id = v_ret), 'CANCELLED',
    'the note is marked reversed rather than removed');

  perform app_test.assert_equals(
    (select status from public.vehicles where id = v_v2), 'IN_STOCK',
    'the chassis comes back into stock — which CANCELLED could never have allowed');

  select quantity into v_qty from public.inventory_stock
   where item_id = v_item and branch_id = v_main and source = 'LOCAL';
  perform app_test.assert_equals(v_qty, 3::numeric,
    'and the three mats come back into the lot they left');

  select returnable_quantity into v_qty
    from public.returnable_purchase_lines(v_bill) where bill_line_id = v_bl_mat;
  perform app_test.assert_equals(v_qty, 3::numeric,
    'a reversed note releases its quantity to be returned again');

  perform app_test.assert_raises(
    format('select public.cancel_purchase_return(%L, ''Again'')', v_ret),
    'a reversed note cannot be reversed twice');

  perform app_test.assert_raises(
    format('select public.cancel_purchase_return(%L, '''')', v_ret2),
    'and a reversal always requires a reason');

  -- ═══ The spare was never touched by any of it ════════════════════════════
  select quantity into v_qty from public.inventory_stock
   where item_id = v_spare and branch_id = v_main and source = 'COMPANY';
  perform app_test.assert_equals(v_qty, 20::numeric,
    'lines nobody returned are untouched — this is not a bill cancellation');

  perform app_test.assert_equals(
    (select status from public.purchase_bills where id = v_bill), 'POSTED',
    'and the bill itself stays posted');

  -- ═══ The books still balance ═════════════════════════════════════════════
  select sum(l.debit), sum(l.credit) into v_debit, v_credit
    from public.journal_entry_lines l
    join public.journal_entries e on e.id = l.journal_entry_id
   where e.dealer_id = v_dealer and e.status in ('POSTED', 'REVERSED');
  perform app_test.assert_equals(v_debit, v_credit,
    'the dealer''s ledger balances after purchase returns (spec §22)');
end;
$$;
