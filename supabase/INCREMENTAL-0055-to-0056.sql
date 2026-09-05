-- =============================================================================
-- INCREMENTAL 0055 → 0056
-- =============================================================================
-- GENERATED FILE. Regenerate with:
--   FROM=0055 bash scripts/build-incremental.sh
--
-- For a database that ALREADY has migrations up to 0054.
-- Running the full ALL-IN-ONE.sql on such a database fails on the first table
-- that already exists; this contains only what is missing.
--
-- Wrapped in one transaction. If any statement fails the whole thing rolls back
-- and the database is left exactly as it was — there is no half-applied state to
-- clean up, and it is safe to fix the cause and run again.
--
-- Paste into the Supabase SQL Editor and Run.
-- =============================================================================

begin;



-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0055_dealer_status_gate.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0055 — A suspended dealer is actually suspended
-- =============================================================================
-- Spec §4, §6, §47, §60.3, §60.20.
--
-- public.dealers.status has accepted 'ACTIVE', 'SUSPENDED' and 'CLOSED' since
-- migration 0002. Nothing has ever read it.
--
-- app.current_dealer_id() is the function every RLS policy in the schema resolves
-- the tenant through, and it checks only that the USER is active:
--
--     select up.dealer_id from public.user_profiles up
--      where up.id = auth.uid() and up.status = 'ACTIVE';
--
-- So a dealer marked SUSPENDED keeps working exactly as before, for every one of
-- their users. There is no way to stop serving a tenant — not for non-payment,
-- not during a dispute, not when they leave. Marking them CLOSED changes a label
-- and nothing else.
--
-- One clause fixes it everywhere at once, which is the point of having a single
-- tenant-resolution function: 133 policies inherit the change without being
-- touched.
--
-- ── Why this ships on its own ───────────────────────────────────────────────
--
-- It alters what every policy in the database returns. That is worth deploying
-- and verifying by itself rather than inside a larger change, because the
-- failure mode in the other direction — a wrong predicate here — locks every
-- tenant out of everything simultaneously.
--
-- Platform admins are unaffected: app.is_platform_admin() is a separate check
-- that does not go through this function, so a suspended dealer can still be
-- administered, looked at and reactivated.
--
-- Rollback: restore app.current_dealer_id() from 0004.
-- =============================================================================

create or replace function app.current_dealer_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select up.dealer_id
    from public.user_profiles up
    join public.dealers d on d.id = up.dealer_id
   where up.id = auth.uid()
     and up.status = 'ACTIVE'
     -- The tenant has to be live too. Without this the status column is a label
     -- rather than a switch, and there is no way to stop serving a dealer.
     and d.status = 'ACTIVE';
$$;

comment on function app.current_dealer_id() is
  'Tenant of the current session, resolved from the JWT (spec §4). Returns NULL '
  'for platform admins, unauthenticated callers, inactive users AND suspended or '
  'closed dealers — so `dealer_id = app.current_dealer_id()` is false for all of '
  'them, and access ends everywhere at once. Deny by default.';


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0056_dealer_provisioning.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0056 — Provisioning a dealer: onboarding becomes a form, not a SQL script
-- =============================================================================
-- Spec §4, §6, §22, §24, §44, §45, §47, §48, §60.3.
--
-- Until now the only thing that has ever created a tenant is supabase/seed.sql —
-- a hand-run script hardcoded to one dealer. Admin → Dealers is read-only and
-- says so: "Platform administrators provision dealers." Onboarding the second
-- dealer meant editing SQL and running it against production.
--
-- This is that script turned into a function, so onboarding is six fields and a
-- button.
--
-- ── One transaction, or none of it ──────────────────────────────────────────
--
-- A half-provisioned tenant is worse than no tenant: the dealer logs in, raises
-- their first sale, and hits `No accounting rule for SALES/INVOICE/RECEIVABLE` —
-- a failure they cannot diagnose and nobody else can see. So the whole sequence
-- is one plpgsql function, and app.dealer_readiness() runs inside it before it
-- returns. A tenant that would not work never commits (spec §48).
--
-- The Supabase invite is deliberately NOT here. It is the one step Postgres
-- cannot roll back, so the service layer sends it after this commits: the worst
-- case then is a tenant with no invite sent, which the readiness check shows and
-- a Resend button fixes. Inside the transaction, a later failure would have
-- emailed someone a link to a dealership that no longer exists.
--
-- ── Rollback ────────────────────────────────────────────────────────────────
--
--   failed part-way   the transaction rolls back; nothing was written
--   created wrongly   public.purge_dealer(), which refuses once anything posted
--   has traded        status = 'CLOSED' (0055 makes that actually stop access)
--
-- Rollback: drop function public.purge_dealer(uuid, text),
--                         public.dealer_readiness(uuid),
--                         app.provision_dealer(...), app.seed_chart_of_accounts(uuid).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- app.seed_chart_of_accounts() — the accounts every dealer starts with
-- -----------------------------------------------------------------------------
-- Lifted verbatim from the loop in seed.sql so there is one implementation
-- rather than two that drift. Group headers are inserted before their children
-- because parent_id is resolved by code as it goes; `order by code` is what makes
-- that true, and is load-bearing rather than tidiness.
-- -----------------------------------------------------------------------------
create or replace function app.seed_chart_of_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
declare
  v_account record;
  v_parent  uuid;
  v_added   integer := 0;
begin
  for v_account in
    select * from (values
      ('1000', 'Assets',                    'ASSET',     'DEBIT',  true,  null,   false),
      ('1100', 'Cash',                      'ASSET',     'DEBIT',  false, '1000', true),
      ('1200', 'Bank',                      'ASSET',     'DEBIT',  false, '1000', true),
      ('1300', 'Customer Receivable',       'ASSET',     'DEBIT',  false, '1000', false),
      ('1400', 'Finance Receivable',        'ASSET',     'DEBIT',  false, '1000', false),
      ('1500', 'Vehicle Inventory',         'ASSET',     'DEBIT',  false, '1000', true),
      ('1600', 'Accessories Inventory',     'ASSET',     'DEBIT',  false, '1000', true),
      ('1700', 'Spare Inventory',           'ASSET',     'DEBIT',  false, '1000', true),
      ('1800', 'Other Receivables',         'ASSET',     'DEBIT',  false, '1000', false),
      ('1900', 'Input CGST',                'ASSET',     'DEBIT',  false, '1000', false),
      ('1910', 'Input SGST',                'ASSET',     'DEBIT',  false, '1000', false),
      ('1920', 'Input IGST',                'ASSET',     'DEBIT',  false, '1000', false),

      ('2000', 'Liabilities',               'LIABILITY', 'CREDIT', true,  null,   false),
      ('2100', 'Customer Advances',         'LIABILITY', 'CREDIT', false, '2000', false),
      ('2200', 'Supplier Payables',         'LIABILITY', 'CREDIT', false, '2000', false),
      ('2300', 'Output CGST',               'LIABILITY', 'CREDIT', false, '2000', false),
      ('2400', 'Output SGST',               'LIABILITY', 'CREDIT', false, '2000', false),
      ('2500', 'Output IGST',               'LIABILITY', 'CREDIT', false, '2000', false),
      ('2600', 'Finance Company Payable',   'LIABILITY', 'CREDIT', false, '2000', false),
      ('2700', 'Other Payables',            'LIABILITY', 'CREDIT', false, '2000', false),

      ('3000', 'Equity',                    'EQUITY',    'CREDIT', true,  null,   false),
      ('3100', 'Share Capital',             'EQUITY',    'CREDIT', false, '3000', false),
      ('3200', 'Retained Earnings',         'EQUITY',    'CREDIT', false, '3000', false),

      ('4000', 'Income',                    'INCOME',    'CREDIT', true,  null,   false),
      ('4100', 'Vehicle Sales',             'INCOME',    'CREDIT', false, '4000', true),
      ('4200', 'Accessories Sales',         'INCOME',    'CREDIT', false, '4000', true),
      ('4300', 'Spare Sales',               'INCOME',    'CREDIT', false, '4000', true),
      ('4400', 'Service Labour',            'INCOME',    'CREDIT', false, '4000', true),
      ('4500', 'Finance Commission',        'INCOME',    'CREDIT', false, '4000', true),
      ('4600', 'Insurance Commission',      'INCOME',    'CREDIT', false, '4000', true),
      ('4700', 'Forwarding Income',         'INCOME',    'CREDIT', false, '4000', true),
      ('4800', 'Other Income',              'INCOME',    'CREDIT', false, '4000', true),

      ('5000', 'Costs and Expenses',        'EXPENSE',   'DEBIT',  true,  null,   false),
      ('5100', 'Vehicle COGS',              'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5200', 'Accessories COGS',          'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5300', 'Spare COGS',                'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5400', 'Service Cost',              'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5500', 'Salaries',                  'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5600', 'Rent',                      'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5700', 'Utilities',                 'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5800', 'Bank Charges',              'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5900', 'Other Expenses',            'EXPENSE',   'DEBIT',  false, '5000', true)
    ) as t(code, name, account_type, normal_balance, is_group, parent_code, branch_scoped)
    order by code
  loop
    v_parent := null;
    if v_account.parent_code is not null then
      select id into v_parent from public.chart_of_accounts
       where dealer_id = p_dealer_id and code = v_account.parent_code;
    end if;

    insert into public.chart_of_accounts
      (dealer_id, code, name, account_type, normal_balance, is_group, parent_id,
       is_system, is_branch_scoped)
    values
      (p_dealer_id, v_account.code, v_account.name, v_account.account_type,
       v_account.normal_balance, v_account.is_group, v_parent, true,
       v_account.branch_scoped)
    on conflict on constraint coa_dealer_code_key do nothing;

    if found then v_added := v_added + 1; end if;
  end loop;

  return v_added;
end;
$$;

comment on function app.seed_chart_of_accounts(uuid) is
  'The accounts a dealer starts with (spec §24). One implementation, shared by '
  'seed.sql and app.provision_dealer(), so the two cannot drift.';

-- -----------------------------------------------------------------------------
-- public.dealer_readiness() — can this tenant actually trade?
-- -----------------------------------------------------------------------------
-- Provisioning runs this before it commits, and the screen runs it afterwards.
-- Each row is one thing that must be true before a dealer can raise an invoice;
-- the accounting-rule check counts rather than merely looks, because the way this
-- breaks in future is a new seeder nobody added to provisioning.
-- -----------------------------------------------------------------------------
create or replace function public.dealer_readiness(p_dealer_id uuid)
returns table (check_name text, ok boolean, detail text)
language sql
stable
as $$
  select 'Chart of accounts',
         count(*) >= 40,
         count(*) || ' accounts'
    from public.chart_of_accounts where dealer_id = p_dealer_id
  union all
  select 'Control accounts resolvable',
         count(*) = 4,
         count(*) || ' of 4 (1100 cash, 1300 receivable, 2200 payable, 1500 vehicle stock)'
    from public.chart_of_accounts
   where dealer_id = p_dealer_id and code in ('1100', '1300', '1500', '2200')
  union all
  -- 0027 seeds the core, 0042 finance, 0049 accessory cost, 0052 purchases. The
  -- number rises whenever a migration adds rules; a tenant below it is missing a
  -- seeder and will fail at posting time rather than here.
  select 'Accounting rules',
         count(*) >= 40,
         count(*) || ' rules across ' || count(distinct module) || ' modules'
    from public.accounting_rules where dealer_id = p_dealer_id
  union all
  select 'Branches',
         count(*) >= 1,
         count(*) || ' branch(es)'
    from public.branches where dealer_id = p_dealer_id
  union all
  select 'Cash account per branch',
         count(*) filter (where c.id is null) = 0,
         count(*) filter (where c.id is null) || ' branch(es) without one'
    from public.branches b
    left join public.cash_accounts c on c.branch_id = b.id
   where b.dealer_id = p_dealer_id
  union all
  select 'Document sequences',
         count(*) >= 9,
         count(*) || ' series for the current financial year'
    from public.document_sequences
   where dealer_id = p_dealer_id
     and financial_year = app.financial_year_token(p_dealer_id, current_date)
  union all
  select 'Accounting period open',
         count(*) >= 1,
         coalesce(min(name), 'none covering today')
    from public.accounting_periods
   where dealer_id = p_dealer_id and status = 'OPEN'
     and current_date between start_date and end_date
  union all
  select 'Owner login',
         count(*) >= 1,
         count(*) || ' active user(s) with DEALER_OWNER'
    from public.user_profiles up
    join public.user_roles ur on ur.user_id = up.id
    join public.roles r on r.id = ur.role_id
   where up.dealer_id = p_dealer_id and up.status = 'ACTIVE' and r.code = 'DEALER_OWNER'
  union all
  select 'Dealer is active',
         bool_or(status = 'ACTIVE'),
         coalesce(min(status), 'missing')
    from public.dealers where id = p_dealer_id;
$$;

comment on function public.dealer_readiness(uuid) is
  'One row per thing that must be true before a dealer can trade (spec §48). Run '
  'inside provisioning so a tenant that would not work never commits, and on the '
  'screen afterwards so the state is visible rather than assumed.';

-- -----------------------------------------------------------------------------
-- app.provision_dealer() — the whole onboarding, as one transaction
-- -----------------------------------------------------------------------------
-- Returns the new dealer and branch so the caller can send the invite and show
-- the readiness report. Raises rather than returning a failure: every failure
-- here should roll the whole thing back, and an exception is the only way to be
-- sure a caller cannot ignore one.
-- -----------------------------------------------------------------------------
create or replace function app.provision_dealer(
  p_code            text,
  p_legal_name      text,
  p_trade_name      text,
  p_state           text,
  p_state_code      text,
  p_owner_email     text,
  p_owner_name      text,
  p_owner_user_id   uuid,
  p_branch_name     text default 'Head Office',
  p_gstin           text default null,
  p_pan             text default null,
  p_city            text default null,
  p_phone           text default null,
  p_fy_start_month  smallint default 4
)
returns table (new_dealer_id uuid, new_branch_id uuid, accounts_created integer, rules_created integer)
language plpgsql
as $$
declare
  v_dealer   uuid;
  v_branch   uuid;
  v_accounts integer;
  v_rules    integer;
  v_year     text;
  v_owner    uuid;
  v_role     uuid;
  v_fy_start date;
  v_check    record;
  v_failed   text;
begin
  -- ── 1. Refuse before writing anything ────────────────────────────────────
  if not app.is_platform_admin() then
    raise exception 'Only a platform administrator can provision a dealer.'
      using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_code), '') = '' or coalesce(btrim(p_legal_name), '') = '' then
    raise exception 'A dealer needs a code and a legal name.' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_state_code), '') !~ '^[0-9]{2}$' then
    -- Not cosmetic: this decides CGST+SGST versus IGST on every invoice the
    -- dealer will ever raise (spec §16).
    raise exception 'A two-digit state code is required; got %.', p_state_code
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.dealers where upper(code) = upper(btrim(p_code))) then
    raise exception 'Dealer code % is already taken.', p_code using errcode = 'unique_violation';
  end if;
  -- Two tenants sharing a GSTIN would file each other's returns.
  if p_gstin is not null and exists (
    select 1 from public.dealers where gstin = upper(btrim(p_gstin))
  ) then
    raise exception 'GSTIN % already belongs to another dealer.', p_gstin
      using errcode = 'unique_violation';
  end if;
  if p_owner_user_id is null then
    raise exception 'The owner''s auth account must exist before provisioning.'
      using errcode = 'check_violation',
            hint = 'Create the Supabase Auth user first, then pass its id.';
  end if;
  if exists (select 1 from public.user_profiles where id = p_owner_user_id) then
    raise exception 'That login already belongs to a dealer.' using errcode = 'unique_violation';
  end if;

  -- ── 2. The dealer ────────────────────────────────────────────────────────
  insert into public.dealers
    (code, legal_name, trade_name, gstin, pan, city, state, state_code, phone,
     email, fy_start_month, status, created_by)
  values
    (upper(btrim(p_code)), btrim(p_legal_name), coalesce(nullif(btrim(p_trade_name), ''), btrim(p_legal_name)),
     upper(nullif(btrim(p_gstin), '')), upper(nullif(btrim(p_pan), '')),
     nullif(btrim(p_city), ''), btrim(p_state), btrim(p_state_code),
     nullif(btrim(p_phone), ''), lower(btrim(p_owner_email)),
     p_fy_start_month, 'ACTIVE', auth.uid())
  returning id into v_dealer;

  -- ── 3. The first branch ──────────────────────────────────────────────────
  -- Every sale, receipt and journal is branch-scoped, so a dealer without one
  -- cannot transact at all.
  insert into public.branches
    (dealer_id, code, name, city, state, state_code, phone, status, created_by)
  values
    (v_dealer, 'MAIN', coalesce(nullif(btrim(p_branch_name), ''), 'Head Office'),
     nullif(btrim(p_city), ''), btrim(p_state), btrim(p_state_code),
     nullif(btrim(p_phone), ''), 'ACTIVE', auth.uid())
  returning id into v_branch;

  -- ── 4. Chart of accounts ─────────────────────────────────────────────────
  v_accounts := app.seed_chart_of_accounts(v_dealer);

  -- ── 5. Every accounting-rule seeder ──────────────────────────────────────
  -- The list that grows. A migration adding rules adds a line here, and the
  -- readiness check below is the backstop when someone forgets.
  v_rules := app.seed_default_accounting_rules(v_dealer)
           + app.seed_finance_accounting_rules(v_dealer)
           + app.seed_cogs_accounting_rules(v_dealer)
           + app.seed_purchase_accounting_rules(v_dealer);

  -- ── 6. Document sequences ────────────────────────────────────────────────
  -- Financial documents only. Identifier sequences — customer, supplier,
  -- purchase-bill codes — self-provision on first use, deliberately: an
  -- identifier must never fail for want of setup, a financial document should.
  v_year := app.financial_year_token(v_dealer, current_date);

  insert into public.document_sequences
    (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
  values
    (v_dealer, null, 'VEHICLE_INVOICE',     v_year, 'INV', 6),
    (v_dealer, null, 'BOOKING',             v_year, 'BK',  6),
    (v_dealer, null, 'RECEIPT',             v_year, 'REC', 6),
    (v_dealer, null, 'PAYMENT',             v_year, 'PAY', 6),
    (v_dealer, null, 'JOB_CARD',            v_year, 'JC',  6),
    (v_dealer, null, 'SERVICE_INVOICE',     v_year, 'SVC', 6),
    (v_dealer, null, 'COUNTER_INVOICE',     v_year, 'CSI', 6),
    (v_dealer, null, 'JOURNAL',             v_year, 'JE',  6),
    (v_dealer, null, 'BANK_RECONCILIATION', v_year, 'BRS', 6),
    (v_dealer, null, 'DELIVERY',            v_year, 'DLV', 6)
  on conflict on constraint document_sequences_scope_key do nothing;

  -- ── 7. Cash account, and an open accounting period ───────────────────────
  -- Without a cash account, record_cash_transaction() raises "This branch has no
  -- cash account" the first time anyone takes money over the counter.
  perform app.ensure_branch_cash_accounts(v_dealer);

  v_fy_start := make_date(
    case when extract(month from current_date) >= p_fy_start_month
         then extract(year from current_date)::int
         else extract(year from current_date)::int - 1 end,
    p_fy_start_month, 1);

  insert into public.accounting_periods (dealer_id, name, start_date, end_date, status)
  values (
    v_dealer,
    'FY ' || to_char(v_fy_start, 'YYYY') || '-' || to_char(v_fy_start + interval '1 year' - interval '1 day', 'YY'),
    v_fy_start,
    (v_fy_start + interval '1 year' - interval '1 day')::date,
    'OPEN')
  on conflict (dealer_id, start_date, end_date) do nothing;

  -- ── 8. The owner ─────────────────────────────────────────────────────────
  insert into public.user_profiles
    (id, dealer_id, full_name, email, has_all_branch_access, default_branch_id, status)
  values
    (p_owner_user_id, v_dealer, btrim(p_owner_name), lower(btrim(p_owner_email)),
     true, v_branch, 'ACTIVE')
  returning id into v_owner;

  -- The system roles are global rows (dealer_id is null), so a new tenant needs
  -- none of its own — granting the role resolves all 123 permissions.
  select id into v_role from public.roles where code = 'DEALER_OWNER' and dealer_id is null;
  if v_role is null then
    raise exception 'The DEALER_OWNER system role is missing. Run seed.sql first.'
      using errcode = 'no_data_found';
  end if;

  insert into public.user_roles (user_id, role_id) values (v_owner, v_role)
  on conflict do nothing;

  -- ── 9. Refuse to commit a tenant that cannot trade ───────────────────────
  for v_check in select * from public.dealer_readiness(v_dealer) where not ok loop
    v_failed := coalesce(v_failed || '; ', '') || v_check.check_name || ' (' || v_check.detail || ')';
  end loop;

  if v_failed is not null then
    raise exception 'Provisioning would leave % unable to trade: %', p_code, v_failed
      using errcode = 'check_violation',
            hint = 'Nothing was written. Fix the cause and run again.';
  end if;

  new_dealer_id := v_dealer; new_branch_id := v_branch;
  accounts_created := v_accounts; rules_created := v_rules;
  return next;
end;
$$;

comment on function app.provision_dealer(text, text, text, text, text, text, text, uuid, text, text, text, text, text, smallint) is
  'Onboards a dealer in one transaction (spec §48): dealer, branch, chart of '
  'accounts, every accounting-rule seeder, document sequences, cash account, '
  'accounting period and owner. Refuses to commit a tenant that cannot trade. '
  'The invite email is sent by the caller AFTER this commits — it is the one '
  'step that cannot be rolled back.';

-- -----------------------------------------------------------------------------
-- public.purge_dealer() — undo an onboarding, while that is still honest
-- -----------------------------------------------------------------------------
-- For a tenant created by mistake. It refuses outright once anything has been
-- posted, rather than asking for confirmation: a posted journal is a statutory
-- record, it stays the dealer's whether or not they are still a customer, and a
-- confirmation dialog is a thing people click through.
--
-- The delete order below is the one scripts/remove-demo-dealer.sql works out —
-- 23 tables reference dealers with ON DELETE RESTRICT and 18 cascade, so a bare
-- `delete from dealers` fails immediately.
-- -----------------------------------------------------------------------------
create or replace function public.purge_dealer(
  p_dealer_id uuid,
  p_reason    text
)
returns void
language plpgsql
as $$
declare
  v_code text;
begin
  if not app.is_platform_admin() then
    raise exception 'Only a platform administrator can purge a dealer.'
      using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Purging a dealer requires a reason.' using errcode = 'check_violation';
  end if;

  select code into v_code from public.dealers where id = p_dealer_id;
  if v_code is null then
    raise exception 'Dealer not found.' using errcode = 'no_data_found';
  end if;

  -- The hard stop.
  if exists (
    select 1 from public.journal_entries
     where dealer_id = p_dealer_id and status in ('POSTED', 'REVERSED')
  ) then
    raise exception
      'Dealer % has posted journals and cannot be purged. Close it instead.', v_code
      using errcode = 'insufficient_privilege',
            hint = 'A posted ledger is a statutory record. Set status to CLOSED.';
  end if;

  -- Recorded before the rows go, because afterwards there is nothing to point at.
  insert into public.audit_logs
    (dealer_id, user_id, action, entity_type, entity_id, new_data, changed_fields)
  values
    (p_dealer_id, auth.uid(), 'DELETE', 'dealers', p_dealer_id::text,
     jsonb_build_object('code', v_code, 'reason', btrim(p_reason)), array['purged']);

  -- RESTRICT-referencing children first, deepest last-written first. Everything
  -- else cascades from public.dealers.
  delete from public.journal_entry_lines where dealer_id = p_dealer_id;
  delete from public.journal_entries      where dealer_id = p_dealer_id;
  delete from public.inventory_transactions where dealer_id = p_dealer_id;
  delete from public.vehicle_stock_transactions where dealer_id = p_dealer_id;
  delete from public.cash_transactions    where dealer_id = p_dealer_id;
  delete from public.bank_transactions    where dealer_id = p_dealer_id;
  delete from public.user_roles ur using public.user_profiles up
   where ur.user_id = up.id and up.dealer_id = p_dealer_id;
  delete from public.user_branches        where dealer_id = p_dealer_id;
  delete from public.user_profiles        where dealer_id = p_dealer_id;
  delete from public.accounting_rules     where dealer_id = p_dealer_id;
  -- Cash and bank accounts point AT the chart of accounts, so they go first;
  -- deleting the accounts underneath them fails on the ledger foreign key.
  delete from public.cash_accounts        where dealer_id = p_dealer_id;
  delete from public.bank_accounts        where dealer_id = p_dealer_id;
  -- Children before parents: the chart is self-referencing through parent_id.
  delete from public.chart_of_accounts    where dealer_id = p_dealer_id and parent_id is not null;
  delete from public.chart_of_accounts    where dealer_id = p_dealer_id;
  delete from public.branches             where dealer_id = p_dealer_id;
  delete from public.dealers              where id = p_dealer_id;
end;
$$;

comment on function public.purge_dealer(uuid, text) is
  'Deletes a mis-created tenant (spec §60.3). Refuses once any journal is POSTED '
  'or REVERSED — that ledger is the dealer''s statutory record. The owner''s '
  'Supabase Auth account survives and must be removed separately.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.dealer_readiness(uuid) to authenticated';
    execute 'grant execute on function public.purge_dealer(uuid, text) to authenticated';
    execute 'grant execute on function app.provision_dealer(text, text, text, text, text, text, text, uuid, text, text, text, text, text, smallint) to authenticated';
    execute 'grant execute on function app.seed_chart_of_accounts(uuid) to authenticated';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.provision_dealer() — the RPC surface
-- -----------------------------------------------------------------------------
-- PostgREST exposes `public` only, and app.provision_dealer() is where the work
-- lives (the app schema is where privileged machinery belongs, as with
-- app.post_journal). This is the thin wrapper the application calls.
-- -----------------------------------------------------------------------------
create or replace function public.provision_dealer(
  p_code            text,
  p_legal_name      text,
  p_trade_name      text,
  p_state           text,
  p_state_code      text,
  p_owner_email     text,
  p_owner_name      text,
  p_owner_user_id   uuid,
  p_branch_name     text default 'Head Office',
  p_gstin           text default null,
  p_pan             text default null,
  p_city            text default null,
  p_phone           text default null,
  p_fy_start_month  smallint default 4
)
returns table (new_dealer_id uuid, new_branch_id uuid, accounts_created integer, rules_created integer)
language sql
as $$
  select * from app.provision_dealer(
    p_code, p_legal_name, p_trade_name, p_state, p_state_code,
    p_owner_email, p_owner_name, p_owner_user_id, p_branch_name,
    p_gstin, p_pan, p_city, p_phone, p_fy_start_month);
$$;

comment on function public.provision_dealer(text, text, text, text, text, text, text, uuid, text, text, text, text, text, smallint) is
  'Onboards a dealer (spec §48). Thin wrapper over app.provision_dealer() so '
  'PostgREST can reach it; the permission check lives in the inner function.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.provision_dealer(text, text, text, text, text, text, text, uuid, text, text, text, text, text, smallint) to authenticated';
  end if;
end;
$$;


commit;
