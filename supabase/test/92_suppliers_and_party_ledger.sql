-- =============================================================================
-- TEST — the supplier master and the party ledger
-- =============================================================================
-- Spec §41, §44.
--
-- The guarantees asserted here:
--   * a supplier code is issued by the database, dealer-unique, and its sequence
--     provisions itself so a new dealer needs no setup;
--   * one ledger serves every party: the customer ledger is the same code with a
--     different literal, so the two can never disagree;
--   * a supplier ledger reconciles to Supplier Payables — the property that
--     makes a subsidiary ledger worth keeping;
--   * cash and bank movements can be attributed to a supplier, which is what
--     puts anything in that ledger at all;
--   * a movement belongs to one party, never two.
-- =============================================================================

\echo '--- suppliers and the party ledger ---'

do $$
declare
  v_dealer   uuid;
  v_branch   uuid;
  v_supplier uuid;
  v_second   uuid;
  v_customer uuid;
  v_code     text;
  v_payable  uuid;
  v_stock    uuid;
  v_cash     uuid;
  v_bank     uuid;
  v_entry    uuid;
  v_txn      bigint;
  v_balance  numeric;
  v_control  numeric;
  v_opening  numeric;
  v_count    int;
  v_party    text;
  v_party_id uuid;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'MAIN';

  select id into v_payable from public.chart_of_accounts where dealer_id = v_dealer and code = '2200';
  select id into v_stock   from public.chart_of_accounts where dealer_id = v_dealer and code = '1600';
  select id into v_cash    from public.chart_of_accounts where dealer_id = v_dealer and code = '1100';

  -- ═══ The master ══════════════════════════════════════════════════════════
  insert into public.suppliers (dealer_id, name, supplier_type, mobile, city, state)
  values (v_dealer, 'Sundaram Auto Components', 'GOODS', '9840055001', 'Chennai', 'Tamil Nadu')
  returning id, supplier_code into v_supplier, v_code;

  perform app_test.assert_equals(v_code ~ '^SUPP-[0-9]{4}-[0-9]{6}$', true,
    'the supplier code is issued as SUPP-YYYY-NNNNNN');

  -- The sequence provisions itself, the way customer codes do: an identifier
  -- must not fail for want of configuration the way a financial document should.
  select count(*)::int into v_count
    from public.document_sequences
   where dealer_id = v_dealer and doc_type = 'SUPPLIER' and branch_id is null;
  perform app_test.assert_equals(v_count, 1, 'the supplier sequence provisioned itself on first use');

  insert into public.suppliers (dealer_id, name, mobile)
  values (v_dealer, 'Chennai Lubricants', '9840055002')
  returning id, supplier_code into v_second, v_code;

  perform app_test.assert_equals(right(v_code, 6), '000002',
    'the second supplier continues the series');

  perform app_test.assert_raises(
    format('insert into public.suppliers (dealer_id, name, supplier_code) values (%L, ''Dup'', %L)',
           v_dealer, v_code),
    'a supplier code cannot be reused within a dealer');

  perform app_test.assert_raises(
    format('insert into public.suppliers (dealer_id, name, mobile) values (%L, ''Bad'', ''12345'')', v_dealer),
    'a malformed mobile number is refused');

  -- ═══ The ledger ══════════════════════════════════════════════════════════
  -- A purchase on credit: stock in, payable up.
  perform app.post_journal(
    v_dealer, v_branch, date '2026-06-10', 'INVENTORY', 'Purchase from Sundaram',
    jsonb_build_array(
      jsonb_build_object('account_id', v_stock, 'debit', 40000, 'credit', 0),
      jsonb_build_object('account_id', v_payable, 'debit', 0, 'credit', 40000,
                         'party_type', 'SUPPLIER', 'party_id', v_supplier)
    ));

  -- A part payment in July, so June is a carried-forward balance.
  perform app.post_journal(
    v_dealer, v_branch, date '2026-07-04', 'BANK', 'Payment to Sundaram',
    jsonb_build_array(
      jsonb_build_object('account_id', v_payable, 'debit', 15000, 'credit', 0,
                         'party_type', 'SUPPLIER', 'party_id', v_supplier),
      jsonb_build_object('account_id', v_cash, 'debit', 0, 'credit', 15000)
    ));

  -- Another supplier's activity, to prove it never leaks.
  perform app.post_journal(
    v_dealer, v_branch, date '2026-06-20', 'INVENTORY', 'Purchase from Chennai Lubricants',
    jsonb_build_array(
      jsonb_build_object('account_id', v_stock, 'debit', 9000, 'credit', 0),
      jsonb_build_object('account_id', v_payable, 'debit', 0, 'credit', 9000,
                         'party_type', 'SUPPLIER', 'party_id', v_second)
    ));

  -- Debit positive throughout, so a supplier the dealer owes reads negative.
  v_opening := public.party_ledger_opening('SUPPLIER', v_supplier, date '2026-07-01');
  perform app_test.assert_equals(v_opening, -40000::numeric,
    'the balance carried into July is what was owed at the end of June');

  select running_balance into v_balance
    from public.party_ledger('SUPPLIER', v_supplier, date '2026-07-01', date '2026-07-31');
  perform app_test.assert_equals(v_balance, -25000::numeric,
    'the running balance builds on the opening rather than restarting at zero');

  -- Reconciliation to the control account, per party.
  select coalesce(sum(l.debit - l.credit), 0) into v_control
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.party_type = 'SUPPLIER' and l.party_id = v_supplier
     and je.status in ('POSTED', 'REVERSED');

  select running_balance into v_balance
    from public.party_ledger('SUPPLIER', v_supplier, date '2026-01-01', date '2026-12-31')
   order by entry_date desc, entry_number desc limit 1;

  perform app_test.assert_equals(v_balance, v_control,
    'the supplier ledger closes at the balance in the control account');

  perform app_test.assert_equals(
    public.party_ledger_opening('SUPPLIER', v_second, date '2026-12-31'), -9000::numeric,
    'each supplier carries only their own balance');

  -- ═══ One implementation, two parties ═════════════════════════════════════
  select id into v_customer from public.customers where dealer_id = v_dealer limit 1;

  perform app_test.assert_equals(
    public.customer_ledger_opening(v_customer, date '2026-12-31'),
    public.party_ledger_opening('CUSTOMER', v_customer, date '2026-12-31'),
    'the customer ledger is the party ledger, reached by its old name');

  select count(*)::int into v_count from public.customer_ledger(v_customer, date '2026-01-01', date '2026-12-31');
  perform app_test.assert_equals(
    v_count,
    (select count(*)::int from public.party_ledger('CUSTOMER', v_customer, date '2026-01-01', date '2026-12-31')),
    'and returns the same rows through either entry point');

  -- ═══ Attributing money movements to a supplier ═══════════════════════════
  select journal_entry_id into v_entry
    from public.record_cash_transaction(
      v_branch, 'PAYMENT', 2500, 'Cash paid to Sundaram', v_payable,
      null, 'VCH-1', current_date, v_supplier);

  select party_type, party_id into v_party, v_party_id
    from public.journal_entry_lines
   where journal_entry_id = v_entry and party_id is not null;

  perform app_test.assert_equals(v_party, 'SUPPLIER',
    'a cash payment tagged to a supplier writes a SUPPLIER journal line');
  perform app_test.assert_equals(v_party_id, v_supplier,
    'and points at the supplier that was paid');

  select supplier_id into v_party_id from public.cash_transactions
   where journal_entry_id = v_entry;
  perform app_test.assert_equals(v_party_id, v_supplier,
    'the cash book row records the supplier too');

  perform app_test.assert_raises(
    format($f$select public.record_cash_transaction(%L, 'PAYMENT', 100, 'Both', %L, %L, null, current_date, %L)$f$,
           v_branch, v_payable, v_customer, v_supplier),
    'an entry cannot belong to a customer and a supplier at once');

  -- The bank side gained party columns it never had.
  select id into v_bank from public.bank_accounts where dealer_id = v_dealer limit 1;
  if v_bank is not null then
    select journal_entry_id into v_entry
      from public.record_bank_transaction(
        v_bank, 'PAYMENT', 3500, 'NEFT to Sundaram', v_payable,
        current_date, 'NEFT-9', null, null, null, v_supplier);

    select party_type into v_party
      from public.journal_entry_lines
     where journal_entry_id = v_entry and party_id = v_supplier;
    perform app_test.assert_equals(v_party, 'SUPPLIER',
      'a bank payment tagged to a supplier writes a SUPPLIER journal line');
  end if;

  -- Everything above must show up on the ledger, which is the whole point.
  select count(*)::int into v_count
    from public.party_ledger('SUPPLIER', v_supplier, date '2026-01-01', date '2030-12-31');
  perform app_test.assert_equals(v_count >= 4, true,
    'the payments reach the supplier ledger rather than vanishing into 2200');

  -- ═══ And the books still balance ═════════════════════════════════════════
  select sum(l.debit), sum(l.credit) into v_balance, v_control
    from public.journal_entry_lines l
    join public.journal_entries e on e.id = l.journal_entry_id
   where e.dealer_id = v_dealer and e.status in ('POSTED', 'REVERSED');

  perform app_test.assert_equals(v_balance, v_control,
    'the ledger balances after supplier activity');
end;
$$;
