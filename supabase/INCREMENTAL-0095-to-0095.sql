-- =============================================================================
-- INCREMENTAL 0095 → 0095
-- =============================================================================
-- GENERATED FILE. Regenerate with:
--   FROM=0095 bash scripts/build-incremental.sh
--
-- For a database that ALREADY has migrations up to 0094.
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
-- SOURCE: supabase/migrations/0095_hr_integration.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0095 — The HR Payroll app, connected: claims, people, payroll
-- =============================================================================
-- The dealer runs an HR app (its own Railway project) where staff raise
-- expense claims and managers approve them. Until now the cash went out of the
-- drawer and the books never heard of it. From here:
--
--   HR app                         this ERP
--   ──────                         ────────
--   claim approved  ── signed ──►  receive_hr_claim(): the expense is booked
--                     webhook          Dr <expense head for the claim type>
--                                      Cr 2770 Employee Claims Payable  (the employee)
--   (claim shows     ◄── paid ────  pay_employee_claims(): the cashier pays it
--    PAID there)                       from the cash or bank book, one voucher
--                                      Dr 2770 (the employee)  Cr Cash / Bank
--   approval taken  ── webhook ──►  hr_claim_changed(): an unpaid claim's
--   back                               expense is reversed; a paid one is
--                                      flagged for the accountant
--
-- The HR app stays the source of truth for people, attendance, approval and
-- payroll calculation; this ERP for money. Employees are mirrored by the HR
-- app's id (employees.external_ref, 0054), branches through hr_branch_map, and
-- a claim type reaches the books only through hr_claim_heads — a claim of a
-- type nobody has mapped waits as AWAITING_MAPPING and is booked once it is.
--
-- The inbound functions run for the webhook, which has no signed-in user: they
-- take the dealer explicitly and are executable by the service role only. The
-- functions people call (paying, mapping, importing payroll) check permissions
-- as every other function does.
--
-- Rollback: drop the tables and functions added here; delete account 2770 if
--           unused; drop payroll_runs.source / source_ref.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Permissions, account, posting authority
-- -----------------------------------------------------------------------------
insert into public.permissions (code, module, description, is_sensitive) values
  ('hr.claims.view', 'hr', 'View employee claims from the HR app', false),
  ('hr.claims.pay',  'hr', 'Pay approved employee claims from the cash or bank book', false)
on conflict (code) do update set module = excluded.module, description = excluded.description,
                                 is_sensitive = excluded.is_sensitive;

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join (values ('hr.claims.view'), ('hr.claims.pay')) as p(code)
 where r.is_system and r.code in ('DEALER_OWNER', 'ACCOUNTS', 'CASHIER')
on conflict do nothing;

create or replace function app.seed_hr_claim_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
declare
  v_added integer := 0;
  a       record;
begin
  for a in
    select * from (values
      ('2770', 'Employee Claims Payable', 'LIABILITY', 'CREDIT')
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
  select p_dealer_id, 'EXPENSE', 'CLAIM', 'CLAIMS_PAYABLE', 'CREDIT', c.id, 'Default mapping'
    from public.chart_of_accounts c
   where c.dealer_id = p_dealer_id and c.code = '2770' and not c.is_group
     and not exists (select 1 from public.accounting_rules x
                      where x.dealer_id = p_dealer_id and x.module = 'EXPENSE' and x.event = 'CLAIM'
                        and x.component = 'CLAIMS_PAYABLE' and x.branch_id is null and x.status = 'ACTIVE');
  return v_added;
end;
$$;

do $$
declare d record;
begin
  for d in select id from public.dealers loop
    perform app.seed_hr_claim_accounts(d.id);
  end loop;
end $$;

alter function app.seed_chart_of_accounts(uuid) rename to seed_chart_of_accounts_0094;

create or replace function app.seed_chart_of_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
begin
  return app.seed_chart_of_accounts_0094(p_dealer_id) + app.seed_hr_claim_accounts(p_dealer_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. The connection's maps
-- -----------------------------------------------------------------------------
create table public.hr_links (
  dealer_id            uuid primary key references public.dealers (id) on delete cascade,
  workspace_slug       text,
  workspace_name       text,
  last_claims_sync_at  timestamptz,
  last_people_sync_at  timestamptz,
  last_error           text,
  updated_at           timestamptz not null default now()
);

comment on table public.hr_links is 'Which HR app workspace this dealer is connected to, and when it last synced.';

create table public.hr_branch_map (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null references public.dealers (id) on delete cascade,
  hr_branch_id   text not null,
  hr_branch_name text not null,
  branch_id      uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,

  constraint hr_branch_map_key unique (dealer_id, hr_branch_id),
  constraint hr_branch_map_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id)
);

create table public.hr_claim_heads (
  id          uuid primary key default gen_random_uuid(),
  dealer_id   uuid not null references public.dealers (id) on delete cascade,
  claim_type  text not null,
  label       text not null,
  account_id  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,

  constraint hr_claim_heads_key unique (dealer_id, claim_type),
  constraint hr_claim_heads_account_tenant_fkey
    foreign key (account_id, dealer_id) references public.chart_of_accounts (id, dealer_id)
);

comment on table public.hr_claim_heads is
  'The account each HR claim type is booked to. Unmapped types wait; nothing is guessed.';

create table public.hr_inbound_events (
  id          uuid primary key default gen_random_uuid(),
  dealer_id   uuid not null references public.dealers (id) on delete cascade,
  event_id    text not null,
  event_type  text not null,
  received_at timestamptz not null default now(),
  outcome     text not null,
  error       text,

  constraint hr_inbound_events_key unique (dealer_id, event_id)
);

comment on table public.hr_inbound_events is 'Every webhook from the HR app, once each — a replay is recognised here.';

-- -----------------------------------------------------------------------------
-- 3. Employee claims
-- -----------------------------------------------------------------------------
create table public.employee_claims (
  id                  uuid primary key default gen_random_uuid(),
  dealer_id           uuid not null references public.dealers (id) on delete restrict,
  hr_claim_id         text not null,
  claim_no            integer,
  hr_voucher_no       integer,
  employee_id         uuid not null,
  -- Kept on the claim so the cashier, who does not read the employee master, sees who is paid.
  employee_name       text not null,
  employee_code       text,
  branch_id           uuid,
  hr_branch_id        text not null,
  claim_type          text not null,
  type_label          text not null,
  title               text not null,
  description         text,
  amount              numeric(18, 2) not null,
  approved_at         timestamptz,
  approved_by         text,
  has_photo           boolean not null default false,
  has_document        boolean not null default false,
  hr_status           text not null,
  status              text not null,
  accrual_journal_id  uuid,
  reversal_journal_id uuid,
  payment_journal_id  uuid,
  cash_transaction_id bigint,
  bank_transaction_id bigint,
  paid_at             timestamptz,
  paid_by             uuid,
  payment_ref         text,
  callback_status     text not null default 'NONE',
  callback_attempts   integer not null default 0,
  callback_error      text,
  review_note         text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  constraint employee_claims_hr_key unique (dealer_id, hr_claim_id),
  constraint employee_claims_id_dealer_key unique (id, dealer_id),
  constraint employee_claims_employee_tenant_fkey
    foreign key (employee_id, dealer_id) references public.employees (id, dealer_id),
  constraint employee_claims_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint employee_claims_status_check
    check (status in ('AWAITING_MAPPING', 'APPROVED', 'PAID', 'CANCELLED', 'NEEDS_REVIEW')),
  constraint employee_claims_callback_check check (callback_status in ('NONE', 'PENDING', 'SENT', 'FAILED')),
  constraint employee_claims_amount_check check (amount > 0)
);

comment on table public.employee_claims is
  'Claims approved in the HR app: booked to their expense head, paid from the cash or bank book, '
  'and reported back to the HR app as paid.';

create index employee_claims_status_idx on public.employee_claims (dealer_id, status);
create index employee_claims_callback_idx on public.employee_claims (dealer_id, callback_status)
  where callback_status in ('PENDING', 'FAILED');

create trigger employee_claims_set_updated_at before update on public.employee_claims
  for each row execute function app.set_updated_at();
create trigger employee_claims_audit after insert or update or delete on public.employee_claims
  for each row execute function app.audit_trigger();
create trigger hr_claim_heads_audit after insert or update or delete on public.hr_claim_heads
  for each row execute function app.audit_trigger();
create trigger hr_branch_map_audit after insert or update or delete on public.hr_branch_map
  for each row execute function app.audit_trigger();

-- Payroll runs brought in from the HR app are marked, one per branch and month.
alter table public.payroll_runs add column source text not null default 'ERP',
  add constraint payroll_runs_source_check check (source in ('ERP', 'HR'));

-- -----------------------------------------------------------------------------
-- 4. Row-level security
-- -----------------------------------------------------------------------------
alter table public.hr_links          enable row level security;
alter table public.hr_branch_map     enable row level security;
alter table public.hr_claim_heads    enable row level security;
alter table public.hr_inbound_events enable row level security;
alter table public.employee_claims   enable row level security;

create policy hr_links_select on public.hr_links for select to authenticated
  using (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy hr_branch_map_select on public.hr_branch_map for select to authenticated
  using (app.is_platform_admin() or dealer_id = app.current_dealer_id());
create policy hr_branch_map_update on public.hr_branch_map for update to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('hr.mapping.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('hr.mapping.manage')));

create policy hr_claim_heads_select on public.hr_claim_heads for select to authenticated
  using (app.is_platform_admin() or dealer_id = app.current_dealer_id());
create policy hr_claim_heads_update on public.hr_claim_heads for update to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('hr.mapping.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('hr.mapping.manage')));

create policy hr_inbound_events_select on public.hr_inbound_events for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('hr.mapping.manage')));

create policy employee_claims_select on public.employee_claims for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('hr.claims.view')
             and (branch_id is null or app.can_access_branch(branch_id))));
create policy employee_claims_update on public.employee_claims for update to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('hr.claims.pay') or app.has_permission('hr.mapping.manage'))))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('hr.claims.pay') or app.has_permission('hr.mapping.manage'))));

-- -----------------------------------------------------------------------------
-- 5. Who may post an employee-claim entry
-- -----------------------------------------------------------------------------
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
    when 'CASH_BOOK'          then array['cashbook.receipts.create', 'cashbook.payments.create', 'hr.claims.pay']
    when 'BANK_BOOK'          then array['bank.book.record', 'cashbook.receipts.create', 'cashbook.payments.create', 'hr.claims.pay']
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
    when 'EMPLOYEE_CLAIM'     then array['hr.mapping.manage', 'accounting.journals.post']
    when 'MANUAL_JOURNAL'     then array['accounting.journals.post', 'accounting.journals.approve']
    when 'OPENING_BALANCE'    then array['accounting.journals.post']
    else array['accounting.journals.post']
  end;
$$;

-- -----------------------------------------------------------------------------
-- 6. People
-- -----------------------------------------------------------------------------
-- Creates or updates the ERP employee behind an HR app employee, matched on
-- the HR id (external_ref). An ERP employee with the same code and no link yet
-- is linked rather than duplicated. Returns the ERP employee id, or null when
-- the person's branch is not mapped yet.
create or replace function app.upsert_hr_employee(p_dealer_id uuid, p jsonb)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id     uuid;
  v_branch uuid;
  v_status text := case upper(coalesce(p ->> 'status', 'ACTIVE'))
                     when 'ACTIVE' then 'ACTIVE' when 'ON_LEAVE' then 'ON_LEAVE'
                     when 'TERMINATED' then 'TERMINATED' else 'RESIGNED' end;
begin
  -- The webhook calls this with no user. A signed-in caller (importing payroll)
  -- may only touch their own dealer.
  if auth.uid() is not null and not app.is_platform_admin()
     and (p_dealer_id is distinct from app.current_dealer_id()
          or not (app.has_permission('hr.payroll.run') or app.has_permission('hr.mapping.manage'))) then
    raise exception 'You may not change employees from the HR app.' using errcode = 'insufficient_privilege';
  end if;
  insert into public.hr_branch_map (dealer_id, hr_branch_id, hr_branch_name)
  values (p_dealer_id, p ->> 'branchId', coalesce(p ->> 'branchName', p ->> 'branchId'))
  on conflict (dealer_id, hr_branch_id) do update set hr_branch_name = excluded.hr_branch_name;
  select branch_id into v_branch from public.hr_branch_map
   where dealer_id = p_dealer_id and hr_branch_id = p ->> 'branchId';

  select id into v_id from public.employees where dealer_id = p_dealer_id and external_ref = p ->> 'id';
  if v_id is null then
    select id into v_id from public.employees
     where dealer_id = p_dealer_id and employee_code = p ->> 'code' and external_ref is null;
  end if;

  if v_id is not null then
    update public.employees
       set external_ref = p ->> 'id',
           name = coalesce(nullif(btrim(p ->> 'name'), ''), name),
           mobile = coalesce(nullif(p ->> 'mobile', ''), mobile),
           email = coalesce(nullif(p ->> 'email', ''), email),
           department = coalesce(p ->> 'department', department),
           designation = coalesce(p ->> 'designation', designation),
           branch_id = coalesce(v_branch, branch_id),
           status = v_status
     where id = v_id;
    return v_id;
  end if;

  if v_branch is null then
    return null;   -- waits for its branch to be mapped
  end if;

  insert into public.employees
    (dealer_id, branch_id, employee_code, name, department, designation, mobile, email, joining_date, status, external_ref)
  values
    (p_dealer_id, v_branch, p ->> 'code', coalesce(nullif(btrim(p ->> 'name'), ''), p ->> 'code'),
     p ->> 'department', p ->> 'designation', nullif(p ->> 'mobile', ''), nullif(p ->> 'email', ''),
     nullif(p ->> 'joiningDate', '')::date, v_status, p ->> 'id')
  on conflict on constraint employees_dealer_code_key do update
    set external_ref = excluded.external_ref, name = excluded.name
  returning id into v_id;
  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Claims
-- -----------------------------------------------------------------------------
-- Book an approved claim: Dr the claim type's account, Cr 2770 for the
-- employee, at the employee's branch. Returns true when it posted.
create or replace function app.book_employee_claim(p_claim_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c         public.employee_claims;
  v_account uuid;
  v_branch  uuid;
  v_entry   uuid;
  v_date    date;
begin
  select * into c from public.employee_claims where id = p_claim_id for update;
  if c.id is null or c.status <> 'AWAITING_MAPPING' then
    return false;
  end if;
  if auth.uid() is not null and not app.is_platform_admin() and c.dealer_id is distinct from app.current_dealer_id() then
    raise exception 'That claim belongs to another dealer.' using errcode = 'insufficient_privilege';
  end if;
  select account_id into v_account from public.hr_claim_heads
   where dealer_id = c.dealer_id and claim_type = c.claim_type;
  v_branch := coalesce(c.branch_id,
                       (select branch_id from public.hr_branch_map where dealer_id = c.dealer_id and hr_branch_id = c.hr_branch_id));
  if v_account is null or v_branch is null then
    update public.employee_claims set branch_id = v_branch where id = p_claim_id and branch_id is distinct from v_branch;
    return false;
  end if;

  -- Dated the day it was approved, or the first open day after locked books.
  v_date := greatest(coalesce((c.approved_at at time zone 'Asia/Kolkata')::date, current_date),
                     coalesce(app.books_locked_through(c.dealer_id) + 1, '-infinity'::date));
  v_entry := app.post_journal(
    c.dealer_id, v_branch, v_date, 'EXPENSE',
    'Claim ' || coalesce(lpad(c.claim_no::text, 3, '0'), c.hr_claim_id) || ' — ' || c.title,
    jsonb_build_array(
      jsonb_build_object('account_id', v_account, 'debit', c.amount, 'credit', 0,
                         'narration', c.type_label || ': ' || c.title),
      jsonb_build_object('account_id', app.require_account(c.dealer_id, 'EXPENSE', 'CLAIM', 'CLAIMS_PAYABLE', v_branch),
                         'debit', 0, 'credit', c.amount, 'narration', 'Claim payable — ' || c.title,
                         'party_type', 'EMPLOYEE', 'party_id', c.employee_id)),
    'EMPLOYEE_CLAIM', c.id, 'hr-claim:' || c.id::text || ':' || coalesce(c.reversal_journal_id::text, 'first'));

  update public.employee_claims
     set status = 'APPROVED', accrual_journal_id = v_entry, branch_id = v_branch
   where id = p_claim_id;
  return true;
end;
$$;

-- An approved claim from the HR app. Idempotent on the HR claim id.
create or replace function app.receive_hr_claim(p_dealer_id uuid, p jsonb)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_employee uuid;
  v_claim    public.employee_claims;
  v_type     text := coalesce(p ->> 'type', 'OTHER');
begin
  if upper(p ->> 'status') not in ('APPROVED', 'PAID') then
    return app.hr_claim_changed(p_dealer_id, p);
  end if;

  v_employee := app.upsert_hr_employee(p_dealer_id, p -> 'employee');
  if v_employee is null then
    return 'WAITING_FOR_BRANCH';
  end if;

  insert into public.hr_claim_heads (dealer_id, claim_type, label)
  values (p_dealer_id, v_type, coalesce(p ->> 'typeLabel', v_type))
  on conflict (dealer_id, claim_type) do nothing;

  select * into v_claim from public.employee_claims where dealer_id = p_dealer_id and hr_claim_id = p ->> 'id' for update;

  if v_claim.id is null and upper(p ->> 'status') = 'PAID' then
    -- Paid at the HR counter before the ERP was connected: not ours to pay.
    return 'SKIPPED_PAID_IN_HR';
  end if;

  if v_claim.id is null then
    insert into public.employee_claims
      (dealer_id, hr_claim_id, claim_no, hr_voucher_no, employee_id, employee_name, employee_code, hr_branch_id, claim_type, type_label,
       title, description, amount, approved_at, approved_by, has_photo, has_document, hr_status, status)
    values
      (p_dealer_id, p ->> 'id', nullif(p ->> 'claimNo', '')::int, nullif(p ->> 'voucherNo', '')::int, v_employee,
       coalesce(p -> 'employee' ->> 'name', ''), p -> 'employee' ->> 'code',
       p -> 'employee' ->> 'branchId', v_type, coalesce(p ->> 'typeLabel', v_type), coalesce(p ->> 'title', 'Claim'),
       p ->> 'description', round((p ->> 'amount')::numeric, 2), nullif(p ->> 'decidedAt', '')::timestamptz,
       p ->> 'decidedBy', coalesce((p ->> 'hasPhoto')::boolean, false), coalesce((p ->> 'hasDocument')::boolean, false),
       upper(p ->> 'status'), 'AWAITING_MAPPING')
    returning * into v_claim;
  elsif v_claim.status = 'CANCELLED' then
    -- Approved again after being taken back: book it afresh.
    update public.employee_claims
       set status = 'AWAITING_MAPPING', hr_status = upper(p ->> 'status'),
           amount = round((p ->> 'amount')::numeric, 2), approved_at = nullif(p ->> 'decidedAt', '')::timestamptz
     where id = v_claim.id;
  else
    update public.employee_claims set hr_status = upper(p ->> 'status') where id = v_claim.id;
    return v_claim.status;
  end if;

  perform app.book_employee_claim(v_claim.id);
  return (select status from public.employee_claims where id = v_claim.id);
end;
$$;

-- An approval taken back in the HR app.
create or replace function app.hr_claim_changed(p_dealer_id uuid, p jsonb)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c       public.employee_claims;
  v_entry uuid;
begin
  select * into c from public.employee_claims where dealer_id = p_dealer_id and hr_claim_id = p ->> 'id' for update;
  if c.id is null then
    return 'IGNORED';
  end if;
  update public.employee_claims set hr_status = upper(p ->> 'status') where id = c.id;

  if c.status = 'AWAITING_MAPPING' then
    update public.employee_claims set status = 'CANCELLED' where id = c.id;
    return 'CANCELLED';
  elsif c.status = 'APPROVED' then
    v_entry := app.reverse_journal(c.accrual_journal_id,
                                   'Claim ' || coalesce(p ->> 'status', 'withdrawn') || ' in the HR app'
                                   || coalesce(': ' || nullif(p ->> 'note', ''), ''),
                                   current_date);
    update public.employee_claims
       set status = 'CANCELLED', reversal_journal_id = v_entry, accrual_journal_id = null
     where id = c.id;
    return 'CANCELLED';
  elsif c.status = 'PAID' then
    update public.employee_claims
       set status = 'NEEDS_REVIEW',
           review_note = 'Paid here, then ' || lower(coalesce(p ->> 'status', 'changed')) || ' in the HR app'
                         || coalesce(': ' || nullif(p ->> 'note', ''), '')
     where id = c.id;
    return 'NEEDS_REVIEW';
  end if;
  return c.status;
end;
$$;

-- A webhook, once: records it and routes it. Returns the outcome.
create or replace function public.hr_receive_event(p_dealer_id uuid, p_event_id text, p_type text, p_data jsonb)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_outcome text;
begin
  if exists (select 1 from public.hr_inbound_events where dealer_id = p_dealer_id and event_id = p_event_id) then
    return 'DUPLICATE';
  end if;
  v_outcome := case p_type
    when 'claim.approved' then app.receive_hr_claim(p_dealer_id, p_data)
    when 'claim.changed'  then app.receive_hr_claim(p_dealer_id, p_data)
    when 'ping'           then 'PONG'
    else 'IGNORED'
  end;
  insert into public.hr_inbound_events (dealer_id, event_id, event_type, outcome)
  values (p_dealer_id, p_event_id, p_type, v_outcome);
  return v_outcome;
end;
$$;

-- The pull: the same, for a batch of claims and people read from the HR app.
create or replace function public.hr_sync_batch(p_dealer_id uuid, p_claims jsonb, p_employees jsonb, p_workspace jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row      jsonb;
  v_people   integer := 0;
  v_claims   integer := 0;
begin
  for v_row in select * from jsonb_array_elements(coalesce(p_employees, '[]'::jsonb)) loop
    perform app.upsert_hr_employee(p_dealer_id, v_row);
    v_people := v_people + 1;
  end loop;
  for v_row in select * from jsonb_array_elements(coalesce(p_claims, '[]'::jsonb)) loop
    perform app.receive_hr_claim(p_dealer_id, v_row);
    v_claims := v_claims + 1;
  end loop;

  insert into public.hr_links (dealer_id, workspace_slug, workspace_name, last_claims_sync_at, last_people_sync_at, last_error)
  values (p_dealer_id, p_workspace ->> 'slug', p_workspace ->> 'name', now(),
          case when p_employees is not null then now() end, null)
  on conflict (dealer_id) do update
    set workspace_slug = coalesce(excluded.workspace_slug, hr_links.workspace_slug),
        workspace_name = coalesce(excluded.workspace_name, hr_links.workspace_name),
        last_claims_sync_at = now(),
        last_people_sync_at = coalesce(excluded.last_people_sync_at, hr_links.last_people_sync_at),
        last_error = null, updated_at = now();

  -- Anything waiting whose mapping has arrived since.
  perform app.book_employee_claim(id) from public.employee_claims
   where dealer_id = p_dealer_id and status = 'AWAITING_MAPPING';

  return jsonb_build_object('people', v_people, 'claims', v_claims);
end;
$$;

-- What a failed pull says, for the Integration screen.
create or replace function public.hr_record_sync_error(p_dealer_id uuid, p_error text)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  insert into public.hr_links (dealer_id, last_error) values (p_dealer_id, left(p_error, 500))
  on conflict (dealer_id) do update set last_error = left(p_error, 500), updated_at = now();
$$;

-- The HR app acknowledged (or refused) a payment report.
create or replace function public.hr_mark_callback(p_dealer_id uuid, p_claim_id uuid, p_ok boolean, p_error text default null)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.employee_claims
     set callback_status = case when p_ok then 'SENT' else 'FAILED' end,
         callback_attempts = callback_attempts + 1,
         callback_error = case when p_ok then null else left(p_error, 500) end
   where id = p_claim_id and dealer_id = p_dealer_id;
$$;

-- -----------------------------------------------------------------------------
-- 8. What people do: map, book what waits, pay
-- -----------------------------------------------------------------------------
create or replace function public.map_hr_claim_head(p_claim_type text, p_account_id uuid)
returns integer
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_booked integer := 0;
  c        record;
begin
  if v_dealer is null or not app.has_permission('hr.mapping.manage') then
    raise exception 'You may not map claim types.' using errcode = 'insufficient_privilege';
  end if;
  if p_account_id is not null and not exists (
       select 1 from public.chart_of_accounts
        where id = p_account_id and dealer_id = v_dealer and not is_group and status = 'ACTIVE'
          and account_type in ('EXPENSE', 'ASSET', 'LIABILITY')) then
    raise exception 'Choose an active expense (or advance / payable) ledger, not a group.' using errcode = 'check_violation';
  end if;
  if p_account_id is not null and app.is_money_ledger(v_dealer, p_account_id) then
    raise exception 'A claim is not booked to cash or bank; that happens when it is paid.' using errcode = 'check_violation';
  end if;
  update public.hr_claim_heads set account_id = p_account_id, updated_at = now(), updated_by = auth.uid()
   where dealer_id = v_dealer and claim_type = p_claim_type;
  if not found then
    raise exception 'Unknown claim type %.', p_claim_type using errcode = 'no_data_found';
  end if;
  for c in select id from public.employee_claims where dealer_id = v_dealer and status = 'AWAITING_MAPPING' loop
    if app.book_employee_claim(c.id) then v_booked := v_booked + 1; end if;
  end loop;
  return v_booked;
end;
$$;

create or replace function public.map_hr_branch(p_hr_branch_id text, p_branch_id uuid)
returns integer
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_booked integer := 0;
  c        record;
begin
  if v_dealer is null or not app.has_permission('hr.mapping.manage') then
    raise exception 'You may not map branches.' using errcode = 'insufficient_privilege';
  end if;
  if p_branch_id is not null and not exists (select 1 from public.branches where id = p_branch_id and dealer_id = v_dealer) then
    raise exception 'That branch does not belong to this dealer.' using errcode = 'insufficient_privilege';
  end if;
  update public.hr_branch_map set branch_id = p_branch_id, updated_at = now(), updated_by = auth.uid()
   where dealer_id = v_dealer and hr_branch_id = p_hr_branch_id;
  if not found then
    raise exception 'Unknown HR branch.' using errcode = 'no_data_found';
  end if;
  for c in select id from public.employee_claims where dealer_id = v_dealer and status = 'AWAITING_MAPPING' loop
    if app.book_employee_claim(c.id) then v_booked := v_booked + 1; end if;
  end loop;
  return v_booked;
end;
$$;

-- Pay approved claims from the cash book (branch) or a bank account: one
-- voucher, one line per claim, Dr 2770 for the employee. The claims turn PAID
-- and wait for the HR app to be told.
create or replace function public.pay_employee_claims(
  p_claim_ids       uuid[],
  p_book            text,
  p_branch_id       uuid default null,
  p_bank_account_id uuid default null,
  p_date            date default current_date,
  p_reference       text default null,
  p_idempotency_key text default null
)
returns table (transaction_id bigint, journal_entry_id uuid, balance_after numeric)
language plpgsql
as $$
declare
  v_dealer  uuid := app.current_dealer_id();
  v_lines   jsonb := '[]'::jsonb;
  v_count   integer;
  v_bad     integer;
  v_names   text;
  v_result  record;
  c         record;
begin
  if v_dealer is null or not app.has_permission('hr.claims.pay') then
    raise exception 'You may not pay employee claims.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(array_length(p_claim_ids, 1), 0) = 0 then
    raise exception 'Choose the claims to pay.' using errcode = 'check_violation';
  end if;

  -- A replay returns the first payment.
  if p_idempotency_key is not null then
    select t.id, t.journal_entry_id, t.balance_after into v_result
      from public.cash_transactions t where t.dealer_id = v_dealer and t.idempotency_key = p_idempotency_key;
    if v_result.id is null then
      select t.id, t.journal_entry_id, t.balance_after into v_result
        from public.bank_transactions t where t.dealer_id = v_dealer and t.idempotency_key = p_idempotency_key;
    end if;
    if v_result.id is not null then
      transaction_id := v_result.id; journal_entry_id := v_result.journal_entry_id; balance_after := v_result.balance_after;
      return next;
      return;
    end if;
  end if;

  perform 1 from public.employee_claims where dealer_id = v_dealer and id = any (p_claim_ids) for update;
  select count(*), count(*) filter (where ec.status <> 'APPROVED'),
         string_agg(distinct ec.employee_name, ', ')
    into v_count, v_bad, v_names
    from public.employee_claims ec
   where ec.dealer_id = v_dealer and ec.id = any (p_claim_ids);
  if v_count <> array_length(p_claim_ids, 1) then
    raise exception 'A chosen claim was not found.' using errcode = 'no_data_found';
  end if;
  if v_bad > 0 then
    raise exception 'Only approved, unpaid claims can be paid — refresh the list.' using errcode = 'check_violation';
  end if;

  for c in
    select ec.* from public.employee_claims ec
     where ec.dealer_id = v_dealer and ec.id = any (p_claim_ids) order by ec.claim_no
  loop
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', app.require_account(v_dealer, 'EXPENSE', 'CLAIM', 'CLAIMS_PAYABLE', c.branch_id),
      'amount', c.amount,
      'narration', 'Claim ' || coalesce(lpad(c.claim_no::text, 3, '0'), '') || ' ' || c.title || ' — ' || c.employee_name,
      'party_type', 'EMPLOYEE', 'party_id', c.employee_id));
  end loop;

  select * into v_result from public.record_money_voucher(
    p_book, 'PAYMENT', v_lines, 'Employee claims paid — ' || v_names,
    p_branch_id, p_bank_account_id, coalesce(p_date, current_date), p_reference, null, null, p_idempotency_key);

  update public.employee_claims
     set status = 'PAID', paid_at = now(), paid_by = auth.uid(),
         payment_journal_id = v_result.journal_entry_id,
         cash_transaction_id = case when p_book = 'CASH' then v_result.transaction_id end,
         bank_transaction_id = case when p_book = 'BANK' then v_result.transaction_id end,
         payment_ref = coalesce(nullif(btrim(p_reference), ''),
                                (select entry_number from public.journal_entries where id = v_result.journal_entry_id)),
         callback_status = 'PENDING'
   where dealer_id = v_dealer and id = any (p_claim_ids);

  transaction_id := v_result.transaction_id; journal_entry_id := v_result.journal_entry_id;
  balance_after := v_result.balance_after;
  return next;
end;
$$;

-- An accountant clears a claim flagged for review, with a reason.
create or replace function public.resolve_employee_claim_review(p_claim_id uuid, p_note text)
returns void
language plpgsql
as $$
begin
  if not app.has_permission('hr.mapping.manage') then
    raise exception 'You may not resolve claim reviews.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(length(btrim(p_note)), 0) < 5 then
    raise exception 'Say what was done about it.' using errcode = 'check_violation';
  end if;
  update public.employee_claims
     set status = 'PAID', review_note = review_note || ' — resolved: ' || btrim(p_note)
   where id = p_claim_id and dealer_id = app.current_dealer_id() and status = 'NEEDS_REVIEW';
  if not found then
    raise exception 'That claim is not waiting for review.' using errcode = 'no_data_found';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- 9. Payroll from the HR app
-- -----------------------------------------------------------------------------
-- p_lines: the HR app's payslips for one month:
-- [{"employee": {...}, "gross": 20000, "pf": 1800, "esi": 150, "professionalTax": 200, "tds": 0, "other": 0}]
-- Creates one DRAFT payroll run per branch, marked source HR; the owner reviews,
-- then posts and pays it through post_payroll_run / pay_payroll_run as usual.
create or replace function public.import_hr_payroll(p_period date, p_lines jsonb)
returns integer
language plpgsql
as $$
declare
  v_dealer  uuid := app.current_dealer_id();
  v_period  date := date_trunc('month', p_period)::date;
  v_line    jsonb;
  v_emp     uuid;
  v_branch  uuid;
  v_run     uuid;
  v_runs    integer := 0;
begin
  if v_dealer is null or not app.has_permission('hr.payroll.run') then
    raise exception 'You may not import payroll.' using errcode = 'insufficient_privilege';
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'The HR app has no finalised payslips for that month.' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.payroll_runs where dealer_id = v_dealer and period = v_period and source = 'HR' and status <> 'DRAFT') then
    raise exception 'Payroll for % from the HR app is already posted.', to_char(v_period, 'Mon YYYY') using errcode = 'check_violation';
  end if;
  -- A fresh import replaces an earlier unposted one for the month.
  delete from public.payroll_runs where dealer_id = v_dealer and period = v_period and source = 'HR' and status = 'DRAFT';

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_emp := app.upsert_hr_employee(v_dealer, v_line -> 'employee');
    if v_emp is null then
      raise exception 'Map the HR branch "%" to a branch here before importing payroll.', v_line -> 'employee' ->> 'branchName'
        using errcode = 'check_violation';
    end if;
    select branch_id into v_branch from public.employees where id = v_emp;

    select id into v_run from public.payroll_runs where dealer_id = v_dealer and branch_id = v_branch and period = v_period;
    if v_run is null then
      insert into public.payroll_runs (dealer_id, branch_id, period, source, created_by)
      values (v_dealer, v_branch, v_period, 'HR', auth.uid())
      returning id into v_run;
      v_runs := v_runs + 1;
    elsif (select source from public.payroll_runs where id = v_run) <> 'HR' then
      raise exception 'A payroll for % at this branch was already prepared in the ERP.', to_char(v_period, 'Mon YYYY')
        using errcode = 'check_violation';
    end if;

    insert into public.payroll_lines
      (run_id, dealer_id, employee_id, gross, pf_employee, esi_employee, professional_tax, tds, other_deduction)
    values
      (v_run, v_dealer, v_emp, round((v_line ->> 'gross')::numeric, 2),
       round(coalesce((v_line ->> 'pf')::numeric, 0), 2), round(coalesce((v_line ->> 'esi')::numeric, 0), 2),
       round(coalesce((v_line ->> 'professionalTax')::numeric, 0), 2), round(coalesce((v_line ->> 'tds')::numeric, 0), 2),
       round(coalesce((v_line ->> 'other')::numeric, 0), 2));
  end loop;
  return v_runs;
end;
$$;

-- -----------------------------------------------------------------------------
-- 10. Grants
-- -----------------------------------------------------------------------------
revoke all on function app.upsert_hr_employee(uuid, jsonb) from public;
revoke all on function app.book_employee_claim(uuid) from public;
revoke all on function app.receive_hr_claim(uuid, jsonb) from public;
revoke all on function app.hr_claim_changed(uuid, jsonb) from public;
revoke all on function public.hr_receive_event(uuid, text, text, jsonb) from public;
revoke all on function public.hr_sync_batch(uuid, jsonb, jsonb, jsonb) from public;
revoke all on function public.hr_record_sync_error(uuid, text) from public;
revoke all on function public.hr_mark_callback(uuid, uuid, boolean, text) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select on public.hr_links, public.hr_branch_map, public.hr_claim_heads, public.hr_inbound_events to authenticated';
    execute 'grant select, update on public.employee_claims to authenticated';
    execute 'grant update on public.hr_branch_map, public.hr_claim_heads to authenticated';
    execute 'grant execute on function public.map_hr_claim_head(text, uuid) to authenticated';
    execute 'grant execute on function public.map_hr_branch(text, uuid) to authenticated';
    execute 'grant execute on function public.pay_employee_claims(uuid[], text, uuid, uuid, date, text, text) to authenticated';
    execute 'grant execute on function public.resolve_employee_claim_review(uuid, text) to authenticated';
    execute 'grant execute on function public.import_hr_payroll(date, jsonb) to authenticated';
    -- Called inside map_hr_* and pay, as the signed-in user.
    execute 'grant execute on function app.book_employee_claim(uuid) to authenticated';
    execute 'grant execute on function app.upsert_hr_employee(uuid, jsonb) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant all on public.hr_links, public.hr_branch_map, public.hr_claim_heads, public.hr_inbound_events, public.employee_claims to service_role';
    execute 'grant execute on function public.hr_receive_event(uuid, text, text, jsonb) to service_role';
    execute 'grant execute on function public.hr_sync_batch(uuid, jsonb, jsonb, jsonb) to service_role';
    execute 'grant execute on function public.hr_record_sync_error(uuid, text) to service_role';
    execute 'grant execute on function public.hr_mark_callback(uuid, uuid, boolean, text) to service_role';
    execute 'grant execute on function app.receive_hr_claim(uuid, jsonb) to service_role';
    execute 'grant execute on function app.hr_claim_changed(uuid, jsonb) to service_role';
    execute 'grant execute on function app.book_employee_claim(uuid) to service_role';
    execute 'grant execute on function app.upsert_hr_employee(uuid, jsonb) to service_role';
  end if;
end $$;

insert into public.schema_migrations (version, name)
values ('0095', 'hr_integration') on conflict (version) do nothing;


commit;
