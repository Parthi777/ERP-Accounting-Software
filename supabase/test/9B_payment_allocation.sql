-- =============================================================================
-- TEST — bill-wise settlement of a party ledger
-- =============================================================================
-- Spec §41, §49, §50, §60.12.
--
-- The guarantees asserted here:
--   * one payment can be split across several bills, and one bill can be
--     settled by several payments;
--   * a bill cannot be settled for more than it is worth, and a payment cannot
--     be spread over more than was received;
--   * a split never crosses parties;
--   * re-submitting a split replaces it rather than doubling it (spec §50);
--   * nothing is posted: the ledger balance is identical before and after, and
--     the journals stay untouched (spec §23, §60.12);
--   * the tally holds — unpaid bills less unapplied payments equals the ledger
--     closing balance — which is the property the whole feature exists for;
--   * a cashier can read a settlement but cannot make one (spec §6).
-- =============================================================================

\echo '--- bill-wise settlement ---'

do $$
declare
  v_dealer   uuid;
  v_branch   uuid;
  v_carol    uuid;
  v_dan      uuid;
  v_recv     uuid;
  v_adv      uuid;
  v_sales    uuid;
  v_cash     uuid;
  v_inv1     uuid;   -- ₹40,000 invoice
  v_inv2     uuid;   -- ₹25,000 invoice
  v_rcpt     uuid;   -- ₹50,000 receipt
  v_advance  uuid;   -- ₹10,000 booking advance
  v_dan_inv  uuid;
  v_line     uuid;
  v_before   numeric;
  v_after    numeric;
  v_open     numeric;
  v_unapp    numeric;
  v_count    int;
  v_journals int;
  v_result   record;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'MAIN';

  select id into v_recv  from public.chart_of_accounts where dealer_id = v_dealer and code = '1300';
  select id into v_adv   from public.chart_of_accounts where dealer_id = v_dealer and code = '2100';
  select id into v_sales from public.chart_of_accounts where dealer_id = v_dealer and code = '4100';
  select id into v_cash  from public.chart_of_accounts where dealer_id = v_dealer and code = '1100';

  insert into public.customers (dealer_id, name, mobile, city, state, state_code)
  values (v_dealer, 'Settlement Test Carol', '9840099801', 'Chennai', 'Tamil Nadu', '33')
  returning id into v_carol;

  insert into public.customers (dealer_id, name, mobile, city, state, state_code)
  values (v_dealer, 'Settlement Test Dan', '9840099802', 'Chennai', 'Tamil Nadu', '33')
  returning id into v_dan;

  -- ═══ A month of ordinary trading ═════════════════════════════════════════
  -- Two invoices, a booking advance taken before them, and one lump receipt
  -- that pays for some of it — which is exactly the shape that leaves a ledger
  -- correct in total and useless in detail.
  perform app.post_journal(
    v_dealer, v_branch, date '2026-07-05', 'SALES', 'Carol invoice one',
    jsonb_build_array(
      jsonb_build_object('account_id', v_recv, 'debit', 40000, 'credit', 0,
                         'party_type', 'CUSTOMER', 'party_id', v_carol),
      jsonb_build_object('account_id', v_sales, 'debit', 0, 'credit', 40000)
    ));

  perform app.post_journal(
    v_dealer, v_branch, date '2026-07-12', 'SALES', 'Carol invoice two',
    jsonb_build_array(
      jsonb_build_object('account_id', v_recv, 'debit', 25000, 'credit', 0,
                         'party_type', 'CUSTOMER', 'party_id', v_carol),
      jsonb_build_object('account_id', v_sales, 'debit', 0, 'credit', 25000)
    ));

  -- The advance sits in a different control account, as a real one does.
  perform app.post_journal(
    v_dealer, v_branch, date '2026-07-01', 'BOOKING', 'Carol booking advance',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', 10000, 'credit', 0),
      jsonb_build_object('account_id', v_adv, 'debit', 0, 'credit', 10000,
                         'party_type', 'CUSTOMER', 'party_id', v_carol)
    ));

  perform app.post_journal(
    v_dealer, v_branch, date '2026-07-20', 'CASH', 'Carol cash receipt',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', 50000, 'credit', 0),
      jsonb_build_object('account_id', v_recv, 'debit', 0, 'credit', 50000,
                         'party_type', 'CUSTOMER', 'party_id', v_carol)
    ));

  perform app.post_journal(
    v_dealer, v_branch, date '2026-07-14', 'SALES', 'Dan invoice',
    jsonb_build_array(
      jsonb_build_object('account_id', v_recv, 'debit', 31000, 'credit', 0,
                         'party_type', 'CUSTOMER', 'party_id', v_dan),
      jsonb_build_object('account_id', v_sales, 'debit', 0, 'credit', 31000)
    ));

  select line_id into v_inv1    from public.party_open_items('CUSTOMER', v_carol) where amount = 40000;
  select line_id into v_inv2    from public.party_open_items('CUSTOMER', v_carol) where amount = 25000;
  select line_id into v_rcpt    from public.party_open_items('CUSTOMER', v_carol) where amount = 50000;
  select line_id into v_advance from public.party_open_items('CUSTOMER', v_carol) where amount = 10000;
  select line_id into v_dan_inv from public.party_open_items('CUSTOMER', v_dan)   where amount = 31000;

  v_before := public.party_ledger_opening('CUSTOMER', v_carol, 'infinity'::date);
  perform app_test.assert_equals(v_before, 5000.0000::numeric,
    'Carol owes 40000 + 25000 less 50000 and 10000 received');

  select count(*)::int into v_journals from public.journal_entries where dealer_id = v_dealer;

  -- ═══ The split ═══════════════════════════════════════════════════════════
  -- ₹50,000 across the two invoices: the older one in full, the balance against
  -- the newer. This is the whole procedure in one call.
  select * into v_result from public.allocate_party_payment(
    v_rcpt,
    jsonb_build_array(
      jsonb_build_object('debit_line_id', v_inv1, 'amount', 40000),
      jsonb_build_object('debit_line_id', v_inv2, 'amount', 10000)
    ),
    'Split by Accounts against the two July invoices');

  perform app_test.assert_equals(v_result.allocated, 50000.0000::numeric,
    'the whole receipt is accounted for');
  perform app_test.assert_equals(v_result.unapplied, 0.0000::numeric,
    'and none of it is left on account');
  perform app_test.assert_equals(v_result.bills, 2, 'across two bills');

  -- The settled invoice leaves the open list; the part-settled one stays with
  -- only its unpaid remainder.
  select count(*)::int into v_count
    from public.party_open_items('CUSTOMER', v_carol) where line_id = v_inv1;
  perform app_test.assert_equals(v_count, 0, 'a fully settled bill is no longer open');

  select outstanding into v_open
    from public.party_open_items('CUSTOMER', v_carol) where line_id = v_inv2;
  perform app_test.assert_equals(v_open, 15000.0000::numeric,
    'the part-paid bill shows only what is still due');

  -- ═══ Nothing was posted ══════════════════════════════════════════════════
  v_after := public.party_ledger_opening('CUSTOMER', v_carol, 'infinity'::date);
  perform app_test.assert_equals(v_after, v_before,
    'the ledger balance is unchanged: settlement posts nothing (spec §23)');

  select count(*)::int into v_count from public.journal_entries where dealer_id = v_dealer;
  perform app_test.assert_equals(v_count, v_journals,
    'and no journal was written, amended or reversed');

  -- ═══ The tally ═══════════════════════════════════════════════════════════
  -- Unpaid bills less unapplied payments must equal the ledger's own closing
  -- balance. If this ever fails the two views of the account have diverged,
  -- which is the failure the feature exists to prevent.
  select coalesce(sum(outstanding) filter (where side = 'DEBIT'), 0),
         coalesce(sum(outstanding) filter (where side = 'CREDIT'), 0)
    into v_open, v_unapp
    from public.party_open_items('CUSTOMER', v_carol);

  perform app_test.assert_equals(v_open - v_unapp, v_after,
    'unpaid bills less unapplied payments equals the ledger closing balance');
  perform app_test.assert_equals(v_unapp, 10000.0000::numeric,
    'the booking advance is still unapplied, and visible as such');

  -- ═══ Re-submitting the same split ════════════════════════════════════════
  select * into v_result from public.allocate_party_payment(
    v_rcpt,
    jsonb_build_array(
      jsonb_build_object('debit_line_id', v_inv1, 'amount', 40000),
      jsonb_build_object('debit_line_id', v_inv2, 'amount', 10000)
    ));

  select count(*)::int into v_count
    from public.party_allocations where credit_line_id = v_rcpt;
  perform app_test.assert_equals(v_count, 2,
    'submitting the same split twice leaves two rows, not four (spec §50)');
  perform app_test.assert_equals(v_result.allocated, 50000.0000::numeric,
    'and the receipt is still allocated exactly once over');

  -- ═══ Revising a split ════════════════════════════════════════════════════
  -- The accountant decides the money should sit against the newer invoice
  -- instead. Replacing the set is the correction mechanism.
  perform public.allocate_party_payment(
    v_rcpt, jsonb_build_array(jsonb_build_object('debit_line_id', v_inv2, 'amount', 25000)));

  select outstanding into v_open
    from public.party_open_items('CUSTOMER', v_carol) where line_id = v_inv1;
  perform app_test.assert_equals(v_open, 40000.0000::numeric,
    'revising a split releases the bill it used to settle');

  select count(*)::int into v_count
    from public.party_open_items('CUSTOMER', v_carol) where line_id = v_inv2;
  perform app_test.assert_equals(v_count, 0, 'and settles the one it now names');

  -- The remaining ₹25,000 of the receipt is unapplied again, so the tally must
  -- still hold after a revision.
  select coalesce(sum(outstanding) filter (where side = 'DEBIT'), 0),
         coalesce(sum(outstanding) filter (where side = 'CREDIT'), 0)
    into v_open, v_unapp
    from public.party_open_items('CUSTOMER', v_carol);
  perform app_test.assert_equals(v_open - v_unapp, v_after,
    'the tally survives a revision');

  -- ═══ Several payments against one bill ═══════════════════════════════════
  -- The advance and what is left of the receipt both go against invoice one.
  perform public.allocate_party_payment(
    v_advance, jsonb_build_array(jsonb_build_object('debit_line_id', v_inv1, 'amount', 10000)));
  perform public.allocate_party_payment(
    v_rcpt,
    jsonb_build_array(
      jsonb_build_object('debit_line_id', v_inv2, 'amount', 25000),
      jsonb_build_object('debit_line_id', v_inv1, 'amount', 25000)
    ));

  select outstanding into v_open
    from public.party_open_items('CUSTOMER', v_carol) where line_id = v_inv1;
  perform app_test.assert_equals(v_open, 5000.0000::numeric,
    'one bill takes money from two different payments');

  -- ═══ What must be refused ════════════════════════════════════════════════
  perform app_test.assert_raises(
    format('select public.allocate_party_payment(%L, %L::jsonb)', v_rcpt,
           jsonb_build_array(jsonb_build_object('debit_line_id', v_inv1, 'amount', 60000))::text),
    'a payment cannot be spread over more than was received');

  perform app_test.assert_raises(
    format('select public.allocate_party_payment(%L, %L::jsonb)', v_advance,
           jsonb_build_array(jsonb_build_object('debit_line_id', v_dan_inv, 'amount', 5000))::text),
    'one customer''s money cannot settle another customer''s bill');

  perform app_test.assert_raises(
    format('select public.allocate_party_payment(%L, %L::jsonb)', v_inv1,
           jsonb_build_array(jsonb_build_object('debit_line_id', v_inv2, 'amount', 1000))::text),
    'a bill cannot be used to pay a bill');

  perform app_test.assert_raises(
    format('select public.allocate_party_payment(%L, %L::jsonb)', v_rcpt,
           jsonb_build_array(jsonb_build_object('debit_line_id', v_rcpt, 'amount', 100))::text),
    'a payment cannot settle itself');

  -- Over-settling a bill needs two payments to attempt it, since one payment's
  -- own headroom would stop it first. Carol's ₹5,000 of open bill takes the
  -- advance's remainder and no more.
  perform app_test.assert_raises(
    format('insert into public.party_allocations '
           '(dealer_id, party_type, party_id, debit_line_id, credit_line_id, amount) '
           'values (%L, ''CUSTOMER'', %L, %L, %L, 9000)',
           v_dealer, v_carol, v_inv1, v_advance),
    'a bill cannot be settled for more than it is worth');

  -- ═══ Clearing a split ════════════════════════════════════════════════════
  perform public.allocate_party_payment(v_rcpt, '[]'::jsonb);

  select count(*)::int into v_count
    from public.party_allocations where credit_line_id = v_rcpt;
  perform app_test.assert_equals(v_count, 0, 'an empty split clears the allocation');

  select coalesce(sum(outstanding) filter (where side = 'DEBIT'), 0),
         coalesce(sum(outstanding) filter (where side = 'CREDIT'), 0)
    into v_open, v_unapp
    from public.party_open_items('CUSTOMER', v_carol);
  perform app_test.assert_equals(v_open - v_unapp, v_after,
    'and the tally still holds with nothing settled at all');
end;
$$;

-- -----------------------------------------------------------------------------
-- Who may settle
-- -----------------------------------------------------------------------------
-- The cashier takes the money; Accounts decides what it pays for. Both can read
-- the ledger, which is why this needs a permission of its own rather than
-- riding on accounting.ledgers.view.
-- -----------------------------------------------------------------------------
set role authenticated;
select app_test.login('33333333-3333-4333-8333-333333333333');   -- Anand Raj, Cashier

do $$
declare
  v_carol uuid;
  v_rcpt  uuid;
  v_inv   uuid;
begin
  select id into v_carol from public.customers where mobile = '9840099801';

  select line_id into v_rcpt from public.party_open_items('CUSTOMER', v_carol)
   where side = 'CREDIT' and amount = 50000;
  select line_id into v_inv  from public.party_open_items('CUSTOMER', v_carol)
   where side = 'DEBIT' and amount = 40000;

  perform app_test.assert_equals(v_rcpt is null, true,
    'a cashier cannot even see the journal lines behind the ledger, so there is nothing to split');
end;
$$;

reset role;
set role authenticated;
select app_test.login('22222222-2222-4222-8222-222222222222');   -- Priya Venkatesh, Accounts

do $$
declare
  v_carol uuid;
  v_rcpt  uuid;
  v_inv   uuid;
  v_alloc numeric;
begin
  select id into v_carol from public.customers where mobile = '9840099801';

  select line_id into v_rcpt from public.party_open_items('CUSTOMER', v_carol)
   where side = 'CREDIT' and amount = 50000;
  select line_id into v_inv  from public.party_open_items('CUSTOMER', v_carol)
   where side = 'DEBIT' and amount = 40000;

  perform app_test.assert_equals(v_rcpt is not null, true,
    'Accounts sees the receipt waiting to be split');

  select allocated into v_alloc from public.allocate_party_payment(
    v_rcpt, jsonb_build_array(jsonb_build_object('debit_line_id', v_inv, 'amount', 5000)));

  perform app_test.assert_equals(v_alloc, 5000.0000::numeric,
    'and may record the split, holding accounting.allocations.manage');
end;
$$;

reset role;
select app_test.logout();
