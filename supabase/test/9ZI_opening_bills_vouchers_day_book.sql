-- =============================================================================
-- TEST — bill-wise openings, split vouchers, the day book (0091)
-- =============================================================================
-- Acceptance scenarios from the BUSY requirements review (§8): an opening
-- balance split across bills whose residuals agree with the control account;
-- a receipt settling one of them; a payment split over three heads that is one
-- book row and one balanced journal; replays that post nothing twice.
-- =============================================================================

\echo '--- opening bills, split vouchers, day book ---'

create temporary table fixture_parties as
select (select customer_code from public.customers c join public.dealers d on d.id = c.dealer_id
         where d.code = 'SBM' order by customer_code offset 1 limit 1) as customer_code,
       (select supplier_code from public.suppliers s join public.dealers d on d.id = s.dealer_id
         where d.code = 'SBM' order by supplier_code limit 1) as supplier_code;
grant select on fixture_parties to authenticated;

select app_test.login('22222222-2222-4222-8222-222222222222');
set role authenticated;

-- ── Opening bills ─────────────────────────────────────────────────────────
do $$
declare
  v_dealer   uuid := app.current_dealer_id();
  v_supcode  text := (select supplier_code from fixture_parties);
  v_cuscode  text := (select customer_code from fixture_parties);
  v_supplier uuid := (select id from public.suppliers where supplier_code = (select supplier_code from fixture_parties));
  v_customer uuid := (select id from public.customers where customer_code = (select customer_code from fixture_parties));
  v_payable  uuid := app.require_account(app.current_dealer_id(), 'INVENTORY', 'PURCHASE', 'PAYABLE', null);
  v_before   numeric;
  v_res      record;
  v_again    record;
  v_bill2    uuid;
  v_rcpt     uuid;
  v_main     uuid := (select id from public.branches where dealer_id = app.current_dealer_id() and code = 'MAIN');
  v_recv     uuid := app.require_account(app.current_dealer_id(), 'SALES', 'INVOICE', 'RECEIVABLE', null);
begin
  select coalesce(sum(l.credit - l.debit), 0) into v_before
    from public.journal_entry_lines l join public.journal_entries je on je.id = l.journal_entry_id
   where l.party_type = 'SUPPLIER' and l.party_id = v_supplier and l.account_id = v_payable
     and je.status in ('POSTED', 'REVERSED');

  select * into v_res from public.post_opening_bills('SUPPLIER', jsonb_build_array(
    jsonb_build_object('party_code', v_supcode, 'bill_reference', 'OB-S-1', 'bill_date', '2026-01-10', 'due_date', '2026-02-09', 'amount', 50000),
    jsonb_build_object('party_code', v_supcode, 'bill_reference', 'OB-S-2', 'bill_date', '2026-02-15', 'due_date', '2026-03-17', 'amount', 30000),
    jsonb_build_object('party_code', v_supcode, 'bill_reference', 'OB-S-3', 'bill_date', '2026-03-20', 'amount', 20000)),
    null, 'ob-9zi-1');
  perform app_test.assert_equals(v_res.bills, 3, 'three opening bills are posted');
  perform app_test.assert_equals(v_res.total, 100000::numeric, 'totalling ₹1,00,000');

  perform app_test.assert_equals(
    (select coalesce(sum(l.credit - l.debit), 0) from public.journal_entry_lines l
       join public.journal_entries je on je.id = l.journal_entry_id
      where l.party_type = 'SUPPLIER' and l.party_id = v_supplier and l.account_id = v_payable
        and je.status in ('POSTED', 'REVERSED')) - v_before,
    100000::numeric, 'the supplier control balance rises by exactly the bills');
  perform app_test.assert_equals(
    (select sum(outstanding) from public.party_open_items('SUPPLIER', v_supplier)
      where document_ref like 'OB-S-%'), 100000::numeric,
    'and the open bills'' residuals add up to it');
  perform app_test.assert_equals(
    (select entry_date::text || '|' || age_days::text from public.party_open_items('SUPPLIER', v_supplier)
      where document_ref = 'OB-S-1'),
    '2026-01-10|' || (current_date - date '2026-01-10')::text,
    'each bill carries its own date and ages from it');
  perform app_test.assert_equals(
    (select bucket_90_plus >= 50000 from public.party_ageing('SUPPLIER') where party_id = v_supplier), true,
    'the oldest bill lands in the 90+ bucket of the ageing');

  select * into v_again from public.post_opening_bills('SUPPLIER', jsonb_build_array(
    jsonb_build_object('party_code', v_supcode, 'bill_reference', 'OB-S-1', 'bill_date', '2026-01-10', 'amount', 50000)),
    null, 'ob-9zi-1');
  perform app_test.assert_equals(v_again.journal_entry_id, v_res.journal_entry_id, 'a replay returns the first posting');
  perform app_test.assert_raises(
    format($q$select public.post_opening_bills('SUPPLIER', '[{"party_code":%s,"bill_reference":"OB-S-2","bill_date":"2026-02-15","amount":1}]'::jsonb, null, 'ob-9zi-2')$q$,
      to_jsonb(v_supcode)),
    'a bill number already entered for the party is refused', 'already entered');
  perform app_test.assert_raises(
    format($q$select public.post_opening_bills('SUPPLIER', '[{"party_code":%s,"bill_reference":"OB-S-9","bill_date":"2026-02-15","due_date":"2026-01-01","amount":1}]'::jsonb)$q$,
      to_jsonb(v_supcode)),
    'a bill due before it is dated is refused', 'due before');

  -- Customer bills, one of them settled by a receipt.
  perform public.post_opening_bills('CUSTOMER', jsonb_build_array(
    jsonb_build_object('party_code', v_cuscode, 'bill_reference', 'OB-C-1', 'bill_date', '2026-03-01', 'amount', 8000),
    jsonb_build_object('party_code', v_cuscode, 'bill_reference', 'OB-C-2', 'bill_date', '2026-03-15', 'amount', 5000)),
    null, 'ob-9zi-c');
  select journal_entry_id into v_rcpt from public.record_cash_transaction(
    v_main, 'RECEIPT', 8000, 'Received against OB-C-1', v_recv, v_customer, 'RC-9ZI', current_date, null, 'rc-9zi');
  select l.id into v_rcpt from public.journal_entry_lines l where l.journal_entry_id = v_rcpt and l.party_id = v_customer;
  select line_id into v_bill2 from public.party_open_items('CUSTOMER', v_customer) where document_ref = 'OB-C-1';
  perform public.allocate_party_payment(v_rcpt, jsonb_build_array(jsonb_build_object('debit_line_id', v_bill2, 'amount', 8000)));
  perform app_test.assert_equals(
    (select count(*)::int from public.party_open_items('CUSTOMER', v_customer) where document_ref like 'OB-C-%'), 1,
    'a receipt settles one opening bill and leaves the other open');
end $$;

-- ── A split payment ───────────────────────────────────────────────────────
do $$
declare
  v_main   uuid := (select id from public.branches where dealer_id = app.current_dealer_id() and code = 'MAIN');
  v_util   uuid := (select id from public.chart_of_accounts where dealer_id = app.current_dealer_id() and code = '5700');
  v_other  uuid := (select id from public.chart_of_accounts where dealer_id = app.current_dealer_id() and code = '5900');
  v_rent   uuid := (select id from public.chart_of_accounts where dealer_id = app.current_dealer_id() and code = '5600');
  v_cash   uuid := (select ledger_account_id from public.cash_accounts
                     where branch_id = (select id from public.branches where dealer_id = app.current_dealer_id() and code = 'MAIN'));
  v_rows   int;
  v_res    record;
  v_again  record;
  v_lines  jsonb;
begin
  select count(*)::int into v_rows from public.cash_transactions where branch_id = v_main;
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_util, 'amount', 450, 'narration', 'Electricity'),
    jsonb_build_object('account_id', v_other, 'amount', 120.50, 'narration', 'Tea'),
    jsonb_build_object('account_id', v_rent, 'amount', 2000));
  select * into v_res from public.record_money_voucher('CASH', 'PAYMENT', v_lines, 'Petty cash 9ZI',
    v_main, null, current_date, 'PV-9ZI', null, null, 'mv-9zi');

  perform app_test.assert_equals((select count(*)::int from public.cash_transactions where branch_id = v_main), v_rows + 1,
    'a three-line payment is one cash book row');
  perform app_test.assert_equals((select amount from public.cash_transactions where id = v_res.transaction_id), 2570.50::numeric,
    'for the whole voucher');
  perform app_test.assert_equals(
    (select count(*)::int || '|' || sum(debit)::text || '|' || sum(credit)::text
       from public.journal_entry_lines where journal_entry_id = v_res.journal_entry_id),
    '4|2570.5000|2570.5000', 'and one balanced journal: three heads and the cash');
  perform app_test.assert_equals(
    (select credit from public.journal_entry_lines where journal_entry_id = v_res.journal_entry_id and account_id = v_cash),
    2570.50::numeric, 'cash goes down by the total');

  select * into v_again from public.record_money_voucher('CASH', 'PAYMENT', v_lines, 'Petty cash 9ZI',
    v_main, null, current_date, 'PV-9ZI', null, null, 'mv-9zi');
  perform app_test.assert_equals(v_again.transaction_id, v_res.transaction_id, 'a replay writes nothing new');

  perform app_test.assert_raises(
    format($q$select public.record_money_voucher('CASH', 'PAYMENT', %L::jsonb, 'x cash', %L)$q$,
      jsonb_build_array(jsonb_build_object('account_id', v_cash, 'amount', 10)), v_main),
    'cash on the other side is refused as a contra', 'Contra');
  perform app_test.assert_raises(
    format($q$select public.record_money_voucher('CASH', 'PAYMENT', %L::jsonb, 'x zero', %L)$q$,
      jsonb_build_array(jsonb_build_object('account_id', v_util, 'amount', 0)), v_main),
    'a zero line is refused', 'greater than zero');
end $$;

-- ── The day book ──────────────────────────────────────────────────────────
do $$
declare
  v_dr numeric;
  v_cr numeric;
begin
  select sum(debit), sum(credit) into v_dr, v_cr from public.day_book(current_date);
  perform app_test.assert_equals(v_dr, v_cr, 'the day book balances');
  perform app_test.assert_equals(
    v_dr,
    (select sum(l.debit) from public.journal_entry_lines l join public.journal_entries je on je.id = l.journal_entry_id
      where je.dealer_id = app.current_dealer_id() and je.entry_date = current_date and je.status in ('POSTED', 'REVERSED')),
    'and totals the day''s posted movement');
  perform app_test.assert_equals(
    (select count(distinct entry_id)::int from public.day_book(current_date) where document_ref = 'PV-9ZI'), 1,
    'a voucher shows under its own number');
  perform app_test.assert_equals(
    (select sum(debit_balance) - sum(credit_balance) from public.trial_balance(current_date)), 0::numeric,
    'the trial balance still nets to nil');
end $$;

-- ── Narration templates ───────────────────────────────────────────────────
do $$
begin
  insert into public.narration_templates (dealer_id, voucher_type, text)
  values (app.current_dealer_id(), 'PAYMENT', 'Being petty expenses paid in cash');
  perform app_test.assert_raises(
    format($q$insert into public.narration_templates (dealer_id, voucher_type, text) values (%L, 'PAYMENT', 'Being petty expenses paid in cash')$q$,
      app.current_dealer_id()),
    'a template is not entered twice');
end $$;

reset role;
select app_test.logout();

-- ── The cashier ───────────────────────────────────────────────────────────
select app_test.login('33333333-3333-4333-8333-333333333333');
set role authenticated;
do $$
begin
  perform app_test.assert_raises(
    format($q$select public.post_opening_bills('SUPPLIER', '[{"party_code":%s,"bill_reference":"X","bill_date":"2026-01-01","amount":1}]'::jsonb)$q$,
      to_jsonb((select supplier_code from fixture_parties))),
    'a cashier cannot post opening bills', 'accountant');
  perform app_test.assert_raises(
    $q$insert into public.narration_templates (dealer_id, voucher_type, text) values (app.current_dealer_id(), 'ANY', 'mine')$q$,
    'nor add narration templates');
  perform app_test.assert_equals(
    (select count(*)::int from public.narration_templates) > 0, true, 'but can pick from them');
end $$;
reset role;
select app_test.logout();
