-- =============================================================================
-- TEST — ledger integrity (0076, 0077)
-- =============================================================================
-- Accounting audit checklist §01 (P0): invalid voucher rejection, account
-- types, closed period, orphans and atomicity; §03 chart of accounts; §05
-- bank/cash ledgers and contra.
--
-- Every refusal below is a way the ledger could previously be made to disagree
-- with its own reports. The first was reproduced before 0076: a journal to the
-- "1000 Assets" heading posted, and the trial balance went out by its amount.
-- =============================================================================

\echo '--- ledger integrity ---'

select app_test.login('11111111-1111-4111-8111-111111111111');

do $$
declare
  v_dealer   uuid;
  v_branch   uuid;
  v_group    uuid;
  v_exp      uuid;
  v_payable  uuid;
  v_cash     uuid;
  v_bank_ldg uuid;
  v_income   uuid;
  v_new      uuid;
  v_parent   uuid;
  v_bank     uuid;
  v_bank2    uuid;
  v_journals bigint;
  v_lines    bigint;
  r          record;
  v_count    int;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_group   from public.chart_of_accounts where dealer_id = v_dealer and code = '1000';
  select id into v_exp     from public.chart_of_accounts where dealer_id = v_dealer and code = '5800';
  select id into v_payable from public.chart_of_accounts where dealer_id = v_dealer and code = '2700';
  select id into v_cash    from public.chart_of_accounts where dealer_id = v_dealer and code = '1100';
  select id into v_bank_ldg from public.chart_of_accounts where dealer_id = v_dealer and code = '1200';
  select id into v_income  from public.chart_of_accounts where dealer_id = v_dealer and code = '4800';

  select count(*) into v_journals from public.journal_entries;
  select count(*) into v_lines from public.journal_entry_lines;

  -- ══ Invalid vouchers are refused, whole ══════════════════════════════════
  perform app_test.assert_raises(
    format($q$select public.post_manual_journal(current_date, 'To a heading',
      jsonb_build_array(
        jsonb_build_object('account_id', %L, 'debit', 999, 'credit', 0),
        jsonb_build_object('account_id', %L, 'debit', 0, 'credit', 999)))$q$, v_group, v_payable),
    'a line on a group heading is refused (it would vanish from the trial balance)');

  perform app_test.assert_raises(
    format($q$select public.record_cash_transaction(%L, 'RECEIPT', 100, 'To a heading',
      (select id from public.chart_of_accounts where dealer_id = %L and code = '4000'))$q$,
      v_branch, v_dealer),
    'and so is a cash receipt to a heading — every caller meets the rule, not just the journal screen');

  perform app_test.assert_raises(
    format($q$select public.post_manual_journal(current_date, 'Negative',
      jsonb_build_array(
        jsonb_build_object('account_id', %L, 'debit', -100, 'credit', 0),
        jsonb_build_object('account_id', %L, 'debit', 0, 'credit', -100)))$q$, v_exp, v_payable),
    'a negative amount is refused');

  perform app_test.assert_raises(
    format($q$select public.post_manual_journal(current_date, 'Both sides',
      jsonb_build_array(
        jsonb_build_object('account_id', %L, 'debit', 100, 'credit', 100),
        jsonb_build_object('account_id', %L, 'debit', 0, 'credit', 0)))$q$, v_exp, v_payable),
    'a two-sided or empty line is refused');

  perform app_test.assert_raises(
    format($q$select public.post_manual_journal(current_date, 'Not a number',
      jsonb_build_array(
        jsonb_build_object('account_id', %L, 'debit', 'ten', 'credit', 0),
        jsonb_build_object('account_id', %L, 'debit', 0, 'credit', 10)))$q$, v_exp, v_payable),
    'a non-numeric amount is refused');

  perform app_test.assert_raises(
    format($q$select public.post_manual_journal(current_date, 'Missing account',
      jsonb_build_array(
        jsonb_build_object('debit', 100, 'credit', 0),
        jsonb_build_object('account_id', %L, 'debit', 0, 'credit', 100)))$q$, v_payable),
    'a line with no account is refused');

  -- Mid-post failure: two good lines, a bad third. Nothing may be left behind.
  perform app_test.assert_raises(
    format($q$select public.post_manual_journal(current_date, 'Fails on the last line',
      jsonb_build_array(
        jsonb_build_object('account_id', %L, 'debit', 100, 'credit', 0),
        jsonb_build_object('account_id', %L, 'debit', 0, 'credit', 50),
        jsonb_build_object('account_id', %L, 'debit', 0, 'credit', 50)))$q$, v_exp, v_payable, v_group),
    'a voucher failing on its last line is refused');

  perform app_test.assert_equals(
    (select count(*) from public.journal_entries), v_journals,
    'no journal header survives any refused voucher (atomicity)');
  perform app_test.assert_equals(
    (select count(*) from public.journal_entry_lines), v_lines,
    'and no orphan line either');

  -- ══ Inactive accounts ════════════════════════════════════════════════════
  select id into v_parent from public.chart_of_accounts where dealer_id = v_dealer and code = '5000';
  v_new := public.create_account('5991', 'Audit test expense', 'EXPENSE', v_parent);

  perform app_test.assert_equals(
    (select normal_balance from public.chart_of_accounts where id = v_new), 'DEBIT',
    'a new expense account is debit-normal without being told');

  perform public.set_account_status(v_new, 'INACTIVE');
  perform app_test.assert_raises(
    format($q$select public.post_manual_journal(current_date, 'To inactive',
      jsonb_build_array(
        jsonb_build_object('account_id', %L, 'debit', 10, 'credit', 0),
        jsonb_build_object('account_id', %L, 'debit', 0, 'credit', 10)))$q$, v_new, v_payable),
    'posting to an inactive account is refused');
  perform public.set_account_status(v_new, 'ACTIVE');

  select * into r from public.post_manual_journal(current_date, 'Audit test posting',
    jsonb_build_array(
      jsonb_build_object('account_id', v_new, 'debit', 40, 'credit', 0),
      jsonb_build_object('account_id', v_payable, 'debit', 0, 'credit', 40)));

  perform app_test.assert_raises(
    format($q$select public.set_account_status(%L, 'INACTIVE')$q$, v_new),
    'an account carrying a balance cannot be deactivated (its money would leave the reports)');

  perform public.reverse_journal_entry(r.journal_entry_id, 'Test posting');
  perform public.set_account_status(v_new, 'INACTIVE');
  perform app_test.assert_equals(
    (select count(*)::int from public.account_balances(date '1900-01-01', current_date)
      where account_id = v_new), 1,
    'once cleared it can be, and its history stays in account_balances');

  -- ══ The chart cannot be changed under posted lines ═══════════════════════
  perform app_test.assert_raises(
    format('update public.chart_of_accounts set account_type = ''ASSET'', normal_balance = ''DEBIT'', parent_id = null where id = %L', v_income),
    'a used account cannot change type');
  perform app_test.assert_raises(
    format('update public.chart_of_accounts set is_group = true where id = %L', v_exp),
    'a used account cannot become a heading');
  perform app_test.assert_raises(
    format('delete from public.chart_of_accounts where id = %L', v_exp),
    'a used account cannot be deleted');
  perform app_test.assert_raises(
    format($q$select public.create_account('5991', 'Under a leaf', 'EXPENSE', %L)$q$, v_exp),
    'nothing can sit beneath a postable account');
  perform app_test.assert_raises(
    format($q$select public.create_account('5992', 'Wrong family', 'INCOME', %L)$q$, v_parent),
    'an income account cannot sit under the expenses heading');
  perform app_test.assert_raises(
    $q$select public.create_account('5800', 'Duplicate', 'EXPENSE')$q$,
    'an account code is used once');

  -- The standard accounts 0076 adds are there, typed correctly.
  perform app_test.assert_equals(
    (select string_agg(code || ':' || account_type, ',' order by code)
       from public.chart_of_accounts
      where dealer_id = v_dealer and code in ('1951', '1959', '2800', '3400', '5950', '5960')),
    '1951:ASSET,1959:ASSET,2800:LIABILITY,3400:EQUITY,5950:EXPENSE,5960:EXPENSE',
    'fixed assets, accumulated depreciation, loans, drawings, depreciation and interest exist');
  perform app_test.assert_equals(
    (select count(*)::int from public.chart_of_accounts
      where dealer_id = v_dealer and account_subtype = 'COST_OF_SALES'), 4,
    'and the four COGS accounts are marked cost of sales');

  -- ══ Cash and bank move with their books ══════════════════════════════════
  select id into v_bank from public.bank_accounts where dealer_id = v_dealer and status = 'ACTIVE'
   order by created_at limit 1;

  perform app_test.assert_raises(
    format($q$select public.record_bank_transaction(%L, 'RECEIPT', 500, 'Cash deposited', %L)$q$,
           v_bank, v_cash),
    'a bank entry whose counter account is cash is refused — that is a contra');

  select * into r from public.record_contra('CASH', v_branch, 'BANK', v_bank, 500, current_date,
                                            'DEP-001', null, 'contra-key-1');

  perform app_test.assert_equals(
    (select count(*)::int from public.journal_entry_lines where journal_entry_id = r.journal_entry_id), 2,
    'a contra is one journal of two lines');
  perform app_test.assert_equals(
    (select direction from public.cash_transactions where journal_entry_id = r.journal_entry_id),
    'PAYMENT', 'the cash book pays it out');
  perform app_test.assert_equals(
    (select direction from public.bank_transactions where journal_entry_id = r.journal_entry_id),
    'RECEIPT', 'and the bank book receives it — both books move');
  perform app_test.assert_equals(
    (select je.source_document_type from public.journal_entries je where je.id = r.journal_entry_id),
    'CONTRA', 'recorded as a contra, not income');

  perform app_test.assert_equals(
    (select journal_entry_id from public.record_contra('CASH', v_branch, 'BANK', v_bank, 500,
       current_date, 'DEP-001', null, 'contra-key-1')),
    r.journal_entry_id, 'a retried contra returns the first one');
  perform app_test.assert_equals(
    (select count(*)::int from public.bank_transactions where journal_entry_id = r.journal_entry_id), 1,
    'and writes no second book row');

  v_bank2 := public.create_bank_account('Second current', 'ICICI Bank', '000405012345', 'ICIC0000004',
                                        'CURRENT', null, 0);
  select * into r from public.record_contra('BANK', v_bank, 'BANK', v_bank2, 200);
  perform app_test.assert_equals(
    (select sum(case when direction = 'RECEIPT' then amount else -amount end)
       from public.bank_transactions where journal_entry_id = r.journal_entry_id),
    0::numeric, 'bank to bank pays out of one and into the other');
  perform app_test.assert_raises(
    format($q$select public.record_contra('BANK', %L, 'BANK', %L, 10)$q$, v_bank, v_bank),
    'a contra to the same account is refused');

  -- ══ The books still balance after all of it ══════════════════════════════
  perform app_test.assert_equals(
    (select sum(debit_balance) = sum(credit_balance) from public.trial_balance(current_date)), true,
    'the trial balance balances');
end $$;

-- ══ The lock date ══════════════════════════════════════════════════════════
do $$
declare
  v_dealer  uuid;
  v_exp     uuid;
  v_payable uuid;
  r         record;
  v_rows    int;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_exp     from public.chart_of_accounts where dealer_id = v_dealer and code = '5800';
  select id into v_payable from public.chart_of_accounts where dealer_id = v_dealer and code = '2700';

  -- A journal from before the lock, to try reversing into it later.
  select * into r from public.post_manual_journal(current_date - 5, 'Before the lock',
    jsonb_build_array(
      jsonb_build_object('account_id', v_exp, 'debit', 75, 'credit', 0),
      jsonb_build_object('account_id', v_payable, 'debit', 0, 'credit', 75)));

  perform app_test.assert_raises(
    $q$select public.set_books_lock(current_date - 1, '')$q$,
    'locking needs a reason');
  perform app_test.assert_raises(
    $q$select public.set_books_lock(current_date, 'Too soon')$q$,
    'today cannot be locked while it is being traded');

  perform public.set_books_lock(current_date - 1, 'August GST return filed');

  perform app_test.assert_raises(
    format($q$select public.post_manual_journal(current_date - 1, 'Backdated',
      jsonb_build_array(
        jsonb_build_object('account_id', %L, 'debit', 10, 'credit', 0),
        jsonb_build_object('account_id', %L, 'debit', 0, 'credit', 10)))$q$, v_exp, v_payable),
    'a journal dated into the locked period is refused');
  perform app_test.assert_raises(
    format($q$select public.reverse_journal_entry(%L, 'Backdated fix', current_date - 1)$q$, r.journal_entry_id),
    'and so is a reversal dated into it');

  perform public.reverse_journal_entry(r.journal_entry_id, 'Corrected after the lock', current_date);
  perform app_test.assert_equals(
    (select status from public.journal_entries where id = r.journal_entry_id), 'REVERSED',
    'a locked-period entry is corrected by a reversal dated today');

  perform public.set_books_lock(null, 'Reopened to post the auditor''s adjustment');
  perform app_test.assert_equals(app.books_locked_through(v_dealer), null::date,
    'reopening is possible, with a reason');

  select count(*)::int into v_rows from public.accounting_locks where dealer_id = v_dealer;
  perform app_test.assert_equals(v_rows, 2, 'and both moves are kept');
  perform app_test.assert_equals(
    (select count(*)::int from public.audit_logs where entity_type = 'accounting_locks' and dealer_id = v_dealer),
    2, 'and audited');

  perform app_test.assert_raises(
    format('update public.accounting_locks set reason = ''rewritten'' where dealer_id = %L', v_dealer),
    'the lock history cannot be rewritten');
  perform app_test.assert_raises(
    format('delete from public.accounting_locks where dealer_id = %L', v_dealer),
    'or deleted');
end $$;

-- Someone without accounting.periods.manage cannot move it.
select app_test.login('33333333-3333-4333-8333-333333333333');
do $$
begin
  perform app_test.assert_raises(
    $q$select public.set_books_lock(current_date - 1, 'Cashier trying')$q$,
    'a cashier cannot lock or reopen the books');
  perform app_test.assert_raises(
    $q$select public.create_account('5993', 'Cashier account', 'EXPENSE')$q$,
    'or add to the chart of accounts');
end $$;

-- ══ Stock movements work as the application runs them (0079) ══════════════════
-- Before 0079 these read the stock lot with SELECT … FOR UPDATE, which RLS
-- empties for a table with no UPDATE policy: run as the app runs, every
-- transfer and every stock decrease was refused as "Only 0 in stock".
select app_test.login('11111111-1111-4111-8111-111111111111');
set role authenticated;

do $$
declare
  v_item  uuid;
  v_main  uuid;
  v_other uuid;
  v_qty   numeric;
begin
  select id into v_item from public.inventory_items where item_code = 'AC-HELM-01';
  select id into v_main from public.branches where code = 'MAIN';
  select id into v_other from public.branches where code <> 'MAIN' order by code limit 1;

  perform public.transfer_inventory_stock(v_item, v_main, v_other, 1, 'COMPANY', 'Branch needs one');
  select quantity into v_qty from public.inventory_stock
   where item_id = v_item and branch_id = v_other and source = 'COMPANY';
  perform app_test.assert_equals(v_qty, 1::numeric,
    'a branch transfer succeeds under RLS, as the application runs it');

  perform public.adjust_inventory_stock(v_item, v_other, 'COMPANY', -1, 'Damaged in transit');
  select quantity into v_qty from public.inventory_stock
   where item_id = v_item and branch_id = v_other and source = 'COMPANY';
  perform app_test.assert_equals(v_qty, 0::numeric,
    'and so does a stock decrease');

  perform app_test.assert_raises(
    format($q$select public.transfer_inventory_stock(%L, %L, %L, 999, 'COMPANY')$q$, v_item, v_main, v_other),
    'while a transfer of more than is there is still refused');
end $$;

reset role;
select app_test.logout();
