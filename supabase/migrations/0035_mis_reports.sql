-- =============================================================================
-- 0035 — MIS reports
-- =============================================================================
-- Spec §41, §43.
--
-- Every figure is derived from posted documents. Nothing here is stored, cached
-- or maintained by trigger, so a report can be wrong only if the transactions
-- behind it are wrong — which is the property that makes a report worth reading.
--
-- Cost and margin appear in these result sets. Spec §10 and §52 require them to
-- be withheld from responses for roles without permission, which the service
-- layer does with scrubRestrictedFields(); it is not this layer's job, but it is
-- this layer's reason for keeping them in named columns rather than blending
-- them into a total.
--
-- Rollback: drop the functions below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.finance_summary() — spec §41
-- -----------------------------------------------------------------------------
create or replace function public.finance_summary(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  finance_company_id   uuid,
  finance_company_name text,
  application_count    bigint,
  approved_count       bigint,
  rejected_count       bigint,
  pending_count        bigint,
  loan_amount          numeric(18, 4),
  disbursed_amount     numeric(18, 4),
  pending_disbursement numeric(18, 4),
  commission_amount    numeric(18, 4)
)
language sql
stable
as $$
  select f.id, f.name,
         count(*),
         count(*) filter (where a.approval_status = 'APPROVED'),
         count(*) filter (where a.approval_status = 'REJECTED'),
         count(*) filter (where a.approval_status = 'PENDING'),
         sum(a.loan_amount),
         sum(a.disbursed_amount),
         -- Only approved business can be pending disbursement; a rejected
         -- application is not money anyone is waiting for.
         sum(case when a.approval_status = 'APPROVED'
                  then coalesce(a.approved_amount, a.loan_amount) - a.disbursed_amount
                  else 0 end),
         sum(a.commission_amount)
    from public.finance_applications a
    join public.finance_companies f on f.id = a.finance_company_id
   where a.application_date between p_from and p_to
     and (p_branch_id is null or a.branch_id = p_branch_id)
   group by f.id, f.name
   order by sum(a.loan_amount) desc;
$$;

-- -----------------------------------------------------------------------------
-- public.branch_performance() — spec §43
-- -----------------------------------------------------------------------------
-- One row per branch, with the streams that make up its result. The subqueries
-- are deliberate: joining sales, service and bookings in one query multiplies
-- rows against each other and inflates every total.
-- -----------------------------------------------------------------------------
create or replace function public.branch_performance(
  p_from date,
  p_to   date
)
returns table (
  branch_id         uuid,
  branch_code       text,
  branch_name       text,
  vehicle_units     bigint,
  vehicle_revenue   numeric(18, 4),
  vehicle_cost      numeric(18, 4),
  vehicle_margin    numeric(18, 4),
  service_jobs      bigint,
  service_revenue   numeric(18, 4),
  service_cost      numeric(18, 4),
  bookings_open     bigint,
  booking_advances  numeric(18, 4),
  cash_in_hand      numeric(18, 4),
  receivables       numeric(18, 4)
)
language sql
stable
as $$
  select b.id, b.code, b.name,
         coalesce(s.units, 0), coalesce(s.revenue, 0), coalesce(s.cost, 0),
         coalesce(s.revenue, 0) - coalesce(s.cost, 0),
         coalesce(v.jobs, 0), coalesce(v.revenue, 0), coalesce(v.cost, 0),
         coalesce(k.open_count, 0), coalesce(k.advances, 0),
         coalesce(c.current_balance, 0),
         coalesce(s.receivable, 0) + coalesce(v.receivable, 0)
    from public.branches b
    left join lateral (
      select count(*) units,
             sum(sa.taxable_value) revenue,
             sum(sa.total_cost) cost,
             sum(sa.total_amount - sa.paid_amount) receivable
        from public.sales sa
       where sa.branch_id = b.id
         and sa.status in ('POSTED', 'DELIVERED')
         and sa.invoice_date between p_from and p_to
    ) s on true
    left join lateral (
      select count(*) jobs,
             sum(si.taxable_value) revenue,
             sum(si.total_cost) cost,
             sum(si.total_amount - si.paid_amount) receivable
        from public.service_invoices si
       where si.branch_id = b.id
         and si.status = 'POSTED'
         and si.invoice_date between p_from and p_to
    ) v on true
    left join lateral (
      select count(*) filter (where bk.status = 'OPEN') open_count,
             sum(bk.received_amount) filter (where bk.status = 'OPEN') advances
        from public.bookings bk
       where bk.branch_id = b.id
         and bk.booking_date between p_from and p_to
    ) k on true
    left join public.cash_accounts c on c.branch_id = b.id
   where b.status = 'ACTIVE'
   order by coalesce(s.revenue, 0) desc, b.name;
$$;

-- -----------------------------------------------------------------------------
-- public.margin_report() — spec §41, restricted
-- -----------------------------------------------------------------------------
-- Margin by stream, because "our margin" means something different for a vehicle
-- than for a spare part, and a blended figure hides which one is failing.
-- -----------------------------------------------------------------------------
create or replace function public.margin_report(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  stream        text,
  document_count bigint,
  revenue       numeric(18, 4),
  cost          numeric(18, 4),
  margin        numeric(18, 4),
  margin_percent numeric(8, 3)
)
language sql
stable
as $$
  with streams as (
    select 'Vehicle sales'::text as stream, count(*)::bigint as documents,
           coalesce(sum(s.taxable_value), 0) as revenue,
           coalesce(sum(s.total_cost), 0) as cost
      from public.sales s
     where s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select 'Service and parts', count(*)::bigint,
           coalesce(sum(si.taxable_value), 0), coalesce(sum(si.total_cost), 0)
      from public.service_invoices si
     where si.status = 'POSTED'
       and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
    union all
    -- Commission has no cost of its own: it is margin in full.
    select 'Finance commission', count(*)::bigint,
           coalesce(sum(a.commission_amount), 0), 0
      from public.finance_applications a
     where a.commission_amount > 0
       and a.application_date between p_from and p_to
       and (p_branch_id is null or a.branch_id = p_branch_id)
  )
  select streams.stream, streams.documents, streams.revenue, streams.cost,
         streams.revenue - streams.cost,
         case when streams.revenue > 0
              then round((streams.revenue - streams.cost) * 100 / streams.revenue, 3)
              else 0 end
    from streams
   where streams.documents > 0
   order by streams.revenue - streams.cost desc;
$$;

-- -----------------------------------------------------------------------------
-- public.consolidated_mis() — the whole dealership on one line per stream
-- -----------------------------------------------------------------------------
-- Spec §43. Sales, service, cash, bank and receivables together, so the owner
-- does not have to open five screens and add them up.
-- -----------------------------------------------------------------------------
create or replace function public.consolidated_mis(
  p_from date,
  p_to   date
)
returns table (
  metric  text,
  category text,
  value   numeric(18, 4),
  count_value bigint
)
language sql
stable
as $$
  select 'Vehicles sold', 'Sales',
         coalesce(sum(s.total_amount), 0), count(*)::bigint
    from public.sales s
   where s.status in ('POSTED', 'DELIVERED') and s.invoice_date between p_from and p_to
  union all
  select 'Service invoices', 'Service',
         coalesce(sum(si.total_amount), 0), count(*)::bigint
    from public.service_invoices si
   where si.status = 'POSTED' and si.invoice_date between p_from and p_to
  union all
  select 'Bookings taken', 'Sales',
         coalesce(sum(b.received_amount), 0), count(*)::bigint
    from public.bookings b
   where b.booking_date between p_from and p_to
  union all
  select 'Cash collected', 'Collections',
         coalesce(sum(t.amount), 0), count(*)::bigint
    from public.cash_transactions t
   where t.direction = 'RECEIPT' and t.status = 'ACTIVE'
     and t.business_date between p_from and p_to
  union all
  select 'Cash paid out', 'Collections',
         coalesce(sum(t.amount), 0), count(*)::bigint
    from public.cash_transactions t
   where t.direction = 'PAYMENT' and t.status = 'ACTIVE'
     and t.business_date between p_from and p_to
  union all
  select 'Bank receipts', 'Collections',
         coalesce(sum(t.amount), 0), count(*)::bigint
    from public.bank_transactions t
   where t.direction = 'RECEIPT' and t.status = 'ACTIVE'
     and t.transaction_date between p_from and p_to
  union all
  -- Outstanding is as at now, not for the period: a receivable does not belong
  -- to the month it was raised in once it is still owed.
  select 'Receivable outstanding', 'Position',
         coalesce(sum(s.total_amount - s.paid_amount), 0), count(*)::bigint
    from public.sales s
   where s.status in ('POSTED', 'DELIVERED') and s.total_amount > s.paid_amount
  union all
  select 'Cash in hand', 'Position',
         coalesce(sum(c.current_balance), 0), count(*)::bigint
    from public.cash_accounts c where c.status = 'ACTIVE'
  union all
  select 'Bank balance', 'Position',
         coalesce(sum(a.current_balance), 0), count(*)::bigint
    from public.bank_accounts a where a.status = 'ACTIVE'
  union all
  select 'Vehicles in stock', 'Position',
         coalesce(sum(v.purchase_cost), 0), count(*)::bigint
    from public.vehicles v where v.status = 'IN_STOCK';
$$;

-- -----------------------------------------------------------------------------
-- public.inventory_movement_report() — what moved, and why
-- -----------------------------------------------------------------------------
create or replace function public.inventory_movement_report(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  item_id        uuid,
  item_code      text,
  item_name      text,
  item_type      text,
  received_qty   numeric(14, 3),
  issued_qty     numeric(14, 3),
  received_value numeric(18, 4),
  issued_value   numeric(18, 4),
  closing_qty    numeric(14, 3),
  closing_value  numeric(18, 4)
)
language sql
stable
as $$
  select i.id, i.item_code, i.name, i.item_type,
         coalesce(sum(t.quantity) filter (where t.quantity > 0), 0),
         coalesce(-sum(t.quantity) filter (where t.quantity < 0), 0),
         coalesce(sum(t.value) filter (where t.quantity > 0), 0),
         coalesce(-sum(t.value) filter (where t.quantity < 0), 0),
         coalesce(max(s.total_qty), 0),
         coalesce(max(s.total_value), 0)
    from public.inventory_items i
    left join public.inventory_transactions t
      on t.item_id = i.id
     and t.created_at::date between p_from and p_to
     and (p_branch_id is null or t.branch_id = p_branch_id)
    left join lateral (
      select sum(st.quantity) total_qty, sum(st.stock_value) total_value
        from public.inventory_stock st
       where st.item_id = i.id
         and (p_branch_id is null or st.branch_id = p_branch_id)
    ) s on true
   group by i.id, i.item_code, i.name, i.item_type
  having coalesce(sum(abs(t.quantity)), 0) > 0 or coalesce(max(s.total_qty), 0) > 0
   order by i.name;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.finance_summary(date, date, uuid) to authenticated';
    execute 'grant execute on function public.branch_performance(date, date) to authenticated';
    execute 'grant execute on function public.margin_report(date, date, uuid) to authenticated';
    execute 'grant execute on function public.consolidated_mis(date, date) to authenticated';
    execute 'grant execute on function public.inventory_movement_report(date, date, uuid) to authenticated';
  end if;
end;
$$;
