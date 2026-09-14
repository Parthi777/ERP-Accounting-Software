-- =============================================================================
-- 0064 — The unit counts the dashboard has been apologising for
-- =============================================================================
-- Spec §10, §43, §59.
--
-- Seven of the dashboard's KPI tiles have been rendering dimmed, with a badge
-- naming the phase that would deliver them:
--
--   Vehicle Sales · Bookings · Deliveries · Vehicle Stock (Qty)
--   Accessories Stock (Qty) · Spare Stock (Qty) · Finance Units
--
-- Every one of those phases has shipped. The tiles were honest when written —
-- dashboard-service.ts sets out the rule that a card must not invent a number —
-- and they have been wrong for months, telling a dealer that modules they use
-- daily have not arrived. That is the same failure as a fake number, pointed the
-- other way.
--
-- ── Why the ledger could not answer ─────────────────────────────────────────
--
-- The file's own comment explains it: a journal records value, not units. Every
-- `ready` tile comes from account_balances(), which cannot say how many vehicles
-- were sold, only what they were worth. So these seven need their own aggregate,
-- and this is it — one round trip for all of them rather than seven.
--
-- Stock counts are "as at now", not "within the period". A stock figure is a
-- position, and a position has no date range: asking how much stock existed
-- between two dates is not a question with an answer. The period filter applies
-- to the four flow counts and is deliberately ignored by the three stock ones.
--
-- Rollback: drop function public.dashboard_unit_counts(date, date, uuid);
-- =============================================================================

create or replace function public.dashboard_unit_counts(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  vehicle_sales_units bigint,
  bookings            bigint,
  deliveries          bigint,
  vehicle_stock_qty   bigint,
  accessory_stock_qty numeric,
  spare_stock_qty     numeric,
  finance_units       bigint
)
language sql
stable
as $$
  select
    -- Sold, by invoice date. POSTED and DELIVERED both count: the sale is made
    -- when it is posted, and delivery is a later event with its own tile.
    (select count(*) from public.sales s
      where s.status in ('POSTED', 'DELIVERED')
        and s.invoice_date between p_from and p_to
        and (p_branch_id is null or s.branch_id = p_branch_id)),

    -- Taken, by booking date. Cancelled bookings are excluded: a dealer asking
    -- "how many bookings this month" means live ones.
    (select count(*) from public.bookings b
      where b.status <> 'CANCELLED'
        and b.booking_date between p_from and p_to
        and (p_branch_id is null or b.branch_id = p_branch_id)),

    -- Handed over, by the date of delivery rather than of the invoice — a
    -- vehicle invoiced in March and delivered in April is an April delivery.
    (select count(*) from public.sales s
      where s.status = 'DELIVERED'
        and s.delivered_at::date between p_from and p_to
        and (p_branch_id is null or s.branch_id = p_branch_id)),

    -- A position, not a flow: what is on the floor now (spec §13).
    (select count(*) from public.vehicles v
      where v.status = 'IN_STOCK'
        and (p_branch_id is null or v.branch_id = p_branch_id)),

    -- Local and company lots summed for the headline; the split stays visible
    -- on the inventory screens, which is where spec §28 requires it.
    (select coalesce(sum(st.quantity), 0) from public.inventory_stock st
      join public.inventory_items i on i.id = st.item_id
     where i.item_type = 'ACCESSORY'
       and (p_branch_id is null or st.branch_id = p_branch_id)),

    (select coalesce(sum(st.quantity), 0) from public.inventory_stock st
      join public.inventory_items i on i.id = st.item_id
     where i.item_type = 'SPARE'
       and (p_branch_id is null or st.branch_id = p_branch_id)),

    -- Financed units for the period: applications raised, excluding those the
    -- financier or the dealer withdrew.
    (select count(*) from public.finance_applications f
      where f.approval_status <> 'CANCELLED'
        and f.application_date between p_from and p_to
        and (p_branch_id is null or f.branch_id = p_branch_id));
$$;

comment on function public.dashboard_unit_counts(date, date, uuid) is
  'The seven unit counts spec §10 requires on the dashboard, which the ledger '
  'cannot answer because a journal records value and not units. Flow counts obey '
  'the period; the three stock counts are positions as at now and ignore it.';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  execute 'grant execute on function public.dashboard_unit_counts(date, date, uuid) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0064', 'dashboard_unit_counts') on conflict (version) do nothing;
