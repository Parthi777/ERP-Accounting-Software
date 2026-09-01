-- =============================================================================
-- TEST — the cash and bank books are complete, and cost lands where it belongs
-- =============================================================================
-- Spec §24, §28, §36, §37, §38, §41, §59. Regression cover for migration 0049.
--
-- Both defects this guards against were invisible to every other test in this
-- suite, because each one checked its own module in isolation and each module
-- was internally consistent. They only showed up when a full set of trading data
-- was put through the real posting functions and the reports were reconciled
-- against the ledger:
--
--   * a booking advance, a vehicle sale receipt and a service receipt all
--     debited the cash ledger account and wrote no cash_transactions row, so the
--     Daily Cash Book — which reads only that table — showed a fraction of the
--     day's takings and could never agree with the general ledger;
--
--   * accessory cost was added to whichever COGS account the selling module used,
--     so accounts 1600 and 5200 stayed empty for the life of the system while
--     vehicle and spare margins were overstated in cost.
--
-- Named 9A_ so it runs last: it asserts against dealer-wide totals, which means
-- it must see every other test's postings rather than land in the middle of them.
-- The glob sorts 9A_ after 99_ (and, note, sorts 100_ before 10_, which is why
-- the numbering stops at 99).
-- =============================================================================

\echo '--- cash book completeness and cost classification ---'

-- =============================================================================
-- Every branch has a cash account (spec §36)
-- =============================================================================
-- The precondition for any of this. It was false for every branch ever created
-- until 0049: cash_accounts has always carried `unique (branch_id)`, but nothing
-- created the row.
do $$
declare v_missing int;
begin
  select count(*) into v_missing
    from public.branches b
    left join public.cash_accounts ca on ca.branch_id = b.id
   where ca.id is null;

  perform app_test.assert_equals(v_missing, 0,
    'every branch has a cash account, so receipts have somewhere to land');
end;
$$;

-- =============================================================================
-- Money taken by other modules reaches the book
-- =============================================================================
do $$
declare
  v_dealer   uuid;
  v_branch   uuid;
  v_customer uuid;
  v_model    uuid;
  v_variant  uuid;
  v_hsn      uuid;
  v_item     uuid;
  v_bank_acc uuid;
  v_bank_ldg uuid;
  v_booking  uuid;
  v_bk_no    text;
  v_invoice  uuid;
  v_inv_no   text;
  v_rows     int;
  v_amount   numeric;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'NORTH';

  insert into public.customers (dealer_id, name, mobile, city, state, state_code)
  values (v_dealer, 'Cash Book Test Customer', '9700000041', 'Chennai', 'Tamil Nadu', '33')
  returning id into v_customer;

  insert into public.vehicle_models (dealer_id, brand, name, model_code, category)
  values (v_dealer, 'TVS', 'Cashbook Test Model', 'CBTEST', 'SCOOTER') returning id into v_model;

  insert into public.vehicle_variants (dealer_id, model_id, name, variant_code)
  values (v_dealer, v_model, 'Standard', 'CBTEST-STD') returning id into v_variant;

  -- ═══ A booking advance in cash ═══════════════════════════════════════════
  select booking_id, booking_number into v_booking, v_bk_no
    from public.create_booking_with_advance(
      v_customer, v_model, v_branch, 60000, 5000, 'CASH', v_variant);

  select count(*), coalesce(sum(ct.amount), 0) into v_rows, v_amount
    from public.cash_transactions ct
    join public.booking_payments bp on bp.journal_entry_id = ct.journal_entry_id
   where bp.booking_id = v_booking;

  perform app_test.assert_equals(v_rows, 1,
    'a cash booking advance writes exactly one cash book row');
  perform app_test.assert_equals(v_amount, 5000::numeric,
    'for the amount actually received');

  -- ═══ A booking advance by bank ═══════════════════════════════════════════
  -- NORTH has no bank account of its own, so this must fall through to the
  -- dealer-wide one rather than being dropped.
  -- Specifically a branchless account: that is the fallback being tested. An
  -- account belonging to another branch must not be borrowed for NORTH's receipt.
  select id into v_bank_acc from public.bank_accounts
   where dealer_id = v_dealer and branch_id is null and status = 'ACTIVE' limit 1;

  if v_bank_acc is null then
    select id into v_bank_ldg from public.chart_of_accounts
     where dealer_id = v_dealer and code = '1200';
    insert into public.bank_accounts
      (dealer_id, branch_id, name, bank_name, account_number, account_type, ledger_account_id)
    values (v_dealer, null, 'Test Collection A/c', 'Test Bank', 'CBTEST0001', 'CURRENT', v_bank_ldg)
    returning id into v_bank_acc;
  end if;

  select booking_id into v_booking
    from public.create_booking_with_advance(
      v_customer, v_model, v_branch, 60000, 7000, 'UPI', v_variant);

  select count(*), coalesce(sum(bt.amount), 0) into v_rows, v_amount
    from public.bank_transactions bt
    join public.booking_payments bp on bp.journal_entry_id = bt.journal_entry_id
   where bp.booking_id = v_booking;

  perform app_test.assert_equals(v_rows, 1,
    'a bank booking advance writes one bank book row, falling back to the dealer account');
  perform app_test.assert_equals(v_amount, 7000::numeric, 'for the amount received');

  -- ═══ A counter sale settled in cash ══════════════════════════════════════
  insert into public.hsn_codes (dealer_id, code, description)
  values (v_dealer, '87141050', 'Cashbook test accessories') returning id into v_hsn;

  insert into public.tax_codes
    (dealer_id, code, name, hsn_code_id, cgst_rate, sgst_rate, igst_rate, effective_from)
  values (v_dealer, 'GST18_CB', 'GST 18% test', v_hsn, 9, 9, 18, date '2020-01-01');

  insert into public.inventory_items
    (dealer_id, item_code, name, item_type, hsn_code_id, standard_cost, selling_price, tax_code)
  values (v_dealer, 'CB-ACC-01', 'Cashbook test helmet', 'ACCESSORY', v_hsn, 600, 1000, 'GST18_CB')
  returning id into v_item;

  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
     reference_type, narration)
  values (v_dealer, v_branch, v_item, 'COMPANY', 'OPENING', 10, 600, 'OPENING', 'Test stock');

  select invoice_id, invoice_number into v_invoice, v_inv_no
    from public.create_counter_invoice(v_branch, v_customer);
  perform public.add_service_line(v_invoice, 'ACCESSORY', 'Cashbook test helmet', 2, 1000, v_item, 'GST18_CB');
  perform public.post_service_invoice(v_invoice);

  select total_amount into v_amount from public.service_invoices where id = v_invoice;
  perform public.record_service_payment(v_invoice, v_amount, 'CASH');

  select count(*) into v_rows
    from public.cash_transactions ct
    join public.service_payments sp on sp.journal_entry_id = ct.journal_entry_id
   where sp.invoice_id = v_invoice;

  perform app_test.assert_equals(v_rows, 1,
    'a counter sale settled in cash reaches the cash book');
end;
$$;

-- =============================================================================
-- A finance settlement is not money in the till
-- =============================================================================
-- The one case that must write nothing. A sale settled by finance moves the debt
-- to the finance company; the cash has not arrived, and a book that claims it
-- has is worse than one that omits it.
do $$
declare
  v_dealer  uuid;
  v_branch  uuid;
  v_company uuid;
  v_sale    uuid;
  v_entry   uuid;
  v_rows    int;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'MAIN';

  select id into v_company from public.finance_companies
   where dealer_id = v_dealer and status = 'ACTIVE' limit 1;

  if v_company is null then
    insert into public.finance_companies (dealer_id, code, name)
    values (v_dealer, 'CBTESTFIN', 'Cashbook Test Finance') returning id into v_company;
  end if;

  select id into v_sale from public.sales
   where dealer_id = v_dealer and status in ('POSTED', 'DELIVERED')
   order by created_at limit 1;

  if v_sale is null then
    -- Nothing posted by the earlier tests to attach a payment to; the assertion
    -- below has nothing to say, so skip rather than assert a vacuous truth.
    raise notice '    -- skipped: no posted sale to settle by finance';
    return;
  end if;

  select journal_entry_id into v_entry
    from public.record_sale_payment(v_sale, 1000, 'FINANCE', 'Test finance', v_company);

  select count(*) into v_rows
    from (select 1 from public.cash_transactions where journal_entry_id = v_entry
          union all
          select 1 from public.bank_transactions where journal_entry_id = v_entry) x;

  perform app_test.assert_equals(v_rows, 0,
    'a finance settlement writes no cash or bank row: no money has moved');
end;
$$;

-- =============================================================================
-- Every module receipt that touches cash is in the cash book
-- =============================================================================
-- The invariant that failed before 0049, stated per journal rather than as a
-- dealer-wide total. A total would be wrong here: other tests in this suite
-- hand-build journals against the cash account on purpose, to exercise the
-- journal machinery itself, and those legitimately have no book row behind them.
--
-- What must hold is narrower and stronger — if a business module took money and
-- posted it to a cash account, the cash book has the row.
do $$
declare
  v_dealer  uuid;
  v_orphans int;
  v_detail  text;
begin
  select id into v_dealer from public.dealers where code = 'SBM';

  select count(*), coalesce(string_agg(distinct x.source_document_type, ', '), '')
    into v_orphans, v_detail
    from (
      select distinct e.id, e.source_document_type
        from public.journal_entries e
        join public.journal_entry_lines l on l.journal_entry_id = e.id
        join public.chart_of_accounts a on a.id = l.account_id
        join public.cash_accounts ca on ca.ledger_account_id = a.id and ca.dealer_id = v_dealer
       where e.dealer_id = v_dealer
         and e.status = 'POSTED'
         and e.source_document_type in
             ('BOOKING', 'SALE_PAYMENT', 'SERVICE_RECEIPT', 'BOOKING_REFUND', 'CASH_BOOK')
         and not exists (
           select 1 from public.cash_transactions ct where ct.journal_entry_id = e.id)
    ) x;

  perform app_test.assert_equals(v_orphans, 0,
    'every module receipt posted to cash has its cash book row' ||
    case when v_orphans > 0 then ' (missing from: ' || v_detail || ')' else '' end);
end;
$$;

-- =============================================================================
-- Cost lands in the account that names it (spec §24)
-- =============================================================================
do $$
declare
  v_dealer    uuid;
  v_branch    uuid;
  v_customer  uuid;
  v_hsn       uuid;
  v_acc       uuid;
  v_spare     uuid;
  v_invoice   uuid;
  v_acc_cogs  numeric;
  v_spr_cogs  numeric;
  v_acc_inv   numeric;
  v_spr_inv   numeric;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'SOUTH';

  insert into public.customers (dealer_id, name, mobile, city, state, state_code)
  values (v_dealer, 'Cost Split Test Customer', '9700000042', 'Chennai', 'Tamil Nadu', '33')
  returning id into v_customer;

  insert into public.hsn_codes (dealer_id, code, description)
  values (v_dealer, '87141060', 'Cost split test goods') returning id into v_hsn;

  insert into public.tax_codes
    (dealer_id, code, name, hsn_code_id, cgst_rate, sgst_rate, igst_rate, effective_from)
  values (v_dealer, 'GST18_CS', 'GST 18% cost split', v_hsn, 9, 9, 18, date '2020-01-01');

  insert into public.inventory_items
    (dealer_id, item_code, name, item_type, hsn_code_id, standard_cost, selling_price, tax_code)
  values
    (v_dealer, 'CS-ACC-01', 'Cost split accessory', 'ACCESSORY', v_hsn, 400, 900, 'GST18_CS'),
    (v_dealer, 'CS-SPR-01', 'Cost split spare',     'SPARE',     v_hsn, 100, 250, 'GST18_CS');

  select id into v_acc   from public.inventory_items where dealer_id = v_dealer and item_code = 'CS-ACC-01';
  select id into v_spare from public.inventory_items where dealer_id = v_dealer and item_code = 'CS-SPR-01';

  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
     reference_type, narration)
  values
    (v_dealer, v_branch, v_acc,   'COMPANY', 'OPENING', 5, 400, 'OPENING', 'Test stock'),
    (v_dealer, v_branch, v_spare, 'COMPANY', 'OPENING', 5, 100, 'OPENING', 'Test stock');

  -- One invoice carrying both, so the split has to happen within a single
  -- journal rather than falling out of which module posted it.
  select invoice_id into v_invoice from public.create_counter_invoice(v_branch, v_customer);
  perform public.add_service_line(v_invoice, 'ACCESSORY', 'Cost split accessory', 3, 900, v_acc,   'GST18_CS');
  perform public.add_service_line(v_invoice, 'SPARE',     'Cost split spare',     2, 250, v_spare, 'GST18_CS');
  perform public.post_service_invoice(v_invoice);

  select
    coalesce(sum(l.debit)  filter (where a.code = '5200'), 0),
    coalesce(sum(l.debit)  filter (where a.code = '5300'), 0),
    coalesce(sum(l.credit) filter (where a.code = '1600'), 0),
    coalesce(sum(l.credit) filter (where a.code = '1700'), 0)
    into v_acc_cogs, v_spr_cogs, v_acc_inv, v_spr_inv
    from public.journal_entry_lines l
    join public.chart_of_accounts a on a.id = l.account_id
    join public.service_invoices si on si.journal_entry_id = l.journal_entry_id
   where si.id = v_invoice;

  -- 3 × 400 accessory, 2 × 100 spare.
  perform app_test.assert_equals(v_acc_cogs, 1200::numeric,
    'accessory cost is charged to Accessories COGS, not to the spare account');
  perform app_test.assert_equals(v_spr_cogs, 200::numeric,
    'spare cost is charged to Spare COGS, and carries none of the accessory cost');
  perform app_test.assert_equals(v_acc_inv, 1200::numeric,
    'and it is Accessories Inventory that is relieved');
  perform app_test.assert_equals(v_spr_inv, 200::numeric,
    'while Spare Inventory is relieved of the spares alone');
end;
$$;

-- =============================================================================
-- Accessories COGS agrees with the accessory stock actually issued
-- =============================================================================
-- The dealer-wide version, cross-checked against the inventory ledger rather
-- than against service_lines.cost_amount. The line carries an indicative cost;
-- what posting charges is the cost of the lots allocate_stock actually drew on
-- (spec §31), and those differ whenever LOCAL and COMPANY stock were bought at
-- different prices — which is the normal case, not an edge case.
--
-- Scoped to posted service invoices so it is deterministic: a vehicle sale
-- consumes its fittings when they are added rather than when it posts, so a sale
-- left in draft would legitimately show stock issued with no COGS behind it yet.
do $$
declare
  v_dealer   uuid;
  v_issued   numeric;
  v_charged  numeric;
begin
  select id into v_dealer from public.dealers where code = 'SBM';

  select coalesce(abs(sum(t.quantity * t.unit_cost)), 0) into v_issued
    from public.inventory_transactions t
    join public.inventory_items i on i.id = t.item_id
    join public.service_invoices si on si.id = t.reference_id
   where t.dealer_id = v_dealer
     and t.transaction_type = 'CONSUMPTION'
     and t.reference_type = 'SERVICE_INVOICE'
     and i.item_type = 'ACCESSORY'
     and si.status = 'POSTED';

  select coalesce(sum(l.debit), 0) into v_charged
    from public.journal_entry_lines l
    join public.chart_of_accounts a on a.id = l.account_id
    join public.journal_entries e on e.id = l.journal_entry_id
    join public.service_invoices si on si.journal_entry_id = e.id
   where a.dealer_id = v_dealer and a.code = '5200'
     and e.status = 'POSTED' and si.status = 'POSTED';

  perform app_test.assert_equals(v_issued > 0, true,
    'accessories were actually issued, so this check has something to prove');
  perform app_test.assert_equals(round(v_charged, 2), round(v_issued, 2),
    'Accessories COGS equals the accessory stock issued at the cost it was issued at');
end;
$$;
