-- =============================================================================
-- INCREMENTAL 0013 → 0026
-- =============================================================================
-- GENERATED FILE. Regenerate with:
--   FROM=0013 bash scripts/build-incremental.sh
--
-- For a database that ALREADY has migrations up to 0012.
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
-- SOURCE: supabase/migrations/0013_customers.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0013 — Customer master
-- =============================================================================
-- Spec §11, §60.6. A dealer-level master: customers belong to the dealer, not to
-- a branch, so a customer who books at one branch and services at another is one
-- record rather than two.
--
-- The Customer ID is mandatory and auto-generated (spec §60.6). It is issued by
-- the same row-locked sequence mechanism as invoices (§45), never by the client,
-- so two cashiers creating customers at the same instant cannot collide.
--
-- Rollback: drop table public.customers; drop function app.financial_year_token(uuid, date),
--           app.customers_assign_code();
-- =============================================================================

-- -----------------------------------------------------------------------------
-- app.financial_year_token() — the year token used inside document numbers
-- -----------------------------------------------------------------------------
-- Reads the dealer's own fy_start_month (4 = April for Indian FY), so a dealer on
-- a non-standard financial year numbers its documents correctly.
-- -----------------------------------------------------------------------------
create or replace function app.financial_year_token(p_dealer_id uuid, p_date date default current_date)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case
           when extract(month from p_date) >= coalesce(d.fy_start_month, 4)
           then extract(year from p_date)::int
           else extract(year from p_date)::int - 1
         end::text
    from public.dealers d
   where d.id = p_dealer_id;
$$;

comment on function app.financial_year_token(uuid, date) is
  'Financial-year token for document numbering, e.g. 2026 in CUST-2026-000001.';

create table public.customers (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null references public.dealers (id) on delete restrict,

  -- Mandatory, dealer-unique, server-issued (spec §11, §60.6).
  customer_code     text not null,

  name              text not null,
  customer_type     text not null default 'INDIVIDUAL',

  mobile            text not null,
  alternate_mobile  text,
  email             text,

  address_line1     text,
  address_line2     text,
  city              text,
  state             text,
  state_code        text,
  pincode           text,

  gstin             text,
  pan               text,

  -- Where the customer was first registered. Informational: the record stays
  -- visible dealer-wide, because a customer is not branch property.
  origin_branch_id  uuid,

  notes             text,
  status            text not null default 'ACTIVE',

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid,
  updated_by        uuid,

  constraint customers_dealer_code_key unique (dealer_id, customer_code),
  constraint customers_id_dealer_key   unique (id, dealer_id),
  constraint customers_origin_branch_tenant_fkey
    foreign key (origin_branch_id, dealer_id) references public.branches (id, dealer_id),

  constraint customers_type_check   check (customer_type in ('INDIVIDUAL', 'BUSINESS')),
  constraint customers_status_check check (status in ('ACTIVE', 'INACTIVE', 'BLOCKED')),
  constraint customers_name_check   check (length(btrim(name)) between 2 and 150),
  -- Ten digits, first digit 6-9: the Indian mobile numbering plan.
  constraint customers_mobile_check check (mobile ~ '^[6-9][0-9]{9}$'),
  constraint customers_alt_mobile_check check (
    alternate_mobile is null or alternate_mobile ~ '^[6-9][0-9]{9}$'
  ),
  constraint customers_email_check check (email is null or email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[a-zA-Z]{2,}$'),
  constraint customers_gstin_check check (
    gstin is null or gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[0-9A-Z]{1}Z[0-9A-Z]{1}$'
  ),
  constraint customers_pan_check     check (pan is null or pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  constraint customers_pincode_check check (pincode is null or pincode ~ '^[1-9][0-9]{5}$'),
  -- A business customer registered under GST must carry a GSTIN.
  constraint customers_business_gstin_check check (
    customer_type <> 'BUSINESS' or gstin is not null
  )
);

comment on table public.customers is
  'Customer master (spec §11). Dealer-scoped, not branch-scoped: one customer record '
  'serves every branch the customer deals with.';
comment on column public.customers.customer_code is
  'Auto-generated, dealer-unique, issued server-side. Never supplied by the client.';

-- The same mobile number twice within a dealer is almost always a duplicate
-- record. Enforced only for active customers so a blocked record does not
-- prevent re-registering the person later.
create unique index customers_dealer_mobile_key
  on public.customers (dealer_id, mobile)
  where status = 'ACTIVE';

-- -----------------------------------------------------------------------------
-- Customer ID assignment
-- -----------------------------------------------------------------------------
-- Runs BEFORE INSERT, so the code is issued by the database under the same row
-- lock that protects invoice numbers. The sequence row is created on first use,
-- which means a newly provisioned dealer needs no manual setup — unlike financial
-- documents, where an unconfigured sequence should be a loud error rather than an
-- assumption.
-- -----------------------------------------------------------------------------
create or replace function app.customers_assign_code()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_year text;
begin
  if new.customer_code is not null and btrim(new.customer_code) <> '' then
    return new;  -- an explicit code (data migration) is respected
  end if;

  v_year := app.financial_year_token(new.dealer_id, coalesce(new.created_at::date, current_date));

  insert into public.document_sequences (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
  values (new.dealer_id, null, 'CUSTOMER', v_year, 'CUST', 6)
  on conflict on constraint document_sequences_scope_key do nothing;

  new.customer_code := app.next_document_number(new.dealer_id, null, 'CUSTOMER', v_year);
  return new;
end;
$$;

create trigger customers_assign_code
  before insert on public.customers
  for each row execute function app.customers_assign_code();

create trigger customers_set_updated_at
  before update on public.customers
  for each row execute function app.set_updated_at();

create trigger customers_audit
  after insert or update or delete on public.customers
  for each row execute function app.audit_trigger();

-- -----------------------------------------------------------------------------
-- Row Level Security
-- -----------------------------------------------------------------------------
alter table public.customers enable row level security;

create policy customers_select on public.customers
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('customers.view'))
  );

create policy customers_insert on public.customers
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('customers.create'))
  );

create policy customers_update on public.customers
  for update to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('customers.edit'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('customers.edit'))
  );

-- No DELETE policy. A customer with transactions behind them must never vanish;
-- set status to INACTIVE or BLOCKED instead.

-- -----------------------------------------------------------------------------
-- Indexes — spec §11 requires search by ID, mobile and name
-- -----------------------------------------------------------------------------
create index customers_dealer_name_idx   on public.customers (dealer_id, lower(name));
create index customers_dealer_status_idx on public.customers (dealer_id, status);
create index customers_alt_mobile_idx    on public.customers (dealer_id, alternate_mobile)
  where alternate_mobile is not null;
create index customers_gstin_idx         on public.customers (dealer_id, gstin) where gstin is not null;
create index customers_created_idx       on public.customers (dealer_id, created_at desc);
create index customers_origin_branch_idx on public.customers (origin_branch_id) where origin_branch_id is not null;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.customers to authenticated';
    execute 'grant all on public.customers to service_role';
    execute 'grant execute on function app.financial_year_token(uuid, date) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0014_tax_and_hsn.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0014 — Tax master: HSN/SAC codes and effective-dated tax codes
-- =============================================================================
-- Spec §16, §60.11. GST is configuration-driven: no rate is ever hard-coded in
-- UI or service logic. Rates are effective-dated, so a historical invoice keeps
-- the rate that applied on its date even after the master changes.
--
-- Rollback: drop table public.tax_codes, public.hsn_codes;
-- =============================================================================

create table public.hsn_codes (
  id          uuid primary key default gen_random_uuid(),
  dealer_id   uuid not null references public.dealers (id) on delete cascade,
  code        text not null,
  -- HSN for goods, SAC for services (labour).
  code_type   text not null default 'HSN',
  description text not null,
  status      text not null default 'ACTIVE',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid,
  updated_by  uuid,

  constraint hsn_dealer_code_key unique (dealer_id, code),
  constraint hsn_id_dealer_key   unique (id, dealer_id),
  constraint hsn_type_check   check (code_type in ('HSN', 'SAC')),
  constraint hsn_status_check check (status in ('ACTIVE', 'INACTIVE')),
  constraint hsn_code_check   check (code ~ '^[0-9]{4,8}$')
);

comment on table public.hsn_codes is 'HSN (goods) and SAC (services) codes, dealer-scoped (spec §16).';

-- -----------------------------------------------------------------------------
-- tax_codes — effective-dated GST rates
-- -----------------------------------------------------------------------------
-- The CGST/SGST split and the IGST rate are stored rather than derived, because
-- they are not always exactly half: cess and special rates exist. `total_rate` is
-- generated so it can never disagree with its components.
-- -----------------------------------------------------------------------------
create table public.tax_codes (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null references public.dealers (id) on delete cascade,

  code           text not null,
  name           text not null,
  hsn_code_id    uuid,

  cgst_rate      numeric(6, 3) not null default 0,
  sgst_rate      numeric(6, 3) not null default 0,
  igst_rate      numeric(6, 3) not null default 0,
  cess_rate      numeric(6, 3) not null default 0,

  -- Intra-state supply uses CGST + SGST; inter-state uses IGST.
  total_rate     numeric(6, 3) generated always as (cgst_rate + sgst_rate + cess_rate) stored,

  effective_from date not null,
  effective_to   date,

  status         text not null default 'ACTIVE',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid,
  updated_by     uuid,

  constraint tax_codes_id_dealer_key unique (id, dealer_id),
  constraint tax_codes_hsn_tenant_fkey
    foreign key (hsn_code_id, dealer_id) references public.hsn_codes (id, dealer_id),
  constraint tax_codes_code_check   check (code ~ '^[A-Z][A-Z0-9_]{1,30}$'),
  constraint tax_codes_status_check check (status in ('ACTIVE', 'INACTIVE')),
  constraint tax_codes_rates_check  check (
    cgst_rate >= 0 and sgst_rate >= 0 and igst_rate >= 0 and cess_rate >= 0
    and cgst_rate <= 50 and sgst_rate <= 50 and igst_rate <= 50
  ),
  -- IGST equals the intra-state total: 9+9 intra maps to 18 inter.
  constraint tax_codes_igst_matches_check check (igst_rate = cgst_rate + sgst_rate),
  constraint tax_codes_dates_check check (effective_to is null or effective_to >= effective_from)
);

comment on table public.tax_codes is
  'Effective-dated GST rates (spec §16). Invoices resolve the rate applicable on '
  'their document date, so history never changes when a rate is updated.';

-- One open-ended version per code: the current rate is unambiguous.
create unique index tax_codes_open_version_key
  on public.tax_codes (dealer_id, code)
  where effective_to is null;

create index tax_codes_lookup_idx on public.tax_codes (dealer_id, code, effective_from desc);
create index hsn_codes_dealer_idx on public.hsn_codes (dealer_id, status);

-- -----------------------------------------------------------------------------
-- app.resolve_tax_code() — the rate applicable to a document date
-- -----------------------------------------------------------------------------
-- Every taxed line resolves its rate through this function. Nothing else should
-- read tax_codes directly to pick a rate, or the effective-dating is bypassed.
-- -----------------------------------------------------------------------------
create or replace function public.resolve_tax_code(
  p_dealer_id uuid,
  p_code      text,
  p_on_date   date default current_date
)
returns table (
  tax_code_id uuid,
  code        text,
  cgst_rate   numeric(6, 3),
  sgst_rate   numeric(6, 3),
  igst_rate   numeric(6, 3),
  cess_rate   numeric(6, 3),
  total_rate  numeric(6, 3)
)
language sql
stable
as $$
  select t.id, t.code, t.cgst_rate, t.sgst_rate, t.igst_rate, t.cess_rate, t.total_rate
    from public.tax_codes t
   where t.dealer_id = p_dealer_id
     and t.code = p_code
     and t.status = 'ACTIVE'
     and t.effective_from <= p_on_date
     and (t.effective_to is null or t.effective_to >= p_on_date)
   order by t.effective_from desc
   limit 1;
$$;

comment on function public.resolve_tax_code(uuid, text, date) is
  'The tax rate in force for a code on a given date (spec §16). Used by every '
  'taxed document so historical invoices keep their original rates.';

create trigger hsn_codes_set_updated_at before update on public.hsn_codes
  for each row execute function app.set_updated_at();
create trigger tax_codes_set_updated_at before update on public.tax_codes
  for each row execute function app.set_updated_at();

create trigger hsn_codes_audit after insert or update or delete on public.hsn_codes
  for each row execute function app.audit_trigger();
-- Spec §46 lists GST changes explicitly among audited actions.
create trigger tax_codes_audit after insert or update or delete on public.tax_codes
  for each row execute function app.audit_trigger();

alter table public.hsn_codes enable row level security;
alter table public.tax_codes enable row level security;

create policy hsn_codes_select on public.hsn_codes for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('masters.hsn.view')));
create policy hsn_codes_write on public.hsn_codes for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('masters.hsn.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('masters.hsn.manage')));

create policy tax_codes_select on public.tax_codes for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('masters.tax.view')));
create policy tax_codes_write on public.tax_codes for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('masters.tax.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('masters.tax.manage')));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update, delete on public.hsn_codes, public.tax_codes to authenticated';
    execute 'grant all on public.hsn_codes, public.tax_codes to service_role';
    execute 'grant execute on function public.resolve_tax_code(uuid, text, date) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0015_vehicle_catalogue.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0015 — Vehicle catalogue: models, variants, colours
-- =============================================================================
-- Spec §13, §44. The catalogue is what a dealer *sells*; migration 0018 adds the
-- physical vehicles they *hold*. Keeping them apart is what makes chassis-level
-- stock possible (spec §60.8) — a model is a type, a vehicle is an object.
--
-- Rollback: drop table public.vehicle_colours, public.vehicle_variants, public.vehicle_models;
-- =============================================================================

create table public.vehicle_models (
  id            uuid primary key default gen_random_uuid(),
  dealer_id     uuid not null references public.dealers (id) on delete cascade,

  brand         text not null,
  name          text not null,
  model_code    text not null,
  -- Segment drives the dashboard's revenue-by-category split.
  category      text not null default 'SCOOTER',
  fuel_type     text not null default 'PETROL',

  hsn_code_id   uuid,
  tax_code      text,

  status        text not null default 'ACTIVE',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid,
  updated_by    uuid,

  constraint vehicle_models_dealer_code_key unique (dealer_id, model_code),
  constraint vehicle_models_id_dealer_key   unique (id, dealer_id),
  constraint vehicle_models_hsn_tenant_fkey
    foreign key (hsn_code_id, dealer_id) references public.hsn_codes (id, dealer_id),
  constraint vehicle_models_category_check check (
    category in ('SCOOTER', 'MOTORCYCLE', 'MOPED', 'ELECTRIC', 'THREE_WHEELER')
  ),
  constraint vehicle_models_fuel_check   check (fuel_type in ('PETROL', 'ELECTRIC', 'CNG', 'HYBRID')),
  constraint vehicle_models_status_check check (status in ('ACTIVE', 'DISCONTINUED')),
  constraint vehicle_models_code_check   check (model_code ~ '^[A-Z0-9][A-Z0-9._-]{1,29}$')
);

comment on table public.vehicle_models is 'Vehicle model master (spec §44). A type, not a physical unit.';

create table public.vehicle_variants (
  id           uuid primary key default gen_random_uuid(),
  dealer_id    uuid not null,
  model_id     uuid not null,

  name         text not null,
  variant_code text not null,
  -- Specification fields a dealer actually quotes on.
  engine_cc    numeric(6, 1),
  transmission text,
  brake_type   text,
  start_type   text,

  status       text not null default 'ACTIVE',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  created_by   uuid,
  updated_by   uuid,

  constraint vehicle_variants_dealer_code_key unique (dealer_id, variant_code),
  constraint vehicle_variants_id_dealer_key   unique (id, dealer_id),
  constraint vehicle_variants_model_tenant_fkey
    foreign key (model_id, dealer_id) references public.vehicle_models (id, dealer_id) on delete cascade,
  constraint vehicle_variants_status_check check (status in ('ACTIVE', 'DISCONTINUED')),
  constraint vehicle_variants_code_check   check (variant_code ~ '^[A-Z0-9][A-Z0-9._-]{1,29}$'),
  constraint vehicle_variants_cc_check     check (engine_cc is null or engine_cc between 0 and 2000)
);

comment on table public.vehicle_variants is 'Variant beneath a model (spec §44). Pricing attaches at this level.';

create table public.vehicle_colours (
  id          uuid primary key default gen_random_uuid(),
  dealer_id   uuid not null,
  variant_id  uuid not null,

  name        text not null,
  colour_code text,
  hex         text,

  status      text not null default 'ACTIVE',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint vehicle_colours_variant_name_key unique (variant_id, name),
  constraint vehicle_colours_id_dealer_key    unique (id, dealer_id),
  constraint vehicle_colours_variant_tenant_fkey
    foreign key (variant_id, dealer_id) references public.vehicle_variants (id, dealer_id) on delete cascade,
  constraint vehicle_colours_status_check check (status in ('ACTIVE', 'DISCONTINUED')),
  constraint vehicle_colours_hex_check    check (hex is null or hex ~ '^#[0-9A-Fa-f]{6}$')
);

create index vehicle_models_dealer_idx   on public.vehicle_models (dealer_id, status);
create index vehicle_models_brand_idx    on public.vehicle_models (dealer_id, brand);
create index vehicle_models_hsn_idx      on public.vehicle_models (hsn_code_id) where hsn_code_id is not null;
create index vehicle_variants_model_idx  on public.vehicle_variants (model_id, status);
create index vehicle_variants_dealer_idx on public.vehicle_variants (dealer_id, status);
create index vehicle_colours_variant_idx on public.vehicle_colours (variant_id, status);

create trigger vehicle_models_set_updated_at before update on public.vehicle_models
  for each row execute function app.set_updated_at();
create trigger vehicle_variants_set_updated_at before update on public.vehicle_variants
  for each row execute function app.set_updated_at();
create trigger vehicle_colours_set_updated_at before update on public.vehicle_colours
  for each row execute function app.set_updated_at();

create trigger vehicle_models_audit after insert or update or delete on public.vehicle_models
  for each row execute function app.audit_trigger();
create trigger vehicle_variants_audit after insert or update or delete on public.vehicle_variants
  for each row execute function app.audit_trigger();

alter table public.vehicle_models   enable row level security;
alter table public.vehicle_variants enable row level security;
alter table public.vehicle_colours  enable row level security;

do $$
declare t text;
begin
  foreach t in array array['vehicle_models', 'vehicle_variants', 'vehicle_colours'] loop
    execute format($f$
      create policy %1$s_select on public.%1$I for select to authenticated
        using (app.is_platform_admin()
               or (dealer_id = app.current_dealer_id() and app.has_permission('vehicles.models.view')))
    $f$, t);
    execute format($f$
      create policy %1$s_write on public.%1$I for all to authenticated
        using (app.is_platform_admin()
               or (dealer_id = app.current_dealer_id() and app.has_permission('vehicles.models.manage')))
        with check (app.is_platform_admin()
               or (dealer_id = app.current_dealer_id() and app.has_permission('vehicles.models.manage')))
    $f$, t);
  end loop;

  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update, delete on public.vehicle_models, public.vehicle_variants, public.vehicle_colours to authenticated';
    execute 'grant all on public.vehicle_models, public.vehicle_variants, public.vehicle_colours to service_role';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0016_inventory_items.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0016 — Accessory and spare item master, and finance companies
-- =============================================================================
-- Spec §28, §29, §25.
--
-- Accessories and spares share one table with an `item_type` discriminator: they
-- have identical structure and identical stock mechanics (spec §29, "same
-- architecture as accessories"), and one table means one stock ledger rather than
-- two that must be kept in step.
--
-- What must NOT be merged is LOCAL and COMPANY stock (spec §28, §60.16). That
-- separation lives on the stock rows in 0020, not here — the item is the same
-- product regardless of who supplied it; the lot is what differs.
--
-- Rollback: drop table public.finance_companies, public.inventory_items;
-- =============================================================================

create table public.inventory_items (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null references public.dealers (id) on delete cascade,

  item_code      text not null,
  name           text not null,
  item_type      text not null,

  brand          text,
  category       text,
  uom            text not null default 'NOS',

  hsn_code_id    uuid,
  tax_code       text,

  -- Indicative only. The cost that matters is on the stock lot (0020), because
  -- two lots of the same item can be bought at different prices.
  standard_cost  numeric(18, 4) not null default 0,
  selling_price  numeric(18, 4) not null default 0,

  reorder_level  numeric(14, 3) not null default 0,
  is_fitment     boolean not null default false,

  status         text not null default 'ACTIVE',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid,
  updated_by     uuid,

  constraint inventory_items_dealer_code_key unique (dealer_id, item_code),
  constraint inventory_items_id_dealer_key   unique (id, dealer_id),
  constraint inventory_items_hsn_tenant_fkey
    foreign key (hsn_code_id, dealer_id) references public.hsn_codes (id, dealer_id),
  constraint inventory_items_type_check   check (item_type in ('ACCESSORY', 'SPARE')),
  constraint inventory_items_status_check check (status in ('ACTIVE', 'INACTIVE')),
  constraint inventory_items_uom_check    check (uom in ('NOS', 'SET', 'PAIR', 'LTR', 'KG', 'MTR', 'BOX')),
  constraint inventory_items_code_check   check (item_code ~ '^[A-Z0-9][A-Z0-9._/-]{1,29}$'),
  constraint inventory_items_price_check  check (standard_cost >= 0 and selling_price >= 0),
  constraint inventory_items_reorder_check check (reorder_level >= 0)
);

comment on table public.inventory_items is
  'Accessory and spare master (spec §28, §29). LOCAL/COMPANY separation lives on '
  'the stock lots, not here — the item is the same product whoever supplied it.';
comment on column public.inventory_items.is_fitment is
  'Can be fitted to a vehicle at sale, making it eligible for the mapping in 0020.';

create index inventory_items_dealer_type_idx on public.inventory_items (dealer_id, item_type, status);
create index inventory_items_name_idx        on public.inventory_items (dealer_id, lower(name));
create index inventory_items_hsn_idx         on public.inventory_items (hsn_code_id) where hsn_code_id is not null;
create index inventory_items_fitment_idx     on public.inventory_items (dealer_id) where is_fitment;

-- =============================================================================
-- finance_companies — spec §25, §60. Each keeps a SEPARATE ledger.
-- =============================================================================
create table public.finance_companies (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null references public.dealers (id) on delete cascade,

  code              text not null,
  name              text not null,
  contact_person    text,
  mobile            text,
  email             text,

  gstin             text,
  -- The subsidiary ledger account this company's balance rolls up into.
  ledger_account_id uuid,

  commission_percent numeric(6, 3) not null default 0,
  status            text not null default 'ACTIVE',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid,
  updated_by        uuid,

  constraint finance_companies_dealer_code_key unique (dealer_id, code),
  constraint finance_companies_id_dealer_key   unique (id, dealer_id),
  constraint finance_companies_account_tenant_fkey
    foreign key (ledger_account_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint finance_companies_status_check check (status in ('ACTIVE', 'INACTIVE')),
  constraint finance_companies_code_check   check (code ~ '^[A-Z0-9][A-Z0-9._-]{1,29}$'),
  constraint finance_companies_commission_check check (commission_percent between 0 and 100),
  constraint finance_companies_gstin_check check (
    gstin is null or gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[0-9A-Z]{1}Z[0-9A-Z]{1}$'
  ),
  constraint finance_companies_mobile_check check (mobile is null or mobile ~ '^[6-9][0-9]{9}$')
);

comment on table public.finance_companies is
  'Finance companies (spec §25). Balances are never combined into one generic '
  'figure — each company has its own ledger account and its own running balance.';

create index finance_companies_dealer_idx  on public.finance_companies (dealer_id, status);
create index finance_companies_account_idx on public.finance_companies (ledger_account_id)
  where ledger_account_id is not null;

create trigger inventory_items_set_updated_at before update on public.inventory_items
  for each row execute function app.set_updated_at();
create trigger finance_companies_set_updated_at before update on public.finance_companies
  for each row execute function app.set_updated_at();

create trigger inventory_items_audit after insert or update or delete on public.inventory_items
  for each row execute function app.audit_trigger();
create trigger finance_companies_audit after insert or update or delete on public.finance_companies
  for each row execute function app.audit_trigger();

alter table public.inventory_items    enable row level security;
alter table public.finance_companies  enable row level security;

create policy inventory_items_select on public.inventory_items for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('inventory.view')));
create policy inventory_items_write on public.inventory_items for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('inventory.items.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('inventory.items.manage')));

create policy finance_companies_select on public.finance_companies for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('finance.companies.view')));
create policy finance_companies_write on public.finance_companies for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('finance.companies.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('finance.companies.manage')));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update, delete on public.inventory_items, public.finance_companies to authenticated';
    execute 'grant all on public.inventory_items, public.finance_companies to service_role';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0017_vehicle_stock.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0017 — Vehicle stock: chassis-level inventory and transfers
-- =============================================================================
-- Spec §13, §35, §60.8. "Never represent vehicle inventory only as quantity.
-- Every physical vehicle must be individually traceable."
--
-- So there is no quantity column anywhere here. One row is one motorcycle, with
-- its own chassis number, its own purchase cost, and its own status. Stock counts
-- are derived by counting rows.
--
-- Concurrency (spec §49): two cashiers must not sell the same chassis. The status
-- transition is guarded by a trigger, and the sale path takes SELECT ... FOR
-- UPDATE on the row, so the second attempt blocks and then fails the check.
--
-- Rollback: drop table public.vehicle_transfers, public.vehicle_stock_transactions,
--           public.vehicles;
-- =============================================================================

create table public.vehicles (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null references public.dealers (id) on delete restrict,
  branch_id         uuid not null,

  model_id          uuid not null,
  variant_id        uuid,
  colour_id         uuid,

  -- The physical identity of the unit. Chassis is globally unique per dealer.
  chassis_no        text not null,
  engine_no         text not null,
  key_no            text,
  model_year        smallint,

  purchase_invoice  text,
  purchase_date     date,
  purchase_cost     numeric(18, 4) not null default 0,
  stock_date        date not null default current_date,

  status            text not null default 'IN_STOCK',

  -- Set once the vehicle leaves stock; lets a sale be traced from the unit.
  sale_id           uuid,
  registration_no   text,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid,
  updated_by        uuid,

  constraint vehicles_dealer_chassis_key unique (dealer_id, chassis_no),
  constraint vehicles_dealer_engine_key  unique (dealer_id, engine_no),
  constraint vehicles_id_dealer_key      unique (id, dealer_id),
  constraint vehicles_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint vehicles_model_tenant_fkey
    foreign key (model_id, dealer_id) references public.vehicle_models (id, dealer_id),
  constraint vehicles_variant_tenant_fkey
    foreign key (variant_id, dealer_id) references public.vehicle_variants (id, dealer_id),
  constraint vehicles_colour_tenant_fkey
    foreign key (colour_id, dealer_id) references public.vehicle_colours (id, dealer_id),

  constraint vehicles_status_check check (status in (
    'IN_STOCK', 'BOOKED', 'SOLD_PENDING_DELIVERY', 'DELIVERED', 'TRANSFERRED', 'CANCELLED'
  )),
  constraint vehicles_cost_check     check (purchase_cost >= 0),
  constraint vehicles_chassis_check  check (chassis_no ~ '^[A-Z0-9]{6,25}$'),
  constraint vehicles_engine_check   check (engine_no ~ '^[A-Z0-9]{6,25}$'),
  constraint vehicles_year_check     check (model_year is null or model_year between 1980 and 2100)
);

comment on table public.vehicles is
  'Chassis-level vehicle stock (spec §13, §60.8). One row is one physical vehicle. '
  'There is deliberately no quantity column.';

-- Registration numbers are unique once assigned.
create unique index vehicles_registration_key
  on public.vehicles (dealer_id, registration_no)
  where registration_no is not null;

create index vehicles_branch_status_idx on public.vehicles (branch_id, status);
create index vehicles_dealer_status_idx on public.vehicles (dealer_id, status);
create index vehicles_model_idx         on public.vehicles (model_id, status);
create index vehicles_variant_idx       on public.vehicles (variant_id) where variant_id is not null;
create index vehicles_colour_idx        on public.vehicles (colour_id) where colour_id is not null;
-- Stock ageing: how long has this unit been sitting (spec §41).
create index vehicles_ageing_idx        on public.vehicles (dealer_id, stock_date) where status = 'IN_STOCK';
create index vehicles_sale_idx          on public.vehicles (sale_id) where sale_id is not null;

-- -----------------------------------------------------------------------------
-- Status transitions
-- -----------------------------------------------------------------------------
-- A vehicle's life runs one way. Encoding the legal moves here means no service,
-- however buggy, can put a DELIVERED unit back into stock and sell it twice.
-- -----------------------------------------------------------------------------
create or replace function app.vehicles_guard_status()
returns trigger
language plpgsql
as $$
declare
  v_allowed text[];
begin
  if tg_op = 'INSERT' then
    if new.status <> 'IN_STOCK' then
      raise exception 'A vehicle enters stock as IN_STOCK, not %.', new.status
        using errcode = 'check_violation';
    end if;
    return new;
  end if;

  if new.status = old.status then
    return new;
  end if;

  v_allowed := case old.status
    when 'IN_STOCK'              then array['BOOKED', 'SOLD_PENDING_DELIVERY', 'TRANSFERRED', 'CANCELLED']
    when 'BOOKED'                then array['IN_STOCK', 'SOLD_PENDING_DELIVERY', 'CANCELLED']
    when 'SOLD_PENDING_DELIVERY' then array['DELIVERED', 'IN_STOCK', 'CANCELLED']
    when 'TRANSFERRED'           then array['IN_STOCK', 'CANCELLED']
    -- Terminal. A delivered vehicle is the customer's; a cancelled one is out.
    when 'DELIVERED'             then array[]::text[]
    when 'CANCELLED'             then array[]::text[]
    else array[]::text[]
  end;

  if not (new.status = any (v_allowed)) then
    raise exception 'Vehicle % cannot move from % to %.', old.chassis_no, old.status, new.status
      using errcode = 'check_violation',
            hint = 'Spec §13 defines the vehicle status lifecycle.';
  end if;

  return new;
end;
$$;

create trigger vehicles_guard_status
  before insert or update on public.vehicles
  for each row execute function app.vehicles_guard_status();

-- -----------------------------------------------------------------------------
-- vehicle_stock_transactions — immutable movement log (spec §34)
-- -----------------------------------------------------------------------------
create table public.vehicle_stock_transactions (
  id               bigint generated always as identity primary key,
  dealer_id        uuid not null,
  branch_id        uuid not null,
  vehicle_id       uuid not null,

  transaction_type text not null,
  reference_type   text,
  reference_id     uuid,

  from_status      text,
  to_status        text,
  from_branch_id   uuid,
  to_branch_id     uuid,

  value            numeric(18, 4) not null default 0,
  narration        text,

  created_at       timestamptz not null default now(),
  created_by       uuid,

  constraint vst_vehicle_tenant_fkey
    foreign key (vehicle_id, dealer_id) references public.vehicles (id, dealer_id) on delete cascade,
  constraint vst_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint vst_type_check check (transaction_type in (
    'OPENING', 'PURCHASE', 'SALE', 'RETURN',
    'TRANSFER_OUT', 'TRANSFER_IN', 'ADJUSTMENT', 'REVERSAL', 'STATUS_CHANGE'
  ))
);

comment on table public.vehicle_stock_transactions is
  'Append-only vehicle movement log (spec §34). Never updated, never deleted.';

create trigger vehicle_stock_transactions_append_only
  before update or delete on public.vehicle_stock_transactions
  for each row execute function app.forbid_mutation();

create index vst_vehicle_idx     on public.vehicle_stock_transactions (vehicle_id, created_at desc);
create index vst_dealer_time_idx on public.vehicle_stock_transactions (dealer_id, created_at desc);
create index vst_branch_time_idx on public.vehicle_stock_transactions (branch_id, created_at desc);
create index vst_reference_idx   on public.vehicle_stock_transactions (reference_type, reference_id)
  where reference_id is not null;

-- Every status change writes a movement row automatically, so the log cannot be
-- forgotten by a caller.
create or replace function app.vehicles_log_movement()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.vehicle_stock_transactions
      (dealer_id, branch_id, vehicle_id, transaction_type, to_status, to_branch_id, value, created_by)
    values (new.dealer_id, new.branch_id, new.id, 'PURCHASE', new.status, new.branch_id,
            new.purchase_cost, new.created_by);
    return null;
  end if;

  if new.status is distinct from old.status or new.branch_id is distinct from old.branch_id then
    insert into public.vehicle_stock_transactions
      (dealer_id, branch_id, vehicle_id, transaction_type,
       from_status, to_status, from_branch_id, to_branch_id, value, created_by)
    values (new.dealer_id, new.branch_id, new.id,
            case when new.branch_id is distinct from old.branch_id then 'TRANSFER_IN' else 'STATUS_CHANGE' end,
            old.status, new.status, old.branch_id, new.branch_id, new.purchase_cost, new.updated_by);
  end if;

  return null;
end;
$$;

create trigger vehicles_log_movement
  after insert or update on public.vehicles
  for each row execute function app.vehicles_log_movement();

-- -----------------------------------------------------------------------------
-- vehicle_transfers — branch to branch, with an in-transit state (spec §35)
-- -----------------------------------------------------------------------------
create table public.vehicle_transfers (
  id              uuid primary key default gen_random_uuid(),
  dealer_id       uuid not null references public.dealers (id) on delete restrict,

  transfer_number text not null,
  vehicle_id      uuid not null,
  from_branch_id  uuid not null,
  to_branch_id    uuid not null,

  status          text not null default 'IN_TRANSIT',
  dispatched_at   timestamptz not null default now(),
  dispatched_by   uuid,
  received_at     timestamptz,
  received_by     uuid,
  remarks         text,

  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint vehicle_transfers_number_key unique (dealer_id, transfer_number),
  constraint vehicle_transfers_id_dealer_key unique (id, dealer_id),
  constraint vehicle_transfers_vehicle_tenant_fkey
    foreign key (vehicle_id, dealer_id) references public.vehicles (id, dealer_id),
  constraint vehicle_transfers_from_tenant_fkey
    foreign key (from_branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint vehicle_transfers_to_tenant_fkey
    foreign key (to_branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint vehicle_transfers_status_check check (status in ('IN_TRANSIT', 'RECEIVED', 'CANCELLED')),
  constraint vehicle_transfers_branches_differ_check check (from_branch_id <> to_branch_id),
  constraint vehicle_transfers_received_check check (
    status <> 'RECEIVED' or received_at is not null
  )
);

create index vehicle_transfers_vehicle_idx on public.vehicle_transfers (vehicle_id);
create index vehicle_transfers_status_idx  on public.vehicle_transfers (dealer_id, status);
create index vehicle_transfers_to_idx      on public.vehicle_transfers (to_branch_id, status);

create trigger vehicles_set_updated_at before update on public.vehicles
  for each row execute function app.set_updated_at();
create trigger vehicle_transfers_set_updated_at before update on public.vehicle_transfers
  for each row execute function app.set_updated_at();

create trigger vehicles_audit after insert or update or delete on public.vehicles
  for each row execute function app.audit_trigger();
create trigger vehicle_transfers_audit after insert or update or delete on public.vehicle_transfers
  for each row execute function app.audit_trigger();

alter table public.vehicles                   enable row level security;
alter table public.vehicle_stock_transactions enable row level security;
alter table public.vehicle_transfers          enable row level security;

create policy vehicles_select on public.vehicles for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and app.can_access_branch(branch_id)
             and app.has_permission('vehicles.stock.view')));

create policy vehicles_insert on public.vehicles for insert to authenticated
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('vehicles.stock.upload')));

create policy vehicles_update on public.vehicles for update to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('vehicles.stock.adjust') or app.has_permission('sales.create'))))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('vehicles.stock.adjust') or app.has_permission('sales.create'))));

-- Movement history is read-only from a session; rows come from the trigger.
create policy vst_select on public.vehicle_stock_transactions for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('vehicles.stock.view')));

create policy vehicle_transfers_select on public.vehicle_transfers for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('vehicles.transfers.view')));
create policy vehicle_transfers_write on public.vehicle_transfers for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('vehicles.transfers.manage')))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('vehicles.transfers.manage')));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.vehicles to authenticated';
    execute 'grant select on public.vehicle_stock_transactions to authenticated';
    execute 'grant select, insert, update on public.vehicle_transfers to authenticated';
    execute 'grant all on public.vehicles, public.vehicle_stock_transactions, public.vehicle_transfers to service_role';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0018_vehicle_pricing.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0018 — Vehicle pricing: effective-dated versions
-- =============================================================================
-- Spec §15, §17, §42, §60.9, §60.10. The central rule: "Do NOT update one price
-- field and destroy history."
--
-- A price is therefore never edited in place. Each change creates a new version
-- with its own effective_from, and a sale records the version id it used. Asking
-- "what was the price on that date?" (spec §42) becomes a lookup, not a guess —
-- and it stays answerable even after ten more price changes.
--
-- Rollback: drop table public.vehicle_price_versions;
-- =============================================================================

create table public.vehicle_price_versions (
  id                    uuid primary key default gen_random_uuid(),
  dealer_id             uuid not null references public.dealers (id) on delete cascade,

  model_id              uuid not null,
  variant_id            uuid,
  -- NULL means the price applies dealer-wide; a branch may override.
  branch_id             uuid,

  version_number        integer not null,

  -- Components, spec §15. Held separately because the invoice itemises them and
  -- because each maps to a different ledger account at posting.
  ex_showroom           numeric(18, 4) not null default 0,
  insurance             numeric(18, 4) not null default 0,
  registration          numeric(18, 4) not null default 0,  -- LTRT
  mandatory_accessories numeric(18, 4) not null default 0,
  forwarding_charge     numeric(18, 4) not null default 0,
  other_charges         numeric(18, 4) not null default 0,

  -- What the dealer paid. Restricted: only roles with vehicles.view_cost see it.
  purchase_cost         numeric(18, 4) not null default 0,

  max_discount          numeric(18, 4) not null default 0,
  tax_code              text,

  total_on_road         numeric(18, 4) generated always as (
    ex_showroom + insurance + registration + mandatory_accessories
    + forwarding_charge + other_charges
  ) stored,

  effective_from        date not null,
  effective_to          date,

  -- Spec §15 offers an optional approval flow; it is implemented.
  status                text not null default 'DRAFT',
  submitted_at          timestamptz,
  submitted_by          uuid,
  approved_at           timestamptz,
  approved_by           uuid,

  notes                 text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  created_by            uuid,
  updated_by            uuid,

  constraint vpv_id_dealer_key unique (id, dealer_id),
  constraint vpv_model_tenant_fkey
    foreign key (model_id, dealer_id) references public.vehicle_models (id, dealer_id) on delete cascade,
  constraint vpv_variant_tenant_fkey
    foreign key (variant_id, dealer_id) references public.vehicle_variants (id, dealer_id) on delete cascade,
  constraint vpv_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),

  constraint vpv_status_check check (status in ('DRAFT', 'SUBMITTED', 'APPROVED', 'ACTIVE', 'SUPERSEDED', 'REJECTED')),
  constraint vpv_amounts_check check (
    ex_showroom >= 0 and insurance >= 0 and registration >= 0
    and mandatory_accessories >= 0 and forwarding_charge >= 0 and other_charges >= 0
    and purchase_cost >= 0 and max_discount >= 0
  ),
  constraint vpv_dates_check   check (effective_to is null or effective_to >= effective_from),
  constraint vpv_version_check check (version_number > 0),
  constraint vpv_approved_check check (status not in ('APPROVED', 'ACTIVE') or approved_at is not null)
);

comment on table public.vehicle_price_versions is
  'Effective-dated vehicle prices (spec §15). Never updated in place: a change is '
  'a new version, and a sale records the version it used (spec §42, §60.9).';
comment on column public.vehicle_price_versions.purchase_cost is
  'Restricted. Withheld from roles lacking vehicles.view_cost (spec §52).';

-- One live price per scope. The partial unique index is what makes "the current
-- price" a single unambiguous row rather than a judgement call.
create unique index vpv_active_scope_key
  on public.vehicle_price_versions (dealer_id, model_id, coalesce(variant_id, '00000000-0000-0000-0000-000000000000'::uuid), coalesce(branch_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where status = 'ACTIVE';

create unique index vpv_version_key
  on public.vehicle_price_versions (dealer_id, model_id, coalesce(variant_id, '00000000-0000-0000-0000-000000000000'::uuid), coalesce(branch_id, '00000000-0000-0000-0000-000000000000'::uuid), version_number);

create index vpv_lookup_idx on public.vehicle_price_versions (dealer_id, model_id, effective_from desc);
create index vpv_variant_idx on public.vehicle_price_versions (variant_id) where variant_id is not null;
create index vpv_status_idx  on public.vehicle_price_versions (dealer_id, status);

-- -----------------------------------------------------------------------------
-- Immutability once ACTIVE
-- -----------------------------------------------------------------------------
-- An ACTIVE version has been used to price real invoices. Editing it would
-- rewrite what those invoices claim to have charged, which spec §60.10 forbids.
-- -----------------------------------------------------------------------------
create or replace function app.vpv_guard()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    if old.status in ('ACTIVE', 'SUPERSEDED') then
      raise exception 'Price version % is % and cannot be deleted.', old.version_number, old.status
        using errcode = 'insufficient_privilege',
              hint = 'Spec §60.9: price history is immutable. Supersede it with a new version.';
    end if;
    return old;
  end if;

  if tg_op = 'UPDATE' and old.status in ('ACTIVE', 'SUPERSEDED') then
    -- Only the lifecycle columns may move: an active version becomes superseded
    -- when a newer one takes over, and nothing else about it may change.
    --
    -- The immutable columns are listed explicitly rather than compared with
    -- `to_jsonb(new) - 'status' - ...`. A BEFORE trigger does not see generated
    -- columns populated in NEW, so `total_on_road` would always read as changed
    -- and every update would be rejected.
    if new.ex_showroom           is distinct from old.ex_showroom
    or new.insurance             is distinct from old.insurance
    or new.registration          is distinct from old.registration
    or new.mandatory_accessories is distinct from old.mandatory_accessories
    or new.forwarding_charge     is distinct from old.forwarding_charge
    or new.other_charges         is distinct from old.other_charges
    or new.purchase_cost         is distinct from old.purchase_cost
    or new.max_discount          is distinct from old.max_discount
    or new.tax_code              is distinct from old.tax_code
    or new.effective_from        is distinct from old.effective_from
    or new.model_id              is distinct from old.model_id
    or new.variant_id            is distinct from old.variant_id
    or new.branch_id             is distinct from old.branch_id
    or new.version_number        is distinct from old.version_number then
      raise exception 'Price version % is % and its amounts are immutable.', old.version_number, old.status
        using errcode = 'insufficient_privilege',
              hint = 'Create a new version instead of editing this one (spec §15).';
    end if;
  end if;

  return new;
end;
$$;

create trigger vpv_guard
  before update or delete on public.vehicle_price_versions
  for each row execute function app.vpv_guard();

-- -----------------------------------------------------------------------------
-- public.resolve_vehicle_price() — the price in force on a date
-- -----------------------------------------------------------------------------
-- Resolution order is most-specific-first: a branch+variant price beats a
-- dealer-wide model price. Sales call this and store the returned id, so the
-- invoice remains explainable years later.
-- -----------------------------------------------------------------------------
create or replace function public.resolve_vehicle_price(
  p_dealer_id  uuid,
  p_model_id   uuid,
  p_variant_id uuid default null,
  p_branch_id  uuid default null,
  p_on_date    date default current_date
)
returns table (
  price_version_id      uuid,
  version_number        integer,
  ex_showroom           numeric(18, 4),
  insurance             numeric(18, 4),
  registration          numeric(18, 4),
  mandatory_accessories numeric(18, 4),
  forwarding_charge     numeric(18, 4),
  other_charges         numeric(18, 4),
  total_on_road         numeric(18, 4),
  max_discount          numeric(18, 4),
  tax_code              text
)
language sql
stable
as $$
  select v.id, v.version_number, v.ex_showroom, v.insurance, v.registration,
         v.mandatory_accessories, v.forwarding_charge, v.other_charges,
         v.total_on_road, v.max_discount, v.tax_code
    from public.vehicle_price_versions v
   where v.dealer_id = p_dealer_id
     and v.model_id = p_model_id
     and v.status in ('ACTIVE', 'SUPERSEDED')
     and v.effective_from <= p_on_date
     and (v.effective_to is null or v.effective_to >= p_on_date)
     and (v.variant_id is null or v.variant_id = p_variant_id)
     and (v.branch_id  is null or v.branch_id  = p_branch_id)
   order by
     -- Most specific scope wins, then the most recent effective date.
     (v.branch_id  is not null) desc,
     (v.variant_id is not null) desc,
     v.effective_from desc,
     v.version_number desc
   limit 1;
$$;

comment on function public.resolve_vehicle_price(uuid, uuid, uuid, uuid, date) is
  'The price in force for a model/variant/branch on a date (spec §15, §42). '
  'Historical invoices resolve their original price through this, never through '
  'the current master.';

create trigger vpv_set_updated_at before update on public.vehicle_price_versions
  for each row execute function app.set_updated_at();

-- Price changes are explicitly audited (spec §46).
create trigger vpv_audit after insert or update or delete on public.vehicle_price_versions
  for each row execute function app.audit_trigger();

alter table public.vehicle_price_versions enable row level security;

create policy vpv_select on public.vehicle_price_versions for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('vehicles.pricing.view')));

create policy vpv_insert on public.vehicle_price_versions for insert to authenticated
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('vehicles.pricing.manage')));

create policy vpv_update on public.vehicle_price_versions for update to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('vehicles.pricing.manage') or app.has_permission('vehicles.pricing.approve'))))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('vehicles.pricing.manage') or app.has_permission('vehicles.pricing.approve'))));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.vehicle_price_versions to authenticated';
    execute 'grant all on public.vehicle_price_versions to service_role';
    execute 'grant execute on function public.resolve_vehicle_price(uuid, uuid, uuid, uuid, date) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0019_inventory_stock.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0019 — Accessory and spare stock: lots, ledger, fitment mapping
-- =============================================================================
-- Spec §28, §29, §30, §31, §34, §60.16, §60.17, §60.22.
--
-- The rule that shapes this file: LOCAL and COMPANY stock must stay separately
-- traceable and must never be merged. So the stock row is keyed by
-- (item, branch, source) — three lots of the same item at the same branch cannot
-- exist, but a LOCAL lot and a COMPANY lot can, and they hold their own
-- quantities and their own costs.
--
-- Quantity is maintained by trigger from the ledger, never written directly
-- (spec §34, §60.22: "No silent stock adjustments"). Every movement leaves a row.
--
-- Rollback: drop table public.accessory_vehicle_mappings, public.inventory_transactions,
--           public.inventory_stock;
-- =============================================================================

create table public.inventory_stock (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null references public.dealers (id) on delete cascade,
  branch_id      uuid not null,
  item_id        uuid not null,

  -- The separation spec §60.16 requires. Part of the key, not an attribute.
  source         text not null,

  quantity       numeric(14, 3) not null default 0,
  -- Weighted average cost for this lot. Recomputed on receipt, held on issue.
  average_cost   numeric(18, 4) not null default 0,
  stock_value    numeric(18, 4) generated always as (quantity * average_cost) stored,

  updated_at     timestamptz not null default now(),

  constraint inventory_stock_lot_key unique (item_id, branch_id, source),
  constraint inventory_stock_id_dealer_key unique (id, dealer_id),
  constraint inventory_stock_item_tenant_fkey
    foreign key (item_id, dealer_id) references public.inventory_items (id, dealer_id) on delete cascade,
  constraint inventory_stock_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint inventory_stock_source_check check (source in ('LOCAL', 'COMPANY')),
  constraint inventory_stock_cost_check   check (average_cost >= 0)
);

comment on table public.inventory_stock is
  'One row per item / branch / source lot (spec §28, §60.16). LOCAL and COMPANY '
  'are never merged. Quantity is maintained by trigger from inventory_transactions.';

create index inventory_stock_branch_idx on public.inventory_stock (branch_id, item_id);
create index inventory_stock_item_idx   on public.inventory_stock (item_id);
create index inventory_stock_dealer_idx on public.inventory_stock (dealer_id);
create index inventory_stock_onhand_idx on public.inventory_stock (dealer_id, branch_id) where quantity > 0;

-- =============================================================================
-- inventory_transactions — the immutable stock ledger (spec §34)
-- =============================================================================
create table public.inventory_transactions (
  id               bigint generated always as identity primary key,
  dealer_id        uuid not null,
  branch_id        uuid not null,
  item_id          uuid not null,
  source           text not null,

  transaction_type text not null,

  -- Signed: positive receives, negative issues. One column rather than separate
  -- in/out columns, so the running balance is a plain sum.
  quantity         numeric(14, 3) not null,
  unit_cost        numeric(18, 4) not null default 0,
  value            numeric(18, 4) generated always as (quantity * unit_cost) stored,

  -- Balance after this movement, for a ledger view that needs no window function.
  balance_after    numeric(14, 3) not null default 0,

  reference_type   text,
  reference_id     uuid,
  reference_number text,
  narration        text,
  reason           text,

  created_at       timestamptz not null default now(),
  created_by       uuid,

  constraint inventory_transactions_item_tenant_fkey
    foreign key (item_id, dealer_id) references public.inventory_items (id, dealer_id) on delete cascade,
  constraint inventory_transactions_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint inventory_transactions_source_check check (source in ('LOCAL', 'COMPANY')),
  constraint inventory_transactions_type_check check (transaction_type in (
    'OPENING', 'PURCHASE', 'SALE', 'CONSUMPTION', 'RETURN',
    'TRANSFER_OUT', 'TRANSFER_IN', 'ADJUSTMENT', 'REVERSAL'
  )),
  constraint inventory_transactions_quantity_check check (quantity <> 0),
  constraint inventory_transactions_cost_check check (unit_cost >= 0),
  -- An adjustment must say why (spec §60.22).
  constraint inventory_transactions_adjustment_reason_check check (
    transaction_type <> 'ADJUSTMENT' or reason is not null
  )
);

comment on table public.inventory_transactions is
  'Append-only stock ledger (spec §34). Current stock is derived from these rows; '
  'quantities are never overwritten directly.';

create trigger inventory_transactions_append_only
  before update or delete on public.inventory_transactions
  for each row execute function app.forbid_mutation();

create index it_item_time_idx    on public.inventory_transactions (item_id, created_at desc);
create index it_branch_time_idx  on public.inventory_transactions (branch_id, created_at desc);
create index it_dealer_time_idx  on public.inventory_transactions (dealer_id, created_at desc);
create index it_reference_idx    on public.inventory_transactions (reference_type, reference_id)
  where reference_id is not null;
create index it_lot_idx          on public.inventory_transactions (item_id, branch_id, source, created_at desc);

-- -----------------------------------------------------------------------------
-- The ledger drives the stock row, not the other way round
-- -----------------------------------------------------------------------------
-- BEFORE INSERT so balance_after is computed under the same row lock that updates
-- the lot. Two concurrent issues of the same item serialise here, which is what
-- stops a race from overselling (spec §49).
-- -----------------------------------------------------------------------------
create or replace function app.inventory_apply_movement()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_stock      public.inventory_stock;
  v_new_qty    numeric(14, 3);
  v_new_cost   numeric(18, 4);
  v_allow_neg  boolean;
begin
  -- Lock the lot for the rest of this transaction, creating it if absent.
  insert into public.inventory_stock (dealer_id, branch_id, item_id, source, quantity, average_cost)
  values (new.dealer_id, new.branch_id, new.item_id, new.source, 0, 0)
  on conflict on constraint inventory_stock_lot_key do nothing;

  select * into v_stock
    from public.inventory_stock
   where item_id = new.item_id and branch_id = new.branch_id and source = new.source
     for update;

  v_new_qty := v_stock.quantity + new.quantity;

  if v_new_qty < 0 then
    select coalesce((value)::text = 'true', false) into v_allow_neg
      from public.system_settings
     where key = 'inventory.allow_negative_stock'
       and (dealer_id = new.dealer_id or dealer_id is null)
     order by dealer_id nulls last
     limit 1;

    if not coalesce(v_allow_neg, false) then
      raise exception
        'Insufficient % stock: % available, % requested.',
        new.source, v_stock.quantity, abs(new.quantity)
        using errcode = 'check_violation',
              hint = 'Spec §33: stock cannot go negative unless explicitly configured.';
    end if;
  end if;

  -- Weighted average, recomputed only on receipt. An issue leaves cost alone, so
  -- COGS uses the cost the stock was actually carried at.
  if new.quantity > 0 and new.unit_cost > 0 then
    v_new_cost := case
      when v_new_qty = 0 then v_stock.average_cost
      else round(((v_stock.quantity * v_stock.average_cost) + (new.quantity * new.unit_cost)) / v_new_qty, 4)
    end;
  else
    v_new_cost := v_stock.average_cost;
    if new.quantity < 0 and new.unit_cost = 0 then
      new.unit_cost := v_stock.average_cost;   -- issue at carrying cost
    end if;
  end if;

  update public.inventory_stock
     set quantity = v_new_qty,
         average_cost = v_new_cost,
         updated_at = now()
   where id = v_stock.id;

  new.balance_after := v_new_qty;
  return new;
end;
$$;

create trigger inventory_apply_movement
  before insert on public.inventory_transactions
  for each row execute function app.inventory_apply_movement();

-- =============================================================================
-- accessory_vehicle_mappings — fitment templates (spec §30)
-- =============================================================================
create table public.accessory_vehicle_mappings (
  id          uuid primary key default gen_random_uuid(),
  dealer_id   uuid not null references public.dealers (id) on delete cascade,

  model_id    uuid not null,
  variant_id  uuid,
  item_id     uuid not null,

  quantity    numeric(14, 3) not null default 1,
  -- Whether the fitting is offered by default when "extra fittings?" is answered yes.
  is_default  boolean not null default true,
  priority    smallint not null default 100,

  status      text not null default 'ACTIVE',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint avm_scope_key unique nulls not distinct (model_id, variant_id, item_id),
  constraint avm_model_tenant_fkey
    foreign key (model_id, dealer_id) references public.vehicle_models (id, dealer_id) on delete cascade,
  constraint avm_variant_tenant_fkey
    foreign key (variant_id, dealer_id) references public.vehicle_variants (id, dealer_id) on delete cascade,
  constraint avm_item_tenant_fkey
    foreign key (item_id, dealer_id) references public.inventory_items (id, dealer_id) on delete cascade,
  constraint avm_quantity_check check (quantity > 0),
  constraint avm_status_check   check (status in ('ACTIVE', 'INACTIVE'))
);

comment on table public.accessory_vehicle_mappings is
  'Which accessories are fitted to which model (spec §30). Drives the automatic '
  'fitting allocation at sale, which must remain auditable (spec §60.17).';

create index avm_model_idx on public.accessory_vehicle_mappings (model_id, status);
create index avm_item_idx  on public.accessory_vehicle_mappings (item_id);

-- -----------------------------------------------------------------------------
-- public.allocate_stock() — LOCAL before COMPANY (spec §31)
-- -----------------------------------------------------------------------------
-- Returns the split without consuming anything, so a sale screen can show the
-- customer exactly where the stock is coming from before committing. The actual
-- consumption inserts one ledger row per source, which is what makes the
-- allocation auditable rather than hidden (spec §31, "Never hide the source").
-- -----------------------------------------------------------------------------
create or replace function public.allocate_stock(
  p_item_id   uuid,
  p_branch_id uuid,
  p_quantity  numeric
)
returns table (source text, quantity numeric, unit_cost numeric, available numeric)
language plpgsql
stable
as $$
declare
  v_needed numeric := p_quantity;
  v_local  numeric := 0;
  v_lcost  numeric := 0;
  v_comp   numeric := 0;
  v_ccost  numeric := 0;
  v_take   numeric;
begin
  select coalesce(s.quantity, 0), coalesce(s.average_cost, 0) into v_local, v_lcost
    from public.inventory_stock s
   where s.item_id = p_item_id and s.branch_id = p_branch_id and s.source = 'LOCAL';

  select coalesce(s.quantity, 0), coalesce(s.average_cost, 0) into v_comp, v_ccost
    from public.inventory_stock s
   where s.item_id = p_item_id and s.branch_id = p_branch_id and s.source = 'COMPANY';

  v_local := coalesce(v_local, 0);
  v_comp  := coalesce(v_comp, 0);

  -- Rule 1: consume LOCAL first.
  if v_needed > 0 and v_local > 0 then
    v_take := least(v_needed, v_local);
    source := 'LOCAL'; quantity := v_take; unit_cost := v_lcost; available := v_local;
    return next;
    v_needed := v_needed - v_take;
  end if;

  -- Rule 2: fall through to COMPANY for the remainder.
  if v_needed > 0 and v_comp > 0 then
    v_take := least(v_needed, v_comp);
    source := 'COMPANY'; quantity := v_take; unit_cost := v_ccost; available := v_comp;
    return next;
    v_needed := v_needed - v_take;
  end if;

  -- Rule 3: report the shortfall rather than silently under-allocating.
  if v_needed > 0 then
    source := 'SHORTFALL'; quantity := v_needed; unit_cost := 0; available := v_local + v_comp;
    return next;
  end if;
end;
$$;

comment on function public.allocate_stock(uuid, uuid, numeric) is
  'Splits a required quantity across LOCAL then COMPANY stock (spec §31). Returns '
  'a SHORTFALL row when stock is insufficient rather than partially allocating.';

create trigger inventory_stock_set_updated_at before update on public.inventory_stock
  for each row execute function app.set_updated_at();
create trigger avm_set_updated_at before update on public.accessory_vehicle_mappings
  for each row execute function app.set_updated_at();
create trigger avm_audit after insert or update or delete on public.accessory_vehicle_mappings
  for each row execute function app.audit_trigger();

alter table public.inventory_stock             enable row level security;
alter table public.inventory_transactions      enable row level security;
alter table public.accessory_vehicle_mappings  enable row level security;

create policy inventory_stock_select on public.inventory_stock for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and app.can_access_branch(branch_id)
             and app.has_permission('inventory.view')));

create policy inventory_transactions_select on public.inventory_transactions for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and app.can_access_branch(branch_id)
             and app.has_permission('inventory.ledger.view')));

create policy inventory_transactions_insert on public.inventory_transactions for insert to authenticated
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('inventory.stock.upload')
                  or app.has_permission('inventory.stock.adjust')
                  or app.has_permission('inventory.stock.transfer')
                  or app.has_permission('inventory.counter_sale.create')
                  or app.has_permission('sales.create')
                  or app.has_permission('service.billing.create'))));

create policy avm_select on public.accessory_vehicle_mappings for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('inventory.view')));
create policy avm_write on public.accessory_vehicle_mappings for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('inventory.items.manage')))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('inventory.items.manage')));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select on public.inventory_stock to authenticated';
    execute 'grant select, insert on public.inventory_transactions to authenticated';
    execute 'grant select, insert, update, delete on public.accessory_vehicle_mappings to authenticated';
    execute 'grant all on public.inventory_stock, public.inventory_transactions, public.accessory_vehicle_mappings to service_role';
    execute 'grant execute on function public.allocate_stock(uuid, uuid, numeric) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0020_bookings_and_sales.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0020 — Bookings, vehicle sales, deliveries
-- =============================================================================
-- Spec §18, §19, §20, §48, §50.
--
-- The sale workflow is DRAFT → SUBMITTED → ACCOUNTS_VERIFICATION → APPROVED →
-- POSTED → DELIVERED (spec §19), and financial posting happens only after
-- approval. The transition guard below encodes that; no service can skip a step.
--
-- Every sale line stores its own tax breakdown (spec §20) rather than deriving it
-- at read time, because the rate that applied on the invoice date must survive
-- later changes to the tax master (spec §16).
--
-- Rollback: drop table public.deliveries, public.sale_payments, public.sale_lines,
--           public.sales, public.booking_payments, public.bookings;
-- =============================================================================

-- =============================================================================
-- bookings — spec §18
-- =============================================================================
create table public.bookings (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null references public.dealers (id) on delete restrict,
  branch_id         uuid not null,

  booking_number    text not null,
  booking_date      date not null default current_date,

  customer_id       uuid not null,
  model_id          uuid not null,
  variant_id        uuid,
  colour_id         uuid,
  -- Optional: a booking may be against a model, or reserve a specific chassis.
  vehicle_id        uuid,

  expected_delivery date,
  booking_amount    numeric(18, 4) not null default 0,
  received_amount   numeric(18, 4) not null default 0,

  sales_executive_id uuid,
  status            text not null default 'OPEN',

  -- Set when the booking becomes a sale.
  converted_sale_id uuid,
  cancelled_reason  text,
  notes             text,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid,
  updated_by        uuid,

  constraint bookings_number_key    unique (dealer_id, booking_number),
  constraint bookings_id_dealer_key unique (id, dealer_id),
  constraint bookings_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint bookings_customer_tenant_fkey
    foreign key (customer_id, dealer_id) references public.customers (id, dealer_id),
  constraint bookings_model_tenant_fkey
    foreign key (model_id, dealer_id) references public.vehicle_models (id, dealer_id),
  constraint bookings_variant_tenant_fkey
    foreign key (variant_id, dealer_id) references public.vehicle_variants (id, dealer_id),
  constraint bookings_vehicle_tenant_fkey
    foreign key (vehicle_id, dealer_id) references public.vehicles (id, dealer_id),
  constraint bookings_employee_tenant_fkey
    foreign key (sales_executive_id, dealer_id) references public.employees (id, dealer_id),
  constraint bookings_status_check check (status in ('OPEN', 'CONVERTED', 'CANCELLED', 'EXPIRED')),
  constraint bookings_amount_check check (booking_amount >= 0 and received_amount >= 0),
  constraint bookings_cancel_reason_check check (status <> 'CANCELLED' or cancelled_reason is not null)
);

comment on table public.bookings is
  'Vehicle bookings (spec §18). The advance posts to Customer Advances, not to '
  'revenue, unless accounting policy says otherwise.';

create index bookings_customer_idx  on public.bookings (customer_id, booking_date desc);
create index bookings_branch_idx    on public.bookings (branch_id, status);
create index bookings_dealer_date_idx on public.bookings (dealer_id, booking_date desc);
create index bookings_vehicle_idx   on public.bookings (vehicle_id) where vehicle_id is not null;
create index bookings_open_idx      on public.bookings (dealer_id) where status = 'OPEN';

create table public.booking_payments (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null,
  booking_id     uuid not null,

  receipt_number text not null,
  payment_date   date not null default current_date,
  amount         numeric(18, 4) not null,
  payment_mode   text not null,
  reference      text,

  journal_entry_id uuid,
  status         text not null default 'RECEIVED',

  created_at     timestamptz not null default now(),
  created_by     uuid,

  constraint booking_payments_receipt_key unique (dealer_id, receipt_number),
  constraint booking_payments_booking_tenant_fkey
    foreign key (booking_id, dealer_id) references public.bookings (id, dealer_id) on delete cascade,
  constraint booking_payments_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint booking_payments_amount_check check (amount > 0),
  constraint booking_payments_mode_check check (payment_mode in (
    'CASH', 'CARD', 'UPI', 'NEFT', 'RTGS', 'IMPS', 'CHEQUE', 'DD', 'FINANCE'
  )),
  constraint booking_payments_status_check check (status in ('RECEIVED', 'REVERSED'))
);

create index booking_payments_booking_idx on public.booking_payments (booking_id);
create index booking_payments_date_idx    on public.booking_payments (dealer_id, payment_date desc);

-- Keep the booking's received total in step with its receipts.
create or replace function app.bookings_sync_received()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_booking uuid := coalesce(new.booking_id, old.booking_id);
begin
  update public.bookings b
     set received_amount = coalesce((
           select sum(p.amount) from public.booking_payments p
            where p.booking_id = v_booking and p.status = 'RECEIVED'
         ), 0)
   where b.id = v_booking;
  return null;
end;
$$;

create trigger booking_payments_sync
  after insert or update or delete on public.booking_payments
  for each row execute function app.bookings_sync_received();

-- =============================================================================
-- sales — spec §19, §20
-- =============================================================================
create table public.sales (
  id                 uuid primary key default gen_random_uuid(),
  dealer_id          uuid not null references public.dealers (id) on delete restrict,
  branch_id          uuid not null,

  invoice_number     text not null,
  invoice_date       date not null default current_date,

  customer_id        uuid not null,
  vehicle_id         uuid not null,
  booking_id         uuid,

  -- The exact price version used, so the invoice stays explainable (spec §42).
  price_version_id   uuid,

  sales_executive_id uuid,

  -- Totals, maintained by trigger from the lines.
  taxable_value      numeric(18, 4) not null default 0,
  cgst_amount        numeric(18, 4) not null default 0,
  sgst_amount        numeric(18, 4) not null default 0,
  igst_amount        numeric(18, 4) not null default 0,
  cess_amount        numeric(18, 4) not null default 0,
  discount_amount    numeric(18, 4) not null default 0,
  total_amount       numeric(18, 4) not null default 0,

  -- Cost side. Restricted from roles without sales.view_cost (spec §52).
  total_cost         numeric(18, 4) not null default 0,

  paid_amount        numeric(18, 4) not null default 0,
  finance_amount     numeric(18, 4) not null default 0,
  balance_amount     numeric(18, 4) generated always as (
    total_amount - paid_amount - finance_amount
  ) stored,

  status             text not null default 'DRAFT',

  submitted_at       timestamptz, submitted_by uuid,
  verified_at        timestamptz, verified_by  uuid,
  approved_at        timestamptz, approved_by  uuid,
  posted_at          timestamptz, posted_by    uuid,
  delivered_at       timestamptz, delivered_by uuid,
  cancelled_at       timestamptz, cancelled_by uuid,
  cancelled_reason   text,
  rejection_reason   text,

  journal_entry_id   uuid,
  -- Duplicate-submission protection (spec §50).
  idempotency_key    text,
  notes              text,

  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  created_by         uuid,
  updated_by         uuid,

  constraint sales_invoice_key   unique (dealer_id, invoice_number),
  constraint sales_id_dealer_key unique (id, dealer_id),
  constraint sales_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint sales_customer_tenant_fkey
    foreign key (customer_id, dealer_id) references public.customers (id, dealer_id),
  constraint sales_vehicle_tenant_fkey
    foreign key (vehicle_id, dealer_id) references public.vehicles (id, dealer_id),
  constraint sales_booking_tenant_fkey
    foreign key (booking_id, dealer_id) references public.bookings (id, dealer_id),
  constraint sales_price_version_tenant_fkey
    foreign key (price_version_id, dealer_id) references public.vehicle_price_versions (id, dealer_id),
  constraint sales_employee_tenant_fkey
    foreign key (sales_executive_id, dealer_id) references public.employees (id, dealer_id),
  constraint sales_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),

  constraint sales_status_check check (status in (
    'DRAFT', 'SUBMITTED', 'ACCOUNTS_VERIFICATION', 'APPROVED', 'POSTED', 'DELIVERED', 'CANCELLED', 'RETURNED'
  )),
  constraint sales_amounts_check check (
    taxable_value >= 0 and cgst_amount >= 0 and sgst_amount >= 0 and igst_amount >= 0
    and cess_amount >= 0 and discount_amount >= 0 and total_amount >= 0
    and paid_amount >= 0 and finance_amount >= 0 and total_cost >= 0
  ),
  -- Intra-state and inter-state are mutually exclusive on one invoice.
  constraint sales_gst_mode_check check (
    (igst_amount = 0) or (cgst_amount = 0 and sgst_amount = 0)
  ),
  constraint sales_posted_journal_check check (status not in ('POSTED', 'DELIVERED') or journal_entry_id is not null),
  constraint sales_cancel_reason_check check (status <> 'CANCELLED' or cancelled_reason is not null)
);

comment on table public.sales is
  'Vehicle sale invoice (spec §19, §20). Financial posting happens at APPROVED → '
  'POSTED, never before (spec §19).';
comment on column public.sales.total_cost is
  'Restricted. Withheld from roles lacking sales.view_cost (spec §52).';

create unique index sales_idempotency_key
  on public.sales (dealer_id, idempotency_key) where idempotency_key is not null;

-- One live sale per vehicle: a chassis cannot be on two open invoices (spec §49).
create unique index sales_vehicle_active_key
  on public.sales (vehicle_id)
  where status not in ('CANCELLED', 'RETURNED');

create index sales_customer_idx    on public.sales (customer_id, invoice_date desc);
create index sales_branch_date_idx on public.sales (branch_id, invoice_date desc);
create index sales_dealer_date_idx on public.sales (dealer_id, invoice_date desc);
create index sales_status_idx      on public.sales (dealer_id, status);
create index sales_booking_idx     on public.sales (booking_id) where booking_id is not null;
create index sales_executive_idx   on public.sales (sales_executive_id) where sales_executive_id is not null;

-- -----------------------------------------------------------------------------
-- sale_lines — spec §20, every component itemised with its own tax
-- -----------------------------------------------------------------------------
create table public.sale_lines (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null,
  sale_id        uuid not null,

  line_number    smallint not null,
  line_type      text not null,

  description    text not null,
  item_id        uuid,
  hsn_code       text,

  quantity       numeric(14, 3) not null default 1,
  unit_rate      numeric(18, 4) not null default 0,
  discount       numeric(18, 4) not null default 0,
  taxable_value  numeric(18, 4) not null default 0,

  tax_code       text,
  cgst_rate      numeric(6, 3) not null default 0,
  sgst_rate      numeric(6, 3) not null default 0,
  igst_rate      numeric(6, 3) not null default 0,
  cgst_amount    numeric(18, 4) not null default 0,
  sgst_amount    numeric(18, 4) not null default 0,
  igst_amount    numeric(18, 4) not null default 0,
  cess_amount    numeric(18, 4) not null default 0,

  total_amount   numeric(18, 4) not null default 0,

  -- Cost and allocation source, for margin and for the audit of spec §31.
  unit_cost      numeric(18, 4) not null default 0,
  cost_amount    numeric(18, 4) not null default 0,
  stock_source   text,

  created_at     timestamptz not null default now(),

  constraint sale_lines_line_key unique (sale_id, line_number),
  constraint sale_lines_sale_tenant_fkey
    foreign key (sale_id, dealer_id) references public.sales (id, dealer_id) on delete cascade,
  constraint sale_lines_item_tenant_fkey
    foreign key (item_id, dealer_id) references public.inventory_items (id, dealer_id),
  constraint sale_lines_type_check check (line_type in (
    'VEHICLE', 'INSURANCE', 'REGISTRATION', 'ACCESSORY', 'FITTING',
    'FORWARDING', 'OTHER_CHARGE', 'DISCOUNT', 'SPARE', 'LABOUR'
  )),
  constraint sale_lines_source_check check (stock_source is null or stock_source in ('LOCAL', 'COMPANY')),
  constraint sale_lines_amounts_check check (
    quantity > 0 and unit_rate >= 0 and discount >= 0 and taxable_value >= 0
    and cgst_amount >= 0 and sgst_amount >= 0 and igst_amount >= 0 and total_amount >= 0
  )
);

comment on table public.sale_lines is
  'Invoice lines (spec §20). stock_source records whether a fitting came from '
  'LOCAL or COMPANY stock, so the allocation is visible on the invoice (spec §31).';

create index sale_lines_sale_idx on public.sale_lines (sale_id, line_number);
create index sale_lines_item_idx on public.sale_lines (item_id) where item_id is not null;

create table public.sale_payments (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null,
  sale_id          uuid not null,

  receipt_number   text not null,
  payment_date     date not null default current_date,
  amount           numeric(18, 4) not null,
  payment_mode     text not null,
  reference        text,

  finance_company_id uuid,
  journal_entry_id uuid,
  status           text not null default 'RECEIVED',

  created_at       timestamptz not null default now(),
  created_by       uuid,

  constraint sale_payments_receipt_key unique (dealer_id, receipt_number),
  constraint sale_payments_sale_tenant_fkey
    foreign key (sale_id, dealer_id) references public.sales (id, dealer_id) on delete cascade,
  constraint sale_payments_finance_tenant_fkey
    foreign key (finance_company_id, dealer_id) references public.finance_companies (id, dealer_id),
  constraint sale_payments_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint sale_payments_amount_check check (amount > 0),
  constraint sale_payments_mode_check check (payment_mode in (
    'CASH', 'CARD', 'UPI', 'NEFT', 'RTGS', 'IMPS', 'CHEQUE', 'DD', 'FINANCE', 'BOOKING_ADVANCE'
  )),
  constraint sale_payments_status_check check (status in ('RECEIVED', 'REVERSED'))
);

create index sale_payments_sale_idx on public.sale_payments (sale_id);
create index sale_payments_date_idx on public.sale_payments (dealer_id, payment_date desc);

create table public.deliveries (
  id              uuid primary key default gen_random_uuid(),
  dealer_id       uuid not null,
  branch_id       uuid not null,
  sale_id         uuid not null,
  vehicle_id      uuid not null,

  delivery_number text not null,
  delivered_at    timestamptz not null default now(),
  delivered_by    uuid,
  received_by_name text,
  odometer        numeric(10, 1),
  remarks         text,

  created_at      timestamptz not null default now(),

  constraint deliveries_number_key unique (dealer_id, delivery_number),
  constraint deliveries_sale_key   unique (sale_id),
  constraint deliveries_sale_tenant_fkey
    foreign key (sale_id, dealer_id) references public.sales (id, dealer_id) on delete cascade,
  constraint deliveries_vehicle_tenant_fkey
    foreign key (vehicle_id, dealer_id) references public.vehicles (id, dealer_id),
  constraint deliveries_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id)
);

create index deliveries_vehicle_idx on public.deliveries (vehicle_id);
create index deliveries_date_idx    on public.deliveries (dealer_id, delivered_at desc);

-- -----------------------------------------------------------------------------
-- Sale workflow guard — spec §19
-- -----------------------------------------------------------------------------
create or replace function app.sales_guard()
returns trigger
language plpgsql
as $$
declare
  v_allowed text[];
begin
  if tg_op = 'DELETE' then
    if old.status <> 'DRAFT' then
      raise exception 'Sale % is % and cannot be deleted.', old.invoice_number, old.status
        using errcode = 'insufficient_privilege',
              hint = 'Cancel it, or post a sales return.';
    end if;
    return old;
  end if;

  if tg_op = 'INSERT' then
    if new.status <> 'DRAFT' then
      raise exception 'A sale is created as DRAFT, not %.', new.status
        using errcode = 'check_violation';
    end if;
    return new;
  end if;

  if new.status = old.status then
    -- A posted invoice's figures are fixed; only the payment tally may move.
    -- Columns are compared explicitly: `balance_amount` is generated, and a
    -- BEFORE trigger does not see generated columns populated in NEW, so a
    -- subtractive JSONB comparison would flag every update as a change.
    if old.status in ('POSTED', 'DELIVERED')
       and (new.taxable_value   is distinct from old.taxable_value
         or new.cgst_amount     is distinct from old.cgst_amount
         or new.sgst_amount     is distinct from old.sgst_amount
         or new.igst_amount     is distinct from old.igst_amount
         or new.cess_amount     is distinct from old.cess_amount
         or new.discount_amount is distinct from old.discount_amount
         or new.total_amount    is distinct from old.total_amount
         or new.total_cost      is distinct from old.total_cost
         or new.invoice_number  is distinct from old.invoice_number
         or new.invoice_date    is distinct from old.invoice_date
         or new.customer_id     is distinct from old.customer_id
         or new.vehicle_id      is distinct from old.vehicle_id
         or new.journal_entry_id is distinct from old.journal_entry_id) then
      raise exception 'Sale % is % and its invoice values are immutable.', old.invoice_number, old.status
        using errcode = 'insufficient_privilege',
              hint = 'Spec §23: correct it with a reversal and a fresh invoice.';
    end if;
    return new;
  end if;

  v_allowed := case old.status
    when 'DRAFT'                 then array['SUBMITTED', 'CANCELLED']
    when 'SUBMITTED'             then array['ACCOUNTS_VERIFICATION', 'DRAFT', 'CANCELLED']
    when 'ACCOUNTS_VERIFICATION' then array['APPROVED', 'DRAFT', 'CANCELLED']
    when 'APPROVED'              then array['POSTED', 'CANCELLED']
    when 'POSTED'                then array['DELIVERED', 'RETURNED']
    when 'DELIVERED'             then array['RETURNED']
    else array[]::text[]
  end;

  if not (new.status = any (v_allowed)) then
    raise exception 'Sale % cannot move from % to %.', old.invoice_number, old.status, new.status
      using errcode = 'check_violation',
            hint = 'Spec §19 defines the sale workflow.';
  end if;

  -- Posting requires the accounting entry to exist (spec §19, §48).
  if new.status = 'POSTED' and new.journal_entry_id is null then
    raise exception 'Sale % cannot be POSTED without a journal entry.', old.invoice_number
      using errcode = 'check_violation',
            hint = 'Spec §48: an invoice without its accounting effect is not permitted.';
  end if;

  new.posted_at    := case when new.status = 'POSTED'    then coalesce(new.posted_at, now())    else new.posted_at end;
  new.delivered_at := case when new.status = 'DELIVERED' then coalesce(new.delivered_at, now()) else new.delivered_at end;
  return new;
end;
$$;

create trigger sales_guard
  before insert or update or delete on public.sales
  for each row execute function app.sales_guard();

-- Lines may only change while the invoice is still being prepared.
create or replace function app.sale_lines_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status text;
  v_sale uuid := coalesce(new.sale_id, old.sale_id);
begin
  select status into v_status from public.sales where id = v_sale;
  if v_status is null then
    return coalesce(new, old);
  end if;
  if v_status not in ('DRAFT', 'SUBMITTED', 'ACCOUNTS_VERIFICATION') then
    raise exception 'Cannot % lines of a % sale.', lower(tg_op), v_status
      using errcode = 'insufficient_privilege';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger sale_lines_guard
  before insert or update or delete on public.sale_lines
  for each row execute function app.sale_lines_guard();

-- Invoice totals are derived from the lines, never supplied by the caller.
create or replace function app.sales_sync_totals()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sale uuid := coalesce(new.sale_id, old.sale_id);
begin
  update public.sales s
     set taxable_value   = coalesce(t.taxable, 0),
         cgst_amount     = coalesce(t.cgst, 0),
         sgst_amount     = coalesce(t.sgst, 0),
         igst_amount     = coalesce(t.igst, 0),
         cess_amount     = coalesce(t.cess, 0),
         discount_amount = coalesce(t.discount, 0),
         total_amount    = coalesce(t.total, 0),
         total_cost      = coalesce(t.cost, 0)
    from (
      select sum(l.taxable_value) taxable, sum(l.cgst_amount) cgst, sum(l.sgst_amount) sgst,
             sum(l.igst_amount) igst, sum(l.cess_amount) cess, sum(l.discount) discount,
             sum(l.total_amount) total, sum(l.cost_amount) cost
        from public.sale_lines l where l.sale_id = v_sale
    ) t
   where s.id = v_sale
     and s.status in ('DRAFT', 'SUBMITTED', 'ACCOUNTS_VERIFICATION');
  return null;
end;
$$;

create trigger sale_lines_sync_totals
  after insert or update or delete on public.sale_lines
  for each row execute function app.sales_sync_totals();

create or replace function app.sales_sync_payments()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sale uuid := coalesce(new.sale_id, old.sale_id);
begin
  update public.sales s
     set paid_amount = coalesce((
           select sum(p.amount) from public.sale_payments p
            where p.sale_id = v_sale and p.status = 'RECEIVED' and p.payment_mode <> 'FINANCE'
         ), 0),
         finance_amount = coalesce((
           select sum(p.amount) from public.sale_payments p
            where p.sale_id = v_sale and p.status = 'RECEIVED' and p.payment_mode = 'FINANCE'
         ), 0)
   where s.id = v_sale;
  return null;
end;
$$;

create trigger sale_payments_sync
  after insert or update or delete on public.sale_payments
  for each row execute function app.sales_sync_payments();

create trigger bookings_set_updated_at before update on public.bookings
  for each row execute function app.set_updated_at();
create trigger sales_set_updated_at before update on public.sales
  for each row execute function app.set_updated_at();

create trigger bookings_audit after insert or update or delete on public.bookings
  for each row execute function app.audit_trigger();
create trigger sales_audit after insert or update or delete on public.sales
  for each row execute function app.audit_trigger();
create trigger deliveries_audit after insert or update or delete on public.deliveries
  for each row execute function app.audit_trigger();

alter table public.bookings         enable row level security;
alter table public.booking_payments enable row level security;
alter table public.sales            enable row level security;
alter table public.sale_lines       enable row level security;
alter table public.sale_payments    enable row level security;
alter table public.deliveries       enable row level security;

create policy bookings_select on public.bookings for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('bookings.view')));
create policy bookings_insert on public.bookings for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('bookings.create')));
create policy bookings_update on public.bookings for update to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('bookings.create') or app.has_permission('bookings.cancel')
              or app.has_permission('bookings.convert'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy booking_payments_select on public.booking_payments for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bookings.view')));
create policy booking_payments_insert on public.booking_payments for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bookings.create')));

create policy sales_select on public.sales for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('sales.view')));
create policy sales_insert on public.sales for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('sales.create')));
create policy sales_update on public.sales for update to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('sales.create') or app.has_permission('sales.submit')
              or app.has_permission('sales.verify') or app.has_permission('sales.approve')
              or app.has_permission('sales.post') or app.has_permission('sales.deliver')
              or app.has_permission('sales.cancel'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy sale_lines_select on public.sale_lines for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('sales.view')));
create policy sale_lines_write on public.sale_lines for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('sales.create')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('sales.create')));

create policy sale_payments_select on public.sale_payments for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('sales.view')));
create policy sale_payments_insert on public.sale_payments for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('sales.create')));

create policy deliveries_select on public.deliveries for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('sales.view')));
create policy deliveries_insert on public.deliveries for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('sales.deliver')));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.bookings, public.sales to authenticated';
    execute 'grant select, insert on public.booking_payments, public.sale_payments, public.deliveries to authenticated';
    execute 'grant select, insert, update, delete on public.sale_lines to authenticated';
    execute 'grant all on public.bookings, public.booking_payments, public.sales, public.sale_lines, public.sale_payments, public.deliveries to service_role';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0021_finance.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0021 — Finance: HP applications, trade advances, settlements
-- =============================================================================
-- Spec §25, §26, §27, §60.
--
-- The rule that shapes this: "Never combine all finance companies into one
-- generic balance." Every transaction carries finance_company_id, and the running
-- balance is per company. `finance_transactions` is the subsidiary ledger that
-- reconciles to the general ledger through the party-tagged journal lines.
--
-- Rollback: drop table public.finance_settlements, public.finance_transactions,
--           public.finance_applications;
-- =============================================================================

create table public.finance_applications (
  id                  uuid primary key default gen_random_uuid(),
  dealer_id           uuid not null references public.dealers (id) on delete restrict,
  branch_id           uuid not null,

  application_number  text not null,
  application_date    date not null default current_date,

  customer_id         uuid not null,
  finance_company_id  uuid not null,
  vehicle_id          uuid,
  sale_id             uuid,

  loan_amount         numeric(18, 4) not null default 0,
  down_payment        numeric(18, 4) not null default 0,
  tenure_months       smallint,
  interest_rate       numeric(6, 3),

  approval_status     text not null default 'PENDING',
  approved_amount     numeric(18, 4),
  approved_at         timestamptz,

  disbursement_status text not null default 'PENDING',
  disbursed_amount    numeric(18, 4) not null default 0,
  disbursed_at        timestamptz,
  dd_number           text,
  bank_reference      text,

  -- Restricted: commission is a sensitive figure (spec §52).
  commission_amount   numeric(18, 4) not null default 0,

  pending_amount      numeric(18, 4) generated always as (
    coalesce(approved_amount, loan_amount) - disbursed_amount
  ) stored,

  rejection_reason    text,
  notes               text,

  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid,
  updated_by          uuid,

  constraint fa_number_key    unique (dealer_id, application_number),
  constraint fa_id_dealer_key unique (id, dealer_id),
  constraint fa_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint fa_customer_tenant_fkey
    foreign key (customer_id, dealer_id) references public.customers (id, dealer_id),
  constraint fa_company_tenant_fkey
    foreign key (finance_company_id, dealer_id) references public.finance_companies (id, dealer_id),
  constraint fa_vehicle_tenant_fkey
    foreign key (vehicle_id, dealer_id) references public.vehicles (id, dealer_id),
  constraint fa_sale_tenant_fkey
    foreign key (sale_id, dealer_id) references public.sales (id, dealer_id),
  constraint fa_approval_check     check (approval_status in ('PENDING', 'APPROVED', 'REJECTED', 'CANCELLED')),
  constraint fa_disbursement_check check (disbursement_status in ('PENDING', 'PARTIAL', 'DISBURSED', 'CANCELLED')),
  constraint fa_amounts_check      check (
    loan_amount >= 0 and down_payment >= 0 and disbursed_amount >= 0 and commission_amount >= 0
    and (approved_amount is null or approved_amount >= 0)
  ),
  constraint fa_approved_amount_check check (approval_status <> 'APPROVED' or approved_amount is not null),
  constraint fa_rejection_check       check (approval_status <> 'REJECTED' or rejection_reason is not null),
  constraint fa_tenure_check          check (tenure_months is null or tenure_months between 1 and 120)
);

comment on table public.finance_applications is 'HP / finance applications (spec §27).';
comment on column public.finance_applications.commission_amount is
  'Restricted. Withheld from roles lacking finance.commission.view (spec §52).';

create index fa_customer_idx  on public.finance_applications (customer_id, application_date desc);
create index fa_company_idx   on public.finance_applications (finance_company_id, approval_status);
create index fa_branch_idx    on public.finance_applications (branch_id, application_date desc);
create index fa_sale_idx      on public.finance_applications (sale_id) where sale_id is not null;
create index fa_pending_idx   on public.finance_applications (dealer_id)
  where disbursement_status in ('PENDING', 'PARTIAL');

-- =============================================================================
-- finance_transactions — the per-company subsidiary ledger (spec §26)
-- =============================================================================
create table public.finance_transactions (
  id                 bigint generated always as identity primary key,
  dealer_id          uuid not null,
  branch_id          uuid not null,
  finance_company_id uuid not null,

  transaction_date   date not null default current_date,
  transaction_type   text not null,

  -- Signed against the dealer's position with this company: a credit increases
  -- what the company owes the dealer, a debit reduces it.
  debit              numeric(18, 4) not null default 0,
  credit             numeric(18, 4) not null default 0,
  balance_after      numeric(18, 4) not null default 0,

  reference_type     text,
  reference_id       uuid,
  reference_number   text,
  narration          text,

  application_id     uuid,
  sale_id            uuid,
  journal_entry_id   uuid,

  created_at         timestamptz not null default now(),
  created_by         uuid,

  constraint ft_company_tenant_fkey
    foreign key (finance_company_id, dealer_id) references public.finance_companies (id, dealer_id),
  constraint ft_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint ft_application_tenant_fkey
    foreign key (application_id, dealer_id) references public.finance_applications (id, dealer_id),
  constraint ft_sale_tenant_fkey
    foreign key (sale_id, dealer_id) references public.sales (id, dealer_id),
  constraint ft_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint ft_type_check check (transaction_type in (
    'ADVANCE_RECEIVED', 'VEHICLE_ADJUSTMENT', 'SETTLEMENT',
    'REFUND', 'COMMISSION', 'MANUAL_ADJUSTMENT', 'DISBURSEMENT'
  )),
  constraint ft_amounts_check check (debit >= 0 and credit >= 0),
  -- One-sided, like a journal line.
  constraint ft_one_sided_check check ((debit > 0 and credit = 0) or (credit > 0 and debit = 0))
);

comment on table public.finance_transactions is
  'Per-finance-company ledger (spec §25, §26). Never aggregated into a single '
  'generic balance across companies.';

create trigger finance_transactions_append_only
  before update or delete on public.finance_transactions
  for each row execute function app.forbid_mutation();

create index ft_company_date_idx on public.finance_transactions (finance_company_id, transaction_date desc);
create index ft_dealer_date_idx  on public.finance_transactions (dealer_id, transaction_date desc);
create index ft_reference_idx    on public.finance_transactions (reference_type, reference_id)
  where reference_id is not null;

-- Running balance per company, computed under a row lock so concurrent postings
-- cannot both read the same prior balance.
create or replace function app.finance_transactions_balance()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prev numeric(18, 4);
begin
  perform 1 from public.finance_companies
   where id = new.finance_company_id for update;

  select coalesce(balance_after, 0) into v_prev
    from public.finance_transactions
   where finance_company_id = new.finance_company_id
   order by id desc
   limit 1;

  new.balance_after := coalesce(v_prev, 0) + new.credit - new.debit;
  return new;
end;
$$;

create trigger finance_transactions_balance
  before insert on public.finance_transactions
  for each row execute function app.finance_transactions_balance();

create table public.finance_settlements (
  id                 uuid primary key default gen_random_uuid(),
  dealer_id          uuid not null,
  finance_company_id uuid not null,

  settlement_number  text not null,
  settlement_date    date not null default current_date,
  from_date          date,
  to_date            date,

  gross_amount       numeric(18, 4) not null default 0,
  commission_amount  numeric(18, 4) not null default 0,
  deductions         numeric(18, 4) not null default 0,
  net_amount         numeric(18, 4) generated always as (
    gross_amount - commission_amount - deductions
  ) stored,

  status             text not null default 'DRAFT',
  journal_entry_id   uuid,
  notes              text,

  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  created_by         uuid,

  constraint fs_number_key unique (dealer_id, settlement_number),
  constraint fs_id_dealer_key unique (id, dealer_id),
  constraint fs_company_tenant_fkey
    foreign key (finance_company_id, dealer_id) references public.finance_companies (id, dealer_id),
  constraint fs_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint fs_status_check  check (status in ('DRAFT', 'POSTED', 'CANCELLED')),
  constraint fs_amounts_check check (gross_amount >= 0 and commission_amount >= 0 and deductions >= 0),
  constraint fs_dates_check   check (to_date is null or from_date is null or to_date >= from_date)
);

create index fs_company_idx on public.finance_settlements (finance_company_id, settlement_date desc);

-- -----------------------------------------------------------------------------
-- public.finance_company_ledger() — opening + credits − debits = closing (§26)
-- -----------------------------------------------------------------------------
create or replace function public.finance_company_ledger(
  p_company_id uuid,
  p_from       date,
  p_to         date
)
returns table (
  transaction_date date,
  transaction_type text,
  reference_number text,
  narration        text,
  debit            numeric(18, 4),
  credit           numeric(18, 4),
  balance_after    numeric(18, 4)
)
language sql
stable
as $$
  -- Opening row: everything before the window, collapsed to one line.
  select p_from, 'OPENING'::text, null::text, 'Opening balance'::text,
         0::numeric(18, 4), 0::numeric(18, 4),
         coalesce((
           select ft.balance_after from public.finance_transactions ft
            where ft.finance_company_id = p_company_id and ft.transaction_date < p_from
            order by ft.id desc limit 1
         ), 0)
  union all
  select ft.transaction_date, ft.transaction_type, ft.reference_number, ft.narration,
         ft.debit, ft.credit, ft.balance_after
    from public.finance_transactions ft
   where ft.finance_company_id = p_company_id
     and ft.transaction_date between p_from and p_to
   order by 1, 7;
$$;

comment on function public.finance_company_ledger(uuid, date, date) is
  'Daily ledger view for one finance company (spec §26): opening, movements, closing.';

create trigger fa_set_updated_at before update on public.finance_applications
  for each row execute function app.set_updated_at();
create trigger fs_set_updated_at before update on public.finance_settlements
  for each row execute function app.set_updated_at();
create trigger fa_audit after insert or update or delete on public.finance_applications
  for each row execute function app.audit_trigger();

alter table public.finance_applications enable row level security;
alter table public.finance_transactions enable row level security;
alter table public.finance_settlements  enable row level security;

create policy fa_select on public.finance_applications for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('finance.applications.view')));
create policy fa_write on public.finance_applications for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('finance.applications.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('finance.applications.manage')));

create policy ft_select on public.finance_transactions for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('finance.trade_advance.view')));
create policy ft_insert on public.finance_transactions for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('finance.trade_advance.manage')
              or app.has_permission('finance.settlements.manage')
              or app.has_permission('sales.post'))));

create policy fs_select on public.finance_settlements for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('finance.trade_advance.view')));
create policy fs_write on public.finance_settlements for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('finance.settlements.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('finance.settlements.manage')));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.finance_applications, public.finance_settlements to authenticated';
    execute 'grant select, insert on public.finance_transactions to authenticated';
    execute 'grant all on public.finance_applications, public.finance_transactions, public.finance_settlements to service_role';
    execute 'grant execute on function public.finance_company_ledger(uuid, date, date) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0022_cash_and_bank.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0022 — Cash book, day closing, bank accounts and reconciliation
-- =============================================================================
-- Spec §36, §37, §38, §39, §60.14, §60.15.
--
-- The daily cash book is mandatory and so is the daily close. Once a day is
-- CLOSED its transactions are frozen — spec §36: "After close: no direct edits.
-- Only reversal/adjustment with permission." That is enforced by a trigger here,
-- not by a UI that hides the edit button.
--
-- Rollback: drop table public.bank_reconciliations, public.bank_statement_lines,
--           public.bank_transactions, public.bank_accounts,
--           public.cash_day_closings, public.cash_transactions, public.cash_accounts;
-- =============================================================================

create table public.cash_accounts (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null references public.dealers (id) on delete cascade,
  branch_id         uuid not null,

  name              text not null,
  ledger_account_id uuid not null,
  opening_balance   numeric(18, 4) not null default 0,
  current_balance   numeric(18, 4) not null default 0,

  status            text not null default 'ACTIVE',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  -- One cash account per branch (spec §36: "Each branch has a cash account").
  constraint cash_accounts_branch_key unique (branch_id),
  constraint cash_accounts_id_dealer_key unique (id, dealer_id),
  constraint cash_accounts_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id) on delete cascade,
  constraint cash_accounts_ledger_tenant_fkey
    foreign key (ledger_account_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint cash_accounts_status_check check (status in ('ACTIVE', 'INACTIVE'))
);

-- -----------------------------------------------------------------------------
-- cash_day_closings — spec §36
-- -----------------------------------------------------------------------------
create table public.cash_day_closings (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null,
  branch_id         uuid not null,
  cash_account_id   uuid not null,

  business_date     date not null,
  status            text not null default 'OPEN',

  opening_balance   numeric(18, 4) not null default 0,
  total_receipts    numeric(18, 4) not null default 0,
  total_payments    numeric(18, 4) not null default 0,
  expected_closing  numeric(18, 4) generated always as (
    opening_balance + total_receipts - total_payments
  ) stored,

  physical_cash     numeric(18, 4),
  -- The number that matters at close: counted minus expected.
  difference        numeric(18, 4),

  denominations     jsonb,
  counted_at        timestamptz,
  counted_by        uuid,
  closed_at         timestamptz,
  closed_by         uuid,
  reopened_at       timestamptz,
  reopened_by       uuid,
  reopen_reason     text,
  remarks           text,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint cdc_branch_date_key unique (branch_id, business_date),
  constraint cdc_id_dealer_key   unique (id, dealer_id),
  constraint cdc_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint cdc_account_tenant_fkey
    foreign key (cash_account_id, dealer_id) references public.cash_accounts (id, dealer_id),
  constraint cdc_status_check check (status in ('OPEN', 'IN_PROGRESS', 'COUNTED', 'CLOSED')),
  constraint cdc_counted_check check (status <> 'COUNTED' or physical_cash is not null),
  constraint cdc_closed_check  check (status <> 'CLOSED' or (physical_cash is not null and closed_at is not null)),
  constraint cdc_reopen_check  check (reopened_at is null or reopen_reason is not null)
);

comment on table public.cash_day_closings is
  'Mandatory daily cash close (spec §36, §60.15). OPEN → IN_PROGRESS → COUNTED → CLOSED.';

create index cdc_branch_date_idx on public.cash_day_closings (branch_id, business_date desc);
create index cdc_open_idx        on public.cash_day_closings (dealer_id) where status <> 'CLOSED';

create table public.cash_transactions (
  id               bigint generated always as identity primary key,
  dealer_id        uuid not null,
  branch_id        uuid not null,
  cash_account_id  uuid not null,

  business_date    date not null default current_date,
  transaction_time timestamptz not null default now(),

  direction        text not null,
  amount           numeric(18, 4) not null,
  balance_after    numeric(18, 4) not null default 0,

  particular       text not null,
  reference_type   text,
  reference_id     uuid,
  reference_number text,

  customer_id      uuid,
  journal_entry_id uuid,
  status           text not null default 'ACTIVE',

  created_at       timestamptz not null default now(),
  created_by       uuid,

  constraint ct_account_tenant_fkey
    foreign key (cash_account_id, dealer_id) references public.cash_accounts (id, dealer_id),
  constraint ct_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint ct_customer_tenant_fkey
    foreign key (customer_id, dealer_id) references public.customers (id, dealer_id),
  constraint ct_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint ct_direction_check check (direction in ('RECEIPT', 'PAYMENT')),
  constraint ct_amount_check    check (amount > 0),
  constraint ct_status_check    check (status in ('ACTIVE', 'REVERSED'))
);

comment on table public.cash_transactions is 'Daily cash book entries (spec §37).';

create index ct_branch_date_idx  on public.cash_transactions (branch_id, business_date desc, transaction_time);
create index ct_account_date_idx on public.cash_transactions (cash_account_id, business_date desc);
create index ct_reference_idx    on public.cash_transactions (reference_type, reference_id) where reference_id is not null;
create index ct_customer_idx     on public.cash_transactions (customer_id) where customer_id is not null;

-- -----------------------------------------------------------------------------
-- A closed day is frozen (spec §36, §60.23)
-- -----------------------------------------------------------------------------
create or replace function app.cash_transactions_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status text;
  v_prev   numeric(18, 4);
  v_row    public.cash_transactions;
begin
  v_row := coalesce(new, old);

  select status into v_status
    from public.cash_day_closings
   where branch_id = v_row.branch_id and business_date = v_row.business_date;

  if v_status = 'CLOSED' then
    raise exception 'The cash book for % is closed and cannot be changed.', v_row.business_date
      using errcode = 'insufficient_privilege',
            hint = 'Spec §36: reopen the day with permission, or post an adjustment.';
  end if;

  if tg_op = 'DELETE' then
    raise exception 'Cash book entries are not deleted; reverse them instead.'
      using errcode = 'insufficient_privilege';
  end if;

  if tg_op = 'INSERT' then
    -- Lock the account so two concurrent receipts cannot read the same balance.
    perform 1 from public.cash_accounts where id = new.cash_account_id for update;

    select coalesce(balance_after, 0) into v_prev
      from public.cash_transactions
     where cash_account_id = new.cash_account_id and status = 'ACTIVE'
     order by id desc limit 1;

    if v_prev is null then
      select opening_balance into v_prev from public.cash_accounts where id = new.cash_account_id;
    end if;

    new.balance_after := coalesce(v_prev, 0)
      + case when new.direction = 'RECEIPT' then new.amount else -new.amount end;
  end if;

  return new;
end;
$$;

create trigger cash_transactions_guard
  before insert or update or delete on public.cash_transactions
  for each row execute function app.cash_transactions_guard();

-- Keep the day sheet and the account balance in step with the entries.
create or replace function app.cash_sync_day()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.cash_transactions := coalesce(new, old);
begin
  update public.cash_day_closings d
     set total_receipts = coalesce((
           select sum(t.amount) from public.cash_transactions t
            where t.branch_id = v_row.branch_id and t.business_date = v_row.business_date
              and t.direction = 'RECEIPT' and t.status = 'ACTIVE'), 0),
         total_payments = coalesce((
           select sum(t.amount) from public.cash_transactions t
            where t.branch_id = v_row.branch_id and t.business_date = v_row.business_date
              and t.direction = 'PAYMENT' and t.status = 'ACTIVE'), 0),
         status = case when d.status = 'OPEN' then 'IN_PROGRESS' else d.status end
   where d.branch_id = v_row.branch_id and d.business_date = v_row.business_date;

  update public.cash_accounts a
     set current_balance = coalesce((
           select t.balance_after from public.cash_transactions t
            where t.cash_account_id = v_row.cash_account_id and t.status = 'ACTIVE'
            order by t.id desc limit 1), a.opening_balance)
   where a.id = v_row.cash_account_id;

  return null;
end;
$$;

create trigger cash_transactions_sync
  after insert or update on public.cash_transactions
  for each row execute function app.cash_sync_day();

-- The difference is computed at close, never typed in.
create or replace function app.cash_day_guard()
returns trigger
language plpgsql
as $$
begin
  if new.physical_cash is not null then
    new.difference := new.physical_cash - new.expected_closing;
  end if;

  if tg_op = 'UPDATE' and old.status = 'CLOSED' and new.status <> 'CLOSED' then
    if new.reopen_reason is null then
      raise exception 'Reopening a closed day requires a reason.'
        using errcode = 'check_violation';
    end if;
    new.reopened_at := now();
  end if;

  return new;
end;
$$;

create trigger cash_day_guard
  before insert or update on public.cash_day_closings
  for each row execute function app.cash_day_guard();

-- =============================================================================
-- Bank — spec §38, §39
-- =============================================================================
create table public.bank_accounts (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null references public.dealers (id) on delete cascade,
  branch_id         uuid,

  name              text not null,
  bank_name         text not null,
  account_number    text not null,
  ifsc              text,
  account_type      text not null default 'CURRENT',

  ledger_account_id uuid not null,
  opening_balance   numeric(18, 4) not null default 0,
  current_balance   numeric(18, 4) not null default 0,

  status            text not null default 'ACTIVE',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint bank_accounts_number_key   unique (dealer_id, account_number),
  constraint bank_accounts_id_dealer_key unique (id, dealer_id),
  constraint bank_accounts_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint bank_accounts_ledger_tenant_fkey
    foreign key (ledger_account_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint bank_accounts_type_check   check (account_type in ('CURRENT', 'SAVINGS', 'OD', 'CC')),
  constraint bank_accounts_status_check check (status in ('ACTIVE', 'INACTIVE', 'CLOSED')),
  constraint bank_accounts_ifsc_check   check (ifsc is null or ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$')
);

create index bank_accounts_dealer_idx on public.bank_accounts (dealer_id, status);
create index bank_accounts_branch_idx on public.bank_accounts (branch_id) where branch_id is not null;

create table public.bank_transactions (
  id                bigint generated always as identity primary key,
  dealer_id         uuid not null,
  bank_account_id   uuid not null,

  transaction_date  date not null default current_date,
  direction         text not null,
  amount            numeric(18, 4) not null,
  balance_after     numeric(18, 4) not null default 0,

  particular        text not null,
  reference_type    text,
  reference_id      uuid,
  reference_number  text,
  utr               text,
  instrument_number text,

  journal_entry_id  uuid,
  -- Reconciliation state (spec §39).
  reconciled        boolean not null default false,
  reconciliation_id uuid,
  status            text not null default 'ACTIVE',

  created_at        timestamptz not null default now(),
  created_by        uuid,

  constraint bt_account_tenant_fkey
    foreign key (bank_account_id, dealer_id) references public.bank_accounts (id, dealer_id),
  constraint bt_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint bt_direction_check check (direction in ('RECEIPT', 'PAYMENT')),
  constraint bt_amount_check    check (amount > 0),
  constraint bt_status_check    check (status in ('ACTIVE', 'REVERSED'))
);

create index bt_account_date_idx on public.bank_transactions (bank_account_id, transaction_date desc);
create index bt_unreconciled_idx on public.bank_transactions (bank_account_id) where not reconciled;
create index bt_utr_idx          on public.bank_transactions (dealer_id, utr) where utr is not null;
create index bt_reference_idx    on public.bank_transactions (reference_type, reference_id) where reference_id is not null;

create or replace function app.bank_transactions_balance()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_prev numeric(18, 4);
begin
  perform 1 from public.bank_accounts where id = new.bank_account_id for update;

  select coalesce(balance_after, 0) into v_prev
    from public.bank_transactions
   where bank_account_id = new.bank_account_id and status = 'ACTIVE'
   order by id desc limit 1;

  if v_prev is null then
    select opening_balance into v_prev from public.bank_accounts where id = new.bank_account_id;
  end if;

  new.balance_after := coalesce(v_prev, 0)
    + case when new.direction = 'RECEIPT' then new.amount else -new.amount end;
  return new;
end;
$$;

create trigger bank_transactions_balance
  before insert on public.bank_transactions
  for each row execute function app.bank_transactions_balance();

create or replace function app.bank_sync_balance()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.bank_accounts a
     set current_balance = coalesce((
           select t.balance_after from public.bank_transactions t
            where t.bank_account_id = a.id and t.status = 'ACTIVE'
            order by t.id desc limit 1), a.opening_balance)
   where a.id = coalesce(new.bank_account_id, old.bank_account_id);
  return null;
end;
$$;

create trigger bank_transactions_sync
  after insert or update on public.bank_transactions
  for each row execute function app.bank_sync_balance();

-- Imported statement lines, staged before matching (spec §39).
create table public.bank_statement_lines (
  id               bigint generated always as identity primary key,
  dealer_id        uuid not null,
  bank_account_id  uuid not null,

  import_batch     uuid not null,
  statement_date   date not null,
  value_date       date,
  narration        text not null,
  reference        text,
  utr              text,
  upi_id           text,
  cheque_number    text,

  debit            numeric(18, 4) not null default 0,
  credit           numeric(18, 4) not null default 0,
  running_balance  numeric(18, 4),

  match_status     text not null default 'UNMATCHED',
  matched_transaction_id bigint,
  reconciliation_id uuid,

  raw_row          jsonb,
  created_at       timestamptz not null default now(),
  created_by       uuid,

  constraint bsl_account_tenant_fkey
    foreign key (bank_account_id, dealer_id) references public.bank_accounts (id, dealer_id),
  constraint bsl_status_check check (match_status in ('UNMATCHED', 'MATCHED', 'PARTIAL', 'IGNORED')),
  constraint bsl_amounts_check check (debit >= 0 and credit >= 0),
  constraint bsl_one_sided_check check ((debit > 0 and credit = 0) or (credit > 0 and debit = 0)),
  -- Spec §39: never mark reconciled without recording the link.
  constraint bsl_matched_link_check check (
    match_status <> 'MATCHED' or matched_transaction_id is not null
  )
);

create index bsl_account_date_idx on public.bank_statement_lines (bank_account_id, statement_date desc);
create index bsl_status_idx       on public.bank_statement_lines (bank_account_id, match_status);
create index bsl_batch_idx        on public.bank_statement_lines (import_batch);
create index bsl_utr_idx          on public.bank_statement_lines (dealer_id, utr) where utr is not null;

-- Duplicate protection on re-import: the same line twice is rejected.
create unique index bsl_dedupe_key
  on public.bank_statement_lines (bank_account_id, statement_date, debit, credit, coalesce(utr, ''), md5(narration));

create table public.bank_reconciliations (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null,
  bank_account_id  uuid not null,

  reconciliation_number text not null,
  from_date        date not null,
  to_date          date not null,
  statement_closing_balance numeric(18, 4) not null default 0,
  book_closing_balance      numeric(18, 4) not null default 0,
  difference       numeric(18, 4) generated always as (
    statement_closing_balance - book_closing_balance
  ) stored,

  matched_count    integer not null default 0,
  unmatched_count  integer not null default 0,

  status           text not null default 'DRAFT',
  completed_at     timestamptz,
  completed_by     uuid,
  notes            text,

  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       uuid,

  constraint br_number_key unique (dealer_id, reconciliation_number),
  constraint br_id_dealer_key unique (id, dealer_id),
  constraint br_account_tenant_fkey
    foreign key (bank_account_id, dealer_id) references public.bank_accounts (id, dealer_id),
  constraint br_status_check check (status in ('DRAFT', 'COMPLETED', 'CANCELLED')),
  constraint br_dates_check  check (to_date >= from_date)
);

create index br_account_idx on public.bank_reconciliations (bank_account_id, to_date desc);

alter table public.bank_statement_lines
  add constraint bsl_reconciliation_fkey
  foreign key (reconciliation_id) references public.bank_reconciliations (id) on delete set null;

alter table public.bank_transactions
  add constraint bt_reconciliation_fkey
  foreign key (reconciliation_id) references public.bank_reconciliations (id) on delete set null;

alter table public.bank_statement_lines
  add constraint bsl_matched_transaction_fkey
  foreign key (matched_transaction_id) references public.bank_transactions (id) on delete set null;

create trigger cash_accounts_set_updated_at before update on public.cash_accounts
  for each row execute function app.set_updated_at();
create trigger cdc_set_updated_at before update on public.cash_day_closings
  for each row execute function app.set_updated_at();
create trigger bank_accounts_set_updated_at before update on public.bank_accounts
  for each row execute function app.set_updated_at();
create trigger br_set_updated_at before update on public.bank_reconciliations
  for each row execute function app.set_updated_at();

create trigger cdc_audit after insert or update or delete on public.cash_day_closings
  for each row execute function app.audit_trigger();
create trigger bank_accounts_audit after insert or update or delete on public.bank_accounts
  for each row execute function app.audit_trigger();
create trigger br_audit after insert or update or delete on public.bank_reconciliations
  for each row execute function app.audit_trigger();

alter table public.cash_accounts        enable row level security;
alter table public.cash_day_closings    enable row level security;
alter table public.cash_transactions    enable row level security;
alter table public.bank_accounts        enable row level security;
alter table public.bank_transactions    enable row level security;
alter table public.bank_statement_lines enable row level security;
alter table public.bank_reconciliations enable row level security;

create policy cash_accounts_select on public.cash_accounts for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('cashbook.view')));
create policy cash_accounts_write on public.cash_accounts for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('admin.settings.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('admin.settings.manage')));

create policy cdc_select on public.cash_day_closings for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('cashbook.view')));
create policy cdc_write on public.cash_day_closings for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('cashbook.day_close') or app.has_permission('cashbook.day_reopen')
              or app.has_permission('cashbook.receipts.create'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy ct_select on public.cash_transactions for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('cashbook.view')));
create policy ct_insert on public.cash_transactions for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('cashbook.receipts.create') or app.has_permission('cashbook.payments.create'))));

create policy bank_accounts_select on public.bank_accounts for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.accounts.view')));
create policy bank_accounts_write on public.bank_accounts for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.accounts.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.accounts.manage')));

create policy bt_select on public.bank_transactions for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.book.view')));
create policy bt_write on public.bank_transactions for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('bank.reconcile') or app.has_permission('cashbook.payments.create'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy bsl_select on public.bank_statement_lines for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.reconcile')));
create policy bsl_write on public.bank_statement_lines for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('bank.statement.import') or app.has_permission('bank.reconcile'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy br_select on public.bank_reconciliations for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.reconcile')));
create policy br_write on public.bank_reconciliations for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.reconcile')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.reconcile')));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.cash_accounts, public.cash_day_closings, public.bank_accounts, public.bank_statement_lines, public.bank_reconciliations, public.bank_transactions to authenticated';
    execute 'grant select, insert on public.cash_transactions to authenticated';
    execute 'grant all on public.cash_accounts, public.cash_day_closings, public.cash_transactions, public.bank_accounts, public.bank_transactions, public.bank_statement_lines, public.bank_reconciliations to service_role';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0023_service.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0023 — Service: job cards, service billing, counter sales
-- =============================================================================
-- Spec §32, §33. Service consumes the same inventory as counter sales and posts
-- through the same accounting engine, so there is no separate stock or ledger
-- mechanism here — only the documents.
--
-- Counter sales (§33) reuse the service invoice with no job card attached: the
-- transaction is identical apart from the absence of a vehicle.
--
-- Rollback: drop table public.service_payments, public.service_lines,
--           public.service_invoices, public.job_cards, public.customer_vehicles;
-- =============================================================================

-- -----------------------------------------------------------------------------
-- customer_vehicles — spec §44. What the customer owns, whether we sold it or not.
-- -----------------------------------------------------------------------------
create table public.customer_vehicles (
  id              uuid primary key default gen_random_uuid(),
  dealer_id       uuid not null references public.dealers (id) on delete cascade,
  customer_id     uuid not null,

  -- Present when the unit came from our own stock; absent for a walk-in service.
  vehicle_id      uuid,
  model_id        uuid,
  variant_id      uuid,

  registration_no text,
  chassis_no      text,
  engine_no       text,
  colour          text,
  purchase_date   date,

  status          text not null default 'ACTIVE',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint cv_id_dealer_key unique (id, dealer_id),
  constraint cv_customer_tenant_fkey
    foreign key (customer_id, dealer_id) references public.customers (id, dealer_id) on delete cascade,
  constraint cv_vehicle_tenant_fkey
    foreign key (vehicle_id, dealer_id) references public.vehicles (id, dealer_id),
  constraint cv_model_tenant_fkey
    foreign key (model_id, dealer_id) references public.vehicle_models (id, dealer_id),
  constraint cv_status_check check (status in ('ACTIVE', 'SOLD', 'SCRAPPED')),
  -- Something must identify the vehicle, or the record is useless for search.
  constraint cv_identity_check check (
    registration_no is not null or chassis_no is not null or vehicle_id is not null
  )
);

create unique index cv_registration_key on public.customer_vehicles (dealer_id, registration_no)
  where registration_no is not null;
create index cv_customer_idx on public.customer_vehicles (customer_id);
create index cv_chassis_idx  on public.customer_vehicles (dealer_id, chassis_no) where chassis_no is not null;

-- -----------------------------------------------------------------------------
-- job_cards — spec §32
-- -----------------------------------------------------------------------------
create table public.job_cards (
  id                  uuid primary key default gen_random_uuid(),
  dealer_id           uuid not null references public.dealers (id) on delete restrict,
  branch_id           uuid not null,

  job_card_number     text not null,
  job_date            date not null default current_date,

  customer_id         uuid not null,
  customer_vehicle_id uuid,
  registration_no     text,
  odometer            numeric(10, 1),

  service_type        text not null default 'PAID',
  complaint           text,
  diagnosis           text,

  service_advisor_id  uuid,
  technician_id       uuid,

  promised_at         timestamptz,
  status              text not null default 'OPEN',
  closed_at           timestamptz,

  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid,
  updated_by          uuid,

  constraint jc_number_key    unique (dealer_id, job_card_number),
  constraint jc_id_dealer_key unique (id, dealer_id),
  constraint jc_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint jc_customer_tenant_fkey
    foreign key (customer_id, dealer_id) references public.customers (id, dealer_id),
  constraint jc_vehicle_tenant_fkey
    foreign key (customer_vehicle_id, dealer_id) references public.customer_vehicles (id, dealer_id),
  constraint jc_advisor_tenant_fkey
    foreign key (service_advisor_id, dealer_id) references public.employees (id, dealer_id),
  constraint jc_technician_tenant_fkey
    foreign key (technician_id, dealer_id) references public.employees (id, dealer_id),
  constraint jc_type_check   check (service_type in ('FREE', 'PAID', 'WARRANTY', 'ACCIDENT', 'RUNNING_REPAIR')),
  constraint jc_status_check check (status in ('OPEN', 'IN_PROGRESS', 'READY', 'INVOICED', 'CLOSED', 'CANCELLED'))
);

create index jc_customer_idx    on public.job_cards (customer_id, job_date desc);
create index jc_branch_date_idx on public.job_cards (branch_id, job_date desc);
create index jc_status_idx      on public.job_cards (dealer_id, status);
create index jc_vehicle_idx     on public.job_cards (customer_vehicle_id) where customer_vehicle_id is not null;

-- -----------------------------------------------------------------------------
-- service_invoices — also used for counter sales (spec §33)
-- -----------------------------------------------------------------------------
create table public.service_invoices (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null references public.dealers (id) on delete restrict,
  branch_id        uuid not null,

  invoice_number   text not null,
  invoice_date     date not null default current_date,
  -- SERVICE when a job card is attached, COUNTER for over-the-counter sales.
  invoice_type     text not null default 'SERVICE',

  job_card_id      uuid,
  customer_id      uuid,

  taxable_value    numeric(18, 4) not null default 0,
  cgst_amount      numeric(18, 4) not null default 0,
  sgst_amount      numeric(18, 4) not null default 0,
  igst_amount      numeric(18, 4) not null default 0,
  discount_amount  numeric(18, 4) not null default 0,
  total_amount     numeric(18, 4) not null default 0,
  total_cost       numeric(18, 4) not null default 0,
  paid_amount      numeric(18, 4) not null default 0,

  status           text not null default 'DRAFT',
  posted_at        timestamptz,
  journal_entry_id uuid,
  idempotency_key  text,

  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       uuid,
  updated_by       uuid,

  constraint si_number_key    unique (dealer_id, invoice_number),
  constraint si_id_dealer_key unique (id, dealer_id),
  constraint si_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint si_job_card_tenant_fkey
    foreign key (job_card_id, dealer_id) references public.job_cards (id, dealer_id),
  constraint si_customer_tenant_fkey
    foreign key (customer_id, dealer_id) references public.customers (id, dealer_id),
  constraint si_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint si_type_check   check (invoice_type in ('SERVICE', 'COUNTER')),
  constraint si_status_check check (status in ('DRAFT', 'POSTED', 'CANCELLED', 'RETURNED')),
  constraint si_amounts_check check (
    taxable_value >= 0 and total_amount >= 0 and paid_amount >= 0 and total_cost >= 0
  ),
  constraint si_gst_mode_check check ((igst_amount = 0) or (cgst_amount = 0 and sgst_amount = 0)),
  -- A service invoice needs its job card; a counter sale must not have one.
  constraint si_job_card_shape_check check (
    (invoice_type = 'SERVICE' and job_card_id is not null)
    or (invoice_type = 'COUNTER' and job_card_id is null)
  ),
  constraint si_posted_journal_check check (status <> 'POSTED' or journal_entry_id is not null)
);

create unique index si_idempotency_key on public.service_invoices (dealer_id, idempotency_key)
  where idempotency_key is not null;
create index si_branch_date_idx on public.service_invoices (branch_id, invoice_date desc);
create index si_customer_idx    on public.service_invoices (customer_id) where customer_id is not null;
create index si_job_card_idx    on public.service_invoices (job_card_id) where job_card_id is not null;
create index si_status_idx      on public.service_invoices (dealer_id, status);

create table public.service_lines (
  id            uuid primary key default gen_random_uuid(),
  dealer_id     uuid not null,
  invoice_id    uuid not null,

  line_number   smallint not null,
  line_type     text not null,

  description   text not null,
  item_id       uuid,
  hsn_code      text,

  quantity      numeric(14, 3) not null default 1,
  unit_rate     numeric(18, 4) not null default 0,
  discount      numeric(18, 4) not null default 0,
  taxable_value numeric(18, 4) not null default 0,

  tax_code      text,
  cgst_rate     numeric(6, 3) not null default 0,
  sgst_rate     numeric(6, 3) not null default 0,
  igst_rate     numeric(6, 3) not null default 0,
  cgst_amount   numeric(18, 4) not null default 0,
  sgst_amount   numeric(18, 4) not null default 0,
  igst_amount   numeric(18, 4) not null default 0,
  total_amount  numeric(18, 4) not null default 0,

  unit_cost     numeric(18, 4) not null default 0,
  cost_amount   numeric(18, 4) not null default 0,
  stock_source  text,

  created_at    timestamptz not null default now(),

  constraint sl_line_key unique (invoice_id, line_number),
  constraint sl_invoice_tenant_fkey
    foreign key (invoice_id, dealer_id) references public.service_invoices (id, dealer_id) on delete cascade,
  constraint sl_item_tenant_fkey
    foreign key (item_id, dealer_id) references public.inventory_items (id, dealer_id),
  constraint sl_type_check   check (line_type in ('LABOUR', 'SPARE', 'ACCESSORY', 'OTHER_CHARGE', 'DISCOUNT')),
  constraint sl_source_check check (stock_source is null or stock_source in ('LOCAL', 'COMPANY')),
  constraint sl_amounts_check check (quantity > 0 and unit_rate >= 0 and taxable_value >= 0)
);

create index sl_invoice_idx on public.service_lines (invoice_id, line_number);
create index sl_item_idx     on public.service_lines (item_id) where item_id is not null;

create table public.service_payments (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null,
  invoice_id     uuid not null,

  receipt_number text not null,
  payment_date   date not null default current_date,
  amount         numeric(18, 4) not null,
  payment_mode   text not null,
  reference      text,

  journal_entry_id uuid,
  status         text not null default 'RECEIVED',
  created_at     timestamptz not null default now(),
  created_by     uuid,

  constraint sp_receipt_key unique (dealer_id, receipt_number),
  constraint sp_invoice_tenant_fkey
    foreign key (invoice_id, dealer_id) references public.service_invoices (id, dealer_id) on delete cascade,
  constraint sp_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint sp_amount_check check (amount > 0),
  constraint sp_mode_check check (payment_mode in ('CASH', 'CARD', 'UPI', 'NEFT', 'RTGS', 'IMPS', 'CHEQUE')),
  constraint sp_status_check check (status in ('RECEIVED', 'REVERSED'))
);

create index sp_invoice_idx on public.service_payments (invoice_id);

-- Totals from the lines; a posted invoice is frozen.
create or replace function app.service_sync_totals()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_invoice uuid := coalesce(new.invoice_id, old.invoice_id);
begin
  update public.service_invoices s
     set taxable_value   = coalesce(t.taxable, 0),
         cgst_amount     = coalesce(t.cgst, 0),
         sgst_amount     = coalesce(t.sgst, 0),
         igst_amount     = coalesce(t.igst, 0),
         discount_amount = coalesce(t.discount, 0),
         total_amount    = coalesce(t.total, 0),
         total_cost      = coalesce(t.cost, 0)
    from (
      select sum(l.taxable_value) taxable, sum(l.cgst_amount) cgst, sum(l.sgst_amount) sgst,
             sum(l.igst_amount) igst, sum(l.discount) discount, sum(l.total_amount) total,
             sum(l.cost_amount) cost
        from public.service_lines l where l.invoice_id = v_invoice
    ) t
   where s.id = v_invoice and s.status = 'DRAFT';
  return null;
end;
$$;

create trigger service_lines_sync_totals
  after insert or update or delete on public.service_lines
  for each row execute function app.service_sync_totals();

create or replace function app.service_invoice_guard()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    if old.status <> 'DRAFT' then
      raise exception 'Service invoice % is % and cannot be deleted.', old.invoice_number, old.status
        using errcode = 'insufficient_privilege';
    end if;
    return old;
  end if;

  if tg_op = 'INSERT' then
    if new.status <> 'DRAFT' then
      raise exception 'A service invoice is created as DRAFT.'
        using errcode = 'check_violation';
    end if;
    return new;
  end if;

  if old.status = 'POSTED' and new.status = 'POSTED'
     and (new.taxable_value   is distinct from old.taxable_value
       or new.cgst_amount     is distinct from old.cgst_amount
       or new.sgst_amount     is distinct from old.sgst_amount
       or new.igst_amount     is distinct from old.igst_amount
       or new.discount_amount is distinct from old.discount_amount
       or new.total_amount    is distinct from old.total_amount
       or new.total_cost      is distinct from old.total_cost
       or new.invoice_number  is distinct from old.invoice_number
       or new.invoice_date    is distinct from old.invoice_date
       or new.journal_entry_id is distinct from old.journal_entry_id) then
    raise exception 'Service invoice % is POSTED and immutable.', old.invoice_number
      using errcode = 'insufficient_privilege';
  end if;

  if new.status = 'POSTED' and old.status = 'DRAFT' then
    if new.journal_entry_id is null then
      raise exception 'A service invoice cannot be POSTED without its journal entry.'
        using errcode = 'check_violation';
    end if;
    new.posted_at := coalesce(new.posted_at, now());
  end if;

  return new;
end;
$$;

create trigger service_invoice_guard
  before insert or update or delete on public.service_invoices
  for each row execute function app.service_invoice_guard();

create or replace function app.service_sync_payments()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_invoice uuid := coalesce(new.invoice_id, old.invoice_id);
begin
  update public.service_invoices s
     set paid_amount = coalesce((
           select sum(p.amount) from public.service_payments p
            where p.invoice_id = v_invoice and p.status = 'RECEIVED'), 0)
   where s.id = v_invoice;
  return null;
end;
$$;

create trigger service_payments_sync
  after insert or update or delete on public.service_payments
  for each row execute function app.service_sync_payments();

create trigger cv_set_updated_at before update on public.customer_vehicles
  for each row execute function app.set_updated_at();
create trigger jc_set_updated_at before update on public.job_cards
  for each row execute function app.set_updated_at();
create trigger si_set_updated_at before update on public.service_invoices
  for each row execute function app.set_updated_at();

create trigger jc_audit after insert or update or delete on public.job_cards
  for each row execute function app.audit_trigger();
create trigger si_audit after insert or update or delete on public.service_invoices
  for each row execute function app.audit_trigger();

alter table public.customer_vehicles enable row level security;
alter table public.job_cards         enable row level security;
alter table public.service_invoices  enable row level security;
alter table public.service_lines     enable row level security;
alter table public.service_payments  enable row level security;

create policy cv_select on public.customer_vehicles for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('customers.view')));
create policy cv_write on public.customer_vehicles for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('customers.edit') or app.has_permission('service.jobcards.create'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy jc_select on public.job_cards for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('service.jobcards.view')));
create policy jc_write on public.job_cards for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('service.jobcards.create')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('service.jobcards.create')));

create policy si_select on public.service_invoices for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id)
         and (app.has_permission('service.jobcards.view') or app.has_permission('inventory.view'))));
create policy si_write on public.service_invoices for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('service.billing.create') or app.has_permission('inventory.counter_sale.create'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy sl_select on public.service_lines for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('service.jobcards.view') or app.has_permission('inventory.view'))));
create policy sl_write on public.service_lines for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('service.billing.create') or app.has_permission('inventory.counter_sale.create'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy sp_select on public.service_payments for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('service.jobcards.view') or app.has_permission('inventory.view'))));
create policy sp_insert on public.service_payments for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('service.payments.collect') or app.has_permission('inventory.counter_sale.create'))));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update, delete on public.customer_vehicles, public.job_cards, public.service_invoices, public.service_lines to authenticated';
    execute 'grant select, insert on public.service_payments to authenticated';
    execute 'grant all on public.customer_vehicles, public.job_cards, public.service_invoices, public.service_lines, public.service_payments to service_role';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0024_gst_and_accounting_rules.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0024 — GST integration layer and accounting rules
-- =============================================================================
-- Spec §22, §40.
--
-- Two independent concerns, both about not hard-coding things:
--
--   accounting_rules  Spec §22: "Exact account mapping must be configurable
--                     through accounting rules. Do not hard-code account IDs in
--                     frontend code." A rule maps (module, event, component) to
--                     an account, so posting logic never names an account.
--
--   einvoices         Spec §40: an integration layer, not a coupling. The
--                     e-invoice row is separate from the invoice, so a failure at
--                     the GST portal leaves the accounting transaction untouched
--                     and simply leaves a FAILED row to retry.
--
-- Rollback: drop table public.eway_bills, public.einvoices, public.accounting_rules;
-- =============================================================================

-- =============================================================================
-- accounting_rules — spec §22
-- =============================================================================
create table public.accounting_rules (
  id           uuid primary key default gen_random_uuid(),
  dealer_id    uuid not null references public.dealers (id) on delete cascade,

  -- Which business event this rule serves.
  module       text not null,
  event        text not null,
  -- Which part of the document: EX_SHOWROOM, CGST, VEHICLE_COGS, CASH, …
  component    text not null,

  -- Which side the component posts to, and where.
  side         text not null,
  account_id   uuid not null,

  -- Optional narrowing: a branch may post to a different account.
  branch_id    uuid,
  priority     smallint not null default 100,

  description  text,
  status       text not null default 'ACTIVE',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  created_by   uuid,
  updated_by   uuid,

  constraint ar_id_dealer_key unique (id, dealer_id),
  constraint ar_account_tenant_fkey
    foreign key (account_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint ar_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint ar_module_check check (module in (
    'SALES', 'BOOKING', 'SERVICE', 'ACCESSORY', 'SPARE', 'FINANCE',
    'TRADE_ADVANCE', 'CASH', 'BANK', 'EXPENSE', 'INVENTORY', 'MANUAL', 'OPENING'
  )),
  constraint ar_side_check   check (side in ('DEBIT', 'CREDIT')),
  constraint ar_status_check check (status in ('ACTIVE', 'INACTIVE'))
);

comment on table public.accounting_rules is
  'Maps a business event component to a ledger account (spec §22). Posting code '
  'resolves accounts through this table so no account id is ever hard-coded.';

create unique index ar_scope_key
  on public.accounting_rules (dealer_id, module, event, component,
                              coalesce(branch_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where status = 'ACTIVE';

create index ar_lookup_idx on public.accounting_rules (dealer_id, module, event, status);

-- -----------------------------------------------------------------------------
-- public.resolve_account() — the only way posting code finds an account
-- -----------------------------------------------------------------------------
create or replace function public.resolve_account(
  p_dealer_id uuid,
  p_module    text,
  p_event     text,
  p_component text,
  p_branch_id uuid default null
)
returns uuid
language sql
stable
as $$
  select r.account_id
    from public.accounting_rules r
   where r.dealer_id = p_dealer_id
     and r.module = p_module
     and r.event = p_event
     and r.component = p_component
     and r.status = 'ACTIVE'
     and (r.branch_id is null or r.branch_id = p_branch_id)
   -- A branch-specific rule beats the dealer-wide default.
   order by (r.branch_id is not null) desc, r.priority
   limit 1;
$$;

comment on function public.resolve_account(uuid, text, text, text, uuid) is
  'Resolves the ledger account for a posting component (spec §22). Returns NULL '
  'when unconfigured, which the posting service must treat as an error rather '
  'than guessing an account.';

-- =============================================================================
-- einvoices — spec §40
-- =============================================================================
create table public.einvoices (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null references public.dealers (id) on delete cascade,

  -- Polymorphic: a vehicle sale or a service invoice.
  document_type     text not null,
  document_id       uuid not null,
  document_number   text not null,
  document_date     date not null,

  status            text not null default 'PENDING',

  -- What the portal gave back.
  irn               text,
  ack_number        text,
  ack_date          timestamptz,
  signed_qr_code    text,
  signed_invoice    text,

  -- What we sent and what came back, for the audit reference §40 requires.
  request_payload   jsonb,
  response_payload  jsonb,
  error_code        text,
  error_message     text,

  attempt_count     integer not null default 0,
  last_attempt_at   timestamptz,
  cancelled_at      timestamptz,
  cancel_reason     text,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid,

  constraint einvoices_document_key unique (dealer_id, document_type, document_id),
  constraint einvoices_irn_key      unique (irn),
  constraint einvoices_type_check   check (document_type in ('SALE', 'SERVICE_INVOICE')),
  constraint einvoices_status_check check (status in ('PENDING', 'GENERATED', 'FAILED', 'CANCELLED')),
  -- A generated e-invoice must carry the portal's identifiers.
  constraint einvoices_generated_check check (
    status <> 'GENERATED' or (irn is not null and ack_number is not null)
  ),
  constraint einvoices_failed_check check (status <> 'FAILED' or error_message is not null),
  constraint einvoices_cancel_check check (cancelled_at is null or cancel_reason is not null)
);

comment on table public.einvoices is
  'E-invoice integration layer (spec §40). Separate from the invoice, so a portal '
  'failure never corrupts the accounting transaction — the document stays posted '
  'and this row records FAILED for retry.';

create index einvoices_status_idx   on public.einvoices (dealer_id, status);
create index einvoices_document_idx on public.einvoices (document_type, document_id);
create index einvoices_retry_idx    on public.einvoices (dealer_id, last_attempt_at) where status = 'FAILED';

create table public.eway_bills (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null references public.dealers (id) on delete cascade,

  document_type    text not null,
  document_id      uuid not null,
  document_number  text not null,

  status           text not null default 'PENDING',
  eway_bill_number text,
  generated_at     timestamptz,
  valid_until      timestamptz,

  transport_mode   text,
  vehicle_number   text,
  transporter_id   text,
  transporter_name text,
  distance_km      integer,

  request_payload  jsonb,
  response_payload jsonb,
  error_message    text,
  attempt_count    integer not null default 0,

  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       uuid,

  constraint eway_document_key unique (dealer_id, document_type, document_id),
  constraint eway_number_key   unique (eway_bill_number),
  constraint eway_type_check   check (document_type in ('SALE', 'SERVICE_INVOICE', 'TRANSFER')),
  constraint eway_status_check check (status in ('PENDING', 'GENERATED', 'FAILED', 'CANCELLED', 'EXPIRED')),
  constraint eway_mode_check   check (transport_mode is null or transport_mode in ('ROAD', 'RAIL', 'AIR', 'SHIP')),
  constraint eway_generated_check check (status <> 'GENERATED' or eway_bill_number is not null)
);

create index eway_status_idx   on public.eway_bills (dealer_id, status);
create index eway_document_idx on public.eway_bills (document_type, document_id);

-- Retry bookkeeping belongs to the database, not the caller.
create or replace function app.einvoice_attempt()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status
     and new.status in ('GENERATED', 'FAILED') then
    new.attempt_count := old.attempt_count + 1;
    new.last_attempt_at := now();
  end if;
  return new;
end;
$$;

create trigger einvoice_attempt before update on public.einvoices
  for each row execute function app.einvoice_attempt();

create trigger ar_set_updated_at before update on public.accounting_rules
  for each row execute function app.set_updated_at();
create trigger einvoices_set_updated_at before update on public.einvoices
  for each row execute function app.set_updated_at();
create trigger eway_set_updated_at before update on public.eway_bills
  for each row execute function app.set_updated_at();

create trigger ar_audit after insert or update or delete on public.accounting_rules
  for each row execute function app.audit_trigger();

alter table public.accounting_rules enable row level security;
alter table public.einvoices        enable row level security;
alter table public.eway_bills       enable row level security;

create policy ar_select on public.accounting_rules for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.coa.view')));
create policy ar_write on public.accounting_rules for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.coa.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.coa.manage')));

create policy einvoices_select on public.einvoices for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('gst.summary.view')));
create policy einvoices_write on public.einvoices for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('gst.einvoice.generate') or app.has_permission('gst.einvoice.retry'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy eway_select on public.eway_bills for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('gst.summary.view')));
create policy eway_write on public.eway_bills for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('gst.ewaybill.generate')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('gst.ewaybill.generate')));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update, delete on public.accounting_rules to authenticated';
    execute 'grant select, insert, update on public.einvoices, public.eway_bills to authenticated';
    execute 'grant all on public.accounting_rules, public.einvoices, public.eway_bills to service_role';
    execute 'grant execute on function public.resolve_account(uuid, text, text, text, uuid) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0025_posting_engine.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0025 — The posting engine
-- =============================================================================
-- Spec §21, §22, §48, §49, §50. The most important code in the product.
--
-- Spec §48 lists thirteen steps a vehicle sale must perform, and ends: "If any
-- critical step fails, rollback the transaction. Never create an invoice without
-- its accounting/inventory effects being consistent."
--
-- That guarantee cannot be made from application code talking to PostgREST: each
-- REST call is its own transaction, so a crash between "create invoice" and
-- "post journal" leaves the books wrong. So the whole sequence lives in one
-- PL/pgSQL function and runs in one transaction.
--
-- These are SECURITY INVOKER, so RLS still applies to every table they touch —
-- the posting engine has no more reach than the user who called it.
--
-- Rollback: drop the functions below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- app.post_journal() — the single entry point to the ledger
-- -----------------------------------------------------------------------------
-- Every module posts through this. Lines arrive as JSONB:
--   [{"account_id": "...", "debit": 100, "credit": 0, "narration": "...",
--     "party_type": "CUSTOMER", "party_id": "..."}]
--
-- Rejects an unbalanced set before writing anything, so a caller cannot leave a
-- half-built draft behind on failure.
-- -----------------------------------------------------------------------------
create or replace function app.post_journal(
  p_dealer_id       uuid,
  p_branch_id       uuid,
  p_entry_date      date,
  p_source_module   text,
  p_narration       text,
  p_lines           jsonb,
  p_source_document_type text default null,
  p_source_document_id   uuid default null,
  p_idempotency_key      text default null,
  -- Reversal linkage is supplied at creation, not stamped afterwards: the entry
  -- is POSTED by the time this function returns, and a posted journal is
  -- immutable (spec §23). There is no later moment to write it.
  p_reversal_of_id       uuid default null,
  p_reversal_reason      text default null
)
returns uuid
language plpgsql
as $$
declare
  v_entry_id  uuid;
  v_number    text;
  v_year      text;
  v_period_id uuid;
  v_debit     numeric(18, 4) := 0;
  v_credit    numeric(18, 4) := 0;
  v_line      jsonb;
  v_index     smallint := 0;
  v_existing  uuid;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    raise exception 'A journal needs at least two lines.'
      using errcode = 'check_violation';
  end if;

  -- Idempotency (spec §50): a repeated submission returns the original entry
  -- rather than posting a second one.
  if p_idempotency_key is not null then
    select id into v_existing
      from public.journal_entries
     where dealer_id = p_dealer_id and idempotency_key = p_idempotency_key;
    if v_existing is not null then
      return v_existing;
    end if;
  end if;

  -- Balance before touching anything.
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_debit  := v_debit  + coalesce((v_line ->> 'debit')::numeric, 0);
    v_credit := v_credit + coalesce((v_line ->> 'credit')::numeric, 0);
  end loop;

  if round(v_debit, 4) <> round(v_credit, 4) then
    raise exception 'Journal does not balance: debit % <> credit %.', v_debit, v_credit
      using errcode = 'check_violation',
            hint = 'Spec §22: total debit must equal total credit.';
  end if;

  v_year   := app.financial_year_token(p_dealer_id, p_entry_date);
  v_number := app.next_document_number(p_dealer_id, null, 'JOURNAL', v_year);

  select id into v_period_id
    from public.accounting_periods
   where dealer_id = p_dealer_id
     and p_entry_date between start_date and end_date
   limit 1;

  -- An entry dated into a closed period must not post (spec §44).
  if v_period_id is not null then
    if (select status from public.accounting_periods where id = v_period_id) <> 'OPEN' then
      raise exception 'The accounting period covering % is closed.', p_entry_date
        using errcode = 'insufficient_privilege';
    end if;
  end if;

  insert into public.journal_entries
    (dealer_id, branch_id, entry_number, entry_date, period_id, source_module,
     source_document_type, source_document_id, narration, idempotency_key,
     reversal_of_id, reversal_reason, created_by)
  values
    (p_dealer_id, p_branch_id, v_number, p_entry_date, v_period_id, p_source_module,
     p_source_document_type, p_source_document_id, p_narration, p_idempotency_key,
     p_reversal_of_id, p_reversal_reason, auth.uid())
  returning id into v_entry_id;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_index := v_index + 1;

    if (v_line ->> 'account_id') is null then
      raise exception 'Journal line % has no account. Check the accounting rules for this event.', v_index
        using errcode = 'check_violation',
              hint = 'Spec §22: accounts are resolved from accounting_rules, never hard-coded.';
    end if;

    insert into public.journal_entry_lines
      (journal_entry_id, dealer_id, line_number, account_id, branch_id,
       debit, credit, narration, party_type, party_id)
    values
      (v_entry_id, p_dealer_id, v_index, (v_line ->> 'account_id')::uuid, p_branch_id,
       coalesce((v_line ->> 'debit')::numeric, 0),
       coalesce((v_line ->> 'credit')::numeric, 0),
       v_line ->> 'narration',
       v_line ->> 'party_type',
       (v_line ->> 'party_id')::uuid);
  end loop;

  -- The trigger in 0007 recomputes totals from the lines and refuses to post
  -- anything unbalanced, so this is the second, independent check.
  update public.journal_entries set status = 'POSTED', posted_by = auth.uid()
   where id = v_entry_id;

  return v_entry_id;
end;
$$;

comment on function app.post_journal(uuid, uuid, date, text, text, jsonb, text, uuid, text, uuid, text) is
  'The single entry point to the ledger (spec §21, §60.18). Balances, numbers, '
  'and posts one journal atomically. Idempotent when given a key (spec §50).';

-- -----------------------------------------------------------------------------
-- app.reverse_journal() — the only way to undo a posting (spec §23)
-- -----------------------------------------------------------------------------
create or replace function app.reverse_journal(
  p_journal_entry_id uuid,
  p_reason           text,
  p_reversal_date    date default current_date
)
returns uuid
language plpgsql
as $$
declare
  v_original public.journal_entries;
  v_lines    jsonb;
  v_new_id   uuid;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reversal requires a reason.'
      using errcode = 'check_violation',
            hint = 'Spec §23: every reversal records reason, user, timestamp and reference.';
  end if;

  select * into v_original from public.journal_entries where id = p_journal_entry_id;

  if v_original.id is null then
    raise exception 'Journal entry not found.' using errcode = 'no_data_found';
  end if;
  if v_original.status <> 'POSTED' then
    raise exception 'Only a POSTED journal can be reversed; this one is %.', v_original.status
      using errcode = 'check_violation';
  end if;

  -- The mirror image: every debit becomes a credit and vice versa.
  select jsonb_agg(jsonb_build_object(
           'account_id', l.account_id,
           'debit',      l.credit,
           'credit',     l.debit,
           'narration',  coalesce(l.narration, '') || ' (reversal)',
           'party_type', l.party_type,
           'party_id',   l.party_id
         ) order by l.line_number)
    into v_lines
    from public.journal_entry_lines l
   where l.journal_entry_id = p_journal_entry_id;

  v_new_id := app.post_journal(
    v_original.dealer_id, v_original.branch_id, p_reversal_date,
    v_original.source_module,
    'Reversal of ' || v_original.entry_number || ' — ' || p_reason,
    v_lines,
    v_original.source_document_type, v_original.source_document_id,
    null,
    p_journal_entry_id, p_reason
  );

  -- Marking the original reversed is the one edit a posted journal permits.
  update public.journal_entries
     set status = 'REVERSED', reversed_by_id = v_new_id, reversal_reason = p_reason
   where id = p_journal_entry_id;

  return v_new_id;
end;
$$;

comment on function app.reverse_journal(uuid, text, date) is
  'Posts the mirror image of a journal and marks the original REVERSED (spec §23). '
  'The only sanctioned way to undo a posting.';

-- -----------------------------------------------------------------------------
-- app.require_account() — resolve or fail
-- -----------------------------------------------------------------------------
-- Posting must never guess. An unconfigured mapping puts the entry in the wrong
-- place, which is harder to find and fix than a refusal to post.
-- -----------------------------------------------------------------------------
create or replace function app.require_account(
  p_dealer_id uuid,
  p_module    text,
  p_event     text,
  p_component text,
  p_branch_id uuid
)
returns uuid
language plpgsql
stable
as $$
declare
  v_id uuid;
begin
  v_id := public.resolve_account(p_dealer_id, p_module, p_event, p_component, p_branch_id);
  if v_id is null then
    raise exception 'No accounting rule for %/%/%. Configure it before posting.',
      p_module, p_event, p_component
      using errcode = 'no_data_found',
            hint = 'Spec §22: account mapping is configuration, not code.';
  end if;
  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.post_vehicle_sale() — spec §48, all thirteen steps, one transaction
-- -----------------------------------------------------------------------------
create or replace function public.post_vehicle_sale(
  p_sale_id uuid,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_sale    public.sales;
  v_vehicle public.vehicles;
  v_lines   jsonb := '[]'::jsonb;
  v_entry   uuid;
  v_account uuid;
  v_line    record;
  v_cogs    numeric(18, 4) := 0;
begin
  -- Step 3: lock the sale and the vehicle. A second concurrent post blocks here
  -- and then fails the status check below (spec §49).
  select * into v_sale from public.sales where id = p_sale_id for update;

  if v_sale.id is null then
    raise exception 'Sale not found.' using errcode = 'no_data_found';
  end if;

  if v_sale.status <> 'APPROVED' then
    raise exception 'Sale % is % — only an APPROVED sale can be posted.', v_sale.invoice_number, v_sale.status
      using errcode = 'check_violation',
            hint = 'Spec §19: posting happens only after accounts approval.';
  end if;

  select * into v_vehicle from public.vehicles where id = v_sale.vehicle_id for update;

  if v_vehicle.status not in ('IN_STOCK', 'BOOKED') then
    raise exception 'Vehicle % is % and cannot be sold.', v_vehicle.chassis_no, v_vehicle.status
      using errcode = 'check_violation';
  end if;

  -- Step 8–10: build the journal from the invoice lines, resolving every account
  -- through accounting_rules.
  v_lines := v_lines || jsonb_build_array(jsonb_build_object(
    'account_id', app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'RECEIVABLE', v_sale.branch_id),
    'debit', v_sale.total_amount, 'credit', 0,
    'narration', 'Sale ' || v_sale.invoice_number,
    'party_type', 'CUSTOMER', 'party_id', v_sale.customer_id
  ));

  for v_line in
    select line_type, sum(taxable_value) taxable, sum(cost_amount) cost
      from public.sale_lines where sale_id = p_sale_id
     group by line_type
  loop
    if v_line.taxable > 0 then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'account_id', app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', v_line.line_type, v_sale.branch_id),
        'debit', 0, 'credit', v_line.taxable,
        'narration', v_line.line_type || ' revenue'
      ));
    end if;
    v_cogs := v_cogs + coalesce(v_line.cost, 0);
  end loop;

  if v_sale.cgst_amount > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'CGST', v_sale.branch_id),
      'debit', 0, 'credit', v_sale.cgst_amount, 'narration', 'Output CGST'));
  end if;
  if v_sale.sgst_amount > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'SGST', v_sale.branch_id),
      'debit', 0, 'credit', v_sale.sgst_amount, 'narration', 'Output SGST'));
  end if;
  if v_sale.igst_amount > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'IGST', v_sale.branch_id),
      'debit', 0, 'credit', v_sale.igst_amount, 'narration', 'Output IGST'));
  end if;

  -- Step 11: inventory relief and COGS recognition (spec §22).
  if v_cogs > 0 then
    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('account_id', app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'COGS', v_sale.branch_id),
                         'debit', v_cogs, 'credit', 0, 'narration', 'Cost of goods sold'),
      jsonb_build_object('account_id', app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'INVENTORY', v_sale.branch_id),
                         'debit', 0, 'credit', v_cogs, 'narration', 'Inventory relief'));
  end if;

  -- Steps 10 and 13: post atomically. Unbalanced input raises and the whole
  -- function rolls back, leaving neither invoice status nor stock changed.
  v_entry := app.post_journal(
    v_sale.dealer_id, v_sale.branch_id, v_sale.invoice_date, 'SALES',
    'Vehicle sale ' || v_sale.invoice_number, v_lines,
    'SALE', v_sale.id,
    coalesce(p_idempotency_key, 'sale:' || v_sale.id::text)
  );

  -- Step 12: vehicle status.
  update public.vehicles
     set status = 'SOLD_PENDING_DELIVERY', sale_id = v_sale.id, updated_by = auth.uid()
   where id = v_sale.vehicle_id;

  update public.sales
     set status = 'POSTED', journal_entry_id = v_entry, posted_by = auth.uid()
   where id = p_sale_id;

  return v_entry;
end;
$$;

comment on function public.post_vehicle_sale(uuid, text) is
  'Posts an approved vehicle sale: journal, inventory relief, COGS and vehicle '
  'status, in one transaction (spec §48). Any failure rolls the whole thing back.';

-- -----------------------------------------------------------------------------
-- public.consume_fitting_stock() — allocate, issue and record the source (§31)
-- -----------------------------------------------------------------------------
create or replace function public.consume_fitting_stock(
  p_sale_id   uuid,
  p_item_id   uuid,
  p_quantity  numeric,
  p_unit_rate numeric
)
returns void
language plpgsql
as $$
declare
  v_sale  public.sales;
  v_alloc record;
  v_next  smallint;
  v_item  public.inventory_items;
begin
  select * into v_sale from public.sales where id = p_sale_id for update;
  if v_sale.status not in ('DRAFT', 'SUBMITTED') then
    raise exception 'Fittings can only be added while the sale is being prepared.'
      using errcode = 'check_violation';
  end if;

  select * into v_item from public.inventory_items where id = p_item_id;

  select coalesce(max(line_number), 0) into v_next from public.sale_lines where sale_id = p_sale_id;

  -- One invoice line per source, so LOCAL and COMPANY consumption is visible on
  -- the document rather than hidden behind a single total (spec §31).
  for v_alloc in select * from public.allocate_stock(p_item_id, v_sale.branch_id, p_quantity) loop
    if v_alloc.source = 'SHORTFALL' then
      raise exception 'Insufficient stock for %: short by %.', v_item.name, v_alloc.quantity
        using errcode = 'check_violation',
              hint = 'Spec §31: block or route for approval rather than overselling.';
    end if;

    v_next := v_next + 1;

    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, item_id,
       quantity, unit_rate, taxable_value, total_amount,
       unit_cost, cost_amount, stock_source)
    values
      (p_sale_id, v_sale.dealer_id, v_next, 'FITTING',
       v_item.name || ' (' || v_alloc.source || ')', p_item_id,
       v_alloc.quantity, p_unit_rate, round(p_unit_rate * v_alloc.quantity, 4),
       round(p_unit_rate * v_alloc.quantity, 4),
       v_alloc.unit_cost, round(v_alloc.unit_cost * v_alloc.quantity, 4), v_alloc.source);

    insert into public.inventory_transactions
      (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
       reference_type, reference_id, reference_number, narration, created_by)
    values
      (v_sale.dealer_id, v_sale.branch_id, p_item_id, v_alloc.source, 'SALE',
       -v_alloc.quantity, v_alloc.unit_cost, 'SALE', p_sale_id, v_sale.invoice_number,
       'Fitted to ' || v_sale.invoice_number, auth.uid());
  end loop;
end;
$$;

comment on function public.consume_fitting_stock(uuid, uuid, numeric, numeric) is
  'Allocates LOCAL before COMPANY stock, writes one invoice line per source and '
  'one ledger row per source (spec §31: never hide the source).';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function app.post_journal(uuid, uuid, date, text, text, jsonb, text, uuid, text, uuid, text) to authenticated';
    execute 'grant execute on function app.require_account(uuid, text, text, text, uuid) to authenticated';
    execute 'grant execute on function app.reverse_journal(uuid, text, date) to authenticated';
    execute 'grant execute on function public.post_vehicle_sale(uuid, text) to authenticated';
    execute 'grant execute on function public.consume_fitting_stock(uuid, uuid, numeric, numeric) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0026_reports.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0026 — Reporting functions
-- =============================================================================
-- Spec §41, §43. Reports are database functions rather than application queries
-- for two reasons: aggregation belongs where the rows are, and SECURITY INVOKER
-- means RLS scopes every report to the caller's dealer and branches without the
-- report itself having to remember to filter (spec §43, "Consolidated reporting
-- must respect tenant isolation").
--
-- Rollback: drop the functions below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Trial balance — spec §41
-- -----------------------------------------------------------------------------
create or replace function public.trial_balance(
  p_as_on     date default current_date,
  p_branch_id uuid default null
)
returns table (
  account_id     uuid,
  account_code   text,
  account_name   text,
  account_type   text,
  debit_balance  numeric(18, 4),
  credit_balance numeric(18, 4)
)
language sql
stable
as $$
  select b.account_id, b.account_code, b.account_name, b.account_type,
         -- A balance shows on the side its account normally sits on; a negative
         -- balance flips to the other column rather than showing as a minus.
         case when b.closing_balance >= 0 and b.normal_balance = 'DEBIT'  then b.closing_balance
              when b.closing_balance <  0 and b.normal_balance = 'CREDIT' then -b.closing_balance
              else 0 end,
         case when b.closing_balance >= 0 and b.normal_balance = 'CREDIT' then b.closing_balance
              when b.closing_balance <  0 and b.normal_balance = 'DEBIT'  then -b.closing_balance
              else 0 end
    from public.account_balances(date '1900-01-01', p_as_on, p_branch_id) b
   where b.closing_debit <> 0 or b.closing_credit <> 0
   order by b.account_code;
$$;

comment on function public.trial_balance(date, uuid) is
  'Trial balance as at a date (spec §41). Totals are guaranteed equal because the '
  'database refuses to post an unbalanced journal.';

-- -----------------------------------------------------------------------------
-- Profit and loss — spec §41
-- -----------------------------------------------------------------------------
create or replace function public.profit_and_loss(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  section      text,
  account_code text,
  account_name text,
  amount       numeric(18, 4)
)
language sql
stable
as $$
  select case when b.account_type = 'INCOME' then 'INCOME' else 'EXPENSE' end,
         b.account_code, b.account_name, b.period_movement
    from public.account_balances(p_from, p_to, p_branch_id) b
   where b.account_type in ('INCOME', 'EXPENSE')
     and b.period_movement <> 0
   order by 1 desc, b.account_code;
$$;

comment on function public.profit_and_loss(date, date, uuid) is
  'Income and expense movement for a period (spec §41). Balance-sheet accounts are '
  'excluded: they carry cumulative balances, not period results.';

-- -----------------------------------------------------------------------------
-- Balance sheet — spec §41
-- -----------------------------------------------------------------------------
create or replace function public.balance_sheet(
  p_as_on     date default current_date,
  p_branch_id uuid default null
)
returns table (
  section      text,
  account_code text,
  account_name text,
  amount       numeric(18, 4)
)
language sql
stable
as $$
  select b.account_type, b.account_code, b.account_name, b.closing_balance
    from public.account_balances(date '1900-01-01', p_as_on, p_branch_id) b
   where b.account_type in ('ASSET', 'LIABILITY', 'EQUITY')
     and b.closing_balance <> 0
  union all
  -- Retained result to date. Without it the sheet cannot balance, because income
  -- and expense have not yet been closed into equity.
  select 'EQUITY', 'RESULT', 'Profit / (loss) to date',
         coalesce(sum(case when b.account_type = 'INCOME' then b.closing_balance
                           else -b.closing_balance end), 0)
    from public.account_balances(date '1900-01-01', p_as_on, p_branch_id) b
   where b.account_type in ('INCOME', 'EXPENSE')
  order by 1, 2;
$$;

comment on function public.balance_sheet(date, uuid) is
  'Assets, liabilities and equity as at a date (spec §41), including the retained '
  'result so the statement balances.';

-- -----------------------------------------------------------------------------
-- Vehicle stock with ageing — spec §41
-- -----------------------------------------------------------------------------
create or replace function public.vehicle_stock_report(
  p_branch_id uuid default null
)
returns table (
  vehicle_id     uuid,
  chassis_no     text,
  engine_no      text,
  brand          text,
  model_name     text,
  variant_name   text,
  branch_name    text,
  status         text,
  stock_date     date,
  age_days       integer,
  age_bucket     text,
  purchase_cost  numeric(18, 4)
)
language sql
stable
as $$
  select v.id, v.chassis_no, v.engine_no, m.brand, m.name, vr.name, b.name,
         v.status, v.stock_date,
         (current_date - v.stock_date)::integer,
         case
           when current_date - v.stock_date <=  30 then '0-30'
           when current_date - v.stock_date <=  60 then '31-60'
           when current_date - v.stock_date <=  90 then '61-90'
           when current_date - v.stock_date <= 180 then '91-180'
           else '180+'
         end,
         v.purchase_cost
    from public.vehicles v
    join public.vehicle_models m on m.id = v.model_id
    left join public.vehicle_variants vr on vr.id = v.variant_id
    join public.branches b on b.id = v.branch_id
   where v.status = 'IN_STOCK'
     and (p_branch_id is null or v.branch_id = p_branch_id)
   order by v.stock_date;
$$;

comment on function public.vehicle_stock_report(uuid) is
  'Chassis-level stock with ageing buckets (spec §41). Rows, not quantities.';

-- -----------------------------------------------------------------------------
-- Accessory and spare stock, LOCAL/COMPANY split — spec §28
-- -----------------------------------------------------------------------------
create or replace function public.inventory_stock_report(
  p_branch_id uuid default null,
  p_item_type text default null
)
returns table (
  item_id       uuid,
  item_code     text,
  item_name     text,
  item_type     text,
  branch_name   text,
  local_qty     numeric(14, 3),
  company_qty   numeric(14, 3),
  total_qty     numeric(14, 3),
  local_value   numeric(18, 4),
  company_value numeric(18, 4),
  total_value   numeric(18, 4)
)
language sql
stable
as $$
  select i.id, i.item_code, i.name, i.item_type, b.name,
         coalesce(sum(s.quantity)    filter (where s.source = 'LOCAL'), 0),
         coalesce(sum(s.quantity)    filter (where s.source = 'COMPANY'), 0),
         coalesce(sum(s.quantity), 0),
         coalesce(sum(s.stock_value) filter (where s.source = 'LOCAL'), 0),
         coalesce(sum(s.stock_value) filter (where s.source = 'COMPANY'), 0),
         coalesce(sum(s.stock_value), 0)
    from public.inventory_stock s
    join public.inventory_items i on i.id = s.item_id
    join public.branches b on b.id = s.branch_id
   where (p_branch_id is null or s.branch_id = p_branch_id)
     and (p_item_type is null or i.item_type = p_item_type)
   group by i.id, i.item_code, i.name, i.item_type, b.name
  having coalesce(sum(s.quantity), 0) <> 0
   order by i.item_code;
$$;

comment on function public.inventory_stock_report(uuid, text) is
  'Stock with the LOCAL / COMPANY split spec §28 requires displayed side by side.';

-- -----------------------------------------------------------------------------
-- Sales summary with margin — spec §41
-- -----------------------------------------------------------------------------
-- Margin is returned here; withholding it from unauthorised roles is the service
-- layer's job, because RLS cannot hide a column, only a row.
-- -----------------------------------------------------------------------------
create or replace function public.sales_summary(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null,
  p_group_by  text default 'MODEL'
)
returns table (
  group_key    text,
  group_label  text,
  unit_count   bigint,
  gross_amount numeric(18, 4),
  tax_amount   numeric(18, 4),
  cost_amount  numeric(18, 4),
  margin       numeric(18, 4)
)
language sql
stable
as $$
  select
    case p_group_by
      when 'BRANCH'   then b.id::text
      when 'EMPLOYEE' then coalesce(e.id::text, 'none')
      when 'DAY'      then s.invoice_date::text
      else m.id::text
    end,
    case p_group_by
      when 'BRANCH'   then b.name
      when 'EMPLOYEE' then coalesce(e.name, 'Unassigned')
      when 'DAY'      then to_char(s.invoice_date, 'DD Mon YYYY')
      else m.brand || ' ' || m.name
    end,
    count(*),
    sum(s.total_amount),
    sum(s.cgst_amount + s.sgst_amount + s.igst_amount + s.cess_amount),
    sum(s.total_cost),
    sum(s.taxable_value - s.total_cost)
  from public.sales s
  join public.vehicles v on v.id = s.vehicle_id
  join public.vehicle_models m on m.id = v.model_id
  join public.branches b on b.id = s.branch_id
  left join public.employees e on e.id = s.sales_executive_id
 where s.status in ('POSTED', 'DELIVERED')
   and s.invoice_date between p_from and p_to
   and (p_branch_id is null or s.branch_id = p_branch_id)
 group by 1, 2
 order by 4 desc;
$$;

comment on function public.sales_summary(date, date, uuid, text) is
  'Sales grouped by model, branch, employee or day (spec §41). Includes cost and '
  'margin; the service layer strips those for roles without permission (spec §52).';

-- -----------------------------------------------------------------------------
-- GST output summary — spec §41
-- -----------------------------------------------------------------------------
create or replace function public.gst_summary(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  hsn_code      text,
  description   text,
  taxable_value numeric(18, 4),
  cgst_amount   numeric(18, 4),
  sgst_amount   numeric(18, 4),
  igst_amount   numeric(18, 4),
  total_tax     numeric(18, 4),
  document_count bigint
)
language sql
stable
as $$
  -- Vehicle sales and service invoices carry the same tax shape, so they are
  -- unioned and grouped by HSN rather than reported separately.
  with lines as (
    select coalesce(l.hsn_code, 'UNSPECIFIED') hsn, l.taxable_value,
           l.cgst_amount, l.sgst_amount, l.igst_amount, s.id doc
      from public.sale_lines l
      join public.sales s on s.id = l.sale_id
     where s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select coalesce(l.hsn_code, 'UNSPECIFIED'), l.taxable_value,
           l.cgst_amount, l.sgst_amount, l.igst_amount, si.id
      from public.service_lines l
      join public.service_invoices si on si.id = l.invoice_id
     where si.status = 'POSTED'
       and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
  )
  select lines.hsn,
         coalesce(max(h.description), ''),
         sum(lines.taxable_value), sum(lines.cgst_amount), sum(lines.sgst_amount),
         sum(lines.igst_amount),
         sum(lines.cgst_amount + lines.sgst_amount + lines.igst_amount),
         count(distinct lines.doc)
    from lines
    left join public.hsn_codes h on h.code = lines.hsn
   group by lines.hsn
   order by lines.hsn;
$$;

comment on function public.gst_summary(date, date, uuid) is
  'HSN-wise output tax for a period (spec §41). Reads the tax stored on each line, '
  'not the current tax master, so historical figures never move (spec §16).';

-- -----------------------------------------------------------------------------
-- Customer ledger — spec §41
-- -----------------------------------------------------------------------------
create or replace function public.customer_ledger(
  p_customer_id uuid,
  p_from        date,
  p_to          date
)
returns table (
  entry_date    date,
  entry_number  text,
  narration     text,
  debit         numeric(18, 4),
  credit        numeric(18, 4),
  running_balance numeric(18, 4)
)
language sql
stable
as $$
  -- The subsidiary ledger is derived from party-tagged journal lines, so it
  -- reconciles to the receivable control account by construction.
  select je.entry_date, je.entry_number, coalesce(l.narration, je.narration),
         l.debit, l.credit,
         sum(l.debit - l.credit) over (order by je.entry_date, je.entry_number, l.line_number
                                       rows between unbounded preceding and current row)
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.party_type = 'CUSTOMER'
     and l.party_id = p_customer_id
     and je.status in ('POSTED', 'REVERSED')
     and je.entry_date between p_from and p_to
   order by je.entry_date, je.entry_number, l.line_number;
$$;

comment on function public.customer_ledger(uuid, date, date) is
  'Customer running account from the general ledger (spec §41), so the subsidiary '
  'ledger and the control account can never disagree.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.trial_balance(date, uuid) to authenticated';
    execute 'grant execute on function public.profit_and_loss(date, date, uuid) to authenticated';
    execute 'grant execute on function public.balance_sheet(date, uuid) to authenticated';
    execute 'grant execute on function public.vehicle_stock_report(uuid) to authenticated';
    execute 'grant execute on function public.inventory_stock_report(uuid, text) to authenticated';
    execute 'grant execute on function public.sales_summary(date, date, uuid, text) to authenticated';
    execute 'grant execute on function public.gst_summary(date, date, uuid) to authenticated';
    execute 'grant execute on function public.customer_ledger(uuid, date, date) to authenticated';
  end if;
end;
$$;


commit;
