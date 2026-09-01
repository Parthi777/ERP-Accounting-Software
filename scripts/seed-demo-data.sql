-- =============================================================================
-- seed-demo-data.sql — realistic trading data for the demo dealer
-- =============================================================================
-- supabase/seed.sql creates the dealer, its branches, staff, chart of accounts,
-- accounting rules and document sequences. It stops there, so a fresh deployment
-- has an ERP with nothing in it: Sales, Inventory, Service and Finance are all
-- empty and there is no way to tell a working screen from a broken one.
--
-- This fills in the trading.
--
--   psql "$DATABASE_URL" -f scripts/seed-demo-data.sql
--
-- Everything goes through the real business functions — create_booking_with_advance,
-- post_vehicle_sale, deliver_vehicle, post_service_invoice, record_trade_advance
-- and the rest — rather than being inserted row by row. Two reasons:
--
--   * the ledger comes out genuinely balanced, with stock relieved, COGS
--     recognised, tax split and documents numbered exactly as they would be in
--     use. Rows inserted directly would look right on screen and be wrong
--     underneath, which is worse than an empty screen;
--   * it exercises the same code paths a user does. If this script runs clean,
--     the application's write paths work against this database.
--
-- The exceptions are the masters — models, price versions, customers, items —
-- which have no posting behaviour to exercise and are plain inserts.
--
-- Idempotent by refusal, not by merging: it stops if trading data is already
-- present, because running it twice would double the stock and the ledger.
--
-- Remove it with scripts/remove-demo-dealer.sql, which takes the demo dealer and
-- everything under it, this data included.
-- =============================================================================

\set ON_ERROR_STOP on

-- =============================================================================
-- 1 — Masters
-- =============================================================================
do $$
declare
  v_dealer   uuid;
  v_main     uuid;
  v_north    uuid;
  v_south    uuid;
  v_hsn_veh  uuid;
  v_hsn_part uuid;
  v_hsn_lab  uuid;
  v_jup uuid; v_jup_v uuid;
  v_ntq uuid; v_ntq_v uuid;
  v_apa uuid; v_apa_v uuid;
  v_cust record;
  v_n int;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  if v_dealer is null then
    raise exception 'No demo dealer (code SBM). Run supabase/seed.sql first.';
  end if;

  select count(*) into v_n from public.vehicles where dealer_id = v_dealer;
  if v_n > 0 then
    raise exception 'Demo trading data is already present (% vehicles). Remove it with '
                    'scripts/remove-demo-dealer.sql and re-seed, rather than running this twice.', v_n
      using errcode = 'unique_violation';
  end if;

  select id into v_main  from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_north from public.branches where dealer_id = v_dealer and code = 'NORTH';
  select id into v_south from public.branches where dealer_id = v_dealer and code = 'SOUTH';

  -- ── HSN / SAC and tax codes (spec §16 — rates are configuration) ──────────
  insert into public.hsn_codes (dealer_id, code, code_type, description) values
    (v_dealer, '87112019', 'HSN', 'Motorcycles and scooters'),
    (v_dealer, '87141090', 'HSN', 'Parts and accessories of two-wheelers'),
    (v_dealer, '998714',   'SAC', 'Maintenance and repair of motor vehicles');

  select id into v_hsn_veh  from public.hsn_codes where dealer_id = v_dealer and code = '87112019';
  select id into v_hsn_part from public.hsn_codes where dealer_id = v_dealer and code = '87141090';
  select id into v_hsn_lab  from public.hsn_codes where dealer_id = v_dealer and code = '998714';

  -- igst_rate = cgst + sgst is enforced by tax_codes_igst_matches_check.
  insert into public.tax_codes
    (dealer_id, code, name, hsn_code_id, cgst_rate, sgst_rate, igst_rate, effective_from) values
    (v_dealer, 'GST28',  'GST 28% — vehicles',       v_hsn_veh,  14,  14,  28, date '2020-04-01'),
    (v_dealer, 'GST18',  'GST 18% — parts',          v_hsn_part,  9,   9,  18, date '2020-04-01'),
    (v_dealer, 'GST18L', 'GST 18% — service labour', v_hsn_lab,   9,   9,  18, date '2020-04-01'),
    (v_dealer, 'GST5',   'GST 5% — concessional',    v_hsn_part, 2.5, 2.5,  5, date '2020-04-01');

  -- ── Vehicle catalogue ────────────────────────────────────────────────────
  insert into public.vehicle_models
    (dealer_id, brand, name, model_code, category, hsn_code_id, tax_code) values
    (v_dealer, 'TVS', 'Jupiter 110', 'JUPITER110', 'SCOOTER',    v_hsn_veh, 'GST28'),
    (v_dealer, 'TVS', 'Ntorq 125',   'NTORQ125',   'SCOOTER',    v_hsn_veh, 'GST28'),
    (v_dealer, 'TVS', 'Apache RTR',  'APACHE160',  'MOTORCYCLE', v_hsn_veh, 'GST28');

  select id into v_jup from public.vehicle_models where dealer_id = v_dealer and model_code = 'JUPITER110';
  select id into v_ntq from public.vehicle_models where dealer_id = v_dealer and model_code = 'NTORQ125';
  select id into v_apa from public.vehicle_models where dealer_id = v_dealer and model_code = 'APACHE160';

  insert into public.vehicle_variants
    (dealer_id, model_id, name, variant_code, engine_cc, brake_type, start_type) values
    (v_dealer, v_jup, 'Sheet Metal',  'JUPITER110-SM', 109.7, 'DRUM', 'SELF'),
    (v_dealer, v_ntq, 'Race XP',      'NTORQ125-RXP',  124.8, 'DISC', 'SELF'),
    (v_dealer, v_apa, 'Race Edition', 'APACHE160-RE',  159.7, 'DISC', 'SELF');

  select id into v_jup_v from public.vehicle_variants where dealer_id = v_dealer and variant_code = 'JUPITER110-SM';
  select id into v_ntq_v from public.vehicle_variants where dealer_id = v_dealer and variant_code = 'NTORQ125-RXP';
  select id into v_apa_v from public.vehicle_variants where dealer_id = v_dealer and variant_code = 'APACHE160-RE';

  -- ── Prices (spec §15) ────────────────────────────────────────────────────
  -- Written ACTIVE with an approval stamp rather than driven through
  -- decide_price_version(). That workflow deliberately refuses to let the
  -- submitter approve their own price, and a seed has nobody to be the second
  -- pair of eyes. The approval path is covered by supabase/test/95_price_approval.sql.
  --
  -- Jupiter gets a superseded version 1 as well, so Price History (spec §42) has
  -- a real before-and-after and an invoice can be checked against the price that
  -- applied on its own date rather than today's.
  insert into public.vehicle_price_versions
    (dealer_id, model_id, variant_id, version_number, ex_showroom, insurance, registration,
     mandatory_accessories, forwarding_charge, purchase_cost, max_discount, tax_code,
     effective_from, effective_to, status, approved_at, notes)
  values
    (v_dealer, v_jup, v_jup_v, 1, 79000, 6000, 7300, 1800, 1200, 66000, 2500, 'GST28',
     date '2026-04-01', date '2026-06-30', 'SUPERSEDED', now(), 'Opening FY price');

  insert into public.vehicle_price_versions
    (dealer_id, model_id, variant_id, version_number, ex_showroom, insurance, registration,
     mandatory_accessories, forwarding_charge, purchase_cost, max_discount, tax_code,
     effective_from, status, approved_at, notes)
  values
    (v_dealer, v_jup, v_jup_v, 2,  82000, 6200,  7500, 1800, 1200,  68500, 3000, 'GST28',
     date '2026-07-01', 'ACTIVE', now(), 'July revision'),
    (v_dealer, v_ntq, v_ntq_v, 1,  98000, 7100,  8800, 2400, 1400,  82000, 3500, 'GST28',
     date '2026-04-01', 'ACTIVE', now(), 'Opening FY price'),
    (v_dealer, v_apa, v_apa_v, 1, 124000, 8600, 10500, 3000, 1600, 104000, 4000, 'GST28',
     date '2026-04-01', 'ACTIVE', now(), 'Opening FY price');

  -- One price awaiting a decision, so /masters/pricing has a queue rather than
  -- a blank screen.
  insert into public.vehicle_price_versions
    (dealer_id, model_id, variant_id, version_number, ex_showroom, insurance, registration,
     mandatory_accessories, forwarding_charge, purchase_cost, max_discount, tax_code,
     effective_from, status, submitted_at, notes)
  values
    (v_dealer, v_ntq, v_ntq_v, 2, 101500, 7300, 9000, 2400, 1400, 84500, 3500, 'GST28',
     date '2026-10-01', 'SUBMITTED', now(), 'Festive season revision — awaiting approval');

  -- ── Customers (spec §11 — the code is issued by a trigger) ───────────────
  for v_cust in
    select * from (values
      ('Ramesh Kumar',       '9840110001', 'INDIVIDUAL', null,              'Chennai',  '600042', 'ABCPK1234M'),
      ('Lakshmi Narayanan',  '9840110002', 'INDIVIDUAL', null,              'Chennai',  '600017', null),
      ('Anitha Selvam',      '9840110003', 'INDIVIDUAL', null,              'Tambaram', '600045', null),
      ('Karthik Industries', '9840110004', 'BUSINESS',   '33AACCK9012B1ZP', 'Ambattur', '600053', 'AACCK9012B'),
      ('Vijay Transport',    '9840110005', 'BUSINESS',   '33AABCV3456C1ZQ', 'Chennai',  '600032', 'AABCV3456C'),
      ('Deepa Ravi',         '9840110006', 'INDIVIDUAL', null,              'Chennai',  '600020', null),
      ('Mohan Raghavan',     '9840110007', 'INDIVIDUAL', null,              'Tambaram', '600045', null),
      ('Meena Traders',      '9840110008', 'BUSINESS',   '33AAFCM7788D1ZR', 'Chennai',  '600028', 'AAFCM7788D')
    ) as t(name, mobile, ctype, gstin, city, pincode, pan)
  loop
    insert into public.customers
      (dealer_id, name, mobile, customer_type, gstin, pan, address_line1, city,
       state, state_code, pincode, origin_branch_id)
    values
      (v_dealer, v_cust.name, v_cust.mobile, v_cust.ctype, v_cust.gstin, v_cust.pan,
       'Plot ' || right(v_cust.mobile, 2) || ', ' || v_cust.city, v_cust.city,
       'Tamil Nadu', '33', v_cust.pincode,
       case when v_cust.city = 'Tambaram' then v_south else v_main end);
  end loop;

  -- ── Suppliers (spec §24 — the payable side of the ledger) ────────────────
  insert into public.suppliers
    (dealer_id, name, supplier_type, contact_person, mobile, city, state, state_code,
     gstin, credit_days) values
    (v_dealer, 'TVS Motor Company',  'OEM',     'Ravi Shankar',   '9840220001', 'Hosur',   'Tamil Nadu', '33', '33AAACT1234E1ZS', 30),
    (v_dealer, 'Chennai Lubricants', 'GOODS',   'Suresh Iyer',    '9840220002', 'Chennai', 'Tamil Nadu', '33', '33AAGCL5566F1ZT', 15),
    (v_dealer, 'Southern Logistics', 'SERVICE', 'Prakash Nair',   '9840220003', 'Chennai', 'Tamil Nadu', '33', null,               7);

  -- ── Finance companies (spec §25 — one ledger each, never merged) ─────────
  insert into public.finance_companies
    (dealer_id, code, name, contact_person, mobile, gstin, commission_percent) values
    (v_dealer, 'TVSCREDIT', 'TVS Credit Services Ltd', 'Priya Menon',    '9840330001', '33AAACT8899G1ZU', 2.500),
    (v_dealer, 'HDFCBANK',  'HDFC Bank Ltd',           'Arun Prasad',    '9840330002', '33AAACH2233H1ZV', 2.000),
    (v_dealer, 'CHOLA',     'Cholamandalam Finance',   'Sneha Krishnan', '9840330003', null,              2.750);

  raise notice 'Masters: 3 models, 5 price versions, 8 customers, 3 suppliers, 3 finance companies.';
end;
$$;

-- =============================================================================
-- 2 — Cash and bank accounts
-- =============================================================================
-- seed.sql already creates one cash account per branch (spec §36) with a nil
-- opening balance. A demo wants a float in the till, so the balances are set
-- here; the bank accounts have no equivalent and are created outright.
do $$
declare
  v_dealer uuid;
  v_bankgl uuid;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_bankgl from public.chart_of_accounts where dealer_id = v_dealer and code = '1200';

  update public.cash_accounts
     set opening_balance = 25000, current_balance = 25000
   where dealer_id = v_dealer;

  insert into public.bank_accounts
    (dealer_id, branch_id, name, bank_name, account_number, ifsc, account_type,
     ledger_account_id, opening_balance, current_balance)
  select v_dealer, b.id, b.name || ' — Current A/c', 'HDFC Bank',
         '5010' || lpad((row_number() over (order by b.code))::text, 8, '0'),
         'HDFC0001234', 'CURRENT', v_bankgl, 500000, 500000
    from public.branches b
   where b.dealer_id = v_dealer and b.is_head_office;

  insert into public.bank_accounts
    (dealer_id, branch_id, name, bank_name, account_number, ifsc, account_type,
     ledger_account_id, opening_balance, current_balance)
  values (v_dealer, null, 'Dealer Collection A/c', 'ICICI Bank', '602201234567',
          'ICIC0006022', 'CURRENT', v_bankgl, 250000, 250000);

  raise notice 'Cash and bank: 3 branch cash accounts, 2 bank accounts.';
end;
$$;

-- =============================================================================
-- 3 — Accessories and spares, with opening stock
-- =============================================================================
do $$
declare
  v_dealer uuid;
  v_main uuid; v_north uuid; v_south uuid;
  v_hsn_part uuid;
  v_helmet uuid; v_mat uuid; v_guard uuid; v_cover uuid;
  v_oil uuid; v_brake uuid; v_filter uuid; v_plug uuid;
  v_jup uuid; v_jup_v uuid; v_ntq uuid; v_ntq_v uuid;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_main  from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_north from public.branches where dealer_id = v_dealer and code = 'NORTH';
  select id into v_south from public.branches where dealer_id = v_dealer and code = 'SOUTH';
  select id into v_hsn_part from public.hsn_codes where dealer_id = v_dealer and code = '87141090';
  select id into v_jup   from public.vehicle_models   where dealer_id = v_dealer and model_code = 'JUPITER110';
  select id into v_ntq   from public.vehicle_models   where dealer_id = v_dealer and model_code = 'NTORQ125';
  select id into v_jup_v from public.vehicle_variants where dealer_id = v_dealer and variant_code = 'JUPITER110-SM';
  select id into v_ntq_v from public.vehicle_variants where dealer_id = v_dealer and variant_code = 'NTORQ125-RXP';

  insert into public.inventory_items
    (dealer_id, item_code, name, item_type, brand, category, uom, hsn_code_id, tax_code,
     standard_cost, selling_price, reorder_level, is_fitment) values
    (v_dealer, 'AC-HELM-01', 'Full face helmet', 'ACCESSORY', 'Studds', 'Safety',    'NOS', v_hsn_part, 'GST18', 900, 1450,  6, false),
    (v_dealer, 'AC-MAT-01',  'Floor mat',        'ACCESSORY', 'Local',  'Fitment',   'NOS', v_hsn_part, 'GST18', 320,  580, 10, true),
    (v_dealer, 'AC-GRD-01',  'Leg guard',        'ACCESSORY', 'Local',  'Fitment',   'NOS', v_hsn_part, 'GST18', 640, 1100,  8, true),
    (v_dealer, 'AC-SEAT-01', 'Seat cover',       'ACCESSORY', 'Local',  'Fitment',   'NOS', v_hsn_part, 'GST18', 380,  720,  8, true),
    (v_dealer, 'SP-OIL-01',  'Engine oil 1L',    'SPARE',     'TVS',    'Lubricant', 'LTR', v_hsn_part, 'GST18', 310,  480, 20, false),
    (v_dealer, 'SP-BRK-01',  'Brake shoe set',   'SPARE',     'TVS',    'Braking',   'SET', v_hsn_part, 'GST18', 240,  420, 12, false),
    (v_dealer, 'SP-FLT-01',  'Air filter',       'SPARE',     'TVS',    'Engine',    'NOS', v_hsn_part, 'GST18', 185,  330, 15, false),
    (v_dealer, 'SP-PLG-01',  'Spark plug',       'SPARE',     'TVS',    'Engine',    'NOS', v_hsn_part, 'GST18',  95,  190, 25, false);

  select id into v_helmet from public.inventory_items where dealer_id = v_dealer and item_code = 'AC-HELM-01';
  select id into v_mat    from public.inventory_items where dealer_id = v_dealer and item_code = 'AC-MAT-01';
  select id into v_guard  from public.inventory_items where dealer_id = v_dealer and item_code = 'AC-GRD-01';
  select id into v_cover  from public.inventory_items where dealer_id = v_dealer and item_code = 'AC-SEAT-01';
  select id into v_oil    from public.inventory_items where dealer_id = v_dealer and item_code = 'SP-OIL-01';
  select id into v_brake  from public.inventory_items where dealer_id = v_dealer and item_code = 'SP-BRK-01';
  select id into v_filter from public.inventory_items where dealer_id = v_dealer and item_code = 'SP-FLT-01';
  select id into v_plug   from public.inventory_items where dealer_id = v_dealer and item_code = 'SP-PLG-01';

  -- Spec §28: LOCAL and COMPANY lots stay separately traceable, so several items
  -- are stocked from both sources at different costs. balance_after is left to
  -- the trigger — writing a derived figure by hand is how ledgers drift.
  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
     reference_type, reference_number, narration) values
    (v_dealer, v_main,  v_helmet, 'COMPANY', 'OPENING', 24, 900, 'OPENING', 'OPEN-2026', 'Opening stock 01-Jul-2026'),
    (v_dealer, v_main,  v_mat,    'LOCAL',   'OPENING', 18, 300, 'OPENING', 'OPEN-2026', 'Opening stock 01-Jul-2026'),
    (v_dealer, v_main,  v_mat,    'COMPANY', 'OPENING', 30, 330, 'OPENING', 'OPEN-2026', 'Opening stock 01-Jul-2026'),
    (v_dealer, v_main,  v_guard,  'LOCAL',   'OPENING', 12, 620, 'OPENING', 'OPEN-2026', 'Opening stock 01-Jul-2026'),
    (v_dealer, v_main,  v_guard,  'COMPANY', 'OPENING', 16, 660, 'OPENING', 'OPEN-2026', 'Opening stock 01-Jul-2026'),
    (v_dealer, v_main,  v_cover,  'LOCAL',   'OPENING', 20, 375, 'OPENING', 'OPEN-2026', 'Opening stock 01-Jul-2026'),
    (v_dealer, v_main,  v_oil,    'COMPANY', 'OPENING', 60, 310, 'OPENING', 'OPEN-2026', 'Opening stock 01-Jul-2026'),
    (v_dealer, v_main,  v_brake,  'COMPANY', 'OPENING', 40, 240, 'OPENING', 'OPEN-2026', 'Opening stock 01-Jul-2026'),
    (v_dealer, v_main,  v_filter, 'COMPANY', 'OPENING', 35, 185, 'OPENING', 'OPEN-2026', 'Opening stock 01-Jul-2026'),
    (v_dealer, v_main,  v_plug,   'COMPANY', 'OPENING', 80,  95, 'OPENING', 'OPEN-2026', 'Opening stock 01-Jul-2026'),
    (v_dealer, v_north, v_helmet, 'COMPANY', 'OPENING', 10, 900, 'OPENING', 'OPEN-2026', 'Opening stock 01-Jul-2026'),
    (v_dealer, v_north, v_mat,    'COMPANY', 'OPENING', 14, 330, 'OPENING', 'OPEN-2026', 'Opening stock 01-Jul-2026'),
    (v_dealer, v_north, v_oil,    'COMPANY', 'OPENING', 25, 310, 'OPENING', 'OPEN-2026', 'Opening stock 01-Jul-2026'),
    (v_dealer, v_north, v_plug,   'COMPANY', 'OPENING', 30,  95, 'OPENING', 'OPEN-2026', 'Opening stock 01-Jul-2026'),
    (v_dealer, v_south, v_helmet, 'COMPANY', 'OPENING',  8, 900, 'OPENING', 'OPEN-2026', 'Opening stock 01-Jul-2026'),
    (v_dealer, v_south, v_oil,    'COMPANY', 'OPENING', 20, 310, 'OPENING', 'OPEN-2026', 'Opening stock 01-Jul-2026'),
    (v_dealer, v_south, v_brake,  'COMPANY', 'OPENING', 15, 240, 'OPENING', 'OPEN-2026', 'Opening stock 01-Jul-2026');

  -- Movements, so the stock ledger is not made entirely of openings.
  perform public.transfer_inventory_stock(v_oil,  v_main, v_north,  5, 'COMPANY', 'Branch indent — North workshop');
  perform public.transfer_inventory_stock(v_plug, v_main, v_south, 10, 'COMPANY', 'Branch indent — South workshop');
  perform public.adjust_inventory_stock(v_brake, v_main, 'COMPANY', -2, 'Two sets damaged in storage — written off after count');
  perform public.adjust_inventory_stock(v_mat,   v_main, 'LOCAL',    3, 'Physical count found three more than the ledger');

  -- ── Fitting templates (spec §30) ─────────────────────────────────────────
  insert into public.accessory_vehicle_mappings
    (dealer_id, model_id, variant_id, item_id, quantity, is_default, priority) values
    (v_dealer, v_jup, v_jup_v, v_mat,   1, true,  10),
    (v_dealer, v_jup, v_jup_v, v_guard, 1, true,  20),
    (v_dealer, v_jup, v_jup_v, v_cover, 1, false, 30),
    (v_dealer, v_ntq, v_ntq_v, v_mat,   1, true,  10),
    (v_dealer, v_ntq, v_ntq_v, v_cover, 1, true,  20);

  raise notice 'Inventory: 8 items, 17 opening lots, 2 transfers, 2 adjustments, 5 fitting mappings.';
end;
$$;

-- =============================================================================
-- 4 — Vehicle stock (spec §13 — chassis level, never a quantity)
-- =============================================================================
do $$
declare
  v_dealer uuid;
  v_main uuid; v_north uuid; v_south uuid;
  v_jup uuid; v_jup_v uuid; v_ntq uuid; v_ntq_v uuid; v_apa uuid; v_apa_v uuid;
  v_moving uuid;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_main  from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_north from public.branches where dealer_id = v_dealer and code = 'NORTH';
  select id into v_south from public.branches where dealer_id = v_dealer and code = 'SOUTH';
  select id into v_jup   from public.vehicle_models   where dealer_id = v_dealer and model_code = 'JUPITER110';
  select id into v_ntq   from public.vehicle_models   where dealer_id = v_dealer and model_code = 'NTORQ125';
  select id into v_apa   from public.vehicle_models   where dealer_id = v_dealer and model_code = 'APACHE160';
  select id into v_jup_v from public.vehicle_variants where dealer_id = v_dealer and variant_code = 'JUPITER110-SM';
  select id into v_ntq_v from public.vehicle_variants where dealer_id = v_dealer and variant_code = 'NTORQ125-RXP';
  select id into v_apa_v from public.vehicle_variants where dealer_id = v_dealer and variant_code = 'APACHE160-RE';

  -- Purchase dates spread over three months, so stock ageing has a shape.
  insert into public.vehicles
    (dealer_id, branch_id, model_id, variant_id, chassis_no, engine_no, key_no, model_year,
     purchase_cost, purchase_invoice, purchase_date, stock_date) values
    (v_dealer, v_main,  v_jup, v_jup_v, 'MD625JU10P1A00001', 'JU1AP1000001', 'K1001', 2026,  68500, 'PINV-4401', date '2026-06-02', date '2026-06-03'),
    (v_dealer, v_main,  v_jup, v_jup_v, 'MD625JU10P1A00002', 'JU1AP1000002', 'K1002', 2026,  68500, 'PINV-4401', date '2026-06-02', date '2026-06-03'),
    (v_dealer, v_main,  v_jup, v_jup_v, 'MD625JU10P1A00003', 'JU1AP1000003', 'K1003', 2026,  68500, 'PINV-4401', date '2026-06-02', date '2026-06-03'),
    (v_dealer, v_main,  v_jup, v_jup_v, 'MD625JU10P1A00004', 'JU1AP1000004', 'K1004', 2026,  68500, 'PINV-4412', date '2026-07-14', date '2026-07-15'),
    (v_dealer, v_main,  v_ntq, v_ntq_v, 'MD625NT12P2B00001', 'NT2BP2000001', 'K2001', 2026,  82000, 'PINV-4402', date '2026-07-10', date '2026-07-11'),
    (v_dealer, v_main,  v_ntq, v_ntq_v, 'MD625NT12P2B00002', 'NT2BP2000002', 'K2002', 2026,  82000, 'PINV-4402', date '2026-07-10', date '2026-07-11'),
    (v_dealer, v_main,  v_apa, v_apa_v, 'MD634AP16P3C00001', 'AP3CP3000001', 'K3001', 2026, 104000, 'PINV-4403', date '2026-07-18', date '2026-07-19'),
    (v_dealer, v_main,  v_apa, v_apa_v, 'MD634AP16P3C00002', 'AP3CP3000002', 'K3002', 2026, 104000, 'PINV-4419', date '2026-08-08', date '2026-08-09'),
    (v_dealer, v_north, v_jup, v_jup_v, 'MD625JU10P1A00005', 'JU1AP1000005', 'K1005', 2026,  68500, 'PINV-4404', date '2026-07-20', date '2026-07-21'),
    (v_dealer, v_north, v_jup, v_jup_v, 'MD625JU10P1A00006', 'JU1AP1000006', 'K1006', 2026,  68500, 'PINV-4404', date '2026-07-20', date '2026-07-21'),
    (v_dealer, v_north, v_ntq, v_ntq_v, 'MD625NT12P2B00003', 'NT2BP2000003', 'K2003', 2026,  82000, 'PINV-4404', date '2026-07-20', date '2026-07-21'),
    (v_dealer, v_south, v_apa, v_apa_v, 'MD634AP16P3C00003', 'AP3CP3000003', 'K3003', 2026, 104000, 'PINV-4405', date '2026-07-25', date '2026-07-26'),
    (v_dealer, v_south, v_jup, v_jup_v, 'MD625JU10P1A00007', 'JU1AP1000007', 'K1007', 2026,  68500, 'PINV-4405', date '2026-07-25', date '2026-07-26'),
    (v_dealer, v_south, v_ntq, v_ntq_v, 'MD625NT12P2B00004', 'NT2BP2000004', 'K2004', 2026,  82000, 'PINV-4420', date '2026-08-12', date '2026-08-13');

  -- One unit in transit between branches (spec §35), so the transfer screen has
  -- something outstanding to receive.
  select id into v_moving from public.vehicles where dealer_id = v_dealer and chassis_no = 'MD625JU10P1A00007';
  perform public.dispatch_vehicle_transfer(v_moving, v_main, 'Stock rebalancing — MAIN is short of Jupiter');

  raise notice 'Vehicles: 14 units across 3 branches, 1 in transit.';
end;
$$;

-- =============================================================================
-- 5 — Opening capital and the purchases that put the stock on the books
-- =============================================================================
-- Stock arrives in this ERP through two paths that write no journal at all: the
-- vehicle upload (0017) and an OPENING inventory transaction (0019). Both are
-- deliberate — they are bulk data loads, not business transactions — but it
-- means an asset exists in the stock ledger that the general ledger has never
-- heard of. Sell it and COGS relieves an inventory account that was never
-- debited, so the balance sheet shows negative inventory.
--
-- Real dealers close that gap with opening entries. So does this: the capital
-- introduced, then one purchase journal per supplier invoice, party-tagged so
-- the supplier ledger (0041) has a balance to work with and the payments made
-- further down draw a real payable down rather than into a debit.
do $$
declare
  v_dealer uuid;
  v_head   uuid;
  v_cash uuid; v_bank uuid; v_capital uuid;
  v_veh_inv uuid; v_acc_inv uuid; v_spr_inv uuid; v_payable uuid;
  v_tvs uuid; v_local uuid;
  v_cash_amt numeric; v_bank_amt numeric;
  v_pinv record;
  v_lot  record;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_head from public.branches where dealer_id = v_dealer and is_head_office;

  select id into v_cash    from public.chart_of_accounts where dealer_id = v_dealer and code = '1100';
  select id into v_bank    from public.chart_of_accounts where dealer_id = v_dealer and code = '1200';
  select id into v_veh_inv from public.chart_of_accounts where dealer_id = v_dealer and code = '1500';
  select id into v_acc_inv from public.chart_of_accounts where dealer_id = v_dealer and code = '1600';
  select id into v_spr_inv from public.chart_of_accounts where dealer_id = v_dealer and code = '1700';
  select id into v_payable from public.chart_of_accounts where dealer_id = v_dealer and code = '2200';
  select id into v_capital from public.chart_of_accounts where dealer_id = v_dealer and code = '3100';

  select id into v_tvs   from public.suppliers where dealer_id = v_dealer and name = 'TVS Motor Company';
  select id into v_local from public.suppliers where dealer_id = v_dealer and name = 'Chennai Lubricants';

  select coalesce(sum(opening_balance), 0) into v_cash_amt from public.cash_accounts where dealer_id = v_dealer;
  select coalesce(sum(opening_balance), 0) into v_bank_amt from public.bank_accounts where dealer_id = v_dealer;

  -- ── Capital introduced ───────────────────────────────────────────────────
  -- The cash and bank accounts carry an opening_balance of their own; this is
  -- the journal that makes the general ledger agree with them.
  perform app.post_journal(
    v_dealer, v_head, date '2026-06-01', 'OPENING',
    'Opening balances — capital introduced',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash,    'debit', v_cash_amt, 'credit', 0,
                         'narration', 'Opening cash in hand across branches'),
      jsonb_build_object('account_id', v_bank,    'debit', v_bank_amt, 'credit', 0,
                         'narration', 'Opening bank balances'),
      jsonb_build_object('account_id', v_capital, 'debit', 0, 'credit', v_cash_amt + v_bank_amt,
                         'narration', 'Proprietor capital')
    ),
    'OPENING', null, 'demo-opening-capital'
  );

  -- ── Vehicle purchases, one journal per supplier invoice ─────────────────
  -- Dated on the invoice, so stock ageing and the ledger tell the same story.
  for v_pinv in
    select purchase_invoice, purchase_date, branch_id, sum(purchase_cost) as cost, count(*) as units
      from public.vehicles
     where dealer_id = v_dealer
     group by purchase_invoice, purchase_date, branch_id
     order by purchase_date, purchase_invoice
  loop
    perform app.post_journal(
      v_dealer, v_pinv.branch_id, v_pinv.purchase_date, 'INVENTORY',
      'Vehicle purchase ' || v_pinv.purchase_invoice,
      jsonb_build_array(
        jsonb_build_object('account_id', v_veh_inv, 'debit', v_pinv.cost, 'credit', 0,
                           'narration', v_pinv.units || ' unit(s) into stock'),
        jsonb_build_object('account_id', v_payable, 'debit', 0, 'credit', v_pinv.cost,
                           'narration', 'TVS Motor Company — ' || v_pinv.purchase_invoice,
                           'party_type', 'SUPPLIER', 'party_id', v_tvs)
      ),
      'PURCHASE_INVOICE', null, 'demo-vpurchase:' || v_pinv.purchase_invoice || ':' || v_pinv.branch_id::text
    );
  end loop;

  -- ── Opening accessory and spare stock, by branch and source ─────────────
  -- LOCAL lots are bought locally, COMPANY lots come from the manufacturer, so
  -- the payable lands on the supplier who actually supplied them (spec §28).
  for v_lot in
    select t.branch_id, t.source, i.item_type, sum(t.quantity * t.unit_cost) as cost
      from public.inventory_transactions t
      join public.inventory_items i on i.id = t.item_id
     where t.dealer_id = v_dealer and t.transaction_type = 'OPENING'
     group by t.branch_id, t.source, i.item_type
     order by t.branch_id, t.source, i.item_type
  loop
    perform app.post_journal(
      v_dealer, v_lot.branch_id, date '2026-07-01', 'INVENTORY',
      'Opening stock — ' || lower(v_lot.item_type) || ' (' || lower(v_lot.source) || ')',
      jsonb_build_array(
        jsonb_build_object(
          'account_id', case when v_lot.item_type = 'ACCESSORY' then v_acc_inv else v_spr_inv end,
          'debit', v_lot.cost, 'credit', 0, 'narration', 'Stock on hand at 01-Jul-2026'),
        jsonb_build_object(
          'account_id', v_payable, 'debit', 0, 'credit', v_lot.cost,
          'narration', 'Opening purchase payable',
          'party_type', 'SUPPLIER',
          'party_id', case when v_lot.source = 'LOCAL' then v_local else v_tvs end)
      ),
      'PURCHASE_INVOICE', null,
      'demo-opening-stock:' || v_lot.branch_id::text || ':' || v_lot.source || ':' || v_lot.item_type
    );
  end loop;

  raise notice 'Opening: capital introduced, vehicle purchases and opening stock brought onto the ledger.';
end;
$$;

-- =============================================================================
-- 6 — Bookings and their advances (spec §18)
-- =============================================================================
do $$
declare
  v_dealer uuid;
  v_main uuid; v_north uuid;
  v_exec_main uuid; v_exec_north uuid;
  v_jup uuid; v_jup_v uuid; v_ntq uuid; v_ntq_v uuid; v_apa uuid; v_apa_v uuid;
  v_b record;
  v_ids uuid[];
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_main  from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_north from public.branches where dealer_id = v_dealer and code = 'NORTH';
  select id into v_exec_main  from public.employees where dealer_id = v_dealer and employee_code = 'EMP0004';
  select id into v_exec_north from public.employees where dealer_id = v_dealer and employee_code = 'EMP0007';
  select id into v_jup   from public.vehicle_models   where dealer_id = v_dealer and model_code = 'JUPITER110';
  select id into v_ntq   from public.vehicle_models   where dealer_id = v_dealer and model_code = 'NTORQ125';
  select id into v_apa   from public.vehicle_models   where dealer_id = v_dealer and model_code = 'APACHE160';
  select id into v_jup_v from public.vehicle_variants where dealer_id = v_dealer and variant_code = 'JUPITER110-SM';
  select id into v_ntq_v from public.vehicle_variants where dealer_id = v_dealer and variant_code = 'NTORQ125-RXP';
  select id into v_apa_v from public.vehicle_variants where dealer_id = v_dealer and variant_code = 'APACHE160-RE';

  -- Matched on the demo mobile range rather than taken as "the first eight
  -- customers": the sections below address these by position, and a dealer that
  -- already had a customer on file would shift every index by one.
  select array_agg(id order by customer_code) into v_ids
    from public.customers where dealer_id = v_dealer and mobile like '98401100%';

  -- Five bookings, deliberately mixed: two convert to sales below, one is
  -- cancelled and refunded, two stay open. Raised from two branches, which is
  -- the case that used to collide on document numbering before 0039.
  for v_b in
    select * from (values
      (1, 1,  98000::numeric, 10000::numeric, 'CASH'),   -- Ramesh   → converts
      (2, 2, 124000::numeric, 15000::numeric, 'UPI'),    -- Lakshmi  → converts
      (3, 3,  82000::numeric,  5000::numeric, 'CASH'),   -- Anitha   → cancelled, then refunded
      (4, 3,  82000::numeric,  7500::numeric, 'NEFT'),   -- Karthik  → stays open
      (5, 1,  98000::numeric,  8000::numeric, 'CASH')    -- Vijay    → stays open
    ) as t(cust_ix, model_ix, amount, advance, mode)
  loop
    perform public.create_booking_with_advance(
      p_customer_id     => v_ids[v_b.cust_ix],
      p_model_id        => case v_b.model_ix when 1 then v_ntq when 2 then v_apa else v_jup end,
      p_branch_id       => case when v_b.cust_ix % 2 = 1 then v_main else v_north end,
      p_booking_amount  => v_b.amount,
      p_advance_amount  => v_b.advance,
      p_payment_mode    => v_b.mode,
      p_variant_id      => case v_b.model_ix when 1 then v_ntq_v when 2 then v_apa_v else v_jup_v end,
      p_expected_delivery  => current_date + 10,
      p_sales_executive_id => case when v_b.cust_ix % 2 = 1 then v_exec_main else v_exec_north end,
      p_notes           => 'Demo booking'
    );
  end loop;

  -- Cancel the third. Spec §18: cancelling does not refund — a retained advance
  -- is a normal outcome, so the refund below is a separate, deliberate act.
  update public.bookings
     set status = 'CANCELLED',
         cancelled_reason = 'Customer chose a different model'
   where dealer_id = v_dealer
     and customer_id = v_ids[3]
     and status = 'OPEN';

  raise notice 'Bookings: 5 raised with advances, 1 cancelled.';
end;
$$;

-- =============================================================================
-- 7 — Vehicle sales, through to delivery (spec §19)
-- =============================================================================
-- DRAFT → SUBMITTED → ACCOUNTS_VERIFICATION → APPROVED → POSTED → DELIVERED.
-- The status transitions are plain updates because that is exactly what the
-- service layer does; posting, payment and delivery run through their real
-- functions, so stock, COGS, tax and the customer ledger all move.
do $$
declare
  v_dealer uuid;
  v_main uuid;
  v_exec uuid;
  v_fin_tvs uuid; v_fin_hdfc uuid;
  v_mat uuid; v_guard uuid; v_cover uuid;
  v_sale record;
  v_veh uuid;
  v_cust uuid;
  v_booking uuid;
  v_ids uuid[];
  v_total numeric;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_main from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_exec from public.employees where dealer_id = v_dealer and employee_code = 'EMP0004';
  select id into v_fin_tvs  from public.finance_companies where dealer_id = v_dealer and code = 'TVSCREDIT';
  select id into v_fin_hdfc from public.finance_companies where dealer_id = v_dealer and code = 'HDFCBANK';
  select id into v_mat   from public.inventory_items where dealer_id = v_dealer and item_code = 'AC-MAT-01';
  select id into v_guard from public.inventory_items where dealer_id = v_dealer and item_code = 'AC-GRD-01';
  select id into v_cover from public.inventory_items where dealer_id = v_dealer and item_code = 'AC-SEAT-01';
  select array_agg(id order by customer_code) into v_ids
    from public.customers where dealer_id = v_dealer and mobile like '98401100%';

  -- ── Sale 1: Ramesh, Ntorq, off his booking, part cash + part finance ─────
  v_cust := v_ids[1];
  select id into v_veh from public.vehicles
   where dealer_id = v_dealer and chassis_no = 'MD625NT12P2B00001';
  select id into v_booking from public.bookings
   where dealer_id = v_dealer and customer_id = v_cust and status = 'OPEN' limit 1;

  select * into v_sale from public.create_vehicle_sale_draft(
    p_customer_id => v_cust, p_vehicle_id => v_veh,
    p_invoice_date => current_date - 12, p_booking_id => v_booking,
    p_sales_executive_id => v_exec, p_discount => 2000,
    p_notes => 'Exchange of an older scooter agreed separately'
  );

  -- Extra fittings, allocated LOCAL before COMPANY (spec §31).
  perform public.consume_fitting_stock(v_sale.sale_id, v_mat,   1,  580);
  perform public.consume_fitting_stock(v_sale.sale_id, v_guard, 1, 1100);

  update public.sales set status = 'SUBMITTED'             where id = v_sale.sale_id;
  update public.sales set status = 'ACCOUNTS_VERIFICATION' where id = v_sale.sale_id;
  update public.sales set status = 'APPROVED'              where id = v_sale.sale_id;
  perform public.post_vehicle_sale(v_sale.sale_id);

  select total_amount into v_total from public.sales where id = v_sale.sale_id;
  perform public.record_sale_payment(v_sale.sale_id, 25000, 'CASH', 'Balance down payment');
  perform public.record_sale_payment(v_sale.sale_id, v_total - 25000 - 10000, 'FINANCE',
                                     'TVS Credit DD 774512', v_fin_tvs);
  perform public.deliver_vehicle(v_sale.sale_id, 'Ramesh Kumar', 4,
                                 'Delivered with both keys and the toolkit');
  update public.vehicles set registration_no = 'TN09BX4471' where id = v_veh;

  -- ── Sale 2: Lakshmi, Apache, off her booking, financed ──────────────────
  v_cust := v_ids[2];
  select id into v_veh from public.vehicles
   where dealer_id = v_dealer and chassis_no = 'MD634AP16P3C00001';
  select id into v_booking from public.bookings
   where dealer_id = v_dealer and customer_id = v_cust and status = 'OPEN' limit 1;

  select * into v_sale from public.create_vehicle_sale_draft(
    p_customer_id => v_cust, p_vehicle_id => v_veh,
    p_invoice_date => current_date - 8, p_booking_id => v_booking,
    p_sales_executive_id => v_exec, p_discount => 0, p_notes => null
  );
  perform public.consume_fitting_stock(v_sale.sale_id, v_cover, 1, 720);

  update public.sales set status = 'SUBMITTED'             where id = v_sale.sale_id;
  update public.sales set status = 'ACCOUNTS_VERIFICATION' where id = v_sale.sale_id;
  update public.sales set status = 'APPROVED'              where id = v_sale.sale_id;
  perform public.post_vehicle_sale(v_sale.sale_id);

  select total_amount into v_total from public.sales where id = v_sale.sale_id;
  perform public.record_sale_payment(v_sale.sale_id, v_total - 15000, 'FINANCE',
                                     'HDFC disbursement 88231', v_fin_hdfc);
  perform public.deliver_vehicle(v_sale.sale_id, 'Lakshmi Narayanan', 6, null);
  update public.vehicles set registration_no = 'TN09BX4488' where id = v_veh;

  -- ── Sale 3: Deepa, Jupiter, cash, no booking behind it ──────────────────
  v_cust := v_ids[6];
  select id into v_veh from public.vehicles
   where dealer_id = v_dealer and chassis_no = 'MD625JU10P1A00001';

  select * into v_sale from public.create_vehicle_sale_draft(
    p_customer_id => v_cust, p_vehicle_id => v_veh,
    p_invoice_date => current_date - 5, p_sales_executive_id => v_exec,
    p_discount => 1500, p_notes => 'Walk-in, cash sale'
  );
  perform public.consume_fitting_stock(v_sale.sale_id, v_mat, 1, 580);

  update public.sales set status = 'SUBMITTED'             where id = v_sale.sale_id;
  update public.sales set status = 'ACCOUNTS_VERIFICATION' where id = v_sale.sale_id;
  update public.sales set status = 'APPROVED'              where id = v_sale.sale_id;
  perform public.post_vehicle_sale(v_sale.sale_id);

  select total_amount into v_total from public.sales where id = v_sale.sale_id;
  perform public.record_sale_payment(v_sale.sale_id, v_total, 'UPI', 'UPI 428871003344');
  perform public.deliver_vehicle(v_sale.sale_id, 'Deepa Ravi', 3, null);
  update public.vehicles set registration_no = 'TN09BX4502' where id = v_veh;

  -- ── Sale 4: Meena Traders, Jupiter at NORTH, part paid, not delivered ───
  -- The delivery queue and the receivables report both need a live case.
  v_cust := v_ids[8];
  select id into v_veh from public.vehicles
   where dealer_id = v_dealer and chassis_no = 'MD625JU10P1A00005';

  select * into v_sale from public.create_vehicle_sale_draft(
    p_customer_id => v_cust, p_vehicle_id => v_veh,
    p_invoice_date => current_date - 2, p_sales_executive_id => v_exec,
    p_discount => 0, p_notes => 'Fleet purchase — registration pending'
  );
  update public.sales set status = 'SUBMITTED'             where id = v_sale.sale_id;
  update public.sales set status = 'ACCOUNTS_VERIFICATION' where id = v_sale.sale_id;
  update public.sales set status = 'APPROVED'              where id = v_sale.sale_id;
  perform public.post_vehicle_sale(v_sale.sale_id);
  perform public.record_sale_payment(v_sale.sale_id, 40000, 'RTGS', 'RTGS HDFC 9928311');

  -- ── Sale 5: Mohan, Ntorq, left awaiting accounts verification ───────────
  -- Spec §53 describes a verification screen; it needs something in its queue.
  v_cust := v_ids[7];
  select id into v_veh from public.vehicles
   where dealer_id = v_dealer and chassis_no = 'MD625NT12P2B00002';

  select * into v_sale from public.create_vehicle_sale_draft(
    p_customer_id => v_cust, p_vehicle_id => v_veh,
    p_invoice_date => current_date, p_sales_executive_id => v_exec,
    p_discount => 3000, p_notes => 'Discount above policy — needs a second look'
  );
  update public.sales set status = 'SUBMITTED'             where id = v_sale.sale_id;
  update public.sales set status = 'ACCOUNTS_VERIFICATION' where id = v_sale.sale_id;

  raise notice 'Sales: 3 delivered, 1 posted awaiting delivery, 1 in accounts verification.';
end;
$$;

-- =============================================================================
-- 8 — Booking refund (spec §18 — deliberate, never automatic on cancellation)
-- =============================================================================
do $$
declare
  v_dealer  uuid;
  v_booking uuid;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_booking from public.bookings
   where dealer_id = v_dealer and status = 'CANCELLED' limit 1;

  if v_booking is not null then
    -- Dated a week back, ahead of every other cash movement this script makes.
    -- cash_transactions.balance_after is a running total fixed at insert time, so
    -- rows must be written in date order or the cash book's running balance jumps
    -- about. Real use enters cash as it happens; a seed has to be careful.
    perform public.refund_booking_advance(
      p_booking_id => v_booking, p_amount => 5000, p_mode => 'CASH',
      p_reason => 'Customer chose a different model — advance returned in full',
      p_date => current_date - 7
    );
    raise notice 'Bookings: 1 advance refunded.';
  end if;
end;
$$;

-- =============================================================================
-- 9 — Service (spec §32)
-- =============================================================================
do $$
declare
  v_dealer uuid;
  v_main uuid; v_north uuid;
  v_advisor uuid; v_tech uuid;
  v_oil uuid; v_brake uuid; v_filter uuid; v_plug uuid;
  v_ids uuid[];
  v_jc record;
  v_inv record;
  v_total numeric;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_main  from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_north from public.branches where dealer_id = v_dealer and code = 'NORTH';
  select id into v_advisor from public.employees where dealer_id = v_dealer and employee_code = 'EMP0005';
  select id into v_tech    from public.employees where dealer_id = v_dealer and employee_code = 'EMP0006';
  select id into v_oil    from public.inventory_items where dealer_id = v_dealer and item_code = 'SP-OIL-01';
  select id into v_brake  from public.inventory_items where dealer_id = v_dealer and item_code = 'SP-BRK-01';
  select id into v_filter from public.inventory_items where dealer_id = v_dealer and item_code = 'SP-FLT-01';
  select id into v_plug   from public.inventory_items where dealer_id = v_dealer and item_code = 'SP-PLG-01';
  select array_agg(id order by customer_code) into v_ids
    from public.customers where dealer_id = v_dealer and mobile like '98401100%';

  -- ── Job 1: Ramesh, first free service on the unit he just bought ────────
  -- The registration matches the vehicle delivered above, so this links to his
  -- existing customer_vehicles row rather than creating a second one.
  select * into v_jc from public.create_job_card(
    p_branch_id => v_main, p_customer_id => v_ids[1], p_service_type => 'FREE',
    p_registration_no => 'TN09BX4471', p_odometer => 512,
    p_complaint => 'First free service', p_service_advisor_id => v_advisor,
    p_technician_id => v_tech, p_job_date => current_date - 3
  );
  select * into v_inv from public.create_service_invoice(v_jc.job_card_id, current_date - 3);
  perform public.add_service_line(v_inv.invoice_id, 'LABOUR', 'First free service labour', 1, 0, null, 'GST18L');
  perform public.add_service_line(v_inv.invoice_id, 'SPARE',  'Engine oil 1L', 1, 480, v_oil, 'GST18');
  perform public.post_service_invoice(v_inv.invoice_id);
  select total_amount into v_total from public.service_invoices where id = v_inv.invoice_id;
  perform public.record_service_payment(v_inv.invoice_id, v_total, 'CASH', null, current_date - 3);

  -- ── Job 2: Lakshmi, paid service, labour and several spares ─────────────
  select * into v_jc from public.create_job_card(
    p_branch_id => v_main, p_customer_id => v_ids[2], p_service_type => 'PAID',
    p_registration_no => 'TN09BX4488', p_odometer => 2140,
    p_complaint => 'Brake noise and rough idling', p_service_advisor_id => v_advisor,
    p_technician_id => v_tech, p_job_date => current_date - 1
  );
  select * into v_inv from public.create_service_invoice(v_jc.job_card_id, current_date - 1);
  perform public.add_service_line(v_inv.invoice_id, 'LABOUR', 'General service labour', 1, 650, null,     'GST18L');
  perform public.add_service_line(v_inv.invoice_id, 'LABOUR', 'Brake overhaul',         1, 350, null,     'GST18L');
  perform public.add_service_line(v_inv.invoice_id, 'SPARE',  'Brake shoe set',         1, 420, v_brake,  'GST18');
  perform public.add_service_line(v_inv.invoice_id, 'SPARE',  'Air filter',             1, 330, v_filter, 'GST18');
  perform public.add_service_line(v_inv.invoice_id, 'SPARE',  'Spark plug',             1, 190, v_plug,   'GST18');
  perform public.post_service_invoice(v_inv.invoice_id);
  select total_amount into v_total from public.service_invoices where id = v_inv.invoice_id;
  perform public.record_service_payment(v_inv.invoice_id, v_total, 'UPI', 'UPI 552310099881', current_date - 1);

  -- ── Job 3: a walk-in the dealer never sold to ───────────────────────────
  -- No customer_vehicles row exists for this registration, so the job card
  -- creates one — the second of the two writers added in 0045.
  select * into v_jc from public.create_job_card(
    p_branch_id => v_north, p_customer_id => v_ids[4], p_service_type => 'PAID',
    p_registration_no => 'TN10AC9021', p_odometer => 18450,
    p_complaint => 'Oil change and general check', p_service_advisor_id => v_advisor,
    p_job_date => current_date - 6
  );
  select * into v_inv from public.create_service_invoice(v_jc.job_card_id, current_date - 6);
  perform public.add_service_line(v_inv.invoice_id, 'LABOUR', 'General service labour', 1, 550, null,  'GST18L');
  perform public.add_service_line(v_inv.invoice_id, 'SPARE',  'Engine oil 1L',          1, 480, v_oil, 'GST18');
  perform public.post_service_invoice(v_inv.invoice_id);
  -- Part paid on the day, so service receivables are not uniformly nil.
  perform public.record_service_payment(v_inv.invoice_id, 500, 'CASH', null, current_date - 6);

  -- ── Job 4: still open on the floor, no invoice yet ──────────────────────
  perform public.create_job_card(
    p_branch_id => v_main, p_customer_id => v_ids[3], p_service_type => 'PAID',
    p_registration_no => 'TN09AB1122', p_odometer => 7300,
    p_complaint => 'Starting trouble in the morning', p_service_advisor_id => v_advisor,
    p_technician_id => v_tech, p_promised_at => now() + interval '6 hours',
    p_job_date => current_date
  );

  raise notice 'Service: 4 job cards, 3 invoices posted, 1 open on the floor.';
end;
$$;

-- =============================================================================
-- 10 — Counter sales (spec §33)
-- =============================================================================
-- A counter invoice is a service invoice with no job card behind it, so it uses
-- the same line, posting and payment functions.
do $$
declare
  v_dealer uuid;
  v_main uuid; v_south uuid;
  v_helmet uuid; v_oil uuid; v_plug uuid; v_mat uuid;
  v_ids uuid[];
  v_inv record;
  v_total numeric;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_main  from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_south from public.branches where dealer_id = v_dealer and code = 'SOUTH';
  select id into v_helmet from public.inventory_items where dealer_id = v_dealer and item_code = 'AC-HELM-01';
  select id into v_oil    from public.inventory_items where dealer_id = v_dealer and item_code = 'SP-OIL-01';
  select id into v_plug   from public.inventory_items where dealer_id = v_dealer and item_code = 'SP-PLG-01';
  select id into v_mat    from public.inventory_items where dealer_id = v_dealer and item_code = 'AC-MAT-01';
  select array_agg(id order by customer_code) into v_ids
    from public.customers where dealer_id = v_dealer and mobile like '98401100%';

  -- Named customer, accessories.
  select * into v_inv from public.create_counter_invoice(v_main, v_ids[5], current_date - 4);
  perform public.add_service_line(v_inv.invoice_id, 'ACCESSORY', 'Full face helmet', 2, 1450, v_helmet, 'GST18');
  perform public.add_service_line(v_inv.invoice_id, 'ACCESSORY', 'Floor mat',        1,  580, v_mat,    'GST18');
  perform public.post_service_invoice(v_inv.invoice_id);
  select total_amount into v_total from public.service_invoices where id = v_inv.invoice_id;
  perform public.record_service_payment(v_inv.invoice_id, v_total, 'CARD', 'Card 4411', current_date - 4);

  -- Walk-in with nobody on file — allowed, because counter_sale.require_customer
  -- is false for this dealer.
  select * into v_inv from public.create_counter_invoice(v_main, null, current_date - 1);
  perform public.add_service_line(v_inv.invoice_id, 'SPARE', 'Engine oil 1L', 2, 480, v_oil,  'GST18');
  perform public.add_service_line(v_inv.invoice_id, 'SPARE', 'Spark plug',    2, 190, v_plug, 'GST18');
  perform public.post_service_invoice(v_inv.invoice_id);
  select total_amount into v_total from public.service_invoices where id = v_inv.invoice_id;
  perform public.record_service_payment(v_inv.invoice_id, v_total, 'CASH', null, current_date - 1);

  -- A third at another branch, so counter revenue is not all in one place.
  select * into v_inv from public.create_counter_invoice(v_south, v_ids[3], current_date);
  perform public.add_service_line(v_inv.invoice_id, 'ACCESSORY', 'Full face helmet', 1, 1450, v_helmet, 'GST18');
  perform public.post_service_invoice(v_inv.invoice_id);
  select total_amount into v_total from public.service_invoices where id = v_inv.invoice_id;
  perform public.record_service_payment(v_inv.invoice_id, v_total, 'UPI', 'UPI 771120054412', current_date);

  raise notice 'Counter sales: 3 invoices posted and paid.';
end;
$$;

-- =============================================================================
-- 11 — Finance: applications, trade advances, settlement (spec §25, §26, §27)
-- =============================================================================
do $$
declare
  v_dealer uuid;
  v_main uuid; v_north uuid;
  v_bank uuid;
  v_tvs uuid; v_hdfc uuid; v_chola uuid;
  v_ids uuid[];
  v_app record;
  v_set record;
  v_veh uuid;
  v_sale uuid;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_main  from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_north from public.branches where dealer_id = v_dealer and code = 'NORTH';
  select id into v_bank from public.bank_accounts
   where dealer_id = v_dealer and name like '%— Current A/c' limit 1;
  select id into v_tvs   from public.finance_companies where dealer_id = v_dealer and code = 'TVSCREDIT';
  select id into v_hdfc  from public.finance_companies where dealer_id = v_dealer and code = 'HDFCBANK';
  select id into v_chola from public.finance_companies where dealer_id = v_dealer and code = 'CHOLA';
  select array_agg(id order by customer_code) into v_ids
    from public.customers where dealer_id = v_dealer and mobile like '98401100%';

  -- ── Application 1: approved and fully disbursed, tied to Ramesh's sale ──
  select v.id, v.sale_id into v_veh, v_sale from public.vehicles v
   where v.dealer_id = v_dealer and v.chassis_no = 'MD625NT12P2B00001';

  select * into v_app from public.create_finance_application(
    p_branch_id => v_main, p_customer_id => v_ids[1], p_finance_company_id => v_tvs,
    p_loan_amount => 85000, p_down_payment => 35000, p_vehicle_id => v_veh, p_sale_id => v_sale,
    p_tenure_months => 24::smallint, p_interest_rate => 11.5, p_commission_amount => 2125,
    p_application_date => current_date - 14, p_notes => 'Salaried, documents complete'
  );
  perform public.decide_finance_application(v_app.application_id, 'APPROVED', 85000);
  perform public.disburse_finance_application(
    v_app.application_id, 85000, v_bank, 'DD 774512', 'TVSCR/2026/44821', current_date - 10
  );

  -- ── Application 2: approved, only part disbursed → PARTIAL ─────────────
  select v.id, v.sale_id into v_veh, v_sale from public.vehicles v
   where v.dealer_id = v_dealer and v.chassis_no = 'MD634AP16P3C00001';

  select * into v_app from public.create_finance_application(
    p_branch_id => v_main, p_customer_id => v_ids[2], p_finance_company_id => v_hdfc,
    p_loan_amount => 130000, p_down_payment => 15000, p_vehicle_id => v_veh, p_sale_id => v_sale,
    p_tenure_months => 36::smallint, p_interest_rate => 10.75, p_commission_amount => 2600,
    p_application_date => current_date - 11, p_notes => null
  );
  perform public.decide_finance_application(v_app.application_id, 'APPROVED', 128000);
  perform public.disburse_finance_application(
    v_app.application_id, 90000, v_bank, null, 'HDFC/DISB/88231', current_date - 7
  );

  -- ── Application 3: still awaiting a decision ───────────────────────────
  perform public.create_finance_application(
    p_branch_id => v_north, p_customer_id => v_ids[8], p_finance_company_id => v_chola,
    p_loan_amount => 78000, p_down_payment => 12000,
    p_tenure_months => 24::smallint, p_interest_rate => 12.25, p_commission_amount => 1950,
    p_application_date => current_date - 1, p_notes => 'Awaiting income proof'
  );

  -- ── Application 4: rejected ────────────────────────────────────────────
  select * into v_app from public.create_finance_application(
    p_branch_id => v_main, p_customer_id => v_ids[7], p_finance_company_id => v_tvs,
    p_loan_amount => 95000, p_down_payment => 5000,
    p_tenure_months => 36::smallint, p_interest_rate => 11.9, p_commission_amount => 0,
    p_application_date => current_date - 4, p_notes => null
  );
  perform public.decide_finance_application(
    v_app.application_id, 'REJECTED', null, 'CIBIL score below the company threshold'
  );

  -- ── Trade advances (spec §26) ──────────────────────────────────────────
  perform public.record_trade_advance(v_tvs,   v_main,  'ADVANCE_RECEIVED', 300000, v_bank,
    current_date - 20, 'Monthly trade advance', 'TVSCR/ADV/0826');
  perform public.record_trade_advance(v_hdfc,  v_main,  'ADVANCE_RECEIVED', 200000, v_bank,
    current_date - 18, 'Trade advance', 'HDFC/ADV/0826');
  perform public.record_trade_advance(v_chola, v_north, 'ADVANCE_RECEIVED', 150000, v_bank,
    current_date - 15, 'Opening trade advance', 'CHOLA/ADV/0826');
  perform public.record_trade_advance(v_tvs,   v_main,  'COMMISSION', 2125, null,
    current_date - 9, 'Commission on TN09BX4471', null);
  perform public.record_trade_advance(v_tvs,   v_main,  'REFUND', 50000, v_bank,
    current_date - 3, 'Unutilised advance returned', 'TVSCR/REF/0926');

  -- ── Settlement (spec §26) ──────────────────────────────────────────────
  select * into v_set from public.create_finance_settlement(
    p_finance_company_id => v_hdfc, p_branch_id => v_main,
    p_from => (date_trunc('month', current_date) - interval '1 month')::date,
    p_to   => (date_trunc('month', current_date) - interval '1 day')::date,
    p_gross => 90000, p_commission => 2600, p_deductions => 1200,
    p_settlement_date => current_date - 2, p_notes => 'Previous month disbursements settled'
  );
  perform public.post_finance_settlement(v_set.settlement_id, v_bank);

  raise notice 'Finance: 4 applications (1 disbursed, 1 partial, 1 pending, 1 rejected), 5 trade advances, 1 settlement.';
end;
$$;

-- =============================================================================
-- 12 — Cash and bank movements (spec §36, §38)
-- =============================================================================
-- Everyday running costs, so the cash book, bank book and P&L carry expenses
-- rather than only sales. Two supplier payments exercise the supplier ledger,
-- which had no writer at all before 0041.
do $$
declare
  v_dealer uuid;
  v_main uuid; v_north uuid;
  v_bank uuid;
  v_rent uuid; v_util uuid; v_sal uuid; v_other uuid; v_charges uuid; v_payable uuid;
  v_supp_lub uuid; v_supp_log uuid;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_main  from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_north from public.branches where dealer_id = v_dealer and code = 'NORTH';
  select id into v_bank from public.bank_accounts
   where dealer_id = v_dealer and name like '%— Current A/c' limit 1;

  select id into v_rent    from public.chart_of_accounts where dealer_id = v_dealer and code = '5600';
  select id into v_util    from public.chart_of_accounts where dealer_id = v_dealer and code = '5700';
  select id into v_sal     from public.chart_of_accounts where dealer_id = v_dealer and code = '5500';
  select id into v_charges from public.chart_of_accounts where dealer_id = v_dealer and code = '5800';
  select id into v_other   from public.chart_of_accounts where dealer_id = v_dealer and code = '5900';
  select id into v_payable from public.chart_of_accounts where dealer_id = v_dealer and code = '2200';

  select id into v_supp_lub from public.suppliers where dealer_id = v_dealer and name = 'Chennai Lubricants';
  select id into v_supp_log from public.suppliers where dealer_id = v_dealer and name = 'Southern Logistics';

  -- Petty cash out of the branch tills. Most of it lands on yesterday, which is
  -- the day closed in section 13 — a day-close over an empty day proves nothing.
  perform public.record_cash_transaction(v_main,  'PAYMENT', 1200, 'Courier and stationery',        v_other, null, null, current_date - 6);
  perform public.record_cash_transaction(v_main,  'PAYMENT', 3400, 'Electricity — August',          v_util,  null, 'TNEB 4471', current_date - 1);
  perform public.record_cash_transaction(v_main,  'RECEIPT', 2500, 'Scrap sale — packing material', v_other, null, null, current_date - 1);
  perform public.record_cash_transaction(v_north, 'PAYMENT',  850, 'Workshop consumables',          v_other, null, null, current_date - 1);
  -- And one on today, so the open day is not empty either.
  perform public.record_cash_transaction(v_main,  'PAYMENT',  600, 'Fuel for the demo vehicle',     v_other, null, null, current_date);

  -- Suppliers settled from the bank: the payable side of the ledger.
  perform public.record_bank_transaction(
    p_bank_account_id => v_bank, p_direction => 'PAYMENT', p_amount => 48500,
    p_particular => 'Lubricants purchase — invoice CL/2026/338', p_account_id => v_payable,
    p_date => current_date - 5, p_reference => 'NEFT 88213', p_utr => 'HDFCN26240800113',
    p_supplier_id => v_supp_lub
  );
  perform public.record_bank_transaction(
    p_bank_account_id => v_bank, p_direction => 'PAYMENT', p_amount => 16750,
    p_particular => 'Vehicle forwarding charges — August', p_account_id => v_payable,
    p_date => current_date - 2, p_reference => 'NEFT 88402', p_utr => 'HDFCN26240800229',
    p_supplier_id => v_supp_log
  );

  -- Standing costs.
  perform public.record_bank_transaction(
    p_bank_account_id => v_bank, p_direction => 'PAYMENT', p_amount => 42000,
    p_particular => 'Showroom rent — September', p_account_id => v_rent,
    p_date => current_date - 1, p_reference => 'NEFT 88455'
  );
  perform public.record_bank_transaction(
    p_bank_account_id => v_bank, p_direction => 'PAYMENT', p_amount => 78000,
    p_particular => 'Salaries — August', p_account_id => v_sal,
    p_date => current_date - 1, p_reference => 'SAL/AUG/2026'
  );
  perform public.record_bank_transaction(
    p_bank_account_id => v_bank, p_direction => 'PAYMENT', p_amount => 1180,
    p_particular => 'Bank charges and GST', p_account_id => v_charges,
    p_date => current_date - 1, p_reference => null
  );

  raise notice 'Cash and bank: 5 cash movements, 5 bank movements, 2 of them to suppliers.';
end;
$$;

-- =============================================================================
-- 13 — Close yesterday's cash day (spec §36)
-- =============================================================================
-- Yesterday is closed with a small counting difference on one branch, which is
-- what actually happens and what the difference column exists to show. Today is
-- left open, so the day-close screen has something to do.
do $$
declare
  v_dealer uuid;
  v_branch record;
  v_expected numeric;
  v_physical numeric;
  v_left     bigint;
  v_note     int;
  v_notes    jsonb;
begin
  select id into v_dealer from public.dealers where code = 'SBM';

  for v_branch in select id, code from public.branches where dealer_id = v_dealer order by code loop
    perform public.ensure_cash_day(v_branch.id, current_date - 1);

    select expected_closing into v_expected
      from public.cash_day_closings
     where branch_id = v_branch.id and business_date = current_date - 1;

    -- MAIN counts fifty rupees short. A day that always tallies exactly teaches
    -- nobody what the difference column is for.
    v_physical := v_expected + case when v_branch.code = 'MAIN' then -50 else 0 end;

    -- The denomination breakdown a cashier would actually record: largest note
    -- first, down to the last rupee.
    v_notes := '{}'::jsonb;
    v_left  := floor(v_physical)::bigint;
    foreach v_note in array array[500, 200, 100, 50, 20, 10, 5, 2, 1] loop
      if v_left >= v_note then
        v_notes := v_notes || jsonb_build_object(v_note::text, v_left / v_note);
        v_left  := v_left % v_note;
      end if;
    end loop;

    perform public.close_cash_day(
      p_branch_id     => v_branch.id,
      p_date          => current_date - 1,
      p_physical_cash => v_physical,
      p_denominations => v_notes,
      p_remarks       => case when v_branch.code = 'MAIN'
                              then 'Fifty rupees short — under review'
                         end
    );
  end loop;

  raise notice 'Cash book: yesterday counted and closed on all 3 branches.';
end;
$$;

-- =============================================================================
-- 14 — Prove the ledger balances
-- =============================================================================
-- The point of driving the real functions rather than inserting rows: if any of
-- it were wrong, this would not come out even.
do $$
declare
  v_dealer uuid;
  v_dr numeric;
  v_cr numeric;
begin
  select id into v_dealer from public.dealers where code = 'SBM';

  select coalesce(sum(l.debit), 0), coalesce(sum(l.credit), 0)
    into v_dr, v_cr
    from public.journal_entry_lines l
    join public.journal_entries e on e.id = l.journal_entry_id
   where e.dealer_id = v_dealer and e.status = 'POSTED';

  if v_dr <> v_cr then
    raise exception 'Ledger does not balance: debits % vs credits %.', v_dr, v_cr;
  end if;

  raise notice '';
  raise notice 'Demo data loaded for dealer SBM. Posted journals: % Dr = % Cr.',
    to_char(v_dr, 'FM99,99,99,999.00'), to_char(v_cr, 'FM99,99,99,999.00');
  raise notice 'Remove it with: psql "$DATABASE_URL" -f scripts/remove-demo-dealer.sql';
end;
$$;
