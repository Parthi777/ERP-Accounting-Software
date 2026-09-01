-- =============================================================================
-- 0024 — GST integration layer and accounting rules
-- =============================================================================
-- Spec §22, §40.
--
-- Two independent concerns, both about not hard-coding things:
--
--   accounting_rules  Spec §22: "Exact account mapping must be configurable
--                     through accounting rules. Do not hard-code account IDs in
--                     frontend code." A rule maps (module, event, component) to
--                     an account, so posting logic never names an account.
--
--   einvoices         Spec §40: an integration layer, not a coupling. The
--                     e-invoice row is separate from the invoice, so a failure at
--                     the GST portal leaves the accounting transaction untouched
--                     and simply leaves a FAILED row to retry.
--
-- Rollback: drop table public.eway_bills, public.einvoices, public.accounting_rules;
-- =============================================================================

-- =============================================================================
-- accounting_rules — spec §22
-- =============================================================================
create table public.accounting_rules (
  id           uuid primary key default gen_random_uuid(),
  dealer_id    uuid not null references public.dealers (id) on delete cascade,

  -- Which business event this rule serves.
  module       text not null,
  event        text not null,
  -- Which part of the document: EX_SHOWROOM, CGST, VEHICLE_COGS, CASH, …
  component    text not null,

  -- Which side the component posts to, and where.
  side         text not null,
  account_id   uuid not null,

  -- Optional narrowing: a branch may post to a different account.
  branch_id    uuid,
  priority     smallint not null default 100,

  description  text,
  status       text not null default 'ACTIVE',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  created_by   uuid,
  updated_by   uuid,

  constraint ar_id_dealer_key unique (id, dealer_id),
  constraint ar_account_tenant_fkey
    foreign key (account_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint ar_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint ar_module_check check (module in (
    'SALES', 'BOOKING', 'SERVICE', 'ACCESSORY', 'SPARE', 'FINANCE',
    'TRADE_ADVANCE', 'CASH', 'BANK', 'EXPENSE', 'INVENTORY', 'MANUAL', 'OPENING'
  )),
  constraint ar_side_check   check (side in ('DEBIT', 'CREDIT')),
  constraint ar_status_check check (status in ('ACTIVE', 'INACTIVE'))
);

comment on table public.accounting_rules is
  'Maps a business event component to a ledger account (spec §22). Posting code '
  'resolves accounts through this table so no account id is ever hard-coded.';

create unique index ar_scope_key
  on public.accounting_rules (dealer_id, module, event, component,
                              coalesce(branch_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where status = 'ACTIVE';

create index ar_lookup_idx on public.accounting_rules (dealer_id, module, event, status);

-- -----------------------------------------------------------------------------
-- public.resolve_account() — the only way posting code finds an account
-- -----------------------------------------------------------------------------
create or replace function public.resolve_account(
  p_dealer_id uuid,
  p_module    text,
  p_event     text,
  p_component text,
  p_branch_id uuid default null
)
returns uuid
language sql
stable
as $$
  select r.account_id
    from public.accounting_rules r
   where r.dealer_id = p_dealer_id
     and r.module = p_module
     and r.event = p_event
     and r.component = p_component
     and r.status = 'ACTIVE'
     and (r.branch_id is null or r.branch_id = p_branch_id)
   -- A branch-specific rule beats the dealer-wide default.
   order by (r.branch_id is not null) desc, r.priority
   limit 1;
$$;

comment on function public.resolve_account(uuid, text, text, text, uuid) is
  'Resolves the ledger account for a posting component (spec §22). Returns NULL '
  'when unconfigured, which the posting service must treat as an error rather '
  'than guessing an account.';

-- =============================================================================
-- einvoices — spec §40
-- =============================================================================
create table public.einvoices (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null references public.dealers (id) on delete cascade,

  -- Polymorphic: a vehicle sale or a service invoice.
  document_type     text not null,
  document_id       uuid not null,
  document_number   text not null,
  document_date     date not null,

  status            text not null default 'PENDING',

  -- What the portal gave back.
  irn               text,
  ack_number        text,
  ack_date          timestamptz,
  signed_qr_code    text,
  signed_invoice    text,

  -- What we sent and what came back, for the audit reference §40 requires.
  request_payload   jsonb,
  response_payload  jsonb,
  error_code        text,
  error_message     text,

  attempt_count     integer not null default 0,
  last_attempt_at   timestamptz,
  cancelled_at      timestamptz,
  cancel_reason     text,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid,

  constraint einvoices_document_key unique (dealer_id, document_type, document_id),
  constraint einvoices_irn_key      unique (irn),
  constraint einvoices_type_check   check (document_type in ('SALE', 'SERVICE_INVOICE')),
  constraint einvoices_status_check check (status in ('PENDING', 'GENERATED', 'FAILED', 'CANCELLED')),
  -- A generated e-invoice must carry the portal's identifiers.
  constraint einvoices_generated_check check (
    status <> 'GENERATED' or (irn is not null and ack_number is not null)
  ),
  constraint einvoices_failed_check check (status <> 'FAILED' or error_message is not null),
  constraint einvoices_cancel_check check (cancelled_at is null or cancel_reason is not null)
);

comment on table public.einvoices is
  'E-invoice integration layer (spec §40). Separate from the invoice, so a portal '
  'failure never corrupts the accounting transaction — the document stays posted '
  'and this row records FAILED for retry.';

create index einvoices_status_idx   on public.einvoices (dealer_id, status);
create index einvoices_document_idx on public.einvoices (document_type, document_id);
create index einvoices_retry_idx    on public.einvoices (dealer_id, last_attempt_at) where status = 'FAILED';

create table public.eway_bills (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null references public.dealers (id) on delete cascade,

  document_type    text not null,
  document_id      uuid not null,
  document_number  text not null,

  status           text not null default 'PENDING',
  eway_bill_number text,
  generated_at     timestamptz,
  valid_until      timestamptz,

  transport_mode   text,
  vehicle_number   text,
  transporter_id   text,
  transporter_name text,
  distance_km      integer,

  request_payload  jsonb,
  response_payload jsonb,
  error_message    text,
  attempt_count    integer not null default 0,

  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       uuid,

  constraint eway_document_key unique (dealer_id, document_type, document_id),
  constraint eway_number_key   unique (eway_bill_number),
  constraint eway_type_check   check (document_type in ('SALE', 'SERVICE_INVOICE', 'TRANSFER')),
  constraint eway_status_check check (status in ('PENDING', 'GENERATED', 'FAILED', 'CANCELLED', 'EXPIRED')),
  constraint eway_mode_check   check (transport_mode is null or transport_mode in ('ROAD', 'RAIL', 'AIR', 'SHIP')),
  constraint eway_generated_check check (status <> 'GENERATED' or eway_bill_number is not null)
);

create index eway_status_idx   on public.eway_bills (dealer_id, status);
create index eway_document_idx on public.eway_bills (document_type, document_id);

-- Retry bookkeeping belongs to the database, not the caller.
create or replace function app.einvoice_attempt()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status
     and new.status in ('GENERATED', 'FAILED') then
    new.attempt_count := old.attempt_count + 1;
    new.last_attempt_at := now();
  end if;
  return new;
end;
$$;

create trigger einvoice_attempt before update on public.einvoices
  for each row execute function app.einvoice_attempt();

create trigger ar_set_updated_at before update on public.accounting_rules
  for each row execute function app.set_updated_at();
create trigger einvoices_set_updated_at before update on public.einvoices
  for each row execute function app.set_updated_at();
create trigger eway_set_updated_at before update on public.eway_bills
  for each row execute function app.set_updated_at();

create trigger ar_audit after insert or update or delete on public.accounting_rules
  for each row execute function app.audit_trigger();

alter table public.accounting_rules enable row level security;
alter table public.einvoices        enable row level security;
alter table public.eway_bills       enable row level security;

create policy ar_select on public.accounting_rules for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.coa.view')));
create policy ar_write on public.accounting_rules for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.coa.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.coa.manage')));

create policy einvoices_select on public.einvoices for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('gst.summary.view')));
create policy einvoices_write on public.einvoices for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('gst.einvoice.generate') or app.has_permission('gst.einvoice.retry'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy eway_select on public.eway_bills for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('gst.summary.view')));
create policy eway_write on public.eway_bills for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('gst.ewaybill.generate')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('gst.ewaybill.generate')));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update, delete on public.accounting_rules to authenticated';
    execute 'grant select, insert, update on public.einvoices, public.eway_bills to authenticated';
    execute 'grant all on public.accounting_rules, public.einvoices, public.eway_bills to service_role';
    execute 'grant execute on function public.resolve_account(uuid, text, text, text, uuid) to authenticated';
  end if;
end;
$$;
