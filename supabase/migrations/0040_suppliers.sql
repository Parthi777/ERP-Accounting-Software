-- =============================================================================
-- 0040 — Supplier master
-- =============================================================================
-- Spec §24, §41, §44.
--
-- The chart of accounts has carried "Supplier Payables" (2200) since the first
-- seed, journal_entry_lines.party_type has always accepted 'SUPPLIER', and the
-- CASH/BANK PAYMENT rules post to 2200 — but there has never been a supplier
-- table to point party_id at, so the payable has only ever been a single lump
-- with no subsidiary detail behind it. Spec §41 asks for a supplier ledger; this
-- is the record it needs.
--
-- Dealer-scoped, not branch-scoped: a supplier deals with the dealer, and any
-- branch may buy from them. Modelled on public.customers (0013), including the
-- self-provisioning code trigger — a supplier code is an identifier, not a
-- financial document, so issuing one must never fail for want of configuration.
--
-- Rollback: drop table public.suppliers; drop function app.suppliers_assign_code();
--           delete from public.document_sequences where doc_type = 'SUPPLIER';
-- =============================================================================

create table public.suppliers (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null references public.dealers (id) on delete restrict,

  -- Mandatory, dealer-unique, server-issued (spec §60.6, as for customers).
  supplier_code     text not null,

  name              text not null,
  supplier_type     text not null default 'GOODS',

  contact_person    text,
  mobile            text,
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

  -- Payment terms, for an ageing view of the payable.
  credit_days       smallint not null default 0,

  notes             text,
  status            text not null default 'ACTIVE',

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid,
  updated_by        uuid,

  constraint suppliers_dealer_code_key unique (dealer_id, supplier_code),
  -- Load-bearing: every composite tenant foreign key that ever points at a
  -- supplier depends on this, exactly as customers_id_dealer_key does.
  constraint suppliers_id_dealer_key   unique (id, dealer_id),

  constraint suppliers_type_check   check (supplier_type in ('GOODS', 'SERVICE', 'OEM')),
  constraint suppliers_status_check check (status in ('ACTIVE', 'INACTIVE', 'BLOCKED')),
  constraint suppliers_name_check   check (length(btrim(name)) between 2 and 150),
  constraint suppliers_mobile_check check (mobile is null or mobile ~ '^[6-9][0-9]{9}$'),
  constraint suppliers_alt_mobile_check check (
    alternate_mobile is null or alternate_mobile ~ '^[6-9][0-9]{9}$'
  ),
  constraint suppliers_email_check check (
    email is null or email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[a-zA-Z]{2,}$'
  ),
  constraint suppliers_gstin_check check (
    gstin is null or gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[0-9A-Z]{1}Z[0-9A-Z]{1}$'
  ),
  constraint suppliers_pan_check     check (pan is null or pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  constraint suppliers_pincode_check check (pincode is null or pincode ~ '^[1-9][0-9]{5}$'),
  constraint suppliers_credit_days_check check (credit_days between 0 and 365)
);

comment on table public.suppliers is
  'Supplier master (spec §41, §44). Dealer-scoped: a supplier serves every branch. '
  'party_id on a journal line tagged party_type = ''SUPPLIER'' points here.';
comment on column public.suppliers.supplier_code is
  'Auto-generated, dealer-unique, issued server-side. Never supplied by the client.';

-- The same GSTIN twice within a dealer is a duplicate record. Enforced only for
-- active suppliers, so a blocked record does not prevent re-registering later.
create unique index suppliers_dealer_gstin_key
  on public.suppliers (dealer_id, gstin)
  where gstin is not null and status = 'ACTIVE';

-- -----------------------------------------------------------------------------
-- Supplier code assignment
-- -----------------------------------------------------------------------------
-- Self-provisioning, like app.customers_assign_code(). A financial document
-- whose sequence is missing should fail loudly; an identifier should not, or a
-- newly provisioned dealer cannot record its first supplier without setup.
-- -----------------------------------------------------------------------------
create or replace function app.suppliers_assign_code()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_year text;
begin
  if new.supplier_code is not null and btrim(new.supplier_code) <> '' then
    return new;  -- an explicit code (data migration) is respected
  end if;

  v_year := app.financial_year_token(new.dealer_id, coalesce(new.created_at::date, current_date));

  insert into public.document_sequences (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
  values (new.dealer_id, null, 'SUPPLIER', v_year, 'SUPP', 6)
  on conflict on constraint document_sequences_scope_key do nothing;

  new.supplier_code := app.next_document_number(new.dealer_id, null, 'SUPPLIER', v_year);
  return new;
end;
$$;

create trigger suppliers_assign_code
  before insert on public.suppliers
  for each row execute function app.suppliers_assign_code();

create trigger suppliers_set_updated_at
  before update on public.suppliers
  for each row execute function app.set_updated_at();

create trigger suppliers_audit
  after insert or update or delete on public.suppliers
  for each row execute function app.audit_trigger();

-- -----------------------------------------------------------------------------
-- Row Level Security
-- -----------------------------------------------------------------------------
alter table public.suppliers enable row level security;

create policy suppliers_select on public.suppliers
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and (app.has_permission('masters.suppliers.view')
             or app.has_permission('accounting.ledgers.view')))
  );

create policy suppliers_insert on public.suppliers
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('masters.suppliers.manage'))
  );

create policy suppliers_update on public.suppliers
  for update to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('masters.suppliers.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('masters.suppliers.manage'))
  );

-- No DELETE policy. A supplier with postings behind them must never vanish;
-- set status to INACTIVE or BLOCKED instead.

-- -----------------------------------------------------------------------------
-- Indexes
-- -----------------------------------------------------------------------------
create index suppliers_dealer_name_idx   on public.suppliers (dealer_id, lower(name));
create index suppliers_dealer_status_idx on public.suppliers (dealer_id, status);
create index suppliers_mobile_idx        on public.suppliers (dealer_id, mobile) where mobile is not null;
create index suppliers_created_idx       on public.suppliers (dealer_id, created_at desc);

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.suppliers to authenticated';
    execute 'grant all on public.suppliers to service_role';
  end if;
end;
$$;
