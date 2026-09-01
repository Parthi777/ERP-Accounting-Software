-- =============================================================================
-- 0038 — Delivery and transfer numbering
-- =============================================================================
-- Spec §45, §60.3, §60.5.
--
-- Two faults, one cause.
--
-- 1. public.deliver_vehicle() numbered delivery notes from the STOCK_TRANSFER
--    sequence, so a delivery note came out as TRF-2026-000004 and drew from the
--    same counter as inter-branch transfers. The delivery is labelled as though
--    it were a transfer, and the two series interleave, so each shows gaps that
--    read as missing documents to anyone auditing them.
--
-- 2. Both series were numbered from *branch-scoped* sequences that carry the
--    same prefix at every branch, while `vehicle_transfers_number_key` and
--    `deliveries_number_key` are unique per *dealer*. Two branches therefore
--    both generate TRF-2026-000001, and the second one to try is rejected by
--    the constraint. A single-branch dealer never sees it; a two-branch dealer
--    hits it on the second branch's first transfer, which is exactly the
--    multi-branch operation spec §60.3 requires to work from day one.
--
-- The sequence scope has to match the uniqueness scope, so both become
-- dealer-wide, the way JOURNAL already is in 0006. Branch is still recorded on
-- every row; it simply stops being part of how the number is allocated.
--
-- Existing numbers are left exactly as issued, and the dealer-wide counter
-- starts above the highest number any branch reached, so nothing is reissued.
--
-- Rollback: restore public.deliver_vehicle() and public.dispatch_vehicle_transfer()
--           from 0028 and 0036, and delete the dealer-wide DELIVERY and
--           STOCK_TRANSFER rows from public.document_sequences.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Dealer-wide sequences, carrying forward each dealer's highest branch counter
-- -----------------------------------------------------------------------------
-- Derived from the sequences that already exist rather than from branches, so
-- this covers the dealer/financial-year combinations actually in use and stays
-- correct for a dealer whose financial year is not the default.
-- next_document_number() raises when a scope has no row, so this backfill is
-- what stops the first transfer or delivery after this migration from failing.
-- -----------------------------------------------------------------------------
insert into public.document_sequences
  (dealer_id, branch_id, doc_type, financial_year, prefix, padding, last_number)
select ds.dealer_id, null::uuid, 'STOCK_TRANSFER', ds.financial_year, 'TRF', 6,
       max(ds.last_number)
  from public.document_sequences ds
 where ds.doc_type = 'STOCK_TRANSFER' and ds.branch_id is not null
 group by ds.dealer_id, ds.financial_year
on conflict on constraint document_sequences_scope_key do nothing;

-- Deliveries were drawing on the transfer counter, so the highest delivery
-- number issued is already covered by the figure carried forward above.
insert into public.document_sequences
  (dealer_id, branch_id, doc_type, financial_year, prefix, padding, last_number)
select distinct ds.dealer_id, null::uuid, 'DELIVERY', ds.financial_year, 'DN', 6, 0
  from public.document_sequences ds
 where ds.branch_id is not null
on conflict on constraint document_sequences_scope_key do nothing;

-- The branch-scoped transfer rows are left in place but no longer consulted;
-- dropping them would discard the record of what each branch had issued.

-- -----------------------------------------------------------------------------
-- public.deliver_vehicle() — spec §19, the final step
-- -----------------------------------------------------------------------------
create or replace function public.deliver_vehicle(
  p_sale_id      uuid,
  p_received_by  text default null,
  p_odometer     numeric default null,
  p_remarks      text default null
)
returns text
language plpgsql
as $$
declare
  v_sale    public.sales;
  v_year    text;
  v_number  text;
begin
  select * into v_sale from public.sales where id = p_sale_id for update;

  if v_sale.id is null then
    raise exception 'Sale not found.' using errcode = 'no_data_found';
  end if;
  if v_sale.status <> 'POSTED' then
    raise exception 'Only a POSTED sale can be delivered; this one is %.', v_sale.status
      using errcode = 'check_violation';
  end if;

  v_year := app.financial_year_token(v_sale.dealer_id, current_date);
  v_number := app.next_document_number(v_sale.dealer_id, null, 'DELIVERY', v_year);

  insert into public.deliveries
    (dealer_id, branch_id, sale_id, vehicle_id, delivery_number,
     delivered_by, received_by_name, odometer, remarks)
  values
    (v_sale.dealer_id, v_sale.branch_id, p_sale_id, v_sale.vehicle_id, v_number,
     auth.uid(), p_received_by, p_odometer, p_remarks);

  update public.vehicles set status = 'DELIVERED', updated_by = auth.uid()
   where id = v_sale.vehicle_id;

  update public.sales set status = 'DELIVERED', delivered_by = auth.uid()
   where id = p_sale_id;

  return v_number;
end;
$$;

comment on function public.deliver_vehicle(uuid, text, numeric, text) is
  'Records the handover and closes the sale (spec §19). Numbered from the '
  'dealer-wide DELIVERY series, which is its own (spec §45).';

-- -----------------------------------------------------------------------------
-- public.dispatch_vehicle_transfer() — spec §35, numbered dealer-wide
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

  -- Dealer-wide: the number has to be unique across the dealer, so it cannot be
  -- allocated from a per-branch counter that every branch starts at one.
  v_number := app.next_document_number(
    v_vehicle.dealer_id, null, 'STOCK_TRANSFER',
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
