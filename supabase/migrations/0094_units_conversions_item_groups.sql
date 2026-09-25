-- =============================================================================
-- 0094 — Units, pack conversion, item groups
-- =============================================================================
-- BUSY requirements F14, F15, F18 (docs/accounting-feature-gap-analysis.md).
--
-- F15  Units were a fixed check list on inventory_items.uom. They become a
--      master, each with its decimal places and the GST unit quantity code
--      (UQC) returns report it under; the item's uom now references it.
-- F18  An item is stocked in one unit and bought in others: "1 BOX = 12 NOS".
--      item_unit_conversions holds the factor per item. A purchase order line
--      entered in packs is stored in the base unit — quantity × factor, rate
--      ÷ factor — with what was entered kept beside it, so stock, receipts and
--      bills never deal in two units.
-- F14  Item groups: a managed, optionally nested list. The free-text category
--      stays; each distinct category becomes a group and items are linked.
--
-- Rollback: drop item_unit_conversions, item_groups, the new columns and the
--           units foreign key; restore inventory_items_uom_check and 0092's
--           create_purchase_order.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Units
-- -----------------------------------------------------------------------------
create table public.units (
  code      text primary key,
  name      text not null,
  decimals  smallint not null default 0,
  gst_uqc   text not null,
  constraint units_code_check check (code ~ '^[A-Z]{2,8}$'),
  constraint units_decimals_check check (decimals between 0 and 3),
  constraint units_uqc_check check (gst_uqc ~ '^[A-Z]{3}$')
);

comment on table public.units is
  'Units of measure (F15) with their decimal places and GST unit quantity code. Shared by every dealer.';

insert into public.units (code, name, decimals, gst_uqc) values
  ('NOS',  'Numbers',   0, 'NOS'),
  ('PCS',  'Pieces',    0, 'PCS'),
  ('SET',  'Sets',      0, 'SET'),
  ('PAIR', 'Pairs',     0, 'PRS'),
  ('BOX',  'Boxes',     0, 'BOX'),
  ('DOZ',  'Dozens',    0, 'DOZ'),
  ('LTR',  'Litres',    3, 'LTR'),
  ('KG',   'Kilograms', 3, 'KGS'),
  ('MTR',  'Metres',    3, 'MTR')
on conflict (code) do nothing;

alter table public.units enable row level security;
create policy units_select on public.units for select to authenticated using (true);
create policy units_write on public.units for all to authenticated
  using (app.is_platform_admin()) with check (app.is_platform_admin());

alter table public.inventory_items drop constraint inventory_items_uom_check;
alter table public.inventory_items
  add constraint inventory_items_uom_fkey foreign key (uom) references public.units (code);

-- -----------------------------------------------------------------------------
-- 2. Pack conversions
-- -----------------------------------------------------------------------------
create table public.item_unit_conversions (
  id         uuid primary key default gen_random_uuid(),
  dealer_id  uuid not null references public.dealers (id) on delete cascade,
  item_id    uuid not null,
  unit_code  text not null references public.units (code),
  factor     numeric(14, 4) not null,
  created_at timestamptz not null default now(),
  created_by uuid,

  constraint iuc_item_unit_key unique (item_id, unit_code),
  constraint iuc_item_tenant_fkey
    foreign key (item_id, dealer_id) references public.inventory_items (id, dealer_id) on delete cascade,
  constraint iuc_factor_check check (factor > 0)
);

comment on table public.item_unit_conversions is
  'How many base units one of this unit holds, per item (F18): 1 BOX = 12 NOS.';

-- The base unit itself is not a conversion.
create or replace function app.item_unit_conversions_guard()
returns trigger
language plpgsql
as $$
begin
  if new.unit_code = (select uom from public.inventory_items where id = new.item_id) then
    raise exception '% is this item''s own unit; a conversion is to another unit.', new.unit_code
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger item_unit_conversions_guard before insert or update on public.item_unit_conversions
  for each row execute function app.item_unit_conversions_guard();
create trigger item_unit_conversions_audit after insert or update or delete on public.item_unit_conversions
  for each row execute function app.audit_trigger();

alter table public.item_unit_conversions enable row level security;
create policy iuc_select on public.item_unit_conversions for select to authenticated
  using (app.is_platform_admin() or dealer_id = app.current_dealer_id());
create policy iuc_write on public.item_unit_conversions for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('inventory.items.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('inventory.items.manage')));

-- How many base units one p_unit of the item is: 1 for the base unit itself.
create or replace function app.unit_factor(p_item_id uuid, p_unit text)
returns numeric
language plpgsql
stable
as $$
declare
  v_base   text;
  v_factor numeric;
begin
  select uom into v_base from public.inventory_items where id = p_item_id;
  if p_unit is null or p_unit = v_base then
    return 1;
  end if;
  select factor into v_factor from public.item_unit_conversions where item_id = p_item_id and unit_code = p_unit;
  if v_factor is null then
    raise exception 'No conversion from % to % is set for this item.', p_unit, v_base
      using errcode = 'check_violation', hint = 'Add it on the item: how many ' || v_base || ' one ' || p_unit || ' holds.';
  end if;
  return v_factor;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. Item groups
-- -----------------------------------------------------------------------------
create table public.item_groups (
  id         uuid primary key default gen_random_uuid(),
  dealer_id  uuid not null references public.dealers (id) on delete cascade,
  name       text not null,
  parent_id  uuid,
  status     text not null default 'ACTIVE',
  created_at timestamptz not null default now(),
  created_by uuid,

  constraint item_groups_name_key unique (dealer_id, name),
  constraint item_groups_id_dealer_key unique (id, dealer_id),
  constraint item_groups_parent_tenant_fkey
    foreign key (parent_id, dealer_id) references public.item_groups (id, dealer_id),
  constraint item_groups_self_check check (parent_id is null or parent_id <> id),
  constraint item_groups_name_check check (length(btrim(name)) between 2 and 60),
  constraint item_groups_status_check check (status in ('ACTIVE', 'INACTIVE'))
);

comment on table public.item_groups is 'Groups of accessories and spares (F14), optionally nested.';

alter table public.inventory_items add column item_group_id uuid;
alter table public.inventory_items
  add constraint inventory_items_group_tenant_fkey
    foreign key (item_group_id, dealer_id) references public.item_groups (id, dealer_id);
create index inventory_items_group_idx on public.inventory_items (item_group_id) where item_group_id is not null;

create trigger item_groups_audit after insert or update or delete on public.item_groups
  for each row execute function app.audit_trigger();

alter table public.item_groups enable row level security;
create policy item_groups_select on public.item_groups for select to authenticated
  using (app.is_platform_admin() or dealer_id = app.current_dealer_id());
create policy item_groups_write on public.item_groups for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('inventory.items.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('inventory.items.manage')));

-- Each distinct category becomes a group, and its items join it.
insert into public.item_groups (dealer_id, name)
select distinct dealer_id, btrim(category)
  from public.inventory_items
 where length(btrim(coalesce(category, ''))) between 2 and 60
on conflict (dealer_id, name) do nothing;

update public.inventory_items i
   set item_group_id = g.id
  from public.item_groups g
 where g.dealer_id = i.dealer_id and g.name = btrim(i.category) and i.item_group_id is null;

-- -----------------------------------------------------------------------------
-- 4. Purchase orders entered in packs
-- -----------------------------------------------------------------------------
alter table public.purchase_order_lines
  add column entry_unit     text references public.units (code),
  add column entry_quantity numeric(14, 3),
  add column entry_rate     numeric(18, 4),
  add column entry_factor   numeric(14, 4) not null default 1;

comment on column public.purchase_order_lines.entry_unit is
  'The unit the line was ordered in, when not the base unit; quantity and unit_rate are in the base unit.';

create or replace function public.create_purchase_order(
  p_branch_id       uuid,
  p_supplier_id     uuid,
  p_lines           jsonb,
  p_order_date      date default current_date,
  p_expected_date   date default null,
  p_notes           text default null,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_id     uuid;
  v_line   jsonb;
  v_item   public.inventory_items;
  v_n      integer := 0;
  v_unit   text;
  v_factor numeric;
  v_qty    numeric;
  v_rate   numeric;
begin
  if v_dealer is null or not app.has_permission('purchases.create') then
    raise exception 'You may not raise purchase orders.' using errcode = 'insufficient_privilege';
  end if;
  if p_idempotency_key is not null then
    select id into v_id from public.purchase_orders
     where dealer_id = v_dealer and idempotency_key = p_idempotency_key;
    if v_id is not null then return v_id; end if;
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Add at least one item to the order.' using errcode = 'check_violation';
  end if;

  insert into public.purchase_orders
    (dealer_id, branch_id, supplier_id, order_date, expected_date, notes, idempotency_key, created_by)
  values
    (v_dealer, p_branch_id, p_supplier_id, coalesce(p_order_date, current_date), p_expected_date,
     nullif(btrim(p_notes), ''), p_idempotency_key, auth.uid())
  returning id into v_id;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_n := v_n + 1;
    select * into v_item from public.inventory_items
     where id = nullif(v_line ->> 'item_id', '')::uuid and dealer_id = v_dealer;
    if v_item.id is null then
      raise exception 'Line %: choose the item.', v_n using errcode = 'check_violation';
    end if;
    -- Ordered in packs (0094): stored in the base unit, the entry kept beside it.
    v_unit := nullif(v_line ->> 'unit', '');
    v_factor := app.unit_factor(v_item.id, v_unit);
    v_qty := (v_line ->> 'quantity')::numeric;
    v_rate := coalesce((v_line ->> 'unit_rate')::numeric, 0);
    insert into public.purchase_order_lines
      (purchase_order_id, dealer_id, line_number, line_type, item_id, source, description,
       quantity, unit_rate, entry_unit, entry_quantity, entry_rate, entry_factor,
       cgst_rate, sgst_rate, igst_rate)
    values
      (v_id, v_dealer, v_n, v_item.item_type, v_item.id, coalesce(nullif(v_line ->> 'source', ''), 'COMPANY'),
       coalesce(nullif(btrim(v_line ->> 'description'), ''), v_item.name)
         || case when v_factor <> 1 then ' (' || v_qty || ' ' || v_unit || ' × ' || v_factor || ' ' || v_item.uom || ')' else '' end,
       round(v_qty * v_factor, 3), round(v_rate / v_factor, 4),
       case when v_factor <> 1 then v_unit end, case when v_factor <> 1 then v_qty end,
       case when v_factor <> 1 then v_rate end, v_factor,
       coalesce((v_line ->> 'cgst_rate')::numeric, 0), coalesce((v_line ->> 'sgst_rate')::numeric, 0),
       coalesce((v_line ->> 'igst_rate')::numeric, 0));
  end loop;

  return v_id;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select on public.units to authenticated';
    execute 'grant select, insert, update, delete on public.item_unit_conversions, public.item_groups to authenticated';
    execute 'grant execute on function app.unit_factor(uuid, text) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant all on public.units, public.item_unit_conversions, public.item_groups to service_role';
  end if;
end $$;

insert into public.schema_migrations (version, name)
values ('0094', 'units_conversions_item_groups') on conflict (version) do nothing;
