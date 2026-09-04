-- =============================================================================
-- 0052 — Purchase bills: how stock and the payable get onto the books
-- =============================================================================
-- Spec §21, §22, §24, §28, §29, §34, §41, §44, §45, §48, §50, §59, §60.22.
--
-- The hole this fills. Migration 0027 seeded accounting rules for
-- INVENTORY/PURCHASE — inventory debit, payable credit — and in the two years of
-- migrations since, nothing has ever posted them. There is no purchase document
-- in the product at all. So:
--
--   * stock arrives through the CSV uploads (spec §14) which create the chassis
--     and the quantity but write no journal, so 1500/1600/1700 are never
--     debited — only credited, by COGS when the thing is sold;
--   * account 2200 Supplier Payables is only ever debited, by cash and bank
--     payments tagged to a supplier (0041). A supplier's subsidiary ledger has
--     the payments and none of the bills they pay;
--   * there is nowhere to record input GST, so no ITC is tracked. The chart of
--     accounts has Output CGST/SGST/IGST and no input counterpart.
--
-- A dealer running this today has a balance sheet where inventory drifts
-- negative with every sale and a supplier ledger that reads as though every
-- supplier owes the dealer money.
--
-- ── The document ────────────────────────────────────────────────────────────
--
-- One bill, three kinds of line, matching the three stock accounts:
--
--     VEHICLE   → 1500 Vehicle Inventory      (chassis-level, spec §13)
--     ACCESSORY → 1600 Accessories Inventory  (quantity, LOCAL/COMPANY lot §28)
--     SPARE     → 1700 Spare Inventory        (quantity, §29)
--     input GST → 1900/1910/1920              (added below)
--     total     → 2200 Supplier Payables, tagged with the supplier
--
-- Vehicle lines POINT AT a chassis the CSV upload already created rather than
-- creating one. Spec §14 makes the upload the way vehicle stock is registered,
-- and a second door into the same table is how the same chassis ends up in stock
-- twice. A unique index makes a vehicle billable exactly once, so the "not yet
-- billed" list is a fact rather than a convention.
--
-- Accessory and spare lines are the opposite: those items are counted, not
-- identified, so the bill CREATES the PURCHASE movement (spec §34 — quantity is
-- never written directly, it follows from movements).
--
-- ── Draft, then posted ──────────────────────────────────────────────────────
--
-- A bill is built as a DRAFT and edited freely. Posting is the moment it becomes
-- accounting: one transaction writes the journal, capitalises the vehicles,
-- moves the stock and freezes the bill (spec §48). After that it is immutable
-- and corrected only by reversal (spec §23).
--
-- Rollback: drop function public.post_purchase_bill(uuid, text);
--           drop function public.cancel_purchase_bill(uuid, text);
--           drop table public.purchase_bill_lines, public.purchase_bills;
--           drop function app.purchase_bills_assign_number(), app.purchase_bills_guard(),
--                         app.purchase_bill_lines_sync_totals(), app.seed_purchase_accounting_rules(uuid);
--           delete from public.chart_of_accounts where code in ('1900','1910','1920');
--           delete from public.document_sequences where doc_type = 'PURCHASE_BILL';
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Input GST — the asset side of the tax the dealer pays on a purchase
-- -----------------------------------------------------------------------------
-- Input tax credit is money the government owes back, so these are assets, and
-- they are deliberately NOT branch-scoped: a GST registration is per state, not
-- per showroom, and the return is filed on the registration.
-- -----------------------------------------------------------------------------
do $$
declare
  d      record;
  a      record;
  v_parent uuid;
begin
  for d in select id from public.dealers loop
    select id into v_parent from public.chart_of_accounts
     where dealer_id = d.id and code = '1000';

    for a in
      select * from (values
        ('1900', 'Input CGST'),
        ('1910', 'Input SGST'),
        ('1920', 'Input IGST')
      ) as t(code, name)
    loop
      insert into public.chart_of_accounts
        (dealer_id, code, name, account_type, normal_balance, is_group, parent_id,
         is_system, is_branch_scoped)
      values
        (d.id, a.code, a.name, 'ASSET', 'DEBIT', false, v_parent, true, false)
      on conflict on constraint coa_dealer_code_key do nothing;
    end loop;
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- The accounting rules a purchase resolves through
-- -----------------------------------------------------------------------------
-- Accounts are never hard-coded (spec §22); the posting function asks for a
-- component and the rule says which account that is for this dealer. 0027
-- already mapped INVENTORY / PURCHASE / INVENTORY, PAYABLE and VEHICLE_INVENTORY;
-- these are the ones it was missing.
-- -----------------------------------------------------------------------------
create or replace function app.seed_purchase_accounting_rules(p_dealer_id uuid)
returns integer
language plpgsql
as $$
declare
  v_added   integer := 0;
  v_rule    record;
  v_account uuid;
begin
  for v_rule in
    select * from (values
      ('INVENTORY', 'PURCHASE', 'ACCESSORY_INVENTORY', 'DEBIT', '1600'),
      ('INVENTORY', 'PURCHASE', 'SPARE_INVENTORY',     'DEBIT', '1700'),
      ('INVENTORY', 'PURCHASE', 'INPUT_CGST',          'DEBIT', '1900'),
      ('INVENTORY', 'PURCHASE', 'INPUT_SGST',          'DEBIT', '1910'),
      ('INVENTORY', 'PURCHASE', 'INPUT_IGST',          'DEBIT', '1920')
    ) as t(module, event, component, side, account_code)
  loop
    select id into v_account from public.chart_of_accounts
     where dealer_id = p_dealer_id and code = v_rule.account_code;
    continue when v_account is null;

    insert into public.accounting_rules
      (dealer_id, module, event, component, side, account_id, description)
    values
      (p_dealer_id, v_rule.module, v_rule.event, v_rule.component, v_rule.side,
       v_account, 'Purchase bills (0052)')
    on conflict do nothing;

    if found then v_added := v_added + 1; end if;
  end loop;

  return v_added;
end;
$$;

do $$
declare d record;
begin
  for d in select id from public.dealers loop
    perform app.seed_purchase_accounting_rules(d.id);
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- purchase_bills
-- -----------------------------------------------------------------------------
create table public.purchase_bills (
  id                  uuid primary key default gen_random_uuid(),
  dealer_id           uuid not null references public.dealers (id) on delete restrict,
  branch_id           uuid not null,

  -- Ours, for the audit trail and the document register (spec §45).
  bill_number         text not null,
  -- Theirs. Two suppliers may legitimately use the same number, so this is
  -- unique per supplier rather than per dealer.
  supplier_bill_number text not null,

  supplier_id         uuid not null,
  bill_date           date not null default current_date,
  due_date            date,

  status              text not null default 'DRAFT',

  -- Maintained from the lines by trigger; never written by the client.
  taxable_value       numeric(18, 4) not null default 0,
  cgst_amount         numeric(18, 4) not null default 0,
  sgst_amount         numeric(18, 4) not null default 0,
  igst_amount         numeric(18, 4) not null default 0,
  total_amount        numeric(18, 4) not null default 0,

  notes               text,
  journal_entry_id    uuid,

  posted_at           timestamptz,
  posted_by           uuid,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid,
  updated_by          uuid,

  constraint purchase_bills_number_key    unique (dealer_id, bill_number),
  constraint purchase_bills_id_dealer_key unique (id, dealer_id),
  -- The same bill keyed twice against one supplier is a duplicate, not a second
  -- purchase (spec §50).
  constraint purchase_bills_supplier_ref_key unique (supplier_id, supplier_bill_number),

  constraint purchase_bills_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint purchase_bills_supplier_tenant_fkey
    foreign key (supplier_id, dealer_id) references public.suppliers (id, dealer_id),
  constraint purchase_bills_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),

  constraint purchase_bills_status_check check (status in ('DRAFT', 'POSTED', 'CANCELLED')),
  constraint purchase_bills_amounts_check check (
    taxable_value >= 0 and cgst_amount >= 0 and sgst_amount >= 0
    and igst_amount >= 0 and total_amount >= 0
  ),
  constraint purchase_bills_supplier_ref_shape_check check (
    length(btrim(supplier_bill_number)) between 1 and 50
  ),
  constraint purchase_bills_due_check check (due_date is null or due_date >= bill_date),
  constraint purchase_bills_posted_stamp_check check (
    status <> 'POSTED' or (posted_at is not null and journal_entry_id is not null)
  )
);

comment on table public.purchase_bills is
  'Supplier bill (spec §24, §41). Brings stock onto the balance sheet and the '
  'payable onto the supplier ledger — the entry point 0027''s INVENTORY/PURCHASE '
  'rules were written for and never had.';

create index purchase_bills_supplier_idx on public.purchase_bills (supplier_id, bill_date desc);
create index purchase_bills_dealer_date_idx on public.purchase_bills (dealer_id, bill_date desc);
create index purchase_bills_branch_idx on public.purchase_bills (branch_id, bill_date desc);
create index purchase_bills_status_idx on public.purchase_bills (dealer_id, status);

-- -----------------------------------------------------------------------------
-- purchase_bill_lines
-- -----------------------------------------------------------------------------
create table public.purchase_bill_lines (
  id             uuid primary key default gen_random_uuid(),
  purchase_bill_id uuid not null,
  dealer_id      uuid not null,

  line_number    smallint not null,
  line_type      text not null,

  -- Exactly one of these, according to line_type. A vehicle is identified; an
  -- accessory or spare is counted.
  vehicle_id     uuid,
  item_id        uuid,
  -- Which lot a counted item joins (spec §28, §31). Meaningless for a vehicle.
  source         text,

  description    text not null,
  quantity       numeric(18, 3) not null,
  unit_rate      numeric(18, 4) not null,

  taxable_value  numeric(18, 4) not null,
  cgst_rate      numeric(6, 3) not null default 0,
  sgst_rate      numeric(6, 3) not null default 0,
  igst_rate      numeric(6, 3) not null default 0,
  cgst_amount    numeric(18, 4) not null default 0,
  sgst_amount    numeric(18, 4) not null default 0,
  igst_amount    numeric(18, 4) not null default 0,
  total_amount   numeric(18, 4) not null,

  created_at     timestamptz not null default now(),

  constraint pbl_bill_line_key unique (purchase_bill_id, line_number),
  constraint pbl_bill_tenant_fkey
    foreign key (purchase_bill_id, dealer_id)
    references public.purchase_bills (id, dealer_id) on delete cascade,
  constraint pbl_vehicle_tenant_fkey
    foreign key (vehicle_id, dealer_id) references public.vehicles (id, dealer_id),
  constraint pbl_item_tenant_fkey
    foreign key (item_id, dealer_id) references public.inventory_items (id, dealer_id),

  constraint pbl_type_check check (line_type in ('VEHICLE', 'ACCESSORY', 'SPARE')),
  constraint pbl_source_check check (source is null or source in ('LOCAL', 'COMPANY')),
  -- A vehicle line names a chassis and one of it; a counted line names an item,
  -- a lot and a quantity. Neither shape can borrow the other's columns.
  constraint pbl_shape_check check (
    (line_type = 'VEHICLE'
       and vehicle_id is not null and item_id is null and source is null and quantity = 1)
    or (line_type <> 'VEHICLE'
       and item_id is not null and vehicle_id is null and source is not null and quantity > 0)
  ),
  constraint pbl_amounts_check check (
    unit_rate >= 0 and taxable_value >= 0 and total_amount >= 0
    and cgst_amount >= 0 and sgst_amount >= 0 and igst_amount >= 0
  ),
  -- Intra-state is CGST+SGST, inter-state is IGST. Never both (spec §16).
  constraint pbl_tax_split_check check (
    (igst_amount = 0) or (cgst_amount = 0 and sgst_amount = 0)
  ),
  constraint pbl_line_number_check check (line_number > 0)
);

comment on table public.purchase_bill_lines is
  'What was bought. VEHICLE lines point at a chassis the upload already created '
  '(spec §14); ACCESSORY and SPARE lines create the stock movement (spec §34).';

-- Load-bearing: this is what makes "not yet billed" a fact rather than a habit.
-- One chassis, one purchase line, ever — so no vehicle can be capitalised twice
-- however many drafts are open at once (spec §49, §60.24).
create unique index purchase_bill_lines_vehicle_key
  on public.purchase_bill_lines (vehicle_id) where vehicle_id is not null;

create index purchase_bill_lines_bill_idx on public.purchase_bill_lines (purchase_bill_id);
create index purchase_bill_lines_item_idx on public.purchase_bill_lines (item_id) where item_id is not null;

-- -----------------------------------------------------------------------------
-- The bill's number, issued by the database
-- -----------------------------------------------------------------------------
-- Self-provisioning like the supplier code (0040): a purchase bill must not be
-- unrecordable because nobody configured a sequence first.
-- -----------------------------------------------------------------------------
create or replace function app.purchase_bills_assign_number()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_year text;
begin
  if new.bill_number is not null and btrim(new.bill_number) <> '' then
    return new;
  end if;

  v_year := app.financial_year_token(new.dealer_id, coalesce(new.bill_date, current_date));

  insert into public.document_sequences (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
  values (new.dealer_id, null, 'PURCHASE_BILL', v_year, 'PB', 6)
  on conflict on constraint document_sequences_scope_key do nothing;

  new.bill_number := app.next_document_number(new.dealer_id, null, 'PURCHASE_BILL', v_year);
  return new;
end;
$$;

create trigger purchase_bills_assign_number
  before insert on public.purchase_bills
  for each row execute function app.purchase_bills_assign_number();

-- -----------------------------------------------------------------------------
-- A posted bill is immutable, and lines only move while it is a draft
-- -----------------------------------------------------------------------------
create or replace function app.purchase_bills_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    if old.status <> 'DRAFT' then
      raise exception 'Purchase bill % is % and cannot be deleted.', old.bill_number, old.status
        using errcode = 'insufficient_privilege',
              hint = 'Spec §23: corrections use reversal, not deletion.';
    end if;
    return old;
  end if;

  if tg_op = 'UPDATE' and old.status = 'POSTED' then
    -- Only the reversal linkage the cancel path writes may change.
    if not (new.status = 'CANCELLED'
            and (to_jsonb(new) - 'status' - 'notes' - 'updated_at' - 'updated_by')
                = (to_jsonb(old) - 'status' - 'notes' - 'updated_at' - 'updated_by')) then
      raise exception 'Purchase bill % is POSTED and immutable.', old.bill_number
        using errcode = 'insufficient_privilege',
              hint = 'Spec §23: post a reversal instead of editing.';
    end if;
  end if;

  if tg_op = 'UPDATE' and old.status = 'CANCELLED' and new.status <> 'CANCELLED' then
    raise exception 'Purchase bill % is cancelled and cannot be reopened.', old.bill_number
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end;
$$;

create trigger purchase_bills_guard
  before update or delete on public.purchase_bills
  for each row execute function app.purchase_bills_guard();

create or replace function app.purchase_bill_lines_sync_totals()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_bill   uuid := coalesce(new.purchase_bill_id, old.purchase_bill_id);
  v_status text;
  v_number text;
begin
  select status, bill_number into v_status, v_number
    from public.purchase_bills where id = v_bill;

  -- Header already gone (ON DELETE CASCADE): let the cascade proceed.
  if v_status is null then
    return coalesce(new, old);
  end if;

  if v_status <> 'DRAFT' then
    raise exception 'Cannot % lines of purchase bill %: it is %.',
      lower(tg_op), v_number, v_status
      using errcode = 'insufficient_privilege';
  end if;

  -- The header's figures follow the lines rather than being sent alongside
  -- them, so a total can never disagree with what it totals.
  update public.purchase_bills b
     set taxable_value = coalesce(t.taxable, 0),
         cgst_amount   = coalesce(t.cgst, 0),
         sgst_amount   = coalesce(t.sgst, 0),
         igst_amount   = coalesce(t.igst, 0),
         total_amount  = coalesce(t.total, 0)
    from (
      select sum(l.taxable_value) as taxable, sum(l.cgst_amount) as cgst,
             sum(l.sgst_amount) as sgst, sum(l.igst_amount) as igst,
             sum(l.total_amount) as total
        from public.purchase_bill_lines l
       where l.purchase_bill_id = v_bill
    ) t
   where b.id = v_bill;

  return coalesce(new, old);
end;
$$;

create trigger purchase_bill_lines_sync
  after insert or update or delete on public.purchase_bill_lines
  for each row execute function app.purchase_bill_lines_sync_totals();

create trigger purchase_bills_set_updated_at
  before update on public.purchase_bills
  for each row execute function app.set_updated_at();

create trigger purchase_bills_audit
  after insert or update or delete on public.purchase_bills
  for each row execute function app.audit_trigger();

-- -----------------------------------------------------------------------------
-- Row Level Security
-- -----------------------------------------------------------------------------
alter table public.purchase_bills      enable row level security;
alter table public.purchase_bill_lines enable row level security;

create policy purchase_bills_select on public.purchase_bills
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and app.has_permission('purchases.view'))
  );

create policy purchase_bills_insert on public.purchase_bills
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and app.has_permission('purchases.create'))
  );

create policy purchase_bills_update on public.purchase_bills
  for update to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and (app.has_permission('purchases.create') or app.has_permission('purchases.post')))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and (app.has_permission('purchases.create') or app.has_permission('purchases.post')))
  );

-- A draft may be abandoned; the trigger above refuses anything further along.
create policy purchase_bills_delete on public.purchase_bills
  for delete to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and app.has_permission('purchases.create'))
  );

create policy purchase_bill_lines_select on public.purchase_bill_lines
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and exists (
          select 1 from public.purchase_bills b
           where b.id = purchase_bill_lines.purchase_bill_id
             and app.can_access_branch(b.branch_id)
        )
        and app.has_permission('purchases.view'))
  );

create policy purchase_bill_lines_write on public.purchase_bill_lines
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('purchases.create'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('purchases.create'))
  );

-- -----------------------------------------------------------------------------
-- public.post_purchase_bill() — the moment a bill becomes accounting
-- -----------------------------------------------------------------------------
-- One transaction (spec §48): journal, vehicle capitalisation, stock movement,
-- status. Any failure leaves the draft exactly as it was.
-- -----------------------------------------------------------------------------
create or replace function public.post_purchase_bill(
  p_bill_id         uuid,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_bill    public.purchase_bills;
  v_line    record;
  v_lines   jsonb := '[]'::jsonb;
  v_entry   uuid;
  v_count   integer;
  v_account uuid;
  v_veh     record;
  v_total   numeric(18, 4);
begin
  select * into v_bill from public.purchase_bills where id = p_bill_id for update;

  if v_bill.id is null then
    raise exception 'Purchase bill not found.' using errcode = 'no_data_found';
  end if;
  -- A repeated submission returns what the first one posted rather than posting
  -- a second time (spec §50), matching post_vehicle_sale and create_counter_invoice.
  -- The check has to be here as well as inside app.post_journal, because the
  -- stock movements below are not idempotent on their own.
  if v_bill.status = 'POSTED' then
    return v_bill.journal_entry_id;
  end if;
  if v_bill.status <> 'DRAFT' then
    raise exception 'Purchase bill % is % and cannot be posted.',
      v_bill.bill_number, v_bill.status using errcode = 'check_violation';
  end if;

  select count(*)::integer into v_count
    from public.purchase_bill_lines where purchase_bill_id = p_bill_id;
  if v_count = 0 then
    raise exception 'Purchase bill % has no lines.', v_bill.bill_number
      using errcode = 'check_violation';
  end if;
  if v_bill.total_amount <= 0 then
    raise exception 'Purchase bill % comes to nothing.', v_bill.bill_number
      using errcode = 'check_violation';
  end if;

  -- ── The stock side of every line, and the debits that mirror it ───────────
  for v_line in
    select * from public.purchase_bill_lines
     where purchase_bill_id = p_bill_id
     order by line_number
  loop
    if v_line.line_type = 'VEHICLE' then
      -- Locked, because two bills racing for the same chassis must not both
      -- believe they have it. The unique index would catch it at insert; this
      -- makes the failure happen before anything is posted (spec §49).
      select id, status, chassis_no into v_veh
        from public.vehicles where id = v_line.vehicle_id for update;

      if v_veh.id is null then
        raise exception 'The vehicle on line % no longer exists.', v_line.line_number
          using errcode = 'no_data_found';
      end if;
      -- A chassis that has been sold, transferred or cancelled since the draft
      -- was built is not stock this bill can capitalise.
      if v_veh.status <> 'IN_STOCK' then
        raise exception 'Chassis % is % and cannot be put on a purchase bill.',
          v_veh.chassis_no, v_veh.status using errcode = 'check_violation';
      end if;

      -- The cost the bill actually charges becomes the vehicle's cost, which is
      -- what COGS will later relieve. Recording the invoice and leaving the
      -- uploaded estimate in place would make the margin wrong for ever.
      update public.vehicles
         set purchase_cost    = v_line.taxable_value,
             purchase_invoice = coalesce(purchase_invoice, v_bill.supplier_bill_number),
             purchase_date    = coalesce(purchase_date, v_bill.bill_date),
             updated_by       = auth.uid()
       where id = v_line.vehicle_id;

      v_account := app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE',
                                       'VEHICLE_INVENTORY', v_bill.branch_id);
    else
      -- Counted stock arrives as a movement; the quantity follows from it
      -- (spec §34, §60.22). The lot identity is preserved (spec §28, §60.16).
      insert into public.inventory_transactions
        (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
         reference_type, reference_id, reference_number, narration, created_by)
      values
        (v_bill.dealer_id, v_bill.branch_id, v_line.item_id, v_line.source, 'PURCHASE',
         v_line.quantity, round(v_line.taxable_value / v_line.quantity, 4),
         'PURCHASE_BILL', p_bill_id, v_bill.bill_number,
         'Purchased on ' || v_bill.bill_number, auth.uid());

      v_account := app.require_account(
        v_bill.dealer_id, 'INVENTORY', 'PURCHASE',
        case when v_line.line_type = 'ACCESSORY' then 'ACCESSORY_INVENTORY'
             else 'SPARE_INVENTORY' end,
        v_bill.branch_id);
    end if;

    v_lines := v_lines || jsonb_build_object(
      'account_id', v_account, 'debit', v_line.taxable_value, 'credit', 0,
      'narration', v_line.description);
  end loop;

  -- ── Input GST: an asset, because the government owes it back ──────────────
  if v_bill.cgst_amount > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_CGST', v_bill.branch_id),
      'debit', v_bill.cgst_amount, 'credit', 0, 'narration', 'Input CGST ' || v_bill.bill_number);
  end if;
  if v_bill.sgst_amount > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_SGST', v_bill.branch_id),
      'debit', v_bill.sgst_amount, 'credit', 0, 'narration', 'Input SGST ' || v_bill.bill_number);
  end if;
  if v_bill.igst_amount > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_IGST', v_bill.branch_id),
      'debit', v_bill.igst_amount, 'credit', 0, 'narration', 'Input IGST ' || v_bill.bill_number);
  end if;

  -- ── And the one credit: what the dealer now owes this supplier ────────────
  -- Party-tagged, which is what puts the bill on the supplier's subsidiary
  -- ledger instead of leaving 2200 an undifferentiated lump (spec §41).
  select total_amount into v_total from public.purchase_bills where id = p_bill_id;

  v_lines := v_lines || jsonb_build_object(
    'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'PAYABLE', v_bill.branch_id),
    'debit', 0, 'credit', v_total,
    'narration', 'Bill ' || v_bill.supplier_bill_number,
    'party_type', 'SUPPLIER', 'party_id', v_bill.supplier_id);

  v_entry := app.post_journal(
    v_bill.dealer_id, v_bill.branch_id, v_bill.bill_date, 'INVENTORY',
    'Purchase ' || v_bill.bill_number || ' — ' || v_bill.supplier_bill_number,
    v_lines,
    'PURCHASE_BILL', p_bill_id,
    coalesce(p_idempotency_key, 'purchase-bill:' || p_bill_id::text)
  );

  update public.purchase_bills
     set status = 'POSTED', journal_entry_id = v_entry,
         posted_at = now(), posted_by = auth.uid(), updated_by = auth.uid()
   where id = p_bill_id;

  return v_entry;
end;
$$;

comment on function public.post_purchase_bill(uuid, text) is
  'Posts a purchase bill (spec §21, §48): stock onto the balance sheet, input '
  'GST to ITC, and the payable onto the supplier''s ledger. Idempotent (spec §50).';

-- -----------------------------------------------------------------------------
-- public.cancel_purchase_bill() — a draft is dropped, a posted bill is reversed
-- -----------------------------------------------------------------------------
create or replace function public.cancel_purchase_bill(
  p_bill_id uuid,
  p_reason  text
)
returns uuid
language plpgsql
as $$
declare
  v_bill  public.purchase_bills;
  v_line  record;
  v_entry uuid;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'Cancelling a purchase bill requires a reason.'
      using errcode = 'check_violation',
            hint = 'Spec §23: the reason is part of the record, not optional.';
  end if;

  select * into v_bill from public.purchase_bills where id = p_bill_id for update;
  if v_bill.id is null then
    raise exception 'Purchase bill not found.' using errcode = 'no_data_found';
  end if;
  if v_bill.status = 'CANCELLED' then
    raise exception 'Purchase bill % is already cancelled.', v_bill.bill_number
      using errcode = 'check_violation';
  end if;

  -- A draft never reached the ledger, so there is nothing to reverse. Deleting
  -- it releases its chassis back to the unbilled list.
  if v_bill.status = 'DRAFT' then
    delete from public.purchase_bills where id = p_bill_id;
    return null;
  end if;

  -- Posted: reverse the journal and take the stock back out again.
  v_entry := app.reverse_journal(v_bill.journal_entry_id, btrim(p_reason), current_date);

  for v_line in
    select * from public.purchase_bill_lines
     where purchase_bill_id = p_bill_id and line_type in ('ACCESSORY', 'SPARE')
  loop
    insert into public.inventory_transactions
      (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
       reference_type, reference_id, reference_number, narration, reason, created_by)
    values
      (v_bill.dealer_id, v_bill.branch_id, v_line.item_id, v_line.source, 'REVERSAL',
       -v_line.quantity, round(v_line.taxable_value / v_line.quantity, 4),
       'PURCHASE_BILL', p_bill_id, v_bill.bill_number,
       'Cancelled ' || v_bill.bill_number, btrim(p_reason), auth.uid());
  end loop;

  update public.purchase_bills
     set status = 'CANCELLED', updated_by = auth.uid(),
         notes = coalesce(notes || E'\n', '') || 'Cancelled: ' || btrim(p_reason)
   where id = p_bill_id;

  return v_entry;
end;
$$;

comment on function public.cancel_purchase_bill(uuid, text) is
  'Drops a draft, or reverses a posted bill and takes its stock back out '
  '(spec §23, §34). The vehicles it capitalised stay billed: their cost is real.';

-- -----------------------------------------------------------------------------
-- public.unbilled_vehicles() — the chassis a bill may still claim
-- -----------------------------------------------------------------------------
-- In stock, and on no purchase bill. Invoker-rights, so it shows only what the
-- caller's branches and permissions already allow them to see.
-- -----------------------------------------------------------------------------
create or replace function public.unbilled_vehicles(
  p_branch_id uuid default null,
  p_search    text default null
)
returns table (
  vehicle_id    uuid,
  chassis_no    text,
  engine_no     text,
  model_label   text,
  branch_name   text,
  purchase_cost numeric(18, 4),
  stock_date    date
)
language sql
stable
as $$
  select v.id, v.chassis_no, v.engine_no,
         m.name || coalesce(' ' || vr.name, ''),
         b.name, v.purchase_cost, v.stock_date
    from public.vehicles v
    join public.branches b on b.id = v.branch_id
    join public.vehicle_models m on m.id = v.model_id
    left join public.vehicle_variants vr on vr.id = v.variant_id
   where v.status = 'IN_STOCK'
     and (p_branch_id is null or v.branch_id = p_branch_id)
     and not exists (
       select 1 from public.purchase_bill_lines l where l.vehicle_id = v.id
     )
     and (
       p_search is null or btrim(p_search) = ''
       or v.chassis_no ilike '%' || btrim(p_search) || '%'
       or v.engine_no  ilike '%' || btrim(p_search) || '%'
       or m.name       ilike '%' || btrim(p_search) || '%'
     )
   order by v.stock_date desc nulls last, v.chassis_no
   limit 200;
$$;

comment on function public.unbilled_vehicles(uuid, text) is
  'Chassis in stock that no purchase bill has claimed (spec §13, §14).';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update, delete on public.purchase_bills to authenticated';
    execute 'grant select, insert, update, delete on public.purchase_bill_lines to authenticated';
    execute 'grant all on public.purchase_bills to service_role';
    execute 'grant all on public.purchase_bill_lines to service_role';
    execute 'grant execute on function public.post_purchase_bill(uuid, text) to authenticated';
    execute 'grant execute on function public.cancel_purchase_bill(uuid, text) to authenticated';
    execute 'grant execute on function public.unbilled_vehicles(uuid, text) to authenticated';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Permissions
-- -----------------------------------------------------------------------------
-- Inserted here as well as in seed.sql so an upgraded database gains them, and
-- granted to the roles that buy stock and account for it (spec §6).
-- -----------------------------------------------------------------------------
insert into public.permissions (code, module, description, is_sensitive) values
  ('purchases.view',   'purchases', 'View purchase bills',                    false),
  ('purchases.create', 'purchases', 'Create and edit draft purchase bills',   false),
  ('purchases.post',   'purchases', 'Post a purchase bill to the accounts',   false),
  ('purchases.cancel', 'purchases', 'Cancel or reverse a purchase bill',      false)
on conflict (code) do update
  set module      = excluded.module,
      description = excluded.description;

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join (values ('purchases.view'), ('purchases.create'), ('purchases.post'), ('purchases.cancel')) as p(code)
 where r.is_system and r.code in ('DEALER_OWNER', 'ACCOUNTS')
on conflict do nothing;
