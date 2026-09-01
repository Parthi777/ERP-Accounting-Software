-- =============================================================================
-- 0021 — Finance: HP applications, trade advances, settlements
-- =============================================================================
-- Spec §25, §26, §27, §60.
--
-- The rule that shapes this: "Never combine all finance companies into one
-- generic balance." Every transaction carries finance_company_id, and the running
-- balance is per company. `finance_transactions` is the subsidiary ledger that
-- reconciles to the general ledger through the party-tagged journal lines.
--
-- Rollback: drop table public.finance_settlements, public.finance_transactions,
--           public.finance_applications;
-- =============================================================================

create table public.finance_applications (
  id                  uuid primary key default gen_random_uuid(),
  dealer_id           uuid not null references public.dealers (id) on delete restrict,
  branch_id           uuid not null,

  application_number  text not null,
  application_date    date not null default current_date,

  customer_id         uuid not null,
  finance_company_id  uuid not null,
  vehicle_id          uuid,
  sale_id             uuid,

  loan_amount         numeric(18, 4) not null default 0,
  down_payment        numeric(18, 4) not null default 0,
  tenure_months       smallint,
  interest_rate       numeric(6, 3),

  approval_status     text not null default 'PENDING',
  approved_amount     numeric(18, 4),
  approved_at         timestamptz,

  disbursement_status text not null default 'PENDING',
  disbursed_amount    numeric(18, 4) not null default 0,
  disbursed_at        timestamptz,
  dd_number           text,
  bank_reference      text,

  -- Restricted: commission is a sensitive figure (spec §52).
  commission_amount   numeric(18, 4) not null default 0,

  pending_amount      numeric(18, 4) generated always as (
    coalesce(approved_amount, loan_amount) - disbursed_amount
  ) stored,

  rejection_reason    text,
  notes               text,

  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid,
  updated_by          uuid,

  constraint fa_number_key    unique (dealer_id, application_number),
  constraint fa_id_dealer_key unique (id, dealer_id),
  constraint fa_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint fa_customer_tenant_fkey
    foreign key (customer_id, dealer_id) references public.customers (id, dealer_id),
  constraint fa_company_tenant_fkey
    foreign key (finance_company_id, dealer_id) references public.finance_companies (id, dealer_id),
  constraint fa_vehicle_tenant_fkey
    foreign key (vehicle_id, dealer_id) references public.vehicles (id, dealer_id),
  constraint fa_sale_tenant_fkey
    foreign key (sale_id, dealer_id) references public.sales (id, dealer_id),
  constraint fa_approval_check     check (approval_status in ('PENDING', 'APPROVED', 'REJECTED', 'CANCELLED')),
  constraint fa_disbursement_check check (disbursement_status in ('PENDING', 'PARTIAL', 'DISBURSED', 'CANCELLED')),
  constraint fa_amounts_check      check (
    loan_amount >= 0 and down_payment >= 0 and disbursed_amount >= 0 and commission_amount >= 0
    and (approved_amount is null or approved_amount >= 0)
  ),
  constraint fa_approved_amount_check check (approval_status <> 'APPROVED' or approved_amount is not null),
  constraint fa_rejection_check       check (approval_status <> 'REJECTED' or rejection_reason is not null),
  constraint fa_tenure_check          check (tenure_months is null or tenure_months between 1 and 120)
);

comment on table public.finance_applications is 'HP / finance applications (spec §27).';
comment on column public.finance_applications.commission_amount is
  'Restricted. Withheld from roles lacking finance.commission.view (spec §52).';

create index fa_customer_idx  on public.finance_applications (customer_id, application_date desc);
create index fa_company_idx   on public.finance_applications (finance_company_id, approval_status);
create index fa_branch_idx    on public.finance_applications (branch_id, application_date desc);
create index fa_sale_idx      on public.finance_applications (sale_id) where sale_id is not null;
create index fa_pending_idx   on public.finance_applications (dealer_id)
  where disbursement_status in ('PENDING', 'PARTIAL');

-- =============================================================================
-- finance_transactions — the per-company subsidiary ledger (spec §26)
-- =============================================================================
create table public.finance_transactions (
  id                 bigint generated always as identity primary key,
  dealer_id          uuid not null,
  branch_id          uuid not null,
  finance_company_id uuid not null,

  transaction_date   date not null default current_date,
  transaction_type   text not null,

  -- Signed against the dealer's position with this company: a credit increases
  -- what the company owes the dealer, a debit reduces it.
  debit              numeric(18, 4) not null default 0,
  credit             numeric(18, 4) not null default 0,
  balance_after      numeric(18, 4) not null default 0,

  reference_type     text,
  reference_id       uuid,
  reference_number   text,
  narration          text,

  application_id     uuid,
  sale_id            uuid,
  journal_entry_id   uuid,

  created_at         timestamptz not null default now(),
  created_by         uuid,

  constraint ft_company_tenant_fkey
    foreign key (finance_company_id, dealer_id) references public.finance_companies (id, dealer_id),
  constraint ft_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint ft_application_tenant_fkey
    foreign key (application_id, dealer_id) references public.finance_applications (id, dealer_id),
  constraint ft_sale_tenant_fkey
    foreign key (sale_id, dealer_id) references public.sales (id, dealer_id),
  constraint ft_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint ft_type_check check (transaction_type in (
    'ADVANCE_RECEIVED', 'VEHICLE_ADJUSTMENT', 'SETTLEMENT',
    'REFUND', 'COMMISSION', 'MANUAL_ADJUSTMENT', 'DISBURSEMENT'
  )),
  constraint ft_amounts_check check (debit >= 0 and credit >= 0),
  -- One-sided, like a journal line.
  constraint ft_one_sided_check check ((debit > 0 and credit = 0) or (credit > 0 and debit = 0))
);

comment on table public.finance_transactions is
  'Per-finance-company ledger (spec §25, §26). Never aggregated into a single '
  'generic balance across companies.';

create trigger finance_transactions_append_only
  before update or delete on public.finance_transactions
  for each row execute function app.forbid_mutation();

create index ft_company_date_idx on public.finance_transactions (finance_company_id, transaction_date desc);
create index ft_dealer_date_idx  on public.finance_transactions (dealer_id, transaction_date desc);
create index ft_reference_idx    on public.finance_transactions (reference_type, reference_id)
  where reference_id is not null;

-- Running balance per company, computed under a row lock so concurrent postings
-- cannot both read the same prior balance.
create or replace function app.finance_transactions_balance()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prev numeric(18, 4);
begin
  perform 1 from public.finance_companies
   where id = new.finance_company_id for update;

  select coalesce(balance_after, 0) into v_prev
    from public.finance_transactions
   where finance_company_id = new.finance_company_id
   order by id desc
   limit 1;

  new.balance_after := coalesce(v_prev, 0) + new.credit - new.debit;
  return new;
end;
$$;

create trigger finance_transactions_balance
  before insert on public.finance_transactions
  for each row execute function app.finance_transactions_balance();

create table public.finance_settlements (
  id                 uuid primary key default gen_random_uuid(),
  dealer_id          uuid not null,
  finance_company_id uuid not null,

  settlement_number  text not null,
  settlement_date    date not null default current_date,
  from_date          date,
  to_date            date,

  gross_amount       numeric(18, 4) not null default 0,
  commission_amount  numeric(18, 4) not null default 0,
  deductions         numeric(18, 4) not null default 0,
  net_amount         numeric(18, 4) generated always as (
    gross_amount - commission_amount - deductions
  ) stored,

  status             text not null default 'DRAFT',
  journal_entry_id   uuid,
  notes              text,

  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  created_by         uuid,

  constraint fs_number_key unique (dealer_id, settlement_number),
  constraint fs_id_dealer_key unique (id, dealer_id),
  constraint fs_company_tenant_fkey
    foreign key (finance_company_id, dealer_id) references public.finance_companies (id, dealer_id),
  constraint fs_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint fs_status_check  check (status in ('DRAFT', 'POSTED', 'CANCELLED')),
  constraint fs_amounts_check check (gross_amount >= 0 and commission_amount >= 0 and deductions >= 0),
  constraint fs_dates_check   check (to_date is null or from_date is null or to_date >= from_date)
);

create index fs_company_idx on public.finance_settlements (finance_company_id, settlement_date desc);

-- -----------------------------------------------------------------------------
-- public.finance_company_ledger() — opening + credits − debits = closing (§26)
-- -----------------------------------------------------------------------------
create or replace function public.finance_company_ledger(
  p_company_id uuid,
  p_from       date,
  p_to         date
)
returns table (
  transaction_date date,
  transaction_type text,
  reference_number text,
  narration        text,
  debit            numeric(18, 4),
  credit           numeric(18, 4),
  balance_after    numeric(18, 4)
)
language sql
stable
as $$
  -- Opening row: everything before the window, collapsed to one line.
  select p_from, 'OPENING'::text, null::text, 'Opening balance'::text,
         0::numeric(18, 4), 0::numeric(18, 4),
         coalesce((
           select ft.balance_after from public.finance_transactions ft
            where ft.finance_company_id = p_company_id and ft.transaction_date < p_from
            order by ft.id desc limit 1
         ), 0)
  union all
  select ft.transaction_date, ft.transaction_type, ft.reference_number, ft.narration,
         ft.debit, ft.credit, ft.balance_after
    from public.finance_transactions ft
   where ft.finance_company_id = p_company_id
     and ft.transaction_date between p_from and p_to
   order by 1, 7;
$$;

comment on function public.finance_company_ledger(uuid, date, date) is
  'Daily ledger view for one finance company (spec §26): opening, movements, closing.';

create trigger fa_set_updated_at before update on public.finance_applications
  for each row execute function app.set_updated_at();
create trigger fs_set_updated_at before update on public.finance_settlements
  for each row execute function app.set_updated_at();
create trigger fa_audit after insert or update or delete on public.finance_applications
  for each row execute function app.audit_trigger();

alter table public.finance_applications enable row level security;
alter table public.finance_transactions enable row level security;
alter table public.finance_settlements  enable row level security;

create policy fa_select on public.finance_applications for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('finance.applications.view')));
create policy fa_write on public.finance_applications for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('finance.applications.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('finance.applications.manage')));

create policy ft_select on public.finance_transactions for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('finance.trade_advance.view')));
create policy ft_insert on public.finance_transactions for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('finance.trade_advance.manage')
              or app.has_permission('finance.settlements.manage')
              or app.has_permission('sales.post'))));

create policy fs_select on public.finance_settlements for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('finance.trade_advance.view')));
create policy fs_write on public.finance_settlements for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('finance.settlements.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('finance.settlements.manage')));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.finance_applications, public.finance_settlements to authenticated';
    execute 'grant select, insert on public.finance_transactions to authenticated';
    execute 'grant all on public.finance_applications, public.finance_transactions, public.finance_settlements to service_role';
    execute 'grant execute on function public.finance_company_ledger(uuid, date, date) to authenticated';
  end if;
end;
$$;
