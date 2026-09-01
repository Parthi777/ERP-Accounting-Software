-- =============================================================================
-- 0045 — Somebody has to write customer_vehicles
-- =============================================================================
-- Spec §11, §32, §33.
--
-- customer_vehicles has existed since 0023 with no writer anywhere in the
-- codebase: job cards carry a free-text registration and never link to it, and
-- delivery never records that a customer now owns the unit. The table has always
-- been empty, so "which vehicles does this customer own" and "what is this
-- vehicle's service history" could not be answered at all.
--
-- Two writers, at the two moments ownership becomes a fact:
--   * delivery — the dealer sold it, so everything about it is known;
--   * a job card for a walk-in — the dealer did not sell it, but the workshop
--     now knows the registration, so the record starts from there.
--
-- Rollback: restore public.deliver_vehicle() from 0038 and public.create_job_card()
--           from 0033, drop index cv_vehicle_key, restore policy cv_write from
--           0023, and drop public.customer_service_summary(uuid, uuid).
-- =============================================================================

-- A vehicle has one current owner. Needed as an ON CONFLICT target, and it makes
-- a resold unit update to the new owner rather than accumulate rows.
create unique index if not exists cv_vehicle_key
  on public.customer_vehicles (vehicle_id) where vehicle_id is not null;

-- -----------------------------------------------------------------------------
-- The writer needs to be allowed to write
-- -----------------------------------------------------------------------------
-- cv_write is FOR ALL, so its USING clause governs the UPDATE half of an upsert.
-- It admitted customers.edit and service.jobcards.create — neither of which a
-- delivery clerk holds — so re-delivering a unit to a new owner would fail on
-- the conflict path while a first delivery succeeded. Adding sales.deliver makes
-- both work.
-- -----------------------------------------------------------------------------
drop policy if exists cv_write on public.customer_vehicles;

create policy cv_write on public.customer_vehicles for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('customers.edit')
                  or app.has_permission('service.jobcards.create')
                  or app.has_permission('sales.deliver'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

-- -----------------------------------------------------------------------------
-- public.deliver_vehicle() — spec §19, now recording ownership
-- -----------------------------------------------------------------------------
create or replace function public.deliver_vehicle(
  p_sale_id      uuid,
  p_received_by  text default null,
  p_odometer     numeric default null,
  p_remarks      text default null
)
returns text
language plpgsql
as $$
declare
  v_sale    public.sales;
  v_year    text;
  v_number  text;
begin
  select * into v_sale from public.sales where id = p_sale_id for update;

  if v_sale.id is null then
    raise exception 'Sale not found.' using errcode = 'no_data_found';
  end if;
  if v_sale.status <> 'POSTED' then
    raise exception 'Only a POSTED sale can be delivered; this one is %.', v_sale.status
      using errcode = 'check_violation';
  end if;

  v_year := app.financial_year_token(v_sale.dealer_id, current_date);
  v_number := app.next_document_number(v_sale.dealer_id, null, 'DELIVERY', v_year);

  insert into public.deliveries
    (dealer_id, branch_id, sale_id, vehicle_id, delivery_number,
     delivered_by, received_by_name, odometer, remarks)
  values
    (v_sale.dealer_id, v_sale.branch_id, p_sale_id, v_sale.vehicle_id, v_number,
     auth.uid(), p_received_by, p_odometer, p_remarks);

  -- The customer now owns this unit. Recorded here because delivery is the
  -- moment it becomes true, and everything needed is already known.
  insert into public.customer_vehicles
    (dealer_id, customer_id, vehicle_id, model_id, variant_id,
     chassis_no, engine_no, registration_no, purchase_date, status)
  select v_sale.dealer_id, v_sale.customer_id, v.id, v.model_id, v.variant_id,
         v.chassis_no, v.engine_no, v.registration_no, current_date, 'ACTIVE'
    from public.vehicles v
   where v.id = v_sale.vehicle_id
  on conflict (vehicle_id) where vehicle_id is not null
  do update set customer_id = excluded.customer_id,
                registration_no = coalesce(excluded.registration_no, public.customer_vehicles.registration_no),
                status = 'ACTIVE',
                updated_at = now();

  update public.vehicles set status = 'DELIVERED', updated_by = auth.uid()
   where id = v_sale.vehicle_id;

  update public.sales set status = 'DELIVERED', delivered_by = auth.uid()
   where id = p_sale_id;

  return v_number;
end;
$$;

comment on function public.deliver_vehicle(uuid, text, numeric, text) is
  'Records the handover, closes the sale and registers the customer as the '
  'vehicle''s owner (spec §19, §11).';

-- -----------------------------------------------------------------------------
-- public.create_job_card() — spec §32, now linking the vehicle
-- -----------------------------------------------------------------------------
create or replace function public.create_job_card(
  p_branch_id       uuid,
  p_customer_id     uuid,
  p_service_type    text default 'PAID',
  p_registration_no text default null,
  p_odometer        numeric default null,
  p_complaint       text default null,
  p_customer_vehicle_id uuid default null,
  p_service_advisor_id  uuid default null,
  p_technician_id       uuid default null,
  p_promised_at     timestamptz default null,
  p_job_date        date default current_date
)
returns table (job_card_id uuid, job_card_number text)
language plpgsql
as $$
declare
  v_dealer uuid;
  v_number text;
  v_id     uuid;
  v_reg    text;
  v_cv     uuid := p_customer_vehicle_id;
begin
  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  v_number := app.next_document_number(
    v_dealer, p_branch_id, 'JOB_CARD', app.financial_year_token(v_dealer, p_job_date));

  v_reg := nullif(upper(btrim(p_registration_no)), '');

  -- A walk-in the dealer never sold still has a vehicle, and the workshop now
  -- knows its registration. Registering it here is what lets the second visit
  -- find the first. cv_registration_key is partial, so ON CONFLICT has to repeat
  -- its predicate or Postgres will not match the index.
  if v_cv is null and v_reg is not null then
    insert into public.customer_vehicles
      (dealer_id, customer_id, registration_no, status)
    values (v_dealer, p_customer_id, v_reg, 'ACTIVE')
    on conflict (dealer_id, registration_no) where registration_no is not null
    do update set customer_id = excluded.customer_id, updated_at = now()
    returning id into v_cv;
  end if;

  insert into public.job_cards
    (dealer_id, branch_id, job_card_number, job_date, customer_id, customer_vehicle_id,
     registration_no, odometer, service_type, complaint, service_advisor_id, technician_id,
     promised_at, created_by)
  values
    (v_dealer, p_branch_id, v_number, p_job_date, p_customer_id, v_cv,
     v_reg, p_odometer, p_service_type, p_complaint,
     p_service_advisor_id, p_technician_id, p_promised_at, auth.uid())
  returning id into v_id;

  job_card_id := v_id; job_card_number := v_number;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.customer_service_summary() — spec §33
-- -----------------------------------------------------------------------------
-- A rollup per customer, not per visit. /service/history already answers "what
-- happened on this job"; the question this answers is "who has stopped coming,
-- and who is worth the most", which no per-visit list makes visible.
-- -----------------------------------------------------------------------------
create or replace function public.customer_service_summary(
  p_customer_id uuid default null,
  p_branch_id   uuid default null
)
returns table (
  customer_id     uuid,
  customer_code   text,
  customer_name   text,
  mobile          text,
  vehicle_count   int,
  visit_count     int,
  first_visit     date,
  last_visit      date,
  days_since_last int,
  lifetime_value  numeric(18, 4),
  open_jobs       int
)
language sql
stable
as $$
  select c.id, c.customer_code, c.name, c.mobile,
         (select count(*)::int from public.customer_vehicles cv
           where cv.customer_id = c.id and cv.status = 'ACTIVE'),
         count(distinct j.id)::int,
         min(j.job_date),
         max(j.job_date),
         (current_date - max(j.job_date))::int,
         coalesce(sum(i.total_amount), 0)::numeric(18, 4),
         count(distinct j.id) filter (where j.status in ('OPEN', 'IN_PROGRESS', 'READY'))::int
    from public.customers c
    join public.job_cards j on j.customer_id = c.id
    left join public.service_invoices i
      on i.job_card_id = j.id and i.status <> 'CANCELLED'
   where (p_customer_id is null or c.id = p_customer_id)
     and (p_branch_id is null or j.branch_id = p_branch_id)
   group by c.id, c.customer_code, c.name, c.mobile
   order by max(j.job_date) desc;
$$;

comment on function public.customer_service_summary(uuid, uuid) is
  'Per-customer service rollup (spec §33): visits, lifetime value and how long '
  'since the last one, for spotting customers who have stopped coming.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.customer_service_summary(uuid, uuid) to authenticated';
  end if;
end;
$$;
