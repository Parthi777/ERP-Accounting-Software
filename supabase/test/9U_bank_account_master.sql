-- =============================================================================
-- TEST — creating a bank account, and the balance it opens with
-- =============================================================================
-- Spec §22, §23, §24, §38, §46.
--
-- Before 0073 nothing could create a bank account: the service had a read and
-- no write, and rows arrived only from provisioning SQL. The live tenant had
-- none at all, so every bank screen was unreachable rather than empty.
--
-- The guarantees asserted here:
--   * an account opens against the 1200 Bank control account, resolved from the
--     chart of accounts rather than passed in from the browser (spec §22);
--   * an opening balance is a posted journal against 3300, not a number in a
--     column — otherwise the bank book and the trial balance disagree from the
--     first day and nothing says which is right;
--   * an overdraft opens the other way round;
--   * a zero opening balance posts nothing at all;
--   * the bank book counts up from the balance that was posted;
--   * a role without bank.accounts.manage cannot create one, and neither the
--     function nor RLS lets a branch from another tenant in.
-- =============================================================================

\echo '--- bank accounts ---'

-- A second tenant, built here rather than borrowed. 10_rls_isolation's RIVAL is
-- deleted by its own teardown and 9G's NDM is another file's fixture; depending
-- on either would make this test pass or fail for reasons that have nothing to
-- do with bank accounts.
--
-- It is captured before the session drops into `authenticated` because RLS
-- hides the row from an SBM user — read from inside the test it would find
-- nothing, and the assertion below would pass without the guard ever being
-- asked the question.
do $$
declare
  v_other uuid;
begin
  insert into public.dealers (code, legal_name, trade_name, city, state, state_code)
  values ('BANKX', 'Other Motors Private Limited', 'Other Motors', 'Salem', 'Tamil Nadu', '33')
  returning id into v_other;

  insert into public.branches (dealer_id, code, name, city, state, state_code, is_head_office)
  values (v_other, 'MAIN', 'Other Main Branch', 'Salem', 'Tamil Nadu', '33', true);
end;
$$;

create temp table rival_branch as
  select b.id from public.branches b
    join public.dealers d on d.id = b.dealer_id
   where d.code = 'BANKX' limit 1;

-- `set role authenticated` below changes who is reading, and a temp table is
-- owned by the session user.
grant select on rival_branch to authenticated;

set role authenticated;
select app_test.login('22222222-2222-4222-8222-222222222222');   -- Accounts

do $$
declare
  v_dealer  uuid;
  v_branch  uuid;
  v_bank    uuid;
  v_od      uuid;
  v_zero    uuid;
  v_ledger  uuid;
  v_equity  uuid;
  v_debit   numeric;
  v_credit  numeric;
  v_count   int;
  v_balance numeric;
  v_row     record;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_ledger from public.chart_of_accounts where dealer_id = v_dealer and code = '1200';
  select id into v_equity from public.chart_of_accounts where dealer_id = v_dealer and code = '3300';

  -- ═══ An account that opens with money in it ══════════════════════════════
  v_bank := public.create_bank_account(
    p_name            => 'HDFC Current',
    p_bank_name       => 'HDFC Bank',
    p_account_number  => '50200073010001',
    p_ifsc            => 'hdfc0001234',          -- lower case on purpose
    p_account_type    => 'CURRENT',
    p_branch_id       => v_branch,
    p_opening_balance => 250000,
    p_as_on           => current_date);

  select * into v_row from public.bank_accounts where id = v_bank;

  perform app_test.assert_equals(v_row.ledger_account_id, v_ledger,
    'the account posts to 1200 Bank, resolved rather than supplied (spec §22)');
  perform app_test.assert_equals(v_row.ifsc, 'HDFC0001234',
    'the IFSC is upper-cased, so the check constraint accepts what a person typed');
  perform app_test.assert_equals(v_row.opening_balance, 250000::numeric(18,4),
    'the opening balance is recorded');
  perform app_test.assert_equals(v_row.created_by is not null, true,
    'and who created it (spec §46)');

  -- The journal, which is the point.
  select sum(jel.debit), sum(jel.credit), count(*)::int
    into v_debit, v_credit, v_count
    from public.journal_entry_lines jel
    join public.journal_entries je on je.id = jel.journal_entry_id
   where je.source_document_type = 'BANK_ACCOUNT' and je.source_document_id = v_bank;

  perform app_test.assert_equals(v_count, 2, 'the opening balance posted two lines');
  perform app_test.assert_equals(v_debit, v_credit,
    'which balance, because an unbalanced journal cannot post at all (spec §22)');

  select jel.debit into v_debit from public.journal_entry_lines jel
    join public.journal_entries je on je.id = jel.journal_entry_id
   where je.source_document_id = v_bank and jel.account_id = v_ledger;
  perform app_test.assert_equals(v_debit, 250000::numeric(18,4),
    'money in the bank is a debit to 1200');

  select jel.credit into v_credit from public.journal_entry_lines jel
    join public.journal_entries je on je.id = jel.journal_entry_id
   where je.source_document_id = v_bank and jel.account_id = v_equity;
  perform app_test.assert_equals(v_credit, 250000::numeric(18,4),
    'and a credit to 3300, the same account the party opening balances use');

  -- ═══ The bank book and the ledger start from the same figure ═════════════
  -- current_balance is what the dashboard and the MIS reports sum (0035), and
  -- opening_balance is what complete_bank_reconciliation() counts up from
  -- (0031). Both must equal what was posted to 1200, or the bank screens and
  -- the trial balance tell the dealer two different stories.
  select current_balance into v_balance from public.bank_accounts where id = v_bank;
  perform app_test.assert_equals(v_balance, 250000::numeric(18,4),
    'the balance the dashboard reads is the balance that was posted');

  select jel.debit into v_debit from public.journal_entry_lines jel
    join public.journal_entries je on je.id = jel.journal_entry_id
   where je.source_document_id = v_bank and jel.account_id = v_ledger;
  perform app_test.assert_equals(v_balance, v_debit,
    'so the bank book and the ledger cannot disagree about the opening figure');

  -- ═══ An overdraft opens the other way round ══════════════════════════════
  v_od := public.create_bank_account(
    p_name            => 'ICICI OD',
    p_bank_name       => 'ICICI Bank',
    p_account_number  => '50200073010002',
    p_account_type    => 'OD',
    p_opening_balance => -75000);

  select jel.credit into v_credit from public.journal_entry_lines jel
    join public.journal_entries je on je.id = jel.journal_entry_id
   where je.source_document_id = v_od and jel.account_id = v_ledger;
  perform app_test.assert_equals(v_credit, 75000::numeric(18,4),
    'an overdrawn account credits 1200 — the bank is owed, not owing');

  -- ═══ Nothing opens nothing ═══════════════════════════════════════════════
  v_zero := public.create_bank_account(
    p_name           => 'Axis Savings',
    p_bank_name      => 'Axis Bank',
    p_account_number => '50200073010003');

  select count(*)::int into v_count from public.journal_entries
   where source_document_type = 'BANK_ACCOUNT' and source_document_id = v_zero;
  perform app_test.assert_equals(v_count, 0,
    'a zero opening balance posts no journal — an entry for nothing is noise');

  -- ═══ Editing, and what cannot be edited ══════════════════════════════════
  perform public.update_bank_account(v_zero, p_name => 'Axis Savings (Main)',
                                     p_status => 'INACTIVE');
  select * into v_row from public.bank_accounts where id = v_zero;
  perform app_test.assert_equals(v_row.name, 'Axis Savings (Main)', 'the name can be corrected');
  perform app_test.assert_equals(v_row.status, 'INACTIVE', 'and the account closed to new entries');
  perform app_test.assert_equals(v_row.opening_balance, 0::numeric(18,4),
    'the opening balance is not among the things update touches (spec §23)');

  -- ═══ The constraint that stops the same account twice ════════════════════
  perform app_test.assert_raises(
    $f$select public.create_bank_account('HDFC Again', 'HDFC Bank', '50200073010001')$f$,
    'the same account number cannot be added to one dealer twice');

  -- ═══ Another tenant's branch ═════════════════════════════════════════════
  perform app_test.assert_equals((select count(*)::int from rival_branch), 1,
    'the fixture really did capture another tenant''s branch');

  perform app_test.assert_raises(
    format($f$select public.create_bank_account('Wrong Branch', 'Some Bank', '50200073010004', null, 'CURRENT', %L)$f$,
           (select id from rival_branch)),
    'a client-submitted branch from another dealer is refused (spec §47)');
end;
$$;

-- ═══ A role without the permission ═════════════════════════════════════════
select app_test.login('33333333-3333-4333-8333-333333333333');   -- Cashier

do $$
begin
  perform app_test.assert_raises(
    $f$select public.create_bank_account('Sneaky', 'Some Bank', '50200073010005')$f$,
    'a cashier cannot open a bank account, whatever the UI offers them');
end;
$$;

select app_test.logout();
reset role;
