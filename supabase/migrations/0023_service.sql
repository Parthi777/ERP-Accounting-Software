-- =============================================================================
-- 0023 — Service: job cards, service billing, counter sales
-- =============================================================================
-- Spec §32, §33. Service consumes the same inventory as counter sales and posts
-- through the same accounting engine, so there is no separate stock or ledger
-- mechanism here — only the documents.
--
-- Counter sales (§33) reuse the service invoice with no job card attached: the
-- transaction is identical apart from the absence of a vehicle.
--
-- Rollback: drop table public.service_payments, public.service_lines,
--           public.service_invoices, public.job_cards, public.customer_vehicles;
-- =============================================================================

-- -----------------------------------------------------------------------------
-- customer_vehicles — spec §44. What the customer owns, whether we sold it or not.
-- -----------------------------------------------------------------------------
create table public.customer_vehicles (
  id              uuid primary key default gen_random_uuid(),
  dealer_id       uuid not null references public.dealers (id) on delete cascade,
  customer_id     uuid not null,

  -- Present when the unit came from our own stock; absent for a walk-in service.
  vehicle_id      uuid,
  model_id        uuid,
  variant_id      uuid,

  registration_no text,
  chassis_no      text,
  engine_no       text,
  colour          text,
  purchase_date   date,

  status          text not null default 'ACTIVE',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint cv_id_dealer_key unique (id, dealer_id),
  constraint cv_customer_tenant_fkey
    foreign key (customer_id, dealer_id) references public.customers (id, dealer_id) on delete cascade,
  constraint cv_vehicle_tenant_fkey
    foreign key (vehicle_id, dealer_id) references public.vehicles (id, dealer_id),
  constraint cv_model_tenant_fkey
    foreign key (model_id, dealer_id) references public.vehicle_models (id, dealer_id),
  constraint cv_status_check check (status in ('ACTIVE', 'SOLD', 'SCRAPPED')),
  -- Something must identify the vehicle, or the record is useless for search.
  constraint cv_identity_check check (
    registration_no is not null or chassis_no is not null or vehicle_id is not null
  )
);

create unique index cv_registration_key on public.customer_vehicles (dealer_id, registration_no)
  where registration_no is not null;
create index cv_customer_idx on public.customer_vehicles (customer_id);
create index cv_chassis_idx  on public.customer_vehicles (dealer_id, chassis_no) where chassis_no is not null;

-- -----------------------------------------------------------------------------
-- job_cards — spec §32
-- -----------------------------------------------------------------------------
create table public.job_cards (
  id                  uuid primary key default gen_random_uuid(),
  dealer_id           uuid not null references public.dealers (id) on delete restrict,
  branch_id           uuid not null,

  job_card_number     text not null,
  job_date            date not null default current_date,

  customer_id         uuid not null,
  customer_vehicle_id uuid,
  registration_no     text,
  odometer            numeric(10, 1),

  service_type        text not null default 'PAID',
  complaint           text,
  diagnosis           text,

  service_advisor_id  uuid,
  technician_id       uuid,

  promised_at         timestamptz,
  status              text not null default 'OPEN',
  closed_at           timestamptz,

  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid,
  updated_by          uuid,

  constraint jc_number_key    unique (dealer_id, job_card_number),
  constraint jc_id_dealer_key unique (id, dealer_id),
  constraint jc_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint jc_customer_tenant_fkey
    foreign key (customer_id, dealer_id) references public.customers (id, dealer_id),
  constraint jc_vehicle_tenant_fkey
    foreign key (customer_vehicle_id, dealer_id) references public.customer_vehicles (id, dealer_id),
  constraint jc_advisor_tenant_fkey
    foreign key (service_advisor_id, dealer_id) references public.employees (id, dealer_id),
  constraint jc_technician_tenant_fkey
    foreign key (technician_id, dealer_id) references public.employees (id, dealer_id),
  constraint jc_type_check   check (service_type in ('FREE', 'PAID', 'WARRANTY', 'ACCIDENT', 'RUNNING_REPAIR')),
  constraint jc_status_check check (status in ('OPEN', 'IN_PROGRESS', 'READY', 'INVOICED', 'CLOSED', 'CANCELLED'))
);

create index jc_customer_idx    on public.job_cards (customer_id, job_date desc);
create index jc_branch_date_idx on public.job_cards (branch_id, job_date desc);
create index jc_status_idx      on public.job_cards (dealer_id, status);
create index jc_vehicle_idx     on public.job_cards (customer_vehicle_id) where customer_vehicle_id is not null;

-- -----------------------------------------------------------------------------
-- service_invoices — also used for counter sales (spec §33)
-- -----------------------------------------------------------------------------
create table public.service_invoices (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null references public.dealers (id) on delete restrict,
  branch_id        uuid not null,

  invoice_number   text not null,
  invoice_date     date not null default current_date,
  -- SERVICE when a job card is attached, COUNTER for over-the-counter sales.
  invoice_type     text not null default 'SERVICE',

  job_card_id      uuid,
  customer_id      uuid,

  taxable_value    numeric(18, 4) not null default 0,
  cgst_amount      numeric(18, 4) not null default 0,
  sgst_amount      numeric(18, 4) not null default 0,
  igst_amount      numeric(18, 4) not null default 0,
  discount_amount  numeric(18, 4) not null default 0,
  total_amount     numeric(18, 4) not null default 0,
  total_cost       numeric(18, 4) not null default 0,
  paid_amount      numeric(18, 4) not null default 0,

  status           text not null default 'DRAFT',
  posted_at        timestamptz,
  journal_entry_id uuid,
  idempotency_key  text,

  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       uuid,
  updated_by       uuid,

  constraint si_number_key    unique (dealer_id, invoice_number),
  constraint si_id_dealer_key unique (id, dealer_id),
  constraint si_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint si_job_card_tenant_fkey
    foreign key (job_card_id, dealer_id) references public.job_cards (id, dealer_id),
  constraint si_customer_tenant_fkey
    foreign key (customer_id, dealer_id) references public.customers (id, dealer_id),
  constraint si_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint si_type_check   check (invoice_type in ('SERVICE', 'COUNTER')),
  constraint si_status_check check (status in ('DRAFT', 'POSTED', 'CANCELLED', 'RETURNED')),
  constraint si_amounts_check check (
    taxable_value >= 0 and total_amount >= 0 and paid_amount >= 0 and total_cost >= 0
  ),
  constraint si_gst_mode_check check ((igst_amount = 0) or (cgst_amount = 0 and sgst_amount = 0)),
  -- A service invoice needs its job card; a counter sale must not have one.
  constraint si_job_card_shape_check check (
    (invoice_type = 'SERVICE' and job_card_id is not null)
    or (invoice_type = 'COUNTER' and job_card_id is null)
  ),
  constraint si_posted_journal_check check (status <> 'POSTED' or journal_entry_id is not null)
);

create unique index si_idempotency_key on public.service_invoices (dealer_id, idempotency_key)
  where idempotency_key is not null;
create index si_branch_date_idx on public.service_invoices (branch_id, invoice_date desc);
create index si_customer_idx    on public.service_invoices (customer_id) where customer_id is not null;
create index si_job_card_idx    on public.service_invoices (job_card_id) where job_card_id is not null;
create index si_status_idx      on public.service_invoices (dealer_id, status);

create table public.service_lines (
  id            uuid primary key default gen_random_uuid(),
  dealer_id     uuid not null,
  invoice_id    uuid not null,

  line_number   smallint not null,
  line_type     text not null,

  description   text not null,
  item_id       uuid,
  hsn_code      text,

  quantity      numeric(14, 3) not null default 1,
  unit_rate     numeric(18, 4) not null default 0,
  discount      numeric(18, 4) not null default 0,
  taxable_value numeric(18, 4) not null default 0,

  tax_code      text,
  cgst_rate     numeric(6, 3) not null default 0,
  sgst_rate     numeric(6, 3) not null default 0,
  igst_rate     numeric(6, 3) not null default 0,
  cgst_amount   numeric(18, 4) not null default 0,
  sgst_amount   numeric(18, 4) not null default 0,
  igst_amount   numeric(18, 4) not null default 0,
  total_amount  numeric(18, 4) not null default 0,

  unit_cost     numeric(18, 4) not null default 0,
  cost_amount   numeric(18, 4) not null default 0,
  stock_source  text,

  created_at    timestamptz not null default now(),

  constraint sl_line_key unique (invoice_id, line_number),
  constraint sl_invoice_tenant_fkey
    foreign key (invoice_id, dealer_id) references public.service_invoices (id, dealer_id) on delete cascade,
  constraint sl_item_tenant_fkey
    foreign key (item_id, dealer_id) references public.inventory_items (id, dealer_id),
  constraint sl_type_check   check (line_type in ('LABOUR', 'SPARE', 'ACCESSORY', 'OTHER_CHARGE', 'DISCOUNT')),
  constraint sl_source_check check (stock_source is null or stock_source in ('LOCAL', 'COMPANY')),
  constraint sl_amounts_check check (quantity > 0 and unit_rate >= 0 and taxable_value >= 0)
);

create index sl_invoice_idx on public.service_lines (invoice_id, line_number);
create index sl_item_idx     on public.service_lines (item_id) where item_id is not null;

create table public.service_payments (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null,
  invoice_id     uuid not null,

  receipt_number text not null,
  payment_date   date not null default current_date,
  amount         numeric(18, 4) not null,
  payment_mode   text not null,
  reference      text,

  journal_entry_id uuid,
  status         text not null default 'RECEIVED',
  created_at     timestamptz not null default now(),
  created_by     uuid,

  constraint sp_receipt_key unique (dealer_id, receipt_number),
  constraint sp_invoice_tenant_fkey
    foreign key (invoice_id, dealer_id) references public.service_invoices (id, dealer_id) on delete cascade,
  constraint sp_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint sp_amount_check check (amount > 0),
  constraint sp_mode_check check (payment_mode in ('CASH', 'CARD', 'UPI', 'NEFT', 'RTGS', 'IMPS', 'CHEQUE')),
  constraint sp_status_check check (status in ('RECEIVED', 'REVERSED'))
);

create index sp_invoice_idx on public.service_payments (invoice_id);

-- Totals from the lines; a posted invoice is frozen.
create or replace function app.service_sync_totals()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_invoice uuid := coalesce(new.invoice_id, old.invoice_id);
begin
  update public.service_invoices s
     set taxable_value   = coalesce(t.taxable, 0),
         cgst_amount     = coalesce(t.cgst, 0),
         sgst_amount     = coalesce(t.sgst, 0),
         igst_amount     = coalesce(t.igst, 0),
         discount_amount = coalesce(t.discount, 0),
         total_amount    = coalesce(t.total, 0),
         total_cost      = coalesce(t.cost, 0)
    from (
      select sum(l.taxable_value) taxable, sum(l.cgst_amount) cgst, sum(l.sgst_amount) sgst,
             sum(l.igst_amount) igst, sum(l.discount) discount, sum(l.total_amount) total,
             sum(l.cost_amount) cost
        from public.service_lines l where l.invoice_id = v_invoice
    ) t
   where s.id = v_invoice and s.status = 'DRAFT';
  return null;
end;
$$;

create trigger service_lines_sync_totals
  after insert or update or delete on public.service_lines
  for each row execute function app.service_sync_totals();

create or replace function app.service_invoice_guard()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    if old.status <> 'DRAFT' then
      raise exception 'Service invoice % is % and cannot be deleted.', old.invoice_number, old.status
        using errcode = 'insufficient_privilege';
    end if;
    return old;
  end if;

  if tg_op = 'INSERT' then
    if new.status <> 'DRAFT' then
      raise exception 'A service invoice is created as DRAFT.'
        using errcode = 'check_violation';
    end if;
    return new;
  end if;

  if old.status = 'POSTED' and new.status = 'POSTED'
     and (new.taxable_value   is distinct from old.taxable_value
       or new.cgst_amount     is distinct from old.cgst_amount
       or new.sgst_amount     is distinct from old.sgst_amount
       or new.igst_amount     is distinct from old.igst_amount
       or new.discount_amount is distinct from old.discount_amount
       or new.total_amount    is distinct from old.total_amount
       or new.total_cost      is distinct from old.total_cost
       or new.invoice_number  is distinct from old.invoice_number
       or new.invoice_date    is distinct from old.invoice_date
       or new.journal_entry_id is distinct from old.journal_entry_id) then
    raise exception 'Service invoice % is POSTED and immutable.', old.invoice_number
      using errcode = 'insufficient_privilege';
  end if;

  if new.status = 'POSTED' and old.status = 'DRAFT' then
    if new.journal_entry_id is null then
      raise exception 'A service invoice cannot be POSTED without its journal entry.'
        using errcode = 'check_violation';
    end if;
    new.posted_at := coalesce(new.posted_at, now());
  end if;

  return new;
end;
$$;

create trigger service_invoice_guard
  before insert or update or delete on public.service_invoices
  for each row execute function app.service_invoice_guard();

create or replace function app.service_sync_payments()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_invoice uuid := coalesce(new.invoice_id, old.invoice_id);
begin
  update public.service_invoices s
     set paid_amount = coalesce((
           select sum(p.amount) from public.service_payments p
            where p.invoice_id = v_invoice and p.status = 'RECEIVED'), 0)
   where s.id = v_invoice;
  return null;
end;
$$;

create trigger service_payments_sync
  after insert or update or delete on public.service_payments
  for each row execute function app.service_sync_payments();

create trigger cv_set_updated_at before update on public.customer_vehicles
  for each row execute function app.set_updated_at();
create trigger jc_set_updated_at before update on public.job_cards
  for each row execute function app.set_updated_at();
create trigger si_set_updated_at before update on public.service_invoices
  for each row execute function app.set_updated_at();

create trigger jc_audit after insert or update or delete on public.job_cards
  for each row execute function app.audit_trigger();
create trigger si_audit after insert or update or delete on public.service_invoices
  for each row execute function app.audit_trigger();

alter table public.customer_vehicles enable row level security;
alter table public.job_cards         enable row level security;
alter table public.service_invoices  enable row level security;
alter table public.service_lines     enable row level security;
alter table public.service_payments  enable row level security;

create policy cv_select on public.customer_vehicles for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('customers.view')));
create policy cv_write on public.customer_vehicles for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('customers.edit') or app.has_permission('service.jobcards.create'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy jc_select on public.job_cards for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('service.jobcards.view')));
create policy jc_write on public.job_cards for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('service.jobcards.create')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('service.jobcards.create')));

create policy si_select on public.service_invoices for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id)
         and (app.has_permission('service.jobcards.view') or app.has_permission('inventory.view'))));
create policy si_write on public.service_invoices for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('service.billing.create') or app.has_permission('inventory.counter_sale.create'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy sl_select on public.service_lines for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('service.jobcards.view') or app.has_permission('inventory.view'))));
create policy sl_write on public.service_lines for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('service.billing.create') or app.has_permission('inventory.counter_sale.create'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy sp_select on public.service_payments for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('service.jobcards.view') or app.has_permission('inventory.view'))));
create policy sp_insert on public.service_payments for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('service.payments.collect') or app.has_permission('inventory.counter_sale.create'))));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update, delete on public.customer_vehicles, public.job_cards, public.service_invoices, public.service_lines to authenticated';
    execute 'grant select, insert on public.service_payments to authenticated';
    execute 'grant all on public.customer_vehicles, public.job_cards, public.service_invoices, public.service_lines, public.service_payments to service_role';
  end if;
end;
$$;
