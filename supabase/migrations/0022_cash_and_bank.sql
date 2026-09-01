-- =============================================================================
-- 0022 — Cash book, day closing, bank accounts and reconciliation
-- =============================================================================
-- Spec §36, §37, §38, §39, §60.14, §60.15.
--
-- The daily cash book is mandatory and so is the daily close. Once a day is
-- CLOSED its transactions are frozen — spec §36: "After close: no direct edits.
-- Only reversal/adjustment with permission." That is enforced by a trigger here,
-- not by a UI that hides the edit button.
--
-- Rollback: drop table public.bank_reconciliations, public.bank_statement_lines,
--           public.bank_transactions, public.bank_accounts,
--           public.cash_day_closings, public.cash_transactions, public.cash_accounts;
-- =============================================================================

create table public.cash_accounts (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null references public.dealers (id) on delete cascade,
  branch_id         uuid not null,

  name              text not null,
  ledger_account_id uuid not null,
  opening_balance   numeric(18, 4) not null default 0,
  current_balance   numeric(18, 4) not null default 0,

  status            text not null default 'ACTIVE',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  -- One cash account per branch (spec §36: "Each branch has a cash account").
  constraint cash_accounts_branch_key unique (branch_id),
  constraint cash_accounts_id_dealer_key unique (id, dealer_id),
  constraint cash_accounts_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id) on delete cascade,
  constraint cash_accounts_ledger_tenant_fkey
    foreign key (ledger_account_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint cash_accounts_status_check check (status in ('ACTIVE', 'INACTIVE'))
);

-- -----------------------------------------------------------------------------
-- cash_day_closings — spec §36
-- -----------------------------------------------------------------------------
create table public.cash_day_closings (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null,
  branch_id         uuid not null,
  cash_account_id   uuid not null,

  business_date     date not null,
  status            text not null default 'OPEN',

  opening_balance   numeric(18, 4) not null default 0,
  total_receipts    numeric(18, 4) not null default 0,
  total_payments    numeric(18, 4) not null default 0,
  expected_closing  numeric(18, 4) generated always as (
    opening_balance + total_receipts - total_payments
  ) stored,

  physical_cash     numeric(18, 4),
  -- The number that matters at close: counted minus expected.
  difference        numeric(18, 4),

  denominations     jsonb,
  counted_at        timestamptz,
  counted_by        uuid,
  closed_at         timestamptz,
  closed_by         uuid,
  reopened_at       timestamptz,
  reopened_by       uuid,
  reopen_reason     text,
  remarks           text,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint cdc_branch_date_key unique (branch_id, business_date),
  constraint cdc_id_dealer_key   unique (id, dealer_id),
  constraint cdc_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint cdc_account_tenant_fkey
    foreign key (cash_account_id, dealer_id) references public.cash_accounts (id, dealer_id),
  constraint cdc_status_check check (status in ('OPEN', 'IN_PROGRESS', 'COUNTED', 'CLOSED')),
  constraint cdc_counted_check check (status <> 'COUNTED' or physical_cash is not null),
  constraint cdc_closed_check  check (status <> 'CLOSED' or (physical_cash is not null and closed_at is not null)),
  constraint cdc_reopen_check  check (reopened_at is null or reopen_reason is not null)
);

comment on table public.cash_day_closings is
  'Mandatory daily cash close (spec §36, §60.15). OPEN → IN_PROGRESS → COUNTED → CLOSED.';

create index cdc_branch_date_idx on public.cash_day_closings (branch_id, business_date desc);
create index cdc_open_idx        on public.cash_day_closings (dealer_id) where status <> 'CLOSED';

create table public.cash_transactions (
  id               bigint generated always as identity primary key,
  dealer_id        uuid not null,
  branch_id        uuid not null,
  cash_account_id  uuid not null,

  business_date    date not null default current_date,
  transaction_time timestamptz not null default now(),

  direction        text not null,
  amount           numeric(18, 4) not null,
  balance_after    numeric(18, 4) not null default 0,

  particular       text not null,
  reference_type   text,
  reference_id     uuid,
  reference_number text,

  customer_id      uuid,
  journal_entry_id uuid,
  status           text not null default 'ACTIVE',

  created_at       timestamptz not null default now(),
  created_by       uuid,

  constraint ct_account_tenant_fkey
    foreign key (cash_account_id, dealer_id) references public.cash_accounts (id, dealer_id),
  constraint ct_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint ct_customer_tenant_fkey
    foreign key (customer_id, dealer_id) references public.customers (id, dealer_id),
  constraint ct_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint ct_direction_check check (direction in ('RECEIPT', 'PAYMENT')),
  constraint ct_amount_check    check (amount > 0),
  constraint ct_status_check    check (status in ('ACTIVE', 'REVERSED'))
);

comment on table public.cash_transactions is 'Daily cash book entries (spec §37).';

create index ct_branch_date_idx  on public.cash_transactions (branch_id, business_date desc, transaction_time);
create index ct_account_date_idx on public.cash_transactions (cash_account_id, business_date desc);
create index ct_reference_idx    on public.cash_transactions (reference_type, reference_id) where reference_id is not null;
create index ct_customer_idx     on public.cash_transactions (customer_id) where customer_id is not null;

-- -----------------------------------------------------------------------------
-- A closed day is frozen (spec §36, §60.23)
-- -----------------------------------------------------------------------------
create or replace function app.cash_transactions_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status text;
  v_prev   numeric(18, 4);
  v_row    public.cash_transactions;
begin
  v_row := coalesce(new, old);

  select status into v_status
    from public.cash_day_closings
   where branch_id = v_row.branch_id and business_date = v_row.business_date;

  if v_status = 'CLOSED' then
    raise exception 'The cash book for % is closed and cannot be changed.', v_row.business_date
      using errcode = 'insufficient_privilege',
            hint = 'Spec §36: reopen the day with permission, or post an adjustment.';
  end if;

  if tg_op = 'DELETE' then
    raise exception 'Cash book entries are not deleted; reverse them instead.'
      using errcode = 'insufficient_privilege';
  end if;

  if tg_op = 'INSERT' then
    -- Lock the account so two concurrent receipts cannot read the same balance.
    perform 1 from public.cash_accounts where id = new.cash_account_id for update;

    select coalesce(balance_after, 0) into v_prev
      from public.cash_transactions
     where cash_account_id = new.cash_account_id and status = 'ACTIVE'
     order by id desc limit 1;

    if v_prev is null then
      select opening_balance into v_prev from public.cash_accounts where id = new.cash_account_id;
    end if;

    new.balance_after := coalesce(v_prev, 0)
      + case when new.direction = 'RECEIPT' then new.amount else -new.amount end;
  end if;

  return new;
end;
$$;

create trigger cash_transactions_guard
  before insert or update or delete on public.cash_transactions
  for each row execute function app.cash_transactions_guard();

-- Keep the day sheet and the account balance in step with the entries.
create or replace function app.cash_sync_day()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.cash_transactions := coalesce(new, old);
begin
  update public.cash_day_closings d
     set total_receipts = coalesce((
           select sum(t.amount) from public.cash_transactions t
            where t.branch_id = v_row.branch_id and t.business_date = v_row.business_date
              and t.direction = 'RECEIPT' and t.status = 'ACTIVE'), 0),
         total_payments = coalesce((
           select sum(t.amount) from public.cash_transactions t
            where t.branch_id = v_row.branch_id and t.business_date = v_row.business_date
              and t.direction = 'PAYMENT' and t.status = 'ACTIVE'), 0),
         status = case when d.status = 'OPEN' then 'IN_PROGRESS' else d.status end
   where d.branch_id = v_row.branch_id and d.business_date = v_row.business_date;

  update public.cash_accounts a
     set current_balance = coalesce((
           select t.balance_after from public.cash_transactions t
            where t.cash_account_id = v_row.cash_account_id and t.status = 'ACTIVE'
            order by t.id desc limit 1), a.opening_balance)
   where a.id = v_row.cash_account_id;

  return null;
end;
$$;

create trigger cash_transactions_sync
  after insert or update on public.cash_transactions
  for each row execute function app.cash_sync_day();

-- The difference is computed at close, never typed in.
create or replace function app.cash_day_guard()
returns trigger
language plpgsql
as $$
begin
  if new.physical_cash is not null then
    new.difference := new.physical_cash - new.expected_closing;
  end if;

  if tg_op = 'UPDATE' and old.status = 'CLOSED' and new.status <> 'CLOSED' then
    if new.reopen_reason is null then
      raise exception 'Reopening a closed day requires a reason.'
        using errcode = 'check_violation';
    end if;
    new.reopened_at := now();
  end if;

  return new;
end;
$$;

create trigger cash_day_guard
  before insert or update on public.cash_day_closings
  for each row execute function app.cash_day_guard();

-- =============================================================================
-- Bank — spec §38, §39
-- =============================================================================
create table public.bank_accounts (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null references public.dealers (id) on delete cascade,
  branch_id         uuid,

  name              text not null,
  bank_name         text not null,
  account_number    text not null,
  ifsc              text,
  account_type      text not null default 'CURRENT',

  ledger_account_id uuid not null,
  opening_balance   numeric(18, 4) not null default 0,
  current_balance   numeric(18, 4) not null default 0,

  status            text not null default 'ACTIVE',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint bank_accounts_number_key   unique (dealer_id, account_number),
  constraint bank_accounts_id_dealer_key unique (id, dealer_id),
  constraint bank_accounts_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint bank_accounts_ledger_tenant_fkey
    foreign key (ledger_account_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint bank_accounts_type_check   check (account_type in ('CURRENT', 'SAVINGS', 'OD', 'CC')),
  constraint bank_accounts_status_check check (status in ('ACTIVE', 'INACTIVE', 'CLOSED')),
  constraint bank_accounts_ifsc_check   check (ifsc is null or ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$')
);

create index bank_accounts_dealer_idx on public.bank_accounts (dealer_id, status);
create index bank_accounts_branch_idx on public.bank_accounts (branch_id) where branch_id is not null;

create table public.bank_transactions (
  id                bigint generated always as identity primary key,
  dealer_id         uuid not null,
  bank_account_id   uuid not null,

  transaction_date  date not null default current_date,
  direction         text not null,
  amount            numeric(18, 4) not null,
  balance_after     numeric(18, 4) not null default 0,

  particular        text not null,
  reference_type    text,
  reference_id      uuid,
  reference_number  text,
  utr               text,
  instrument_number text,

  journal_entry_id  uuid,
  -- Reconciliation state (spec §39).
  reconciled        boolean not null default false,
  reconciliation_id uuid,
  status            text not null default 'ACTIVE',

  created_at        timestamptz not null default now(),
  created_by        uuid,

  constraint bt_account_tenant_fkey
    foreign key (bank_account_id, dealer_id) references public.bank_accounts (id, dealer_id),
  constraint bt_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint bt_direction_check check (direction in ('RECEIPT', 'PAYMENT')),
  constraint bt_amount_check    check (amount > 0),
  constraint bt_status_check    check (status in ('ACTIVE', 'REVERSED'))
);

create index bt_account_date_idx on public.bank_transactions (bank_account_id, transaction_date desc);
create index bt_unreconciled_idx on public.bank_transactions (bank_account_id) where not reconciled;
create index bt_utr_idx          on public.bank_transactions (dealer_id, utr) where utr is not null;
create index bt_reference_idx    on public.bank_transactions (reference_type, reference_id) where reference_id is not null;

create or replace function app.bank_transactions_balance()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_prev numeric(18, 4);
begin
  perform 1 from public.bank_accounts where id = new.bank_account_id for update;

  select coalesce(balance_after, 0) into v_prev
    from public.bank_transactions
   where bank_account_id = new.bank_account_id and status = 'ACTIVE'
   order by id desc limit 1;

  if v_prev is null then
    select opening_balance into v_prev from public.bank_accounts where id = new.bank_account_id;
  end if;

  new.balance_after := coalesce(v_prev, 0)
    + case when new.direction = 'RECEIPT' then new.amount else -new.amount end;
  return new;
end;
$$;

create trigger bank_transactions_balance
  before insert on public.bank_transactions
  for each row execute function app.bank_transactions_balance();

create or replace function app.bank_sync_balance()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.bank_accounts a
     set current_balance = coalesce((
           select t.balance_after from public.bank_transactions t
            where t.bank_account_id = a.id and t.status = 'ACTIVE'
            order by t.id desc limit 1), a.opening_balance)
   where a.id = coalesce(new.bank_account_id, old.bank_account_id);
  return null;
end;
$$;

create trigger bank_transactions_sync
  after insert or update on public.bank_transactions
  for each row execute function app.bank_sync_balance();

-- Imported statement lines, staged before matching (spec §39).
create table public.bank_statement_lines (
  id               bigint generated always as identity primary key,
  dealer_id        uuid not null,
  bank_account_id  uuid not null,

  import_batch     uuid not null,
  statement_date   date not null,
  value_date       date,
  narration        text not null,
  reference        text,
  utr              text,
  upi_id           text,
  cheque_number    text,

  debit            numeric(18, 4) not null default 0,
  credit           numeric(18, 4) not null default 0,
  running_balance  numeric(18, 4),

  match_status     text not null default 'UNMATCHED',
  matched_transaction_id bigint,
  reconciliation_id uuid,

  raw_row          jsonb,
  created_at       timestamptz not null default now(),
  created_by       uuid,

  constraint bsl_account_tenant_fkey
    foreign key (bank_account_id, dealer_id) references public.bank_accounts (id, dealer_id),
  constraint bsl_status_check check (match_status in ('UNMATCHED', 'MATCHED', 'PARTIAL', 'IGNORED')),
  constraint bsl_amounts_check check (debit >= 0 and credit >= 0),
  constraint bsl_one_sided_check check ((debit > 0 and credit = 0) or (credit > 0 and debit = 0)),
  -- Spec §39: never mark reconciled without recording the link.
  constraint bsl_matched_link_check check (
    match_status <> 'MATCHED' or matched_transaction_id is not null
  )
);

create index bsl_account_date_idx on public.bank_statement_lines (bank_account_id, statement_date desc);
create index bsl_status_idx       on public.bank_statement_lines (bank_account_id, match_status);
create index bsl_batch_idx        on public.bank_statement_lines (import_batch);
create index bsl_utr_idx          on public.bank_statement_lines (dealer_id, utr) where utr is not null;

-- Duplicate protection on re-import: the same line twice is rejected.
create unique index bsl_dedupe_key
  on public.bank_statement_lines (bank_account_id, statement_date, debit, credit, coalesce(utr, ''), md5(narration));

create table public.bank_reconciliations (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null,
  bank_account_id  uuid not null,

  reconciliation_number text not null,
  from_date        date not null,
  to_date          date not null,
  statement_closing_balance numeric(18, 4) not null default 0,
  book_closing_balance      numeric(18, 4) not null default 0,
  difference       numeric(18, 4) generated always as (
    statement_closing_balance - book_closing_balance
  ) stored,

  matched_count    integer not null default 0,
  unmatched_count  integer not null default 0,

  status           text not null default 'DRAFT',
  completed_at     timestamptz,
  completed_by     uuid,
  notes            text,

  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       uuid,

  constraint br_number_key unique (dealer_id, reconciliation_number),
  constraint br_id_dealer_key unique (id, dealer_id),
  constraint br_account_tenant_fkey
    foreign key (bank_account_id, dealer_id) references public.bank_accounts (id, dealer_id),
  constraint br_status_check check (status in ('DRAFT', 'COMPLETED', 'CANCELLED')),
  constraint br_dates_check  check (to_date >= from_date)
);

create index br_account_idx on public.bank_reconciliations (bank_account_id, to_date desc);

alter table public.bank_statement_lines
  add constraint bsl_reconciliation_fkey
  foreign key (reconciliation_id) references public.bank_reconciliations (id) on delete set null;

alter table public.bank_transactions
  add constraint bt_reconciliation_fkey
  foreign key (reconciliation_id) references public.bank_reconciliations (id) on delete set null;

alter table public.bank_statement_lines
  add constraint bsl_matched_transaction_fkey
  foreign key (matched_transaction_id) references public.bank_transactions (id) on delete set null;

create trigger cash_accounts_set_updated_at before update on public.cash_accounts
  for each row execute function app.set_updated_at();
create trigger cdc_set_updated_at before update on public.cash_day_closings
  for each row execute function app.set_updated_at();
create trigger bank_accounts_set_updated_at before update on public.bank_accounts
  for each row execute function app.set_updated_at();
create trigger br_set_updated_at before update on public.bank_reconciliations
  for each row execute function app.set_updated_at();

create trigger cdc_audit after insert or update or delete on public.cash_day_closings
  for each row execute function app.audit_trigger();
create trigger bank_accounts_audit after insert or update or delete on public.bank_accounts
  for each row execute function app.audit_trigger();
create trigger br_audit after insert or update or delete on public.bank_reconciliations
  for each row execute function app.audit_trigger();

alter table public.cash_accounts        enable row level security;
alter table public.cash_day_closings    enable row level security;
alter table public.cash_transactions    enable row level security;
alter table public.bank_accounts        enable row level security;
alter table public.bank_transactions    enable row level security;
alter table public.bank_statement_lines enable row level security;
alter table public.bank_reconciliations enable row level security;

create policy cash_accounts_select on public.cash_accounts for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('cashbook.view')));
create policy cash_accounts_write on public.cash_accounts for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('admin.settings.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('admin.settings.manage')));

create policy cdc_select on public.cash_day_closings for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('cashbook.view')));
create policy cdc_write on public.cash_day_closings for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('cashbook.day_close') or app.has_permission('cashbook.day_reopen')
              or app.has_permission('cashbook.receipts.create'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy ct_select on public.cash_transactions for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('cashbook.view')));
create policy ct_insert on public.cash_transactions for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('cashbook.receipts.create') or app.has_permission('cashbook.payments.create'))));

create policy bank_accounts_select on public.bank_accounts for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.accounts.view')));
create policy bank_accounts_write on public.bank_accounts for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.accounts.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.accounts.manage')));

create policy bt_select on public.bank_transactions for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.book.view')));
create policy bt_write on public.bank_transactions for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('bank.reconcile') or app.has_permission('cashbook.payments.create'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy bsl_select on public.bank_statement_lines for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.reconcile')));
create policy bsl_write on public.bank_statement_lines for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('bank.statement.import') or app.has_permission('bank.reconcile'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy br_select on public.bank_reconciliations for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.reconcile')));
create policy br_write on public.bank_reconciliations for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.reconcile')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.reconcile')));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.cash_accounts, public.cash_day_closings, public.bank_accounts, public.bank_statement_lines, public.bank_reconciliations, public.bank_transactions to authenticated';
    execute 'grant select, insert on public.cash_transactions to authenticated';
    execute 'grant all on public.cash_accounts, public.cash_day_closings, public.cash_transactions, public.bank_accounts, public.bank_transactions, public.bank_statement_lines, public.bank_reconciliations to service_role';
  end if;
end;
$$;
