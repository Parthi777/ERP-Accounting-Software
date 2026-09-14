-- =============================================================================
-- TEST — re-importing a bank statement imports it once (spec §39)
-- =============================================================================
-- Overlapping statements are the ordinary case, not an edge one: a dealer
-- downloading "this month" on the 20th and again on the 30th has ten days of
-- rows in both files. import_bank_statement counts on bsl_dedupe_key to skip
-- what it has already staged.
--
-- The protection has existed since 0022 and nothing has ever proved it. If the
-- index were dropped or its column list changed, the `unique_violation` handler
-- would stop firing and every re-import would double the statement — with no
-- error, because the handler swallows exactly that exception.
-- =============================================================================

\echo '--- bank statement dedupe ---'

do $$
declare
  v_dealer  uuid;
  v_account uuid;
  v_rows    jsonb;
  v_first   record;
  v_second  record;
  v_count   int;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_account from public.bank_accounts
   where dealer_id = v_dealer and status = 'ACTIVE' limit 1;

  if v_account is null then
    raise notice '  -- no bank account in this database; skipping';
    return;
  end if;

  v_rows := jsonb_build_array(
    jsonb_build_object('statement_date', '2026-05-01', 'narration', 'NEFT IN ACME',
                       'utr', 'UTR-DEDUPE-1', 'debit', 0, 'credit', 5000),
    jsonb_build_object('statement_date', '2026-05-02', 'narration', 'CHEQUE PAID',
                       'utr', null, 'debit', 1200, 'credit', 0)
  );

  select * into v_first from public.import_bank_statement(v_account, v_rows);
  perform app_test.assert_equals(v_first.imported, 2, 'a fresh statement stages every line');
  perform app_test.assert_equals(v_first.skipped, 0, 'and skips none of it');

  -- The same file again, as a dealer re-downloading an overlapping period.
  select * into v_second from public.import_bank_statement(v_account, v_rows);
  perform app_test.assert_equals(
    v_second.imported, 0, 'the same statement again stages nothing new'
  );
  perform app_test.assert_equals(
    v_second.skipped, 2, 'and reports every line as already held'
  );

  select count(*) into v_count from public.bank_statement_lines
   where bank_account_id = v_account and narration in ('NEFT IN ACME', 'CHEQUE PAID');
  perform app_test.assert_equals(
    v_count, 2, 'so the account still holds one copy of each line, not two'
  );

  -- A genuinely different line on the same day must still come through: the key
  -- is the whole row, not the date.
  select * into v_first from public.import_bank_statement(
    v_account,
    jsonb_build_array(jsonb_build_object(
      'statement_date', '2026-05-01', 'narration', 'NEFT IN ACME',
      'utr', 'UTR-DEDUPE-2', 'debit', 0, 'credit', 5000))
  );
  perform app_test.assert_equals(
    v_first.imported, 1,
    'a different UTR on the same date and amount is a different transaction'
  );

  -- Two genuinely identical payments in one day are indistinguishable by the
  -- key, so the second is treated as a duplicate. Worth pinning as known
  -- behaviour: a dealer taking the same amount twice from the same payer on one
  -- day sees one line, and reconciles the other by hand.
  select * into v_second from public.import_bank_statement(
    v_account,
    jsonb_build_array(jsonb_build_object(
      'statement_date', '2026-05-02', 'narration', 'CHEQUE PAID',
      'utr', null, 'debit', 1200, 'credit', 0))
  );
  perform app_test.assert_equals(
    v_second.skipped, 1,
    'an identical row on the same day cannot be told apart — known limitation'
  );
end $$;

-- ── The index the whole thing rests on ────────────────────────────────────
do $$
declare v_exists boolean;
begin
  select exists (
    select 1 from pg_indexes
     where schemaname = 'public' and indexname = 'bsl_dedupe_key'
  ) into v_exists;

  perform app_test.assert_equals(
    v_exists, true,
    'bsl_dedupe_key exists — without it the unique_violation handler never fires'
  );
end $$;
