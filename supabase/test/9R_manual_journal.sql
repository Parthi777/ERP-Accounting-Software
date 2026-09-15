-- =============================================================================
-- TEST — manual journal entries and reversal (spec §9, §21, §23)
-- =============================================================================
-- Two things a dealer's accountant needs and the product has never had: a way to
-- write an entry by hand, and a way to correct one.
--
-- The second is the important one to get right. A posted journal is immutable —
-- that is what makes this a book of account rather than a spreadsheet — so a
-- correction is two visible documents: a reversal carrying its reason, and a
-- replacement. These assertions pin both halves, including that in-place editing
-- really is refused rather than merely discouraged.
-- =============================================================================

\echo '--- manual journal ---'

-- current_dealer_id() reads auth.uid(), so the session has to be a dealer user.
-- A platform admin has no tenant and no business writing into one's books.
select app_test.login('11111111-1111-4111-8111-111111111111');

do $$
declare
  v_dealer uuid;
  v_cash   uuid;
  v_bank   uuid;
  v_exp    uuid;
  v_other  uuid;
  v_alien  uuid;
  r        record;
  v_rev    record;
  v_before numeric;
  v_status text;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_cash from public.chart_of_accounts where dealer_id = v_dealer and code = '1100';
  select id into v_bank from public.chart_of_accounts where dealer_id = v_dealer and code = '1200';
  select id into v_exp  from public.chart_of_accounts where dealer_id = v_dealer and code = '5800';

  select sum(debit) into v_before from public.journal_entry_lines;

  -- ── A bank charge, which is exactly why this exists ─────────────────────
  select * into r from public.post_manual_journal(
    current_date,
    'Bank charges for August',
    jsonb_build_array(
      jsonb_build_object('account_id', v_exp,  'debit', 250, 'credit', 0, 'narration', 'Monthly charges'),
      jsonb_build_object('account_id', v_bank, 'debit', 0, 'credit', 250, 'narration', 'HDFC current account')
    ));

  perform app_test.assert_equals(
    (r.entry_number is not null), true, 'a manual entry is issued a journal number'
  );
  perform app_test.assert_equals(
    (select source_module from public.journal_entries where id = r.journal_entry_id), 'MANUAL',
    'and is marked as written by hand, not produced by a module'
  );
  perform app_test.assert_equals(
    (select status from public.journal_entries where id = r.journal_entry_id), 'POSTED',
    'and lands posted'
  );

  -- ── The rules that make it a journal and not a note ─────────────────────
  perform app_test.assert_raises(
    format($q$select public.post_manual_journal(current_date, 'Unbalanced',
      jsonb_build_array(
        jsonb_build_object('account_id', %L, 'debit', 100, 'credit', 0),
        jsonb_build_object('account_id', %L, 'debit', 0, 'credit', 50)))$q$, v_exp, v_bank),
    'an unbalanced entry is refused (spec §22)'
  );
  perform app_test.assert_raises(
    format($q$select public.post_manual_journal(current_date, 'One-sided',
      jsonb_build_array(jsonb_build_object('account_id', %L, 'debit', 100, 'credit', 0)))$q$, v_exp),
    'a single line is refused — an entry has two sides'
  );
  perform app_test.assert_raises(
    format($q$select public.post_manual_journal(current_date, '   ',
      jsonb_build_array(
        jsonb_build_object('account_id', %L, 'debit', 100, 'credit', 0),
        jsonb_build_object('account_id', %L, 'debit', 0, 'credit', 100)))$q$, v_exp, v_bank),
    'an entry with no narration is refused — it has to be readable a year later'
  );

  -- ── Another dealer's account cannot be posted into ──────────────────────
  -- RLS governs what is read; this is a write through a SECURITY-scoped path,
  -- so the tenant check has to be explicit.
  select id into v_other from public.dealers where code <> 'SBM' limit 1;
  if v_other is not null then
    select id into v_alien from public.chart_of_accounts where dealer_id = v_other limit 1;
    if v_alien is not null then
      perform app_test.assert_raises(
        format($q$select public.post_manual_journal(current_date, 'Cross tenant',
          jsonb_build_array(
            jsonb_build_object('account_id', %L, 'debit', 100, 'credit', 0),
            jsonb_build_object('account_id', %L, 'debit', 0, 'credit', 100)))$q$, v_exp, v_alien),
        'a line naming another dealer''s account is refused'
      );
    end if;
  end if;

  -- ── A posted journal cannot be edited. At all. ──────────────────────────
  -- The whole correction story rests on this, so it is asserted rather than
  -- assumed: without it, "reverse and re-enter" would be a convention rather
  -- than a guarantee.
  perform app_test.assert_raises(
    format('update public.journal_entries set narration = ''Tampered'' where id = %L', r.journal_entry_id),
    'a posted journal refuses to be edited (spec §23, §60.12)'
  );
  perform app_test.assert_raises(
    format('delete from public.journal_entries where id = %L', r.journal_entry_id),
    'and refuses to be deleted'
  );
  perform app_test.assert_raises(
    format('update public.journal_entry_lines set debit = 9999 where journal_entry_id = %L', r.journal_entry_id),
    'and so do its lines'
  );

  -- ── Correction is a reversal plus a replacement ─────────────────────────
  perform app_test.assert_raises(
    format('select public.reverse_journal_entry(%L, ''  '')', r.journal_entry_id),
    'a reversal must say why'
  );

  select * into v_rev from public.reverse_journal_entry(
    r.journal_entry_id, 'Charged to the wrong account');

  perform app_test.assert_equals(
    (v_rev.entry_number is not null), true, 'the reversal is its own numbered document'
  );

  select status into v_status from public.journal_entries where id = r.journal_entry_id;
  perform app_test.assert_equals(
    v_status, 'REVERSED', 'and the original is marked reversed rather than removed'
  );
  perform app_test.assert_equals(
    (select reversal_reason from public.journal_entries where id = r.journal_entry_id),
    'Charged to the wrong account',
    'carrying the reason on the record'
  );
  perform app_test.assert_equals(
    (select reversed_by_id from public.journal_entries where id = r.journal_entry_id),
    v_rev.journal_entry_id,
    'and linked to the entry that undid it'
  );

  -- The pair nets to nothing, which is what makes a reversal a reversal.
  perform app_test.assert_equals(
    (select sum(debit) - sum(credit) from public.journal_entry_lines
      where journal_entry_id in (r.journal_entry_id, v_rev.journal_entry_id)),
    0::numeric,
    'the original and its reversal net to zero'
  );

  perform app_test.assert_raises(
    format('select public.reverse_journal_entry(%L, ''Again'')', r.journal_entry_id),
    'and a reversed entry cannot be reversed twice'
  );

  -- ── The books still balance after all of that ───────────────────────────
  perform app_test.assert_equals(
    (select sum(debit) = sum(credit) from public.journal_entry_lines), true,
    'the ledger balances after a manual entry and its reversal'
  );
end $$;

select app_test.logout();
