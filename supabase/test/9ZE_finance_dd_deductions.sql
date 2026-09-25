-- =============================================================================
-- TEST — finance DD with deductions, and journals that name the party (0087)
-- =============================================================================
-- A financed sale: the DD arrives short by the financier's document charges
-- (recovered from the customer) and a freight charge (the dealer's cost). The
-- finance company must end owing nothing, the customer must owe the charges,
-- and every line must name a party of this dealer's.
-- =============================================================================

\echo '--- finance DD with deductions ---'

select app_test.login('11111111-1111-4111-8111-111111111111');
set role authenticated;

do $$
declare
  v_dealer   uuid := app.current_dealer_id();
  v_branch   uuid;
  v_customer uuid;
  v_company  uuid;
  v_bank     uuid;
  v_app      uuid;
  v_entry    uuid;
  v_again    uuid;
  v_bank_rows int;
  r          record;
  acc        record;
begin
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_bank from public.bank_accounts where dealer_id = v_dealer and status = 'ACTIVE' limit 1;
  select (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '1300') as recv,
         (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '1400') as fin,
         (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '4100') as sales
    into acc;

  insert into public.customers (dealer_id, name, mobile, city, state, state_code)
  values (v_dealer, 'DD Test Customer', '9840097555', 'Chennai', 'Tamil Nadu', '33')
  returning id into v_customer;
  insert into public.finance_companies (dealer_id, code, name)
  values (v_dealer, 'CHOLADD', 'Cholamandalam (DD test)')
  returning id into v_company;

  select application_id into v_app from public.create_finance_application(
    v_branch, v_customer, v_company, 100000, 20000);
  perform public.decide_finance_application(v_app, 'APPROVED', 100000);

  -- The sale and its finance part, as the accountant would tally them by hand:
  -- customer Dr / sales Cr, then finance company Dr / customer Cr for the loan.
  perform public.post_manual_journal(current_date, 'DD test: vehicle sold on finance', jsonb_build_array(
    jsonb_build_object('account_id', acc.recv, 'debit', 120000, 'credit', 0, 'party_type', 'CUSTOMER', 'party_id', v_customer),
    jsonb_build_object('account_id', acc.sales, 'debit', 0, 'credit', 120000)));
  perform public.post_manual_journal(current_date, 'DD test: loan moved to the financier', jsonb_build_array(
    jsonb_build_object('account_id', acc.fin, 'debit', 100000, 'credit', 0, 'party_type', 'FINANCE_COMPANY', 'party_id', v_company),
    jsonb_build_object('account_id', acc.recv, 'debit', 0, 'credit', 100000, 'party_type', 'CUSTOMER', 'party_id', v_customer)));

  -- ── Parties must be this dealer's ────────────────────────────────────────
  perform app_test.assert_raises(
    format($q$select public.post_manual_journal(current_date, 'bad party', jsonb_build_array(
      jsonb_build_object('account_id', %L::uuid, 'debit', 10, 'credit', 0, 'party_type', 'CUSTOMER', 'party_id', gen_random_uuid()),
      jsonb_build_object('account_id', %L::uuid, 'debit', 0, 'credit', 10)))$q$, acc.recv, acc.sales),
    'a journal line cannot name a customer that does not exist');
  perform app_test.assert_raises(
    format($q$select public.post_manual_journal(current_date, 'foreign party', jsonb_build_array(
      jsonb_build_object('account_id', %L::uuid, 'debit', 10, 'credit', 0, 'party_type', 'CUSTOMER',
        'party_id', (select id from public.customers where name = 'Acceptance Customer')),
      jsonb_build_object('account_id', %L::uuid, 'debit', 0, 'credit', 10)))$q$, acc.recv, acc.sales),
    'nor another dealer''s customer');

  -- ── The DD: 97,500, less 2,000 document charges (customer) and 500 freight (dealer)
  select count(*)::int into v_bank_rows from public.bank_transactions where bank_account_id = v_bank;
  v_entry := public.receive_finance_dd(v_app, v_bank, 97500, jsonb_build_array(
    jsonb_build_object('kind', 'DOCUMENT_CHARGES', 'amount', 2000, 'borne_by', 'CUSTOMER'),
    jsonb_build_object('kind', 'FREIGHT', 'amount', 500, 'borne_by', 'DEALER')),
    'DD-445566', null, current_date, 'dd-test-1');

  perform app_test.assert_equals(
    (select string_agg(c.code || case when l.debit > 0 then ' Dr ' || l.debit::numeric(18, 0) else ' Cr ' || l.credit::numeric(18, 0) end
                       || coalesce(' ' || lower(l.party_type), ''), ', ' order by l.line_number)
       from public.journal_entry_lines l join public.chart_of_accounts c on c.id = l.account_id
      where l.journal_entry_id = v_entry and c.code <> (select code from public.chart_of_accounts where id =
            (select ledger_account_id from public.bank_accounts where id = v_bank))),
    '1300 Dr 2000 customer, 5930 Dr 500, 1400 Cr 100000 finance_company',
    'document charges to the customer, freight to expense, the financier cleared by the whole 1,00,000');
  perform app_test.assert_equals(
    (select debit from public.journal_entry_lines where journal_entry_id = v_entry and line_number = 1), 97500::numeric,
    'and the bank receives the DD of 97,500');

  perform app_test.assert_equals(
    (select coalesce(sum(debit - credit), 0) from public.journal_entry_lines
      where party_type = 'FINANCE_COMPANY' and party_id = v_company), 0::numeric,
    'the finance company owes nothing more');
  perform app_test.assert_equals(
    (select coalesce(sum(debit - credit), 0) from public.journal_entry_lines
      where party_type = 'CUSTOMER' and party_id = v_customer), 22000::numeric,
    'the customer owes the down payment 20,000 plus the 2,000 document charges');

  select * into r from public.finance_applications where id = v_app;
  perform app_test.assert_equals(r.pending_amount || '/' || r.deductions_amount || '/' || r.disbursement_status || '/' || r.dd_number,
    '0.0000/2500.0000/DISBURSED/DD-445566', 'the application is settled, with 2,500 deducted');
  perform app_test.assert_equals(
    (select string_agg(transaction_type || ' ' || debit::numeric(18, 0), ', ' order by debit desc)
       from public.finance_transactions where application_id = v_app),
    'DISBURSEMENT 97500, DEDUCTION 2000, DEDUCTION 500', 'the company ledger shows the DD and each deduction');
  perform app_test.assert_equals(
    (select count(*)::int from public.bank_transactions where bank_account_id = v_bank) - v_bank_rows, 1,
    'the bank book shows the DD once');

  -- ── Repeats and over-settlement ──────────────────────────────────────────
  v_again := public.receive_finance_dd(v_app, v_bank, 97500, '[]'::jsonb, 'DD-445566', null, current_date, 'dd-test-1');
  perform app_test.assert_equals(v_again, v_entry, 'a repeated submission returns the same entry');
  perform app_test.assert_equals(
    (select count(*)::int from public.bank_transactions where bank_account_id = v_bank) - v_bank_rows, 1,
    'and writes no second bank row');
  perform app_test.assert_raises(
    format($q$select public.receive_finance_dd(%L, %L, 1, '[]'::jsonb)$q$, v_app, v_bank),
    'nothing more can be received on a settled application');
  perform app_test.assert_raises(
    format($q$select public.receive_finance_dd(%L, %L, 10, '[{"kind":"FREIGHT","amount":5}]'::jsonb)$q$, v_app, v_bank),
    'a deduction must say who bears it');

  perform app_test.assert_equals(
    (select sum(debit_balance) - sum(credit_balance) from public.trial_balance(current_date)), 0::numeric,
    'the trial balance still balances');
end $$;

reset role;
select app_test.logout();
