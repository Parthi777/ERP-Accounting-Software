-- =============================================================================
-- TEST — the constraints a customer import has to satisfy (spec §11, §14)
-- =============================================================================
-- The importer validates in TypeScript, against the same Zod schema the
-- single-customer form uses. This asserts the half that TypeScript cannot: that
-- the database agrees, so a file which previews clean is not rejected at commit.
--
-- It also pins the behaviour the whole migration path depends on — that a
-- supplied customer_code is kept. A dealer's paper records, old invoices and
-- their customers' own memories all carry the codes they already have, and
-- renumbering at cut-over makes every historical document unfindable by the
-- number printed on it.
-- =============================================================================

\echo '--- customer import ---'

do $$
declare
  v_dealer uuid;
  v_id     uuid;
  v_code   text;
  v_count  int;
begin
  select id into v_dealer from public.dealers where code = 'SBM';

  -- ── A supplied code is respected ────────────────────────────────────────
  insert into public.customers (dealer_id, customer_code, name, mobile)
  values (v_dealer, 'LEGACY-0042', 'Migrated Customer', '9800000001')
  returning id, customer_code into v_id, v_code;

  perform app_test.assert_equals(
    v_code, 'LEGACY-0042',
    'an imported customer keeps the code the dealer already used'
  );

  -- ── An absent code is issued ────────────────────────────────────────────
  insert into public.customers (dealer_id, name, mobile)
  values (v_dealer, 'Auto Coded Customer', '9800000002')
  returning customer_code into v_code;

  perform app_test.assert_equals(
    (v_code is not null and v_code <> ''), true,
    'a customer with no code in the file is issued one'
  );
  perform app_test.assert_equals(
    v_code like 'CUST%', true,
    'and it comes from the dealer CUSTOMER sequence'
  );

  -- ── The same code twice is refused ──────────────────────────────────────
  -- This is why the importer checks within the file as well as against the
  -- database: without it, one repeated code fails the whole insert with nothing
  -- to say which row caused it.
  perform app_test.assert_raises(
    format('insert into public.customers (dealer_id, customer_code, name, mobile)
            values (%L, %L, %L, %L)', v_dealer, 'LEGACY-0042', 'Duplicate Code', '9800000003'),
    'the same customer code twice is refused'
  );

  -- ── The row-level rules the importer previews ───────────────────────────
  perform app_test.assert_raises(
    format('insert into public.customers (dealer_id, name, mobile) values (%L, %L, %L)',
           v_dealer, 'Bad Mobile', '12345'),
    'a mobile outside the Indian numbering plan is refused'
  );
  perform app_test.assert_raises(
    format('insert into public.customers (dealer_id, name, mobile) values (%L, %L, %L)',
           v_dealer, 'X', '9800000004'),
    'a name under two characters is refused'
  );
  perform app_test.assert_raises(
    format('insert into public.customers (dealer_id, name, mobile, customer_type)
            values (%L, %L, %L, %L)', v_dealer, 'Business No GSTIN', '9800000005', 'BUSINESS'),
    'a BUSINESS customer without a GSTIN is refused'
  );
  perform app_test.assert_raises(
    format('insert into public.customers (dealer_id, name, mobile, gstin) values (%L, %L, %L, %L)',
           v_dealer, 'Bad GSTIN', '9800000006', 'NOTAGSTIN'),
    'a malformed GSTIN is refused'
  );
  perform app_test.assert_raises(
    format('insert into public.customers (dealer_id, name, mobile, pan) values (%L, %L, %L, %L)',
           v_dealer, 'Bad PAN', '9800000007', 'BADPAN'),
    'a malformed PAN is refused'
  );

  -- ── A duplicate mobile is refused, for ACTIVE customers ────────────────
  -- customers_dealer_mobile_key is a *partial* unique index: it applies where
  -- status = 'ACTIVE', so a blocked record does not stop the same person being
  -- registered again later. The importer checks mobiles itself anyway — not
  -- because the database would miss it, but because one unique violation on a
  -- 5,000-row insert fails the whole file and names no row.
  perform app_test.assert_raises(
    format('insert into public.customers (dealer_id, name, mobile) values (%L, %L, %L)',
           v_dealer, 'Same Mobile As Another', '9800000001'),
    'the same mobile twice within a dealer is refused'
  );

  -- The partial index is what makes re-registration possible, and it is a real
  -- migration case: a dealer's old list often holds lapsed records.
  update public.customers set status = 'BLOCKED' where customer_code = 'LEGACY-0042';

  insert into public.customers (dealer_id, name, mobile)
  values (v_dealer, 'Re-registered Later', '9800000001');

  select count(*) into v_count from public.customers
   where dealer_id = v_dealer and mobile = '9800000001';
  perform app_test.assert_equals(
    v_count, 2,
    'but a blocked record does not block re-registering the same person'
  );
end $$;

-- ── Imported customers belong to the tenant that imported them ────────────
set role authenticated;
select app_test.login('11111111-1111-4111-8111-111111111111');

do $$
declare v_n int;
begin
  select count(*) into v_n from public.customers where customer_code = 'LEGACY-0042';
  perform app_test.assert_equals(
    v_n, 1, 'the importing dealer can read what it imported'
  );

  select count(*) into v_n from public.customers
   where dealer_id <> (select dealer_id from public.customers where customer_code = 'LEGACY-0042');
  perform app_test.assert_equals(
    v_n, 0, 'and sees nothing belonging to another dealer'
  );
end $$;

select app_test.logout();
reset role;
