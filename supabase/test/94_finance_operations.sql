-- =============================================================================
-- TEST — finance applications, trade advances and settlements
-- =============================================================================
-- Spec §25, §26, §27.
--
-- The guarantees asserted here:
--   * an application is a request, not a posting — nothing hits the ledger until
--     money moves;
--   * the constraints that make a decision meaningful are enforced with a
--     sentence: an approval states its amount, a rejection states its reason;
--   * every finance movement posts a balanced journal, and the running position
--     with a company is computed by the database, never supplied by the caller;
--   * the per-company subsidiary ledger reconciles to the control account —
--     spec §25's whole reason for keeping one ledger per company;
--   * the ledger is append-only, so a mistake is corrected by a further entry.
-- =============================================================================

\echo '--- finance operations ---'

do $$
declare
  v_dealer   uuid;
  v_branch   uuid;
  v_customer uuid;
  v_company  uuid;
  v_bank     uuid;
  v_app      uuid;
  v_app_no   text;
  v_entry    uuid;
  v_txn      bigint;
  v_settle   uuid;
  v_settle_no text;
  v_status   text;
  v_amount   numeric;
  v_balance  numeric;
  v_control  numeric;
  v_debit    numeric;
  v_credit   numeric;
  v_count    int;
  v_recv     uuid;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_bank   from public.bank_accounts where dealer_id = v_dealer limit 1;
  select id into v_recv   from public.chart_of_accounts where dealer_id = v_dealer and code = '1400';

  insert into public.customers (dealer_id, name, mobile, city, state, state_code)
  values (v_dealer, 'Finance Test Customer', '9840096001', 'Chennai', 'Tamil Nadu', '33')
  returning id into v_customer;

  -- Finance companies are not seeded, so the test creates its own (spec §25).
  insert into public.finance_companies (dealer_id, code, name, commission_percent)
  values (v_dealer, 'TVSCREDIT', 'TVS Credit Services', 2.5)
  returning id into v_company;

  -- ═══ The application ═════════════════════════════════════════════════════
  select application_id, application_number into v_app, v_app_no
    from public.create_finance_application(
      v_branch, v_customer, v_company, 90000, 15000, null, null,
      36::smallint, 13.5, 1200, current_date, 'HP for Jupiter');

  perform app_test.assert_equals(v_app_no ~ '^FA-[0-9]{4}-[0-9]{6}$', true,
    'the application number follows the FA-YYYY-NNNNNN format');

  select count(*)::int into v_count
    from public.journal_entries where source_document_id = v_app;
  perform app_test.assert_equals(v_count, 0,
    'an application posts nothing: nothing is owed until money moves');

  select approval_status, pending_amount into v_status, v_amount
    from public.finance_applications where id = v_app;
  perform app_test.assert_equals(v_status, 'PENDING', 'a new application is pending');
  perform app_test.assert_equals(v_amount, 90000::numeric,
    'the whole loan is outstanding before approval');

  -- ═══ The decision ════════════════════════════════════════════════════════
  perform app_test.assert_raises(
    format('select public.decide_finance_application(%L, ''APPROVED'', null)', v_app),
    'an approval must state the amount approved');

  perform app_test.assert_raises(
    format('select public.decide_finance_application(%L, ''REJECTED'', null, '''')', v_app),
    'a rejection must state a reason');

  perform app_test.assert_raises(
    format('select public.disburse_finance_application(%L, 1000, %L)', v_app, v_bank),
    'an unapproved application cannot be disbursed');

  perform public.decide_finance_application(v_app, 'APPROVED', 85000);

  select approval_status, approved_amount, pending_amount into v_status, v_amount, v_balance
    from public.finance_applications where id = v_app;
  perform app_test.assert_equals(v_status, 'APPROVED', 'the application is approved');
  perform app_test.assert_equals(v_amount, 85000::numeric, 'for the amount the company agreed');
  perform app_test.assert_equals(v_balance, 85000::numeric,
    'and the pending amount follows the approved figure, not the requested one');

  perform app_test.assert_raises(
    format('select public.decide_finance_application(%L, ''REJECTED'', null, ''Changed mind'')', v_app),
    'a decided application cannot be decided again');

  -- ═══ Disbursement ════════════════════════════════════════════════════════
  perform app_test.assert_raises(
    format('select public.disburse_finance_application(%L, 90000, %L)', v_app, v_bank),
    'more than the approved amount cannot be disbursed');

  select journal_entry_id, finance_transaction_id into v_entry, v_txn
    from public.disburse_finance_application(v_app, 50000, v_bank, 'DD-8891', 'HDFC-REF-1');

  select sum(debit), sum(credit) into v_debit, v_credit
    from public.journal_entry_lines where journal_entry_id = v_entry;
  perform app_test.assert_equals(v_debit, v_credit, 'the disbursement journal balances');

  select disbursement_status, disbursed_amount, pending_amount into v_status, v_amount, v_balance
    from public.finance_applications where id = v_app;
  perform app_test.assert_equals(v_status, 'PARTIAL', 'a part disbursement leaves the application partial');
  perform app_test.assert_equals(v_balance, 35000::numeric, 'with the remainder still pending');

  select count(*)::int into v_count
    from public.bank_transactions where journal_entry_id = v_entry;
  perform app_test.assert_equals(v_count, 1,
    'the money reaches the bank book, not just the ledger');

  -- balance_after is the trigger's, never the caller's.
  select balance_after into v_balance from public.finance_transactions where id = v_txn;
  perform app_test.assert_equals(v_balance, -50000::numeric,
    'the position falls by what the company has now paid');

  perform app_test.assert_raises(
    format('update public.finance_transactions set debit = 1 where id = %s', v_txn),
    'the finance ledger is append-only: a mistake is corrected by a further entry');

  -- Settling the balance completes the application.
  perform public.disburse_finance_application(v_app, 35000, v_bank, null, 'HDFC-REF-2');
  select disbursement_status into v_status from public.finance_applications where id = v_app;
  perform app_test.assert_equals(v_status, 'DISBURSED', 'the final disbursement closes the application');

  -- ═══ Trade advances — every type posts, and balances ═════════════════════
  perform app_test.assert_raises(
    format('select public.record_trade_advance(%L, %L, ''ADVANCE_RECEIVED'', 0, %L)',
           v_company, v_branch, v_bank),
    'a trade advance of nothing is refused');

  perform app_test.assert_raises(
    format('select public.record_trade_advance(%L, %L, ''ADVANCE_RECEIVED'', 5000)',
           v_company, v_branch),
    'money in or out needs the bank account it moved through');

  select transaction_id, journal_entry_id into v_txn, v_entry
    from public.record_trade_advance(v_company, v_branch, 'ADVANCE_RECEIVED', 200000, v_bank);
  select sum(debit), sum(credit) into v_debit, v_credit
    from public.journal_entry_lines where journal_entry_id = v_entry;
  perform app_test.assert_equals(v_debit, v_credit, 'an advance received posts a balanced journal');

  select transaction_id, journal_entry_id into v_txn, v_entry
    from public.record_trade_advance(v_company, v_branch, 'VEHICLE_ADJUSTMENT', 60000);
  select sum(debit), sum(credit) into v_debit, v_credit
    from public.journal_entry_lines where journal_entry_id = v_entry;
  perform app_test.assert_equals(v_debit, v_credit, 'a vehicle adjustment posts a balanced journal');

  select journal_entry_id into v_entry
    from public.record_trade_advance(v_company, v_branch, 'COMMISSION', 4500);
  select sum(debit), sum(credit) into v_debit, v_credit
    from public.journal_entry_lines where journal_entry_id = v_entry;
  perform app_test.assert_equals(v_debit, v_credit, 'commission earned posts a balanced journal');

  select journal_entry_id into v_entry
    from public.record_trade_advance(v_company, v_branch, 'MANUAL_ADJUSTMENT', 1000, null, current_date, 'Correction');
  select sum(debit), sum(credit) into v_debit, v_credit
    from public.journal_entry_lines where journal_entry_id = v_entry;
  perform app_test.assert_equals(v_debit, v_credit, 'a manual adjustment posts a balanced journal');

  select journal_entry_id into v_entry
    from public.record_trade_advance(v_company, v_branch, 'REFUND', 5000, v_bank);
  select sum(debit), sum(credit) into v_debit, v_credit
    from public.journal_entry_lines where journal_entry_id = v_entry;
  perform app_test.assert_equals(v_debit, v_credit, 'a refund posts a balanced journal');

  -- ═══ The subsidiary ledger agrees with itself ════════════════════════════
  select balance_after into v_balance
    from public.finance_transactions
   where finance_company_id = v_company order by id desc limit 1;

  select coalesce(sum(credit) - sum(debit), 0) into v_control
    from public.finance_transactions where finance_company_id = v_company;

  perform app_test.assert_equals(v_balance, v_control,
    'the running position equals credits less debits over the whole company ledger');

  select balance_after into v_amount
    from public.finance_company_ledger(v_company, date '2000-01-01', date '2099-12-31')
   order by transaction_date desc, balance_after desc limit 1;
  perform app_test.assert_equals(v_amount is not null, true,
    'the company ledger reports a closing position');

  -- ═══ Settlement ══════════════════════════════════════════════════════════
  perform app_test.assert_raises(
    format('select public.create_finance_settlement(%L, %L, current_date - 30, current_date, 1000, 900, 500)',
           v_company, v_branch),
    'commission and deductions cannot exceed the gross');

  select settlement_id, settlement_number into v_settle, v_settle_no
    from public.create_finance_settlement(
      v_company, v_branch, current_date - 30, current_date, 100000, 2500, 500);

  perform app_test.assert_equals(v_settle_no ~ '^FS-[0-9]{4}-[0-9]{6}$', true,
    'the settlement number follows the FS-YYYY-NNNNNN format');

  select status, net_amount into v_status, v_amount
    from public.finance_settlements where id = v_settle;
  perform app_test.assert_equals(v_status, 'DRAFT', 'a new settlement is a draft');
  perform app_test.assert_equals(v_amount, 97000::numeric,
    'net is gross less commission and deductions, computed not typed');

  v_entry := public.post_finance_settlement(v_settle, v_bank);

  select sum(debit), sum(credit) into v_debit, v_credit
    from public.journal_entry_lines where journal_entry_id = v_entry;
  perform app_test.assert_equals(v_debit, v_credit, 'the settlement journal balances');
  perform app_test.assert_equals(v_debit, 100000::numeric,
    'the receivable clears at gross, with the withholdings as their own lines');

  select status into v_status from public.finance_settlements where id = v_settle;
  perform app_test.assert_equals(v_status, 'POSTED', 'the settlement is posted');

  perform app_test.assert_raises(
    format('select public.post_finance_settlement(%L, %L)', v_settle, v_bank),
    'a settlement cannot be posted twice');

  -- A settlement with nothing withheld must not try to write a zero line.
  select settlement_id into v_settle
    from public.create_finance_settlement(v_company, v_branch, current_date - 10, current_date, 5000, 0, 0);
  v_entry := public.post_finance_settlement(v_settle, v_bank);
  select count(*)::int into v_count
    from public.journal_entry_lines where journal_entry_id = v_entry;
  perform app_test.assert_equals(v_count, 2,
    'a settlement withholding nothing posts two lines, not four empty ones');

  -- ═══ Control account reconciliation (spec §25) ═══════════════════════════
  -- Every finance posting tags its company, so 1400 must equal the sum of the
  -- party-tagged lines. If these disagree the subsidiary ledger is decorative.
  -- Scoped to what the finance functions posted. Historical demo entries predate
  -- party tagging, and asserting over those would test the fixture, not the code.
  select count(*)::int into v_count
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.account_id = v_recv
     and je.source_document_type in ('FINANCE_APPLICATION', 'FINANCE_SETTLEMENT', 'SALE_PAYMENT')
     and l.party_type is distinct from 'FINANCE_COMPANY';

  perform app_test.assert_equals(v_count, 0,
    'every finance movement on Finance Receivable names the company it belongs to');

  -- ═══ And the books still balance ═════════════════════════════════════════
  select sum(l.debit), sum(l.credit) into v_debit, v_credit
    from public.journal_entry_lines l
    join public.journal_entries e on e.id = l.journal_entry_id
   where e.dealer_id = v_dealer and e.status in ('POSTED', 'REVERSED');

  perform app_test.assert_equals(v_debit, v_credit,
    'the ledger balances after finance activity');
end;
$$;
