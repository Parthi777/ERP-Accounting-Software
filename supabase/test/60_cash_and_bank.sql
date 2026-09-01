-- =============================================================================
-- TEST — cash book, daily close, and bank reconciliation
-- =============================================================================
-- Spec §36, §37, §38, §39, §60.14, §60.15.
--
-- The assertions that matter most here:
--   * the close computes the difference — this was NULL before migration 0030,
--     which meant the daily close never actually reported cash short or over;
--   * a closed day is frozen against further entries;
--   * a statement line is never reconciled without a link to its book entry, and
--     mismatched amounts are refused.
-- =============================================================================

\echo '--- cash book and bank ---'

do $$
declare
  v_dealer    uuid;
  v_branch    uuid;
  v_cash_acct uuid;
  v_cash_ldg  uuid;
  v_bank      uuid;
  v_bank_ldg  uuid;
  v_income    uuid;
  v_expense   uuid;
  v_day       uuid;
  v_status    text;
  v_txn       bigint;
  v_txn2      bigint;
  v_balance   numeric;
  v_expected  numeric;
  v_diff      numeric;
  v_entry     uuid;
  v_debit     numeric;
  v_credit    numeric;
  v_line      bigint;
  v_line2     bigint;
  v_count     int;
  v_conf      text;
  v_matched   boolean;
  v_recon     uuid;
  v_number    text;
  v_before    numeric;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'MAIN';

  select id into v_cash_ldg from public.chart_of_accounts
   where dealer_id = v_dealer and account_type = 'ASSET' and is_group = false
     and name ilike '%cash%' limit 1;

  select id into v_income from public.chart_of_accounts
   where dealer_id = v_dealer and account_type = 'INCOME' and is_group = false limit 1;

  select id into v_expense from public.chart_of_accounts
   where dealer_id = v_dealer and account_type = 'EXPENSE' and is_group = false limit 1;

  perform app_test.assert_equals(v_cash_ldg is not null, true, 'a cash ledger account exists');
  perform app_test.assert_equals(v_income  is not null, true, 'an income account exists');
  perform app_test.assert_equals(v_expense is not null, true, 'an expense account exists');

  -- ── A cash account for the branch (spec §36) ──────────────────────────────
  -- The branch already has a cash account: seed.sql creates one per branch, as
  -- spec §36 requires. So the conflict path is the one that runs, and it has to
  -- carry the opening balance across — the assertions below are about what
  -- ensure_cash_day() does with it.
  insert into public.cash_accounts (dealer_id, branch_id, name, ledger_account_id, opening_balance, current_balance)
  values (v_dealer, v_branch, 'Main counter cash', v_cash_ldg, 10000, 10000)
  on conflict (branch_id) do update
    set name = excluded.name,
        opening_balance = excluded.opening_balance,
        current_balance = excluded.current_balance
  returning id into v_cash_acct;

  -- ── The day opens on demand, carrying the account's opening balance ───────
  v_day := public.ensure_cash_day(v_branch, date '2026-06-01');
  select status, opening_balance into v_status, v_balance
    from public.cash_day_closings where id = v_day;

  perform app_test.assert_equals(v_status, 'OPEN', 'the day opens on demand');
  perform app_test.assert_equals(v_balance, 10000::numeric, 'it carries the opening balance');

  -- Calling again is idempotent — it must not create a second day.
  perform public.ensure_cash_day(v_branch, date '2026-06-01');
  select count(*) into v_count from public.cash_day_closings
   where branch_id = v_branch and business_date = date '2026-06-01';
  perform app_test.assert_equals(v_count, 1, 'opening the same day twice creates one row');

  -- ── A receipt ─────────────────────────────────────────────────────────────
  -- Asserted as a movement rather than an absolute, because cash_transactions
  -- carries one running balance per account and earlier tests now put receipts
  -- through it: since 0049 a booking advance taken in cash reaches the cash book
  -- like any other receipt. What matters here is that this receipt moves the
  -- balance by its own amount.
  select coalesce(
           (select ct.balance_after from public.cash_transactions ct
             where ct.cash_account_id = v_cash_acct
             order by ct.id desc limit 1),
           (select ca.opening_balance from public.cash_accounts ca where ca.id = v_cash_acct))
    into v_before;

  select transaction_id, balance_after into v_txn, v_balance
    from public.record_cash_transaction(
      v_branch, 'RECEIPT', 5000, 'Advance from walk-in customer', v_income, null, 'REC-T1', date '2026-06-01');

  perform app_test.assert_equals(v_balance - v_before, 5000::numeric, 'a receipt raises cash in hand');

  select status into v_status from public.cash_day_closings where id = v_day;
  perform app_test.assert_equals(v_status, 'IN_PROGRESS', 'the first entry moves the day to IN_PROGRESS');

  -- The journal must balance, and must exist at all: a receipt without one is
  -- money the books never saw.
  select journal_entry_id into v_entry from public.cash_transactions where id = v_txn;
  perform app_test.assert_equals(v_entry is not null, true, 'the receipt wrote a journal entry');

  select sum(debit), sum(credit) into v_debit, v_credit
    from public.journal_entry_lines where journal_entry_id = v_entry;
  perform app_test.assert_equals(v_debit, v_credit, 'the receipt journal balances');
  perform app_test.assert_equals(v_debit, 5000::numeric, 'for the amount received');

  -- ── A payment ─────────────────────────────────────────────────────────────
  select transaction_id, balance_after into v_txn2, v_balance
    from public.record_cash_transaction(
      v_branch, 'PAYMENT', 2000, 'Fuel for delivery van', v_expense, null, 'PAY-T1', date '2026-06-01');

  perform app_test.assert_equals(v_balance - v_before, 3000::numeric,
    'a payment lowers cash in hand (5000 in, 2000 out)');

  select total_receipts, total_payments, expected_closing
    into v_balance, v_diff, v_expected
    from public.cash_day_closings where id = v_day;

  perform app_test.assert_equals(v_balance,  5000::numeric,  'the day sheet totals receipts');
  perform app_test.assert_equals(v_diff,     2000::numeric,  'the day sheet totals payments');
  perform app_test.assert_equals(v_expected, 13000::numeric, 'expected closing = opening + receipts − payments');

  perform app_test.assert_raises(
    format('select public.record_cash_transaction(%L, %L, -100, %L, %L)', v_branch, 'RECEIPT', 'Negative', v_income),
    'a negative receipt is refused');

  perform app_test.assert_raises(
    format('select public.record_cash_transaction(%L, %L, 100, %L, %L)', v_branch, 'TRANSFER', 'Bad direction', v_income),
    'an unknown direction is refused');

  -- ── The close computes the difference (spec §36) ──────────────────────────
  -- Counting 12,900 against an expected 13,000 is a shortage of 100. Before
  -- migration 0030 this came back NULL, because the trigger read a generated
  -- column that PostgreSQL had not yet populated.
  select expected, counted, difference into v_expected, v_balance, v_diff
    from public.close_cash_day(v_branch, date '2026-06-01', 12900,
      '{"500": 25, "100": 4}'::jsonb, 'Short by one hundred');

  perform app_test.assert_equals(v_expected, 13000::numeric, 'the close reports the expected closing');
  perform app_test.assert_equals(v_balance,  12900::numeric, 'the close reports what was counted');
  perform app_test.assert_equals(v_diff is not null, true,
    'the close computes a difference rather than leaving it NULL');
  perform app_test.assert_equals(v_diff, -100::numeric, 'a shortage is negative');

  select status into v_status from public.cash_day_closings where id = v_day;
  perform app_test.assert_equals(v_status, 'CLOSED', 'the day is closed');

  -- ── A closed day is frozen (spec §36, §60.23) ─────────────────────────────
  perform app_test.assert_raises(
    format('select public.record_cash_transaction(%L, %L, 500, %L, %L, null, null, %L)',
           v_branch, 'RECEIPT', 'After close', v_income, date '2026-06-01'),
    'a closed day refuses new entries');

  perform app_test.assert_raises(
    format('select public.close_cash_day(%L, %L, 100)', v_branch, date '2026-06-01'),
    'a day cannot be closed twice');

  perform app_test.assert_raises(
    format('delete from public.cash_transactions where id = %s', v_txn),
    'cash entries are never deleted');

  -- ── Reopening needs a reason (spec §36) ───────────────────────────────────
  perform app_test.assert_raises(
    format('select public.reopen_cash_day(%L, %L, %L)', v_branch, date '2026-06-01', ''),
    'reopening without a reason is refused');

  perform public.reopen_cash_day(v_branch, date '2026-06-01', 'Recount ordered by the accountant');
  select status into v_status from public.cash_day_closings where id = v_day;
  perform app_test.assert_equals(v_status, 'COUNTED', 'a reopened day leaves CLOSED');

  -- Entries are possible again once reopened, which is the point of reopening.
  select transaction_id into v_txn
    from public.record_cash_transaction(
      v_branch, 'RECEIPT', 100, 'Found in the drawer', v_income, null, null, date '2026-06-01');
  perform app_test.assert_equals(v_txn is not null, true, 'a reopened day accepts entries');

  -- ── The next day carries yesterday's counted cash forward ─────────────────
  perform public.close_cash_day(v_branch, date '2026-06-01', 13000, null, 'Recounted and tallied');
  v_day := public.ensure_cash_day(v_branch, date '2026-06-02');
  select opening_balance into v_balance from public.cash_day_closings where id = v_day;
  perform app_test.assert_equals(v_balance, 13000::numeric,
    'the next day opens at what was physically counted, not at the book figure');

  -- ── The cash book report ──────────────────────────────────────────────────
  select count(*) into v_count from public.cash_book(v_branch, date '2026-06-01');
  perform app_test.assert_equals(v_count, 3, 'the cash book lists the day''s entries');

  -- =========================================================================
  -- Bank — spec §38, §39
  -- =========================================================================
  select id into v_bank_ldg from public.chart_of_accounts
   where dealer_id = v_dealer and account_type = 'ASSET' and is_group = false
     and name ilike '%bank%' limit 1;

  if v_bank_ldg is null then
    v_bank_ldg := v_cash_ldg;
  end if;

  insert into public.bank_accounts
    (dealer_id, branch_id, name, bank_name, account_number, ifsc, ledger_account_id,
     opening_balance, current_balance)
  values
    (v_dealer, v_branch, 'Current account', 'HDFC Bank', '50200012345678', 'HDFC0001234',
     v_bank_ldg, 100000, 100000)
  returning id into v_bank;

  select transaction_id, balance_after into v_txn, v_balance
    from public.record_bank_transaction(
      v_bank, 'RECEIPT', 25000, 'NEFT from customer', v_income, date '2026-06-05', null, 'UTR2026060512345');

  perform app_test.assert_equals(v_balance, 125000::numeric, 'a bank receipt raises the balance');

  select journal_entry_id into v_entry from public.bank_transactions where id = v_txn;
  select sum(debit), sum(credit) into v_debit, v_credit
    from public.journal_entry_lines where journal_entry_id = v_entry;
  perform app_test.assert_equals(v_debit, v_credit, 'the bank journal balances');

  select transaction_id into v_txn2
    from public.record_bank_transaction(
      v_bank, 'PAYMENT', 8000, 'Supplier payment', v_expense, date '2026-06-06', null, null, '000123');

  -- ── Statement import ──────────────────────────────────────────────────────
  select imported, skipped into v_count, v_diff
    from public.import_bank_statement(v_bank, jsonb_build_array(
      jsonb_build_object('statement_date', '2026-06-05', 'narration', 'NEFT CR CUSTOMER',
                         'utr', 'UTR2026060512345', 'debit', 0, 'credit', 25000),
      jsonb_build_object('statement_date', '2026-06-06', 'narration', 'CHQ 000123 PAID',
                         'cheque_number', '000123', 'debit', 8000, 'credit', 0),
      jsonb_build_object('statement_date', '2026-06-07', 'narration', 'BANK CHARGES',
                         'debit', 118, 'credit', 0),
      -- Neither a debit nor a credit: not a transaction, and not imported.
      jsonb_build_object('statement_date', '2026-06-07', 'narration', 'OPENING BALANCE',
                         'debit', 0, 'credit', 0)
    ));

  perform app_test.assert_equals(v_count, 3, 'three statement lines import');
  perform app_test.assert_equals(v_diff, 1::numeric, 'a row with no amount is skipped, not imported');

  -- Re-importing the same statement must not duplicate it.
  select imported, skipped into v_count, v_diff
    from public.import_bank_statement(v_bank, jsonb_build_array(
      jsonb_build_object('statement_date', '2026-06-05', 'narration', 'NEFT CR CUSTOMER',
                         'utr', 'UTR2026060512345', 'debit', 0, 'credit', 25000)
    ));
  perform app_test.assert_equals(v_count, 0, 'a re-imported line is not duplicated');
  perform app_test.assert_equals(v_diff, 1::numeric, 'it is reported as skipped');

  -- ── Matching (spec §39) ───────────────────────────────────────────────────
  select count(*) into v_count from public.suggest_bank_matches(v_bank);
  perform app_test.assert_equals(v_count, 2, 'two of the three lines have candidate matches');

  select confidence into v_conf from public.suggest_bank_matches(v_bank)
   where statement_line_id = (select id from public.bank_statement_lines
                               where bank_account_id = v_bank and utr = 'UTR2026060512345');
  perform app_test.assert_equals(v_conf, 'EXACT', 'a UTR match is reported as exact');

  select id into v_line from public.bank_statement_lines
   where bank_account_id = v_bank and utr = 'UTR2026060512345';
  select id into v_line2 from public.bank_statement_lines
   where bank_account_id = v_bank and narration = 'BANK CHARGES';

  -- The bank charge has no book entry; matching it to the NEFT receipt would be
  -- a reconciliation that balances on paper and is wrong in fact.
  perform app_test.assert_raises(
    format('select public.match_bank_line(%s, %s)', v_line2, v_txn),
    'matching two different amounts is refused');

  perform public.match_bank_line(v_line, v_txn);

  select match_status, matched_transaction_id is not null
    into v_status, v_matched
    from public.bank_statement_lines where id = v_line;
  perform app_test.assert_equals(v_status, 'MATCHED', 'the line is matched');
  perform app_test.assert_equals(v_matched, true,
    'a matched line always records which book entry it matched');

  select reconciled into v_matched from public.bank_transactions where id = v_txn;
  perform app_test.assert_equals(v_matched, true, 'the book entry is marked reconciled');

  perform app_test.assert_raises(
    format('select public.match_bank_line(%s, %s)', v_line, v_txn),
    'a line cannot be matched twice');

  -- Unmatching releases both sides.
  perform public.unmatch_bank_line(v_line);
  select reconciled into v_matched from public.bank_transactions where id = v_txn;
  perform app_test.assert_equals(v_matched, false, 'unmatching releases the book entry');

  perform public.match_bank_line(v_line, v_txn);

  -- An unexplained line is ignored explicitly rather than left to rot.
  perform public.ignore_bank_line(v_line2);
  select match_status into v_status from public.bank_statement_lines where id = v_line2;
  perform app_test.assert_equals(v_status, 'IGNORED', 'an unmatched line can be ignored');

  perform app_test.assert_raises(
    format('select public.ignore_bank_line(%s)', v_line),
    'a matched line cannot be ignored');

  -- ── Completing the reconciliation ─────────────────────────────────────────
  select reconciliation_id, number, difference, matched, unmatched
    into v_recon, v_number, v_diff, v_count, v_expected
    from public.complete_bank_reconciliation(v_bank, date '2026-06-01', date '2026-06-30', 117000);

  perform app_test.assert_equals(v_number is not null, true, 'the reconciliation is numbered');
  perform app_test.assert_equals(v_count, 1, 'it counts the matched lines');
  perform app_test.assert_equals(v_expected, 1::numeric, 'and the ones still unmatched');

  -- Books: 100,000 opening + 25,000 − 8,000 = 117,000. The statement agrees.
  perform app_test.assert_equals(v_diff, 0::numeric,
    'statement and book closing balances agree');

  -- A completed reconciliation is not retrospectively unpicked.
  perform app_test.assert_raises(
    format('select public.unmatch_bank_line(%s)', v_line),
    'a settled line cannot be unmatched');

  -- ── The ledger still balances after all of it ─────────────────────────────
  select sum(l.debit), sum(l.credit) into v_debit, v_credit
    from public.journal_entry_lines l
    join public.journal_entries e on e.id = l.journal_entry_id
   where e.dealer_id = v_dealer and e.status = 'POSTED';

  perform app_test.assert_equals(v_debit, v_credit,
    'the ledger balances after cash and bank activity');
end;
$$;
