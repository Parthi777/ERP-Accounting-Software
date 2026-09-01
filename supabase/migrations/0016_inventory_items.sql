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
