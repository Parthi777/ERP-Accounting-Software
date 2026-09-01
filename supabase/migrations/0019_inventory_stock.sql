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
