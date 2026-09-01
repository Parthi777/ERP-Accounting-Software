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
