-- =============================================================================
-- TEST — opening balances (spec §24, §41)
-- =============================================================================
-- A dealer switching systems arrives owed money and owing it. Until those
-- balances are on the books, every ledger and ageing report describes a business
-- that began the day they signed up.
--
-- The guarantees asserted here:
--   * the entry balances — by construction, not by hoping the file added up;
--   * each party's opening lands where party_ledger_opening reads it, so the
--     customer and supplier ledger screens agree with what was imported;
--   * the sign convention works in both directions: a positive amount is owed
--     to the dealer, a negative one is an advance already held;
--   * posting the same cut-over twice replays rather than doubling — of all the
--     things to post twice this is the worst, because nobody notices until a
--     customer disputes a statement;
--   * an unknown party code stops the whole file rather than being skipped.
-- =============================================================================

\echo '--- opening balances ---'

do $$
declare
  v_dealer  uuid;
  v_c1      text;
  v_c2      text;
  v_entry   uuid;
  v_entry2  uuid;
  v_parties int;
  v_debit   numeric;
  v_credit  numeric;
  v_open1   numeric;
  v_open2   numeric;
  v_equity  numeric;
begin
  select id into v_dealer from public.dealers where code = 'SBM';

  -- Two customers with known codes, so the ledger can be checked by party.
  insert into public.customers (dealer_id, customer_code, name, mobile)
  values (v_dealer, 'OPEN-0001', 'Opening Debtor', '9700000001')
  returning customer_code into v_c1;

  insert into public.customers (dealer_id, customer_code, name, mobile)
  values (v_dealer, 'OPEN-0002', 'Opening Advance Holder', '9700000002')
  returning customer_code into v_c2;

  -- One owes us 12,500; the other has already paid us 3,000 we have not earned.
  select journal_entry_id, parties into v_entry, v_parties
    from public.post_opening_balances(
      'CUSTOMER',
      jsonb_build_array(
        jsonb_build_object('party_code', v_c1, 'amount', 12500),
        jsonb_build_object('party_code', v_c2, 'amount', -3000)
      ),
      date '2026-04-01',
      'Cut-over from the old system',
      'test-opening-customers');

  perform app_test.assert_equals(v_parties, 2, 'both parties became lines');

  -- ── It balances ─────────────────────────────────────────────────────────
  select sum(debit), sum(credit) into v_debit, v_credit
    from public.journal_entry_lines where journal_entry_id = v_entry;
  perform app_test.assert_equals(
    v_debit, v_credit, 'the opening entry balances (spec §22)'
  );
  -- 12,500 debit against 3,000 + 9,500 credit. The advance is a credit to the
  -- *same* control account, so it offsets within 1300 rather than adding to the
  -- entry's size — which is why the equity line is the net 9,500 and not 15,500.
  perform app_test.assert_equals(
    v_debit, 12500::numeric,
    'the debit side is the gross receivable, the advance offsetting within the control account'
  );

  -- ── Each party reads back where the ledger screens look ─────────────────
  select public.party_ledger_opening('CUSTOMER',
           (select id from public.customers where customer_code = v_c1), 'infinity'::date)
    into v_open1;
  perform app_test.assert_equals(
    v_open1, 12500::numeric,
    'a debtor opening reaches the party ledger the customer screen reads'
  );

  select public.party_ledger_opening('CUSTOMER',
           (select id from public.customers where customer_code = v_c2), 'infinity'::date)
    into v_open2;
  perform app_test.assert_equals(
    v_open2, -3000::numeric,
    'and a negative amount is an advance held, not a debt'
  );

  -- ── The equity side carries the net ─────────────────────────────────────
  select coalesce(sum(l.credit - l.debit), 0) into v_equity
    from public.journal_entry_lines l
    join public.chart_of_accounts c on c.id = l.account_id
   where l.journal_entry_id = v_entry and c.code = '3300';
  perform app_test.assert_equals(
    v_equity, 9500::numeric,
    'Opening Balance Equity holds the net, so it reads as what is still to be reconciled'
  );

  -- ── Posting the cut-over twice replays it ───────────────────────────────
  select journal_entry_id into v_entry2
    from public.post_opening_balances(
      'CUSTOMER',
      jsonb_build_array(
        jsonb_build_object('party_code', v_c1, 'amount', 12500),
        jsonb_build_object('party_code', v_c2, 'amount', -3000)
      ),
      date '2026-04-01', null, 'test-opening-customers');

  perform app_test.assert_equals(
    v_entry2, v_entry, 'running the cut-over twice replays the same journal'
  );

  select public.party_ledger_opening('CUSTOMER',
           (select id from public.customers where customer_code = v_c1), 'infinity'::date)
    into v_open1;
  perform app_test.assert_equals(
    v_open1, 12500::numeric, 'and does not double the balance'
  );

  -- ── An unknown code stops the file ──────────────────────────────────────
  -- Skipping it would leave the operator believing a party was migrated when it
  -- was not, and the shortfall would surface as an unexplained equity balance.
  perform app_test.assert_raises(
    format($q$select public.post_opening_balances('CUSTOMER',
             jsonb_build_array(jsonb_build_object('party_code', 'NO-SUCH-CODE', 'amount', 100)),
             %L)$q$, date '2026-04-01'),
    'an unknown party code rejects the whole file'
  );

  -- ── Zero rows are not lines ─────────────────────────────────────────────
  perform app_test.assert_raises(
    format($q$select public.post_opening_balances('CUSTOMER',
             jsonb_build_array(jsonb_build_object('party_code', %L, 'amount', 0)),
             %L)$q$, v_c1, date '2026-04-01'),
    'a file of nothing but zeros posts nothing'
  );

  perform app_test.assert_raises(
    $q$select public.post_opening_balances('PARTNER', '[]'::jsonb)$q$,
    'opening balances are only for customers and suppliers'
  );
end $$;

-- ── Suppliers post to the payable side ────────────────────────────────────
do $$
declare
  v_dealer uuid;
  v_code   text;
  v_entry  uuid;
  v_open   numeric;
  v_debit  numeric;
  v_credit numeric;
begin
  select id into v_dealer from public.dealers where code = 'SBM';

  insert into public.suppliers (dealer_id, supplier_code, name)
  values (v_dealer, 'OPENSUP-0001', 'Opening Creditor')
  returning supplier_code into v_code;

  -- Positive means the party owes us; for a supplier that is unusual but real —
  -- an advance we have paid. 8,000 owed TO the supplier is negative.
  select journal_entry_id into v_entry
    from public.post_opening_balances(
      'SUPPLIER',
      jsonb_build_array(jsonb_build_object('party_code', v_code, 'amount', -8000)),
      date '2026-04-01', null, 'test-opening-suppliers');

  select sum(debit), sum(credit) into v_debit, v_credit
    from public.journal_entry_lines where journal_entry_id = v_entry;
  perform app_test.assert_equals(v_debit, v_credit, 'the supplier opening balances too');

  select public.party_ledger_opening('SUPPLIER',
           (select id from public.suppliers where supplier_code = v_code), 'infinity'::date)
    into v_open;
  perform app_test.assert_equals(
    v_open, -8000::numeric,
    'and the supplier ledger shows the dealer owing, not being owed'
  );
end $$;

-- ── The whole ledger still balances afterwards ────────────────────────────
do $$
declare v_ok boolean;
begin
  select sum(debit) = sum(credit) into v_ok from public.journal_entry_lines;
  perform app_test.assert_equals(
    v_ok, true, 'the dealer ledger still balances after a cut-over (spec §22)'
  );
end $$;
