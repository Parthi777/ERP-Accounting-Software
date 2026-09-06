-- =============================================================================
-- INCREMENTAL 0057 → 0057
-- =============================================================================
-- GENERATED FILE. Regenerate with:
--   FROM=0057 bash scripts/build-incremental.sh
--
-- For a database that ALREADY has migrations up to 0056.
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
-- SOURCE: supabase/migrations/0057_purchase_returns.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0057 — Purchase returns: the debit note that sends bought stock back
-- =============================================================================
-- Spec §21, §22, §23, §24, §28, §29, §34, §41, §44, §45, §48, §50, §59, §60.22.
--
-- The hole this fills. 0052 gave the dealer a way to bring stock in and 0051
-- gave the customer a way to send it back out. Between them there is nothing
-- pointing at the supplier. Goods arrive damaged, the wrong variant is sent, a
-- carton is short — and today the only tool for any of it is
-- cancel_purchase_bill(), which reverses the WHOLE bill. So a dealer returning
-- three floor mats out of a bill of two hundred lines has to reverse the entire
-- consignment and re-key it, or leave the mats on the books for ever and let
-- inventory drift away from the shelf.
--
-- ── What a debit note is, and what it is not ────────────────────────────────
--
-- Cancelling a bill says "this purchase never happened". A return says "this
-- purchase happened, and some of it is going back". They are different facts and
-- the ledger has to be able to state both:
--
--     cancel_purchase_bill()   whole bill, reversal of the original journal
--     post_purchase_return()   part of a bill, a new journal of its own
--
-- The return is the mirror of the bill, line for line:
--
--     Dr  2200 Supplier Payables   (party-tagged)      total
--         Cr  1500 / 1600 / 1700   inventory                    at cost
--         Cr  1900 / 1910 / 1920   input GST reversed           ITC given back
--
-- It resolves the SAME accounting rules the purchase used (INVENTORY/PURCHASE)
-- and flips the side, rather than gaining rules of its own. That is deliberate:
-- a return has to relieve the very accounts the purchase raised, and a separate
-- mapping is a way for one dealer's misconfiguration to leave inventory
-- overstated for ever with a balanced journal to prove it.
--
-- ── Where the money goes ────────────────────────────────────────────────────
--
-- Nowhere, here. The debit note reduces what is owed; it does not move cash.
-- Posted, it becomes an unapplied DEBIT on the supplier's ledger, which is
-- exactly what 0050's bill-wise settlement was built to consume — knock it off
-- the bill it came from, or off the next one. If the supplier actually sends
-- money back, that is a cash or bank receipt tagged to the supplier (0041) and
-- allocated against this note, and it goes through the book that itemises it
-- like every other movement. Inventing a second money path here would put a
-- receipt in the ledger that the cash book had never heard of.
--
-- ── A returned vehicle is not a cancelled one ───────────────────────────────
--
-- Sending a chassis back needs it out of stock, and the obvious move — reusing
-- CANCELLED — is wrong twice over. It reads as "this record was a mistake" when
-- the truth is "this vehicle went back to the manufacturer", and CANCELLED is
-- terminal by design (0017), so reversing the return could never bring the
-- vehicle back. So vehicles gain RETURNED, whose only exit is back to IN_STOCK
-- when the note is reversed. The lifecycle stays a closed set of legal moves.
--
-- The chassis stays on its purchase bill line, and the unique index there means
-- it can never be billed again. That is correct: it was bought once, and it left.
--
-- Rollback: drop function public.post_purchase_return(uuid, jsonb, text, date, text, text);
--           drop function public.cancel_purchase_return(uuid, text);
--           drop function public.returnable_purchase_lines(uuid);
--           drop table public.purchase_return_lines, public.purchase_returns;
--           drop function app.purchase_returns_assign_number(), app.purchase_returns_guard();
--           restore app.vehicles_log_movement() and app.vehicles_guard_status() from 0036/0017;
--           alter table public.vehicles drop constraint vehicles_status_check, re-add without RETURNED;
--           delete from public.document_sequences where doc_type = 'PURCHASE_RETURN';
--           delete from public.permissions where code = 'purchases.return';
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A bill line becomes addressable by a composite tenant key
-- -----------------------------------------------------------------------------
-- Every foreign key in this schema carries (id, dealer_id) so it cannot cross a
-- tenant boundary even if the application asks it to. purchase_bill_lines had
-- never been the target of one; it is now.
-- -----------------------------------------------------------------------------
alter table public.purchase_bill_lines
  add constraint pbl_id_dealer_key unique (id, dealer_id);

-- -----------------------------------------------------------------------------
-- vehicles.status gains RETURNED
-- -----------------------------------------------------------------------------
alter table public.vehicles drop constraint vehicles_status_check;
alter table public.vehicles add constraint vehicles_status_check check (status in (
  'IN_STOCK', 'BOOKED', 'SOLD_PENDING_DELIVERY', 'DELIVERED', 'TRANSFERRED',
  'RETURNED', 'CANCELLED'
));

-- The lifecycle guard from 0017, with the two new moves. IN_STOCK is the only
-- way in, because a vehicle that is booked, sold or in transit is not the
-- dealer's to send back; IN_STOCK is the only way out, and only a reversal of
-- the debit note takes it.
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
    when 'IN_STOCK'              then array['BOOKED', 'SOLD_PENDING_DELIVERY', 'TRANSFERRED', 'RETURNED', 'CANCELLED']
    when 'BOOKED'                then array['IN_STOCK', 'SOLD_PENDING_DELIVERY', 'CANCELLED']
    when 'SOLD_PENDING_DELIVERY' then array['DELIVERED', 'IN_STOCK', 'CANCELLED']
    when 'TRANSFERRED'           then array['IN_STOCK', 'CANCELLED']
    -- Sent back to the supplier. Comes back only if the debit note is reversed.
    when 'RETURNED'              then array['IN_STOCK']
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

-- The stock ledger has to label the two new movements. Everything else is
-- exactly as 0036 left it: the trigger stays the sole writer of the log, and the
-- causing document still arrives in app.vehicle_movement_ref.
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
              -- Back to the supplier, and back again if the note is reversed.
              when new.status = 'RETURNED'                       then 'RETURN'
              when old.status = 'RETURNED'                       then 'REVERSAL'
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
  'Sole writer of the vehicle stock ledger (spec §34). Labels transfers, sale '
  'returns and purchase returns from the status pair, and takes the causing '
  'document from the transaction-local setting app.vehicle_movement_ref.';

-- -----------------------------------------------------------------------------
-- purchase_returns — the debit note
-- -----------------------------------------------------------------------------
create table public.purchase_returns (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null references public.dealers (id) on delete restrict,
  branch_id        uuid not null,

  return_number    text not null,
  -- The bill the goods came in on. A return always has one: what is being sent
  -- back was bought at a price, on a date, at a tax rate, and those are the
  -- figures the credit has to use.
  purchase_bill_id uuid not null,
  -- Denormalised from the bill so the supplier's own list is one index lookup.
  -- The posting function is the only writer and copies it from the bill.
  supplier_id      uuid not null,

  return_date      date not null default current_date,
  -- Their credit note number, when they have issued one. Not unique: a supplier
  -- may not have raised it yet, and two may reuse a number.
  supplier_ref     text,

  status           text not null default 'DRAFT',

  -- Why. Required, because a debit note without one is unexplainable a year
  -- later, and it is written onto the accounting narration (spec §23).
  reason           text not null,

  taxable_value    numeric(18, 4) not null default 0,
  cgst_amount      numeric(18, 4) not null default 0,
  sgst_amount      numeric(18, 4) not null default 0,
  igst_amount      numeric(18, 4) not null default 0,
  total_amount     numeric(18, 4) not null default 0,

  notes            text,
  journal_entry_id uuid,
  -- A duplicate submission returns the first note rather than sending the goods
  -- back twice (spec §50). Supplied by the browser, one per dialog.
  idempotency_key  text,

  posted_at        timestamptz,
  posted_by        uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       uuid,
  updated_by       uuid,

  constraint purchase_returns_number_key    unique (dealer_id, return_number),
  constraint purchase_returns_id_dealer_key unique (id, dealer_id),
  constraint purchase_returns_idempotency_key unique (dealer_id, idempotency_key),

  constraint purchase_returns_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint purchase_returns_bill_tenant_fkey
    foreign key (purchase_bill_id, dealer_id) references public.purchase_bills (id, dealer_id),
  constraint purchase_returns_supplier_tenant_fkey
    foreign key (supplier_id, dealer_id) references public.suppliers (id, dealer_id),
  constraint purchase_returns_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),

  constraint purchase_returns_status_check check (status in ('DRAFT', 'POSTED', 'CANCELLED')),
  constraint purchase_returns_reason_check check (length(btrim(reason)) between 1 and 500),
  constraint purchase_returns_amounts_check check (
    taxable_value >= 0 and cgst_amount >= 0 and sgst_amount >= 0
    and igst_amount >= 0 and total_amount >= 0
  ),
  constraint purchase_returns_posted_stamp_check check (
    status <> 'POSTED' or (posted_at is not null and journal_entry_id is not null)
  )
);

comment on table public.purchase_returns is
  'Debit note against a purchase bill (spec §24, §34, §41). Takes part of a '
  'consignment back off the books at the cost it came in at, reverses its input '
  'GST and reduces what is owed to the supplier.';
comment on column public.purchase_returns.status is
  'DRAFT exists only inside post_purchase_return(), which creates the note and '
  'posts it in one transaction. Nothing in the product leaves one in DRAFT.';

create index purchase_returns_bill_idx     on public.purchase_returns (purchase_bill_id);
create index purchase_returns_supplier_idx on public.purchase_returns (supplier_id, return_date desc);
create index purchase_returns_dealer_idx   on public.purchase_returns (dealer_id, return_date desc);
create index purchase_returns_branch_idx   on public.purchase_returns (branch_id, return_date desc);
create index purchase_returns_status_idx   on public.purchase_returns (dealer_id, status);

-- -----------------------------------------------------------------------------
-- purchase_return_lines — what is going back, and off which bill line
-- -----------------------------------------------------------------------------
-- Every line points at the bill line it reverses. That is what makes "how much
-- of this line is still returnable" answerable, and it carries the rate and the
-- tax split forward so the credit is at the price actually paid rather than at
-- whatever the item costs today.
-- -----------------------------------------------------------------------------
create table public.purchase_return_lines (
  id                   uuid primary key default gen_random_uuid(),
  purchase_return_id   uuid not null,
  dealer_id            uuid not null,
  purchase_bill_line_id uuid not null,

  line_number    smallint not null,
  line_type      text not null,

  vehicle_id     uuid,
  item_id        uuid,
  source         text,

  description    text not null,
  quantity       numeric(18, 3) not null,
  unit_rate      numeric(18, 4) not null,

  taxable_value  numeric(18, 4) not null,
  cgst_amount    numeric(18, 4) not null default 0,
  sgst_amount    numeric(18, 4) not null default 0,
  igst_amount    numeric(18, 4) not null default 0,
  total_amount   numeric(18, 4) not null,

  created_at     timestamptz not null default now(),

  constraint prl_return_line_key unique (purchase_return_id, line_number),
  constraint prl_return_tenant_fkey
    foreign key (purchase_return_id, dealer_id)
    references public.purchase_returns (id, dealer_id) on delete cascade,
  constraint prl_bill_line_tenant_fkey
    foreign key (purchase_bill_line_id, dealer_id)
    references public.purchase_bill_lines (id, dealer_id),
  constraint prl_vehicle_tenant_fkey
    foreign key (vehicle_id, dealer_id) references public.vehicles (id, dealer_id),
  constraint prl_item_tenant_fkey
    foreign key (item_id, dealer_id) references public.inventory_items (id, dealer_id),

  constraint prl_type_check check (line_type in ('VEHICLE', 'ACCESSORY', 'SPARE')),
  constraint prl_source_check check (source is null or source in ('LOCAL', 'COMPANY')),
  -- The same shapes the bill line has: a chassis goes back whole, a counted item
  -- goes back from the lot it joined (spec §28).
  constraint prl_shape_check check (
    (line_type = 'VEHICLE'
       and vehicle_id is not null and item_id is null and source is null and quantity = 1)
    or (line_type <> 'VEHICLE'
       and item_id is not null and vehicle_id is null and source is not null and quantity > 0)
  ),
  constraint prl_amounts_check check (
    unit_rate >= 0 and taxable_value >= 0 and total_amount >= 0
    and cgst_amount >= 0 and sgst_amount >= 0 and igst_amount >= 0
  ),
  constraint prl_tax_split_check check (
    (igst_amount = 0) or (cgst_amount = 0 and sgst_amount = 0)
  ),
  constraint prl_line_number_check check (line_number > 0)
);

comment on table public.purchase_return_lines is
  'What is going back to the supplier, against the bill line it came in on '
  '(spec §34). Priced at the bill''s rate, never at today''s cost.';

-- One chassis goes back once. A second note for the same vehicle is a duplicate,
-- and the returnable-quantity check would already have refused it — this makes
-- it impossible rather than merely checked (spec §49, §50).
create unique index purchase_return_lines_vehicle_key
  on public.purchase_return_lines (vehicle_id) where vehicle_id is not null;

create index purchase_return_lines_return_idx on public.purchase_return_lines (purchase_return_id);
create index purchase_return_lines_bill_line_idx on public.purchase_return_lines (purchase_bill_line_id);
create index purchase_return_lines_item_idx on public.purchase_return_lines (item_id) where item_id is not null;

-- -----------------------------------------------------------------------------
-- The note's number, issued by the database
-- -----------------------------------------------------------------------------
create or replace function app.purchase_returns_assign_number()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_year text;
begin
  if new.return_number is not null and btrim(new.return_number) <> '' then
    return new;
  end if;

  v_year := app.financial_year_token(new.dealer_id, coalesce(new.return_date, current_date));

  insert into public.document_sequences (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
  values (new.dealer_id, null, 'PURCHASE_RETURN', v_year, 'PR', 6)
  on conflict on constraint document_sequences_scope_key do nothing;

  new.return_number := app.next_document_number(new.dealer_id, null, 'PURCHASE_RETURN', v_year);
  return new;
end;
$$;

create trigger purchase_returns_assign_number
  before insert on public.purchase_returns
  for each row execute function app.purchase_returns_assign_number();

-- -----------------------------------------------------------------------------
-- A posted note is immutable, and no note is ever deleted
-- -----------------------------------------------------------------------------
create or replace function app.purchase_returns_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Purchase return % cannot be deleted.', old.return_number
      using errcode = 'insufficient_privilege',
            hint = 'Spec §23: corrections use reversal, not deletion.';
  end if;

  -- A note is born as a draft, the same way a journal is (0007). Declaring one
  -- POSTED on the way in would put a document on the supplier's ledger that
  -- moved no stock and wrote no journal.
  if tg_op = 'INSERT' then
    if new.status <> 'DRAFT' then
      raise exception 'A purchase return is created as DRAFT and posted by post_purchase_return(); got %.',
        new.status using errcode = 'check_violation';
    end if;
    return new;
  end if;

  -- DRAFT exists only for the moment inside post_purchase_return() between
  -- writing the note and posting its journal. A note reaching POSTED by any
  -- other route would carry no stock movements and no accounting: the journal
  -- named has to be one that points back at this very note.
  if old.status = 'DRAFT' and new.status = 'POSTED' then
    if not exists (
      select 1 from public.journal_entries je
       where je.id = new.journal_entry_id
         and je.source_document_type = 'PURCHASE_RETURN'
         and je.source_document_id = new.id
    ) then
      raise exception 'A purchase return is posted by post_purchase_return(), not by hand.'
        using errcode = 'insufficient_privilege';
    end if;
  end if;

  if old.status = 'POSTED' then
    -- Only the cancellation the reverse path writes may change.
    if not (new.status = 'CANCELLED'
            and (to_jsonb(new) - 'status' - 'notes' - 'updated_at' - 'updated_by')
                = (to_jsonb(old) - 'status' - 'notes' - 'updated_at' - 'updated_by')) then
      raise exception 'Purchase return % is POSTED and immutable.', old.return_number
        using errcode = 'insufficient_privilege',
              hint = 'Spec §23: reverse it instead of editing.';
    end if;
  end if;

  if old.status = 'CANCELLED' and new.status <> 'CANCELLED' then
    raise exception 'Purchase return % is reversed and cannot be reopened.', old.return_number
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end;
$$;

-- INSERT is guarded too: the status a note is born with is as load-bearing as
-- the ones it may move to.
create trigger purchase_returns_guard
  before insert or update or delete on public.purchase_returns
  for each row execute function app.purchase_returns_guard();

-- Lines are written once, by the posting function, inside the transaction that
-- creates the note. Nothing edits them afterwards.
create trigger purchase_return_lines_append_only
  before update or delete on public.purchase_return_lines
  for each row execute function app.forbid_mutation();

create trigger purchase_returns_set_updated_at
  before update on public.purchase_returns
  for each row execute function app.set_updated_at();

create trigger purchase_returns_audit
  after insert or update or delete on public.purchase_returns
  for each row execute function app.audit_trigger();

-- -----------------------------------------------------------------------------
-- Row Level Security
-- -----------------------------------------------------------------------------
alter table public.purchase_returns      enable row level security;
alter table public.purchase_return_lines enable row level security;

create policy purchase_returns_select on public.purchase_returns
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and app.has_permission('purchases.view'))
  );

create policy purchase_returns_insert on public.purchase_returns
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and app.has_permission('purchases.return'))
  );

-- The DRAFT → POSTED flip inside the posting function, and the cancellation.
-- The guard above decides what an update may actually contain.
create policy purchase_returns_update on public.purchase_returns
  for update to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and (app.has_permission('purchases.return') or app.has_permission('purchases.cancel')))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and (app.has_permission('purchases.return') or app.has_permission('purchases.cancel')))
  );

-- Deliberately no delete policy: a debit note is a document, not a draft.

create policy purchase_return_lines_select on public.purchase_return_lines
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and exists (
          select 1 from public.purchase_returns r
           where r.id = purchase_return_lines.purchase_return_id
             and app.can_access_branch(r.branch_id)
        )
        and app.has_permission('purchases.view'))
  );

create policy purchase_return_lines_insert on public.purchase_return_lines
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('purchases.return'))
  );

-- -----------------------------------------------------------------------------
-- public.returnable_purchase_lines() — what is left to send back
-- -----------------------------------------------------------------------------
-- Billed, less everything already returned on posted notes. Invoker-rights, so
-- it shows only what the caller's branches and permissions already allow.
-- -----------------------------------------------------------------------------
create or replace function public.returnable_purchase_lines(p_bill_id uuid)
returns table (
  bill_line_id        uuid,
  line_number         smallint,
  line_type           text,
  description         text,
  source              text,
  chassis_no          text,
  item_code           text,
  vehicle_status      text,
  billed_quantity     numeric(18, 3),
  returned_quantity   numeric(18, 3),
  returnable_quantity numeric(18, 3),
  unit_rate           numeric(18, 4),
  cgst_rate           numeric(6, 3),
  sgst_rate           numeric(6, 3),
  igst_rate           numeric(6, 3)
)
language sql
stable
as $$
  select l.id, l.line_number, l.line_type, l.description, l.source,
         v.chassis_no, i.item_code, v.status,
         l.quantity,
         coalesce(r.returned, 0)::numeric(18, 3),
         (l.quantity - coalesce(r.returned, 0))::numeric(18, 3),
         l.unit_rate, l.cgst_rate, l.sgst_rate, l.igst_rate
    from public.purchase_bill_lines l
    left join public.vehicles v on v.id = l.vehicle_id
    left join public.inventory_items i on i.id = l.item_id
    left join lateral (
      select sum(rl.quantity) as returned
        from public.purchase_return_lines rl
        join public.purchase_returns pr on pr.id = rl.purchase_return_id
       where rl.purchase_bill_line_id = l.id
         and pr.status = 'POSTED'
    ) r on true
   where l.purchase_bill_id = p_bill_id
   order by l.line_number;
$$;

comment on function public.returnable_purchase_lines(uuid) is
  'Bill lines with how much of each has already gone back (spec §34), so a '
  'debit note cannot return more than arrived.';

-- -----------------------------------------------------------------------------
-- public.post_purchase_return() — the debit note, in one transaction
-- -----------------------------------------------------------------------------
-- Spec §48: the note, its lines, the stock movements and the journal all commit
-- together or not at all. p_lines is [{ "bill_line_id": uuid, "quantity": n }].
-- -----------------------------------------------------------------------------
create or replace function public.post_purchase_return(
  p_bill_id         uuid,
  p_lines           jsonb,
  p_reason          text,
  p_return_date     date default current_date,
  p_supplier_ref    text default null,
  p_idempotency_key text default null
)
returns table (
  return_id     uuid,
  return_number text,
  entry_id      uuid,
  total         numeric(18, 4)
)
language plpgsql
as $$
declare
  v_bill        public.purchase_bills;
  v_return      public.purchase_returns;
  v_line        public.purchase_bill_lines;
  v_req         jsonb;
  v_veh         record;
  v_account     uuid;
  v_entry       uuid;
  v_index       smallint := 0;
  v_qty         numeric(18, 3);
  v_returned    numeric(18, 3);
  v_ret_taxable numeric(18, 4);
  v_ret_cgst    numeric(18, 4);
  v_ret_sgst    numeric(18, 4);
  v_ret_igst    numeric(18, 4);
  v_taxable     numeric(18, 4);
  v_cgst        numeric(18, 4);
  v_sgst        numeric(18, 4);
  v_igst        numeric(18, 4);
  v_share       numeric;
  v_sum_taxable numeric(18, 4) := 0;
  v_sum_cgst    numeric(18, 4) := 0;
  v_sum_sgst    numeric(18, 4) := 0;
  v_sum_igst    numeric(18, 4) := 0;
  v_sum_total   numeric(18, 4) := 0;
  v_entries     jsonb := '[]'::jsonb;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A purchase return requires a reason.'
      using errcode = 'check_violation',
            hint = 'Spec §23: the reason is part of the record, not optional.';
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Choose at least one line to send back.'
      using errcode = 'check_violation';
  end if;

  -- Locked for the rest of the transaction, so two notes against the same bill
  -- cannot each believe the same quantity is still returnable (spec §49).
  select * into v_bill from public.purchase_bills where id = p_bill_id for update;

  if v_bill.id is null then
    raise exception 'Purchase bill not found.' using errcode = 'no_data_found';
  end if;
  if v_bill.status <> 'POSTED' then
    raise exception
      'Purchase bill % is % — only a posted bill has stock on the books to send back.',
      v_bill.bill_number, v_bill.status using errcode = 'check_violation';
  end if;

  -- A repeated submission returns the note the first one wrote rather than
  -- sending the goods back twice (spec §50).
  if p_idempotency_key is not null then
    select * into v_return from public.purchase_returns
     where dealer_id = v_bill.dealer_id and idempotency_key = p_idempotency_key;
    if v_return.id is not null then
      return query select v_return.id, v_return.return_number,
                          v_return.journal_entry_id, v_return.total_amount;
      return;
    end if;
  end if;

  insert into public.purchase_returns
    (dealer_id, branch_id, purchase_bill_id, supplier_id, return_date,
     supplier_ref, reason, idempotency_key, created_by)
  values
    (v_bill.dealer_id, v_bill.branch_id, p_bill_id, v_bill.supplier_id,
     coalesce(p_return_date, current_date), nullif(btrim(p_supplier_ref), ''),
     btrim(p_reason), p_idempotency_key, auth.uid())
  returning * into v_return;

  -- ── Every line: what goes back, off the books, and out of stock ───────────
  for v_req in select value from jsonb_array_elements(p_lines) loop
    v_index := v_index + 1;

    select * into v_line from public.purchase_bill_lines
     where id = (v_req->>'bill_line_id')::uuid
       and purchase_bill_id = p_bill_id;

    if v_line.id is null then
      raise exception 'A line being returned is not on bill %.', v_bill.bill_number
        using errcode = 'no_data_found';
    end if;

    v_qty := round(coalesce((v_req->>'quantity')::numeric, 0), 3);
    if v_qty <= 0 then
      raise exception 'Line % has nothing to return. Enter a quantity above zero.',
        v_line.line_number using errcode = 'check_violation';
    end if;

    -- What has already gone back on this bill line, and at what value. Both are
    -- needed: the quantity to cap this note, the value so the last return of a
    -- line takes the exact remainder rather than a rounded share of it.
    select coalesce(sum(rl.quantity), 0), coalesce(sum(rl.taxable_value), 0),
           coalesce(sum(rl.cgst_amount), 0), coalesce(sum(rl.sgst_amount), 0),
           coalesce(sum(rl.igst_amount), 0)
      into v_returned, v_ret_taxable, v_ret_cgst, v_ret_sgst, v_ret_igst
      from public.purchase_return_lines rl
      join public.purchase_returns pr on pr.id = rl.purchase_return_id
     where rl.purchase_bill_line_id = v_line.id
       and pr.status = 'POSTED';

    if v_qty > v_line.quantity - v_returned then
      raise exception
        'Line % has % of % left to return; % is more than arrived.',
        v_line.line_number, v_line.quantity - v_returned, v_line.quantity, v_qty
        using errcode = 'check_violation';
    end if;

    if v_qty = v_line.quantity - v_returned then
      -- The remainder, exactly. Rounding cannot accumulate across part returns
      -- and leave a few paise of stock on the books for ever.
      v_taxable := v_line.taxable_value - v_ret_taxable;
      v_cgst    := v_line.cgst_amount   - v_ret_cgst;
      v_sgst    := v_line.sgst_amount   - v_ret_sgst;
      v_igst    := v_line.igst_amount   - v_ret_igst;
    else
      v_share   := v_qty / v_line.quantity;
      v_taxable := round(v_line.taxable_value * v_share, 4);
      v_cgst    := round(v_line.cgst_amount   * v_share, 4);
      v_sgst    := round(v_line.sgst_amount   * v_share, 4);
      v_igst    := round(v_line.igst_amount   * v_share, 4);
    end if;

    if v_line.line_type = 'VEHICLE' then
      if v_qty <> 1 then
        raise exception 'A vehicle goes back whole; % of one cannot be returned.', v_qty
          using errcode = 'check_violation';
      end if;

      select id, status, chassis_no into v_veh
        from public.vehicles where id = v_line.vehicle_id for update;

      if v_veh.id is null then
        raise exception 'The vehicle on line % no longer exists.', v_line.line_number
          using errcode = 'no_data_found';
      end if;
      -- Booked, sold or in transit, it is not the dealer's to send back.
      if v_veh.status <> 'IN_STOCK' then
        raise exception
          'Chassis % is % — only a vehicle still in stock can go back to the supplier.',
          v_veh.chassis_no, v_veh.status using errcode = 'check_violation';
      end if;

      -- The RETURN ledger row is written by app.vehicles_log_movement(), which
      -- reads this setting to record what the movement was for.
      perform set_config('app.vehicle_movement_ref', 'PURCHASE_RETURN:' || v_return.id, true);
      update public.vehicles
         set status = 'RETURNED', updated_by = auth.uid()
       where id = v_line.vehicle_id;
      perform set_config('app.vehicle_movement_ref', '', true);

      v_account := app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE',
                                       'VEHICLE_INVENTORY', v_bill.branch_id);
    else
      -- Out of the lot it joined, never merged with the other one (spec §28,
      -- §60.16). The movement is what reduces the quantity (spec §34), and the
      -- trigger on inventory_transactions refuses to drive the lot negative.
      insert into public.inventory_transactions
        (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
         reference_type, reference_id, reference_number, narration, reason, created_by)
      values
        (v_bill.dealer_id, v_bill.branch_id, v_line.item_id, v_line.source, 'RETURN',
         -v_qty, round(v_taxable / v_qty, 4),
         'PURCHASE_RETURN', v_return.id, v_return.return_number,
         'Returned to supplier on ' || v_return.return_number, btrim(p_reason), auth.uid());

      v_account := app.require_account(
        v_bill.dealer_id, 'INVENTORY', 'PURCHASE',
        case when v_line.line_type = 'ACCESSORY' then 'ACCESSORY_INVENTORY'
             else 'SPARE_INVENTORY' end,
        v_bill.branch_id);
    end if;

    insert into public.purchase_return_lines
      (purchase_return_id, dealer_id, purchase_bill_line_id, line_number, line_type,
       vehicle_id, item_id, source, description, quantity, unit_rate,
       taxable_value, cgst_amount, sgst_amount, igst_amount, total_amount)
    values
      (v_return.id, v_bill.dealer_id, v_line.id, v_index, v_line.line_type,
       v_line.vehicle_id, v_line.item_id, v_line.source, v_line.description,
       v_qty, v_line.unit_rate,
       v_taxable, v_cgst, v_sgst, v_igst, v_taxable + v_cgst + v_sgst + v_igst);

    -- The credit that takes it off the balance sheet, at the cost it came in at.
    v_entries := v_entries || jsonb_build_object(
      'account_id', v_account, 'debit', 0, 'credit', v_taxable,
      'narration', 'Returned: ' || v_line.description);

    v_sum_taxable := v_sum_taxable + v_taxable;
    v_sum_cgst    := v_sum_cgst + v_cgst;
    v_sum_sgst    := v_sum_sgst + v_sgst;
    v_sum_igst    := v_sum_igst + v_igst;
  end loop;

  v_sum_total := v_sum_taxable + v_sum_cgst + v_sum_sgst + v_sum_igst;

  if v_sum_total <= 0 then
    raise exception 'This return comes to nothing. Check the quantities.'
      using errcode = 'check_violation';
  end if;

  -- ── Input GST goes back too: credit that is no longer claimable ───────────
  if v_sum_cgst > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_CGST', v_bill.branch_id),
      'debit', 0, 'credit', v_sum_cgst, 'narration', 'Input CGST reversed ' || v_return.return_number);
  end if;
  if v_sum_sgst > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_SGST', v_bill.branch_id),
      'debit', 0, 'credit', v_sum_sgst, 'narration', 'Input SGST reversed ' || v_return.return_number);
  end if;
  if v_sum_igst > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_IGST', v_bill.branch_id),
      'debit', 0, 'credit', v_sum_igst, 'narration', 'Input IGST reversed ' || v_return.return_number);
  end if;

  -- ── And the one debit: what the dealer no longer owes ─────────────────────
  -- Party-tagged, so it lands on the supplier's own ledger as an open debit that
  -- bill-wise settlement (0050) can knock off the bill it came from.
  v_entries := v_entries || jsonb_build_object(
    'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'PAYABLE', v_bill.branch_id),
    'debit', v_sum_total, 'credit', 0,
    'narration', 'Debit note ' || v_return.return_number || ' on ' || v_bill.supplier_bill_number,
    'party_type', 'SUPPLIER', 'party_id', v_bill.supplier_id);

  update public.purchase_returns
     set taxable_value = v_sum_taxable,
         cgst_amount   = v_sum_cgst,
         sgst_amount   = v_sum_sgst,
         igst_amount   = v_sum_igst,
         total_amount  = v_sum_total
   where id = v_return.id;

  v_entry := app.post_journal(
    v_bill.dealer_id, v_bill.branch_id, coalesce(p_return_date, current_date), 'INVENTORY',
    'Purchase return ' || v_return.return_number || ' — ' || v_bill.bill_number,
    v_entries,
    'PURCHASE_RETURN', v_return.id,
    'purchase-return:' || v_return.id::text
  );

  update public.purchase_returns
     set status = 'POSTED', journal_entry_id = v_entry,
         posted_at = now(), posted_by = auth.uid(), updated_by = auth.uid()
   where id = v_return.id;

  return query select v_return.id, v_return.return_number, v_entry, v_sum_total;
end;
$$;

comment on function public.post_purchase_return(uuid, jsonb, text, date, text, text) is
  'Sends part of a purchase bill back to the supplier (spec §21, §34, §48): '
  'stock out at the cost it came in at, input GST reversed, and the payable '
  'reduced on the supplier''s ledger. Idempotent (spec §50).';

-- -----------------------------------------------------------------------------
-- public.cancel_purchase_return() — the note itself was wrong
-- -----------------------------------------------------------------------------
-- The goods never went, or went on the wrong note. The journal is reversed by a
-- second entry, the stock comes back into the lot it left, and a returned
-- chassis returns to stock. The note stays on the record (spec §23).
-- -----------------------------------------------------------------------------
create or replace function public.cancel_purchase_return(
  p_return_id uuid,
  p_reason    text
)
returns uuid
language plpgsql
as $$
declare
  v_return public.purchase_returns;
  v_line   record;
  v_entry  uuid;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'Reversing a purchase return requires a reason.'
      using errcode = 'check_violation',
            hint = 'Spec §23: the reason is part of the record, not optional.';
  end if;

  select * into v_return from public.purchase_returns where id = p_return_id for update;

  if v_return.id is null then
    raise exception 'Purchase return not found.' using errcode = 'no_data_found';
  end if;
  if v_return.status <> 'POSTED' then
    raise exception 'Purchase return % is % and cannot be reversed.',
      v_return.return_number, v_return.status using errcode = 'check_violation';
  end if;

  v_entry := app.reverse_journal(v_return.journal_entry_id, btrim(p_reason), current_date);

  for v_line in
    select * from public.purchase_return_lines
     where purchase_return_id = p_return_id
     order by line_number
  loop
    if v_line.line_type = 'VEHICLE' then
      perform set_config('app.vehicle_movement_ref', 'PURCHASE_RETURN:' || p_return_id, true);
      update public.vehicles
         set status = 'IN_STOCK', updated_by = auth.uid()
       where id = v_line.vehicle_id;
      perform set_config('app.vehicle_movement_ref', '', true);
    else
      insert into public.inventory_transactions
        (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
         reference_type, reference_id, reference_number, narration, reason, created_by)
      values
        (v_return.dealer_id, v_return.branch_id, v_line.item_id, v_line.source, 'REVERSAL',
         v_line.quantity, round(v_line.taxable_value / v_line.quantity, 4),
         'PURCHASE_RETURN', p_return_id, v_return.return_number,
         'Reversed ' || v_return.return_number, btrim(p_reason), auth.uid());
    end if;
  end loop;

  update public.purchase_returns
     set status = 'CANCELLED', updated_by = auth.uid(),
         notes = coalesce(notes || E'\n', '') || 'Reversed: ' || btrim(p_reason)
   where id = p_return_id;

  return v_entry;
end;
$$;

comment on function public.cancel_purchase_return(uuid, text) is
  'Reverses a posted debit note (spec §23): a second journal undoes the first '
  'and the stock comes back into the lot it left.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.purchase_returns to authenticated';
    execute 'grant select, insert on public.purchase_return_lines to authenticated';
    execute 'grant all on public.purchase_returns to service_role';
    execute 'grant all on public.purchase_return_lines to service_role';
    execute 'grant execute on function public.returnable_purchase_lines(uuid) to authenticated';
    execute 'grant execute on function public.post_purchase_return(uuid, jsonb, text, date, text, text) to authenticated';
    execute 'grant execute on function public.cancel_purchase_return(uuid, text) to authenticated';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Permissions
-- -----------------------------------------------------------------------------
-- Separate from purchases.create: entering what arrived and deciding that some
-- of it goes back are different authorities, and the second one moves stock off
-- the books (spec §6).
-- -----------------------------------------------------------------------------
insert into public.permissions (code, module, description, is_sensitive) values
  ('purchases.return', 'purchases', 'Return purchased stock to a supplier (debit note)', false)
on conflict (code) do update
  set module      = excluded.module,
      description = excluded.description;

insert into public.role_permissions (role_id, permission_code)
select r.id, 'purchases.return'
  from public.roles r
 where r.is_system and r.code in ('DEALER_OWNER', 'ACCOUNTS')
on conflict do nothing;


commit;
