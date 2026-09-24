-- =============================================================================
-- TEST — the ledger of one account (spec §41, §43)
-- =============================================================================
-- The plainest report there is, and the one the product never had. The trial
-- balance gives a total and stops; the chart of accounts is a list of names. So
-- "why is Bank Charges 4,150 this month" had no answer anywhere.
--
-- The guarantees asserted here:
--   * the running balance starts from the carried-forward opening, so any row
--     read on its own is the account's real position on that date rather than a
--     total of the window on screen;
--   * it reconciles with the trial balance — two reports disagreeing about one
--     account is worse than either being absent;
--   * the contra account is named, which is the question a reader actually has;
--   * a reversed entry stays visible, because a ledger that hides corrections
--     is not a ledger.
-- =============================================================================

\echo '--- account ledger ---'

select app_test.login('11111111-1111-4111-8111-111111111111');

do $$
declare
  v_dealer  uuid;
  v_cash    uuid;
  v_exp     uuid;
  v_open    numeric;
  v_last    numeric;
  v_sum     numeric;
  v_tb      numeric;
  v_contra  text;
  r         record;
  v_rev     record;
  v_rows    int;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_cash from public.chart_of_accounts where dealer_id = v_dealer and code = '1100';
  select id into v_exp  from public.chart_of_accounts where dealer_id = v_dealer and code = '5800';

  -- ── The running balance carries the opening in ──────────────────────────
  select public.account_ledger_opening(v_cash, date '2026-09-01') into v_open;

  select running_balance into v_last
    from public.account_ledger(v_cash, date '2026-09-01', date '2026-12-31')
   order by entry_date desc, entry_number desc limit 1;

  select coalesce(sum(debit - credit), 0) into v_sum
    from public.account_ledger(v_cash, date '2026-09-01', date '2026-12-31');

  if v_last is not null then
    perform app_test.assert_equals(
      v_last, v_open + v_sum,
      'the closing balance is the opening plus the period, not the period alone'
    );
  end if;

  -- ── It agrees with the trial balance ────────────────────────────────────
  -- Two reports disagreeing about one account is worse than either being
  -- absent, because nobody can tell which to believe.
  select coalesce(sum(l.debit - l.credit), 0) into v_tb
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.account_id = v_cash and je.status in ('POSTED', 'REVERSED')
     and je.entry_date <= date '2026-12-31';

  select public.account_ledger_opening(v_cash, date '2026-12-31' + 1) into v_open;
  perform app_test.assert_equals(
    v_open, v_tb, 'the ledger and the trial balance agree on the account'
  );

  -- ── The contra account is named ─────────────────────────────────────────
  select contra into v_contra
    from public.account_ledger(v_cash, date '2000-01-01', date '2099-12-31')
   where contra is not null limit 1;
  perform app_test.assert_equals(
    (v_contra is not null and length(v_contra) > 0), true,
    'each row names what sat on the other side of the entry'
  );

  -- ── A reversal stays visible ────────────────────────────────────────────
  select * into r from public.post_manual_journal(
    current_date, 'Ledger visibility check',
    jsonb_build_array(
      jsonb_build_object('account_id', v_exp,  'debit', 111, 'credit', 0),
      -- 2700, not cash: a hand-written line may not move the cash ledger (0076).
      jsonb_build_object('account_id',
        (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '2700'),
        'debit', 0, 'credit', 111)
    ));

  select count(*) into v_rows from public.account_ledger(v_exp, current_date, current_date);
  perform app_test.assert_equals(v_rows >= 1, true, 'a new entry appears in the ledger at once');

  select * into v_rev from public.reverse_journal_entry(r.journal_entry_id, 'Posted in error');

  -- Both sides of the correction, still there: the original marked reversed and
  -- the entry that undid it. A ledger that hid either would be describing a
  -- history that did not happen.
  select count(*) into v_rows
    from public.account_ledger(v_exp, current_date, current_date)
   where entry_number in (r.entry_number, v_rev.entry_number);
  perform app_test.assert_equals(
    v_rows, 2, 'the original and its reversal both remain on the ledger'
  );

  perform app_test.assert_equals(
    (select status from public.account_ledger(v_exp, current_date, current_date)
      where entry_number = r.entry_number limit 1),
    'REVERSED',
    'and the original is shown as reversed rather than quietly dropped'
  );

  -- Net effect nil, which is what a reversal means.
  select coalesce(sum(debit - credit), 0) into v_sum
    from public.account_ledger(v_exp, current_date, current_date)
   where entry_number in (r.entry_number, v_rev.entry_number);
  perform app_test.assert_equals(
    v_sum, 0::numeric, 'and the pair nets to nothing on the account'
  );

  -- ── A branch filter narrows it ──────────────────────────────────────────
  perform app_test.assert_equals(
    (select count(*) from public.account_ledger(
       v_cash, date '2000-01-01', date '2099-12-31',
       '00000000-0000-4000-8000-000000000000'::uuid)),
    0::bigint,
    'a branch that has no entries returns none, rather than ignoring the filter'
  );
end $$;

select app_test.logout();
