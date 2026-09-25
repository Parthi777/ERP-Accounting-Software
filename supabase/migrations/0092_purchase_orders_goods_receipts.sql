-- =============================================================================
-- 0092 — Purchase order → goods receipt → supplier bill
-- =============================================================================
-- BUSY requirements F33–F37, F40 (docs/accounting-feature-gap-analysis.md).
--
-- Accessories and spares arrive from the OEM before, or without, the bill. Until
-- now the only way to bring them into stock was the supplier bill itself, so
-- goods on the shelf and unbilled were invisible to the books, and a bill that
-- arrived later had nothing to match against.
--
--   purchase order     what was ordered, at what rate — no accounting effect
--   goods receipt      what arrived, against which order lines, with the
--                      supplier's challan and transport details. Stock in, at
--                      the order rate:
--                          Dr Accessory / Spare Inventory
--                              Cr 2760 Goods Received Not Invoiced
--   supplier bill      a bill line pointing at a receipt line adds NO stock —
--                      the receipt already did. It clears GRNI instead:
--                          Dr 2760 GRNI (the value received)
--                          Dr/Cr 5970 Stock Adjustments (bill rate − order rate)
--                          Dr Input GST
--                              Cr Supplier
--
-- Controls, each enforced here rather than in a screen:
--   * a receipt cannot exceed what is ordered and not yet received;
--   * a bill cannot bill more of a receipt line than was received and not yet
--     billed on another posted bill;
--   * a receipt that has been billed cannot be cancelled — cancel the bill first;
--   * cancelling a receipt takes its stock back out and reverses its journal;
--   * cancelling a bill that billed a receipt reverses the journal (GRNI owed
--     again) and leaves the stock where it is, because it is still on the shelf.
--
-- 2760 at any moment is the value of goods received and not yet billed;
-- grni_outstanding() lists it line by line, and 9ZJ ties the two.
--
-- Permissions reuse the purchase set: purchases.create raises and edits orders,
-- purchases.post approves them and posts receipts, purchases.cancel cancels.
--
-- Rollback: drop the tables, functions and the grn_line_id column added here;
--           restore post_purchase_bill (0084) and cancel_purchase_bill (0052).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Goods Received Not Invoiced, and its posting rules
-- -----------------------------------------------------------------------------
create or replace function app.seed_purchase_order_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
declare
  v_added integer := 0;
  a       record;
begin
  for a in
    select * from (values
      ('2760', 'Goods Received Not Invoiced', 'LIABILITY', 'CREDIT')
    ) as t(code, name, account_type, normal_balance)
  loop
    insert into public.chart_of_accounts
      (dealer_id, code, name, account_type, normal_balance, is_group, parent_id, is_system, is_branch_scoped)
    select p_dealer_id, a.code, a.name, a.account_type, a.normal_balance, false, p.id, true, false
      from public.chart_of_accounts p
     where p.dealer_id = p_dealer_id and p.is_group
       and p.code = (select coalesce(max(code) filter (where code = '2001'), '2000')
                       from public.chart_of_accounts
                      where dealer_id = p_dealer_id and code in ('2000', '2001') and is_group)
    on conflict on constraint coa_dealer_code_key do nothing;
    if found then v_added := v_added + 1; end if;
  end loop;

  insert into public.accounting_rules (dealer_id, module, event, component, side, account_id, description)
  select p_dealer_id, 'INVENTORY', 'PURCHASE', r.component, r.side, c.id, 'Default mapping'
    from (values ('GRNI', 'CREDIT', '2760'), ('PRICE_VARIANCE', 'DEBIT', '5970')) as r(component, side, code)
    join public.chart_of_accounts c on c.dealer_id = p_dealer_id and c.code = r.code and not c.is_group
   where not exists (select 1 from public.accounting_rules x
                      where x.dealer_id = p_dealer_id and x.module = 'INVENTORY' and x.event = 'PURCHASE'
                        and x.component = r.component and x.branch_id is null and x.status = 'ACTIVE');

  return v_added;
end;
$$;

do $$
declare d record;
begin
  for d in select id from public.dealers loop
    perform app.seed_purchase_order_accounts(d.id);
  end loop;
end $$;

alter function app.seed_chart_of_accounts(uuid) rename to seed_chart_of_accounts_0091;

create or replace function app.seed_chart_of_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
begin
  return app.seed_chart_of_accounts_0091(p_dealer_id) + app.seed_purchase_order_accounts(p_dealer_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. Tables
-- -----------------------------------------------------------------------------
create table public.purchase_orders (
  id              uuid primary key default gen_random_uuid(),
  dealer_id       uuid not null references public.dealers (id) on delete restrict,
  branch_id       uuid not null,
  po_number       text not null,
  supplier_id     uuid not null,
  order_date      date not null default current_date,
  expected_date   date,
  status          text not null default 'DRAFT',
  notes           text,
  idempotency_key text,
  approved_at     timestamptz,
  approved_by     uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  created_by      uuid,
  updated_by      uuid,

  constraint purchase_orders_number_key unique (dealer_id, po_number),
  constraint purchase_orders_id_dealer_key unique (id, dealer_id),
  constraint purchase_orders_idem_key unique (dealer_id, idempotency_key),
  constraint purchase_orders_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint purchase_orders_supplier_tenant_fkey
    foreign key (supplier_id, dealer_id) references public.suppliers (id, dealer_id),
  constraint purchase_orders_status_check
    check (status in ('DRAFT', 'APPROVED', 'PARTIAL', 'RECEIVED', 'CLOSED', 'CANCELLED')),
  constraint purchase_orders_expected_check check (expected_date is null or expected_date >= order_date)
);

create table public.purchase_order_lines (
  id                uuid primary key default gen_random_uuid(),
  purchase_order_id uuid not null,
  dealer_id         uuid not null,
  line_number       integer not null,
  line_type         text not null,
  item_id           uuid not null,
  source            text not null,
  description       text not null,
  quantity          numeric(14, 3) not null,
  unit_rate         numeric(18, 4) not null,
  cgst_rate         numeric(6, 3) not null default 0,
  sgst_rate         numeric(6, 3) not null default 0,
  igst_rate         numeric(6, 3) not null default 0,

  constraint pol_order_line_key unique (purchase_order_id, line_number),
  constraint pol_id_dealer_key unique (id, dealer_id),
  constraint pol_order_tenant_fkey
    foreign key (purchase_order_id, dealer_id) references public.purchase_orders (id, dealer_id) on delete cascade,
  constraint pol_item_tenant_fkey
    foreign key (item_id, dealer_id) references public.inventory_items (id, dealer_id),
  constraint pol_type_check check (line_type in ('ACCESSORY', 'SPARE')),
  constraint pol_source_check check (source in ('LOCAL', 'COMPANY')),
  constraint pol_quantity_check check (quantity > 0),
  constraint pol_rate_check check (unit_rate >= 0),
  constraint pol_tax_check check (cgst_rate >= 0 and sgst_rate >= 0 and igst_rate >= 0
                                  and (igst_rate = 0 or (cgst_rate = 0 and sgst_rate = 0)))
);

create table public.goods_receipts (
  id                     uuid primary key default gen_random_uuid(),
  dealer_id              uuid not null references public.dealers (id) on delete restrict,
  branch_id              uuid not null,
  grn_number             text not null,
  purchase_order_id      uuid not null,
  supplier_id            uuid not null,
  receipt_date           date not null default current_date,
  supplier_challan_number text,
  transporter            text,
  lr_number              text,
  vehicle_number         text,
  origin                 text,
  origin_pincode         text,
  status                 text not null default 'POSTED',
  total_value            numeric(18, 4) not null default 0,
  journal_entry_id       uuid,
  idempotency_key        text,
  cancel_reason          text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  created_by             uuid,
  updated_by             uuid,

  constraint goods_receipts_number_key unique (dealer_id, grn_number),
  constraint goods_receipts_id_dealer_key unique (id, dealer_id),
  constraint goods_receipts_idem_key unique (dealer_id, idempotency_key),
  constraint goods_receipts_order_tenant_fkey
    foreign key (purchase_order_id, dealer_id) references public.purchase_orders (id, dealer_id),
  constraint goods_receipts_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint goods_receipts_supplier_tenant_fkey
    foreign key (supplier_id, dealer_id) references public.suppliers (id, dealer_id),
  constraint goods_receipts_status_check check (status in ('POSTED', 'CANCELLED')),
  constraint goods_receipts_pin_check check (origin_pincode is null or origin_pincode ~ '^[1-9][0-9]{5}$')
);

create table public.goods_receipt_lines (
  id                  uuid primary key default gen_random_uuid(),
  goods_receipt_id    uuid not null,
  dealer_id           uuid not null,
  po_line_id          uuid not null,
  line_number         integer not null,
  line_type           text not null,
  item_id             uuid not null,
  source              text not null,
  quantity            numeric(14, 3) not null,
  unit_cost           numeric(18, 4) not null,
  value               numeric(18, 4) not null,

  constraint grl_receipt_line_key unique (goods_receipt_id, line_number),
  constraint grl_id_dealer_key unique (id, dealer_id),
  constraint grl_receipt_tenant_fkey
    foreign key (goods_receipt_id, dealer_id) references public.goods_receipts (id, dealer_id) on delete cascade,
  constraint grl_po_line_tenant_fkey
    foreign key (po_line_id, dealer_id) references public.purchase_order_lines (id, dealer_id),
  constraint grl_item_tenant_fkey
    foreign key (item_id, dealer_id) references public.inventory_items (id, dealer_id),
  constraint grl_quantity_check check (quantity > 0),
  constraint grl_value_check check (value >= 0)
);

alter table public.purchase_bill_lines add column grn_line_id uuid;
alter table public.purchase_bill_lines
  add constraint pbl_grn_line_tenant_fkey
    foreign key (grn_line_id, dealer_id) references public.goods_receipt_lines (id, dealer_id);
alter table public.purchase_bill_lines
  add constraint pbl_grn_line_type_check check (grn_line_id is null or (line_type <> 'VEHICLE' and line_type <> 'EXPENSE'));

create index pol_order_idx on public.purchase_order_lines (purchase_order_id);
create index grl_receipt_idx on public.goods_receipt_lines (goods_receipt_id);
create index grl_po_line_idx on public.goods_receipt_lines (po_line_id);
create index pbl_grn_line_idx on public.purchase_bill_lines (grn_line_id) where grn_line_id is not null;
create index purchase_orders_dealer_status_idx on public.purchase_orders (dealer_id, status);
create index goods_receipts_order_idx on public.goods_receipts (purchase_order_id);

comment on table public.purchase_orders is 'What was ordered from a supplier (BUSY F33). No accounting effect.';
comment on table public.goods_receipts is
  'What arrived against an order (F34, F36): stock in at the order rate, Cr 2760 GRNI.';
comment on column public.purchase_bill_lines.grn_line_id is
  'The receipt line this bill line bills. Such a line adds no stock; it clears GRNI (F37).';

-- Numbers, self-provisioned per financial year as purchase bills are (0052).
create or replace function app.purchase_orders_assign_number()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_year text;
begin
  if new.po_number is not null and btrim(new.po_number) <> '' then
    return new;
  end if;
  v_year := app.financial_year_token(new.dealer_id, coalesce(new.order_date, current_date));
  insert into public.document_sequences (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
  values (new.dealer_id, null, 'PURCHASE_ORDER', v_year, 'PO', 6)
  on conflict on constraint document_sequences_scope_key do nothing;
  new.po_number := app.next_document_number(new.dealer_id, null, 'PURCHASE_ORDER', v_year);
  return new;
end;
$$;

create trigger purchase_orders_assign_number
  before insert on public.purchase_orders
  for each row execute function app.purchase_orders_assign_number();

create or replace function app.goods_receipts_assign_number()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_year text;
begin
  if new.grn_number is not null and btrim(new.grn_number) <> '' then
    return new;
  end if;
  v_year := app.financial_year_token(new.dealer_id, coalesce(new.receipt_date, current_date));
  insert into public.document_sequences (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
  values (new.dealer_id, null, 'GOODS_RECEIPT', v_year, 'GRN', 6)
  on conflict on constraint document_sequences_scope_key do nothing;
  new.grn_number := app.next_document_number(new.dealer_id, null, 'GOODS_RECEIPT', v_year);
  return new;
end;
$$;

create trigger goods_receipts_assign_number
  before insert on public.goods_receipts
  for each row execute function app.goods_receipts_assign_number();

create trigger purchase_orders_set_updated_at before update on public.purchase_orders
  for each row execute function app.set_updated_at();
create trigger goods_receipts_set_updated_at before update on public.goods_receipts
  for each row execute function app.set_updated_at();
create trigger purchase_orders_audit after insert or update or delete on public.purchase_orders
  for each row execute function app.audit_trigger();
create trigger goods_receipts_audit after insert or update or delete on public.goods_receipts
  for each row execute function app.audit_trigger();

-- -----------------------------------------------------------------------------
-- 3. Row-level security
-- -----------------------------------------------------------------------------
alter table public.purchase_orders      enable row level security;
alter table public.purchase_order_lines enable row level security;
alter table public.goods_receipts       enable row level security;
alter table public.goods_receipt_lines  enable row level security;

create policy purchase_orders_select on public.purchase_orders
  for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.can_access_branch(branch_id)
             and app.has_permission('purchases.view')));
create policy purchase_orders_write on public.purchase_orders
  for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.can_access_branch(branch_id)
             and (app.has_permission('purchases.create') or app.has_permission('purchases.post')
                  or app.has_permission('purchases.cancel'))))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.can_access_branch(branch_id)
             and (app.has_permission('purchases.create') or app.has_permission('purchases.post')
                  or app.has_permission('purchases.cancel'))));

create policy purchase_order_lines_select on public.purchase_order_lines
  for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and exists (select 1 from public.purchase_orders o where o.id = purchase_order_id)));
create policy purchase_order_lines_write on public.purchase_order_lines
  for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('purchases.create')))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('purchases.create')));

create policy goods_receipts_select on public.goods_receipts
  for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.can_access_branch(branch_id)
             and app.has_permission('purchases.view')));
create policy goods_receipts_write on public.goods_receipts
  for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.can_access_branch(branch_id)
             and (app.has_permission('purchases.post') or app.has_permission('purchases.cancel'))))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.can_access_branch(branch_id)
             and (app.has_permission('purchases.post') or app.has_permission('purchases.cancel'))));

create policy goods_receipt_lines_select on public.goods_receipt_lines
  for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and exists (select 1 from public.goods_receipts g where g.id = goods_receipt_id)));
create policy goods_receipt_lines_write on public.goods_receipt_lines
  for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('purchases.post')))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('purchases.post')));

-- -----------------------------------------------------------------------------
-- 4. What has been received and billed, per order line and receipt line
-- -----------------------------------------------------------------------------
create or replace function app.po_line_received(p_po_line_id uuid)
returns numeric
language sql
stable
as $$
  select coalesce(sum(l.quantity), 0)
    from public.goods_receipt_lines l
    join public.goods_receipts g on g.id = l.goods_receipt_id
   where l.po_line_id = p_po_line_id and g.status = 'POSTED';
$$;

create or replace function app.grn_line_billed(p_grn_line_id uuid, p_except_bill uuid default null)
returns numeric
language sql
stable
as $$
  select coalesce(sum(bl.quantity), 0)
    from public.purchase_bill_lines bl
    join public.purchase_bills b on b.id = bl.purchase_bill_id
   where bl.grn_line_id = p_grn_line_id
     and b.status = 'POSTED'
     and (p_except_bill is null or b.id <> p_except_bill);
$$;

-- -----------------------------------------------------------------------------
-- 5. Orders
-- -----------------------------------------------------------------------------
-- p_lines: [{"item_id": "…", "source": "COMPANY", "quantity": 10, "unit_rate": 450,
--            "cgst_rate": 9, "sgst_rate": 9, "igst_rate": 0, "description": "…"}]
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
    insert into public.purchase_order_lines
      (purchase_order_id, dealer_id, line_number, line_type, item_id, source, description,
       quantity, unit_rate, cgst_rate, sgst_rate, igst_rate)
    values
      (v_id, v_dealer, v_n, v_item.item_type, v_item.id, coalesce(nullif(v_line ->> 'source', ''), 'COMPANY'),
       coalesce(nullif(btrim(v_line ->> 'description'), ''), v_item.name),
       (v_line ->> 'quantity')::numeric, coalesce((v_line ->> 'unit_rate')::numeric, 0),
       coalesce((v_line ->> 'cgst_rate')::numeric, 0), coalesce((v_line ->> 'sgst_rate')::numeric, 0),
       coalesce((v_line ->> 'igst_rate')::numeric, 0));
  end loop;

  return v_id;
end;
$$;

create or replace function public.approve_purchase_order(p_order_id uuid)
returns void
language plpgsql
as $$
declare
  v_po public.purchase_orders;
begin
  if not app.has_permission('purchases.post') then
    raise exception 'You may not approve purchase orders.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_po from public.purchase_orders where id = p_order_id for update;
  if v_po.id is null then
    raise exception 'Purchase order not found.' using errcode = 'no_data_found';
  end if;
  if v_po.status <> 'DRAFT' then
    raise exception 'Purchase order % is %.', v_po.po_number, lower(v_po.status) using errcode = 'check_violation';
  end if;
  update public.purchase_orders
     set status = 'APPROVED', approved_at = now(), approved_by = auth.uid(), updated_by = auth.uid()
   where id = p_order_id;
end;
$$;

-- Cancel an order nothing has been received against; close one that is partly
-- received so its remainder stops showing as pending.
create or replace function public.close_purchase_order(p_order_id uuid, p_reason text)
returns text
language plpgsql
as $$
declare
  v_po       public.purchase_orders;
  v_received boolean;
begin
  if not (app.has_permission('purchases.cancel') or app.has_permission('purchases.post')) then
    raise exception 'You may not close purchase orders.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(length(btrim(p_reason)), 0) < 3 then
    raise exception 'Say why the order is being closed.' using errcode = 'check_violation';
  end if;
  select * into v_po from public.purchase_orders where id = p_order_id for update;
  if v_po.id is null then
    raise exception 'Purchase order not found.' using errcode = 'no_data_found';
  end if;
  if v_po.status in ('CLOSED', 'CANCELLED', 'RECEIVED') then
    raise exception 'Purchase order % is already %.', v_po.po_number, lower(v_po.status) using errcode = 'check_violation';
  end if;
  select exists (select 1 from public.goods_receipts where purchase_order_id = p_order_id and status = 'POSTED')
    into v_received;
  update public.purchase_orders
     set status = case when v_received then 'CLOSED' else 'CANCELLED' end,
         notes = coalesce(notes || E'\n', '') || case when v_received then 'Closed: ' else 'Cancelled: ' end || btrim(p_reason),
         updated_by = auth.uid()
   where id = p_order_id;
  return case when v_received then 'CLOSED' else 'CANCELLED' end;
end;
$$;

create or replace function app.refresh_purchase_order_status(p_order_id uuid)
returns void
language plpgsql
as $$
declare
  v_ordered  numeric;
  v_received numeric;
begin
  select coalesce(sum(quantity), 0), coalesce(sum(app.po_line_received(id)), 0)
    into v_ordered, v_received
    from public.purchase_order_lines where purchase_order_id = p_order_id;
  update public.purchase_orders
     set status = case when v_received = 0 then 'APPROVED'
                       when v_received >= v_ordered then 'RECEIVED'
                       else 'PARTIAL' end
   where id = p_order_id and status in ('APPROVED', 'PARTIAL', 'RECEIVED');
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Goods receipt
-- -----------------------------------------------------------------------------
-- p_lines: [{"po_line_id": "…", "quantity": 6}]
-- p_transport: {"supplier_challan_number": "…", "transporter": "…", "lr_number": "…",
--               "vehicle_number": "…", "origin": "…", "origin_pincode": "…"}
create or replace function public.post_goods_receipt(
  p_order_id        uuid,
  p_lines           jsonb,
  p_receipt_date    date default current_date,
  p_transport       jsonb default '{}'::jsonb,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_po      public.purchase_orders;
  v_id      uuid;
  v_line    jsonb;
  v_pol     public.purchase_order_lines;
  v_qty     numeric(14, 3);
  v_left    numeric(14, 3);
  v_value   numeric(18, 4);
  v_total   numeric(18, 4) := 0;
  v_n       integer := 0;
  v_jl      jsonb := '[]'::jsonb;
  v_grn     public.goods_receipts;
  v_entry   uuid;
  v_t       jsonb := coalesce(p_transport, '{}'::jsonb);
begin
  if not app.has_permission('purchases.post') then
    raise exception 'You may not receive goods.' using errcode = 'insufficient_privilege';
  end if;

  select * into v_po from public.purchase_orders where id = p_order_id for update;
  if v_po.id is null then
    raise exception 'Purchase order not found.' using errcode = 'no_data_found';
  end if;
  if p_idempotency_key is not null then
    select id into v_id from public.goods_receipts
     where dealer_id = v_po.dealer_id and idempotency_key = p_idempotency_key;
    if v_id is not null then return v_id; end if;
  end if;
  if v_po.status not in ('APPROVED', 'PARTIAL') then
    raise exception 'Purchase order % is % — goods are received only against an approved order.',
      v_po.po_number, lower(v_po.status) using errcode = 'check_violation';
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Enter what was received.' using errcode = 'check_violation';
  end if;
  if coalesce(p_receipt_date, current_date) < v_po.order_date then
    raise exception 'Goods cannot be received before they were ordered (%).', v_po.order_date
      using errcode = 'check_violation';
  end if;

  insert into public.goods_receipts
    (dealer_id, branch_id, purchase_order_id, supplier_id, receipt_date,
     supplier_challan_number, transporter, lr_number, vehicle_number, origin, origin_pincode,
     idempotency_key, created_by)
  values
    (v_po.dealer_id, v_po.branch_id, v_po.id, v_po.supplier_id, coalesce(p_receipt_date, current_date),
     nullif(btrim(v_t ->> 'supplier_challan_number'), ''), nullif(btrim(v_t ->> 'transporter'), ''),
     nullif(btrim(v_t ->> 'lr_number'), ''), nullif(upper(btrim(v_t ->> 'vehicle_number')), ''),
     nullif(btrim(v_t ->> 'origin'), ''), nullif(btrim(v_t ->> 'origin_pincode'), ''),
     p_idempotency_key, auth.uid())
  returning * into v_grn;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_qty := round(coalesce((v_line ->> 'quantity')::numeric, 0), 3);
    if v_qty = 0 then continue; end if;
    if v_qty < 0 then
      raise exception 'A received quantity cannot be negative.' using errcode = 'check_violation';
    end if;

    select * into v_pol from public.purchase_order_lines
     where id = nullif(v_line ->> 'po_line_id', '')::uuid and purchase_order_id = p_order_id
       for update;
    if v_pol.id is null then
      raise exception 'A received line does not belong to order %.', v_po.po_number using errcode = 'check_violation';
    end if;
    v_left := v_pol.quantity - app.po_line_received(v_pol.id);
    if v_qty > v_left then
      raise exception '% — % ordered, % still to come; % cannot be received.',
        v_pol.description, v_pol.quantity, v_left, v_qty using errcode = 'check_violation';
    end if;

    v_n := v_n + 1;
    v_value := round(v_qty * v_pol.unit_rate, 2);
    v_total := v_total + v_value;

    insert into public.goods_receipt_lines
      (goods_receipt_id, dealer_id, po_line_id, line_number, line_type, item_id, source, quantity, unit_cost, value)
    values
      (v_grn.id, v_po.dealer_id, v_pol.id, v_n, v_pol.line_type, v_pol.item_id, v_pol.source,
       v_qty, v_pol.unit_rate, v_value);

    insert into public.inventory_transactions
      (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
       reference_type, reference_id, reference_number, narration, created_by)
    values
      (v_po.dealer_id, v_po.branch_id, v_pol.item_id, v_pol.source, 'PURCHASE',
       v_qty, v_pol.unit_rate, 'GOODS_RECEIPT', v_grn.id, v_grn.grn_number,
       'Received on ' || v_grn.grn_number || ' against ' || v_po.po_number, auth.uid());

    if v_value > 0 then
      v_jl := v_jl || jsonb_build_array(jsonb_build_object(
        'account_id', app.require_account(v_po.dealer_id, 'INVENTORY', 'PURCHASE',
                        case when v_pol.line_type = 'ACCESSORY' then 'ACCESSORY_INVENTORY' else 'SPARE_INVENTORY' end,
                        v_po.branch_id),
        'debit', v_value, 'credit', 0, 'narration', v_pol.description));
    end if;
  end loop;

  if v_n = 0 then
    raise exception 'Nothing was received — every quantity is zero.' using errcode = 'check_violation';
  end if;

  if v_total > 0 then
    v_jl := v_jl || jsonb_build_array(jsonb_build_object(
      'account_id', app.require_account(v_po.dealer_id, 'INVENTORY', 'PURCHASE', 'GRNI', v_po.branch_id),
      'debit', 0, 'credit', v_total,
      'narration', 'Received, not yet billed — ' || v_po.po_number));
    v_entry := app.post_journal(
      v_po.dealer_id, v_po.branch_id, v_grn.receipt_date, 'INVENTORY',
      'Goods receipt ' || v_grn.grn_number || ' against ' || v_po.po_number,
      v_jl, 'GOODS_RECEIPT', v_grn.id, 'grn:' || v_grn.id::text);
  end if;

  update public.goods_receipts set total_value = v_total, journal_entry_id = v_entry where id = v_grn.id;
  perform app.refresh_purchase_order_status(p_order_id);
  return v_grn.id;
end;
$$;

create or replace function public.cancel_goods_receipt(p_receipt_id uuid, p_reason text)
returns void
language plpgsql
as $$
declare
  v_grn  public.goods_receipts;
  v_line record;
begin
  if not (app.has_permission('purchases.cancel') or app.has_permission('purchases.post')) then
    raise exception 'You may not cancel goods receipts.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(length(btrim(p_reason)), 0) < 3 then
    raise exception 'Cancelling a goods receipt requires a reason.' using errcode = 'check_violation';
  end if;
  select * into v_grn from public.goods_receipts where id = p_receipt_id for update;
  if v_grn.id is null then
    raise exception 'Goods receipt not found.' using errcode = 'no_data_found';
  end if;
  if v_grn.status = 'CANCELLED' then
    raise exception 'Goods receipt % is already cancelled.', v_grn.grn_number using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.purchase_bill_lines bl
               join public.purchase_bills b on b.id = bl.purchase_bill_id
               join public.goods_receipt_lines l on l.id = bl.grn_line_id
              where l.goods_receipt_id = p_receipt_id and b.status in ('DRAFT', 'POSTED')) then
    raise exception 'Goods receipt % is on a supplier bill. Remove it from the bill, or cancel the bill, first.',
      v_grn.grn_number using errcode = 'check_violation';
  end if;

  for v_line in select * from public.goods_receipt_lines where goods_receipt_id = p_receipt_id loop
    insert into public.inventory_transactions
      (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
       reference_type, reference_id, reference_number, narration, reason, created_by)
    values
      (v_grn.dealer_id, v_grn.branch_id, v_line.item_id, v_line.source, 'REVERSAL',
       -v_line.quantity, v_line.unit_cost, 'GOODS_RECEIPT', v_grn.id, v_grn.grn_number,
       'Cancelled ' || v_grn.grn_number, btrim(p_reason), auth.uid());
  end loop;

  if v_grn.journal_entry_id is not null then
    perform app.reverse_journal(v_grn.journal_entry_id, btrim(p_reason), current_date);
  end if;

  update public.goods_receipts
     set status = 'CANCELLED', cancel_reason = btrim(p_reason), updated_by = auth.uid()
   where id = p_receipt_id;
  perform app.refresh_purchase_order_status(v_grn.purchase_order_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Billing a receipt
-- -----------------------------------------------------------------------------
-- p_lines: [{"grn_line_id": "…", "quantity": 6, "unit_rate": 455}] — rate
-- defaults to the order rate; tax rates come from the order line.
create or replace function public.add_receipt_lines_to_bill(p_bill_id uuid, p_lines jsonb)
returns integer
language plpgsql
as $$
declare
  v_bill  public.purchase_bills;
  v_line  jsonb;
  v_grl   record;
  v_qty   numeric(14, 3);
  v_rate  numeric(18, 4);
  v_left  numeric(14, 3);
  v_tax   numeric(18, 4);
  v_cgst  numeric(18, 4);
  v_sgst  numeric(18, 4);
  v_igst  numeric(18, 4);
  v_n     integer;
  v_added integer := 0;
begin
  if not app.has_permission('purchases.create') then
    raise exception 'You may not edit purchase bills.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_bill from public.purchase_bills where id = p_bill_id for update;
  if v_bill.id is null then
    raise exception 'Purchase bill not found.' using errcode = 'no_data_found';
  end if;
  if v_bill.status <> 'DRAFT' then
    raise exception 'Purchase bill % is % and cannot change.', v_bill.bill_number, lower(v_bill.status)
      using errcode = 'check_violation';
  end if;

  select coalesce(max(line_number), 0) into v_n from public.purchase_bill_lines where purchase_bill_id = p_bill_id;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    select l.*, g.supplier_id, g.branch_id, g.status as grn_status, g.grn_number,
           pol.description, pol.cgst_rate, pol.sgst_rate, pol.igst_rate
      into v_grl
      from public.goods_receipt_lines l
      join public.goods_receipts g on g.id = l.goods_receipt_id
      join public.purchase_order_lines pol on pol.id = l.po_line_id
     where l.id = nullif(v_line ->> 'grn_line_id', '')::uuid
       for update of l;
    if v_grl.id is null then
      raise exception 'A receipt line was not found.' using errcode = 'no_data_found';
    end if;
    if v_grl.grn_status <> 'POSTED' then
      raise exception 'Goods receipt % is cancelled.', v_grl.grn_number using errcode = 'check_violation';
    end if;
    if v_grl.supplier_id <> v_bill.supplier_id then
      raise exception 'Goods receipt % is from another supplier.', v_grl.grn_number using errcode = 'check_violation';
    end if;
    if v_grl.branch_id <> v_bill.branch_id then
      raise exception 'Goods receipt % was received at another branch.', v_grl.grn_number using errcode = 'check_violation';
    end if;

    v_qty := round(coalesce((v_line ->> 'quantity')::numeric, v_grl.quantity), 3);
    v_rate := coalesce((v_line ->> 'unit_rate')::numeric, v_grl.unit_cost);
    v_left := v_grl.quantity - app.grn_line_billed(v_grl.id)
              - coalesce((select sum(quantity) from public.purchase_bill_lines
                           where purchase_bill_id = p_bill_id and grn_line_id = v_grl.id), 0);
    if v_qty <= 0 or v_rate < 0 then
      raise exception 'Enter a quantity above zero and a rate of zero or more.' using errcode = 'check_violation';
    end if;
    if v_qty > v_left then
      raise exception '% on % — % received and not yet billed; % cannot be billed.',
        v_grl.description, v_grl.grn_number, v_left, v_qty using errcode = 'check_violation';
    end if;

    v_tax := round(v_qty * v_rate, 2);
    v_cgst := round(v_tax * v_grl.cgst_rate / 100, 2);
    v_sgst := round(v_tax * v_grl.sgst_rate / 100, 2);
    v_igst := round(v_tax * v_grl.igst_rate / 100, 2);
    v_n := v_n + 1;

    insert into public.purchase_bill_lines
      (purchase_bill_id, dealer_id, line_number, line_type, item_id, source, description,
       quantity, unit_rate, taxable_value, cgst_rate, sgst_rate, igst_rate,
       cgst_amount, sgst_amount, igst_amount, total_amount, grn_line_id)
    values
      (p_bill_id, v_bill.dealer_id, v_n, v_grl.line_type, v_grl.item_id, v_grl.source,
       v_grl.description || ' (' || v_grl.grn_number || ')',
       v_qty, v_rate, v_tax, v_grl.cgst_rate, v_grl.sgst_rate, v_grl.igst_rate,
       v_cgst, v_sgst, v_igst, v_tax + v_cgst + v_sgst + v_igst, v_grl.id);
    v_added := v_added + 1;
  end loop;

  return v_added;
end;
$$;

-- Receipt lines still to be billed for a supplier — what the bill form offers.
create or replace function public.unbilled_receipt_lines(p_supplier_id uuid, p_branch_id uuid default null)
returns table (
  grn_line_id  uuid,
  grn_number   text,
  receipt_date date,
  po_number    text,
  item_id      uuid,
  description  text,
  source       text,
  received     numeric(14, 3),
  billed       numeric(14, 3),
  unbilled     numeric(14, 3),
  unit_cost    numeric(18, 4)
)
language sql
stable
as $$
  select l.id, g.grn_number, g.receipt_date, po.po_number, l.item_id, pol.description, l.source,
         l.quantity, app.grn_line_billed(l.id), l.quantity - app.grn_line_billed(l.id), l.unit_cost
    from public.goods_receipt_lines l
    join public.goods_receipts g on g.id = l.goods_receipt_id
    join public.purchase_orders po on po.id = g.purchase_order_id
    join public.purchase_order_lines pol on pol.id = l.po_line_id
   where g.supplier_id = p_supplier_id
     and g.status = 'POSTED'
     and (p_branch_id is null or g.branch_id = p_branch_id)
     and l.quantity > app.grn_line_billed(l.id)
   order by g.receipt_date, g.grn_number, l.line_number;
$$;

-- -----------------------------------------------------------------------------
-- 8. Reports
-- -----------------------------------------------------------------------------
create or replace function public.pending_purchase_orders(p_include_closed boolean default false)
returns table (
  order_id      uuid,
  po_number     text,
  order_date    date,
  expected_date date,
  status        text,
  supplier_name text,
  branch_name   text,
  po_line_id    uuid,
  description   text,
  ordered       numeric(14, 3),
  received      numeric(14, 3),
  billed        numeric(14, 3),
  pending       numeric(14, 3),
  unit_rate     numeric(18, 4),
  overdue       boolean
)
language sql
stable
as $$
  select po.id, po.po_number, po.order_date, po.expected_date, po.status, s.name, b.name,
         pol.id, pol.description, pol.quantity, r.received, coalesce(bl.billed, 0),
         case when po.status in ('CLOSED', 'CANCELLED') then 0 else greatest(pol.quantity - r.received, 0) end,
         pol.unit_rate,
         po.expected_date is not null and po.expected_date < current_date
           and po.status in ('APPROVED', 'PARTIAL') and pol.quantity > r.received
    from public.purchase_orders po
    join public.purchase_order_lines pol on pol.purchase_order_id = po.id
    join public.suppliers s on s.id = po.supplier_id
    join public.branches b on b.id = po.branch_id
    cross join lateral (select app.po_line_received(pol.id) as received) r
    left join lateral (
      select sum(app.grn_line_billed(l.id)) as billed
        from public.goods_receipt_lines l join public.goods_receipts g on g.id = l.goods_receipt_id
       where l.po_line_id = pol.id and g.status = 'POSTED') bl on true
   where po.dealer_id = app.current_dealer_id()
     and (p_include_closed or po.status in ('DRAFT', 'APPROVED', 'PARTIAL'))
   order by po.order_date, po.po_number, pol.line_number;
$$;

-- Goods received and not yet billed, line by line; its total is 2760's balance.
create or replace function public.grni_outstanding()
returns table (
  grn_line_id  uuid,
  grn_number   text,
  receipt_date date,
  supplier_name text,
  description  text,
  unbilled     numeric(14, 3),
  unit_cost    numeric(18, 4),
  value        numeric(18, 4)
)
language sql
stable
as $$
  select l.id, g.grn_number, g.receipt_date, s.name, pol.description,
         l.quantity - app.grn_line_billed(l.id), l.unit_cost,
         round((l.quantity - app.grn_line_billed(l.id)) * l.unit_cost, 2)
    from public.goods_receipt_lines l
    join public.goods_receipts g on g.id = l.goods_receipt_id
    join public.purchase_order_lines pol on pol.id = l.po_line_id
    join public.suppliers s on s.id = g.supplier_id
   where g.dealer_id = app.current_dealer_id()
     and g.status = 'POSTED'
     and l.quantity > app.grn_line_billed(l.id)
   order by g.receipt_date, g.grn_number;
$$;

-- -----------------------------------------------------------------------------
-- 9. Posting a bill that bills receipts
-- -----------------------------------------------------------------------------
-- 0084's post_purchase_bill with one change: an ACCESSORY/SPARE line that points
-- at a receipt line adds no stock and debits GRNI at the received value, the
-- difference to the bill's rate going to PRICE_VARIANCE; and it refuses billing
-- more than was received.
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
  v_debit   numeric(18, 4);
  v_cgst    numeric(18, 4);
  v_sgst    numeric(18, 4);
  v_igst    numeric(18, 4);
  v_rcm     numeric(18, 4);
  v_grl     record;
  v_grni    numeric(18, 4);
  v_var     numeric(18, 4);
  v_inbill  numeric(14, 3);
begin
  select * into v_bill from public.purchase_bills where id = p_bill_id for update;

  if v_bill.id is null then
    raise exception 'Purchase bill not found.' using errcode = 'no_data_found';
  end if;
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

  for v_line in
    select * from public.purchase_bill_lines
     where purchase_bill_id = p_bill_id
     order by line_number
  loop
    v_debit := v_line.taxable_value;

    if v_line.line_type = 'VEHICLE' then
      select id, status, chassis_no into v_veh
        from public.vehicles where id = v_line.vehicle_id for update;

      if v_veh.id is null then
        raise exception 'The vehicle on line % no longer exists.', v_line.line_number
          using errcode = 'no_data_found';
      end if;
      if v_veh.status <> 'IN_STOCK' then
        raise exception 'Chassis % is % and cannot be put on a purchase bill.',
          v_veh.chassis_no, v_veh.status using errcode = 'check_violation';
      end if;

      update public.vehicles
         set purchase_cost    = v_line.taxable_value,
             purchase_invoice = coalesce(purchase_invoice, v_bill.supplier_bill_number),
             purchase_date    = coalesce(purchase_date, v_bill.bill_date),
             updated_by       = auth.uid()
       where id = v_line.vehicle_id;

      v_account := app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE',
                                       'VEHICLE_INVENTORY', v_bill.branch_id);

    elsif v_line.line_type = 'EXPENSE' then
      v_account := v_line.account_id;
      if not v_line.itc_eligible then
        v_debit := v_debit + v_line.cgst_amount + v_line.sgst_amount + v_line.igst_amount;
      end if;

    elsif v_line.grn_line_id is not null then
      -- Billing goods already received (0092): the receipt brought the stock in
      -- and credited GRNI; the bill clears GRNI at the received value and puts
      -- any difference in rate to price variance. No second stock-in.
      select l.quantity, l.unit_cost, g.status, g.grn_number into v_grl
        from public.goods_receipt_lines l
        join public.goods_receipts g on g.id = l.goods_receipt_id
       where l.id = v_line.grn_line_id
         for update of l;
      if v_grl.status is distinct from 'POSTED' then
        raise exception 'Line %: goods receipt % is cancelled.', v_line.line_number, v_grl.grn_number
          using errcode = 'check_violation';
      end if;
      select coalesce(sum(quantity), 0) into v_inbill
        from public.purchase_bill_lines
       where purchase_bill_id = p_bill_id and grn_line_id = v_line.grn_line_id;
      if v_inbill > v_grl.quantity - app.grn_line_billed(v_line.grn_line_id, p_bill_id) then
        raise exception 'Line %: % received on %, % already billed; % cannot be billed again.',
          v_line.line_number, v_grl.quantity, v_grl.grn_number,
          app.grn_line_billed(v_line.grn_line_id, p_bill_id), v_inbill using errcode = 'check_violation';
      end if;

      v_grni := round(v_line.quantity * v_grl.unit_cost, 2);
      v_var := v_line.taxable_value - v_grni;
      v_account := app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'GRNI', v_bill.branch_id);
      v_debit := v_grni;
      if v_var <> 0 then
        v_lines := v_lines || jsonb_build_object(
          'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'PRICE_VARIANCE', v_bill.branch_id),
          'debit', greatest(v_var, 0), 'credit', greatest(-v_var, 0),
          'narration', 'Rate difference on ' || v_grl.grn_number || ': ' || v_line.description);
      end if;

    else
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

    if v_debit > 0 then
      v_lines := v_lines || jsonb_build_object(
        'account_id', v_account, 'debit', v_debit, 'credit', 0,
        'narration', v_line.description);
    end if;
  end loop;

  select coalesce(sum(cgst_amount), 0), coalesce(sum(sgst_amount), 0), coalesce(sum(igst_amount), 0)
    into v_cgst, v_sgst, v_igst
    from public.purchase_bill_lines
   where purchase_bill_id = p_bill_id and itc_eligible;

  if v_cgst > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_CGST', v_bill.branch_id),
      'debit', v_cgst, 'credit', 0, 'narration', 'Input CGST ' || v_bill.bill_number);
  end if;
  if v_sgst > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_SGST', v_bill.branch_id),
      'debit', v_sgst, 'credit', 0, 'narration', 'Input SGST ' || v_bill.bill_number);
  end if;
  if v_igst > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_IGST', v_bill.branch_id),
      'debit', v_igst, 'credit', 0, 'narration', 'Input IGST ' || v_bill.bill_number);
  end if;

  -- ── Reverse charge: the dealer owes this tax to the government ───────────
  select coalesce(sum(cgst_amount + sgst_amount + igst_amount), 0) into v_rcm
    from public.purchase_bill_lines
   where purchase_bill_id = p_bill_id and reverse_charge;

  if v_rcm > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'RCM_PAYABLE', v_bill.branch_id),
      'debit', 0, 'credit', v_rcm, 'narration', 'GST on reverse charge ' || v_bill.bill_number);
  end if;

  select total_amount into v_total from public.purchase_bills where id = p_bill_id;

  v_lines := v_lines || jsonb_build_object(
    'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'PAYABLE', v_bill.branch_id),
    'debit', 0, 'credit', v_total,
    'narration', 'Bill ' || v_bill.supplier_bill_number,
    'party_type', 'SUPPLIER', 'party_id', v_bill.supplier_id);

  v_entry := app.post_journal(
    v_bill.dealer_id, v_bill.branch_id, v_bill.bill_date,
    case when exists (select 1 from public.purchase_bill_lines
                       where purchase_bill_id = p_bill_id and line_type <> 'EXPENSE')
         then 'INVENTORY' else 'EXPENSE' end,
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

-- Cancelling a bill that billed a receipt: the journal reverses (GRNI is owed
-- again) and the stock stays — it is still on the shelf.
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
       -- A line that billed a goods receipt brought no stock in; the goods stay.
       and grn_line_id is null
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

-- A goods receipt is posted by whoever may post purchases.
create or replace function app.posting_permissions(p_source_document_type text)
returns text[]
language sql
immutable
as $$
  select case p_source_document_type
    when 'SALE'               then array['sales.post', 'sales.cancel', 'sales.return']
    when 'SALE_RETURN'        then array['sales.return']
    when 'SALE_PAYMENT'       then array['sales.create', 'sales.post', 'cashbook.receipts.create']
    when 'BOOKING'            then array['bookings.create', 'bookings.cancel']
    when 'BOOKING_APPLY'      then array['sales.post', 'bookings.convert']
    when 'BOOKING_REFUND'     then array['bookings.refund']
    when 'SERVICE_INVOICE'    then array['service.billing.create', 'inventory.counter_sale.create']
    when 'SERVICE_RECEIPT'    then array['service.payments.collect', 'service.billing.create', 'inventory.counter_sale.create']
    when 'CASH_BOOK'          then array['cashbook.receipts.create', 'cashbook.payments.create']
    when 'BANK_BOOK'          then array['bank.book.record', 'cashbook.receipts.create', 'cashbook.payments.create']
    when 'CONTRA'             then array['bank.book.record', 'bank.reconcile']
    when 'BANK_ACCOUNT'       then array['bank.accounts.manage']
    when 'PURCHASE_BILL'      then array['purchases.post', 'purchases.create', 'purchases.cancel']
    when 'PURCHASE_RETURN'    then array['purchases.return', 'purchases.cancel']
    when 'GOODS_RECEIPT'      then array['purchases.post', 'purchases.cancel']
    when 'STOCK_ADJUSTMENT'   then array['inventory.stock.adjust', 'inventory.stock.approve', 'vehicles.stock.adjust']
    when 'STOCK_DAMAGE'       then array['inventory.stock.adjust']
    when 'BRANCH_TRANSFER'    then array['inventory.stock.transfer', 'vehicles.transfers.manage']
    when 'FINANCE_APPLICATION' then array['finance.applications.manage']
    when 'FINANCE_SETTLEMENT' then array['finance.settlements.manage']
    when 'TRADE_ADVANCE'      then array['finance.trade_advance.manage']
    when 'GST_NOTE'           then array['gst.notes.manage']
    when 'GST_SETOFF'         then array['gst.returns.file']
    when 'ITC_ADJUSTMENT'     then array['gst.itc.manage']
    when 'DEPRECIATION'       then array['assets.manage']
    when 'ASSET_DISPOSAL'     then array['assets.manage']
    when 'LOAN'               then array['loans.manage']
    when 'PAYROLL'            then array['hr.payroll.run']
    when 'PAYROLL_PAYMENT'    then array['hr.payroll.run']
    when 'MANUAL_JOURNAL'     then array['accounting.journals.post', 'accounting.journals.approve']
    when 'OPENING_BALANCE'    then array['accounting.journals.post']
    else array['accounting.journals.post']
  end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update, delete on public.purchase_orders, public.purchase_order_lines, public.goods_receipts, public.goods_receipt_lines to authenticated';
    execute 'grant execute on function public.create_purchase_order(uuid, uuid, jsonb, date, date, text, text) to authenticated';
    execute 'grant execute on function public.approve_purchase_order(uuid) to authenticated';
    execute 'grant execute on function public.close_purchase_order(uuid, text) to authenticated';
    execute 'grant execute on function public.post_goods_receipt(uuid, jsonb, date, jsonb, text) to authenticated';
    execute 'grant execute on function public.cancel_goods_receipt(uuid, text) to authenticated';
    execute 'grant execute on function public.add_receipt_lines_to_bill(uuid, jsonb) to authenticated';
    execute 'grant execute on function public.unbilled_receipt_lines(uuid, uuid) to authenticated';
    execute 'grant execute on function public.pending_purchase_orders(boolean) to authenticated';
    execute 'grant execute on function public.grni_outstanding() to authenticated';
    execute 'grant execute on function app.po_line_received(uuid) to authenticated';
    execute 'grant execute on function app.grn_line_billed(uuid, uuid) to authenticated';
    execute 'grant execute on function app.refresh_purchase_order_status(uuid) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant all on public.purchase_orders, public.purchase_order_lines, public.goods_receipts, public.goods_receipt_lines to service_role';
  end if;
end $$;

insert into public.schema_migrations (version, name)
values ('0092', 'purchase_orders_goods_receipts') on conflict (version) do nothing;
