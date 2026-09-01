-- =============================================================================
-- TEST — double-entry integrity and journal immutability
-- =============================================================================
-- Spec §22 (debit = credit), §23 (posted journals are immutable, corrections are
-- reversals), §45 (server-side document numbering), §49 (concurrency safety),
-- §50 (idempotency).
--
-- Runs as the table owner: these are database guarantees that must hold no matter
-- which role or service reaches the table.
-- =============================================================================

\echo '--- accounting integrity ---'

do $$
declare
  v_dealer  uuid;
  v_branch  uuid;
  v_cash    uuid;
  v_sales   uuid;
  v_cgst    uuid;
  v_je      uuid;
  v_reversal uuid;
  v_number  text;
  v_number2 text;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_cash  from public.chart_of_accounts where dealer_id = v_dealer and code = '1100';
  select id into v_sales from public.chart_of_accounts where dealer_id = v_dealer and code = '4100';
  select id into v_cgst  from public.chart_of_accounts where dealer_id = v_dealer and code = '2300';

  -- ── Document numbering is server-side and increments (spec §45) ───────────
  -- Asserted relatively rather than against a fixed number: earlier blocks in
  -- this file have already consumed a run of them.
  v_number  := app.next_document_number(v_dealer, null, 'JOURNAL', '2026');
  v_number2 := app.next_document_number(v_dealer, null, 'JOURNAL', '2026');

  perform app_test.assert_equals(
    v_number ~ '^JE-2026-[0-9]{6}$', true,
    'journal number matches the JE-2026-NNNNNN format from spec §45'
  );
  perform app_test.assert_equals(
    right(v_number2, 6)::int - right(v_number, 6)::int, 1,
    'consecutive calls increment by exactly one'
  );

  perform app_test.assert_raises(
    format('select app.next_document_number(%L, null, ''NOT_CONFIGURED'', ''2026'')', v_dealer),
    'unconfigured document type is rejected rather than silently invented'
  );

  -- ── A journal must be created as DRAFT ────────────────────────────────────
  perform app_test.assert_raises(
    format($f$insert into public.journal_entries
              (dealer_id, branch_id, entry_number, entry_date, source_module, status, posted_at)
              values (%L, %L, 'JE-BAD-1', current_date, 'MANUAL', 'POSTED', now())$f$,
           v_dealer, v_branch),
    'cannot insert a journal directly in POSTED state'
  );

  -- ── Build a balanced draft ────────────────────────────────────────────────
  insert into public.journal_entries
    (dealer_id, branch_id, entry_number, entry_date, source_module, narration, idempotency_key)
  values
    (v_dealer, v_branch, v_number, date '2026-08-30', 'SALES',
     'Vehicle sale — TVS Jupiter 110', 'sale:test:0001')
  returning id into v_je;

  insert into public.journal_entry_lines
    (journal_entry_id, dealer_id, line_number, account_id, branch_id, debit, credit, narration)
  values
    (v_je, v_dealer, 1, v_cash,  v_branch, 84000.00,     0, 'Cash received'),
    (v_je, v_dealer, 2, v_sales, v_branch,        0, 75000.00, 'Vehicle sales'),
    (v_je, v_dealer, 3, v_cgst,  v_branch,        0,  9000.00, 'Output CGST');

  -- Totals are maintained by trigger, not by the caller.
  perform app_test.assert_equals(
    (select total_debit from public.journal_entries where id = v_je), 84000.0000::numeric(18,4),
    'draft total_debit is derived from the lines'
  );
  perform app_test.assert_equals(
    (select total_credit from public.journal_entries where id = v_je), 84000.0000::numeric(18,4),
    'draft total_credit is derived from the lines'
  );

  -- ── An unbalanced journal cannot post (spec §22) ──────────────────────────
  update public.journal_entry_lines set credit = 8000.00
   where journal_entry_id = v_je and line_number = 3;

  perform app_test.assert_raises(
    format('update public.journal_entries set status = ''POSTED'' where id = %L', v_je),
    'unbalanced journal is refused at posting'
  );

  -- Restore balance and post for real.
  update public.journal_entry_lines set credit = 9000.00
   where journal_entry_id = v_je and line_number = 3;

  update public.journal_entries set status = 'POSTED', posted_by = null where id = v_je;

  perform app_test.assert_equals(
    (select status from public.journal_entries where id = v_je), 'POSTED',
    'balanced journal posts'
  );
  perform app_test.assert_equals(
    (select posted_at is not null from public.journal_entries where id = v_je), true,
    'posting stamps posted_at server-side'
  );

  -- ── A posted journal is immutable (spec §23, §60.12) ──────────────────────
  perform app_test.assert_raises(
    format('update public.journal_entries set narration = ''edited'' where id = %L', v_je),
    'cannot edit a posted journal'
  );

  perform app_test.assert_raises(
    format('update public.journal_entries set entry_date = current_date where id = %L', v_je),
    'cannot backdate a posted journal'
  );

  perform app_test.assert_raises(
    format('delete from public.journal_entries where id = %L', v_je),
    'cannot delete a posted journal'
  );

  perform app_test.assert_raises(
    format('update public.journal_entry_lines set debit = 1 where journal_entry_id = %L and line_number = 1', v_je),
    'cannot edit the lines of a posted journal'
  );

  perform app_test.assert_raises(
    format('delete from public.journal_entry_lines where journal_entry_id = %L', v_je),
    'cannot delete the lines of a posted journal'
  );

  perform app_test.assert_raises(
    format($f$insert into public.journal_entry_lines
             (journal_entry_id, dealer_id, line_number, account_id, debit, credit)
             values (%L, %L, 9, %L, 100, 0)$f$, v_je, v_dealer, v_cash),
    'cannot append a line to a posted journal'
  );

  -- ── Correction happens through reversal, and must state a reason (§23) ────
  v_number := app.next_document_number(v_dealer, null, 'JOURNAL', '2026');

  perform app_test.assert_raises(
    format($f$insert into public.journal_entries
             (dealer_id, branch_id, entry_number, entry_date, source_module, reversal_of_id)
             values (%L, %L, 'JE-NOREASON', current_date, 'SALES', %L)$f$,
           v_dealer, v_branch, v_je),
    'a reversal without a reason is rejected'
  );

  insert into public.journal_entries
    (dealer_id, branch_id, entry_number, entry_date, source_module, narration,
     reversal_of_id, reversal_reason)
  values
    (v_dealer, v_branch, v_number, date '2026-08-30', 'SALES',
     'Reversal of ' || (select entry_number from public.journal_entries where id = v_je),
     v_je, 'Wrong chassis selected at billing')
  returning id into v_reversal;

  -- Mirror image of the original.
  insert into public.journal_entry_lines
    (journal_entry_id, dealer_id, line_number, account_id, branch_id, debit, credit)
  values
    (v_reversal, v_dealer, 1, v_cash,  v_branch,        0, 84000.00),
    (v_reversal, v_dealer, 2, v_sales, v_branch, 75000.00,        0),
    (v_reversal, v_dealer, 3, v_cgst,  v_branch,  9000.00,        0);

  update public.journal_entries set status = 'POSTED' where id = v_reversal;

  -- Marking the original as reversed is the one permitted change to a posted row.
  update public.journal_entries
     set status = 'REVERSED', reversed_by_id = v_reversal, reversal_reason = 'Wrong chassis selected at billing'
   where id = v_je;

  perform app_test.assert_equals(
    (select status from public.journal_entries where id = v_je), 'REVERSED',
    'original is marked REVERSED once its reversal is posted'
  );

  perform app_test.assert_raises(
    format('update public.journal_entries set narration = ''again'' where id = %L', v_je),
    'a reversed journal is immutable too'
  );

  -- The pair nets to zero — the ledger is unchanged by the correction.
  perform app_test.assert_equals(
    (select sum(l.debit) - sum(l.credit)
       from public.journal_entry_lines l
      where l.journal_entry_id in (v_je, v_reversal)), 0.0000::numeric,
    'original and reversal net to zero'
  );

  -- ── Idempotency: the same business reference cannot post twice (§50) ──────
  perform app_test.assert_raises(
    format($f$insert into public.journal_entries
             (dealer_id, branch_id, entry_number, entry_date, source_module, idempotency_key)
             values (%L, %L, 'JE-DUPLICATE', current_date, 'SALES', 'sale:test:0001')$f$,
           v_dealer, v_branch),
    'a duplicate idempotency key is rejected'
  );

  -- ── One-sided lines only ──────────────────────────────────────────────────
  v_number := app.next_document_number(v_dealer, null, 'JOURNAL', '2026');
  insert into public.journal_entries
    (dealer_id, branch_id, entry_number, entry_date, source_module)
  values (v_dealer, v_branch, v_number, current_date, 'MANUAL')
  returning id into v_je;

  perform app_test.assert_raises(
    format($f$insert into public.journal_entry_lines
             (journal_entry_id, dealer_id, line_number, account_id, debit, credit)
             values (%L, %L, 1, %L, 500, 500)$f$, v_je, v_dealer, v_cash),
    'a line cannot be both a debit and a credit'
  );

  perform app_test.assert_raises(
    format($f$insert into public.journal_entry_lines
             (journal_entry_id, dealer_id, line_number, account_id, debit, credit)
             values (%L, %L, 1, %L, 0, 0)$f$, v_je, v_dealer, v_cash),
    'a zero-value line is rejected'
  );

  perform app_test.assert_raises(
    format($f$insert into public.journal_entry_lines
             (journal_entry_id, dealer_id, line_number, account_id, debit, credit)
             values (%L, %L, 1, %L, -100, 0)$f$, v_je, v_dealer, v_cash),
    'a negative amount is rejected'
  );

  -- A single-line journal cannot post.
  insert into public.journal_entry_lines
    (journal_entry_id, dealer_id, line_number, account_id, debit, credit)
  values (v_je, v_dealer, 1, v_cash, 500, 0);

  perform app_test.assert_raises(
    format('update public.journal_entries set status = ''POSTED'' where id = %L', v_je),
    'a one-line journal cannot post'
  );

  -- A draft, however, can still be discarded.
  delete from public.journal_entries where id = v_je;
  perform app_test.assert_equals(
    (select count(*)::int from public.journal_entries where id = v_je), 0,
    'a draft journal can be deleted'
  );
end;
$$;

-- =============================================================================
-- Cross-tenant references are structurally impossible (spec §60.4)
-- =============================================================================
do $$
declare
  v_dealer_a uuid;
  v_dealer_b uuid;
  v_branch_b uuid;
begin
  select id into v_dealer_a from public.dealers where code = 'SBM';

  insert into public.dealers (code, legal_name, city, state, state_code)
  values ('XTEST', 'Cross Tenant Test Motors', 'Madurai', 'Tamil Nadu', '33')
  returning id into v_dealer_b;

  insert into public.branches (dealer_id, code, name, city, state, state_code)
  values (v_dealer_b, 'MAIN', 'Cross Test Branch', 'Madurai', 'Tamil Nadu', '33')
  returning id into v_branch_b;

  -- Dealer A's employee pointing at Dealer B's branch: rejected by the composite FK.
  perform app_test.assert_raises(
    format($f$insert into public.employees (dealer_id, branch_id, employee_code, name)
             values (%L, %L, 'XEMP001', 'Impossible Employee')$f$, v_dealer_a, v_branch_b),
    'an employee cannot reference another dealer''s branch'
  );

  -- Same for a journal header.
  perform app_test.assert_raises(
    format($f$insert into public.journal_entries
             (dealer_id, branch_id, entry_number, entry_date, source_module)
             values (%L, %L, 'JE-CROSS', current_date, 'MANUAL')$f$, v_dealer_a, v_branch_b),
    'a journal cannot reference another dealer''s branch'
  );

  -- Children first: dealers is referenced ON DELETE RESTRICT by design.
  delete from public.branches where dealer_id = v_dealer_b;
  delete from public.dealers  where id = v_dealer_b;
end;
$$;

-- =============================================================================
-- The books balance (spec §22) and the reporting function agrees with them
-- =============================================================================
do $$
declare
  v_debit   numeric(18, 4);
  v_credit  numeric(18, 4);
  v_assets  numeric(18, 4);
  v_liab_eq numeric(18, 4);
  v_income  numeric(18, 4);
  v_expense numeric(18, 4);
  v_dealer  uuid;
  v_branch  uuid;
begin
  -- Revenue this block posts itself, so the assertions below stand on their own.
  -- They used to lean on seed-demo-ledger.sql, which no longer exists: it painted
  -- journals with no documents behind them, and scripts/seed-demo-data.sql now
  -- produces the same figures by actually trading. That file is deliberately not
  -- loaded here — it consumes document numbers these tests assert against.
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'MAIN';

  perform app.post_journal(
    v_dealer, v_branch, date '2026-08-01', 'SALES',
    'Revenue for the reporting assertions below',
    jsonb_build_array(
      jsonb_build_object(
        'account_id', (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '1300'),
        'debit', 50000, 'credit', 0, 'narration', 'Receivable'),
      jsonb_build_object(
        'account_id', (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '4100'),
        'debit', 0, 'credit', 50000, 'narration', 'Vehicle sales')
    ),
    'TEST', null, 'test:reporting-income');

  -- Every posted journal balances individually, so the whole ledger must too.
  select coalesce(sum(l.debit), 0), coalesce(sum(l.credit), 0)
    into v_debit, v_credit
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where je.status in ('POSTED', 'REVERSED');

  perform app_test.assert_equals(v_debit, v_credit,
    'trial balance: total debits equal total credits across the whole ledger');

  perform app_test.assert_equals(v_debit > 0, true,
    'the demo ledger actually posted something');

  -- Read the same figures back through the function the dashboard uses, so a bug
  -- in account_balances() cannot quietly report numbers the ledger disagrees with.
  select
    coalesce(sum(closing_balance) filter (where account_type = 'ASSET'), 0),
    coalesce(sum(closing_balance) filter (where account_type in ('LIABILITY', 'EQUITY')), 0),
    coalesce(sum(closing_balance) filter (where account_type = 'INCOME'), 0),
    coalesce(sum(closing_balance) filter (where account_type = 'EXPENSE'), 0)
    into v_assets, v_liab_eq, v_income, v_expense
    from public.account_balances(date '2000-01-01', date '2030-12-31', null);

  -- Assets = Liabilities + Equity + (Income - Expenses)
  perform app_test.assert_equals(
    round(v_assets, 2),
    round(v_liab_eq + v_income - v_expense, 2),
    'accounting equation holds: assets = liabilities + equity + retained result'
  );

  perform app_test.assert_equals(v_income > 0, true,
    'account_balances() reports income for the demo period');
end;
$$;

-- Branch filtering in the reporting function must partition, not duplicate.
do $$
declare
  v_all    numeric(18, 4);
  v_summed numeric(18, 4);
begin
  select coalesce(sum(period_debit), 0) into v_all
    from public.account_balances(date '2026-08-01', date '2026-08-31', null);

  select coalesce(sum(b.total), 0) into v_summed
    from public.branches br
    cross join lateral (
      select coalesce(sum(period_debit), 0) as total
        from public.account_balances(date '2026-08-01', date '2026-08-31', br.id)
    ) b
   where br.dealer_id = (select id from public.dealers where code = 'SBM');

  perform app_test.assert_equals(round(v_all, 2), round(v_summed, 2),
    'branch-filtered balances sum to the consolidated total (spec §43)');
end;
$$;

-- =============================================================================
-- Audit trail is append-only (spec §46)
-- =============================================================================
do $$
declare
  v_id bigint;
begin
  perform app_test.assert_equals(
    (select count(*)::int from public.audit_logs) > 0, true,
    'seeding produced audit rows'
  );

  select id into v_id from public.audit_logs order by id limit 1;

  perform app_test.assert_raises(
    format('update public.audit_logs set action = ''CREATE'' where id = %L', v_id),
    'an audit row cannot be updated'
  );

  perform app_test.assert_raises(
    format('delete from public.audit_logs where id = %L', v_id),
    'an audit row cannot be deleted'
  );

  -- The chart-of-accounts insert during seeding should have been captured.
  perform app_test.assert_equals(
    (select count(*)::int from public.audit_logs
      where entity_type = 'chart_of_accounts' and action = 'CREATE') > 0, true,
    'chart of accounts creation is audited'
  );
end;
$$;

\echo '--- accounting integrity passed ---'
