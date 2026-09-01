-- =============================================================================
-- TEST — customer master
-- =============================================================================
-- Spec §11, §60.6: the Customer ID is mandatory, auto-generated and dealer-unique;
-- customers are dealer-scoped and isolated between tenants.
-- =============================================================================

\echo '--- customer master ---'

do $$
declare
  v_dealer uuid;
  v_branch uuid;
  v_id     uuid;
  v_code   text;
  v_code2  text;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'MAIN';

  -- ── The code is issued by the database ────────────────────────────────────
  insert into public.customers (dealer_id, name, mobile, origin_branch_id, city, state, state_code)
  values (v_dealer, 'Ramesh Kannan', '9840011111', v_branch, 'Chennai', 'Tamil Nadu', '33')
  returning id, customer_code into v_id, v_code;

  perform app_test.assert_equals(
    v_code ~ '^CUST-[0-9]{4}-[0-9]{6}$', true,
    'customer code is auto-generated in the CUST-YYYY-NNNNNN format'
  );

  insert into public.customers (dealer_id, name, mobile)
  values (v_dealer, 'Lakshmi Narayanan', '9840022222')
  returning customer_code into v_code2;

  perform app_test.assert_equals(
    right(v_code2, 6)::int - right(v_code, 6)::int, 1,
    'customer codes increment by exactly one'
  );

  -- A client-supplied code is not how codes are normally issued, but a data
  -- migration needs it, so an explicit value is respected.
  insert into public.customers (dealer_id, customer_code, name, mobile)
  values (v_dealer, 'LEGACY-0001', 'Imported Customer', '9840033333');

  perform app_test.assert_equals(
    (select customer_code from public.customers where mobile = '9840033333'), 'LEGACY-0001',
    'an explicit code is preserved for data migration'
  );

  -- ── Validation ────────────────────────────────────────────────────────────
  perform app_test.assert_raises(
    format($f$insert into public.customers (dealer_id, name, mobile)
             values (%L, 'Bad Mobile', '1234567890')$f$, v_dealer),
    'a mobile number outside the Indian numbering plan is rejected'
  );

  perform app_test.assert_raises(
    format($f$insert into public.customers (dealer_id, name, mobile, gstin)
             values (%L, 'Bad GSTIN', '9840044444', 'NOTAGSTIN')$f$, v_dealer),
    'a malformed GSTIN is rejected'
  );

  perform app_test.assert_raises(
    format($f$insert into public.customers (dealer_id, name, mobile, pan)
             values (%L, 'Bad PAN', '9840044444', 'BADPAN')$f$, v_dealer),
    'a malformed PAN is rejected'
  );

  perform app_test.assert_raises(
    format($f$insert into public.customers (dealer_id, name, mobile, customer_type)
             values (%L, 'No GSTIN Business', '9840044444', 'BUSINESS')$f$, v_dealer),
    'a BUSINESS customer without a GSTIN is rejected'
  );

  perform app_test.assert_raises(
    format($f$insert into public.customers (dealer_id, name, mobile)
             values (%L, 'X', '9840044444')$f$, v_dealer),
    'a one-character name is rejected'
  );

  -- ── Duplicate protection ──────────────────────────────────────────────────
  perform app_test.assert_raises(
    format($f$insert into public.customers (dealer_id, name, mobile)
             values (%L, 'Duplicate Mobile', '9840011111')$f$, v_dealer),
    'the same mobile twice in one dealer is rejected'
  );

  -- Blocking the original frees the number for re-registration.
  update public.customers set status = 'BLOCKED' where id = v_id;

  insert into public.customers (dealer_id, name, mobile)
  values (v_dealer, 'Ramesh Kannan Again', '9840011111');

  perform app_test.assert_equals(
    (select count(*)::int from public.customers where mobile = '9840011111'), 2,
    'a blocked record does not block re-registering the same mobile'
  );

  -- ── Customers are never deleted (they carry transaction history) ──────────
  perform app_test.assert_equals(
    (select count(*)::int from pg_policies
      where schemaname = 'public' and tablename = 'customers' and cmd = 'DELETE'), 0,
    'there is no DELETE policy on customers'
  );
end;
$$;

-- =============================================================================
-- Tenant isolation and permission gating
-- =============================================================================
do $$
declare
  v_dealer_b uuid;
  v_count    int;
begin
  -- A second dealer with a customer of its own.
  insert into public.dealers (code, legal_name, city, state, state_code)
  values ('CUSTTEST', 'Customer Isolation Test Motors', 'Salem', 'Tamil Nadu', '33')
  returning id into v_dealer_b;

  insert into public.customers (dealer_id, name, mobile)
  values (v_dealer_b, 'Other Tenant Customer', '9880011111');

  -- Codes restart per dealer: the sequence is dealer-scoped.
  perform app_test.assert_equals(
    (select right(customer_code, 6)::int from public.customers where mobile = '9880011111'), 1,
    'customer numbering restarts at 1 for a new dealer'
  );

  set role authenticated;

  -- The dealer owner of SBM must not see the other tenant's customer.
  perform app_test.login('11111111-1111-4111-8111-111111111111');
  select count(*)::int into v_count from public.customers where mobile = '9880011111';
  perform app_test.assert_equals(v_count, 0, 'dealer owner cannot see another tenant''s customer');

  perform app_test.assert_equals(
    (select count(*)::int from public.customers) > 0, true,
    'dealer owner can see their own customers'
  );

  -- The cashier holds customers.view/create/edit, so the master is reachable.
  perform app_test.login('33333333-3333-4333-8333-333333333333');
  perform app_test.assert_equals(
    (select count(*)::int from public.customers) > 0, true,
    'cashier can read the customer master'
  );
  perform app_test.assert_equals(
    (select count(*)::int from public.customers where mobile = '9880011111'), 0,
    'cashier cannot see another tenant''s customer'
  );

  -- Counter sales can create customers but not edit them (spec §6).
  perform app_test.login('66666666-6666-4666-8666-666666666666');
  perform app_test.assert_equals(
    app.has_permission('customers.create'), true, 'counter sales can create customers'
  );
  perform app_test.assert_equals(
    app.has_permission('customers.edit'), false, 'counter sales cannot edit customers'
  );

  perform app_test.logout();
  perform app_test.assert_equals(
    (select count(*)::int from public.customers), 0,
    'anonymous session sees no customers'
  );

  reset role;

  delete from public.customers where dealer_id = v_dealer_b;
  delete from public.document_sequences where dealer_id = v_dealer_b;
  delete from public.dealers where id = v_dealer_b;
end;
$$;

-- Leave the seeded dealer as we found it.
delete from public.customers where dealer_id = (select id from public.dealers where code = 'SBM');

\echo '--- customer master passed ---'
