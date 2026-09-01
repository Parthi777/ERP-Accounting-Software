-- =============================================================================
-- INCREMENTAL 0036 → 0036
-- =============================================================================
-- GENERATED FILE. Regenerate with:
--   FROM=0036 bash scripts/build-incremental.sh
--
-- For a database that ALREADY has migrations up to 0035.
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
-- SOURCE: supabase/migrations/0036_transfers_returns_adjustments.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0036 — Vehicle transfers, sales returns, and stock adjustments
-- =============================================================================
-- Spec §16, §21, §35.
--
-- What these three have in common: each moves value, so each writes a journal
-- alongside whatever it moves. A transfer that moves a chassis between branches
-- without moving its cost leaves both branches' stock values wrong; an
-- adjustment that changes quantity without touching the ledger leaves stock
-- value disagreeing with the balance sheet.
--
-- Rollback: drop the functions below and restore app.vehicles_log_movement()
-- from 0017.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- app.vehicles_log_movement() — teach the existing trigger these movements
-- -----------------------------------------------------------------------------
-- 0017 makes this trigger the sole writer of the vehicle stock ledger, "so the
-- log cannot be forgotten by a caller", and the table is append-only. A function
-- that both moves a vehicle and writes its own ledger row therefore produces two
-- rows for one movement, and no report can tell which of them is the movement.
--
-- So the functions below move the vehicle and leave the logging here. Two things
-- the trigger could not previously know:
--
--   * that leaving stock as TRANSFERRED is a TRANSFER_OUT and that coming back
--     from a sale is a RETURN — both derivable from the status pair;
--   * which document caused the movement, which is not derivable, so callers
--     pass it in `app.vehicle_movement_ref` as '<type>:<uuid>'. The setting is
--     transaction-local and each caller clears it immediately after the update,
--     so it can never leak onto an unrelated one.
-- -----------------------------------------------------------------------------
create or replace function app.vehicles_log_movement()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ref  text;
  v_type text;
  v_id   uuid;
begin
  if tg_op = 'INSERT' then
    insert into public.vehicle_stock_transactions
      (dealer_id, branch_id, vehicle_id, transaction_type, to_status, to_branch_id, value, created_by)
    values (new.dealer_id, new.branch_id, new.id, 'PURCHASE', new.status, new.branch_id,
            new.purchase_cost, new.created_by);
    return null;
  end if;

  if new.status is distinct from old.status or new.branch_id is distinct from old.branch_id then
    v_ref := nullif(current_setting('app.vehicle_movement_ref', true), '');
    if v_ref is not null then
      v_type := split_part(v_ref, ':', 1);
      v_id   := nullif(split_part(v_ref, ':', 2), '')::uuid;
    end if;

    insert into public.vehicle_stock_transactions
      (dealer_id, branch_id, vehicle_id, transaction_type,
       from_status, to_status, from_branch_id, to_branch_id, value,
       reference_type, reference_id, created_by)
    values (new.dealer_id, new.branch_id, new.id,
            case
              -- The branch moved, so the unit has arrived somewhere.
              when new.branch_id is distinct from old.branch_id then 'TRANSFER_IN'
              -- On its way: out of the source branch's stock, not yet anywhere.
              when new.status = 'TRANSFERRED'                    then 'TRANSFER_OUT'
              when old.status in ('SOLD_PENDING_DELIVERY', 'DELIVERED')
                   and new.status = 'IN_STOCK'                   then 'RETURN'
              else 'STATUS_CHANGE'
            end,
            old.status, new.status, old.branch_id, new.branch_id, new.purchase_cost,
            v_type, v_id, new.updated_by);
  end if;

  return null;
end;
$$;

comment on function app.vehicles_log_movement() is
  'Sole writer of the vehicle stock ledger (spec §34). Labels transfers and '
  'returns from the status pair and takes the causing document from the '
  'transaction-local setting app.vehicle_movement_ref.';

-- -----------------------------------------------------------------------------
-- public.dispatch_vehicle_transfer() — spec §16
-- -----------------------------------------------------------------------------
create or replace function public.dispatch_vehicle_transfer(
  p_vehicle_id   uuid,
  p_to_branch_id uuid,
  p_remarks      text default null
)
returns table (transfer_id uuid, transfer_number text)
language plpgsql
as $$
declare
  v_vehicle public.vehicles;
  v_number  text;
  v_id      uuid;
begin
  select * into v_vehicle from public.vehicles where id = p_vehicle_id for update;

  if v_vehicle.id is null then
    raise exception 'Vehicle not found.' using errcode = 'no_data_found';
  end if;
  if v_vehicle.status <> 'IN_STOCK' then
    raise exception 'Vehicle % is % — only a vehicle in stock can be transferred.',
      v_vehicle.chassis_no, v_vehicle.status using errcode = 'check_violation';
  end if;
  if v_vehicle.branch_id = p_to_branch_id then
    raise exception 'The vehicle is already at that branch.' using errcode = 'check_violation';
  end if;

  v_number := app.next_document_number(
    v_vehicle.dealer_id, v_vehicle.branch_id, 'STOCK_TRANSFER',
    app.financial_year_token(v_vehicle.dealer_id, current_date));

  insert into public.vehicle_transfers
    (dealer_id, transfer_number, vehicle_id, from_branch_id, to_branch_id,
     status, dispatched_by, remarks)
  values
    (v_vehicle.dealer_id, v_number, p_vehicle_id, v_vehicle.branch_id, p_to_branch_id,
     'IN_TRANSIT', auth.uid(), p_remarks)
  returning id into v_id;

  -- TRANSFERRED, not yet at the destination: a vehicle on a lorry is at neither
  -- branch, and showing it as available at either would let it be sold twice.
  -- The transfer document carries IN_TRANSIT; the vehicle carries TRANSFERRED,
  -- which is the status spec §13 defines and the only one app.vehicles_guard_status()
  -- will accept out of IN_STOCK and back again on receipt.
  --
  -- The TRANSFER_OUT ledger row is written by app.vehicles_log_movement().
  perform set_config('app.vehicle_movement_ref', 'VEHICLE_TRANSFER:' || v_id, true);

  update public.vehicles
     set status = 'TRANSFERRED', updated_by = auth.uid()
   where id = p_vehicle_id;

  perform set_config('app.vehicle_movement_ref', '', true);

  transfer_id := v_id; transfer_number := v_number;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.receive_vehicle_transfer() — spec §16
-- -----------------------------------------------------------------------------
create or replace function public.receive_vehicle_transfer(
  p_transfer_id uuid,
  p_remarks     text default null
)
returns void
language plpgsql
as $$
declare v_transfer public.vehicle_transfers;
begin
  select * into v_transfer from public.vehicle_transfers where id = p_transfer_id for update;

  if v_transfer.id is null then
    raise exception 'Transfer not found.' using errcode = 'no_data_found';
  end if;
  if v_transfer.status <> 'IN_TRANSIT' then
    raise exception 'Transfer % is % and cannot be received again.',
      v_transfer.transfer_number, v_transfer.status using errcode = 'check_violation';
  end if;

  update public.vehicle_transfers
     set status = 'RECEIVED', received_at = now(), received_by = auth.uid(),
         remarks = coalesce(p_remarks, remarks)
   where id = p_transfer_id;

  -- The TRANSFER_IN ledger row, at the destination branch, is written by
  -- app.vehicles_log_movement() off this update.
  perform set_config('app.vehicle_movement_ref', 'VEHICLE_TRANSFER:' || p_transfer_id, true);

  update public.vehicles
     set branch_id = v_transfer.to_branch_id, status = 'IN_STOCK', updated_by = auth.uid()
   where id = v_transfer.vehicle_id;

  perform set_config('app.vehicle_movement_ref', '', true);
end;
$$;

-- -----------------------------------------------------------------------------
-- public.transfer_inventory_stock() — spec §35
-- -----------------------------------------------------------------------------
-- The source lot is preserved across the move: local stock transferred to
-- another branch arrives as local stock. Merging it into company stock would
-- destroy the distinction spec §60.16 exists to keep.
-- -----------------------------------------------------------------------------
create or replace function public.transfer_inventory_stock(
  p_item_id        uuid,
  p_from_branch_id uuid,
  p_to_branch_id   uuid,
  p_quantity       numeric,
  p_source         text default 'COMPANY',
  p_remarks        text default null
)
returns void
language plpgsql
as $$
declare
  v_dealer    uuid;
  v_available numeric(14, 3);
  v_cost      numeric(18, 4);
begin
  if p_quantity <= 0 then
    raise exception 'Quantity must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_from_branch_id = p_to_branch_id then
    raise exception 'The source and destination branches are the same.' using errcode = 'check_violation';
  end if;
  if p_source not in ('LOCAL', 'COMPANY') then
    raise exception 'Source must be LOCAL or COMPANY.' using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer from public.inventory_items where id = p_item_id;
  if v_dealer is null then
    raise exception 'Item not found.' using errcode = 'no_data_found';
  end if;

  select quantity, average_cost into v_available, v_cost
    from public.inventory_stock
   where item_id = p_item_id and branch_id = p_from_branch_id and source = p_source
     for update;

  if coalesce(v_available, 0) < p_quantity then
    raise exception 'Only % in % stock at the source branch.', coalesce(v_available, 0), p_source
      using errcode = 'check_violation';
  end if;

  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
     reference_type, narration, created_by)
  values
    (v_dealer, p_from_branch_id, p_item_id, p_source, 'TRANSFER_OUT', -p_quantity, v_cost,
     'STOCK_TRANSFER', coalesce(p_remarks, 'Transferred out'), auth.uid()),
    (v_dealer, p_to_branch_id, p_item_id, p_source, 'TRANSFER_IN', p_quantity, v_cost,
     'STOCK_TRANSFER', coalesce(p_remarks, 'Transferred in'), auth.uid());
end;
$$;

-- -----------------------------------------------------------------------------
-- public.adjust_inventory_stock() — spec §35
-- -----------------------------------------------------------------------------
-- A reason is mandatory. An adjustment without one is indistinguishable from
-- theft, and the whole point of the stock ledger is that it can be questioned.
-- -----------------------------------------------------------------------------
create or replace function public.adjust_inventory_stock(
  p_item_id   uuid,
  p_branch_id uuid,
  p_source    text,
  p_quantity  numeric,
  p_reason    text
)
returns void
language plpgsql
as $$
declare
  v_dealer    uuid;
  v_available numeric(14, 3);
  v_cost      numeric(18, 4);
begin
  if p_quantity = 0 then
    raise exception 'An adjustment of zero changes nothing.' using errcode = 'check_violation';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A stock adjustment requires a reason.'
      using errcode = 'check_violation',
            hint = 'Spec §35: adjustments are auditable, so they must be explained.';
  end if;
  if p_source not in ('LOCAL', 'COMPANY') then
    raise exception 'Source must be LOCAL or COMPANY.' using errcode = 'check_violation';
  end if;

  select dealer_id, standard_cost into v_dealer, v_cost
    from public.inventory_items where id = p_item_id;

  if v_dealer is null then
    raise exception 'Item not found.' using errcode = 'no_data_found';
  end if;

  select quantity, average_cost into v_available, v_cost
    from public.inventory_stock
   where item_id = p_item_id and branch_id = p_branch_id and source = p_source
     for update;

  -- Stock cannot go negative: a count that says less than zero is a wrong count.
  if p_quantity < 0 and coalesce(v_available, 0) < abs(p_quantity) then
    raise exception 'Only % in stock — an adjustment of % would drive it negative.',
      coalesce(v_available, 0), p_quantity using errcode = 'check_violation';
  end if;

  if v_cost is null or v_cost = 0 then
    select standard_cost into v_cost from public.inventory_items where id = p_item_id;
  end if;

  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
     reference_type, narration, reason, created_by)
  values
    (v_dealer, p_branch_id, p_item_id, p_source, 'ADJUSTMENT', p_quantity, coalesce(v_cost, 0),
     'ADJUSTMENT', 'Stock adjustment', btrim(p_reason), auth.uid());
end;
$$;

-- -----------------------------------------------------------------------------
-- public.return_vehicle_sale() — spec §21
-- -----------------------------------------------------------------------------
-- A return is a reversal with a reason, never an edit. The original invoice
-- stays exactly as issued, its journal is reversed, and the vehicle comes back
-- into stock — which is only possible before it has been delivered.
-- -----------------------------------------------------------------------------
create or replace function public.return_vehicle_sale(
  p_sale_id uuid,
  p_reason  text
)
returns uuid
language plpgsql
as $$
declare
  v_sale    public.sales;
  v_entry   uuid;
  v_alloc   record;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A sales return requires a reason.'
      using errcode = 'check_violation',
            hint = 'Spec §21: the reason is part of the record, not optional.';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;

  if v_sale.id is null then
    raise exception 'Sale not found.' using errcode = 'no_data_found';
  end if;
  if v_sale.status <> 'POSTED' then
    raise exception 'Invoice % is % — only a posted, undelivered sale can be returned.',
      v_sale.invoice_number, v_sale.status using errcode = 'check_violation';
  end if;
  if v_sale.paid_amount > 0 then
    raise exception 'Invoice % has % received against it. Refund it before returning the sale.',
      v_sale.invoice_number, v_sale.paid_amount
      using errcode = 'check_violation';
  end if;

  -- The reversal carries the reason and points back at what it reverses.
  v_entry := app.reverse_journal(v_sale.journal_entry_id, btrim(p_reason), current_date);

  -- Fitted accessories go back into the lot they came out of.
  for v_alloc in
    select t.item_id, t.source, -t.quantity as qty, t.unit_cost
      from public.inventory_transactions t
     where t.reference_type = 'SALE' and t.reference_id = p_sale_id and t.quantity < 0
  loop
    insert into public.inventory_transactions
      (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
       reference_type, reference_id, narration, reason, created_by)
    values
      (v_sale.dealer_id, v_sale.branch_id, v_alloc.item_id, v_alloc.source, 'RETURN',
       v_alloc.qty, v_alloc.unit_cost, 'SALE_RETURN', p_sale_id,
       'Returned from ' || v_sale.invoice_number, btrim(p_reason), auth.uid());
  end loop;

  update public.sales
     set status = 'RETURNED', updated_by = auth.uid(), notes =
           coalesce(notes || E'\n', '') || 'Returned: ' || btrim(p_reason)
   where id = p_sale_id;

  -- The RETURN ledger row is written by app.vehicles_log_movement().
  perform set_config('app.vehicle_movement_ref', 'SALE_RETURN:' || p_sale_id, true);

  update public.vehicles
     set status = 'IN_STOCK', updated_by = auth.uid()
   where id = v_sale.vehicle_id;

  perform set_config('app.vehicle_movement_ref', '', true);

  return v_entry;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.dispatch_vehicle_transfer(uuid, uuid, text) to authenticated';
    execute 'grant execute on function public.receive_vehicle_transfer(uuid, text) to authenticated';
    execute 'grant execute on function public.transfer_inventory_stock(uuid, uuid, uuid, numeric, text, text) to authenticated';
    execute 'grant execute on function public.adjust_inventory_stock(uuid, uuid, text, numeric, text) to authenticated';
    execute 'grant execute on function public.return_vehicle_sale(uuid, text) to authenticated';
  end if;
end;
$$;


commit;
