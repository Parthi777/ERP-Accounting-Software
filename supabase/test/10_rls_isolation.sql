-- =============================================================================
-- TEST — tenant and branch isolation
-- =============================================================================
-- Spec §4, §60.4, §60.5, §60.20. Creates a second dealer, then impersonates a
-- Dealer A user and asserts that not one row of Dealer B is reachable through
-- any tenant table.
--
-- Runs as the `authenticated` role, exactly as a browser session does. Assertions
-- raise on failure, so the harness fails the whole run.
-- =============================================================================

\echo '--- RLS isolation ---'

-- ── Arrange: a second dealer with its own branch, user and accounts ──────────
do $$
declare
  v_dealer_b uuid;
  v_branch_b uuid;
  v_role_id  uuid;
begin
  insert into public.dealers (code, legal_name, trade_name, city, state, state_code)
  values ('RIVAL', 'Rival Motors Private Limited', 'Rival Motors', 'Coimbatore', 'Tamil Nadu', '33')
  returning id into v_dealer_b;

  insert into public.branches (dealer_id, code, name, city, state, state_code, is_head_office)
  values (v_dealer_b, 'MAIN', 'Rival Main Branch', 'Coimbatore', 'Tamil Nadu', '33', true)
  returning id into v_branch_b;

  insert into auth.users (id, email)
  values ('99999999-9999-4999-8999-999999999999', 'owner@rivalmotors.example');

  insert into public.user_profiles (id, dealer_id, full_name, email, has_all_branch_access, default_branch_id)
  values ('99999999-9999-4999-8999-999999999999', v_dealer_b, 'Rival Owner',
          'owner@rivalmotors.example', true, v_branch_b);

  select id into v_role_id from public.roles where code = 'DEALER_OWNER' and dealer_id is null;
  insert into public.user_roles (user_id, role_id)
  values ('99999999-9999-4999-8999-999999999999', v_role_id);

  insert into public.employees (dealer_id, branch_id, employee_code, name, department)
  values (v_dealer_b, v_branch_b, 'REMP001', 'Rival Employee', 'Sales');

  insert into public.chart_of_accounts (dealer_id, code, name, account_type, normal_balance)
  values (v_dealer_b, '1100', 'Rival Cash', 'ASSET', 'DEBIT');
end;
$$;

-- ── Act: become the Dealer A owner ──────────────────────────────────────────
set role authenticated;
select app_test.login('11111111-1111-4111-8111-111111111111');

-- ── Assert: only Dealer A's data is visible ─────────────────────────────────
do $$
begin
  perform app_test.assert_equals(
    (select count(*)::int from public.dealers), 1,
    'dealer owner sees exactly one dealer'
  );

  perform app_test.assert_equals(
    (select code from public.dealers), 'SBM',
    'the visible dealer is their own'
  );

  perform app_test.assert_equals(
    (select count(*)::int from public.branches), 3,
    'sees own 3 branches and none of Rival Motors'
  );

  perform app_test.assert_equals(
    (select count(*)::int from public.branches b
      join public.dealers d on d.id = b.dealer_id where d.code = 'RIVAL'), 0,
    'no Rival Motors branch is reachable'
  );

  perform app_test.assert_equals(
    (select count(*)::int from public.employees where name = 'Rival Employee'), 0,
    'no Rival Motors employee is reachable'
  );

  perform app_test.assert_equals(
    (select count(*)::int from public.chart_of_accounts where name = 'Rival Cash'), 0,
    'no Rival Motors account is reachable'
  );

  perform app_test.assert_equals(
    (select count(*)::int from public.user_profiles where email like '%rivalmotors%'), 0,
    'no Rival Motors user profile is reachable'
  );

  perform app_test.assert_equals(
    (select count(*)::int from public.audit_logs
      where dealer_id is not null
        and dealer_id <> app.current_dealer_id()), 0,
    'audit log leaks no other tenant''s rows'
  );

  perform app_test.assert_equals(
    (select count(*)::int from public.document_sequences ds
      join public.dealers d on d.id = ds.dealer_id where d.code = 'RIVAL'), 0,
    'no Rival Motors document sequence is reachable'
  );

  perform app_test.assert_equals(
    (select count(*)::int from public.suppliers s
      join public.dealers d on d.id = s.dealer_id where d.code = 'RIVAL'), 0,
    'no Rival Motors supplier is reachable'
  );
end;
$$;

-- ── Assert: writes cannot cross the tenant boundary either ──────────────────
-- Two different failure modes are at work here, and both matter:
--   * UPDATE/DELETE are filtered by the policy's USING clause. The foreign row is
--     simply not in scope, so the statement is a silent no-op — zero rows, no
--     error. Asserting on the row count is the only way to catch a leak.
--   * INSERT is checked by WITH CHECK, which does raise.
do $$
declare
  v_rival_branch uuid;
  v_rival_dealer uuid;
  v_affected     int;
  v_name         text;
begin
  -- Read the ids out of band (as owner) so the test targets real foreign rows.
  reset role;
  select b.id, b.dealer_id into v_rival_branch, v_rival_dealer
    from public.branches b join public.dealers d on d.id = b.dealer_id
   where d.code = 'RIVAL';
  set role authenticated;

  update public.branches set name = 'Hijacked' where id = v_rival_branch;
  get diagnostics v_affected = row_count;
  perform app_test.assert_equals(v_affected, 0,
    'renaming another tenant''s branch affects zero rows');

  delete from public.branches where id = v_rival_branch;
  get diagnostics v_affected = row_count;
  perform app_test.assert_equals(v_affected, 0,
    'deleting another tenant''s branch affects zero rows');

  perform app_test.assert_raises(
    format($f$insert into public.branches (dealer_id, code, name, city, state, state_code)
             values (%L, 'EVIL', 'Planted Branch', 'Chennai', 'Tamil Nadu', '33')$f$, v_rival_dealer),
    'cannot insert a branch into another tenant'
  );

  perform app_test.assert_raises(
    format($f$insert into public.employees (dealer_id, branch_id, employee_code, name)
             values (%L, %L, 'EVIL001', 'Planted Employee')$f$, v_rival_dealer, v_rival_branch),
    'cannot insert an employee into another tenant'
  );

  perform app_test.assert_equals(
    (select count(*)::int from public.employees
      where dealer_id <> app.current_dealer_id()), 0,
    'cannot read employees outside own dealer'
  );

  -- Confirm the foreign row survived all of the above untouched.
  reset role;
  select b.name into v_name from public.branches b where b.id = v_rival_branch;
  perform app_test.assert_equals(v_name, 'Rival Main Branch',
    'the other tenant''s branch is intact after every attempt');
  set role authenticated;
end;
$$;

-- ── Assert: a user cannot escalate their own privileges (spec §47) ──────────
do $$
declare
  v_affected int;
  v_escalated boolean;
begin
  update public.user_profiles set is_platform_admin = true where id = auth.uid();
  get diagnostics v_affected = row_count;
  perform app_test.assert_equals(v_affected, 0,
    'a user cannot promote themselves to platform admin'
  );

  reset role;
  select is_platform_admin into v_escalated
    from public.user_profiles where id = '11111111-1111-4111-8111-111111111111';
  perform app_test.assert_equals(v_escalated, false,
    'the platform-admin flag is unchanged after the attempt'
  );
  set role authenticated;
exception
  when insufficient_privilege or check_violation then
    -- A raising policy is an equally correct outcome.
    reset role;
    set role authenticated;
    raise notice '  ok  self-promotion to platform admin rejected';
end;
$$;

-- =============================================================================
-- Branch-level isolation (spec §60.5)
-- =============================================================================
-- The cashier is granted the main branch only.
select app_test.login('33333333-3333-4333-8333-333333333333');

do $$
begin
  perform app_test.assert_equals(
    (select count(*)::int from public.branches), 1,
    'branch-limited user sees only their granted branch'
  );

  perform app_test.assert_equals(
    (select code from public.branches), 'MAIN',
    'the visible branch is the one granted'
  );
end;
$$;

-- =============================================================================
-- Permission gating: the cashier must not reach cost or accounting data
-- (spec §6, §52)
-- =============================================================================
do $$
begin
  perform app_test.assert_equals(
    app.has_permission('sales.view_cost'), false,
    'cashier does not hold sales.view_cost'
  );

  perform app_test.assert_equals(
    app.has_permission('dashboard.view_margin'), false,
    'cashier does not hold dashboard.view_margin'
  );

  perform app_test.assert_equals(
    app.has_permission('reports.profitability.view'), false,
    'cashier does not hold reports.profitability.view'
  );

  perform app_test.assert_equals(
    (select count(*)::int from public.chart_of_accounts), 0,
    'cashier cannot read the chart of accounts'
  );

  perform app_test.assert_equals(
    (select count(*)::int from public.audit_logs), 0,
    'cashier cannot read the audit trail'
  );

  perform app_test.assert_equals(
    app.has_permission('bookings.create'), true,
    'cashier can create bookings'
  );

  perform app_test.assert_equals(
    app.has_permission('cashbook.receipts.create'), true,
    'cashier can record cash receipts'
  );
end;
$$;

-- The accounts user is the counterpart: cost and margin are theirs to see.
select app_test.login('22222222-2222-4222-8222-222222222222');

do $$
begin
  perform app_test.assert_equals(
    app.has_permission('sales.view_cost'), true,
    'accounts holds sales.view_cost'
  );

  perform app_test.assert_equals(
    app.has_permission('dashboard.view_margin'), true,
    'accounts holds dashboard.view_margin'
  );

  perform app_test.assert_equals(
    (select count(*)::int from public.chart_of_accounts) > 0, true,
    'accounts can read the chart of accounts'
  );

  perform app_test.assert_equals(
    app.has_permission('admin.dealers.manage'), false,
    'accounts cannot manage dealer configuration'
  );
end;
$$;

-- =============================================================================
-- Unauthenticated sessions see nothing
-- =============================================================================
select app_test.logout();

do $$
begin
  perform app_test.assert_equals(
    (select count(*)::int from public.dealers), 0,
    'anonymous session sees no dealers'
  );

  perform app_test.assert_equals(
    (select count(*)::int from public.branches), 0,
    'anonymous session sees no branches'
  );

  perform app_test.assert_equals(
    (select count(*)::int from public.user_profiles), 0,
    'anonymous session sees no user profiles'
  );
end;
$$;

reset role;

-- ── Teardown ────────────────────────────────────────────────────────────────
-- dealers.id is referenced ON DELETE RESTRICT precisely so a tenant with live
-- data cannot be removed by accident, so the children go first. That the naive
-- `delete from dealers` fails here is the constraint doing its job.
do $$
declare
  v_dealer uuid;
begin
  select id into v_dealer from public.dealers where code = 'RIVAL';
  if v_dealer is null then
    return;
  end if;

  delete from public.employees          where dealer_id = v_dealer;
  delete from public.chart_of_accounts  where dealer_id = v_dealer;
  delete from public.user_branches      where dealer_id = v_dealer;
  delete from public.user_roles ur
   using public.user_profiles up
   where up.id = ur.user_id and up.dealer_id = v_dealer;
  delete from public.user_profiles      where dealer_id = v_dealer;
  delete from public.branches           where dealer_id = v_dealer;
  delete from public.dealers            where id = v_dealer;
  delete from auth.users                where email = 'owner@rivalmotors.example';
end;
$$;

\echo '--- RLS isolation passed ---'
