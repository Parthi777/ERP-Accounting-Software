-- =============================================================================
-- 0026 — Reporting functions
-- =============================================================================
-- Spec §41, §43. Reports are database functions rather than application queries
-- for two reasons: aggregation belongs where the rows are, and SECURITY INVOKER
-- means RLS scopes every report to the caller's dealer and branches without the
-- report itself having to remember to filter (spec §43, "Consolidated reporting
-- must respect tenant isolation").
--
-- Rollback: drop the functions below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Trial balance — spec §41
-- -----------------------------------------------------------------------------
create or replace function public.trial_balance(
  p_as_on     date default current_date,
  p_branch_id uuid default null
)
returns table (
  account_id     uuid,
  account_code   text,
  account_name   text,
  account_type   text,
  debit_balance  numeric(18, 4),
  credit_balance numeric(18, 4)
)
language sql
stable
as $$
  select b.account_id, b.account_code, b.account_name, b.account_type,
         -- A balance shows on the side its account normally sits on; a negative
         -- balance flips to the other column rather than showing as a minus.
         case when b.closing_balance >= 0 and b.normal_balance = 'DEBIT'  then b.closing_balance
              when b.closing_balance <  0 and b.normal_balance = 'CREDIT' then -b.closing_balance
              else 0 end,
         case when b.closing_balance >= 0 and b.normal_balance = 'CREDIT' then b.closing_balance
              when b.closing_balance <  0 and b.normal_balance = 'DEBIT'  then -b.closing_balance
              else 0 end
    from public.account_balances(date '1900-01-01', p_as_on, p_branch_id) b
   where b.closing_debit <> 0 or b.closing_credit <> 0
   order by b.account_code;
$$;

comment on function public.trial_balance(date, uuid) is
  'Trial balance as at a date (spec §41). Totals are guaranteed equal because the '
  'database refuses to post an unbalanced journal.';

-- -----------------------------------------------------------------------------
-- Profit and loss — spec §41
-- -----------------------------------------------------------------------------
create or replace function public.profit_and_loss(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  section      text,
  account_code text,
  account_name text,
  amount       numeric(18, 4)
)
language sql
stable
as $$
  select case when b.account_type = 'INCOME' then 'INCOME' else 'EXPENSE' end,
         b.account_code, b.account_name, b.period_movement
    from public.account_balances(p_from, p_to, p_branch_id) b
   where b.account_type in ('INCOME', 'EXPENSE')
     and b.period_movement <> 0
   order by 1 desc, b.account_code;
$$;

comment on function public.profit_and_loss(date, date, uuid) is
  'Income and expense movement for a period (spec §41). Balance-sheet accounts are '
  'excluded: they carry cumulative balances, not period results.';

-- -----------------------------------------------------------------------------
-- Balance sheet — spec §41
-- -----------------------------------------------------------------------------
create or replace function public.balance_sheet(
  p_as_on     date default current_date,
  p_branch_id uuid default null
)
returns table (
  section      text,
  account_code text,
  account_name text,
  amount       numeric(18, 4)
)
language sql
stable
as $$
  select b.account_type, b.account_code, b.account_name, b.closing_balance
    from public.account_balances(date '1900-01-01', p_as_on, p_branch_id) b
   where b.account_type in ('ASSET', 'LIABILITY', 'EQUITY')
     and b.closing_balance <> 0
  union all
  -- Retained result to date. Without it the sheet cannot balance, because income
  -- and expense have not yet been closed into equity.
  select 'EQUITY', 'RESULT', 'Profit / (loss) to date',
         coalesce(sum(case when b.account_type = 'INCOME' then b.closing_balance
                           else -b.closing_balance end), 0)
    from public.account_balances(date '1900-01-01', p_as_on, p_branch_id) b
   where b.account_type in ('INCOME', 'EXPENSE')
  order by 1, 2;
$$;

comment on function public.balance_sheet(date, uuid) is
  'Assets, liabilities and equity as at a date (spec §41), including the retained '
  'result so the statement balances.';

-- -----------------------------------------------------------------------------
-- Vehicle stock with ageing — spec §41
-- -----------------------------------------------------------------------------
create or replace function public.vehicle_stock_report(
  p_branch_id uuid default null
)
returns table (
  vehicle_id     uuid,
  chassis_no     text,
  engine_no      text,
  brand          text,
  model_name     text,
  variant_name   text,
  branch_name    text,
  status         text,
  stock_date     date,
  age_days       integer,
  age_bucket     text,
  purchase_cost  numeric(18, 4)
)
language sql
stable
as $$
  select v.id, v.chassis_no, v.engine_no, m.brand, m.name, vr.name, b.name,
         v.status, v.stock_date,
         (current_date - v.stock_date)::integer,
         case
           when current_date - v.stock_date <=  30 then '0-30'
           when current_date - v.stock_date <=  60 then '31-60'
           when current_date - v.stock_date <=  90 then '61-90'
           when current_date - v.stock_date <= 180 then '91-180'
           else '180+'
         end,
         v.purchase_cost
    from public.vehicles v
    join public.vehicle_models m on m.id = v.model_id
    left join public.vehicle_variants vr on vr.id = v.variant_id
    join public.branches b on b.id = v.branch_id
   where v.status = 'IN_STOCK'
     and (p_branch_id is null or v.branch_id = p_branch_id)
   order by v.stock_date;
$$;

comment on function public.vehicle_stock_report(uuid) is
  'Chassis-level stock with ageing buckets (spec §41). Rows, not quantities.';

-- -----------------------------------------------------------------------------
-- Accessory and spare stock, LOCAL/COMPANY split — spec §28
-- -----------------------------------------------------------------------------
create or replace function public.inventory_stock_report(
  p_branch_id uuid default null,
  p_item_type text default null
)
returns table (
  item_id       uuid,
  item_code     text,
  item_name     text,
  item_type     text,
  branch_name   text,
  local_qty     numeric(14, 3),
  company_qty   numeric(14, 3),
  total_qty     numeric(14, 3),
  local_value   numeric(18, 4),
  company_value numeric(18, 4),
  total_value   numeric(18, 4)
)
language sql
stable
as $$
  select i.id, i.item_code, i.name, i.item_type, b.name,
         coalesce(sum(s.quantity)    filter (where s.source = 'LOCAL'), 0),
         coalesce(sum(s.quantity)    filter (where s.source = 'COMPANY'), 0),
         coalesce(sum(s.quantity), 0),
         coalesce(sum(s.stock_value) filter (where s.source = 'LOCAL'), 0),
         coalesce(sum(s.stock_value) filter (where s.source = 'COMPANY'), 0),
         coalesce(sum(s.stock_value), 0)
    from public.inventory_stock s
    join public.inventory_items i on i.id = s.item_id
    join public.branches b on b.id = s.branch_id
   where (p_branch_id is null or s.branch_id = p_branch_id)
     and (p_item_type is null or i.item_type = p_item_type)
   group by i.id, i.item_code, i.name, i.item_type, b.name
  having coalesce(sum(s.quantity), 0) <> 0
   order by i.item_code;
$$;

comment on function public.inventory_stock_report(uuid, text) is
  'Stock with the LOCAL / COMPANY split spec §28 requires displayed side by side.';

-- -----------------------------------------------------------------------------
-- Sales summary with margin — spec §41
-- -----------------------------------------------------------------------------
-- Margin is returned here; withholding it from unauthorised roles is the service
-- layer's job, because RLS cannot hide a column, only a row.
-- -----------------------------------------------------------------------------
create or replace function public.sales_summary(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null,
  p_group_by  text default 'MODEL'
)
returns table (
  group_key    text,
  group_label  text,
  unit_count   bigint,
  gross_amount numeric(18, 4),
  tax_amount   numeric(18, 4),
  cost_amount  numeric(18, 4),
  margin       numeric(18, 4)
)
language sql
stable
as $$
  select
    case p_group_by
      when 'BRANCH'   then b.id::text
      when 'EMPLOYEE' then coalesce(e.id::text, 'none')
      when 'DAY'      then s.invoice_date::text
      else m.id::text
    end,
    case p_group_by
      when 'BRANCH'   then b.name
      when 'EMPLOYEE' then coalesce(e.name, 'Unassigned')
      when 'DAY'      then to_char(s.invoice_date, 'DD Mon YYYY')
      else m.brand || ' ' || m.name
    end,
    count(*),
    sum(s.total_amount),
    sum(s.cgst_amount + s.sgst_amount + s.igst_amount + s.cess_amount),
    sum(s.total_cost),
    sum(s.taxable_value - s.total_cost)
  from public.sales s
  join public.vehicles v on v.id = s.vehicle_id
  join public.vehicle_models m on m.id = v.model_id
  join public.branches b on b.id = s.branch_id
  left join public.employees e on e.id = s.sales_executive_id
 where s.status in ('POSTED', 'DELIVERED')
   and s.invoice_date between p_from and p_to
   and (p_branch_id is null or s.branch_id = p_branch_id)
 group by 1, 2
 order by 4 desc;
$$;

comment on function public.sales_summary(date, date, uuid, text) is
  'Sales grouped by model, branch, employee or day (spec §41). Includes cost and '
  'margin; the service layer strips those for roles without permission (spec §52).';

-- -----------------------------------------------------------------------------
-- GST output summary — spec §41
-- -----------------------------------------------------------------------------
create or replace function public.gst_summary(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  hsn_code      text,
  description   text,
  taxable_value numeric(18, 4),
  cgst_amount   numeric(18, 4),
  sgst_amount   numeric(18, 4),
  igst_amount   numeric(18, 4),
  total_tax     numeric(18, 4),
  document_count bigint
)
language sql
stable
as $$
  -- Vehicle sales and service invoices carry the same tax shape, so they are
  -- unioned and grouped by HSN rather than reported separately.
  with lines as (
    select coalesce(l.hsn_code, 'UNSPECIFIED') hsn, l.taxable_value,
           l.cgst_amount, l.sgst_amount, l.igst_amount, s.id doc
      from public.sale_lines l
      join public.sales s on s.id = l.sale_id
     where s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select coalesce(l.hsn_code, 'UNSPECIFIED'), l.taxable_value,
           l.cgst_amount, l.sgst_amount, l.igst_amount, si.id
      from public.service_lines l
      join public.service_invoices si on si.id = l.invoice_id
     where si.status = 'POSTED'
       and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
  )
  select lines.hsn,
         coalesce(max(h.description), ''),
         sum(lines.taxable_value), sum(lines.cgst_amount), sum(lines.sgst_amount),
         sum(lines.igst_amount),
         sum(lines.cgst_amount + lines.sgst_amount + lines.igst_amount),
         count(distinct lines.doc)
    from lines
    left join public.hsn_codes h on h.code = lines.hsn
   group by lines.hsn
   order by lines.hsn;
$$;

comment on function public.gst_summary(date, date, uuid) is
  'HSN-wise output tax for a period (spec §41). Reads the tax stored on each line, '
  'not the current tax master, so historical figures never move (spec §16).';

-- -----------------------------------------------------------------------------
-- Customer ledger — spec §41
-- -----------------------------------------------------------------------------
create or replace function public.customer_ledger(
  p_customer_id uuid,
  p_from        date,
  p_to          date
)
returns table (
  entry_date    date,
  entry_number  text,
  narration     text,
  debit         numeric(18, 4),
  credit        numeric(18, 4),
  running_balance numeric(18, 4)
)
language sql
stable
as $$
  -- The subsidiary ledger is derived from party-tagged journal lines, so it
  -- reconciles to the receivable control account by construction.
  select je.entry_date, je.entry_number, coalesce(l.narration, je.narration),
         l.debit, l.credit,
         sum(l.debit - l.credit) over (order by je.entry_date, je.entry_number, l.line_number
                                       rows between unbounded preceding and current row)
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.party_type = 'CUSTOMER'
     and l.party_id = p_customer_id
     and je.status in ('POSTED', 'REVERSED')
     and je.entry_date between p_from and p_to
   order by je.entry_date, je.entry_number, l.line_number;
$$;

comment on function public.customer_ledger(uuid, date, date) is
  'Customer running account from the general ledger (spec §41), so the subsidiary '
  'ledger and the control account can never disagree.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.trial_balance(date, uuid) to authenticated';
    execute 'grant execute on function public.profit_and_loss(date, date, uuid) to authenticated';
    execute 'grant execute on function public.balance_sheet(date, uuid) to authenticated';
    execute 'grant execute on function public.vehicle_stock_report(uuid) to authenticated';
    execute 'grant execute on function public.inventory_stock_report(uuid, text) to authenticated';
    execute 'grant execute on function public.sales_summary(date, date, uuid, text) to authenticated';
    execute 'grant execute on function public.gst_summary(date, date, uuid) to authenticated';
    execute 'grant execute on function public.customer_ledger(uuid, date, date) to authenticated';
  end if;
end;
$$;
