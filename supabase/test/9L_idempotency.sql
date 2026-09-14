-- =============================================================================
-- TEST — a retried receipt is the same receipt (spec §50)
-- =============================================================================
-- Before 0061 these three functions had no duplicate protection at all. A
-- double-click that outran the disabled button, a phone retrying on a flaky shop
-- connection, a resent POST — any of them gave the dealer two receipts, two
-- journals, and a cash book over by the amount. Nothing downstream caught it:
-- these are the primary record, not a correction some later screen reconciles.
--
-- The guarantees asserted here:
--   * the same key twice writes one row and replays the first answer;
--   * two *different* keys with identical amounts write two rows — idempotency
--     must not become accidental deduplication, because a cashier really does
--     take ₹500 twice in a day;
--   * a null key behaves exactly as before, so nothing that does not opt in
--     changed;
--   * a replay does not consume a document number — a gap in a receipt series
--     is a GST problem, not a cosmetic one;
--   * one dealer's key cannot collide with another's.
-- =============================================================================

\echo '--- idempotency ---'

do $$
declare
  v_dealer   uuid;
  v_branch   uuid;
  v_income   uuid;
  v_bank     uuid;
  v_expense  uuid;
  v_sale     uuid;
  v_txn1     bigint;
  v_txn2     bigint;
  v_txn3     bigint;
  v_bal1     numeric;
  v_bal2     numeric;
  v_count    int;
  v_seq_before bigint;
  v_seq_after  bigint;
  v_r1       text;
  v_r2       text;
  v_e1       uuid;
  v_e2       uuid;
  v_day      date := date '2026-11-11';
begin
  select id into v_dealer from public.dealers  where code = 'SBM';
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_income  from public.chart_of_accounts
   where dealer_id = v_dealer and account_type = 'INCOME' order by code limit 1;
  select id into v_expense from public.chart_of_accounts
   where dealer_id = v_dealer and account_type = 'EXPENSE' order by code limit 1;
  select id into v_bank from public.bank_accounts where dealer_id = v_dealer and status = 'ACTIVE' limit 1;

  -- ── Cash: the same key twice is one receipt ─────────────────────────────
  select transaction_id, balance_after into v_txn1, v_bal1
    from public.record_cash_transaction(
      v_branch, 'RECEIPT', 1500, 'Idempotent receipt', v_income,
      null, 'IDEM-REF', v_day, null, 'test-cash-key-1');

  select transaction_id, balance_after into v_txn2, v_bal2
    from public.record_cash_transaction(
      v_branch, 'RECEIPT', 1500, 'Idempotent receipt', v_income,
      null, 'IDEM-REF', v_day, null, 'test-cash-key-1');

  perform app_test.assert_equals(
    v_txn2, v_txn1,
    'a retried cash receipt replays the first transaction id'
  );
  perform app_test.assert_equals(
    v_bal2, v_bal1,
    'and the same balance — the cash book did not move twice'
  );

  select count(*) into v_count from public.cash_transactions
   where dealer_id = v_dealer and idempotency_key = 'test-cash-key-1';
  perform app_test.assert_equals(v_count, 1, 'exactly one row carries that key');

  -- ── A different key is a different receipt ──────────────────────────────
  -- The same amount, the same particular, the same second. Only the key says
  -- these are two events, and it must be believed.
  select transaction_id into v_txn3
    from public.record_cash_transaction(
      v_branch, 'RECEIPT', 1500, 'Idempotent receipt', v_income,
      null, 'IDEM-REF', v_day, null, 'test-cash-key-2');

  perform app_test.assert_equals(
    (v_txn3 <> v_txn1), true,
    'an identical amount under a different key is a second receipt, not a replay'
  );

  -- ── No key behaves exactly as it always did ─────────────────────────────
  select transaction_id into v_txn1
    from public.record_cash_transaction(
      v_branch, 'PAYMENT', 40, 'Unkeyed payment', v_expense, null, null, v_day);
  select transaction_id into v_txn2
    from public.record_cash_transaction(
      v_branch, 'PAYMENT', 40, 'Unkeyed payment', v_expense, null, null, v_day);

  perform app_test.assert_equals(
    (v_txn2 <> v_txn1), true,
    'two unkeyed entries are still two entries — nothing opted in changed'
  );

  -- ── Bank: the same guarantees ───────────────────────────────────────────
  select transaction_id, balance_after into v_txn1, v_bal1
    from public.record_bank_transaction(
      v_bank, 'RECEIPT', 2500, 'Idempotent bank receipt', v_income,
      v_day, 'NEFT-1', null, null, null, null, 'test-bank-key-1');

  select transaction_id, balance_after into v_txn2, v_bal2
    from public.record_bank_transaction(
      v_bank, 'RECEIPT', 2500, 'Idempotent bank receipt', v_income,
      v_day, 'NEFT-1', null, null, null, null, 'test-bank-key-1');

  perform app_test.assert_equals(v_txn2, v_txn1, 'a retried bank receipt replays');
  perform app_test.assert_equals(v_bal2, v_bal1, 'and the bank balance did not move twice');

  select count(*) into v_count from public.bank_transactions
   where dealer_id = v_dealer and idempotency_key = 'test-bank-key-1';
  perform app_test.assert_equals(v_count, 1, 'one bank row carries that key');

  -- ── Sale payment: the replay must not burn a receipt number ─────────────
  select id into v_sale from public.sales
   where dealer_id = v_dealer and status in ('POSTED', 'DELIVERED')
   order by created_at limit 1;

  if v_sale is null then
    raise notice '  -- no posted sale in this database; skipping the receipt-number checks';
  else
    select last_number into v_seq_before from public.document_sequences
     where dealer_id = v_dealer and doc_type = 'RECEIPT'
     order by financial_year desc limit 1;

    select receipt_number, journal_entry_id into v_r1, v_e1
      from public.record_sale_payment(v_sale, 250, 'CASH', 'Idem receipt', null, 'test-sale-key-1');
    select receipt_number, journal_entry_id into v_r2, v_e2
      from public.record_sale_payment(v_sale, 250, 'CASH', 'Idem receipt', null, 'test-sale-key-1');

    perform app_test.assert_equals(v_r2, v_r1, 'a retried sale payment replays the same receipt number');
    perform app_test.assert_equals(v_e2, v_e1, 'and the same journal — not a second one');

    select count(*) into v_count from public.sale_payments
     where dealer_id = v_dealer and idempotency_key = 'test-sale-key-1';
    perform app_test.assert_equals(v_count, 1, 'one receipt row carries that key');

    select last_number into v_seq_after from public.document_sequences
     where dealer_id = v_dealer and doc_type = 'RECEIPT'
     order by financial_year desc limit 1;

    -- The assertion that would have caught the old bug. 'receipt:' || v_rnumber
    -- was minted from this very sequence, so the key differed on every call and
    -- the journal guard could never fire.
    perform app_test.assert_equals(
      v_seq_after - v_seq_before, 1::bigint,
      'a replayed pair consumes one receipt number, not two — a gap in a financial series is not cosmetic'
    );
  end if;
end $$;

-- ── One dealer's key cannot collide with another's ────────────────────────
do $$
declare
  v_other   uuid;
  v_branch  uuid;
  v_income  uuid;
  v_txn     bigint;
  v_count   int;
begin
  -- 9G provisions a second dealer; if it is not present there is nothing to
  -- prove here and saying so is better than a silent pass.
  select id into v_other from public.dealers where code <> 'SBM' order by code limit 1;
  if v_other is null then
    raise notice '  -- only one dealer in this database; skipping the cross-tenant check';
    return;
  end if;

  select id into v_branch from public.branches where dealer_id = v_other order by code limit 1;
  select id into v_income from public.chart_of_accounts
   where dealer_id = v_other and account_type = 'INCOME' order by code limit 1;

  if v_branch is null or v_income is null
     or not exists (select 1 from public.cash_accounts where branch_id = v_branch) then
    raise notice '  -- the second dealer has no cash account; skipping the cross-tenant check';
    return;
  end if;

  -- The identical key string the first dealer already used.
  select transaction_id into v_txn
    from public.record_cash_transaction(
      v_branch, 'RECEIPT', 99, 'Other tenant, same key', v_income,
      null, null, date '2026-11-11', null, 'test-cash-key-1');

  perform app_test.assert_equals(
    (v_txn is not null), true,
    'another dealer may use the same key string — the constraint is (dealer_id, key)'
  );

  select count(*) into v_count from public.cash_transactions
   where idempotency_key = 'test-cash-key-1';
  perform app_test.assert_equals(
    v_count, 2, 'and that is two rows across two tenants, not one shared row'
  );
end $$;
