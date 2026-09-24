-- =============================================================================
-- 0082 — Fixed assets and depreciation, payroll, and loans
-- =============================================================================
-- Spec §12, §21, §24, §41. Audit checklist §02 (depreciation / accruals, loans
-- and interest, payroll), §09 (fixed asset and depreciation register).
--
-- ── Fixed assets ───────────────────────────────────────────────────────────
--
-- A computer could be bought on a purchase bill (0078) and depreciated by a
-- hand journal (0076), but nothing remembered the asset: its cost, its life,
-- what had been charged against it, what it was worth now. fixed_assets is the
-- register; run_depreciation() posts a month's depreciation for every asset in
-- one journal per branch, at most once per asset per month (a unique key, not
-- a convention); dispose_fixed_asset() takes it off the books with the gain or
-- loss. Registering an asset posts nothing — its cost is already in the ledger
-- from the bill that bought it.
--
-- ── Payroll ────────────────────────────────────────────────────────────────
--
-- Salary structures existed (0053); nothing turned them into a journal, so
-- salary was a bank payment to 5500 and PF, ESI, TDS and professional tax —
-- money the dealer owes the government from the day the salary is earned —
-- appeared nowhere. A payroll run takes the month's structures, is reviewed as
-- a draft (TDS and other deductions are entered then), posts
--
--     Salaries (gross) + Employer PF & ESI      Dr
--       Salaries Payable (net, per employee)      Cr
--       PF / ESI / TDS / PT Payable               Cr
--       Other Receivables (advance recovered)     Cr
--
-- and is paid from a bank account in one journal that also writes the bank
-- book. The statutory payables are then paid like any other liability.
--
-- ── Loans ──────────────────────────────────────────────────────────────────
--
-- A loan is a liability account and two kinds of money movement: the amount
-- received, and repayments that split into principal (reducing the liability)
-- and interest (an expense). Recording a repayment as one figure against the
-- loan understates the liability's fall and hides the interest cost; the
-- checklist asks for exactly this split. loan_schedule() gives the reducing-
-- balance EMI plan to compare against.
--
-- Rollback: drop the tables and functions created here; restore
--           public.control_account_tieout from 0077 and app.seed_chart_of_accounts
--           by renaming the _0076 function back.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Accounts
-- -----------------------------------------------------------------------------
create or replace function app.seed_payroll_asset_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
declare
  v_added integer := 0;
  a       record;
begin
  for a in
    select * from (values
      ('2710', 'Salaries Payable',          'LIABILITY', '2000'),
      ('2720', 'PF Payable',                'LIABILITY', '2000'),
      ('2730', 'ESI Payable',               'LIABILITY', '2000'),
      ('2740', 'TDS Payable',               'LIABILITY', '2000'),
      ('2750', 'Professional Tax Payable',  'LIABILITY', '2000'),
      ('4810', 'Gain on Sale of Assets',    'INCOME',    '4000'),
      ('5510', 'Employer PF & ESI',         'EXPENSE',   '5000'),
      ('5980', 'Loss on Sale of Assets',    'EXPENSE',   '5000')
    ) as t(code, name, account_type, parent_code)
  loop
    insert into public.chart_of_accounts
      (dealer_id, code, name, account_type, normal_balance, is_group, parent_id, is_system, is_branch_scoped)
    select p_dealer_id, a.code, a.name, a.account_type,
           case when a.account_type in ('ASSET', 'EXPENSE') then 'DEBIT' else 'CREDIT' end,
           false, p.id, true, false
      from public.chart_of_accounts p
     where p.dealer_id = p_dealer_id and p.code = a.parent_code and p.is_group
    on conflict on constraint coa_dealer_code_key do nothing;
    if found then v_added := v_added + 1; end if;
  end loop;
  return v_added;
end;
$$;

do $$
declare d record;
begin
  for d in select id from public.dealers loop
    perform app.seed_payroll_asset_accounts(d.id);
  end loop;
end $$;

alter function app.seed_chart_of_accounts(uuid) rename to seed_chart_of_accounts_0076;

create or replace function app.seed_chart_of_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
begin
  return app.seed_chart_of_accounts_0076(p_dealer_id) + app.seed_payroll_asset_accounts(p_dealer_id);
end;
$$;

insert into public.permissions (code, module, description, is_sensitive) values
  ('assets.view',     'accounting', 'View the fixed asset register', false),
  ('assets.manage',   'accounting', 'Register, depreciate and dispose of fixed assets', false),
  ('loans.view',      'accounting', 'View loans and their statements', false),
  ('loans.manage',    'accounting', 'Record loans, disbursements and repayments', false),
  ('hr.payroll.run',  'hr',         'Prepare, post and pay monthly payroll', true)
on conflict (code) do update set module = excluded.module, description = excluded.description,
                                 is_sensitive = excluded.is_sensitive;

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join (values ('assets.view'), ('assets.manage'), ('loans.view'), ('loans.manage')) as p(code)
 where r.is_system and r.code in ('DEALER_OWNER', 'ACCOUNTS')
on conflict do nothing;

insert into public.role_permissions (role_id, permission_code)
select r.id, 'hr.payroll.run' from public.roles r
 where r.is_system and r.code = 'DEALER_OWNER'
on conflict do nothing;

-- A cash or bank ledger line is always accompanied by its book row. These
-- helpers write the bank-book row for a journal this migration's functions post.
create or replace function app.bank_book_row(
  p_bank_account_id uuid, p_date date, p_direction text, p_amount numeric,
  p_particular text, p_reference_type text, p_reference_id uuid, p_journal_entry_id uuid,
  p_idempotency_key text default null
)
returns void
language sql
as $$
  insert into public.bank_transactions
    (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
     reference_type, reference_id, journal_entry_id, idempotency_key, created_by)
  select b.dealer_id, b.id, p_date, p_direction, p_amount, p_particular,
         p_reference_type, p_reference_id, p_journal_entry_id, p_idempotency_key, auth.uid()
    from public.bank_accounts b where b.id = p_bank_account_id;
$$;

-- =============================================================================
-- Fixed assets
-- =============================================================================
create table public.fixed_assets (
  id                     uuid primary key default gen_random_uuid(),
  dealer_id              uuid not null references public.dealers (id) on delete restrict,
  branch_id              uuid not null,
  asset_code             text not null,
  name                   text not null,
  category               text,
  asset_account_id       uuid not null,
  accumulated_account_id uuid not null,
  expense_account_id     uuid not null,
  purchase_bill_line_id  uuid,
  acquired_on            date not null,
  depreciation_start     date not null,
  cost                   numeric(18, 4) not null,
  salvage_value          numeric(18, 4) not null default 0,
  method                 text not null,
  useful_life_months     integer,
  wdv_rate               numeric(6, 3),
  status                 text not null default 'ACTIVE',
  disposed_on            date,
  disposal_value         numeric(18, 4),
  disposal_journal_id    uuid,
  created_at             timestamptz not null default now(),
  created_by             uuid,

  constraint fixed_assets_code_key unique (dealer_id, asset_code),
  constraint fixed_assets_id_dealer_key unique (id, dealer_id),
  constraint fixed_assets_branch_tenant_fkey foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint fixed_assets_asset_acc_fkey foreign key (asset_account_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint fixed_assets_accum_acc_fkey foreign key (accumulated_account_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint fixed_assets_expense_acc_fkey foreign key (expense_account_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint fixed_assets_bill_line_key unique (purchase_bill_line_id),
  constraint fixed_assets_amounts_check check (cost > 0 and salvage_value >= 0 and salvage_value < cost),
  constraint fixed_assets_method_check check (
    (method = 'SLM' and useful_life_months between 1 and 1200 and wdv_rate is null)
    or (method = 'WDV' and wdv_rate > 0 and wdv_rate <= 100 and useful_life_months is null)
  ),
  constraint fixed_assets_status_check check (status in ('ACTIVE', 'DISPOSED')),
  constraint fixed_assets_disposal_check check (
    status = 'ACTIVE' or (disposed_on is not null and disposal_journal_id is not null)
  )
);

create table public.fixed_asset_depreciation (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null,
  asset_id         uuid not null,
  period           date not null,
  amount           numeric(18, 4) not null,
  journal_entry_id uuid not null,
  created_at       timestamptz not null default now(),

  -- The rule that makes a re-run harmless: one charge per asset per month.
  constraint fad_asset_period_key unique (asset_id, period),
  constraint fad_asset_fkey foreign key (asset_id, dealer_id) references public.fixed_assets (id, dealer_id),
  constraint fad_period_check check (extract(day from period) = 1),
  constraint fad_amount_check check (amount > 0)
);

create index fixed_assets_dealer_idx on public.fixed_assets (dealer_id, status);

create trigger fixed_assets_audit after insert or update on public.fixed_assets
  for each row execute function app.audit_trigger();

alter table public.fixed_assets enable row level security;
alter table public.fixed_asset_depreciation enable row level security;

create policy fixed_assets_select on public.fixed_assets for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('assets.view')));
create policy fixed_assets_write on public.fixed_assets for all to authenticated
  using (dealer_id = app.current_dealer_id() and app.has_permission('assets.manage'))
  with check (dealer_id = app.current_dealer_id() and app.has_permission('assets.manage'));
create policy fad_select on public.fixed_asset_depreciation for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('assets.view')));
create policy fad_insert on public.fixed_asset_depreciation for insert to authenticated
  with check (dealer_id = app.current_dealer_id() and app.has_permission('assets.manage'));

-- Accumulated depreciation of one asset, to a date.
create or replace function app.asset_accumulated(p_asset_id uuid, p_as_on date default null)
returns numeric
language sql
stable
as $$
  select coalesce(sum(d.amount), 0) from public.fixed_asset_depreciation d
   where d.asset_id = p_asset_id
     and (p_as_on is null or d.period <= p_as_on);
$$;

create or replace function public.register_fixed_asset(
  p_name               text,
  p_asset_account_id   uuid,
  p_acquired_on        date,
  p_cost               numeric,
  p_method             text default 'SLM',
  p_useful_life_months integer default null,
  p_wdv_rate           numeric default null,
  p_salvage_value      numeric default 0,
  p_category           text default null,
  p_branch_id          uuid default null,
  p_purchase_bill_line_id uuid default null
)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_acc    public.chart_of_accounts;
  v_line   record;
  v_code   text;
  v_id     uuid;
  v_branch uuid;
begin
  if v_dealer is null or not app.has_permission('assets.manage') then
    raise exception 'You may not register fixed assets.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(length(btrim(p_name)), 0) < 2 then
    raise exception 'Name the asset.' using errcode = 'check_violation';
  end if;

  select * into v_acc from public.chart_of_accounts where id = p_asset_account_id and dealer_id = v_dealer;
  if v_acc.id is null or v_acc.account_type <> 'ASSET' or v_acc.is_group then
    raise exception 'A fixed asset sits on a postable asset account (e.g. 1951).' using errcode = 'check_violation';
  end if;
  if app.is_money_ledger(v_dealer, p_asset_account_id) or v_acc.code in ('1959') then
    raise exception 'Account % % cannot hold a fixed asset.', v_acc.code, v_acc.name using errcode = 'check_violation';
  end if;

  if p_purchase_bill_line_id is not null then
    select l.id, l.account_id, l.taxable_value, l.itc_eligible, l.cgst_amount + l.sgst_amount + l.igst_amount as tax,
           b.status, b.branch_id, b.bill_date
      into v_line
      from public.purchase_bill_lines l join public.purchase_bills b on b.id = l.purchase_bill_id
     where l.id = p_purchase_bill_line_id and l.dealer_id = v_dealer;
    if v_line.id is null or v_line.status <> 'POSTED' or v_line.account_id <> p_asset_account_id then
      raise exception 'That bill line is not a posted purchase charged to this asset account.' using errcode = 'check_violation';
    end if;
  end if;

  v_branch := coalesce(p_branch_id, v_line.branch_id,
                       (select id from public.branches where dealer_id = v_dealer order by code limit 1));
  v_code := 'FA-' || lpad((select count(*) + 1 from public.fixed_assets where dealer_id = v_dealer)::text, 5, '0');

  insert into public.fixed_assets
    (dealer_id, branch_id, asset_code, name, category, asset_account_id, accumulated_account_id,
     expense_account_id, purchase_bill_line_id, acquired_on, depreciation_start, cost, salvage_value,
     method, useful_life_months, wdv_rate, created_by)
  values
    (v_dealer, v_branch, v_code, btrim(p_name), nullif(btrim(p_category), ''), p_asset_account_id,
     (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '1959'),
     (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '5950'),
     p_purchase_bill_line_id, p_acquired_on,
     -- Depreciation starts the month the asset is acquired.
     date_trunc('month', p_acquired_on)::date,
     coalesce(p_cost, v_line.taxable_value + case when v_line.itc_eligible then 0 else v_line.tax end),
     coalesce(p_salvage_value, 0), upper(p_method),
     case when upper(p_method) = 'SLM' then p_useful_life_months end,
     case when upper(p_method) = 'WDV' then p_wdv_rate end,
     auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.register_fixed_asset(text, uuid, date, numeric, text, integer, numeric, numeric, text, uuid, uuid) is
  'Adds an asset to the register (checklist §09). Posts nothing: its cost is '
  'already in the ledger from the bill that bought it.';

create or replace function public.run_depreciation(p_month date)
returns table (assets integer, total numeric, journals integer)
language plpgsql
as $$
declare
  v_dealer  uuid := app.current_dealer_id();
  v_period  date := date_trunc('month', p_month)::date;
  v_end     date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  v_branch  record;
  v_asset   record;
  v_amount  numeric;
  v_nbv     numeric;
  v_lines   jsonb;
  v_charges jsonb;
  v_entry   uuid;
  v_c       jsonb;
begin
  if v_dealer is null or not app.has_permission('assets.manage') then
    raise exception 'You may not run depreciation.' using errcode = 'insufficient_privilege';
  end if;
  if v_period > current_date then
    raise exception 'Depreciation for % cannot be run before the month begins.', to_char(v_period, 'Mon YYYY')
      using errcode = 'check_violation';
  end if;

  assets := 0; total := 0; journals := 0;

  for v_branch in select distinct branch_id from public.fixed_assets
                   where dealer_id = v_dealer and status = 'ACTIVE' loop
    v_lines := '[]'::jsonb;
    v_charges := '[]'::jsonb;

    for v_asset in
      select a.* from public.fixed_assets a
       where a.dealer_id = v_dealer and a.branch_id = v_branch.branch_id and a.status = 'ACTIVE'
         and a.depreciation_start <= v_period
         -- Never twice, and never behind a month already charged.
         and not exists (select 1 from public.fixed_asset_depreciation d
                          where d.asset_id = a.id and d.period >= v_period)
       order by a.asset_code
    loop
      v_nbv := v_asset.cost - app.asset_accumulated(v_asset.id);
      v_amount := case v_asset.method
                    when 'SLM' then round((v_asset.cost - v_asset.salvage_value) / v_asset.useful_life_months, 2)
                    else round(v_nbv * v_asset.wdv_rate / 100 / 12, 2)
                  end;
      v_amount := least(v_amount, v_nbv - v_asset.salvage_value);
      continue when v_amount <= 0;

      v_lines := v_lines
        || jsonb_build_object('account_id', v_asset.expense_account_id, 'debit', v_amount, 'credit', 0,
                              'narration', v_asset.asset_code || ' ' || v_asset.name)
        || jsonb_build_object('account_id', v_asset.accumulated_account_id, 'debit', 0, 'credit', v_amount,
                              'narration', v_asset.asset_code || ' ' || v_asset.name);
      v_charges := v_charges || jsonb_build_object('asset_id', v_asset.id, 'amount', v_amount);
      assets := assets + 1;
      total := total + v_amount;
    end loop;

    continue when jsonb_array_length(v_lines) = 0;

    v_entry := app.post_journal(
      v_dealer, v_branch.branch_id, least(v_end, current_date), 'EXPENSE',
      'Depreciation for ' || to_char(v_period, 'Mon YYYY'), v_lines,
      'DEPRECIATION', null, null);
    journals := journals + 1;

    for v_c in select * from jsonb_array_elements(v_charges) loop
      insert into public.fixed_asset_depreciation (dealer_id, asset_id, period, amount, journal_entry_id)
      values (v_dealer, (v_c ->> 'asset_id')::uuid, v_period, (v_c ->> 'amount')::numeric, v_entry);
    end loop;
  end loop;

  return next;
end;
$$;

comment on function public.run_depreciation(date) is
  'Posts one month''s depreciation for every active asset, one journal per branch '
  '(checklist §02). At most once per asset per month; a re-run charges only what '
  'was not charged.';

create or replace function public.dispose_fixed_asset(
  p_asset_id uuid,
  p_date     date,
  p_proceeds numeric,
  p_reason   text
)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_asset  public.fixed_assets;
  v_acc    numeric;
  v_nbv    numeric;
  v_gain   numeric;
  v_lines  jsonb := '[]'::jsonb;
  v_entry  uuid;
begin
  if v_dealer is null or not app.has_permission('assets.manage') then
    raise exception 'You may not dispose of fixed assets.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(length(btrim(p_reason)), 0) < 3 then
    raise exception 'Say why the asset is leaving the books.' using errcode = 'check_violation';
  end if;
  if coalesce(p_proceeds, 0) < 0 then
    raise exception 'Proceeds cannot be negative.' using errcode = 'check_violation';
  end if;

  select * into v_asset from public.fixed_assets where id = p_asset_id and dealer_id = v_dealer for update;
  if v_asset.id is null then
    raise exception 'Asset not found.' using errcode = 'no_data_found';
  end if;
  if v_asset.status <> 'ACTIVE' then
    raise exception 'Asset % is already disposed of.', v_asset.asset_code using errcode = 'check_violation';
  end if;

  v_acc  := app.asset_accumulated(p_asset_id);
  v_nbv  := v_asset.cost - v_acc;
  v_gain := coalesce(p_proceeds, 0) - v_nbv;

  if v_acc > 0 then
    v_lines := v_lines || jsonb_build_object('account_id', v_asset.accumulated_account_id, 'debit', v_acc, 'credit', 0,
                                             'narration', 'Depreciation written back');
  end if;
  if coalesce(p_proceeds, 0) > 0 then
    v_lines := v_lines || jsonb_build_object('account_id',
      (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '1800'),
      'debit', p_proceeds, 'credit', 0, 'narration', 'Sale proceeds receivable');
  end if;
  if v_gain < 0 then
    v_lines := v_lines || jsonb_build_object('account_id',
      (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '5980'),
      'debit', -v_gain, 'credit', 0, 'narration', 'Loss on disposal');
  end if;
  v_lines := v_lines || jsonb_build_object('account_id', v_asset.asset_account_id, 'debit', 0, 'credit', v_asset.cost,
                                           'narration', v_asset.asset_code || ' at cost');
  if v_gain > 0 then
    v_lines := v_lines || jsonb_build_object('account_id',
      (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '4810'),
      'debit', 0, 'credit', v_gain, 'narration', 'Gain on disposal');
  end if;

  v_entry := app.post_journal(v_dealer, v_asset.branch_id, p_date, 'EXPENSE',
    'Disposal of ' || v_asset.asset_code || ' ' || v_asset.name || ' — ' || btrim(p_reason),
    v_lines, 'ASSET_DISPOSAL', p_asset_id, 'asset-disposal:' || p_asset_id::text);

  update public.fixed_assets
     set status = 'DISPOSED', disposed_on = p_date, disposal_value = coalesce(p_proceeds, 0),
         disposal_journal_id = v_entry
   where id = p_asset_id;

  return v_entry;
end;
$$;

create or replace function public.fixed_asset_register(p_as_on date default current_date)
returns table (
  asset_id uuid, asset_code text, name text, category text, branch_name text,
  account_code text, acquired_on date, method text, cost numeric(18, 4),
  accumulated numeric(18, 4), net_book_value numeric(18, 4), status text,
  last_period date, disposed_on date
)
language sql
stable
as $$
  select a.id, a.asset_code, a.name, a.category, b.name, c.code, a.acquired_on, a.method,
         a.cost, app.asset_accumulated(a.id, p_as_on),
         case when a.status = 'DISPOSED' and a.disposed_on <= p_as_on then 0
              else a.cost - app.asset_accumulated(a.id, p_as_on) end,
         case when a.status = 'DISPOSED' and a.disposed_on <= p_as_on then 'DISPOSED' else 'ACTIVE' end,
         (select max(d.period) from public.fixed_asset_depreciation d where d.asset_id = a.id and d.period <= p_as_on),
         a.disposed_on
    from public.fixed_assets a
    join public.branches b on b.id = a.branch_id
    join public.chart_of_accounts c on c.id = a.asset_account_id
   where a.acquired_on <= p_as_on
   order by a.asset_code;
$$;

-- =============================================================================
-- Payroll
-- =============================================================================
create table public.payroll_runs (
  id                 uuid primary key default gen_random_uuid(),
  dealer_id          uuid not null references public.dealers (id) on delete restrict,
  branch_id          uuid not null,
  period             date not null,
  status             text not null default 'DRAFT',
  journal_entry_id   uuid,
  payment_journal_id uuid,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  posted_at          timestamptz,
  posted_by          uuid,
  paid_at            timestamptz,

  constraint payroll_runs_id_dealer_key unique (id, dealer_id),
  constraint payroll_runs_period_key unique (dealer_id, branch_id, period),
  constraint payroll_runs_branch_tenant_fkey foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint payroll_runs_status_check check (status in ('DRAFT', 'POSTED', 'PAID')),
  constraint payroll_runs_period_check check (extract(day from period) = 1)
);

create table public.payroll_lines (
  id               uuid primary key default gen_random_uuid(),
  run_id           uuid not null,
  dealer_id        uuid not null,
  employee_id      uuid not null,
  gross            numeric(14, 2) not null,
  pf_employee      numeric(14, 2) not null default 0,
  esi_employee     numeric(14, 2) not null default 0,
  professional_tax numeric(14, 2) not null default 0,
  tds              numeric(14, 2) not null default 0,
  other_deduction  numeric(14, 2) not null default 0,
  pf_employer      numeric(14, 2) not null default 0,
  esi_employer     numeric(14, 2) not null default 0,
  net_pay          numeric(14, 2) generated always as (
    gross - pf_employee - esi_employee - professional_tax - tds - other_deduction
  ) stored,

  constraint payroll_lines_run_employee_key unique (run_id, employee_id),
  constraint payroll_lines_run_fkey foreign key (run_id, dealer_id) references public.payroll_runs (id, dealer_id) on delete cascade,
  constraint payroll_lines_employee_fkey foreign key (employee_id, dealer_id) references public.employees (id, dealer_id),
  constraint payroll_lines_amounts_check check (
    gross >= 0 and pf_employee >= 0 and esi_employee >= 0 and professional_tax >= 0
    and tds >= 0 and other_deduction >= 0 and pf_employer >= 0 and esi_employer >= 0
  ),
  constraint payroll_lines_net_check check (
    gross - pf_employee - esi_employee - professional_tax - tds - other_deduction >= 0
  )
);

-- A run's lines move only while it is a draft.
create or replace function app.payroll_lines_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_status text;
begin
  select status into v_status from public.payroll_runs where id = coalesce(new.run_id, old.run_id);
  if v_status is not null and v_status <> 'DRAFT' then
    raise exception 'This payroll is % and cannot be changed.', lower(v_status) using errcode = 'insufficient_privilege';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger payroll_lines_guard before insert or update or delete on public.payroll_lines
  for each row execute function app.payroll_lines_guard();
create trigger payroll_runs_audit after insert or update on public.payroll_runs
  for each row execute function app.audit_trigger();

alter table public.payroll_runs enable row level security;
alter table public.payroll_lines enable row level security;
create policy payroll_runs_all on public.payroll_runs for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('hr.payroll.run')))
  with check (dealer_id = app.current_dealer_id() and app.has_permission('hr.payroll.run'));
create policy payroll_lines_all on public.payroll_lines for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('hr.payroll.run')))
  with check (dealer_id = app.current_dealer_id() and app.has_permission('hr.payroll.run'));

create or replace function public.create_payroll_run(p_period date, p_branch_id uuid)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_period date := date_trunc('month', p_period)::date;
  v_end    date := (date_trunc('month', p_period) + interval '1 month - 1 day')::date;
  v_run    uuid;
begin
  if v_dealer is null or not app.has_permission('hr.payroll.run') then
    raise exception 'You may not run payroll.' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.branches where id = p_branch_id and dealer_id = v_dealer) then
    raise exception 'That branch does not belong to this dealer.' using errcode = 'insufficient_privilege';
  end if;

  insert into public.payroll_runs (dealer_id, branch_id, period, created_by)
  values (v_dealer, p_branch_id, v_period, auth.uid())
  returning id into v_run;

  -- Everyone at the branch with a salary structure in force during the month.
  insert into public.payroll_lines
    (run_id, dealer_id, employee_id, gross, pf_employee, esi_employee, professional_tax,
     other_deduction, pf_employer, esi_employer)
  select v_run, v_dealer, e.id, s.gross_earnings, s.pf_employee, s.esi_employee, s.professional_tax,
         s.other_deduction, s.pf_employer, s.esi_employer
    from public.employees e
    join lateral (
      select * from public.employee_salary_structures ss
       where ss.employee_id = e.id and ss.effective_from <= v_end
         and (ss.effective_to is null or ss.effective_to >= v_period)
       order by ss.effective_from desc limit 1
    ) s on true
   where e.dealer_id = v_dealer and e.branch_id = p_branch_id and e.status in ('ACTIVE', 'ON_LEAVE');

  return v_run;
end;
$$;

create or replace function public.post_payroll_run(p_run_id uuid)
returns uuid
language plpgsql
as $$
declare
  v_run   public.payroll_runs;
  v_d     uuid;
  v_lines jsonb := '[]'::jsonb;
  t       record;
  e       record;
  v_entry uuid;
  acc     record;
begin
  select * into v_run from public.payroll_runs where id = p_run_id and dealer_id = app.current_dealer_id() for update;
  if v_run.id is null then
    raise exception 'Payroll run not found.' using errcode = 'no_data_found';
  end if;
  if not app.has_permission('hr.payroll.run') then
    raise exception 'You may not post payroll.' using errcode = 'insufficient_privilege';
  end if;
  if v_run.status <> 'DRAFT' then
    return v_run.journal_entry_id;
  end if;
  v_d := v_run.dealer_id;

  select (select id from public.chart_of_accounts where dealer_id = v_d and code = '5500') as salaries,
         (select id from public.chart_of_accounts where dealer_id = v_d and code = '5510') as employer,
         (select id from public.chart_of_accounts where dealer_id = v_d and code = '2710') as payable,
         (select id from public.chart_of_accounts where dealer_id = v_d and code = '2720') as pf,
         (select id from public.chart_of_accounts where dealer_id = v_d and code = '2730') as esi,
         (select id from public.chart_of_accounts where dealer_id = v_d and code = '2740') as tds,
         (select id from public.chart_of_accounts where dealer_id = v_d and code = '2750') as pt,
         (select id from public.chart_of_accounts where dealer_id = v_d and code = '1800') as advances
    into acc;

  select coalesce(sum(gross), 0) as gross, coalesce(sum(pf_employer + esi_employer), 0) as employer,
         coalesce(sum(pf_employee + pf_employer), 0) as pf, coalesce(sum(esi_employee + esi_employer), 0) as esi,
         coalesce(sum(tds), 0) as tds, coalesce(sum(professional_tax), 0) as pt, count(*) as n
    into t from public.payroll_lines where run_id = p_run_id;
  if t.n = 0 or t.gross = 0 then
    raise exception 'This payroll has no salary to post.' using errcode = 'check_violation';
  end if;

  v_lines := v_lines || jsonb_build_object('account_id', acc.salaries, 'debit', t.gross, 'credit', 0,
                                           'narration', 'Gross salaries');
  if t.employer > 0 then
    v_lines := v_lines || jsonb_build_object('account_id', acc.employer, 'debit', t.employer, 'credit', 0,
                                             'narration', 'Employer PF and ESI');
  end if;
  -- Net pay owed, per employee, so each one's balance is on their own ledger.
  for e in select l.employee_id, l.net_pay, l.other_deduction, em.name from public.payroll_lines l
            join public.employees em on em.id = l.employee_id
           where l.run_id = p_run_id order by em.name loop
    if e.net_pay > 0 then
      v_lines := v_lines || jsonb_build_object('account_id', acc.payable, 'debit', 0, 'credit', e.net_pay,
        'narration', 'Net pay ' || e.name, 'party_type', 'EMPLOYEE', 'party_id', e.employee_id);
    end if;
    if e.other_deduction > 0 then
      v_lines := v_lines || jsonb_build_object('account_id', acc.advances, 'debit', 0, 'credit', e.other_deduction,
        'narration', 'Recovered from ' || e.name, 'party_type', 'EMPLOYEE', 'party_id', e.employee_id);
    end if;
  end loop;
  if t.pf > 0 then v_lines := v_lines || jsonb_build_object('account_id', acc.pf, 'debit', 0, 'credit', t.pf, 'narration', 'PF'); end if;
  if t.esi > 0 then v_lines := v_lines || jsonb_build_object('account_id', acc.esi, 'debit', 0, 'credit', t.esi, 'narration', 'ESI'); end if;
  if t.tds > 0 then v_lines := v_lines || jsonb_build_object('account_id', acc.tds, 'debit', 0, 'credit', t.tds, 'narration', 'TDS on salary'); end if;
  if t.pt > 0 then v_lines := v_lines || jsonb_build_object('account_id', acc.pt, 'debit', 0, 'credit', t.pt, 'narration', 'Professional tax'); end if;

  v_entry := app.post_journal(v_d, v_run.branch_id,
    least((v_run.period + interval '1 month - 1 day')::date, current_date), 'EXPENSE',
    'Payroll for ' || to_char(v_run.period, 'Mon YYYY'), v_lines, 'PAYROLL', p_run_id, 'payroll:' || p_run_id::text);

  update public.payroll_runs set status = 'POSTED', journal_entry_id = v_entry, posted_at = now(), posted_by = auth.uid()
   where id = p_run_id;
  return v_entry;
end;
$$;

create or replace function public.pay_payroll_run(p_run_id uuid, p_bank_account_id uuid, p_date date default current_date)
returns uuid
language plpgsql
as $$
declare
  v_run   public.payroll_runs;
  v_bank  public.bank_accounts;
  v_lines jsonb := '[]'::jsonb;
  v_total numeric := 0;
  e       record;
  v_entry uuid;
  v_payable uuid;
begin
  select * into v_run from public.payroll_runs where id = p_run_id and dealer_id = app.current_dealer_id() for update;
  if v_run.id is null then
    raise exception 'Payroll run not found.' using errcode = 'no_data_found';
  end if;
  if not app.has_permission('hr.payroll.run') then
    raise exception 'You may not pay payroll.' using errcode = 'insufficient_privilege';
  end if;
  if v_run.status = 'PAID' then
    return v_run.payment_journal_id;
  end if;
  if v_run.status <> 'POSTED' then
    raise exception 'Post the payroll before paying it.' using errcode = 'check_violation';
  end if;
  select * into v_bank from public.bank_accounts where id = p_bank_account_id and dealer_id = v_run.dealer_id and status = 'ACTIVE';
  if v_bank.id is null then
    raise exception 'Choose an active bank account.' using errcode = 'no_data_found';
  end if;

  select id into v_payable from public.chart_of_accounts where dealer_id = v_run.dealer_id and code = '2710';
  for e in select l.employee_id, l.net_pay, em.name from public.payroll_lines l
            join public.employees em on em.id = l.employee_id
           where l.run_id = p_run_id and l.net_pay > 0 order by em.name loop
    v_lines := v_lines || jsonb_build_object('account_id', v_payable, 'debit', e.net_pay, 'credit', 0,
      'narration', 'Salary paid ' || e.name, 'party_type', 'EMPLOYEE', 'party_id', e.employee_id);
    v_total := v_total + e.net_pay;
  end loop;
  v_lines := v_lines || jsonb_build_object('account_id', v_bank.ledger_account_id, 'debit', 0, 'credit', v_total,
                                           'narration', 'Salaries ' || to_char(v_run.period, 'Mon YYYY'));

  v_entry := app.post_journal(v_run.dealer_id, v_run.branch_id, p_date, 'BANK',
    'Salary payment for ' || to_char(v_run.period, 'Mon YYYY'), v_lines,
    'PAYROLL_PAYMENT', p_run_id, 'payroll-pay:' || p_run_id::text);

  perform app.bank_book_row(p_bank_account_id, p_date, 'PAYMENT', v_total,
    'Salaries ' || to_char(v_run.period, 'Mon YYYY'), 'PAYROLL', p_run_id, v_entry);

  update public.payroll_runs set status = 'PAID', payment_journal_id = v_entry, paid_at = now() where id = p_run_id;
  return v_entry;
end;
$$;

-- =============================================================================
-- Loans
-- =============================================================================
create table public.loans (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null references public.dealers (id) on delete restrict,
  branch_id      uuid not null,
  loan_number    text not null,
  lender         text not null,
  account_id     uuid not null,
  principal      numeric(18, 4) not null,
  interest_rate  numeric(6, 3) not null,
  start_date     date not null,
  tenure_months  integer not null,
  status         text not null default 'ACTIVE',
  notes          text,
  created_at     timestamptz not null default now(),
  created_by     uuid,

  constraint loans_number_key unique (dealer_id, loan_number),
  constraint loans_id_dealer_key unique (id, dealer_id),
  constraint loans_branch_tenant_fkey foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint loans_account_fkey foreign key (account_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint loans_amounts_check check (principal > 0 and interest_rate >= 0 and tenure_months between 1 and 600),
  constraint loans_status_check check (status in ('ACTIVE', 'CLOSED'))
);

create table public.loan_transactions (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null,
  loan_id          uuid not null,
  txn_date         date not null,
  kind             text not null,
  principal        numeric(18, 4) not null default 0,
  interest         numeric(18, 4) not null default 0,
  bank_account_id  uuid not null,
  journal_entry_id uuid not null,
  idempotency_key  text,
  created_at       timestamptz not null default now(),
  created_by       uuid,

  constraint loan_txn_loan_fkey foreign key (loan_id, dealer_id) references public.loans (id, dealer_id),
  constraint loan_txn_kind_check check (kind in ('DISBURSEMENT', 'REPAYMENT')),
  constraint loan_txn_amounts_check check (principal >= 0 and interest >= 0 and principal + interest > 0),
  constraint loan_txn_disbursement_check check (kind <> 'DISBURSEMENT' or interest = 0)
);

create unique index loan_txn_idempotency_key on public.loan_transactions (dealer_id, idempotency_key)
  where idempotency_key is not null;

create trigger loans_audit after insert or update on public.loans for each row execute function app.audit_trigger();

alter table public.loans enable row level security;
alter table public.loan_transactions enable row level security;
create policy loans_select on public.loans for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('loans.view')));
create policy loans_write on public.loans for all to authenticated
  using (dealer_id = app.current_dealer_id() and app.has_permission('loans.manage'))
  with check (dealer_id = app.current_dealer_id() and app.has_permission('loans.manage'));
create policy loan_txn_select on public.loan_transactions for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('loans.view')));
create policy loan_txn_insert on public.loan_transactions for insert to authenticated
  with check (dealer_id = app.current_dealer_id() and app.has_permission('loans.manage'));

create or replace function public.create_loan(
  p_lender text, p_principal numeric, p_interest_rate numeric, p_start_date date,
  p_tenure_months integer, p_account_id uuid default null, p_branch_id uuid default null, p_notes text default null
)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_acc    public.chart_of_accounts;
  v_id     uuid;
begin
  if v_dealer is null or not app.has_permission('loans.manage') then
    raise exception 'You may not record loans.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(length(btrim(p_lender)), 0) < 2 then
    raise exception 'Name the lender.' using errcode = 'check_violation';
  end if;
  select * into v_acc from public.chart_of_accounts
   where dealer_id = v_dealer and id = coalesce(p_account_id,
     (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '2800'));
  if v_acc.id is null or v_acc.account_type <> 'LIABILITY' or v_acc.is_group then
    raise exception 'A loan sits on a postable liability account (e.g. 2800 Loans).' using errcode = 'check_violation';
  end if;

  insert into public.loans (dealer_id, branch_id, loan_number, lender, account_id, principal, interest_rate,
                            start_date, tenure_months, notes, created_by)
  values (v_dealer,
          coalesce(p_branch_id, (select id from public.branches where dealer_id = v_dealer order by code limit 1)),
          'LN-' || lpad((select count(*) + 1 from public.loans where dealer_id = v_dealer)::text, 4, '0'),
          btrim(p_lender), v_acc.id, p_principal, p_interest_rate, p_start_date, p_tenure_months,
          nullif(btrim(p_notes), ''), auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.record_loan_transaction(
  p_loan_id         uuid,
  p_kind            text,
  p_bank_account_id uuid,
  p_date            date,
  p_principal       numeric,
  p_interest        numeric default 0,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_loan  public.loans;
  v_bank  public.bank_accounts;
  v_out   numeric;
  v_lines jsonb;
  v_entry uuid;
  v_existing uuid;
  v_total numeric := coalesce(p_principal, 0) + coalesce(p_interest, 0);
begin
  select * into v_loan from public.loans where id = p_loan_id and dealer_id = app.current_dealer_id() for update;
  if v_loan.id is null then
    raise exception 'Loan not found.' using errcode = 'no_data_found';
  end if;
  if not app.has_permission('loans.manage') then
    raise exception 'You may not record loan transactions.' using errcode = 'insufficient_privilege';
  end if;
  if p_idempotency_key is not null then
    select journal_entry_id into v_existing from public.loan_transactions
     where dealer_id = v_loan.dealer_id and idempotency_key = p_idempotency_key;
    if v_existing is not null then return v_existing; end if;
  end if;
  if p_kind not in ('DISBURSEMENT', 'REPAYMENT') then
    raise exception 'A loan transaction is a DISBURSEMENT or a REPAYMENT.' using errcode = 'check_violation';
  end if;
  if coalesce(p_principal, 0) < 0 or coalesce(p_interest, 0) < 0 or v_total <= 0 then
    raise exception 'Enter an amount greater than zero.' using errcode = 'check_violation';
  end if;
  select * into v_bank from public.bank_accounts where id = p_bank_account_id and dealer_id = v_loan.dealer_id and status = 'ACTIVE';
  if v_bank.id is null then
    raise exception 'Choose an active bank account.' using errcode = 'no_data_found';
  end if;

  select coalesce(sum(case when kind = 'DISBURSEMENT' then principal else -principal end), 0) into v_out
    from public.loan_transactions where loan_id = p_loan_id;

  if p_kind = 'DISBURSEMENT' then
    if coalesce(p_interest, 0) <> 0 then
      raise exception 'A disbursement carries no interest.' using errcode = 'check_violation';
    end if;
    -- The sanction caps what is ever drawn, not what is outstanding: repaying an
    -- instalment does not free that amount to be drawn again.
    if (select coalesce(sum(principal), 0) from public.loan_transactions
         where loan_id = p_loan_id and kind = 'DISBURSEMENT') + p_principal > v_loan.principal then
      raise exception 'That would take % beyond its sanctioned %.', v_loan.loan_number, v_loan.principal
        using errcode = 'check_violation';
    end if;
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_bank.ledger_account_id, 'debit', p_principal, 'credit', 0, 'narration', 'Loan received'),
      jsonb_build_object('account_id', v_loan.account_id, 'debit', 0, 'credit', p_principal, 'narration', v_loan.loan_number || ' ' || v_loan.lender));
  else
    if coalesce(p_principal, 0) > v_out then
      raise exception 'Only % of principal is outstanding on %.', v_out, v_loan.loan_number using errcode = 'check_violation';
    end if;
    -- Principal reduces the liability; interest is a cost, never a repayment of principal.
    v_lines := '[]'::jsonb;
    if coalesce(p_principal, 0) > 0 then
      v_lines := v_lines || jsonb_build_object('account_id', v_loan.account_id, 'debit', p_principal, 'credit', 0,
                                               'narration', v_loan.loan_number || ' principal');
    end if;
    if coalesce(p_interest, 0) > 0 then
      v_lines := v_lines || jsonb_build_object('account_id',
        (select id from public.chart_of_accounts where dealer_id = v_loan.dealer_id and code = '5960'),
        'debit', p_interest, 'credit', 0, 'narration', v_loan.loan_number || ' interest');
    end if;
    v_lines := v_lines || jsonb_build_object('account_id', v_bank.ledger_account_id, 'debit', 0, 'credit', v_total,
                                             'narration', 'Loan instalment');
  end if;

  v_entry := app.post_journal(v_loan.dealer_id, v_loan.branch_id, p_date, 'BANK',
    initcap(lower(p_kind)) || ' — ' || v_loan.loan_number || ' ' || v_loan.lender, v_lines,
    'LOAN', p_loan_id, case when p_idempotency_key is null then null else 'loan:' || p_idempotency_key end);

  perform app.bank_book_row(p_bank_account_id, p_date,
    case when p_kind = 'DISBURSEMENT' then 'RECEIPT' else 'PAYMENT' end, v_total,
    v_loan.loan_number || ' ' || lower(p_kind), 'LOAN', p_loan_id, v_entry);

  insert into public.loan_transactions (dealer_id, loan_id, txn_date, kind, principal, interest,
                                        bank_account_id, journal_entry_id, idempotency_key, created_by)
  values (v_loan.dealer_id, p_loan_id, p_date, p_kind, coalesce(p_principal, 0), coalesce(p_interest, 0),
          p_bank_account_id, v_entry, p_idempotency_key, auth.uid());

  if p_kind = 'REPAYMENT' and v_out - coalesce(p_principal, 0) = 0 then
    update public.loans set status = 'CLOSED' where id = p_loan_id;
  end if;

  return v_entry;
end;
$$;

create or replace function public.loan_schedule(p_loan_id uuid)
returns table (instalment integer, due_date date, emi numeric(18, 2), principal numeric(18, 2),
               interest numeric(18, 2), balance numeric(18, 2))
language plpgsql
stable
as $$
declare
  v_loan public.loans;
  v_r    numeric;
  v_emi  numeric;
  v_bal  numeric;
  v_int  numeric;
  v_pr   numeric;
  i      integer;
begin
  select * into v_loan from public.loans where id = p_loan_id;
  if v_loan.id is null then return; end if;
  v_r := v_loan.interest_rate / 100 / 12;
  v_emi := case when v_r = 0 then v_loan.principal / v_loan.tenure_months
                else v_loan.principal * v_r * power(1 + v_r, v_loan.tenure_months)
                     / (power(1 + v_r, v_loan.tenure_months) - 1) end;
  v_bal := v_loan.principal;
  for i in 1 .. v_loan.tenure_months loop
    v_int := round(v_bal * v_r, 2);
    v_pr := case when i = v_loan.tenure_months then v_bal else round(v_emi - v_int, 2) end;
    v_bal := v_bal - v_pr;
    instalment := i; due_date := (v_loan.start_date + (i || ' month')::interval)::date;
    emi := round(v_pr + v_int, 2); principal := v_pr; interest := v_int; balance := round(v_bal, 2);
    return next;
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- The tie-out learns the new registers: fixed assets at cost, accumulated
-- depreciation, and loans outstanding — each only where the register is in use.
-- -----------------------------------------------------------------------------
create or replace function app.gl_balance(p_account_id uuid, p_as_on date)
returns numeric
language sql
stable
as $$
  select coalesce(sum(l.debit - l.credit), 0)
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.account_id = p_account_id and je.status in ('POSTED', 'REVERSED') and je.entry_date <= p_as_on;
$$;

create or replace function public.register_tieout(p_as_on date default current_date)
returns table (control text, account_code text, account_name text, ledger_balance numeric(18, 4),
               subledger_balance numeric(18, 4), difference numeric(18, 4), explanation text)
language sql
stable
as $$
  with fa as (
    select a.asset_account_id as account_id, sum(a.cost) as reg
      from public.fixed_assets a
     where a.acquired_on <= p_as_on and not (a.status = 'DISPOSED' and a.disposed_on <= p_as_on)
     group by a.asset_account_id
  ),
  acc as (
    select a.accumulated_account_id as account_id,
           -sum(app.asset_accumulated(a.id, p_as_on)) as reg
      from public.fixed_assets a
     where not (a.status = 'DISPOSED' and a.disposed_on <= p_as_on)
     group by a.accumulated_account_id
  ),
  ln as (
    select l.account_id,
           -coalesce(sum(case when t.kind = 'DISBURSEMENT' then t.principal else -t.principal end), 0) as reg
      from public.loans l
      left join public.loan_transactions t on t.loan_id = l.id and t.txn_date <= p_as_on
     group by l.account_id
  ),
  rows as (
    select 'FIXED_ASSETS'::text as control, account_id, reg from fa
    union all select 'ACCUMULATED_DEPRECIATION', account_id, reg from acc
    union all select 'LOANS', account_id, reg from ln
  )
  select r.control, c.code, c.name, app.gl_balance(r.account_id, p_as_on), r.reg,
         app.gl_balance(r.account_id, p_as_on) - r.reg,
         case when app.gl_balance(r.account_id, p_as_on) = r.reg then null
              else 'The register and the ledger disagree: an asset bought or depreciated outside the register, or a loan moved by hand' end
    from rows r join public.chart_of_accounts c on c.id = r.account_id
   order by 1, 2;
$$;

comment on function public.register_tieout(date) is
  'Fixed asset register, accumulated depreciation and loans against their '
  'ledger accounts. Shown beside control_account_tieout() on the tie-out page.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.fixed_assets, public.payroll_runs, public.payroll_lines, public.loans to authenticated';
    execute 'grant select, insert on public.fixed_asset_depreciation, public.loan_transactions to authenticated';
    execute 'grant delete on public.payroll_lines to authenticated';
  end if;
end $$;

insert into public.schema_migrations (version, name)
values ('0082', 'fixed_assets_payroll_loans') on conflict (version) do nothing;
