-- =============================================================================
-- TEST — Acceptance test A: one sample month, end to end
-- =============================================================================
-- Accounting Web App Audit Checklist §10 ("enter one sample month"), §11 test B
-- (bank reconciliation) and §12 (duplicate request, tenant access, sub-ledger
-- tie-out).
--
-- A clean tenant, provisioned the way a real dealer is, with zero opening
-- balances. The ten events are entered through the same functions the screens
-- call — bank entry, purchase bill, counter invoice, receipt, payment, manual
-- journal — never by inserting journal lines directly, because the point is to
-- prove the documents produce the right accounting, not that the ledger can
-- hold it.
--
-- The checklist's figures, which every assertion below comes from:
--
--   1  Owner capital into bank          10,00,000
--   2  Computer on credit               1,00,000 + input GST 18,000
--   3  Inventory on credit              5,00,000 + input GST 90,000
--   4  Sale, cost 3,20,000              4,50,000 + output GST 81,000; 2,00,000 by bank
--   5  Rent paid by bank                50,000 + input GST 9,000
--   6  Salary paid                      80,000
--   7  Customer receipt                 2,50,000
--   8  Supplier payment                 4,00,000
--   9  Bank charge                      1,000
--  10  Computer depreciation            2,000
--
--   receivable 81,000 · payable 3,08,000 · inventory 1,80,000
--   input GST 1,17,000 Dr · output GST 81,000 Cr · gross profit 1,30,000
--   net loss 3,000 · bank 9,10,000 · trial balance 18,41,000 each side
--
-- Two shapes differ from the checklist's single journals, and the net effect is
-- identical: the sale is an invoice then a bank receipt (event 4), and the rent
-- is a supplier bill then a bank payment (event 5) — because that is what the
-- documents are. The landlord's account nets to nil, so the checkpoints hold.
--
-- Everything from event 1 on runs as the dealer owner under `authenticated`, so
-- RLS is in force exactly as it is for the application: the reports below see
-- this tenant and nothing else.
-- =============================================================================

\echo '--- acceptance test A: the sample month ---'

-- ── A clean tenant (platform admin work) ──────────────────────────────────────
select app_test.login('99999999-9999-4999-8999-999999999999');

do $$
begin
  insert into auth.users (id, email) values
    ('99999999-9999-4999-8999-999999999999', 'platform@example.com'),
    ('cccccccc-1111-4111-8111-cccccccccccc', 'owner@acceptance.example')
  on conflict (id) do nothing;

  insert into public.user_profiles (id, dealer_id, full_name, email, is_platform_admin, status)
  values ('99999999-9999-4999-8999-999999999999', null, 'Platform Admin', 'platform@example.com', true, 'ACTIVE')
  on conflict (id) do update set is_platform_admin = true;

  perform app.provision_dealer(
    p_code          => 'ACPT',
    p_legal_name    => 'Acceptance Test Motors Private Limited',
    p_trade_name    => 'Acceptance Test Motors',
    p_state         => 'Tamil Nadu',
    p_state_code    => '33',
    p_owner_email   => 'owner@acceptance.example',
    p_owner_name    => 'Acceptance Owner',
    p_owner_user_id => 'cccccccc-1111-4111-8111-cccccccccccc',
    p_branch_name   => 'Chennai Main',
    p_city          => 'Chennai');
end $$;

select app_test.login('cccccccc-1111-4111-8111-cccccccccccc');
set role authenticated;

do $$
declare
  v_dealer     uuid := app.current_dealer_id();
  v_branch     uuid;
  v_bank       uuid;
  v_supplier   uuid;
  v_landlord   uuid;
  v_customer   uuid;
  v_hsn        uuid;
  v_item       uuid;
  v_bill       uuid;
  v_invoice    uuid;
  v_entry      uuid;
  v_journals   bigint;
  r            record;
  v_n          numeric;
  v_dr         numeric;
  v_cr         numeric;

  -- Signed, debit-positive balance of the accounts with these codes.
  -- (a small closure, written out: plpgsql has none)
begin
  select id into v_branch from public.branches where dealer_id = v_dealer;

  perform app_test.assert_equals(
    (select count(*)::int from public.journal_entries), 0,
    'the tenant starts with no journals: zero opening balances');

  -- ── Masters ──────────────────────────────────────────────────────────────
  v_bank := public.create_bank_account('Main current account', 'HDFC Bank', '50200099990001',
                                       'HDFC0000001', 'CURRENT', v_branch, 0);

  insert into public.suppliers (dealer_id, name, supplier_type, mobile, city, state)
  values (v_dealer, 'Alpha Traders', 'GOODS', '9840011111', 'Chennai', 'Tamil Nadu')
  returning id into v_supplier;

  insert into public.suppliers (dealer_id, name, supplier_type, mobile, city, state)
  values (v_dealer, 'Showroom Landlord', 'SERVICE', '9840022222', 'Chennai', 'Tamil Nadu')
  returning id into v_landlord;

  insert into public.customers (dealer_id, name, mobile, city, state, state_code)
  values (v_dealer, 'Acceptance Customer', '9840033333', 'Chennai', 'Tamil Nadu', '33')
  returning id into v_customer;

  insert into public.hsn_codes (dealer_id, code, description)
  values (v_dealer, '87141090', 'Two-wheeler accessories') returning id into v_hsn;

  insert into public.tax_codes
    (dealer_id, code, name, hsn_code_id, cgst_rate, sgst_rate, igst_rate, effective_from)
  values (v_dealer, 'GST18', 'GST 18%', v_hsn, 9, 9, 18, date '2020-01-01');

  insert into public.inventory_items
    (dealer_id, item_code, name, item_type, hsn_code_id, standard_cost, selling_price, tax_code)
  values (v_dealer, 'ACC-KIT-01', 'Accessory kit', 'ACCESSORY', v_hsn, 5000, 7031.25, 'GST18')
  returning id into v_item;

  -- ══ 1. Owner capital into bank ═══════════════════════════════════════════
  select journal_entry_id into v_entry from public.record_bank_transaction(
    v_bank, 'RECEIPT', 1000000, 'Owner capital introduced',
    (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '3100'));
  raise notice '  evidence  event 1  %  Bank Dr / Capital Cr 10,00,000',
    (select entry_number from public.journal_entries where id = v_entry);

  -- ══ 2. Computer on credit — an EXPENSE line capitalised to fixed assets ══
  insert into public.purchase_bills (dealer_id, branch_id, supplier_id, supplier_bill_number, bill_date)
  values (v_dealer, v_branch, v_supplier, 'AT/COMP/001', current_date) returning id into v_bill;
  insert into public.purchase_bill_lines
    (purchase_bill_id, dealer_id, line_number, line_type, account_id, hsn_sac, description,
     quantity, unit_rate, taxable_value, cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount)
  values (v_bill, v_dealer, 1, 'EXPENSE',
          (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '1951'),
          '8471', 'Desktop computer', 1, 100000, 100000, 9, 9, 9000, 9000, 118000);
  v_entry := public.post_purchase_bill(v_bill);
  raise notice '  evidence  event 2  %  Computer Dr 1,00,000; Input GST Dr 18,000; Supplier Cr 1,18,000',
    (select entry_number from public.journal_entries where id = v_entry);

  -- ══ 3. Inventory on credit — 100 kits at 5,000 ═══════════════════════════
  insert into public.purchase_bills (dealer_id, branch_id, supplier_id, supplier_bill_number, bill_date)
  values (v_dealer, v_branch, v_supplier, 'AT/STOCK/001', current_date) returning id into v_bill;
  insert into public.purchase_bill_lines
    (purchase_bill_id, dealer_id, line_number, line_type, item_id, source, description,
     quantity, unit_rate, taxable_value, cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount)
  values (v_bill, v_dealer, 1, 'ACCESSORY', v_item, 'LOCAL', 'Accessory kit',
          100, 5000, 500000, 9, 9, 45000, 45000, 590000);
  v_entry := public.post_purchase_bill(v_bill);
  raise notice '  evidence  event 3  %  Inventory Dr 5,00,000; Input GST Dr 90,000; Supplier Cr 5,90,000',
    (select entry_number from public.journal_entries where id = v_entry);

  -- ══ 4. The sale: 64 kits, 4,50,000 + 18%; 2,00,000 received by bank ═════
  select invoice_id into v_invoice from public.create_counter_invoice(v_branch, v_customer);
  perform public.add_service_line(v_invoice, 'ACCESSORY', 'Accessory kit', 64, 7031.25, v_item, 'GST18');
  v_entry := public.post_service_invoice(v_invoice);
  raise notice '  evidence  event 4  %  Customer Dr 5,31,000; Sales Cr 4,50,000; Output GST Cr 81,000; COGS Dr / Inventory Cr 3,20,000',
    (select entry_number from public.journal_entries where id = v_entry);

  perform app_test.assert_equals(
    (select total_cost from public.service_invoices where id = v_invoice), 320000::numeric,
    'event 4: COGS is the cost of the 64 kits sold, 3,20,000');

  select * into r from public.record_service_payment(v_invoice, 200000, 'NEFT', 'UTR-ACPT-0001');
  raise notice '  evidence  event 4  %  Bank Dr / Customer Cr 2,00,000 (receipt %)',
    (select je.entry_number from public.service_payments sp
       join public.journal_entries je on je.id = sp.journal_entry_id where sp.id = r.payment_id),
    r.receipt_number;

  -- ══ 5. Rent: the landlord's bill, paid by bank the same day ═════════════
  insert into public.purchase_bills (dealer_id, branch_id, supplier_id, supplier_bill_number, bill_date)
  values (v_dealer, v_branch, v_landlord, 'RENT/SEP', current_date) returning id into v_bill;
  insert into public.purchase_bill_lines
    (purchase_bill_id, dealer_id, line_number, line_type, account_id, hsn_sac, description,
     quantity, unit_rate, taxable_value, cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount)
  values (v_bill, v_dealer, 1, 'EXPENSE',
          (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '5600'),
          '997212', 'Showroom rent', 1, 50000, 50000, 9, 9, 4500, 4500, 59000);
  v_entry := public.post_purchase_bill(v_bill);
  raise notice '  evidence  event 5  %  Rent Dr 50,000; Input GST Dr 9,000; Landlord Cr 59,000',
    (select entry_number from public.journal_entries where id = v_entry);

  select journal_entry_id into v_entry from public.record_bank_transaction(
    p_bank_account_id => v_bank, p_direction => 'PAYMENT', p_amount => 59000,
    p_particular => 'Rent paid', p_supplier_id => v_landlord,
    p_account_id => (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '2200'));
  raise notice '  evidence  event 5  %  Landlord Dr / Bank Cr 59,000',
    (select entry_number from public.journal_entries where id = v_entry);

  -- ══ 6. Salary ════════════════════════════════════════════════════════════
  select journal_entry_id into v_entry from public.record_bank_transaction(
    v_bank, 'PAYMENT', 80000, 'Salaries for the month',
    (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '5500'));
  raise notice '  evidence  event 6  %  Salary Dr / Bank Cr 80,000',
    (select entry_number from public.journal_entries where id = v_entry);

  -- ══ 7. Customer receipt ═══════════════════════════════════════════════════
  select journal_entry_id into v_entry from public.record_bank_transaction(
    p_bank_account_id => v_bank, p_direction => 'RECEIPT', p_amount => 250000,
    p_particular => 'Received from Acceptance Customer', p_customer_id => v_customer,
    p_account_id => (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '1300'),
    p_idempotency_key => 'acpt-receipt-7');
  raise notice '  evidence  event 7  %  Bank Dr / Customer Cr 2,50,000',
    (select entry_number from public.journal_entries where id = v_entry);

  -- Duplicate request (§12): the same receipt submitted again.
  select count(*) into v_journals from public.journal_entries;
  perform public.record_bank_transaction(
    p_bank_account_id => v_bank, p_direction => 'RECEIPT', p_amount => 250000,
    p_particular => 'Received from Acceptance Customer', p_customer_id => v_customer,
    p_account_id => (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '1300'),
    p_idempotency_key => 'acpt-receipt-7');
  perform app_test.assert_equals((select count(*) from public.journal_entries), v_journals,
    '§12 duplicate request: a resubmitted receipt posts nothing new');
  perform app_test.assert_equals(
    (select count(*)::int from public.bank_transactions where idempotency_key = 'acpt-receipt-7'), 1,
    'and writes one bank-book row');

  -- ══ 8. Supplier payment ══════════════════════════════════════════════════
  select journal_entry_id into v_entry from public.record_bank_transaction(
    p_bank_account_id => v_bank, p_direction => 'PAYMENT', p_amount => 400000,
    p_particular => 'Paid to Alpha Traders', p_supplier_id => v_supplier,
    p_account_id => (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '2200'));
  raise notice '  evidence  event 8  %  Supplier Dr / Bank Cr 4,00,000',
    (select entry_number from public.journal_entries where id = v_entry);

  -- ══ 9. Bank charge ═══════════════════════════════════════════════════════
  select journal_entry_id into v_entry from public.record_bank_transaction(
    v_bank, 'PAYMENT', 1000, 'Bank charges',
    (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '5800'));
  raise notice '  evidence  event 9  %  Bank charges Dr / Bank Cr 1,000',
    (select entry_number from public.journal_entries where id = v_entry);

  -- ══ 10. Depreciation — the one entry that is a journal by nature ═════════
  select journal_entry_id into v_entry from public.post_manual_journal(
    current_date, 'Depreciation on computer for the month',
    jsonb_build_array(
      jsonb_build_object('account_id',
        (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '5950'),
        'debit', 2000, 'credit', 0),
      jsonb_build_object('account_id',
        (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '1959'),
        'debit', 0, 'credit', 2000)));
  raise notice '  evidence  event 10 %  Depreciation Dr / Accumulated depreciation Cr 2,000',
    (select entry_number from public.journal_entries where id = v_entry);
end $$;

-- ═══ Each event's journal, line by line ══════════════════════════════════════
-- The closing figures below could come out right from wrong journals that
-- happen to net. So each of the twelve vouchers is compared, account by
-- account, with the effect the checklist expects (GST shown as its CGST 1900 /
-- SGST 1910 and output 2300 / 2400 halves).
do $$
declare
  v_expected text[] := array[
    '1200 Dr 1000000, 3100 Cr 1000000',                                   -- 1 capital
    '1900 Dr 9000, 1910 Dr 9000, 1951 Dr 100000, 2200 Cr 118000',          -- 2 computer
    '1600 Dr 500000, 1900 Dr 45000, 1910 Dr 45000, 2200 Cr 590000',        -- 3 inventory
    '1300 Dr 531000, 5200 Dr 320000, 1600 Cr 320000, 2300 Cr 40500, 2400 Cr 40500, 4200 Cr 450000', -- 4 sale + COGS
    '1200 Dr 200000, 1300 Cr 200000',                                     -- 4 part received by bank
    '1900 Dr 4500, 1910 Dr 4500, 5600 Dr 50000, 2200 Cr 59000',            -- 5 rent bill
    '2200 Dr 59000, 1200 Cr 59000',                                       -- 5 rent paid
    '5500 Dr 80000, 1200 Cr 80000',                                       -- 6 salary
    '1200 Dr 250000, 1300 Cr 250000',                                     -- 7 customer receipt
    '2200 Dr 400000, 1200 Cr 400000',                                     -- 8 supplier payment
    '5800 Dr 1000, 1200 Cr 1000',                                         -- 9 bank charge
    '5950 Dr 2000, 1959 Cr 2000'                                          -- 10 depreciation
  ];
  v_actual text[];
begin
  select array_agg(lines order by entry_number) into v_actual
    from (
      select je.entry_number,
             string_agg(c.code || case when l.debit > 0 then ' Dr ' || l.debit::numeric(18, 0)
                                       else ' Cr ' || l.credit::numeric(18, 0) end,
                        ', ' order by l.debit = 0, c.code) as lines
        from public.journal_entries je
        join public.journal_entry_lines l on l.journal_entry_id = je.id
        join public.chart_of_accounts c on c.id = l.account_id
       where je.dealer_id = app.current_dealer_id()
       group by je.entry_number
    ) j;

  for i in 1 .. array_length(v_expected, 1) loop
    perform app_test.assert_equals(v_actual[i], v_expected[i],
      format('journal %s posts exactly the expected lines', i));
  end loop;
  perform app_test.assert_equals(array_length(v_actual, 1), 12,
    'and the month produced those twelve vouchers and no others');
end $$;

-- ═══ Required closing results ════════════════════════════════════════════════
do $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_dr     numeric;
  v_cr     numeric;
  v_inc    numeric;
  v_cos    numeric;
  v_exp    numeric;
  v_assets numeric;
  v_rest   numeric;
  r        record;
begin
  -- Every journal balances and every line has its parent.
  perform app_test.assert_equals(
    (select count(*)::int from public.journal_entries where total_debit <> total_credit), 0,
    'every posted voucher balances');
  perform app_test.assert_equals(
    (select count(*)::int from public.journal_entry_lines l
      where not exists (select 1 from public.journal_entries je where je.id = l.journal_entry_id)), 0,
    'no line without its voucher');

  -- Balances from the trial balance itself, by code.
  perform app_test.assert_equals(
    (select debit_balance from public.trial_balance(current_date) where account_code = '1300'),
    81000::numeric, 'customer receivable 81,000');
  perform app_test.assert_equals(
    (select credit_balance from public.trial_balance(current_date) where account_code = '2200'),
    308000::numeric, 'supplier payable 3,08,000');
  perform app_test.assert_equals(
    (select debit_balance from public.trial_balance(current_date) where account_code = '1600'),
    180000::numeric, 'inventory 1,80,000');
  perform app_test.assert_equals(
    (select quantity from public.inventory_stock s
       join public.inventory_items i on i.id = s.item_id where i.item_code = 'ACC-KIT-01'),
    36::numeric, 'and 36 kits on hand to show for it');
  perform app_test.assert_equals(
    (select sum(debit_balance) from public.trial_balance(current_date)
      where account_code in ('1900', '1910', '1920')),
    117000::numeric, 'input GST 1,17,000 debit');
  perform app_test.assert_equals(
    (select sum(credit_balance) from public.trial_balance(current_date)
      where account_code in ('2300', '2400', '2500')),
    81000::numeric, 'output GST 81,000 credit');
  perform app_test.assert_equals(
    117000::numeric - 81000,
    (select sum(debit_balance) - (select sum(credit_balance) from public.trial_balance(current_date)
                                   where account_code in ('2300', '2400', '2500'))
       from public.trial_balance(current_date) where account_code in ('1900', '1910', '1920')),
    'simplified excess ITC 36,000');
  perform app_test.assert_equals(
    (select debit_balance from public.trial_balance(current_date) where account_code = '1200'),
    910000::numeric, 'bank 9,10,000 debit');
  perform app_test.assert_equals(
    (select credit_balance from public.trial_balance(current_date) where account_code = '1959'),
    2000::numeric, 'accumulated depreciation sits on the credit side');

  select sum(debit_balance), sum(credit_balance) into v_dr, v_cr from public.trial_balance(current_date);
  perform app_test.assert_equals(v_dr, 1841000::numeric, 'trial balance debits 18,41,000');
  perform app_test.assert_equals(v_cr, 1841000::numeric, 'trial balance credits 18,41,000');

  -- The P&L, read the way the page reads it.
  select coalesce(sum(amount) filter (where section = 'INCOME'), 0),
         coalesce(sum(amount) filter (where section = 'COST_OF_SALES'), 0),
         coalesce(sum(amount) filter (where section = 'EXPENSE'), 0)
    into v_inc, v_cos, v_exp
    from public.profit_and_loss(current_date, current_date);
  perform app_test.assert_equals(v_inc, 450000::numeric, 'sales 4,50,000');
  perform app_test.assert_equals(v_inc - v_cos, 130000::numeric, 'gross profit 1,30,000');
  perform app_test.assert_equals(v_inc - v_cos - v_exp, -3000::numeric, 'net result: loss of 3,000');

  -- The balance sheet balances, with the period's result in equity.
  select coalesce(sum(amount) filter (where section = 'ASSET'), 0),
         coalesce(sum(amount) filter (where section <> 'ASSET'), 0)
    into v_assets, v_rest
    from public.balance_sheet(current_date);
  perform app_test.assert_equals(v_assets, 1386000::numeric, 'total assets 13,86,000');
  perform app_test.assert_equals(v_assets, v_rest,
    'assets = liabilities + equity + current result');
  perform app_test.assert_equals(
    (select amount from public.balance_sheet(current_date) where account_code = 'RESULT'),
    -3000::numeric, 'and the result carried to equity is the P&L''s loss');

  -- Every control account agrees with its sub-ledger (§04, §06, §12).
  for r in select * from public.control_account_tieout(current_date) loop
    raise notice '  evidence  tie-out  % %  ledger % · sub-ledger %',
      r.control, r.account_code, r.ledger_balance, r.subledger_balance;
  end loop;
  perform app_test.assert_equals(
    (select count(*)::int from public.control_account_tieout(current_date) where difference <> 0), 0,
    'every control account ties to its sub-ledger: customers, suppliers, cash, bank, stock');
  perform app_test.assert_equals(
    (select subledger_balance from public.control_account_tieout(current_date) where control = 'BANK'),
    910000::numeric, 'the bank book says 9,10,000 as well');
  perform app_test.assert_equals(
    (select subledger_balance from public.control_account_tieout(current_date) where control = 'ACCESSORY_STOCK'),
    180000::numeric, 'and the stock ledger values the 36 kits at 1,80,000');

  -- Input tax reaches the GST screens, overheads included.
  perform app_test.assert_equals(
    (select sum(total_tax) from public.gst_input_summary(current_date, current_date)),
    117000::numeric, 'the input-tax summary carries all 1,17,000, not only the stock purchase');
  perform app_test.assert_equals(
    (select total_tax from public.gst_input_summary(current_date, current_date) where hsn_code = '997212'),
    9000::numeric, 'with the rent under its SAC');
  perform app_test.assert_equals(
    (select sum(total_tax) from public.gst_summary(current_date, current_date)),
    81000::numeric, 'and the output summary carries 81,000');
end $$;

-- ═══ §12 tenant access: this owner cannot reach another dealer's books ═══════
do $$
declare
  v_mine  uuid;
  v_alien uuid;
  v_sbm   uuid;
begin
  select id into v_mine from public.chart_of_accounts where dealer_id = app.current_dealer_id() and code = '5800';
  -- The other tenant's ids are read with RLS off — they are what an attacker
  -- would have guessed or scraped — then used with RLS back on.
  reset role;
  select id into v_sbm from public.dealers where code = 'SBM';
  select id into v_alien from public.chart_of_accounts where dealer_id = v_sbm and code = '2700';
  set role authenticated;

  perform app_test.assert_equals(v_alien is not null, true, 'the other tenant''s account exists');
  perform app_test.assert_equals(
    (select count(*)::int from public.chart_of_accounts where dealer_id = v_sbm), 0,
    'but its chart is invisible to this owner');
  perform app_test.assert_equals(
    (select count(*)::int from public.journal_entries where dealer_id = v_sbm), 0,
    'and so are its journals');
  perform app_test.assert_raises(
    format($q$select public.post_manual_journal(current_date, 'Cross tenant',
      jsonb_build_array(
        jsonb_build_object('account_id', %L, 'debit', 10, 'credit', 0),
        jsonb_build_object('account_id', %L, 'debit', 0, 'credit', 10)))$q$, v_mine, v_alien),
    'and posting into it with a guessed id is refused');
end $$;

reset role;

-- ═══ Acceptance test B: the bank reconciliation statement ═══════════════════
-- Book 2,40,000; direct deposit 50,000 and charge 1,500 on the statement only;
-- a 30,000 cheque not yet presented and a 20,000 deposit not yet credited.
-- Pass: adjusted book 2,88,500, expected statement 2,98,500, items visible.
select app_test.login('cccccccc-1111-4111-8111-cccccccccccc');
set role authenticated;

do $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_branch uuid;
  v_bank   uuid;
  v_income uuid;
  v_exp    uuid;
  v_in     bigint;
  v_line   bigint;
  r        record;
begin
  select id into v_branch from public.branches where dealer_id = v_dealer;
  select id into v_income from public.chart_of_accounts where dealer_id = v_dealer and code = '4800';
  select id into v_exp    from public.chart_of_accounts where dealer_id = v_dealer and code = '5900';

  v_bank := public.create_bank_account('BRS test account', 'Axis Bank', '91702000000077',
                                       'UTIB0000001', 'CURRENT', v_branch, 0);

  select transaction_id into v_in from public.record_bank_transaction(
    v_bank, 'RECEIPT', 250000, 'Cleared receipt', v_income, current_date - 3, 'R1', 'UTR-BRS-1');
  perform public.record_bank_transaction(
    v_bank, 'PAYMENT', 30000, 'Cheque 000451 issued', v_exp, current_date - 2, null, null, '000451');
  perform public.record_bank_transaction(
    v_bank, 'RECEIPT', 20000, 'Cash deposited late', v_income, current_date - 1);

  perform public.import_bank_statement(v_bank, jsonb_build_array(
    jsonb_build_object('statement_date', (current_date - 3)::text, 'narration', 'NEFT CR',
                       'utr', 'UTR-BRS-1', 'debit', 0, 'credit', 250000),
    jsonb_build_object('statement_date', (current_date - 2)::text, 'narration', 'DIRECT DEPOSIT',
                       'debit', 0, 'credit', 50000),
    jsonb_build_object('statement_date', (current_date - 1)::text, 'narration', 'SERVICE CHARGES',
                       'debit', 1500, 'credit', 0)));

  select id into v_line from public.bank_statement_lines where bank_account_id = v_bank and utr = 'UTR-BRS-1';
  perform public.match_bank_line(v_line, v_in);

  select * into r from public.bank_reconciliation_statement(v_bank, current_date, 298500);
  perform app_test.assert_equals(r.book_balance, 240000::numeric, 'test B: book balance 2,40,000');
  perform app_test.assert_equals(r.bank_only_credits, 50000::numeric, 'the direct deposit is a bank-only credit');
  perform app_test.assert_equals(r.bank_only_debits, 1500::numeric, 'the charge is a bank-only debit');
  perform app_test.assert_equals(r.adjusted_book_balance, 288500::numeric, 'adjusted book 2,88,500');
  perform app_test.assert_equals(r.unpresented_payments, 30000::numeric, 'the cheque is unpresented');
  perform app_test.assert_equals(r.deposits_in_transit, 20000::numeric, 'the deposit is in transit');
  perform app_test.assert_equals(r.expected_statement_balance, 298500::numeric, 'expected statement 2,98,500');
  perform app_test.assert_equals(r.unexplained_difference, 0::numeric, 'nothing left unexplained');

  perform app_test.assert_equals(
    (select string_agg(kind, ',' order by kind) from public.bank_reconciliation_items(v_bank, current_date)),
    'BANK_CREDIT,BANK_DEBIT,IN_TRANSIT,UNPRESENTED',
    'each timing difference and bank-only item is listed, not netted away');

  -- Completing it stores the statement, and the difference returned is the
  -- one that needs explaining.
  select * into r from public.complete_bank_reconciliation(
    v_bank, current_date - 30, current_date, 298500, 'Test B');
  perform app_test.assert_equals(r.difference, 0::numeric,
    'a completed reconciliation reports no unexplained difference');
  perform app_test.assert_equals(
    (select unpresented_payments from public.bank_reconciliations where id = r.reconciliation_id),
    30000::numeric, 'and keeps its reconciling items on the record');
  perform app_test.assert_equals(
    (select string_agg(kind, ',' order by kind) from public.bank_reconciliation_items(v_bank, current_date)),
    'BANK_CREDIT,BANK_DEBIT,IN_TRANSIT,UNPRESENTED',
    'timing differences remain visible after completion');
end $$;

-- ═══ Expense lines: blocked credit, and what they may be charged to ════════════
do $$
declare
  v_dealer   uuid := app.current_dealer_id();
  v_branch   uuid;
  v_supplier uuid;
  v_bill     uuid;
  v_entry    uuid;
  v_before   numeric;
begin
  select id into v_branch from public.branches where dealer_id = v_dealer;
  select id into v_supplier from public.suppliers where dealer_id = v_dealer and name = 'Alpha Traders';

  select coalesce(sum(total_tax), 0) into v_before
    from public.gst_input_summary(current_date, current_date);

  insert into public.purchase_bills (dealer_id, branch_id, supplier_id, supplier_bill_number, bill_date)
  values (v_dealer, v_branch, v_supplier, 'AT/STAFF/001', current_date) returning id into v_bill;

  -- A staff lunch: input tax on food is a blocked credit (s.17(5)).
  insert into public.purchase_bill_lines
    (purchase_bill_id, dealer_id, line_number, line_type, account_id, hsn_sac, itc_eligible,
     description, quantity, unit_rate, taxable_value, cgst_rate, sgst_rate, cgst_amount,
     sgst_amount, total_amount)
  values (v_bill, v_dealer, 1, 'EXPENSE',
          (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '5900'),
          '996331', false, 'Staff lunch', 1, 1000, 1000, 2.5, 2.5, 25, 25, 1050);

  v_entry := public.post_purchase_bill(v_bill);

  perform app_test.assert_equals(
    (select debit from public.journal_entry_lines l
       join public.chart_of_accounts c on c.id = l.account_id
      where l.journal_entry_id = v_entry and c.code = '5900'),
    1050::numeric, 'blocked input tax is charged to the expense with it');
  perform app_test.assert_equals(
    (select count(*)::int from public.journal_entry_lines l
       join public.chart_of_accounts c on c.id = l.account_id
      where l.journal_entry_id = v_entry and c.code in ('1900', '1910', '1920')), 0,
    'and never reaches input GST');
  perform app_test.assert_equals(
    (select coalesce(sum(total_tax), 0) from public.gst_input_summary(current_date, current_date)),
    v_before, 'nor the input-tax summary — a blocked credit is not claimed');

  insert into public.purchase_bills (dealer_id, branch_id, supplier_id, supplier_bill_number, bill_date)
  values (v_dealer, v_branch, v_supplier, 'AT/GUARD/001', current_date) returning id into v_bill;

  perform app_test.assert_raises(
    format($q$insert into public.purchase_bill_lines
      (purchase_bill_id, dealer_id, line_number, line_type, account_id, description,
       quantity, unit_rate, taxable_value, total_amount)
      values (%L, %L, 1, 'EXPENSE', (select id from public.chart_of_accounts
        where dealer_id = %L and code = '1600'), 'Stock by the back door', 1, 100, 100, 100)$q$,
      v_bill, v_dealer, v_dealer),
    'an expense line cannot charge an inventory account — stock has its own lines');
  perform app_test.assert_raises(
    format($q$insert into public.purchase_bill_lines
      (purchase_bill_id, dealer_id, line_number, line_type, account_id, description,
       quantity, unit_rate, taxable_value, total_amount)
      values (%L, %L, 1, 'EXPENSE', (select id from public.chart_of_accounts
        where dealer_id = %L and code = '1200'), 'Into the bank', 1, 100, 100, 100)$q$,
      v_bill, v_dealer, v_dealer),
    'nor a bank ledger');
  perform app_test.assert_raises(
    format($q$insert into public.purchase_bill_lines
      (purchase_bill_id, dealer_id, line_number, line_type, account_id, description,
       quantity, unit_rate, taxable_value, total_amount)
      values (%L, %L, 1, 'EXPENSE', (select id from public.chart_of_accounts
        where dealer_id = %L and code = '4800'), 'Income?', 1, 100, 100, 100)$q$,
      v_bill, v_dealer, v_dealer),
    'nor an income account');
  perform app_test.assert_raises(
    format($q$insert into public.purchase_bill_lines
      (purchase_bill_id, dealer_id, line_number, line_type, item_id, source, itc_eligible,
       description, quantity, unit_rate, taxable_value, total_amount)
      values (%L, %L, 1, 'ACCESSORY', (select id from public.inventory_items
        where dealer_id = %L limit 1), 'LOCAL', false, 'Blocked stock', 1, 100, 100, 100)$q$,
      v_bill, v_dealer, v_dealer),
    'blocked credit is an expense-line switch, not a stock one');

  perform app_test.assert_equals(
    (select count(*)::int from public.returnable_purchase_lines(
       (select id from public.purchase_bills where supplier_bill_number = 'AT/COMP/001'))), 0,
    'an expense bill offers nothing to return — it is corrected by cancelling');
end $$;

-- ═══ Stock adjustments reach the ledger (0079) ════════════════════════════════
do $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_branch uuid;
  v_item   uuid;
  v_before int;
begin
  select id into v_branch from public.branches where dealer_id = v_dealer;
  select id into v_item from public.inventory_items where dealer_id = v_dealer and item_code = 'ACC-KIT-01';
  select count(*)::int into v_before from public.journal_entries;

  perform public.adjust_inventory_stock(v_item, v_branch, 'LOCAL', -2, 'Two kits damaged in the store');
  perform public.adjust_inventory_stock(v_item, v_branch, 'LOCAL', 1, 'One found at the recount');

  perform app_test.assert_equals((select count(*)::int from public.journal_entries), v_before + 2,
    'each count adjustment posts its own journal');
  perform app_test.assert_equals(
    (select debit_balance from public.trial_balance(current_date) where account_code = '5970'),
    5000::numeric, 'the net shortage of one kit at 5,000 is charged to Stock Adjustments');
  perform app_test.assert_equals(
    (select difference from public.control_account_tieout(current_date) where control = 'ACCESSORY_STOCK'),
    0::numeric, 'and stock at cost still agrees with account 1600 — no silent stock adjustment');
  perform app_test.assert_equals(
    (select count(*)::int from public.inventory_transactions
      where transaction_type = 'ADJUSTMENT' and dealer_id = v_dealer and reference_id is null), 0,
    'every adjustment movement points at its journal');
end $$;

-- ═══ Walk-in counter sales are paid when they are made (0080) ══════════════════
-- Found on production: a walk-in invoice posted and never paid, leaving a
-- receivable that belongs to nobody.
do $$
declare
  v_dealer  uuid := app.current_dealer_id();
  v_branch  uuid;
  v_item    uuid;
  v_invoice uuid;
  r         record;
begin
  select id into v_branch from public.branches where dealer_id = v_dealer;
  select id into v_item from public.inventory_items where dealer_id = v_dealer and item_code = 'ACC-KIT-01';

  select invoice_id into v_invoice from public.create_counter_invoice(v_branch, null);
  perform public.add_service_line(v_invoice, 'ACCESSORY', 'Accessory kit', 1, 7031.25, v_item, 'GST18');

  -- The rule is checked at commit; made immediate here so the refusal can be seen.
  set constraints service_invoices_walk_in_settled immediate;
  perform app_test.assert_raises(
    format('select public.post_service_invoice(%L)', v_invoice),
    'a walk-in sale cannot be posted and left unpaid');
  set constraints service_invoices_walk_in_settled deferred;

  select * into r from public.settle_counter_invoice(v_invoice, 'CASH', null, 'acpt-walk-in-1');
  perform app_test.assert_equals(r.amount_received, 8296.87::numeric,
    'settling posts the walk-in and takes its whole balance in one step');
  perform app_test.assert_equals(
    (select status || ':' || (total_amount - paid_amount)::numeric(18, 2)
       from public.service_invoices where id = v_invoice),
    'POSTED:0.00', 'the invoice is posted with nothing owed');
  perform app_test.assert_equals(
    (select count(*)::int from public.cash_transactions
      where journal_entry_id = (select sp.journal_entry_id from public.service_payments sp
                                 where sp.invoice_id = v_invoice)), 1,
    'and the cash reached the cash book');
  perform app_test.assert_equals(
    (select (public.settle_counter_invoice(v_invoice, 'CASH', null, 'acpt-walk-in-1')).amount_received),
    0::numeric, 'settling again takes nothing more');
  perform app_test.assert_equals(
    (select difference from public.control_account_tieout(current_date) where account_code = '1300'),
    0::numeric, 'and no receivable is left without a customer');
end $$;

-- ═══ Ageing (0080) ═════════════════════════════════════════════════════════════
do $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_bank   uuid;
  v_cust   uuid;
  v_ar     uuid;
  v_inc    uuid;
  r        record;
begin
  select id into v_bank from public.bank_accounts where dealer_id = v_dealer and name = 'Main current account';
  select id into v_ar  from public.chart_of_accounts where dealer_id = v_dealer and code = '1300';
  select id into v_inc from public.chart_of_accounts where dealer_id = v_dealer and code = '4800';

  -- Test A's customer: one invoice this month, part paid → 81,000 current.
  select * into r from public.party_ageing('CUSTOMER', current_date)
   where party_name = 'Acceptance Customer';
  perform app_test.assert_equals(r.bucket_0_30, 81000::numeric, 'Test A customer: 81,000 in 0–30 days');
  perform app_test.assert_equals(r.balance, 81000::numeric, 'which is the whole balance');

  -- Test A's supplier: 1,18,000 + 5,90,000 billed, 4,00,000 paid unallocated —
  -- 3,08,000 — plus the 1,050 staff-lunch bill posted in the expense-line block.
  select * into r from public.party_ageing('SUPPLIER', current_date)
   where party_name = 'Alpha Traders';
  perform app_test.assert_equals(r.balance, 309050::numeric,
    'Test A supplier: 3,08,000 from the month plus the 1,050 blocked-ITC bill');
  perform app_test.assert_equals(
    (select sum(balance) from public.party_ageing('SUPPLIER', current_date)),
    (select -ledger_balance from public.control_account_tieout(current_date) where account_code = '2200'),
    'and the payables ageing totals to the 2200 control account');
  perform app_test.assert_equals(
    (select count(*)::int from public.party_ageing('SUPPLIER', current_date)
      where party_name = 'Showroom Landlord'), 0,
    'a supplier paid in full does not appear');

  -- An older customer: bills 100 and 45 days ago, a 3,000 receipt with no
  -- allocation, and a 1,500 advance on account.
  insert into public.customers (dealer_id, name, mobile, city, state, state_code)
  values (v_dealer, 'Ageing Customer', '9840044444', 'Chennai', 'Tamil Nadu', '33')
  returning id into v_cust;

  perform public.post_manual_journal(current_date - 100, 'Old service bill',
    jsonb_build_array(
      jsonb_build_object('account_id', v_ar, 'debit', 5000, 'credit', 0, 'party_type', 'CUSTOMER', 'party_id', v_cust),
      jsonb_build_object('account_id', v_inc, 'debit', 0, 'credit', 5000)));
  perform public.post_manual_journal(current_date - 45, 'Later service bill',
    jsonb_build_array(
      jsonb_build_object('account_id', v_ar, 'debit', 10000, 'credit', 0, 'party_type', 'CUSTOMER', 'party_id', v_cust),
      jsonb_build_object('account_id', v_inc, 'debit', 0, 'credit', 10000)));
  perform public.record_bank_transaction(
    p_bank_account_id => v_bank, p_direction => 'RECEIPT', p_amount => 3000,
    p_particular => 'Part payment', p_account_id => v_ar, p_customer_id => v_cust);
  perform public.post_manual_journal(current_date, 'Advance on a future booking',
    jsonb_build_array(
      jsonb_build_object('account_id', (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '5900'),
                         'debit', 1500, 'credit', 0),
      jsonb_build_object('account_id', (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '2100'),
                         'debit', 0, 'credit', 1500, 'party_type', 'CUSTOMER', 'party_id', v_cust)));

  select * into r from public.party_ageing('CUSTOMER', current_date) where party_id = v_cust;
  perform app_test.assert_equals(r.bucket_90_plus, 2000::numeric,
    'an unallocated receipt settles the oldest bill first: 2,000 of it left, over 90 days');
  perform app_test.assert_equals(r.bucket_31_60, 10000::numeric, 'the later bill is untouched, 31–60 days');
  perform app_test.assert_equals(r.balance, 12000::numeric, 'balance 12,000');
  perform app_test.assert_equals(r.advance_held, 1500::numeric,
    'the advance is its own column — never netted into what is owed');
  perform app_test.assert_equals(r.oldest_open_date, current_date - 100, 'and the oldest open bill is named');

  -- As it stood 60 days ago: only the first bill existed, and was unpaid.
  select * into r from public.party_ageing('CUSTOMER', current_date - 60) where party_id = v_cust;
  perform app_test.assert_equals(r.bucket_31_60 + r.bucket_0_30 + r.bucket_61_90 + r.bucket_90_plus,
    5000::numeric, 'an earlier as-on date sees only what existed then');
end $$;

reset role;
select app_test.logout();
