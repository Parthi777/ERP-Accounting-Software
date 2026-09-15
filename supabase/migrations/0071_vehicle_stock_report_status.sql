-- =============================================================================
-- 0071 — The inventory report, which has been returning 500
-- =============================================================================
-- Spec §41, §55.
--
-- reports-service.ts calls vehicle_stock_report with p_branch_id *and*
-- p_status. The function has only ever taken p_branch_id, so PostgREST cannot
-- resolve it and answers:
--
--   Could not find the function public.vehicle_stock_report(p_branch_id, p_status)
--   in the schema cache
--
-- which the page turns into a 500. Every time — the caller sends p_status even
-- when it is null, so the signature never matched and the vehicles view of
-- Inventory Reports has never rendered.
--
-- Nothing caught it. The database tests exercise the function directly with the
-- signature it has; the TypeScript types describe that signature correctly and
-- supabase-js does not enforce the argument object against it. It took opening
-- the page in a browser, which until now nothing did.
--
-- The screen's intent is plain — it asks for status 'IN_STOCK' — and the old
-- body hard-coded exactly that. So the filter becomes a parameter and keeps
-- IN_STOCK as its default behaviour when none is given.
--
-- Rollback: restore vehicle_stock_report from 0026 and drop p_status from the
-- caller.
-- =============================================================================

-- A parameter cannot be added with `create or replace`: a different argument
-- list makes an overload, and supabase-js sends named arguments, so a call would
-- then be ambiguous across the two (PGRST203).
drop function if exists public.vehicle_stock_report(uuid);

create function public.vehicle_stock_report(
  p_branch_id uuid default null,
  -- Null means every status, which is what a stock *report* should be able to
  -- show: a vehicle that is BOOKED or SOLD_PENDING_DELIVERY is still on the
  -- floor and still the dealer's until it is delivered.
  p_status    text default null
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
   where (p_status is null or v.status = p_status)
     and (p_branch_id is null or v.branch_id = p_branch_id)
   order by v.stock_date;
$$;

comment on function public.vehicle_stock_report(uuid, text) is
  'Chassis-level stock with ageing buckets (spec §41). Rows, not quantities. '
  'A null status returns every vehicle: BOOKED and SOLD_PENDING_DELIVERY units '
  'are still on the floor and still the dealer''s.';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  -- Per-signature, and the old one went with the drop.
  execute 'grant execute on function public.vehicle_stock_report(uuid, text) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0071', 'vehicle_stock_report_status') on conflict (version) do nothing;
