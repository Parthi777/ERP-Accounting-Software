-- =============================================================================
-- TEST — ledger master, ledger groups, ledger modify, financial years (0090)
-- =============================================================================
-- The BUSY way of working: every ledger sits under a group, can be opened and
-- modified, carries an opening balance, and the accountant creates and closes
-- financial years.
-- =============================================================================

\echo '--- ledger master, groups, financial years ---'

-- A customer with a mobile, read here so the probes need no customer access.
create temporary table fixture_party as
select c.id, c.mobile, c.name from public.customers c join public.dealers d on d.id = c.dealer_id
 where d.code = 'SBM' and c.mobile is not null
 order by c.customer_code limit 1;
grant select on fixture_party to authenticated;

-- ── Groups ─────────────────────────────────────────────────────────────────
do $$
declare
  v_dealer uuid := (select id from public.dealers where code = 'SBM');
begin
  perform app_test.assert_equals(
    (select count(*)::int from public.chart_of_accounts
      where dealer_id = v_dealer and is_group and code in ('1001','1002','1003','1004','1005','2001','2002','2003',
                                                            '2004','3001','3002','4001','4002','4003','5001','5002','5003')),
    17, 'the seventeen ledger groups exist');
  perform app_test.assert_equals(
    (select g.code from public.chart_of_accounts a join public.chart_of_accounts g on g.id = a.parent_id
      where a.dealer_id = v_dealer and a.code = '1300'), '1003',
    'Customer Receivable sits under Sundry Debtors');
  perform app_test.assert_equals(
    (select g.code from public.chart_of_accounts a join public.chart_of_accounts g on g.id = a.parent_id
      where a.dealer_id = v_dealer and a.code = '2300'), '2003',
    'Output CGST sits under Duties & Taxes');
  perform app_test.assert_equals(
    (select g.code from public.chart_of_accounts a join public.chart_of_accounts g on g.id = a.parent_id
      where a.dealer_id = v_dealer and a.code = '5600'), '5003',
    'Rent sits under Indirect Expenses');
  perform app_test.assert_equals(
    (select g.code from public.chart_of_accounts a join public.chart_of_accounts g on g.id = a.parent_id
      where a.dealer_id = v_dealer and a.code = '1951'), '1950',
    'a ledger already in a group of its own (Fixed Assets) is left there');
  perform app_test.assert_equals(
    (select count(*)::int from public.chart_of_accounts a join public.chart_of_accounts h on h.id = a.parent_id
      where a.dealer_id = v_dealer and not a.is_group and a.is_system and h.parent_id is null),
    0, 'no standard ledger is left directly under a type heading');
  perform app_test.assert_equals(app.seed_ledger_groups(v_dealer), 0, 'seeding the groups again adds nothing');
end $$;

-- ── Modifying a ledger (accountant) ────────────────────────────────────────
select app_test.login('22222222-2222-4222-8222-222222222222');
set role authenticated;

do $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_rent   uuid := (select id from public.chart_of_accounts where dealer_id = app.current_dealer_id() and code = '5600');
  v_direct uuid := (select id from public.chart_of_accounts where dealer_id = app.current_dealer_id() and code = '5002');
  v_indir  uuid := (select id from public.chart_of_accounts where dealer_id = app.current_dealer_id() and code = '5003');
  v_duties uuid := (select id from public.chart_of_accounts where dealer_id = app.current_dealer_id() and code = '2003');
  v_exp    uuid := (select id from public.chart_of_accounts where dealer_id = app.current_dealer_id() and code = '5000');
  v_new    uuid;
  v_sub    uuid;
begin
  perform public.update_account(v_rent, 'Shop Rent', '5600', v_direct, 'RENT');
  perform app_test.assert_equals(
    (select name || '|' || coalesce(alias, '') || '|' || parent_id::text from public.chart_of_accounts where id = v_rent),
    'Shop Rent|RENT|' || v_direct::text, 'a ledger is renamed, given an alias and moved to another group');
  perform app_test.assert_equals(
    (select count(*)::int from public.audit_logs where entity_id = v_rent::text and action = 'UPDATE') > 0, true,
    'and the change is audited');
  perform public.update_account(v_rent, 'Rent', '5600', v_indir, null);

  perform app_test.assert_raises(
    format($q$select public.update_account(%L, 'Rent', '5601', %L, null)$q$, v_rent, v_indir),
    'a system ledger keeps its code', 'system ledger');
  perform app_test.assert_raises(
    format($q$select public.update_account(%L, 'Rent', '5600', %L, null)$q$, v_rent, v_duties),
    'a ledger cannot move to a group of another type');
  perform app_test.assert_raises(
    format($q$select public.update_account(%L, 'Costs', '5000', %L, null)$q$, v_exp, v_indir),
    'a top heading stays at the top', 'top heading');

  -- A sub-group, a ledger in it, and a group that may not go beneath itself.
  v_sub := public.create_account('5004', 'Showroom Expenses', 'EXPENSE', v_indir, true, null);
  v_new := public.create_account('5601', 'Showroom Upkeep', 'EXPENSE', v_sub, false, null);
  perform app_test.assert_raises(
    format($q$select public.update_account(%L, 'Indirect Expenses', '5003', %L, null)$q$, v_indir, v_sub),
    'a group cannot move beneath its own sub-group', 'beneath itself');
  perform public.update_account(v_new, 'Showroom Maintenance', '5602', v_sub, 'UPKEEP');
  perform app_test.assert_equals((select code from public.chart_of_accounts where id = v_new), '5602',
    'a ledger the accountant made can change its code');
  perform app_test.assert_raises(
    format($q$select public.update_account(%L, 'Showroom Maintenance', '5600', %L, null)$q$, v_new, v_sub),
    'but not to a code in use', 'already in use');
end $$;

-- ── Opening balances ───────────────────────────────────────────────────────
do $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_loan   uuid := (select id from public.chart_of_accounts where dealer_id = app.current_dealer_id() and code = '2800');
  v_cash   uuid := (select id from public.chart_of_accounts where dealer_id = app.current_dealer_id() and code = '1100');
  v_recv   uuid := (select id from public.chart_of_accounts where dealer_id = app.current_dealer_id() and code = '1300');
  v_stock  uuid := (select id from public.chart_of_accounts where dealer_id = app.current_dealer_id() and code = '1500');
  v_equity uuid := (select id from public.chart_of_accounts where dealer_id = app.current_dealer_id() and code = '3300');
  v_group  uuid := (select id from public.chart_of_accounts where dealer_id = app.current_dealer_id() and code = '2004');
  v_cust   uuid := (select id from fixture_party);
  v_entry  uuid;
  v_before int;
begin
  v_entry := public.set_ledger_opening_balance('ACCOUNT', v_loan, 50000, 'CR');
  perform app_test.assert_equals(public.ledger_opening_entered('ACCOUNT', v_loan), -50000::numeric,
    'a ledger takes an opening balance, Cr');
  perform app_test.assert_equals(
    (select entry_date from public.journal_entries where id = v_entry), app.opening_date(v_dealer),
    'dated the day before the first financial year');

  select count(*)::int into v_before from public.journal_entries where source_document_type = 'OPENING_BALANCE';
  v_entry := public.set_ledger_opening_balance('ACCOUNT', v_loan, 60000, 'CR');
  perform app_test.assert_equals(
    (select sum(credit) from public.journal_entry_lines where journal_entry_id = v_entry and account_id = v_loan),
    10000::numeric, 'changing it posts only the difference');
  perform app_test.assert_equals(public.ledger_opening_entered('ACCOUNT', v_loan), -60000::numeric,
    'and the opening is now the new figure');
  perform app_test.assert_equals(public.set_ledger_opening_balance('ACCOUNT', v_loan, 60000, 'CR') is null, true,
    'setting the same figure again posts nothing');
  perform app_test.assert_equals(
    (select count(*)::int from public.journal_entries where source_document_type = 'OPENING_BALANCE'), v_before + 1,
    'one journal for the change, none for the repeat');

  v_entry := public.set_ledger_opening_balance('CUSTOMER', v_cust, 1200, 'DR');
  perform app_test.assert_equals(
    (select account_id::text || '|' || party_type from public.journal_entry_lines
      where journal_entry_id = v_entry and party_id = v_cust),
    v_recv::text || '|CUSTOMER', 'a customer''s opening lands on the receivable, tagged with the customer');
  perform public.set_ledger_opening_balance('CUSTOMER', v_cust, 0, 'DR');
  perform app_test.assert_equals(public.ledger_opening_entered('CUSTOMER', v_cust), 0::numeric,
    'and can be set back to nil');

  perform app_test.assert_raises(
    format($q$select public.set_ledger_opening_balance('ACCOUNT', %L, 100, 'DR')$q$, v_cash),
    'a cash ledger takes its opening on the cash account', 'cash or bank');
  perform app_test.assert_raises(
    format($q$select public.set_ledger_opening_balance('ACCOUNT', %L, 100, 'DR')$q$, v_recv),
    'a control ledger takes its opening from its parties', 'control ledger');
  perform app_test.assert_raises(
    format($q$select public.set_ledger_opening_balance('ACCOUNT', %L, 100, 'DR')$q$, v_stock),
    'a stock ledger takes its opening from the stock upload', 'stock ledger');
  perform app_test.assert_raises(
    format($q$select public.set_ledger_opening_balance('ACCOUNT', %L, 100, 'DR')$q$, v_equity),
    'Opening Balance Equity takes none of its own');
  perform app_test.assert_raises(
    format($q$select public.set_ledger_opening_balance('ACCOUNT', %L, 100, 'DR')$q$, v_group),
    'a group takes no opening balance', 'not a group');
  perform app_test.assert_raises(
    format($q$select public.set_ledger_opening_balance('ACCOUNT', %L, 100, 'XX')$q$, v_loan),
    'an opening balance is Dr or Cr');

  perform app_test.assert_equals(
    (select sum(debit_balance) - sum(credit_balance) from public.trial_balance(current_date)), 0::numeric,
    'the trial balance still nets to nil');
end $$;

-- ── The ledger master ──────────────────────────────────────────────────────
do $$
declare
  v_loan  uuid := (select id from public.chart_of_accounts where dealer_id = app.current_dealer_id() and code = '2800');
  v_recv  uuid := (select id from public.chart_of_accounts where dealer_id = app.current_dealer_id() and code = '1300');
  v_sd    uuid := (select id from public.chart_of_accounts where dealer_id = app.current_dealer_id() and code = '1003');
  v_cust  uuid := (select id from fixture_party);
  v_row   record;
begin
  select * into v_row from public.ledger_master(null, null, null, 1000, 0) where id = v_loan;
  perform app_test.assert_equals(v_row.group_name || '|' || v_row.opening::text, 'Loans (Liability)|-60000.0000',
    'the ledger master shows a ledger under its group with its opening');
  -- The receivable is listed through its customers; it appears itself only
  -- for what is on it tagged to no customer, and then with just that.
  perform app_test.assert_equals(
    coalesce((select sum(closing) from public.ledger_master(null, null, null, 1000, 0) where id = v_recv), 0),
    (select coalesce(sum(l.debit - l.credit), 0)::numeric(18, 4) from public.journal_entry_lines l
       join public.journal_entries je on je.id = l.journal_entry_id
      where l.account_id = v_recv and l.party_id is null and je.status in ('POSTED', 'REVERSED')),
    'the receivable itself shows only what no customer carries');
  select * into v_row from public.ledger_master((select mobile from fixture_party), null, null, 50, 0)
   where kind = 'CUSTOMER' and id = v_cust;
  perform app_test.assert_equals(v_row.group_name, 'Sundry Debtors', 'a customer is found by mobile, under Sundry Debtors');
  perform app_test.assert_equals(
    (select bool_and(group_id = v_sd) from public.ledger_master(null, v_sd, null, 1000, 0) where kind = 'CUSTOMER'), true,
    'filtering by Sundry Debtors lists the customers');
  perform app_test.assert_equals(
    (select count(*)::int from public.ledger_master('RENT', null, null, 50, 0) where code = '5600'), 1,
    'a ledger is found by its alias or name');
end $$;

reset role;
select app_test.logout();

-- ── Financial years ────────────────────────────────────────────────────────
-- A past year to close, as a dealer migrating mid-way would have.
insert into public.accounting_periods (dealer_id, name, start_date, end_date, status)
select id, 'FY 2025-26', date '2025-04-01', date '2026-03-31', 'OPEN' from public.dealers where code = 'SBM';

select app_test.login('22222222-2222-4222-8222-222222222222');
set role authenticated;

do $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_main   uuid := (select id from public.branches where dealer_id = app.current_dealer_id() and code = 'MAIN');
  v_a      uuid := (select id from public.chart_of_accounts where dealer_id = app.current_dealer_id() and code = '4800');
  v_b      uuid := (select id from public.chart_of_accounts where dealer_id = app.current_dealer_id() and code = '5900');
  v_last   date := (select max(end_date) from public.accounting_periods where dealer_id = app.current_dealer_id());
  v_old    uuid := (select id from public.accounting_periods where dealer_id = app.current_dealer_id() and name = 'FY 2025-26');
  v_cur    uuid := (select id from public.accounting_periods where dealer_id = app.current_dealer_id()
                       and current_date between start_date and end_date);
  v_fy     uuid;
  v_fy2    uuid;
begin
  v_fy := public.create_financial_year();
  perform app_test.assert_equals(
    (select start_date from public.accounting_periods where id = v_fy), v_last + 1,
    'a new financial year starts the day after the last one ends');
  perform app_test.assert_equals(
    (select (end_date - start_date + 1) between 365 and 366 from public.accounting_periods where id = v_fy), true,
    'and runs a year');
  perform app_test.assert_equals(
    (select name from public.accounting_periods where id = v_fy),
    'FY ' || extract(year from v_last + 1)::int || '-' || lpad((extract(year from v_last + 1)::int % 100 + 1)::text, 2, '0'),
    'named FY yyyy-yy');
  v_fy2 := public.create_financial_year();
  perform app_test.assert_equals(
    (select start_date from public.accounting_periods where id = v_fy2),
    (select end_date + 1 from public.accounting_periods where id = v_fy),
    'the next one follows on');
  perform app_test.assert_equals(
    (select count(*)::int from public.audit_logs where entity_id = v_fy2::text), 1, 'creating a year is audited');

  perform app_test.assert_raises(
    format($q$select public.close_financial_year(%L)$q$, v_fy),
    'nor a later year while an earlier one is open', 'earlier');

  perform public.close_financial_year(v_old);
  perform app_test.assert_equals((select status from public.accounting_periods where id = v_old), 'CLOSED',
    'a year that has ended closes');
  perform app_test.assert_raises(
    format($q$select public.close_financial_year(%L)$q$, v_cur),
    'the running year cannot close before it ends', 'not ended');
  perform app_test.assert_raises(
    format($q$select app.post_journal(%L, %L, date '2025-06-01', 'MANUAL', 'late', jsonb_build_array(
      jsonb_build_object('account_id', %L::uuid, 'debit', 1, 'credit', 0),
      jsonb_build_object('account_id', %L::uuid, 'debit', 0, 'credit', 1)), 'MANUAL_JOURNAL', null, null)$q$,
      v_dealer, v_main, v_b, v_a),
    'nothing posts into a closed year', 'closed');

  perform app_test.assert_raises(
    format($q$select public.reopen_financial_year(%L, '')$q$, v_old),
    'reopening needs a reason', 'why');
  perform public.reopen_financial_year(v_old, 'Late supplier bill found');
  perform app_test.assert_equals(
    (select status || '|' || status_reason from public.accounting_periods where id = v_old),
    'OPEN|Late supplier bill found', 'and with one the year reopens');
  perform app_test.assert_equals(
    (select count(*)::int from public.audit_logs where entity_id = v_old::text and action = 'UPDATE'), 2,
    'closing and reopening are both audited');
end $$;

reset role;
select app_test.logout();

-- ── A cashier can do none of it ────────────────────────────────────────────
create temporary table fixture_rent as
select c.id from public.chart_of_accounts c join public.dealers d on d.id = c.dealer_id
 where d.code = 'SBM' and c.code = '5600';
grant select on fixture_rent to authenticated;

select app_test.login('33333333-3333-4333-8333-333333333333');
set role authenticated;
do $$
declare
  v_rent uuid := (select id from fixture_rent);
begin
  perform app_test.assert_raises(
    format($q$select public.update_account(%L, 'Mine', '5600', null, null)$q$, v_rent),
    'a cashier cannot modify a ledger', 'may not');
  perform app_test.assert_raises(
    format($q$select public.set_ledger_opening_balance('ACCOUNT', %L, 1, 'DR')$q$, v_rent),
    'nor set an opening balance', 'accountant');
  perform app_test.assert_raises('select public.create_financial_year()', 'nor create a financial year', 'may not');
  perform app_test.assert_equals(
    (select count(*)::int from public.ledger_master(null, null, null, 50, 0)), 0,
    'and the ledger master shows them nothing');
end $$;
reset role;
select app_test.logout();

-- Leave the fixture year out of later runs' way.
delete from public.accounting_periods
 where name = 'FY 2025-26' and dealer_id = (select id from public.dealers where code = 'SBM');
