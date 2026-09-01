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
