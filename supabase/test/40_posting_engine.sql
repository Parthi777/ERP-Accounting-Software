-- =============================================================================
-- TEST — the posting engine, end to end
-- =============================================================================
-- Builds a real vehicle sale from catalogue to posted journal and asserts every
-- guarantee spec §48 asks for: atomicity, LOCAL-before-COMPANY allocation, COGS,
-- stock relief, vehicle status, idempotency, and that the books still balance.
-- =============================================================================

\echo '--- posting engine ---'

do $$
declare
  v_dealer   uuid;
  v_branch   uuid;
  v_customer uuid;
  v_model    uuid;
  v_variant  uuid;
  v_vehicle  uuid;
  v_item     uuid;
  v_sale     uuid;
  v_entry    uuid;
  v_entry2   uuid;
  v_hsn      uuid;
  v_invoice  text;
  v_debit    numeric;
  v_credit   numeric;
  v_local    numeric;
  v_company  numeric;
  v_lines    int;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'MAIN';

  -- This test owns its own customer. Depending on one left behind by an earlier
  -- test file would couple the two and break whenever their order changed.
  insert into public.customers (dealer_id, name, mobile, city, state, state_code)
  values (v_dealer, 'Posting Engine Test Customer', '9840099001', 'Chennai', 'Tamil Nadu', '33')
  returning id into v_customer;

  -- ── Catalogue ─────────────────────────────────────────────────────────────
  insert into public.hsn_codes (dealer_id, code, description)
  values (v_dealer, '87112019', 'Motorcycles up to 125cc')
  returning id into v_hsn;

  insert into public.tax_codes (dealer_id, code, name, hsn_code_id,
                                cgst_rate, sgst_rate, igst_rate, effective_from, status)
  values (v_dealer, 'GST28', 'GST 28%', v_hsn, 14, 14, 28, date '2026-04-01', 'ACTIVE');

  perform app_test.assert_equals(
    (select total_rate from public.tax_codes where code = 'GST28'), 28.000::numeric(6,3),
    'tax total_rate is generated from its components'
  );

  perform app_test.assert_equals(
    (select cgst_rate from public.resolve_tax_code(v_dealer, 'GST28', date '2026-08-15')), 14.000::numeric(6,3),
    'resolve_tax_code returns the rate in force on a date'
  );
  perform app_test.assert_equals(
    (select count(*)::int from public.resolve_tax_code(v_dealer, 'GST28', date '2026-01-01')), 0,
    'a date before effective_from resolves to no rate'
  );

  insert into public.vehicle_models (dealer_id, brand, name, model_code, category, hsn_code_id, tax_code)
  values (v_dealer, 'TVS', 'Jupiter 110', 'JUP110', 'SCOOTER', v_hsn, 'GST28')
  returning id into v_model;

  insert into public.vehicle_variants (dealer_id, model_id, name, variant_code, engine_cc)
  values (v_dealer, v_model, 'Drum', 'JUP110-DRM', 109.7)
  returning id into v_variant;

  -- ── Pricing (spec §15) ────────────────────────────────────────────────────
  insert into public.vehicle_price_versions
    (dealer_id, model_id, variant_id, version_number, ex_showroom, insurance, registration,
     forwarding_charge, purchase_cost, effective_from, status, approved_at, tax_code)
  values
    (v_dealer, v_model, v_variant, 1, 75000, 6000, 8000, 1500, 62000,
     date '2026-04-01', 'ACTIVE', now(), 'GST28');

  perform app_test.assert_equals(
    (select total_on_road from public.resolve_vehicle_price(v_dealer, v_model, v_variant, v_branch, date '2026-08-15')),
    90500.0000::numeric(18,4),
    'resolve_vehicle_price returns the on-road total for the date'
  );

  -- A second, later version supersedes the first but must not rewrite it.
  update public.vehicle_price_versions set status = 'SUPERSEDED', effective_to = date '2026-08-31'
   where model_id = v_model and version_number = 1;

  insert into public.vehicle_price_versions
    (dealer_id, model_id, variant_id, version_number, ex_showroom, insurance, registration,
     forwarding_charge, purchase_cost, effective_from, status, approved_at, tax_code)
  values
    (v_dealer, v_model, v_variant, 2, 78000, 6000, 8000, 1500, 64000,
     date '2026-09-01', 'ACTIVE', now(), 'GST28');

  perform app_test.assert_equals(
    (select ex_showroom from public.resolve_vehicle_price(v_dealer, v_model, v_variant, v_branch, date '2026-08-15')),
    75000.0000::numeric(18,4),
    'a sale dated in August still resolves the August price, not the September one'
  );
  perform app_test.assert_equals(
    (select ex_showroom from public.resolve_vehicle_price(v_dealer, v_model, v_variant, v_branch, date '2026-09-15')),
    78000.0000::numeric(18,4),
    'a September sale resolves the new price'
  );

  perform app_test.assert_raises(
    format('update public.vehicle_price_versions set ex_showroom = 1 where model_id = %L and version_number = 1', v_model),
    'a superseded price version cannot be edited (spec §60.9)'
  );

  -- ── Vehicle stock (spec §13) ──────────────────────────────────────────────
  insert into public.vehicles
    (dealer_id, branch_id, model_id, variant_id, chassis_no, engine_no, purchase_cost, purchase_date)
  values (v_dealer, v_branch, v_model, v_variant, 'MD625KF12N1A00001', 'KF1AN1000001', 62000, date '2026-07-01')
  returning id into v_vehicle;

  perform app_test.assert_equals(
    (select status from public.vehicles where id = v_vehicle), 'IN_STOCK',
    'a vehicle enters stock as IN_STOCK'
  );
  perform app_test.assert_equals(
    (select count(*)::int from public.vehicle_stock_transactions where vehicle_id = v_vehicle), 1,
    'entering stock writes a movement row automatically'
  );

  perform app_test.assert_raises(
    format('update public.vehicles set status = ''DELIVERED'' where id = %L', v_vehicle),
    'a vehicle cannot jump straight from IN_STOCK to DELIVERED'
  );

  perform app_test.assert_raises(
    format($f$insert into public.vehicles (dealer_id, branch_id, model_id, chassis_no, engine_no)
             values (%L, %L, %L, 'MD625KF12N1A00001', 'KF1AN1000999')$f$, v_dealer, v_branch, v_model),
    'a duplicate chassis number is rejected (spec §14)'
  );

  -- ── Accessory stock, both sources (spec §28) ──────────────────────────────
  insert into public.inventory_items (dealer_id, item_code, name, item_type, is_fitment, selling_price)
  values (v_dealer, 'ACC-FLOORMAT', 'Floor Mat', 'ACCESSORY', true, 450)
  returning id into v_item;

  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost)
  values (v_dealer, v_branch, v_item, 'LOCAL', 'OPENING', 2, 300);

  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost)
  values (v_dealer, v_branch, v_item, 'COMPANY', 'OPENING', 10, 320);

  perform app_test.assert_equals(
    (select quantity from public.inventory_stock where item_id = v_item and source = 'LOCAL'), 2.000::numeric(14,3),
    'LOCAL stock is tracked separately'
  );
  perform app_test.assert_equals(
    (select quantity from public.inventory_stock where item_id = v_item and source = 'COMPANY'), 10.000::numeric(14,3),
    'COMPANY stock is tracked separately (spec §60.16)'
  );

  -- Spec §31's worked example: need 3, local 2, company 10 → 2 local + 1 company.
  perform app_test.assert_equals(
    (select quantity from public.allocate_stock(v_item, v_branch, 3) where source = 'LOCAL'), 2::numeric,
    'allocation takes all 2 LOCAL first (spec §31)'
  );
  perform app_test.assert_equals(
    (select quantity from public.allocate_stock(v_item, v_branch, 3) where source = 'COMPANY'), 1::numeric,
    'allocation takes the remaining 1 from COMPANY'
  );
  perform app_test.assert_equals(
    (select count(*)::int from public.allocate_stock(v_item, v_branch, 99) where source = 'SHORTFALL'), 1,
    'an impossible quantity reports a SHORTFALL rather than over-allocating'
  );

  perform app_test.assert_raises(
    format($f$insert into public.inventory_transactions
             (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost)
             values (%L, %L, %L, 'LOCAL', 'SALE', -50, 300)$f$, v_dealer, v_branch, v_item),
    'stock cannot go negative (spec §33)'
  );

  -- ── Accounting rules (spec §22) ───────────────────────────────────────────
  -- These now arrive from the seed via app.seed_default_accounting_rules(), so
  -- this asserts the mapping exists rather than creating it — inserting here
  -- would collide with the seeded rule and, worse, would mean the test proved
  -- nothing about the defaults a real dealer actually gets.
  perform app_test.assert_equals(
    public.resolve_account(v_dealer, 'SALES', 'INVOICE', 'CGST', v_branch) is not null, true,
    'accounting rules resolve an account without hard-coding an id (spec §22)'
  );
  perform app_test.assert_equals(
    (select count(*)::int from (values ('RECEIVABLE'),('VEHICLE'),('FITTING'),('INSURANCE'),
                                      ('REGISTRATION'),('FORWARDING'),('CGST'),('SGST'),
                                      ('COGS'),('INVENTORY')) as c(component)
      where public.resolve_account(v_dealer, 'SALES', 'INVOICE', c.component, v_branch) is null), 0,
    'every component a vehicle sale posts has a default mapping'
  );

  -- ── Build the sale ────────────────────────────────────────────────────────
  v_invoice := app.next_document_number(v_dealer, v_branch, 'VEHICLE_INVOICE', '2026');

  insert into public.sales
    (dealer_id, branch_id, invoice_number, invoice_date, customer_id, vehicle_id, price_version_id)
  select v_dealer, v_branch, v_invoice, date '2026-08-15', v_customer, v_vehicle,
         (select price_version_id from public.resolve_vehicle_price(v_dealer, v_model, v_variant, v_branch, date '2026-08-15'))
  returning id into v_sale;

  insert into public.sale_lines
    (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
     taxable_value, cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount,
     unit_cost, cost_amount)
  values
    (v_sale, v_dealer, 1, 'VEHICLE', 'TVS Jupiter 110 Drum', 1, 75000,
     75000, 14, 14, 10500, 10500, 96000, 62000, 62000),
    (v_sale, v_dealer, 2, 'INSURANCE', 'Insurance', 1, 6000, 6000, 0, 0, 0, 0, 6000, 0, 0),
    (v_sale, v_dealer, 3, 'REGISTRATION', 'LTRT', 1, 8000, 8000, 0, 0, 0, 0, 8000, 0, 0),
    (v_sale, v_dealer, 4, 'FORWARDING', 'Forwarding', 1, 1500, 1500, 0, 0, 0, 0, 1500, 0, 0);

  perform app_test.assert_equals(
    (select taxable_value from public.sales where id = v_sale), 90500.0000::numeric(18,4),
    'invoice totals are derived from the lines'
  );

  -- ── Fittings: allocation is recorded per source (spec §31) ────────────────
  perform public.consume_fitting_stock(v_sale, v_item, 3, 450);

  perform app_test.assert_equals(
    (select count(*)::int from public.sale_lines where sale_id = v_sale and line_type = 'FITTING'), 2,
    'a split allocation produces one invoice line per source, not one merged line'
  );
  perform app_test.assert_equals(
    (select stock_source from public.sale_lines
      where sale_id = v_sale and line_type = 'FITTING' order by line_number limit 1), 'LOCAL',
    'the first fitting line names LOCAL as its source (spec §31: never hide the source)'
  );

  select quantity into v_local   from public.inventory_stock where item_id = v_item and source = 'LOCAL';
  select quantity into v_company from public.inventory_stock where item_id = v_item and source = 'COMPANY';
  perform app_test.assert_equals(v_local,   0.000::numeric(14,3), 'LOCAL stock is exhausted first');
  perform app_test.assert_equals(v_company, 9.000::numeric(14,3), 'COMPANY stock supplies only the shortfall');

  -- ── Posting requires approval (spec §19) ──────────────────────────────────
  perform app_test.assert_raises(
    format('select public.post_vehicle_sale(%L)', v_sale),
    'a DRAFT sale cannot be posted'
  );

  update public.sales set status = 'SUBMITTED'             where id = v_sale;
  update public.sales set status = 'ACCOUNTS_VERIFICATION' where id = v_sale;
  update public.sales set status = 'APPROVED', approved_at = now() where id = v_sale;

  v_entry := public.post_vehicle_sale(v_sale);

  perform app_test.assert_equals(
    (select status from public.sales where id = v_sale), 'POSTED',
    'the sale is POSTED after the engine runs'
  );
  perform app_test.assert_equals(
    (select status from public.vehicles where id = v_vehicle), 'SOLD_PENDING_DELIVERY',
    'the vehicle status moves with the sale (spec §48 step 12)'
  );
  perform app_test.assert_equals(
    (select status from public.journal_entries where id = v_entry), 'POSTED',
    'the journal is posted'
  );

  select sum(debit), sum(credit), count(*) into v_debit, v_credit, v_lines
    from public.journal_entry_lines where journal_entry_id = v_entry;

  perform app_test.assert_equals(v_debit, v_credit, 'the sale journal balances (spec §22)');
  perform app_test.assert_equals(v_lines > 4, true, 'the journal has revenue, tax and COGS lines');

  perform app_test.assert_equals(
    (select sum(l.debit) from public.journal_entry_lines l
      join public.chart_of_accounts c on c.id = l.account_id
     where l.journal_entry_id = v_entry and c.code = '5100') > 0, true,
    'COGS is recognised (spec §22)'
  );
  perform app_test.assert_equals(
    (select sum(l.credit) from public.journal_entry_lines l
      join public.chart_of_accounts c on c.id = l.account_id
     where l.journal_entry_id = v_entry and c.code = '1500') > 0, true,
    'vehicle inventory is relieved'
  );

  -- ── Duplicate protection (spec §50) ───────────────────────────────────────
  -- Two layers, tested separately.
  --
  -- 1. At the sale: a second post finds the row already POSTED and refuses. The
  --    SELECT ... FOR UPDATE means a concurrent second caller blocks until the
  --    first commits, then hits this same check rather than racing past it.
  perform app_test.assert_raises(
    format('select public.post_vehicle_sale(%L)', v_sale),
    'a sale that is already POSTED cannot be posted again'
  );

  -- 2. At the ledger: post_journal with a key it has seen before returns the
  --    original entry instead of writing a second one.
  v_entry2 := app.post_journal(
    v_dealer, v_branch, date '2026-08-15', 'SALES', 'Duplicate attempt',
    jsonb_build_array(
      jsonb_build_object('account_id', public.resolve_account(v_dealer, 'SALES', 'INVOICE', 'RECEIVABLE', v_branch),
                         'debit', 100, 'credit', 0),
      jsonb_build_object('account_id', public.resolve_account(v_dealer, 'SALES', 'INVOICE', 'VEHICLE', v_branch),
                         'debit', 0, 'credit', 100)
    ),
    'SALE', v_sale, 'sale:' || v_sale::text
  );
  perform app_test.assert_equals(v_entry2, v_entry,
    'post_journal with a seen idempotency key returns the original entry (spec §50)');

  perform app_test.assert_equals(
    (select count(*)::int from public.journal_entries
      where source_document_id = v_sale and status = 'POSTED'), 1,
    'only one journal exists for the sale despite the repeated attempts'
  );

  -- An unbalanced set is refused before anything is written.
  perform app_test.assert_raises(
    format($f$select app.post_journal(%L, %L, current_date, 'MANUAL', 'Unbalanced',
      jsonb_build_array(
        jsonb_build_object('account_id', public.resolve_account(%L, 'SALES', 'INVOICE', 'RECEIVABLE', %L), 'debit', 100, 'credit', 0),
        jsonb_build_object('account_id', public.resolve_account(%L, 'SALES', 'INVOICE', 'VEHICLE', %L), 'debit', 0, 'credit', 90)
      ))$f$, v_dealer, v_branch, v_dealer, v_branch, v_dealer, v_branch),
    'post_journal refuses an unbalanced set (spec §22)'
  );

  -- ── Reversal is the only correction (spec §23) ────────────────────────────
  perform app_test.assert_raises(
    format('select app.reverse_journal(%L, null)', v_entry),
    'a reversal without a reason is refused'
  );

  perform app_test.assert_equals(
    app.reverse_journal(v_entry, 'Wrong chassis billed') is not null, true,
    'a posted journal can be reversed with a reason'
  );
  perform app_test.assert_equals(
    (select status from public.journal_entries where id = v_entry), 'REVERSED',
    'the original is marked REVERSED'
  );

  -- The pair nets to zero: the correction leaves the ledger where it was.
  perform app_test.assert_equals(
    (select sum(l.debit) - sum(l.credit) from public.journal_entry_lines l
      join public.journal_entries je on je.id = l.journal_entry_id
     where je.id = v_entry or je.reversal_of_id = v_entry), 0::numeric,
    'the sale and its reversal net to zero'
  );
end;
$$;

-- The whole ledger must still balance after everything above.
do $$
declare v_debit numeric; v_credit numeric;
begin
  select coalesce(sum(l.debit), 0), coalesce(sum(l.credit), 0) into v_debit, v_credit
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where je.status in ('POSTED', 'REVERSED');

  perform app_test.assert_equals(v_debit, v_credit,
    'the whole ledger still balances after the sale and its reversal');
end;
$$;

\echo '--- posting engine passed ---'
