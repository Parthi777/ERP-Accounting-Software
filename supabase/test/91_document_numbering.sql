-- =============================================================================
-- TEST — document numbering is dealer-wide
-- =============================================================================
-- Spec §45, §60.3.
--
-- The guarantees asserted here:
--   * a document series has one counter per dealer, not one per branch, so two
--     branches issuing the same kind of document never produce the same number;
--   * the number is what the unique constraint on the storing table demands —
--     these constraints are all (dealer_id, <number>), so a per-branch counter
--     would be rejected the moment a second branch used it;
--   * a dealer-wide sequence takes precedence over a branch one, which is how
--     the scope is decided by configuration rather than by each call site;
--   * a type configured only per branch still numbers per branch.
-- =============================================================================

\echo '--- document numbering ---'

do $$
declare
  v_dealer   uuid;
  v_main     uuid;
  v_north    uuid;
  v_south    uuid;
  v_fy       text;
  v_a        text;
  v_b        text;
  v_c        text;
  v_count    int;
  v_last     bigint;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_main  from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_north from public.branches where dealer_id = v_dealer and code = 'NORTH';
  select id into v_south from public.branches where dealer_id = v_dealer and code = 'SOUTH';

  v_fy := app.financial_year_token(v_dealer, current_date);

  -- ═══ One counter per dealer ══════════════════════════════════════════════
  -- Three calls naming three different branches. Under the old branch-scoped
  -- scheme each branch had its own counter starting at 1, so these would have
  -- returned the same number three times over.
  v_a := app.next_document_number(v_dealer, v_main,  'VEHICLE_INVOICE', v_fy);
  v_b := app.next_document_number(v_dealer, v_north, 'VEHICLE_INVOICE', v_fy);
  v_c := app.next_document_number(v_dealer, v_south, 'VEHICLE_INVOICE', v_fy);

  perform app_test.assert_equals(v_a ~ '^INV-[0-9]{4}-[0-9]{6}$', true,
    'the invoice number follows the INV-YYYY-NNNNNN format');
  perform app_test.assert_equals(
    cardinality(array[v_a, v_b, v_c]), 3,
    'three calls returned three numbers');
  perform app_test.assert_equals(
    (select count(distinct n)::int from unnest(array[v_a, v_b, v_c]) n), 3,
    'naming a different branch does not restart the series');

  -- Consecutive, because it is one counter and not three.
  perform app_test.assert_equals(
    right(v_b, 6)::bigint - right(v_a, 6)::bigint, 1::bigint,
    'the second branch continues the dealer series rather than starting its own');
  perform app_test.assert_equals(
    right(v_c, 6)::bigint - right(v_b, 6)::bigint, 1::bigint,
    'and so does the third');

  -- ═══ The branch argument no longer selects the counter ═══════════════════
  -- Passing null and passing a branch reach the same row, which is what makes
  -- every existing caller correct without being rewritten.
  v_a := app.next_document_number(v_dealer, null,   'BOOKING', v_fy);
  v_b := app.next_document_number(v_dealer, v_north, 'BOOKING', v_fy);
  perform app_test.assert_equals(
    right(v_b, 6)::bigint - right(v_a, 6)::bigint, 1::bigint,
    'a branch call and a dealer-wide call share one counter');

  -- ═══ Every series that a per-dealer constraint stores ════════════════════
  for v_a in
    select unnest(array['VEHICLE_INVOICE', 'BOOKING', 'RECEIPT', 'PAYMENT',
                        'JOB_CARD', 'SERVICE_INVOICE', 'COUNTER_INVOICE',
                        'STOCK_TRANSFER', 'DELIVERY',
                        'FINANCE_APPLICATION', 'FINANCE_SETTLEMENT'])
  loop
    select count(*)::int into v_count
      from public.document_sequences
     where dealer_id = v_dealer and doc_type = v_a
       and financial_year = v_fy and branch_id is null;

    perform app_test.assert_equals(v_count, 1,
      format('%s is configured as a dealer-wide series', v_a));
  end loop;

  -- ═══ Precedence, and the fallback that keeps per-branch series possible ══
  -- A type with only a branch row still numbers per branch: scope is decided by
  -- what is configured, not by the caller.
  insert into public.document_sequences
    (dealer_id, branch_id, doc_type, financial_year, prefix, padding, last_number)
  values (v_dealer, v_main, 'TEST_BRANCH_ONLY', v_fy, 'TBO', 6, 0);

  v_a := app.next_document_number(v_dealer, v_main, 'TEST_BRANCH_ONLY', v_fy);
  perform app_test.assert_equals(v_a, 'TBO-' || v_fy || '-000001',
    'a type configured only per branch still numbers per branch');

  perform app_test.assert_raises(
    format('select app.next_document_number(%L, %L, ''TEST_BRANCH_ONLY'', %L)',
           v_dealer, v_north, v_fy),
    'and a branch with no row of its own is refused rather than guessed at');

  -- Adding a dealer-wide row takes precedence from then on.
  insert into public.document_sequences
    (dealer_id, branch_id, doc_type, financial_year, prefix, padding, last_number)
  values (v_dealer, null, 'TEST_BRANCH_ONLY', v_fy, 'TBO', 6, 40);

  v_a := app.next_document_number(v_dealer, v_main, 'TEST_BRANCH_ONLY', v_fy);
  perform app_test.assert_equals(v_a, 'TBO-' || v_fy || '-000041',
    'a dealer-wide row takes precedence over the branch row');

  -- ═══ Nothing was reissued ════════════════════════════════════════════════
  -- The backfill carried each dealer's highest branch counter forward, so a
  -- number already handed to a customer can never come round again.
  select last_number into v_last
    from public.document_sequences
   where dealer_id = v_dealer and doc_type = 'VEHICLE_INVOICE'
     and financial_year = v_fy and branch_id is null;

  perform app_test.assert_equals(
    v_last >= coalesce((select max(ds.last_number) from public.document_sequences ds
                         where ds.dealer_id = v_dealer and ds.doc_type = 'VEHICLE_INVOICE'
                           and ds.financial_year = v_fy and ds.branch_id is not null), 0),
    true,
    'the dealer-wide counter is at or above every branch counter it replaced');

  -- ═══ And the constraint the whole thing exists to satisfy ════════════════
  perform app_test.assert_raises(
    format($f$insert into public.bookings
             (dealer_id, branch_id, booking_number, customer_id, model_id, booking_amount)
             select %L, %L, b.booking_number, b.customer_id, b.model_id, 0
               from public.bookings b where b.dealer_id = %L limit 1$f$,
           v_dealer, v_north, v_dealer),
    'two bookings cannot share a number, whatever branch raised them');
end;
$$;
