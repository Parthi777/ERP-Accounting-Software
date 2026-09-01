-- =============================================================================
-- TEST — the customer subsidiary ledger
-- =============================================================================
-- Spec §11, §41.
--
-- The guarantees asserted here:
--   * a balance carried in from before the window is the ledger's starting
--     point, so a mid-year statement is not off by everything that came before;
--   * every running balance is the customer's real position on that date, not a
--     total of whatever rows happen to be on screen;
--   * the ledger sums to the receivable control account, which is the property
--     that makes a subsidiary ledger worth keeping at all;
--   * one customer's activity never appears on another's ledger.
-- =============================================================================

\echo '--- customer ledger ---'

do $$
declare
  v_dealer    uuid;
  v_branch    uuid;
  v_alice     uuid;
  v_bob       uuid;
  v_recv      uuid;
  v_sales     uuid;
  v_cash      uuid;
  v_opening   numeric;
  v_balance   numeric;
  v_control   numeric;
  v_count     int;
  v_first     numeric;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'MAIN';

  select id into v_recv  from public.chart_of_accounts where dealer_id = v_dealer and code = '1300';
  select id into v_sales from public.chart_of_accounts where dealer_id = v_dealer and code = '4100';
  select id into v_cash  from public.chart_of_accounts where dealer_id = v_dealer and code = '1100';

  insert into public.customers (dealer_id, name, mobile, city, state, state_code)
  values (v_dealer, 'Ledger Test Alice', '9840097001', 'Chennai', 'Tamil Nadu', '33')
  returning id into v_alice;

  insert into public.customers (dealer_id, name, mobile, city, state, state_code)
  values (v_dealer, 'Ledger Test Bob', '9840097002', 'Chennai', 'Tamil Nadu', '33')
  returning id into v_bob;

  -- ── June: an invoice, then a part payment. This is the carried balance. ────
  perform app.post_journal(
    v_dealer, v_branch, date '2026-06-10', 'SALES', 'Alice invoice',
    jsonb_build_array(
      jsonb_build_object('account_id', v_recv, 'debit', 50000, 'credit', 0,
                         'party_type', 'CUSTOMER', 'party_id', v_alice),
      jsonb_build_object('account_id', v_sales, 'debit', 0, 'credit', 50000)
    ));

  perform app.post_journal(
    v_dealer, v_branch, date '2026-06-20', 'CASH', 'Alice part payment',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', 20000, 'credit', 0),
      jsonb_build_object('account_id', v_recv, 'debit', 0, 'credit', 20000,
                         'party_type', 'CUSTOMER', 'party_id', v_alice)
    ));

  -- Someone else's activity, to prove it never leaks onto Alice's account.
  perform app.post_journal(
    v_dealer, v_branch, date '2026-06-15', 'SALES', 'Bob invoice',
    jsonb_build_array(
      jsonb_build_object('account_id', v_recv, 'debit', 77000, 'credit', 0,
                         'party_type', 'CUSTOMER', 'party_id', v_bob),
      jsonb_build_object('account_id', v_sales, 'debit', 0, 'credit', 77000)
    ));

  -- ── July: one more invoice inside the window we will report on ────────────
  perform app.post_journal(
    v_dealer, v_branch, date '2026-07-05', 'SALES', 'Alice second invoice',
    jsonb_build_array(
      jsonb_build_object('account_id', v_recv, 'debit', 12000, 'credit', 0,
                         'party_type', 'CUSTOMER', 'party_id', v_alice),
      jsonb_build_object('account_id', v_sales, 'debit', 0, 'credit', 12000)
    ));

  -- ── The opening balance (spec §41) ────────────────────────────────────────
  v_opening := public.customer_ledger_opening(v_alice, date '2026-07-01');
  perform app_test.assert_equals(v_opening, 30000::numeric,
    'the balance carried into July is June''s closing, not zero');

  perform app_test.assert_equals(
    public.customer_ledger_opening(v_alice, date '2026-06-01'), 0::numeric,
    'a customer with no prior activity opens at nil');

  -- ── The window itself ─────────────────────────────────────────────────────
  select count(*) into v_count
    from public.customer_ledger(v_alice, date '2026-07-01', date '2026-07-31');
  perform app_test.assert_equals(v_count, 1, 'only July movements appear in a July ledger');

  select running_balance into v_first
    from public.customer_ledger(v_alice, date '2026-07-01', date '2026-07-31');
  -- 30,000 carried in plus a 12,000 invoice. Without the opening it would read
  -- 12,000, understating what Alice owes by the whole carried balance.
  perform app_test.assert_equals(v_first, 42000::numeric,
    'the running balance builds on the opening rather than restarting at zero');

  -- ── Reconciliation to the control account (spec §41) ──────────────────────
  select running_balance into v_balance
    from public.customer_ledger(v_alice, date '2026-01-01', date '2026-12-31')
   order by entry_date desc, entry_number desc limit 1;

  select coalesce(sum(l.debit - l.credit), 0) into v_control
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.party_type = 'CUSTOMER' and l.party_id = v_alice
     and je.status in ('POSTED', 'REVERSED');

  perform app_test.assert_equals(v_balance, v_control,
    'the ledger closes at the customer''s balance in the control account');

  -- ── Isolation between parties ─────────────────────────────────────────────
  perform app_test.assert_equals(
    public.customer_ledger_opening(v_bob, date '2026-07-01'), 77000::numeric,
    'each customer carries only their own balance');

  select count(*) into v_count
    from public.customer_ledger(v_alice, date '2026-01-01', date '2026-12-31')
   where narration like '%Bob%';
  perform app_test.assert_equals(v_count, 0,
    'another customer''s entries never appear on this ledger');

  -- A customer who owes money but did nothing in the window still has a
  -- balance to show, which is why the opening is fetched separately.
  select count(*) into v_count
    from public.customer_ledger(v_bob, date '2026-08-01', date '2026-08-31');
  perform app_test.assert_equals(v_count, 0, 'a quiet month has no movements');
  perform app_test.assert_equals(
    public.customer_ledger_opening(v_bob, date '2026-08-01'), 77000::numeric,
    'but the balance is still there to be reported');
end;
$$;
