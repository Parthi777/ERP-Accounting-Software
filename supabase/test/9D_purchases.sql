-- =============================================================================
-- TEST — purchase bills
-- =============================================================================
-- Spec §13, §14, §21, §22, §28, §29, §34, §41, §48, §50.
--
-- The guarantees asserted here:
--   * a bill puts stock on the balance sheet — the debit that 1500/1600/1700
--     have never had — and the payable on the supplier's own ledger;
--   * input GST is captured as an asset, so ITC is tracked;
--   * a vehicle can be billed exactly once, however many drafts want it;
--   * accessory and spare quantities arrive as movements, into the right lot;
--   * the invoiced cost becomes the vehicle's cost, so margin is right later;
--   * a draft is editable and its totals follow its lines; a posted bill is not;
--   * posting twice posts once (spec §50);
--   * cancelling a posted bill reverses the journal and takes the stock back.
-- =============================================================================

\echo '--- purchase bills ---'

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
  v_other    uuid;
  v_entry    uuid;
  v_again    uuid;
  v_rev      uuid;
  v_qty      numeric;
  v_bal      numeric;
  v_total    numeric;
  v_cost     numeric;
  v_count    int;
  v_debit    numeric;
  v_credit   numeric;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_main   from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_model   from public.vehicle_models   where dealer_id = v_dealer limit 1;
  select id into v_variant from public.vehicle_variants where model_id = v_model limit 1;
  select id into v_hsn from public.hsn_codes limit 1;

  insert into public.suppliers (dealer_id, name, supplier_type, mobile, city, state)
  values (v_dealer, 'Purchase Test Motors', 'OEM', '9840077101', 'Chennai', 'Tamil Nadu')
  returning id into v_supplier;

  -- Two chassis, arrived through the upload path: created, but never accounted.
  insert into public.vehicles
    (dealer_id, branch_id, model_id, variant_id, chassis_no, engine_no,
     purchase_invoice, purchase_cost)
  values
    (v_dealer, v_main, v_model, v_variant, 'PURCHTEST00000001', 'PURCHENG00000001', null, 0),
    (v_dealer, v_main, v_model, v_variant, 'PURCHTEST00000002', 'PURCHENG00000002', null, 0);

  select id into v_v1 from public.vehicles where chassis_no = 'PURCHTEST00000001';
  select id into v_v2 from public.vehicles where chassis_no = 'PURCHTEST00000002';

  insert into public.inventory_items
    (dealer_id, item_code, name, item_type, hsn_code_id, standard_cost, selling_price)
  values (v_dealer, 'PT-MAT-01', 'Purchase Test Mat', 'ACCESSORY', v_hsn, 400, 650)
  returning id into v_item;

  insert into public.inventory_items
    (dealer_id, item_code, name, item_type, hsn_code_id, standard_cost, selling_price)
  values (v_dealer, 'PT-SHOE-01', 'Purchase Test Brake Shoe', 'SPARE', v_hsn, 200, 320)
  returning id into v_spare;

  -- ═══ Both chassis are billable, and nothing else knows about them ════════
  select count(*)::int into v_count
    from public.unbilled_vehicles(v_main)
   where chassis_no in ('PURCHTEST00000001', 'PURCHTEST00000002');
  perform app_test.assert_equals(v_count, 2, 'uploaded chassis are offered as unbilled');

  -- ═══ The draft ═══════════════════════════════════════════════════════════
  insert into public.purchase_bills
    (dealer_id, branch_id, supplier_id, supplier_bill_number, bill_date)
  values (v_dealer, v_main, v_supplier, 'TVS/2026/8801', current_date)
  returning id into v_bill;

  perform app_test.assert_equals(
    (select bill_number ~ '^PB-[0-9]{4}-[0-9]{6}$' from public.purchase_bills where id = v_bill),
    true, 'the bill number is issued by the database as PB-YYYY-NNNNNN (spec §45)');

  -- Two vehicles at 66,000 + 28% GST, twenty mats at 400, fifty shoes at 200.
  insert into public.purchase_bill_lines
    (purchase_bill_id, dealer_id, line_number, line_type, vehicle_id, description,
     quantity, unit_rate, taxable_value, cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount)
  values
    (v_bill, v_dealer, 1, 'VEHICLE', v_v1, 'Jupiter 110 — PURCHTEST00000001',
     1, 66000, 66000, 14, 14, 9240, 9240, 84480),
    (v_bill, v_dealer, 2, 'VEHICLE', v_v2, 'Jupiter 110 — PURCHTEST00000002',
     1, 66000, 66000, 14, 14, 9240, 9240, 84480);

  insert into public.purchase_bill_lines
    (purchase_bill_id, dealer_id, line_number, line_type, item_id, source, description,
     quantity, unit_rate, taxable_value, cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount)
  values
    (v_bill, v_dealer, 3, 'ACCESSORY', v_item, 'LOCAL', 'Floor mat', 20, 400, 8000, 9, 9, 720, 720, 9440),
    (v_bill, v_dealer, 4, 'SPARE', v_spare, 'COMPANY', 'Brake shoe', 50, 200, 10000, 9, 9, 900, 900, 11800);

  select taxable_value, total_amount into v_total, v_bal
    from public.purchase_bills where id = v_bill;
  perform app_test.assert_equals(v_total, 150000.0000::numeric,
    'the header taxable value follows the lines rather than being sent with them');
  perform app_test.assert_equals(v_bal, 190200.0000::numeric,
    'and so does the bill total');

  -- A chassis already on this draft is no longer on offer.
  select count(*)::int into v_count
    from public.unbilled_vehicles(v_main)
   where chassis_no in ('PURCHTEST00000001', 'PURCHTEST00000002');
  perform app_test.assert_equals(v_count, 0,
    'a chassis on an open draft is not offered to another bill');

  -- ═══ What a draft refuses ════════════════════════════════════════════════
  insert into public.purchase_bills
    (dealer_id, branch_id, supplier_id, supplier_bill_number, bill_date)
  values (v_dealer, v_main, v_supplier, 'TVS/2026/8802', current_date)
  returning id into v_other;

  perform app_test.assert_raises(
    format('insert into public.purchase_bill_lines (purchase_bill_id, dealer_id, line_number, '
           'line_type, vehicle_id, description, quantity, unit_rate, taxable_value, total_amount) '
           'values (%L, %L, 1, ''VEHICLE'', %L, ''Dup'', 1, 66000, 66000, 66000)',
           v_other, v_dealer, v_v1),
    'the same chassis cannot be put on two bills (spec §49)');

  perform app_test.assert_raises(
    format('insert into public.purchase_bill_lines (purchase_bill_id, dealer_id, line_number, '
           'line_type, item_id, description, quantity, unit_rate, taxable_value, total_amount) '
           'values (%L, %L, 2, ''ACCESSORY'', %L, ''No lot'', 5, 400, 2000, 2000)',
           v_other, v_dealer, v_item),
    'a counted line must say which lot it joins (spec §28)');

  perform app_test.assert_raises(
    format('insert into public.purchase_bill_lines (purchase_bill_id, dealer_id, line_number, '
           'line_type, vehicle_id, item_id, source, description, quantity, unit_rate, taxable_value, total_amount) '
           'values (%L, %L, 3, ''VEHICLE'', %L, %L, ''LOCAL'', ''Both'', 1, 1, 1, 1)',
           v_other, v_dealer, v_v2, v_item),
    'a line is a chassis or a counted item, never both');

  perform app_test.assert_raises(
    format('select public.post_purchase_bill(%L)', v_other),
    'a bill with no lines cannot be posted');

  perform public.cancel_purchase_bill(v_other, 'Keyed by mistake');
  perform app_test.assert_equals(
    (select count(*)::int from public.purchase_bills where id = v_other), 0,
    'cancelling a draft removes it — it never reached the ledger');

  -- ═══ Posting ═════════════════════════════════════════════════════════════
  v_entry := public.post_purchase_bill(v_bill);
  perform app_test.assert_equals(v_entry is not null, true, 'the bill posts a journal');

  perform app_test.assert_equals(
    (select status from public.purchase_bills where id = v_bill), 'POSTED',
    'and the bill is posted');

  select sum(l.debit), sum(l.credit) into v_debit, v_credit
    from public.journal_entry_lines l where l.journal_entry_id = v_entry;
  perform app_test.assert_equals(v_debit, v_credit, 'the purchase journal balances (spec §22)');
  perform app_test.assert_equals(v_credit, 190200.0000::numeric,
    'and its credit is the whole bill');

  -- ═══ The debit inventory never used to get ═══════════════════════════════
  select sum(l.debit) into v_debit
    from public.journal_entry_lines l
    join public.chart_of_accounts c on c.id = l.account_id
   where l.journal_entry_id = v_entry and c.code = '1500';
  perform app_test.assert_equals(v_debit, 132000.0000::numeric,
    'vehicle stock reaches Vehicle Inventory at cost');

  select sum(l.debit) into v_debit
    from public.journal_entry_lines l
    join public.chart_of_accounts c on c.id = l.account_id
   where l.journal_entry_id = v_entry and c.code = '1600';
  perform app_test.assert_equals(v_debit, 8000.0000::numeric,
    'accessories reach Accessories Inventory, not the vehicle account');

  select sum(l.debit) into v_debit
    from public.journal_entry_lines l
    join public.chart_of_accounts c on c.id = l.account_id
   where l.journal_entry_id = v_entry and c.code = '1700';
  perform app_test.assert_equals(v_debit, 10000.0000::numeric,
    'and spares reach Spare Inventory');

  -- ═══ Input GST is an asset, because it is owed back ══════════════════════
  select sum(l.debit) into v_debit
    from public.journal_entry_lines l
    join public.chart_of_accounts c on c.id = l.account_id
   where l.journal_entry_id = v_entry and c.code in ('1900', '1910');
  perform app_test.assert_equals(v_debit, 40200.0000::numeric,
    'input CGST and SGST are captured as ITC rather than buried in cost');

  -- ═══ The supplier ledger finally has a bill on it ════════════════════════
  v_bal := public.party_ledger_opening('SUPPLIER', v_supplier, 'infinity'::date);
  perform app_test.assert_equals(v_bal, -190200.0000::numeric,
    'the payable lands on the supplier''s own ledger, debit-positive so a Cr (spec §41)');

  select count(*)::int into v_count
    from public.party_open_items('SUPPLIER', v_supplier);
  perform app_test.assert_equals(v_count, 1,
    'and shows as one open item the payment can later be set against');

  -- ═══ Stock ═══════════════════════════════════════════════════════════════
  select quantity into v_qty from public.inventory_stock
   where item_id = v_item and branch_id = v_main and source = 'LOCAL';
  perform app_test.assert_equals(v_qty, 20::numeric,
    'the accessory quantity arrives through a movement, into the lot named');

  select count(*)::int into v_count from public.inventory_stock
   where item_id = v_item and branch_id = v_main and source = 'COMPANY';
  perform app_test.assert_equals(v_count, 0,
    'and not into the other lot (spec §28, §60.16)');

  select quantity into v_qty from public.inventory_stock
   where item_id = v_spare and branch_id = v_main and source = 'COMPANY';
  perform app_test.assert_equals(v_qty, 50::numeric, 'the spare quantity likewise');

  select purchase_cost into v_cost from public.vehicles where id = v_v1;
  perform app_test.assert_equals(v_cost, 66000.0000::numeric,
    'the invoiced cost becomes the vehicle cost, so COGS and margin are right later');

  perform app_test.assert_equals(
    (select purchase_invoice from public.vehicles where id = v_v1), 'TVS/2026/8801',
    'and the chassis carries the supplier''s bill number');

  -- ═══ Immutability and idempotency ════════════════════════════════════════
  v_again := public.post_purchase_bill(v_bill);
  perform app_test.assert_equals(v_again, v_entry,
    'posting twice returns the first entry rather than posting again (spec §50)');

  perform app_test.assert_raises(
    format('insert into public.purchase_bill_lines (purchase_bill_id, dealer_id, line_number, '
           'line_type, item_id, source, description, quantity, unit_rate, taxable_value, total_amount) '
           'values (%L, %L, 9, ''SPARE'', %L, ''LOCAL'', ''Late'', 1, 100, 100, 100)',
           v_bill, v_dealer, v_spare),
    'a posted bill cannot gain a line (spec §23)');

  perform app_test.assert_raises(
    format('update public.purchase_bills set supplier_bill_number = ''CHANGED'' where id = %L', v_bill),
    'and a posted bill cannot be edited');

  perform app_test.assert_raises(
    format('delete from public.purchase_bills where id = %L', v_bill),
    'nor deleted');

  -- ═══ Cancelling a posted bill ════════════════════════════════════════════
  v_rev := public.cancel_purchase_bill(v_bill, 'Supplier raised a corrected invoice');
  perform app_test.assert_equals(v_rev is not null, true, 'cancelling posts a reversal');
  perform app_test.assert_equals(
    (select status from public.journal_entries where id = v_entry), 'REVERSED',
    'the original journal is reversed, not edited');

  select quantity into v_qty from public.inventory_stock
   where item_id = v_item and branch_id = v_main and source = 'LOCAL';
  perform app_test.assert_equals(v_qty, 0::numeric,
    'the stock the bill brought in goes back out again (spec §34)');

  v_bal := public.party_ledger_opening('SUPPLIER', v_supplier, 'infinity'::date);
  perform app_test.assert_equals(v_bal, 0.0000::numeric,
    'and the supplier is owed nothing again');

  -- ═══ The books still balance ═════════════════════════════════════════════
  select sum(l.debit), sum(l.credit) into v_debit, v_credit
    from public.journal_entry_lines l
    join public.journal_entries e on e.id = l.journal_entry_id
   where e.dealer_id = v_dealer and e.status in ('POSTED', 'REVERSED');
  perform app_test.assert_equals(v_debit, v_credit,
    'the dealer''s ledger balances after purchases (spec §22)');
end;
$$;
