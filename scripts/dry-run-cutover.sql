-- =============================================================================
-- dry-run-cutover.sql — rehearse onboarding a dealer, end to end
-- =============================================================================
-- Runs the whole cut-over against a throwaway tenant: provision, masters,
-- opening balances, reconcile, close. Every step goes through the same function
-- the UI calls, so a failure here is a failure a real dealer would have seen.
--
-- Run it against a THROWAWAY database, not production:
--
--   createdb twerp_rehearsal
--   psql twerp_rehearsal -f supabase/test/00_supabase_shim.sql
--   for f in supabase/migrations/*.sql; do psql twerp_rehearsal -f "$f"; done
--   psql twerp_rehearsal -f supabase/seed.sql
--   psql twerp_rehearsal -f scripts/dry-run-cutover.sql
--   dropdb twerp_rehearsal
--
-- Three things this rehearsal found the first time it was run, all now fixed or
-- documented:
--
--   * post_opening_balances resolved its tenant with `select id from dealers
--     limit 1`, which is right under RLS and wrong for a platform admin, who
--     sees every tenant. Fixed in 0067.
--   * provision_dealer seeds document sequences for the current financial year,
--     but an opening balance is always dated in the previous one — so the first
--     thing a new tenant did failed for want of a JOURNAL sequence. Also 0067.
--   * purge_dealer refuses once anything is POSTED, because a posted ledger is a
--     statutory record. A rehearsal that reaches opening balances is therefore
--     closed, not purged.
-- =============================================================================

\set ON_ERROR_STOP on
\echo '════════ DRY-RUN CUT-OVER ════════'

-- ── 0. Become a platform administrator ─────────────────────────────────────
-- Provisioning refuses anyone else, which is correct: creating a tenant is
-- platform work, not dealer work. The real flow signs in as the account made by
-- scripts/create-platform-admin.sql.
insert into auth.users (id, email)
values ('99999999-9999-4999-8999-999999999999', 'platform@example.test')
on conflict (id) do nothing;

insert into public.user_profiles (id, dealer_id, full_name, email, is_platform_admin, status)
values ('99999999-9999-4999-8999-999999999999', null, 'Platform Admin',
        'platform@example.test', true, 'ACTIVE')
on conflict (id) do update set is_platform_admin = true;

-- The incoming owner's login must exist first — provisioning refuses to create a
-- tenant with no one able to sign into it. In the real flow this is the account
-- added in Supabase → Authentication → Users before onboarding.
insert into auth.users (id, email)
values ('88888888-8888-4888-8888-888888888888', 'dryrun@example.test')
on conflict (id) do nothing;

select app_test.login('99999999-9999-4999-8999-999999999999');

-- ── 1. Provision a tenant, as Administration → Dealers does ────────────────
do $$
declare r record;
begin
  -- Named arguments: the positional order is code, legal, trade, state,
  -- state_code, owner_email, owner_name, owner_user_id, … and getting that wrong
  -- silently passes an address where a uuid belongs.
  select * into r from public.provision_dealer(
    p_code           => 'DRYRUN',
    p_legal_name     => 'Dry Run Motors Private Limited',
    p_trade_name     => 'Dry Run Motors',
    p_state          => 'Tamil Nadu',
    p_state_code     => '33',
    p_owner_email    => 'dryrun@example.test',
    p_owner_name     => 'Dry Run Owner',
    p_owner_user_id  => '88888888-8888-4888-8888-888888888888',
    p_branch_name    => 'Head Office',
    p_gstin          => '33AABCD1234E1Z5',
    p_city           => 'Coimbatore',
    p_phone          => '9876500001');
  raise notice 'provisioned: dealer=% accounts=% rules=%',
    r.new_dealer_id, r.accounts_created, r.rules_created;
end $$;

\echo '── 2. Masters: customers and suppliers ──'
do $$
declare v_d uuid; v_n int;
begin
  select id into v_d from public.dealers where code = 'DRYRUN';

  -- As the customer importer inserts them: some with legacy codes, some without.
  insert into public.customers (dealer_id, customer_code, name, mobile, city, state, state_code)
  values
    (v_d, 'LEG-0001', 'Anand Kumar',    '9700100001', 'Coimbatore', 'Tamil Nadu', '33'),
    (v_d, 'LEG-0002', 'Priya Ramesh',   '9700100002', 'Tiruppur',   'Tamil Nadu', '33'),
    (v_d, null,       'Walk-in Buyer',  '9700100003', 'Coimbatore', 'Tamil Nadu', '33');

  insert into public.suppliers (dealer_id, supplier_code, name, gstin, credit_days)
  values
    (v_d, 'SUP-0001', 'TVS Motor Company', '33AAACT1234A1Z1', 30),
    (v_d, null,       'Local Parts Co',    null,               15);

  select count(*) into v_n from public.customers where dealer_id = v_d;
  raise notice 'customers=% (one auto-coded: %)', v_n,
    (select customer_code from public.customers where dealer_id=v_d and name='Walk-in Buyer');
  raise notice 'suppliers=% (one auto-coded: %)',
    (select count(*) from public.suppliers where dealer_id=v_d),
    (select supplier_code from public.suppliers where dealer_id=v_d and name='Local Parts Co');
end $$;

\echo '── 3. Opening balances ──'
do $$
declare v_d uuid; r record; v_open numeric; v_eq numeric;
begin
  select id into v_d from public.dealers where code = 'DRYRUN';

  select * into r from public.post_opening_balances(
    'CUSTOMER',
    jsonb_build_array(
      jsonb_build_object('party_code','LEG-0001','amount', 45000),
      jsonb_build_object('party_code','LEG-0002','amount', -5000)),
    date '2026-03-31', 'Dry run cut-over', 'dryrun-customers', v_d);
  raise notice 'customer opening: journal=% parties=%', r.journal_entry_id, r.parties;

  select * into r from public.post_opening_balances(
    'SUPPLIER',
    jsonb_build_array(jsonb_build_object('party_code','SUP-0001','amount', -120000)),
    date '2026-03-31', 'Dry run cut-over', 'dryrun-suppliers', v_d);
  raise notice 'supplier opening: journal=% parties=%', r.journal_entry_id, r.parties;

  -- ── 4. Reconcile, exactly as the runbook says to ──
  select public.party_ledger_opening('CUSTOMER',
    (select id from public.customers where dealer_id=v_d and customer_code='LEG-0001'),
    'infinity'::date) into v_open;
  raise notice 'LEG-0001 ledger reads: %  (expected 45000)', v_open;

  select public.party_ledger_opening('SUPPLIER',
    (select id from public.suppliers where dealer_id=v_d and supplier_code='SUP-0001'),
    'infinity'::date) into v_open;
  raise notice 'SUP-0001 ledger reads: %  (expected -120000)', v_open;

  select coalesce(sum(l.credit - l.debit),0) into v_eq
    from public.journal_entry_lines l
    join public.chart_of_accounts c on c.id = l.account_id
    join public.journal_entries e on e.id = l.journal_entry_id
   where e.dealer_id = v_d and c.code = '3300';
  raise notice '3300 Opening Balance Equity: %  (expected -80000 = 40000 debtors - 120000 creditors)', v_eq;
end $$;

\echo '── 5. Does the tenant balance? ──'
select case when sum(l.debit) = sum(l.credit) then 'BALANCED' else 'OUT BY ' || (sum(l.debit)-sum(l.credit))::text end
         as trial_balance,
       count(distinct l.journal_entry_id) || ' journals' as journals
  from public.journal_entry_lines l
  join public.journal_entries e on e.id = l.journal_entry_id
 where e.dealer_id = (select id from public.dealers where code='DRYRUN');

\echo '── 6. Ending a rehearsal that has posted journals ──'
-- purge_dealer refuses once anything is POSTED: "a posted ledger is a statutory
-- record". Correct, and it means a rehearsal that got as far as opening balances
-- is closed, not purged. Purging only works if you stop before posting.
do $$
declare v_d uuid; v_msg text;
begin
  select id into v_d from public.dealers where code='DRYRUN';

  begin
    perform public.purge_dealer(v_d, 'Dry run complete');
    raise notice 'purge succeeded (unexpected once journals exist)';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    raise notice 'purge refused, as designed: %', v_msg;
  end;

  update public.dealers set status = 'CLOSED' where id = v_d;
  raise notice 'closed instead: status=%', (select status from public.dealers where id=v_d);
end $$;

\echo '── 7. A closed tenant is out of the way but still on the record ──'
select 'dealer status: ' || status from public.dealers where code='DRYRUN'
union all
select 'its journals still exist: ' || count(*)::text from public.journal_entries
  where dealer_id = (select id from public.dealers where code='DRYRUN')
union all
select 'every dealer still balances: ' ||
  case when sum(debit)=sum(credit) then 'yes' else 'NO' end from public.journal_entry_lines;
