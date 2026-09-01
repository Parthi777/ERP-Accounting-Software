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
