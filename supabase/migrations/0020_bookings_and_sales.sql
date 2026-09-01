-- =============================================================================
-- 0020 — Bookings, vehicle sales, deliveries
-- =============================================================================
-- Spec §18, §19, §20, §48, §50.
--
-- The sale workflow is DRAFT → SUBMITTED → ACCOUNTS_VERIFICATION → APPROVED →
-- POSTED → DELIVERED (spec §19), and financial posting happens only after
-- approval. The transition guard below encodes that; no service can skip a step.
--
-- Every sale line stores its own tax breakdown (spec §20) rather than deriving it
-- at read time, because the rate that applied on the invoice date must survive
-- later changes to the tax master (spec §16).
--
-- Rollback: drop table public.deliveries, public.sale_payments, public.sale_lines,
--           public.sales, public.booking_payments, public.bookings;
-- =============================================================================

-- =============================================================================
-- bookings — spec §18
-- =============================================================================
create table public.bookings (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null references public.dealers (id) on delete restrict,
  branch_id         uuid not null,

  booking_number    text not null,
  booking_date      date not null default current_date,

  customer_id       uuid not null,
  model_id          uuid not null,
  variant_id        uuid,
  colour_id         uuid,
  -- Optional: a booking may be against a model, or reserve a specific chassis.
  vehicle_id        uuid,

  expected_delivery date,
  booking_amount    numeric(18, 4) not null default 0,
  received_amount   numeric(18, 4) not null default 0,

  sales_executive_id uuid,
  status            text not null default 'OPEN',

  -- Set when the booking becomes a sale.
  converted_sale_id uuid,
  cancelled_reason  text,
  notes             text,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid,
  updated_by        uuid,

  constraint bookings_number_key    unique (dealer_id, booking_number),
  constraint bookings_id_dealer_key unique (id, dealer_id),
  constraint bookings_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint bookings_customer_tenant_fkey
    foreign key (customer_id, dealer_id) references public.customers (id, dealer_id),
  constraint bookings_model_tenant_fkey
    foreign key (model_id, dealer_id) references public.vehicle_models (id, dealer_id),
  constraint bookings_variant_tenant_fkey
    foreign key (variant_id, dealer_id) references public.vehicle_variants (id, dealer_id),
  constraint bookings_vehicle_tenant_fkey
    foreign key (vehicle_id, dealer_id) references public.vehicles (id, dealer_id),
  constraint bookings_employee_tenant_fkey
    foreign key (sales_executive_id, dealer_id) references public.employees (id, dealer_id),
  constraint bookings_status_check check (status in ('OPEN', 'CONVERTED', 'CANCELLED', 'EXPIRED')),
  constraint bookings_amount_check check (booking_amount >= 0 and received_amount >= 0),
  constraint bookings_cancel_reason_check check (status <> 'CANCELLED' or cancelled_reason is not null)
);

comment on table public.bookings is
  'Vehicle bookings (spec §18). The advance posts to Customer Advances, not to '
  'revenue, unless accounting policy says otherwise.';

create index bookings_customer_idx  on public.bookings (customer_id, booking_date desc);
create index bookings_branch_idx    on public.bookings (branch_id, status);
create index bookings_dealer_date_idx on public.bookings (dealer_id, booking_date desc);
create index bookings_vehicle_idx   on public.bookings (vehicle_id) where vehicle_id is not null;
create index bookings_open_idx      on public.bookings (dealer_id) where status = 'OPEN';

create table public.booking_payments (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null,
  booking_id     uuid not null,

  receipt_number text not null,
  payment_date   date not null default current_date,
  amount         numeric(18, 4) not null,
  payment_mode   text not null,
  reference      text,

  journal_entry_id uuid,
  status         text not null default 'RECEIVED',

  created_at     timestamptz not null default now(),
  created_by     uuid,

  constraint booking_payments_receipt_key unique (dealer_id, receipt_number),
  constraint booking_payments_booking_tenant_fkey
    foreign key (booking_id, dealer_id) references public.bookings (id, dealer_id) on delete cascade,
  constraint booking_payments_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint booking_payments_amount_check check (amount > 0),
  constraint booking_payments_mode_check check (payment_mode in (
    'CASH', 'CARD', 'UPI', 'NEFT', 'RTGS', 'IMPS', 'CHEQUE', 'DD', 'FINANCE'
  )),
  constraint booking_payments_status_check check (status in ('RECEIVED', 'REVERSED'))
);

create index booking_payments_booking_idx on public.booking_payments (booking_id);
create index booking_payments_date_idx    on public.booking_payments (dealer_id, payment_date desc);

-- Keep the booking's received total in step with its receipts.
create or replace function app.bookings_sync_received()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_booking uuid := coalesce(new.booking_id, old.booking_id);
begin
  update public.bookings b
     set received_amount = coalesce((
           select sum(p.amount) from public.booking_payments p
            where p.booking_id = v_booking and p.status = 'RECEIVED'
         ), 0)
   where b.id = v_booking;
  return null;
end;
$$;

create trigger booking_payments_sync
  after insert or update or delete on public.booking_payments
  for each row execute function app.bookings_sync_received();

-- =============================================================================
-- sales — spec §19, §20
-- =============================================================================
create table public.sales (
  id                 uuid primary key default gen_random_uuid(),
  dealer_id          uuid not null references public.dealers (id) on delete restrict,
  branch_id          uuid not null,

  invoice_number     text not null,
  invoice_date       date not null default current_date,

  customer_id        uuid not null,
  vehicle_id         uuid not null,
  booking_id         uuid,

  -- The exact price version used, so the invoice stays explainable (spec §42).
  price_version_id   uuid,

  sales_executive_id uuid,

  -- Totals, maintained by trigger from the lines.
  taxable_value      numeric(18, 4) not null default 0,
  cgst_amount        numeric(18, 4) not null default 0,
  sgst_amount        numeric(18, 4) not null default 0,
  igst_amount        numeric(18, 4) not null default 0,
  cess_amount        numeric(18, 4) not null default 0,
  discount_amount    numeric(18, 4) not null default 0,
  total_amount       numeric(18, 4) not null default 0,

  -- Cost side. Restricted from roles without sales.view_cost (spec §52).
  total_cost         numeric(18, 4) not null default 0,

  paid_amount        numeric(18, 4) not null default 0,
  finance_amount     numeric(18, 4) not null default 0,
  balance_amount     numeric(18, 4) generated always as (
    total_amount - paid_amount - finance_amount
  ) stored,

  status             text not null default 'DRAFT',

  submitted_at       timestamptz, submitted_by uuid,
  verified_at        timestamptz, verified_by  uuid,
  approved_at        timestamptz, approved_by  uuid,
  posted_at          timestamptz, posted_by    uuid,
  delivered_at       timestamptz, delivered_by uuid,
  cancelled_at       timestamptz, cancelled_by uuid,
  cancelled_reason   text,
  rejection_reason   text,

  journal_entry_id   uuid,
  -- Duplicate-submission protection (spec §50).
  idempotency_key    text,
  notes              text,

  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  created_by         uuid,
  updated_by         uuid,

  constraint sales_invoice_key   unique (dealer_id, invoice_number),
  constraint sales_id_dealer_key unique (id, dealer_id),
  constraint sales_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint sales_customer_tenant_fkey
    foreign key (customer_id, dealer_id) references public.customers (id, dealer_id),
  constraint sales_vehicle_tenant_fkey
    foreign key (vehicle_id, dealer_id) references public.vehicles (id, dealer_id),
  constraint sales_booking_tenant_fkey
    foreign key (booking_id, dealer_id) references public.bookings (id, dealer_id),
  constraint sales_price_version_tenant_fkey
    foreign key (price_version_id, dealer_id) references public.vehicle_price_versions (id, dealer_id),
  constraint sales_employee_tenant_fkey
    foreign key (sales_executive_id, dealer_id) references public.employees (id, dealer_id),
  constraint sales_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),

  constraint sales_status_check check (status in (
    'DRAFT', 'SUBMITTED', 'ACCOUNTS_VERIFICATION', 'APPROVED', 'POSTED', 'DELIVERED', 'CANCELLED', 'RETURNED'
  )),
  constraint sales_amounts_check check (
    taxable_value >= 0 and cgst_amount >= 0 and sgst_amount >= 0 and igst_amount >= 0
    and cess_amount >= 0 and discount_amount >= 0 and total_amount >= 0
    and paid_amount >= 0 and finance_amount >= 0 and total_cost >= 0
  ),
  -- Intra-state and inter-state are mutually exclusive on one invoice.
  constraint sales_gst_mode_check check (
    (igst_amount = 0) or (cgst_amount = 0 and sgst_amount = 0)
  ),
  constraint sales_posted_journal_check check (status not in ('POSTED', 'DELIVERED') or journal_entry_id is not null),
  constraint sales_cancel_reason_check check (status <> 'CANCELLED' or cancelled_reason is not null)
);

comment on table public.sales is
  'Vehicle sale invoice (spec §19, §20). Financial posting happens at APPROVED → '
  'POSTED, never before (spec §19).';
comment on column public.sales.total_cost is
  'Restricted. Withheld from roles lacking sales.view_cost (spec §52).';

create unique index sales_idempotency_key
  on public.sales (dealer_id, idempotency_key) where idempotency_key is not null;

-- One live sale per vehicle: a chassis cannot be on two open invoices (spec §49).
create unique index sales_vehicle_active_key
  on public.sales (vehicle_id)
  where status not in ('CANCELLED', 'RETURNED');

create index sales_customer_idx    on public.sales (customer_id, invoice_date desc);
create index sales_branch_date_idx on public.sales (branch_id, invoice_date desc);
create index sales_dealer_date_idx on public.sales (dealer_id, invoice_date desc);
create index sales_status_idx      on public.sales (dealer_id, status);
create index sales_booking_idx     on public.sales (booking_id) where booking_id is not null;
create index sales_executive_idx   on public.sales (sales_executive_id) where sales_executive_id is not null;

-- -----------------------------------------------------------------------------
-- sale_lines — spec §20, every component itemised with its own tax
-- -----------------------------------------------------------------------------
create table public.sale_lines (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null,
  sale_id        uuid not null,

  line_number    smallint not null,
  line_type      text not null,

  description    text not null,
  item_id        uuid,
  hsn_code       text,

  quantity       numeric(14, 3) not null default 1,
  unit_rate      numeric(18, 4) not null default 0,
  discount       numeric(18, 4) not null default 0,
  taxable_value  numeric(18, 4) not null default 0,

  tax_code       text,
  cgst_rate      numeric(6, 3) not null default 0,
  sgst_rate      numeric(6, 3) not null default 0,
  igst_rate      numeric(6, 3) not null default 0,
  cgst_amount    numeric(18, 4) not null default 0,
  sgst_amount    numeric(18, 4) not null default 0,
  igst_amount    numeric(18, 4) not null default 0,
  cess_amount    numeric(18, 4) not null default 0,

  total_amount   numeric(18, 4) not null default 0,

  -- Cost and allocation source, for margin and for the audit of spec §31.
  unit_cost      numeric(18, 4) not null default 0,
  cost_amount    numeric(18, 4) not null default 0,
  stock_source   text,

  created_at     timestamptz not null default now(),

  constraint sale_lines_line_key unique (sale_id, line_number),
  constraint sale_lines_sale_tenant_fkey
    foreign key (sale_id, dealer_id) references public.sales (id, dealer_id) on delete cascade,
  constraint sale_lines_item_tenant_fkey
    foreign key (item_id, dealer_id) references public.inventory_items (id, dealer_id),
  constraint sale_lines_type_check check (line_type in (
    'VEHICLE', 'INSURANCE', 'REGISTRATION', 'ACCESSORY', 'FITTING',
    'FORWARDING', 'OTHER_CHARGE', 'DISCOUNT', 'SPARE', 'LABOUR'
  )),
  constraint sale_lines_source_check check (stock_source is null or stock_source in ('LOCAL', 'COMPANY')),
  constraint sale_lines_amounts_check check (
    quantity > 0 and unit_rate >= 0 and discount >= 0 and taxable_value >= 0
    and cgst_amount >= 0 and sgst_amount >= 0 and igst_amount >= 0 and total_amount >= 0
  )
);

comment on table public.sale_lines is
  'Invoice lines (spec §20). stock_source records whether a fitting came from '
  'LOCAL or COMPANY stock, so the allocation is visible on the invoice (spec §31).';

create index sale_lines_sale_idx on public.sale_lines (sale_id, line_number);
create index sale_lines_item_idx on public.sale_lines (item_id) where item_id is not null;

create table public.sale_payments (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null,
  sale_id          uuid not null,

  receipt_number   text not null,
  payment_date     date not null default current_date,
  amount           numeric(18, 4) not null,
  payment_mode     text not null,
  reference        text,

  finance_company_id uuid,
  journal_entry_id uuid,
  status           text not null default 'RECEIVED',

  created_at       timestamptz not null default now(),
  created_by       uuid,

  constraint sale_payments_receipt_key unique (dealer_id, receipt_number),
  constraint sale_payments_sale_tenant_fkey
    foreign key (sale_id, dealer_id) references public.sales (id, dealer_id) on delete cascade,
  constraint sale_payments_finance_tenant_fkey
    foreign key (finance_company_id, dealer_id) references public.finance_companies (id, dealer_id),
  constraint sale_payments_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint sale_payments_amount_check check (amount > 0),
  constraint sale_payments_mode_check check (payment_mode in (
    'CASH', 'CARD', 'UPI', 'NEFT', 'RTGS', 'IMPS', 'CHEQUE', 'DD', 'FINANCE', 'BOOKING_ADVANCE'
  )),
  constraint sale_payments_status_check check (status in ('RECEIVED', 'REVERSED'))
);

create index sale_payments_sale_idx on public.sale_payments (sale_id);
create index sale_payments_date_idx on public.sale_payments (dealer_id, payment_date desc);

create table public.deliveries (
  id              uuid primary key default gen_random_uuid(),
  dealer_id       uuid not null,
  branch_id       uuid not null,
  sale_id         uuid not null,
  vehicle_id      uuid not null,

  delivery_number text not null,
  delivered_at    timestamptz not null default now(),
  delivered_by    uuid,
  received_by_name text,
  odometer        numeric(10, 1),
  remarks         text,

  created_at      timestamptz not null default now(),

  constraint deliveries_number_key unique (dealer_id, delivery_number),
  constraint deliveries_sale_key   unique (sale_id),
  constraint deliveries_sale_tenant_fkey
    foreign key (sale_id, dealer_id) references public.sales (id, dealer_id) on delete cascade,
  constraint deliveries_vehicle_tenant_fkey
    foreign key (vehicle_id, dealer_id) references public.vehicles (id, dealer_id),
  constraint deliveries_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id)
);

create index deliveries_vehicle_idx on public.deliveries (vehicle_id);
create index deliveries_date_idx    on public.deliveries (dealer_id, delivered_at desc);

-- -----------------------------------------------------------------------------
-- Sale workflow guard — spec §19
-- -----------------------------------------------------------------------------
create or replace function app.sales_guard()
returns trigger
language plpgsql
as $$
declare
  v_allowed text[];
begin
  if tg_op = 'DELETE' then
    if old.status <> 'DRAFT' then
      raise exception 'Sale % is % and cannot be deleted.', old.invoice_number, old.status
        using errcode = 'insufficient_privilege',
              hint = 'Cancel it, or post a sales return.';
    end if;
    return old;
  end if;

  if tg_op = 'INSERT' then
    if new.status <> 'DRAFT' then
      raise exception 'A sale is created as DRAFT, not %.', new.status
        using errcode = 'check_violation';
    end if;
    return new;
  end if;

  if new.status = old.status then
    -- A posted invoice's figures are fixed; only the payment tally may move.
    -- Columns are compared explicitly: `balance_amount` is generated, and a
    -- BEFORE trigger does not see generated columns populated in NEW, so a
    -- subtractive JSONB comparison would flag every update as a change.
    if old.status in ('POSTED', 'DELIVERED')
       and (new.taxable_value   is distinct from old.taxable_value
         or new.cgst_amount     is distinct from old.cgst_amount
         or new.sgst_amount     is distinct from old.sgst_amount
         or new.igst_amount     is distinct from old.igst_amount
         or new.cess_amount     is distinct from old.cess_amount
         or new.discount_amount is distinct from old.discount_amount
         or new.total_amount    is distinct from old.total_amount
         or new.total_cost      is distinct from old.total_cost
         or new.invoice_number  is distinct from old.invoice_number
         or new.invoice_date    is distinct from old.invoice_date
         or new.customer_id     is distinct from old.customer_id
         or new.vehicle_id      is distinct from old.vehicle_id
         or new.journal_entry_id is distinct from old.journal_entry_id) then
      raise exception 'Sale % is % and its invoice values are immutable.', old.invoice_number, old.status
        using errcode = 'insufficient_privilege',
              hint = 'Spec §23: correct it with a reversal and a fresh invoice.';
    end if;
    return new;
  end if;

  v_allowed := case old.status
    when 'DRAFT'                 then array['SUBMITTED', 'CANCELLED']
    when 'SUBMITTED'             then array['ACCOUNTS_VERIFICATION', 'DRAFT', 'CANCELLED']
    when 'ACCOUNTS_VERIFICATION' then array['APPROVED', 'DRAFT', 'CANCELLED']
    when 'APPROVED'              then array['POSTED', 'CANCELLED']
    when 'POSTED'                then array['DELIVERED', 'RETURNED']
    when 'DELIVERED'             then array['RETURNED']
    else array[]::text[]
  end;

  if not (new.status = any (v_allowed)) then
    raise exception 'Sale % cannot move from % to %.', old.invoice_number, old.status, new.status
      using errcode = 'check_violation',
            hint = 'Spec §19 defines the sale workflow.';
  end if;

  -- Posting requires the accounting entry to exist (spec §19, §48).
  if new.status = 'POSTED' and new.journal_entry_id is null then
    raise exception 'Sale % cannot be POSTED without a journal entry.', old.invoice_number
      using errcode = 'check_violation',
            hint = 'Spec §48: an invoice without its accounting effect is not permitted.';
  end if;

  new.posted_at    := case when new.status = 'POSTED'    then coalesce(new.posted_at, now())    else new.posted_at end;
  new.delivered_at := case when new.status = 'DELIVERED' then coalesce(new.delivered_at, now()) else new.delivered_at end;
  return new;
end;
$$;

create trigger sales_guard
  before insert or update or delete on public.sales
  for each row execute function app.sales_guard();

-- Lines may only change while the invoice is still being prepared.
create or replace function app.sale_lines_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status text;
  v_sale uuid := coalesce(new.sale_id, old.sale_id);
begin
  select status into v_status from public.sales where id = v_sale;
  if v_status is null then
    return coalesce(new, old);
  end if;
  if v_status not in ('DRAFT', 'SUBMITTED', 'ACCOUNTS_VERIFICATION') then
    raise exception 'Cannot % lines of a % sale.', lower(tg_op), v_status
      using errcode = 'insufficient_privilege';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger sale_lines_guard
  before insert or update or delete on public.sale_lines
  for each row execute function app.sale_lines_guard();

-- Invoice totals are derived from the lines, never supplied by the caller.
create or replace function app.sales_sync_totals()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sale uuid := coalesce(new.sale_id, old.sale_id);
begin
  update public.sales s
     set taxable_value   = coalesce(t.taxable, 0),
         cgst_amount     = coalesce(t.cgst, 0),
         sgst_amount     = coalesce(t.sgst, 0),
         igst_amount     = coalesce(t.igst, 0),
         cess_amount     = coalesce(t.cess, 0),
         discount_amount = coalesce(t.discount, 0),
         total_amount    = coalesce(t.total, 0),
         total_cost      = coalesce(t.cost, 0)
    from (
      select sum(l.taxable_value) taxable, sum(l.cgst_amount) cgst, sum(l.sgst_amount) sgst,
             sum(l.igst_amount) igst, sum(l.cess_amount) cess, sum(l.discount) discount,
             sum(l.total_amount) total, sum(l.cost_amount) cost
        from public.sale_lines l where l.sale_id = v_sale
    ) t
   where s.id = v_sale
     and s.status in ('DRAFT', 'SUBMITTED', 'ACCOUNTS_VERIFICATION');
  return null;
end;
$$;

create trigger sale_lines_sync_totals
  after insert or update or delete on public.sale_lines
  for each row execute function app.sales_sync_totals();

create or replace function app.sales_sync_payments()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sale uuid := coalesce(new.sale_id, old.sale_id);
begin
  update public.sales s
     set paid_amount = coalesce((
           select sum(p.amount) from public.sale_payments p
            where p.sale_id = v_sale and p.status = 'RECEIVED' and p.payment_mode <> 'FINANCE'
         ), 0),
         finance_amount = coalesce((
           select sum(p.amount) from public.sale_payments p
            where p.sale_id = v_sale and p.status = 'RECEIVED' and p.payment_mode = 'FINANCE'
         ), 0)
   where s.id = v_sale;
  return null;
end;
$$;

create trigger sale_payments_sync
  after insert or update or delete on public.sale_payments
  for each row execute function app.sales_sync_payments();

create trigger bookings_set_updated_at before update on public.bookings
  for each row execute function app.set_updated_at();
create trigger sales_set_updated_at before update on public.sales
  for each row execute function app.set_updated_at();

create trigger bookings_audit after insert or update or delete on public.bookings
  for each row execute function app.audit_trigger();
create trigger sales_audit after insert or update or delete on public.sales
  for each row execute function app.audit_trigger();
create trigger deliveries_audit after insert or update or delete on public.deliveries
  for each row execute function app.audit_trigger();

alter table public.bookings         enable row level security;
alter table public.booking_payments enable row level security;
alter table public.sales            enable row level security;
alter table public.sale_lines       enable row level security;
alter table public.sale_payments    enable row level security;
alter table public.deliveries       enable row level security;

create policy bookings_select on public.bookings for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('bookings.view')));
create policy bookings_insert on public.bookings for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('bookings.create')));
create policy bookings_update on public.bookings for update to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('bookings.create') or app.has_permission('bookings.cancel')
              or app.has_permission('bookings.convert'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy booking_payments_select on public.booking_payments for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bookings.view')));
create policy booking_payments_insert on public.booking_payments for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bookings.create')));

create policy sales_select on public.sales for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('sales.view')));
create policy sales_insert on public.sales for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('sales.create')));
create policy sales_update on public.sales for update to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('sales.create') or app.has_permission('sales.submit')
              or app.has_permission('sales.verify') or app.has_permission('sales.approve')
              or app.has_permission('sales.post') or app.has_permission('sales.deliver')
              or app.has_permission('sales.cancel'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy sale_lines_select on public.sale_lines for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('sales.view')));
create policy sale_lines_write on public.sale_lines for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('sales.create')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('sales.create')));

create policy sale_payments_select on public.sale_payments for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('sales.view')));
create policy sale_payments_insert on public.sale_payments for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('sales.create')));

create policy deliveries_select on public.deliveries for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('sales.view')));
create policy deliveries_insert on public.deliveries for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('sales.deliver')));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.bookings, public.sales to authenticated';
    execute 'grant select, insert on public.booking_payments, public.sale_payments, public.deliveries to authenticated';
    execute 'grant select, insert, update, delete on public.sale_lines to authenticated';
    execute 'grant all on public.bookings, public.booking_payments, public.sales, public.sale_lines, public.sale_payments, public.deliveries to service_role';
  end if;
end;
$$;
