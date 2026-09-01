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
