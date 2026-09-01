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
