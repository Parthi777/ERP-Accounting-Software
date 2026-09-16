-- =============================================================================
-- 0072 — Document series: the three nobody seeds, and the year they all expire
-- =============================================================================
-- Spec §45, §48, §60.3, §60.6, §60.7.
--
-- Three defects, one cause: the list of document series a dealer needs is
-- written out by hand in three places that have drifted apart.
--
--   seed.sql                 15 types   the demo dealer
--   app.provision_dealer()   10 types   every real dealer
--   0038 / 0039 backfills     3 types   dealers that existed in August
--
-- 1. A PROVISIONED DEALER CANNOT TRANSFER STOCK OR FINANCE A SALE.
--
--    STOCK_TRANSFER, FINANCE_APPLICATION and FINANCE_SETTLEMENT are requested at
--    runtime by dispatch_vehicle_transfer(), transfer_inventory_stock(),
--    create_finance_application() and create_finance_settlement(). They are
--    seeded by neither provision_dealer() nor a self-provisioning trigger. They
--    were backfilled once, by 0038 and 0039, with `where ds.branch_id is not
--    null` — which reached only the dealers that already existed then.
--    provision_dealer() landed later, at 0056, and never picked them up.
--
--    So every tenant created through Administration → Dealers raises
--    "No document sequence configured" the first time anyone moves a vehicle
--    between branches or sends a customer to a finance company. The demo dealer
--    cannot show it: seed.sql lists all fifteen, so the test suite has been
--    asserting against the one dealer that was never affected.
--
-- 2. dealer_readiness() REPORTS GREEN WHILE THEY ARE MISSING.
--
--    Its document-sequence check passes at `count(*) >= 9`. Provisioning inserts
--    ten. The check therefore cannot fail for this, and it is read at exactly the
--    moment someone decides a tenant is fit to trade.
--
-- 3. EVERY SERIES EXPIRES AT THE FINANCIAL-YEAR BOUNDARY.
--
--    financial_year is part of the unique scope, and provisioning seeds only the
--    year current when the tenant was created. On the dealer's next 1 April all
--    thirteen financial types begin raising at once — no invoice, no receipt, no
--    journal, no delivery — and dealer_readiness() only ever looks at the current
--    year, so nothing warns beforehand. There is no screen on which to fix it:
--    document_sequences is read-only in the app.
--
-- WHY THIS DOES NOT CONTRADICT 0056.
--
-- 0056 says plainly that an identifier may self-provision but a financial
-- document should fail rather than invent a series nobody configured, and 0067
-- reaffirmed it while carving out a narrow exception for back-dated opening
-- balances. That principle is kept here. The rule added below is narrower than
-- self-provisioning:
--
--   a series already configured for one financial year is carried into another,
--   keeping its prefix and padding and starting its counter at zero;
--   a doc_type configured in NO year still raises, exactly as today.
--
-- Nothing is invented. A series the dealer deliberately configured continues
-- across a year boundary, which is what every Indian dealer's numbering does on
-- 1 April anyway. An unknown doc_type — a typo at a call site, a type nobody set
-- up — still fails loudly, which is the behaviour 0056 wanted to protect.
--
-- This is the third time the missing-series shape has been fixed (0038 for
-- transfers and deliveries, 0067 for opening-balance journals, this one). Both
-- earlier fixes were narrow exceptions for one type. The mechanism below retires
-- the shape rather than the instance, and the canonical list moves into one
-- function so the three hand-written copies cannot drift again.
--
-- Rollback: drop trigger dealers_ensure_document_sequences on public.dealers;
--           drop function app.ensure_document_sequences(uuid, text),
--                         app.dealers_ensure_document_sequences(),
--                         app.required_document_series();
--           restore app.next_document_number() from 0039 and
--           public.dealer_readiness() from 0056. Rows created by the backfill are
--           left in place; deleting a counter a document has been issued from
--           would reissue numbers.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- app.required_document_series() — the one list
-- -----------------------------------------------------------------------------
-- Every financial document series a dealer needs, with its prefix. This is the
-- list seed.sql had right and provision_dealer() had wrong; from here there is
-- one copy and everything reads it.
--
-- Identifier series — CUSTOMER, SUPPLIER, PURCHASE_BILL, PURCHASE_RETURN — are
-- deliberately absent. They self-provision in a BEFORE INSERT trigger on the row
-- that needs them (0013, 0040, 0052, 0057), because an identifier must never
-- fail for want of setup. Adding them here would be harmless but would blur the
-- distinction 0056 drew.
-- -----------------------------------------------------------------------------
create or replace function app.required_document_series()
returns table (doc_type text, prefix text)
language sql
immutable
as $$
  values ('VEHICLE_INVOICE',     'INV'),
         ('BOOKING',             'BK'),
         ('RECEIPT',             'REC'),
         ('PAYMENT',             'PAY'),
         ('JOB_CARD',            'JC'),
         ('SERVICE_INVOICE',     'SVC'),
         ('COUNTER_INVOICE',     'CSI'),
         ('JOURNAL',             'JE'),
         ('BANK_RECONCILIATION', 'BRS'),
         ('STOCK_TRANSFER',      'TRF'),
         ('DELIVERY',            'DN'),
         ('FINANCE_APPLICATION', 'FA'),
         ('FINANCE_SETTLEMENT',  'FS');
$$;

comment on function app.required_document_series() is
  'The financial document series every dealer needs, with prefixes (spec §45). '
  'One definition: provisioning, the readiness check and the seed all read it. '
  'Identifier series are absent on purpose — they self-provision (0013, 0040).';

-- Note on DELIVERY: provision_dealer() used prefix DLV while seed.sql and the
-- 0038 backfill both used DN. DN wins, because it is what every dealer that has
-- actually issued a delivery note is using. Dealers already provisioned with DLV
-- keep it — the insert below cannot overwrite an existing row, and changing the
-- prefix of a series someone has issued documents from would break the sequence
-- printed on paper.

-- -----------------------------------------------------------------------------
-- app.ensure_document_sequences() — idempotent, for one dealer and one year
-- -----------------------------------------------------------------------------
create or replace function app.ensure_document_sequences(
  p_dealer_id      uuid,
  p_financial_year text default null
)
returns int
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_year    text;
  v_created int;
begin
  v_year := coalesce(p_financial_year, app.financial_year_token(p_dealer_id, current_date));

  if v_year is null then
    raise exception 'Dealer % not found.', p_dealer_id using errcode = 'no_data_found';
  end if;

  insert into public.document_sequences
    (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
  select p_dealer_id, null, s.doc_type, v_year, s.prefix, 6
    from app.required_document_series() s
  on conflict on constraint document_sequences_scope_key do nothing;

  get diagnostics v_created = row_count;
  return v_created;
end;
$$;

comment on function app.ensure_document_sequences(uuid, text) is
  'Creates any missing dealer-wide financial series for one financial year and '
  'returns how many it created. Idempotent, so it is safe to call on every '
  'dealer insert and from a year-end rollover (spec §45).';

-- -----------------------------------------------------------------------------
-- Every new dealer gets the full set, whatever created it
-- -----------------------------------------------------------------------------
-- A trigger rather than an edit to provision_dealer(), so that seed.sql, a
-- data migration and any future provisioning path are all covered by the same
-- rule. provision_dealer() still runs its own ten-row insert afterwards; every
-- row it writes now collides with one this trigger already created and is
-- discarded by `on conflict do nothing`, so the canonical list wins and the
-- vestigial block is harmless.
-- -----------------------------------------------------------------------------
create or replace function app.dealers_ensure_document_sequences()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform app.ensure_document_sequences(new.id, null);
  return null;
end;
$$;

drop trigger if exists dealers_ensure_document_sequences on public.dealers;
create trigger dealers_ensure_document_sequences
  after insert on public.dealers
  for each row execute function app.dealers_ensure_document_sequences();

-- -----------------------------------------------------------------------------
-- app.next_document_number() — carry a configured series into another year
-- -----------------------------------------------------------------------------
-- Unchanged from 0039 except for the block marked below: dealer-wide first,
-- branch second, and the row lock that makes it safe under concurrent sales
-- (spec §49) both still hold.
-- -----------------------------------------------------------------------------
create or replace function app.next_document_number(
  p_dealer_id      uuid,
  p_branch_id      uuid,
  p_doc_type       text,
  p_financial_year text
)
returns text
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_prefix   text;
  v_padding  smallint;
  v_number   bigint;
  v_scope    uuid;
  v_src_prefix  text;
  v_src_padding smallint;
begin
  -- A dealer-wide series, when configured, is authoritative for this type. The
  -- branch the caller passed is still recorded on the document; it simply is not
  -- what allocates the number (spec §45).
  update public.document_sequences ds
     set last_number = ds.last_number + 1
   where ds.dealer_id = p_dealer_id
     and ds.branch_id is null
     and ds.doc_type = p_doc_type
     and ds.financial_year = p_financial_year
  returning ds.prefix, ds.padding, ds.last_number
       into v_prefix, v_padding, v_number;

  if v_number is null then
    update public.document_sequences ds
       set last_number = ds.last_number + 1
     where ds.dealer_id = p_dealer_id
       and ds.branch_id is not distinct from p_branch_id
       and ds.doc_type = p_doc_type
       and ds.financial_year = p_financial_year
    returning ds.prefix, ds.padding, ds.last_number
         into v_prefix, v_padding, v_number;
  end if;

  -- ── Carry the series into a year it has not been configured for ──────────
  --
  -- Only ever from a definition this dealer already has for this doc_type. The
  -- nearest configured year wins, preferring an earlier one, so a new financial
  -- year continues the definition in force the day before it started, and a
  -- back-dated document (an opening balance, 0067) picks up the definition of
  -- the year it is dated into. Prefix and padding carry; the counter starts at
  -- zero, which is what a financial year turning over is supposed to do.
  --
  -- A doc_type this dealer has configured in no year at all falls through to the
  -- raise below, unchanged. Nothing is invented here (spec §45, and the rule
  -- 0056 set out).
  if v_number is null and p_financial_year ~ '^[0-9]{4}$' then
    -- The scope this dealer keeps this type in: dealer-wide if any year has a
    -- dealer-wide row, otherwise the branch the caller named. Resolved once,
    -- rather than inside the search, so the carried row lands in the same scope
    -- the precedence above will look for.
    if exists (select 1 from public.document_sequences d2
                where d2.dealer_id = p_dealer_id
                  and d2.doc_type = p_doc_type
                  and d2.branch_id is null) then
      v_scope := null;
    else
      v_scope := p_branch_id;
    end if;

    select ds.prefix, ds.padding
      into v_src_prefix, v_src_padding
      from public.document_sequences ds
     where ds.dealer_id = p_dealer_id
       and ds.doc_type = p_doc_type
       and ds.branch_id is not distinct from v_scope
       -- A year token this function did not write is not a year to reason about.
       and ds.financial_year ~ '^[0-9]{4}$'
     order by (ds.financial_year > p_financial_year),
              abs(ds.financial_year::int - p_financial_year::int)
     limit 1;

    if v_src_prefix is not null then
      insert into public.document_sequences
        (dealer_id, branch_id, doc_type, financial_year, prefix, padding, last_number)
      values
        (p_dealer_id, v_scope, p_doc_type, p_financial_year,
         v_src_prefix, v_src_padding, 0)
      on conflict on constraint document_sequences_scope_key do nothing;

      -- Re-read rather than trust the insert. Two cashiers crossing the year
      -- boundary together both reach here; one insert wins, the other is
      -- discarded, and both take their number from the row that survived.
      update public.document_sequences ds
         set last_number = ds.last_number + 1
       where ds.dealer_id = p_dealer_id
         and ds.branch_id is not distinct from v_scope
         and ds.doc_type = p_doc_type
         and ds.financial_year = p_financial_year
      returning ds.prefix, ds.padding, ds.last_number
           into v_prefix, v_padding, v_number;
    end if;
  end if;

  if v_number is null then
    raise exception
      'No document sequence configured for dealer %, branch %, type %, year %.',
      p_dealer_id, coalesce(p_branch_id::text, '(dealer-wide)'), p_doc_type, p_financial_year
      using errcode = 'no_data_found',
            hint = 'Insert a row into document_sequences before issuing this document type.';
  end if;

  return v_prefix || '-' || p_financial_year || '-' || lpad(v_number::text, v_padding, '0');
end;
$$;

comment on function app.next_document_number(uuid, uuid, text, text) is
  'Returns the next number for a document scope, e.g. INV-2026-000001. '
  'A dealer-wide sequence takes precedence over a branch one (spec §45, §60.3). '
  'A series configured for another financial year is carried into this one, '
  'keeping its prefix and restarting its counter; a doc_type configured in no '
  'year at all still raises. Row-locked, so it is safe under concurrent sales '
  '(spec §49).';

-- -----------------------------------------------------------------------------
-- Backfill: the three missing types, for every dealer that already exists
-- -----------------------------------------------------------------------------
-- Covers the current financial year for every active tenant. Earlier years are
-- left alone — carrying a series backwards would create counters for years that
-- are closed, and next_document_number() now reaches them on demand if a
-- back-dated document ever needs one.
-- -----------------------------------------------------------------------------
do $$
declare
  v_dealer  record;
  v_created int;
  v_total   int := 0;
begin
  for v_dealer in select id, code from public.dealers loop
    v_created := app.ensure_document_sequences(v_dealer.id, null);
    v_total := v_total + v_created;
    if v_created > 0 then
      raise notice '  % — created % missing series', v_dealer.code, v_created;
    end if;
  end loop;
  raise notice '  document series backfill: % row(s) created', v_total;
end $$;

-- -----------------------------------------------------------------------------
-- dealer_readiness() — say which series are missing, not how many are present
-- -----------------------------------------------------------------------------
-- Unchanged from 0056 except the 'Document sequences' branch. `count(*) >= 9`
-- could not fail for the three types this migration fixes; it now compares
-- against app.required_document_series() and names what is absent, which is the
-- difference between a check and a formality.
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
         count(*) filter (where ds.id is null) = 0,
         case when count(*) filter (where ds.id is null) = 0
              then count(*) || ' series for the current financial year'
              else 'missing: ' || string_agg(s.doc_type, ', ' order by s.doc_type)
                                  filter (where ds.id is null)
         end
    from app.required_document_series() s
    left join public.document_sequences ds
           on ds.dealer_id = p_dealer_id
          and ds.doc_type = s.doc_type
          and ds.financial_year = app.financial_year_token(p_dealer_id, current_date)
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

-- Ownership of the new functions matches the rest: security definer bodies reach
-- document_sequences past RLS, and only `authenticated` may call them.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function app.required_document_series() to authenticated';
    execute 'grant execute on function app.ensure_document_sequences(uuid, text) to authenticated';
  end if;
end $$;

revoke execute on function app.ensure_document_sequences(uuid, text) from public;

insert into public.schema_migrations (version, name)
values ('0072', 'document_sequence_rollover') on conflict (version) do nothing;
