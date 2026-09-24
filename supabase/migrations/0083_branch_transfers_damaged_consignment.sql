-- =============================================================================
-- 0083 — Branch transfers that move value, damaged stock, consignment stock
-- =============================================================================
-- Spec §28, §34, §35, §40. Audit checklist §06 (transfers; damaged /
-- consignment), §07 (document lifecycle: delivery challan).
--
-- ── Transfers moved quantity and not value ─────────────────────────────────
--
-- A stock or vehicle transfer moved the item between branches and wrote no
-- journal. 1500/1600/1700 are branch-scoped, so a branch's trial balance kept
-- the value of stock it had sent away and never showed stock it had received;
-- only the dealer total was right. And when the two branches hold different
-- GSTINs, a transfer is a supply under GST — a tax invoice with output tax at
-- one end and input tax at the other — which nothing recorded at all.
--
-- Every transfer now issues a transfer note (a delivery challan between
-- branches of one GSTIN, a tax invoice between two) and posts through a new
-- account, 1850 Inter-Branch Stock in Transit, so each branch balances on its
-- own:
--
--   sending branch    Stock in Transit  Dr  /  Inventory Cr  [/ Output GST Cr]
--   receiving branch  Inventory Dr  [/ Input GST Dr]  /  Stock in Transit Cr
--
-- Counted stock arrives at once, so both halves post together. A vehicle is on
-- the road between dispatch and receipt: the first half posts at dispatch, the
-- second at receipt, and 1850 holds the vehicle meanwhile — goods in transit,
-- where an auditor expects them. A cancelled dispatch is reversed. To do this in
-- one journal, post_journal now accepts a branch per line; account_balances()
-- and account_ledger() filter on the line's branch, which for every existing
-- line is the same as its header's.
--
-- ── Damaged and consignment stock ──────────────────────────────────────────
--
-- Two new lots beside LOCAL and COMPANY, neither of which the sale allocator
-- reads, so neither can be sold by accident:
--
--   DAMAGED      moved out of saleable stock at its cost, and written down to
--                what it will fetch; the write-down posts to 5970. It can then
--                be written off like any other adjustment.
--   CONSIGNMENT  held for a supplier and not owned: received and returned at nil
--                value, so it never enters the stock ledger's value or the GL.
--                To sell it, buy it in on a purchase bill.
--
-- Rollback: restore post_journal (0076), account_balances (0076),
--           account_ledger (0070), control_account_tieout (0077),
--           app.adjust_inventory_stock_core and transfer_inventory_stock (0079);
--           drop the note table, triggers and functions added here.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1850 Inter-Branch Stock in Transit
-- -----------------------------------------------------------------------------
create or replace function app.seed_transfer_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
begin
  insert into public.chart_of_accounts
    (dealer_id, code, name, account_type, normal_balance, is_group, parent_id, is_system, is_branch_scoped)
  select p_dealer_id, '1850', 'Inter-Branch Stock in Transit', 'ASSET', 'DEBIT', false, p.id, true, true
    from public.chart_of_accounts p
   where p.dealer_id = p_dealer_id and p.code = '1000' and p.is_group
  on conflict on constraint coa_dealer_code_key do nothing;
  return case when found then 1 else 0 end;
end;
$$;

do $$
declare d record;
begin
  for d in select id from public.dealers loop
    perform app.seed_transfer_accounts(d.id);
  end loop;
end $$;

alter function app.seed_chart_of_accounts(uuid) rename to seed_chart_of_accounts_0082;

create or replace function app.seed_chart_of_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
begin
  return app.seed_chart_of_accounts_0082(p_dealer_id) + app.seed_transfer_accounts(p_dealer_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- New lots
-- -----------------------------------------------------------------------------
alter table public.inventory_stock drop constraint inventory_stock_source_check;
alter table public.inventory_stock add constraint inventory_stock_source_check
  check (source in ('LOCAL', 'COMPANY', 'DAMAGED', 'CONSIGNMENT'));
alter table public.inventory_transactions drop constraint inventory_transactions_source_check;
alter table public.inventory_transactions add constraint inventory_transactions_source_check
  check (source in ('LOCAL', 'COMPANY', 'DAMAGED', 'CONSIGNMENT'));

-- -----------------------------------------------------------------------------
-- branch_transfer_notes — the challan or tax invoice behind every transfer
-- -----------------------------------------------------------------------------
create table public.branch_transfer_notes (
  id                 uuid primary key default gen_random_uuid(),
  dealer_id          uuid not null references public.dealers (id) on delete restrict,
  note_number        text not null,
  note_date          date not null default current_date,
  note_kind          text not null,
  from_branch_id     uuid not null,
  to_branch_id       uuid not null,
  from_gstin         text,
  to_gstin           text,
  item_id            uuid,
  vehicle_id         uuid,
  quantity           numeric(14, 3) not null,
  description        text not null,
  taxable_value      numeric(18, 4) not null,
  cgst_amount        numeric(18, 4) not null default 0,
  sgst_amount        numeric(18, 4) not null default 0,
  igst_amount        numeric(18, 4) not null default 0,
  journal_entry_id   uuid,
  receipt_journal_id uuid,
  created_at         timestamptz not null default now(),
  created_by         uuid,

  constraint btn_number_key unique (dealer_id, note_number),
  constraint btn_kind_check check (note_kind in ('DELIVERY_CHALLAN', 'TAX_INVOICE')),
  constraint btn_from_fkey foreign key (from_branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint btn_to_fkey foreign key (to_branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint btn_amounts_check check (taxable_value >= 0 and cgst_amount >= 0 and sgst_amount >= 0 and igst_amount >= 0),
  constraint btn_challan_untaxed_check check (
    note_kind = 'TAX_INVOICE' or (cgst_amount = 0 and sgst_amount = 0 and igst_amount = 0)
  )
);

create index btn_dealer_date_idx on public.branch_transfer_notes (dealer_id, note_date desc);

alter table public.branch_transfer_notes enable row level security;
create policy btn_select on public.branch_transfer_notes for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('inventory.view') or app.has_permission('gst.summary.view'))));
create policy btn_insert on public.branch_transfer_notes for insert to authenticated
  with check (dealer_id = app.current_dealer_id());
create policy btn_update on public.branch_transfer_notes for update to authenticated
  using (dealer_id = app.current_dealer_id()) with check (dealer_id = app.current_dealer_id());

create or replace function app.btn_append_only()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'A transfer note is a document and cannot be deleted.' using errcode = 'insufficient_privilege';
  end if;
  -- Only the receipt journal may be added later, once.
  if (to_jsonb(new) - 'receipt_journal_id') <> (to_jsonb(old) - 'receipt_journal_id')
     or old.receipt_journal_id is not null then
    raise exception 'A transfer note cannot be changed.' using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;

create trigger btn_append_only before update or delete on public.branch_transfer_notes
  for each row execute function app.btn_append_only();
create trigger btn_audit after insert on public.branch_transfer_notes
  for each row execute function app.audit_trigger();

-- -----------------------------------------------------------------------------
-- app.post_branch_transfer() — the note, and one or both halves of the journal
-- -----------------------------------------------------------------------------
-- p_mode: BOTH (counted stock, arrives at once), DISPATCH (vehicle leaves),
-- RECEIVE (vehicle arrives; p_note_id names the dispatch note).
create or replace function app.post_branch_transfer(
  p_dealer_id    uuid,
  p_from_branch  uuid,
  p_to_branch    uuid,
  p_inventory    uuid,
  p_value        numeric,
  p_tax_code     text,
  p_mode         text,
  p_item_id      uuid,
  p_vehicle_id   uuid,
  p_quantity     numeric,
  p_description  text,
  p_note_id      uuid
)
returns uuid
language plpgsql
as $$
declare
  v_note     public.branch_transfer_notes;
  v_from     public.branches;
  v_to       public.branches;
  v_taxable  boolean;
  v_inter    boolean;
  v_rate     record;
  v_cgst     numeric := 0;
  v_sgst     numeric := 0;
  v_igst     numeric := 0;
  v_transit  uuid;
  v_send     jsonb := '[]'::jsonb;
  v_recv     jsonb := '[]'::jsonb;
  v_year     text;
  v_gross    numeric;
  v_entry    uuid;
begin
  select id into v_transit from public.chart_of_accounts where dealer_id = p_dealer_id and code = '1850';
  if v_transit is null then
    raise exception 'The Inter-Branch Stock in Transit account (1850) is missing.' using errcode = 'no_data_found';
  end if;

  if p_mode = 'RECEIVE' then
    select * into v_note from public.branch_transfer_notes where id = p_note_id;
  else
    select * into v_from from public.branches where id = p_from_branch;
    select * into v_to from public.branches where id = p_to_branch;
    v_taxable := nullif(btrim(v_from.gstin), '') is not null and nullif(btrim(v_to.gstin), '') is not null
                 and v_from.gstin <> v_to.gstin;

    if v_taxable and p_tax_code is not null and p_value > 0 then
      select * into v_rate from public.resolve_tax_code(p_dealer_id, p_tax_code, current_date);
      v_inter := left(v_from.gstin, 2) <> left(v_to.gstin, 2);
      if v_inter then
        v_igst := round(p_value * coalesce(v_rate.igst_rate, v_rate.cgst_rate + v_rate.sgst_rate, 0) / 100, 2);
      else
        v_cgst := round(p_value * coalesce(v_rate.cgst_rate, 0) / 100, 2);
        v_sgst := round(p_value * coalesce(v_rate.sgst_rate, 0) / 100, 2);
      end if;
    end if;

    -- The series provisions itself: a dealer never finds transfers blocked for
    -- want of a sequence row.
    v_year := app.financial_year_token(p_dealer_id, current_date);
    insert into public.document_sequences (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
    values (p_dealer_id, null, 'TRANSFER_NOTE', v_year, 'TN', 6)
    on conflict on constraint document_sequences_scope_key do nothing;

    insert into public.branch_transfer_notes
      (dealer_id, note_number, note_kind, from_branch_id, to_branch_id, from_gstin, to_gstin,
       item_id, vehicle_id, quantity, description, taxable_value, cgst_amount, sgst_amount, igst_amount, created_by)
    values
      (p_dealer_id, app.next_document_number(p_dealer_id, null, 'TRANSFER_NOTE', v_year),
       case when v_taxable then 'TAX_INVOICE' else 'DELIVERY_CHALLAN' end,
       p_from_branch, p_to_branch, nullif(btrim(v_from.gstin), ''), nullif(btrim(v_to.gstin), ''),
       p_item_id, p_vehicle_id, p_quantity, p_description, p_value, v_cgst, v_sgst, v_igst, auth.uid())
    returning * into v_note;
  end if;

  if v_note.taxable_value <= 0 then
    return v_note.id;   -- nothing of value moved; the note alone records it
  end if;

  v_gross := v_note.taxable_value + v_note.cgst_amount + v_note.sgst_amount + v_note.igst_amount;

  -- The sending branch.
  v_send := jsonb_build_array(
    jsonb_build_object('account_id', v_transit, 'debit', v_gross, 'credit', 0,
                       'branch_id', v_note.from_branch_id, 'narration', v_note.note_number || ' to branch'),
    jsonb_build_object('account_id', p_inventory, 'debit', 0, 'credit', v_note.taxable_value,
                       'branch_id', v_note.from_branch_id, 'narration', v_note.description));
  if v_note.cgst_amount > 0 then
    v_send := v_send
      || jsonb_build_object('account_id', app.require_account(p_dealer_id, 'SERVICE', 'INVOICE', 'CGST', v_note.from_branch_id),
                            'debit', 0, 'credit', v_note.cgst_amount, 'branch_id', v_note.from_branch_id, 'narration', 'Output CGST')
      || jsonb_build_object('account_id', app.require_account(p_dealer_id, 'SERVICE', 'INVOICE', 'SGST', v_note.from_branch_id),
                            'debit', 0, 'credit', v_note.sgst_amount, 'branch_id', v_note.from_branch_id, 'narration', 'Output SGST');
  end if;
  if v_note.igst_amount > 0 then
    v_send := v_send
      || jsonb_build_object('account_id', app.require_account(p_dealer_id, 'SERVICE', 'INVOICE', 'IGST', v_note.from_branch_id),
                            'debit', 0, 'credit', v_note.igst_amount, 'branch_id', v_note.from_branch_id, 'narration', 'Output IGST');
  end if;

  -- The receiving branch.
  v_recv := jsonb_build_array(
    jsonb_build_object('account_id', p_inventory, 'debit', v_note.taxable_value, 'credit', 0,
                       'branch_id', v_note.to_branch_id, 'narration', v_note.description));
  if v_note.cgst_amount > 0 then
    v_recv := v_recv
      || jsonb_build_object('account_id', app.require_account(p_dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_CGST', v_note.to_branch_id),
                            'debit', v_note.cgst_amount, 'credit', 0, 'branch_id', v_note.to_branch_id, 'narration', 'Input CGST')
      || jsonb_build_object('account_id', app.require_account(p_dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_SGST', v_note.to_branch_id),
                            'debit', v_note.sgst_amount, 'credit', 0, 'branch_id', v_note.to_branch_id, 'narration', 'Input SGST');
  end if;
  if v_note.igst_amount > 0 then
    v_recv := v_recv
      || jsonb_build_object('account_id', app.require_account(p_dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_IGST', v_note.to_branch_id),
                            'debit', v_note.igst_amount, 'credit', 0, 'branch_id', v_note.to_branch_id, 'narration', 'Input IGST');
  end if;
  v_recv := v_recv || jsonb_build_object('account_id', v_transit, 'debit', 0, 'credit', v_gross,
                                         'branch_id', v_note.to_branch_id, 'narration', v_note.note_number || ' from branch');

  if p_mode = 'BOTH' then
    v_entry := app.post_journal(p_dealer_id, v_note.from_branch_id, v_note.note_date, 'INVENTORY',
      'Transfer ' || v_note.note_number || ' — ' || v_note.description, v_send || v_recv,
      'BRANCH_TRANSFER', v_note.id, 'transfer:' || v_note.id::text);
    update public.branch_transfer_notes set receipt_journal_id = v_entry where id = v_note.id;
    -- journal_entry_id is written at insert time for the other modes; here the
    -- single journal is both, recorded as the receipt.
  elsif p_mode = 'DISPATCH' then
    v_entry := app.post_journal(p_dealer_id, v_note.from_branch_id, v_note.note_date, 'INVENTORY',
      'Dispatch ' || v_note.note_number || ' — ' || v_note.description, v_send,
      'BRANCH_TRANSFER', v_note.id, 'transfer-out:' || v_note.id::text);
  else
    v_entry := app.post_journal(p_dealer_id, v_note.to_branch_id, current_date, 'INVENTORY',
      'Receipt ' || v_note.note_number || ' — ' || v_note.description, v_recv,
      'BRANCH_TRANSFER', v_note.id, 'transfer-in:' || v_note.id::text);
    update public.branch_transfer_notes set receipt_journal_id = v_entry where id = v_note.id;
  end if;

  return case when p_mode = 'DISPATCH' then v_entry else v_note.id end;
end;
$$;

comment on function app.post_branch_transfer(uuid, uuid, uuid, uuid, numeric, text, text, uuid, uuid, numeric, text, uuid) is
  'Issues a transfer note (challan or tax invoice) and posts the value through '
  '1850 so each branch balances (0083). DISPATCH returns the journal id; the '
  'other modes return the note id.';

-- -----------------------------------------------------------------------------
-- Vehicle transfers: dispatch and receipt carry their halves
-- -----------------------------------------------------------------------------
alter table public.vehicle_transfers
  add column if not exists transfer_note_id    uuid,
  add column if not exists dispatch_journal_id uuid,
  add column if not exists receipt_journal_id  uuid;

create or replace function app.vehicle_transfer_journals()
returns trigger
language plpgsql
as $$
declare
  v_vehicle record;
  v_entry   uuid;
begin
  if tg_op = 'INSERT' then
    select v.purchase_cost, v.chassis_no, m.tax_code, m.brand || ' ' || m.name as label
      into v_vehicle
      from public.vehicles v join public.vehicle_models m on m.id = v.model_id
     where v.id = new.vehicle_id;

    if coalesce(v_vehicle.purchase_cost, 0) > 0 then
      v_entry := app.post_branch_transfer(
        new.dealer_id, new.from_branch_id, new.to_branch_id,
        app.require_account(new.dealer_id, 'INVENTORY', 'PURCHASE', 'VEHICLE_INVENTORY', new.from_branch_id),
        v_vehicle.purchase_cost, v_vehicle.tax_code, 'DISPATCH', null, new.vehicle_id, 1,
        v_vehicle.label || ' — ' || v_vehicle.chassis_no, null);
      new.dispatch_journal_id := v_entry;
      select je.source_document_id into new.transfer_note_id from public.journal_entries je where je.id = v_entry;
    end if;
    return new;
  end if;

  if old.status = 'IN_TRANSIT' and new.status = 'RECEIVED' and new.transfer_note_id is not null then
    perform app.post_branch_transfer(
      new.dealer_id, new.from_branch_id, new.to_branch_id,
      app.require_account(new.dealer_id, 'INVENTORY', 'PURCHASE', 'VEHICLE_INVENTORY', new.to_branch_id),
      0, null, 'RECEIVE', null, new.vehicle_id, 1, null, new.transfer_note_id);
    select receipt_journal_id into new.receipt_journal_id
      from public.branch_transfer_notes where id = new.transfer_note_id;
  elsif old.status = 'IN_TRANSIT' and new.status = 'CANCELLED' and new.dispatch_journal_id is not null then
    perform app.reverse_journal(new.dispatch_journal_id, 'Transfer ' || new.transfer_number || ' cancelled', current_date);
  end if;
  return new;
end;
$$;

create trigger vehicle_transfers_journals
  before insert or update of status on public.vehicle_transfers
  for each row execute function app.vehicle_transfer_journals();

-- -----------------------------------------------------------------------------
-- Damaged stock
-- -----------------------------------------------------------------------------
create or replace function public.mark_stock_damaged(
  p_item_id        uuid,
  p_branch_id      uuid,
  p_source         text,
  p_quantity       numeric,
  p_realisable_unit numeric,
  p_reason         text
)
returns uuid
language plpgsql
as $$
declare
  v_dealer   uuid := app.current_dealer_id();
  v_item     public.inventory_items;
  v_avail    numeric;
  v_cost     numeric;
  v_nrv      numeric;
  v_writedown numeric;
  v_entry    uuid;
  v_inv      uuid;
begin
  if v_dealer is null or not app.has_permission('inventory.stock.adjust') then
    raise exception 'You may not adjust stock.' using errcode = 'insufficient_privilege';
  end if;
  if p_source not in ('LOCAL', 'COMPANY') then
    raise exception 'Damaged stock comes out of the LOCAL or COMPANY lot.' using errcode = 'check_violation';
  end if;
  if coalesce(p_quantity, 0) <= 0 then
    raise exception 'Enter how many are damaged.' using errcode = 'check_violation';
  end if;
  if coalesce(length(btrim(p_reason)), 0) < 3 then
    raise exception 'Say what happened to it.' using errcode = 'check_violation';
  end if;

  select * into v_item from public.inventory_items where id = p_item_id and dealer_id = v_dealer;
  if v_item.id is null then
    raise exception 'Item not found.' using errcode = 'no_data_found';
  end if;

  select l.quantity, l.average_cost into v_avail, v_cost from app.lock_stock_lot(p_item_id, p_branch_id, p_source) l;
  if coalesce(v_avail, 0) < p_quantity then
    raise exception 'Only % in % stock.', coalesce(v_avail, 0), p_source using errcode = 'check_violation';
  end if;
  v_cost := coalesce(v_cost, 0);
  v_nrv := least(greatest(coalesce(p_realisable_unit, 0), 0), v_cost);
  v_writedown := round(p_quantity * (v_cost - v_nrv), 4);

  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
     reference_type, narration, reason, created_by)
  values
    (v_dealer, p_branch_id, p_item_id, p_source, 'TRANSFER_OUT', -p_quantity, v_cost,
     'DAMAGE', 'Moved to damaged stock', btrim(p_reason), auth.uid()),
    (v_dealer, p_branch_id, p_item_id, 'DAMAGED', 'TRANSFER_IN', p_quantity, v_nrv,
     'DAMAGE', 'Damaged, held at realisable value', btrim(p_reason), auth.uid());

  if v_writedown > 0 then
    v_inv := app.require_account(v_dealer, 'INVENTORY', 'ADJUSTMENT',
      case when v_item.item_type = 'ACCESSORY' then 'ACCESSORY_INVENTORY' else 'SPARE_INVENTORY' end, p_branch_id);
    v_entry := app.post_journal(v_dealer, p_branch_id, current_date, 'INVENTORY',
      'Write-down of damaged ' || v_item.item_code || ' ×' || p_quantity || ' — ' || btrim(p_reason),
      jsonb_build_array(
        jsonb_build_object('account_id', app.require_account(v_dealer, 'INVENTORY', 'ADJUSTMENT', 'VARIANCE', p_branch_id),
                           'debit', v_writedown, 'credit', 0, 'narration', 'Damaged stock written down'),
        jsonb_build_object('account_id', v_inv, 'debit', 0, 'credit', v_writedown, 'narration', v_item.item_code)),
      'STOCK_DAMAGE', p_item_id, null);
  end if;

  return v_entry;
end;
$$;

comment on function public.mark_stock_damaged(uuid, uuid, text, numeric, numeric, text) is
  'Moves counted stock into the DAMAGED lot (never sold by the allocator) at its '
  'realisable value, posting the write-down to 5970 (checklist §06).';

-- -----------------------------------------------------------------------------
-- Consignment stock: held, not owned, valued at nil
-- -----------------------------------------------------------------------------
create or replace function public.move_consignment_stock(
  p_item_id   uuid,
  p_branch_id uuid,
  p_quantity  numeric,
  p_direction text,
  p_reference text
)
returns void
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
begin
  if v_dealer is null or not app.has_permission('inventory.stock.adjust') then
    raise exception 'You may not move stock.' using errcode = 'insufficient_privilege';
  end if;
  if p_direction not in ('RECEIVE', 'RETURN') or coalesce(p_quantity, 0) <= 0 then
    raise exception 'Receive or return a positive quantity.' using errcode = 'check_violation';
  end if;
  if coalesce(length(btrim(p_reference)), 0) < 2 then
    raise exception 'Give the consignor''s delivery note or reference.' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.inventory_items where id = p_item_id and dealer_id = v_dealer) then
    raise exception 'Item not found.' using errcode = 'no_data_found';
  end if;

  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
     reference_type, reference_number, narration, created_by)
  values
    (v_dealer, p_branch_id, p_item_id, 'CONSIGNMENT',
     case when p_direction = 'RECEIVE' then 'TRANSFER_IN' else 'TRANSFER_OUT' end,
     case when p_direction = 'RECEIVE' then p_quantity else -p_quantity end,
     0, 'CONSIGNMENT', btrim(p_reference),
     case when p_direction = 'RECEIVE' then 'Received on consignment — not owned' else 'Returned to consignor' end,
     auth.uid());
end;
$$;

create or replace function public.inventory_condition_report(p_branch_id uuid default null)
returns table (item_id uuid, item_code text, item_name text, branch_name text,
               damaged_qty numeric, damaged_value numeric, consignment_qty numeric)
language sql
stable
as $$
  select i.id, i.item_code, i.name, b.name,
         coalesce(sum(s.quantity) filter (where s.source = 'DAMAGED'), 0),
         coalesce(sum(s.stock_value) filter (where s.source = 'DAMAGED'), 0),
         coalesce(sum(s.quantity) filter (where s.source = 'CONSIGNMENT'), 0)
    from public.inventory_stock s
    join public.inventory_items i on i.id = s.item_id
    join public.branches b on b.id = s.branch_id
   where s.source in ('DAMAGED', 'CONSIGNMENT')
     and (p_branch_id is null or s.branch_id = p_branch_id)
   group by i.id, i.item_code, i.name, b.name
  having coalesce(sum(s.quantity), 0) <> 0
   order by i.item_code;
$$;
create or replace function app.post_journal(
  p_dealer_id       uuid,
  p_branch_id       uuid,
  p_entry_date      date,
  p_source_module   text,
  p_narration       text,
  p_lines           jsonb,
  p_source_document_type text default null,
  p_source_document_id   uuid default null,
  p_idempotency_key      text default null,
  p_reversal_of_id       uuid default null,
  p_reversal_reason      text default null
)
returns uuid
language plpgsql
as $$
declare
  v_entry_id  uuid;
  v_number    text;
  v_year      text;
  v_period_id uuid;
  v_debit     numeric(18, 4) := 0;
  v_credit    numeric(18, 4) := 0;
  v_line      jsonb;
  v_index     smallint := 0;
  v_existing  uuid;
  v_acc       record;
  v_dr        numeric;
  v_cr        numeric;
  v_money     integer := 0;
  v_lock      date;
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    raise exception 'A journal needs at least two lines.'
      using errcode = 'check_violation';
  end if;

  -- Idempotency (spec §50): a repeated submission returns the original entry
  -- rather than posting a second one.
  if p_idempotency_key is not null then
    select id into v_existing
      from public.journal_entries
     where dealer_id = p_dealer_id and idempotency_key = p_idempotency_key;
    if v_existing is not null then
      return v_existing;
    end if;
  end if;

  -- ── Every line, before anything is written ───────────────────────────────
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_index := v_index + 1;

    if (v_line ->> 'account_id') is null then
      raise exception 'Journal line % has no account. Check the accounting rules for this event.', v_index
        using errcode = 'check_violation',
              hint = 'Spec §22: accounts are resolved from accounting_rules, never hard-coded.';
    end if;

    begin
      v_dr := coalesce((v_line ->> 'debit')::numeric, 0);
      v_cr := coalesce((v_line ->> 'credit')::numeric, 0);
    exception when others then
      raise exception 'Journal line % has an amount that is not a number.', v_index
        using errcode = 'check_violation';
    end;

    if v_dr < 0 or v_cr < 0 then
      raise exception 'Journal line % has a negative amount. Use the other side instead.', v_index
        using errcode = 'check_violation';
    end if;
    if (v_dr > 0) = (v_cr > 0) then
      raise exception 'Journal line % must be a debit or a credit — not both, and not zero.', v_index
        using errcode = 'check_violation';
    end if;

    -- A line may sit in another branch of the same dealer (an inter-branch
    -- transfer posts both branches in one entry, each side balanced).
    if (v_line ->> 'branch_id') is not null and not exists (
         select 1 from public.branches b
          where b.id = (v_line ->> 'branch_id')::uuid and b.dealer_id = p_dealer_id) then
      raise exception 'Journal line % names a branch that does not belong to this dealer.', v_index
        using errcode = 'insufficient_privilege';
    end if;

    select * into v_acc from app.journal_account(p_dealer_id, (v_line ->> 'account_id')::uuid);
    if v_acc.code is null then
      raise exception 'Journal line % names an account that does not belong to this dealer.', v_index
        using errcode = 'insufficient_privilege';
    end if;
    if v_acc.is_group then
      raise exception 'Journal line %: % % is a group heading and cannot be posted to.',
        v_index, v_acc.code, v_acc.name
        using errcode = 'check_violation',
              hint = 'Post to one of the accounts beneath it.';
    end if;
    if v_acc.status <> 'ACTIVE' then
      raise exception 'Journal line %: % % is inactive and cannot be posted to.',
        v_index, v_acc.code, v_acc.name
        using errcode = 'check_violation';
    end if;

    if app.is_money_ledger(p_dealer_id, (v_line ->> 'account_id')::uuid) then
      v_money := v_money + 1;
      -- A hand-written line on cash or bank moves the ledger and not the book.
      if p_source_document_type = 'MANUAL_JOURNAL' then
        raise exception 'Journal line %: % % is a cash or bank account. Use Bank or Cash entry, or a Contra voucher, so the book moves with the ledger.',
          v_index, v_acc.code, v_acc.name
          using errcode = 'check_violation';
      end if;
    end if;

    v_debit  := v_debit  + v_dr;
    v_credit := v_credit + v_cr;
  end loop;

  -- A cash or bank entry writes ONE book row. A counter account that is itself
  -- cash or bank would move a second book that nothing writes.
  if p_source_document_type in ('CASH_BOOK', 'BANK_BOOK') and v_money > 1 then
    raise exception 'Money moving between cash and bank, or between two banks, is a Contra voucher.'
      using errcode = 'check_violation',
            hint = 'Bank → Contra writes both books; a receipt or payment writes only one.';
  end if;

  if round(v_debit, 4) <> round(v_credit, 4) then
    raise exception 'Journal does not balance: debit % <> credit %.', v_debit, v_credit
      using errcode = 'check_violation',
            hint = 'Spec §22: total debit must equal total credit.';
  end if;

  -- ── The lock date ────────────────────────────────────────────────────────
  v_lock := app.books_locked_through(p_dealer_id);
  if v_lock is not null and p_entry_date <= v_lock then
    raise exception 'The books are locked through %. Nothing dated % can be posted.',
      to_char(v_lock, 'DD-MM-YYYY'), to_char(p_entry_date, 'DD-MM-YYYY')
      using errcode = 'insufficient_privilege',
            hint = 'Date the entry after the lock, or ask Accounts to reopen the period with a reason.';
  end if;

  v_year   := app.financial_year_token(p_dealer_id, p_entry_date);
  v_number := app.next_document_number(p_dealer_id, null, 'JOURNAL', v_year);

  select id into v_period_id
    from public.accounting_periods
   where dealer_id = p_dealer_id
     and p_entry_date between start_date and end_date
   limit 1;

  -- An entry dated into a closed period must not post (spec §44).
  if v_period_id is not null then
    if (select status from public.accounting_periods where id = v_period_id) <> 'OPEN' then
      raise exception 'The accounting period covering % is closed.', p_entry_date
        using errcode = 'insufficient_privilege';
    end if;
  end if;

  insert into public.journal_entries
    (dealer_id, branch_id, entry_number, entry_date, period_id, source_module,
     source_document_type, source_document_id, narration, idempotency_key,
     reversal_of_id, reversal_reason, created_by)
  values
    (p_dealer_id, p_branch_id, v_number, p_entry_date, v_period_id, p_source_module,
     p_source_document_type, p_source_document_id, p_narration, p_idempotency_key,
     p_reversal_of_id, p_reversal_reason, auth.uid())
  returning id into v_entry_id;

  v_index := 0;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_index := v_index + 1;
    insert into public.journal_entry_lines
      (journal_entry_id, dealer_id, line_number, account_id, branch_id,
       debit, credit, narration, party_type, party_id)
    values
      (v_entry_id, p_dealer_id, v_index, (v_line ->> 'account_id')::uuid,
       coalesce((v_line ->> 'branch_id')::uuid, p_branch_id),
       coalesce((v_line ->> 'debit')::numeric, 0),
       coalesce((v_line ->> 'credit')::numeric, 0),
       v_line ->> 'narration',
       v_line ->> 'party_type',
       (v_line ->> 'party_id')::uuid);
  end loop;

  -- The trigger in 0007 recomputes totals from the lines and refuses to post
  -- anything unbalanced, so this is the second, independent check.
  update public.journal_entries set status = 'POSTED', posted_by = auth.uid()
   where id = v_entry_id;

  return v_entry_id;
end;
$$;

create or replace function public.account_balances(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  account_id        uuid,
  account_code      text,
  account_name      text,
  account_type      text,
  normal_balance    text,
  period_debit      numeric(18, 4),
  period_credit     numeric(18, 4),
  closing_debit     numeric(18, 4),
  closing_credit    numeric(18, 4),
  period_movement   numeric(18, 4),
  closing_balance   numeric(18, 4)
)
language sql
stable
as $$
  select
    coa.id,
    coa.code,
    coa.name,
    coa.account_type,
    coa.normal_balance,

    coalesce(sum(l.debit)  filter (where je.entry_date between p_from and p_to), 0),
    coalesce(sum(l.credit) filter (where je.entry_date between p_from and p_to), 0),
    coalesce(sum(l.debit)  filter (where je.entry_date <= p_to), 0),
    coalesce(sum(l.credit) filter (where je.entry_date <= p_to), 0),

    case when coa.normal_balance = 'DEBIT'
      then coalesce(sum(l.debit)  filter (where je.entry_date between p_from and p_to), 0)
         - coalesce(sum(l.credit) filter (where je.entry_date between p_from and p_to), 0)
      else coalesce(sum(l.credit) filter (where je.entry_date between p_from and p_to), 0)
         - coalesce(sum(l.debit)  filter (where je.entry_date between p_from and p_to), 0)
    end,

    case when coa.normal_balance = 'DEBIT'
      then coalesce(sum(l.debit)  filter (where je.entry_date <= p_to), 0)
         - coalesce(sum(l.credit) filter (where je.entry_date <= p_to), 0)
      else coalesce(sum(l.credit) filter (where je.entry_date <= p_to), 0)
         - coalesce(sum(l.debit)  filter (where je.entry_date <= p_to), 0)
    end

  from public.chart_of_accounts coa
  left join public.journal_entry_lines l
    on l.account_id = coa.id
   -- The line's branch, not the header's: an inter-branch transfer puts each
   -- side in its own branch within one entry (0083).
   and (p_branch_id is null or l.branch_id = p_branch_id)
  left join public.journal_entries je
    on je.id = l.journal_entry_id
   and je.status in ('POSTED', 'REVERSED')
  group by coa.id, coa.code, coa.name, coa.account_type, coa.normal_balance,
           coa.is_group, coa.status
  having (not coa.is_group and coa.status = 'ACTIVE') or count(je.id) > 0
  order by coa.code;
$$;

create or replace function public.account_ledger(
  p_account_id uuid,
  p_from       date,
  p_to         date,
  p_branch_id  uuid default null
)
returns table (
  journal_entry_id uuid,
  entry_date       date,
  entry_number     text,
  source_module    text,
  status           text,
  narration        text,
  -- What sat on the other side of this line, which is the question anyone
  -- reading a ledger row actually has: "4,150 to Bank Charges — from where?"
  contra           text,
  debit            numeric(18, 4),
  credit           numeric(18, 4),
  running_balance  numeric(18, 4)
)
language sql
stable
as $$
  select je.id,
         je.entry_date,
         je.entry_number,
         je.source_module,
         je.status,
         coalesce(l.narration, je.narration),
         (
           -- The opposite side of the same entry, named. Several accounts on the
           -- other side are listed rather than reduced to "Split", because on a
           -- two-line entry — which most are — the one name is the whole answer.
           select string_agg(distinct c2.name, ', ' order by c2.name)
             from public.journal_entry_lines l2
             join public.chart_of_accounts c2 on c2.id = l2.account_id
            where l2.journal_entry_id = je.id
              and l2.account_id <> p_account_id
         ),
         l.debit,
         l.credit,
         public.account_ledger_opening(p_account_id, p_from)
           + sum(l.debit - l.credit) over (order by je.entry_date, je.entry_number, l.line_number
                                           rows between unbounded preceding and current row)
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.account_id = p_account_id
     and je.status in ('POSTED', 'REVERSED')
     and je.entry_date between p_from and p_to
     and (p_branch_id is null or l.branch_id = p_branch_id)
   order by je.entry_date, je.entry_number, l.line_number;
$$;

create or replace function public.control_account_tieout(p_as_on date default current_date)
returns table (
  control          text,     -- PARTY | CASH | BANK | VEHICLE_STOCK | ACCESSORY_STOCK | SPARE_STOCK
  account_code     text,
  account_name     text,
  ledger_balance   numeric(18, 4),
  subledger_balance numeric(18, 4),
  difference       numeric(18, 4),
  explanation      text
)
language sql
stable
as $$
  with gl as (
    select l.account_id,
           sum(l.debit - l.credit) as bal,
           sum(l.debit - l.credit) filter (where l.party_id is not null) as tagged,
           count(*) filter (where l.party_id is null) as untagged_lines
      from public.journal_entry_lines l
      join public.journal_entries je on je.id = l.journal_entry_id
     where je.status in ('POSTED', 'REVERSED')
       and je.entry_date <= p_as_on
     group by l.account_id
  ),
  coa as (
    select c.id, c.code, c.name, c.normal_balance, c.account_type, c.dealer_id
      from public.chart_of_accounts c
  ),
  -- Party control accounts: receivables, payables, advances and finance-company
  -- balances — balance-sheet accounts a party line has touched, plus the two
  -- that should only ever be touched that way. A bank line or a commission
  -- income line may carry a party for reference; those are not controls, and
  -- listing them would report a "difference" that is nothing of the kind.
  party as (
    select 'PARTY'::text, coa.code, coa.name,
           coalesce(gl.bal, 0), coalesce(gl.tagged, 0),
           coalesce(gl.bal, 0) - coalesce(gl.tagged, 0),
           case when coalesce(gl.bal, 0) = coalesce(gl.tagged, 0) then null
                else gl.untagged_lines || ' line(s) on this account carry no customer, supplier or finance company' end
      from coa
      left join gl on gl.account_id = coa.id
     where coa.code in ('1300', '2200')
        or (coalesce(gl.tagged, 0) <> 0
            and coa.account_type in ('ASSET', 'LIABILITY')
            and not app.is_money_ledger(coa.dealer_id, coa.id))
  ),
  cash_book as (
    select ca.ledger_account_id,
           sum(ca.opening_balance + coalesce((
             select sum(case when t.direction = 'RECEIPT' then t.amount else -t.amount end)
               from public.cash_transactions t
              where t.cash_account_id = ca.id and t.status = 'ACTIVE'
                and t.business_date <= p_as_on), 0)) as bal
      from public.cash_accounts ca
     group by ca.ledger_account_id
  ),
  bank_book as (
    select ba.ledger_account_id,
           sum(ba.opening_balance + coalesce((
             select sum(case when t.direction = 'RECEIPT' then t.amount else -t.amount end)
               from public.bank_transactions t
              where t.bank_account_id = ba.id and t.status = 'ACTIVE'
                and t.transaction_date <= p_as_on), 0)) as bal
      from public.bank_accounts ba
     group by ba.ledger_account_id
  ),
  money as (
    select 'CASH'::text, coa.code, coa.name, coalesce(gl.bal, 0), cb.bal,
           coalesce(gl.bal, 0) - cb.bal,
           case when coalesce(gl.bal, 0) = cb.bal then null
                else 'Cash-ledger lines with no cash-book row, or a cash book opening balance never journalled' end
      from cash_book cb join coa on coa.id = cb.ledger_account_id
      left join gl on gl.account_id = cb.ledger_account_id
    union all
    select 'BANK'::text, coa.code, coa.name, coalesce(gl.bal, 0), bb.bal,
           coalesce(gl.bal, 0) - bb.bal,
           case when coalesce(gl.bal, 0) = bb.bal then null
                else 'Bank-ledger lines with no bank-book row (e.g. a receipt taken before any bank account existed)' end
      from bank_book bb join coa on coa.id = bb.ledger_account_id
      left join gl on gl.account_id = bb.ledger_account_id
  ),
  -- Stock is valued as it stands now; a stock tie-out for a past date would
  -- need the movement history replayed, and is only offered for today.
  stock as (
    -- A vehicle on the road left 1500 when its dispatch was journalled (0083);
    -- one dispatched before that never did.
    select 'VEHICLE_STOCK'::text as control, '1500'::text as code,
           coalesce(sum(v.purchase_cost), 0) as val
      from public.vehicles v
     where v.status in ('IN_STOCK', 'BOOKED')
        or (v.status = 'TRANSFERRED' and not exists (
              select 1 from public.vehicle_transfers vt
               where vt.vehicle_id = v.id and vt.status = 'IN_TRANSIT' and vt.dispatch_journal_id is not null))
    union all
    select 'STOCK_IN_TRANSIT', '1850',
           coalesce(sum(n.taxable_value + n.cgst_amount + n.sgst_amount + n.igst_amount), 0)
      from public.branch_transfer_notes n
      join public.vehicle_transfers vt on vt.transfer_note_id = n.id
     where vt.status = 'IN_TRANSIT'
    union all
    select case i.item_type when 'ACCESSORY' then 'ACCESSORY_STOCK' else 'SPARE_STOCK' end,
           case i.item_type when 'ACCESSORY' then '1600' else '1700' end,
           coalesce(sum(s.stock_value), 0)
      from public.inventory_stock s
      join public.inventory_items i on i.id = s.item_id
     group by i.item_type
  ),
  stock_rows as (
    select st.control, coa.code, coa.name, coalesce(gl.bal, 0), sum(st.val),
           coalesce(gl.bal, 0) - sum(st.val),
           case when coalesce(gl.bal, 0) = sum(st.val) then null
                else 'Stock at cost that never reached the ledger (uploaded without a purchase bill or opening entry), or the reverse' end
      from stock st
      join coa on coa.code = st.code
      left join gl on gl.account_id = coa.id
     where p_as_on >= current_date
     group by st.control, coa.code, coa.name, gl.bal
  )
  select * from party
  union all select * from money
  union all select * from stock_rows
  order by 1, 2;
$$;

create or replace function app.adjust_inventory_stock_core(
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
  v_type      text;
  v_code      text;
  v_available numeric(14, 3);
  v_cost      numeric(18, 4);
  v_value     numeric(18, 4);
  v_stock_acc uuid;
  v_var_acc   uuid;
  v_entry     uuid;
begin
  if p_quantity = 0 then
    raise exception 'An adjustment of zero changes nothing.' using errcode = 'check_violation';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A stock adjustment requires a reason.'
      using errcode = 'check_violation',
            hint = 'Spec §35: adjustments are auditable, so they must be explained.';
  end if;
  -- DAMAGED stock can be written off; CONSIGNMENT is not the dealer's to adjust.
  if p_source not in ('LOCAL', 'COMPANY', 'DAMAGED') then
    raise exception 'Source must be LOCAL, COMPANY or DAMAGED.' using errcode = 'check_violation';
  end if;

  select dealer_id, standard_cost, item_type, item_code into v_dealer, v_cost, v_type, v_code
    from public.inventory_items where id = p_item_id;

  if v_dealer is null then
    raise exception 'Item not found.' using errcode = 'no_data_found';
  end if;

  select l.quantity, l.average_cost into v_available, v_cost
    from app.lock_stock_lot(p_item_id, p_branch_id, p_source) l;

  if p_quantity < 0 and coalesce(v_available, 0) < abs(p_quantity) then
    raise exception 'Only % in stock — an adjustment of % would drive it negative.',
      coalesce(v_available, 0), p_quantity using errcode = 'check_violation';
  end if;

  if v_cost is null or v_cost = 0 then
    select standard_cost into v_cost from public.inventory_items where id = p_item_id;
  end if;
  v_cost  := coalesce(v_cost, 0);
  -- The same figure the movement's generated `value` column will hold, so the
  -- stock ledger and the general ledger move by exactly the same amount.
  v_value := round(abs(p_quantity) * v_cost, 4);

  -- ── The journal first: if the rules are missing, nothing moves ──────────
  if v_value > 0 then
    v_stock_acc := app.require_account(v_dealer, 'INVENTORY', 'ADJUSTMENT',
      case when v_type = 'ACCESSORY' then 'ACCESSORY_INVENTORY' else 'SPARE_INVENTORY' end,
      p_branch_id);
    v_var_acc := app.require_account(v_dealer, 'INVENTORY', 'ADJUSTMENT', 'VARIANCE', p_branch_id);

    v_entry := app.post_journal(
      v_dealer, p_branch_id, current_date, 'INVENTORY',
      'Stock adjustment ' || v_code || ' ' || p_source || ' '
        || case when p_quantity > 0 then '+' else '' end || p_quantity::text
        || ' — ' || btrim(p_reason),
      case when p_quantity > 0 then
        jsonb_build_array(
          jsonb_build_object('account_id', v_stock_acc, 'debit', v_value, 'credit', 0,
                             'narration', 'Counted more ' || v_code),
          jsonb_build_object('account_id', v_var_acc, 'debit', 0, 'credit', v_value,
                             'narration', btrim(p_reason)))
      else
        jsonb_build_array(
          jsonb_build_object('account_id', v_var_acc, 'debit', v_value, 'credit', 0,
                             'narration', btrim(p_reason)),
          jsonb_build_object('account_id', v_stock_acc, 'debit', 0, 'credit', v_value,
                             'narration', 'Counted less ' || v_code))
      end,
      'STOCK_ADJUSTMENT', p_item_id, null);
  end if;

  -- reference_id carries the journal, so the stock ledger row drills to it.
  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
     reference_type, reference_id, narration, reason, created_by)
  values
    (v_dealer, p_branch_id, p_item_id, p_source, 'ADJUSTMENT', p_quantity, v_cost,
     'ADJUSTMENT', v_entry, 'Stock adjustment', btrim(p_reason), auth.uid());
end;
$$;

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
  if not exists (select 1 from public.branches where id = p_to_branch_id and dealer_id = v_dealer) then
    raise exception 'The destination branch does not belong to this dealer.'
      using errcode = 'insufficient_privilege';
  end if;

  select l.quantity, l.average_cost into v_available, v_cost
    from app.lock_stock_lot(p_item_id, p_from_branch_id, p_source) l;

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

  -- The value moves with the quantity (0083): out of the sending branch's stock,
  -- into the receiving branch's, through Inter-Branch Stock in Transit — with
  -- GST when the two branches hold different GSTINs, because then it is a supply.
  perform app.post_branch_transfer(
    v_dealer, p_from_branch_id, p_to_branch_id,
    app.require_account(v_dealer, 'INVENTORY', 'ADJUSTMENT',
      case when (select item_type from public.inventory_items where id = p_item_id) = 'ACCESSORY'
           then 'ACCESSORY_INVENTORY' else 'SPARE_INVENTORY' end, p_from_branch_id),
    round(p_quantity * coalesce(v_cost, 0), 4),
    (select tax_code from public.inventory_items where id = p_item_id),
    'BOTH', p_item_id, null, p_quantity,
    (select item_code || ' ' || name from public.inventory_items where id = p_item_id), null);
end;
$$;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.branch_transfer_notes to authenticated';
    execute 'grant execute on function public.mark_stock_damaged(uuid, uuid, text, numeric, numeric, text) to authenticated';
    execute 'grant execute on function public.move_consignment_stock(uuid, uuid, numeric, text, text) to authenticated';
    execute 'grant execute on function public.inventory_condition_report(uuid) to authenticated';
  end if;
end $$;

-- What was dispatched before this and never journalled stays in 1500 until it
-- is received; the tie-out counts it there.
do $$
declare v_count integer;
begin
  select count(*) into v_count from public.vehicle_transfers where status = 'IN_TRANSIT' and dispatch_journal_id is null;
  if v_count > 0 then
    raise notice '0083: % vehicle(s) in transit were dispatched before transfers carried value; they post nothing on receipt.', v_count;
  end if;
end $$;

insert into public.schema_migrations (version, name)
values ('0083', 'branch_transfer_value_damaged_consignment') on conflict (version) do nothing;
