-- =============================================================================
-- 0047 — Counter sales
-- =============================================================================
-- Spec §33.
--
-- The last module of the specification with no implementation. Everything around
-- it has been in place since 0023: service_invoices.invoice_type accepts
-- 'COUNTER', si_job_card_check requires such an invoice to have no job card, the
-- COUNTER_INVOICE sequence is seeded, and inventory.counter_sale.create exists.
-- What was missing is the one function that starts the invoice — so the sequence
-- and the permission have never been used by anything.
--
-- Almost nothing new is needed, because a counter sale IS a service invoice
-- without a job card:
--   * add_service_line() already allocates stock LOCAL-before-COMPANY and
--     refuses to oversell (spec §31, §33);
--   * post_service_invoice() already posts revenue, GST, COGS and stock relief,
--     and already guards its job-card update with `if job_card_id is not null`,
--     so it works here unchanged;
--   * record_service_payment() already collects against it.
--
-- Reusing them is the point: a second billing engine for counter sales would be
-- a second place for the accounting to be wrong (spec §60.18).
--
-- Rollback: drop function public.create_counter_invoice(uuid, uuid, date); restore
--           policies si_write and sl_write from 0023; delete the
--           counter_sale.require_customer setting.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.create_counter_invoice() — spec §33
-- -----------------------------------------------------------------------------
-- The customer is optional by configuration. A walk-in buying a helmet for cash
-- is not worth a customer record, but a dealer who wants every sale attributable
-- turns the setting on and the invoice refuses to start without one.
-- -----------------------------------------------------------------------------
create or replace function public.create_counter_invoice(
  p_branch_id    uuid,
  p_customer_id  uuid default null,
  p_invoice_date date default current_date
)
returns table (invoice_id uuid, invoice_number text)
language plpgsql
as $$
declare
  v_dealer   uuid;
  v_number   text;
  v_id       uuid;
  v_required boolean;
begin
  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  select coalesce((value)::text = 'true', false) into v_required
    from public.system_settings
   where key = 'counter_sale.require_customer'
     and (dealer_id = v_dealer or dealer_id is null)
   order by dealer_id nulls last
   limit 1;

  if coalesce(v_required, false) and p_customer_id is null then
    raise exception 'This dealer requires a customer on every counter sale.'
      using errcode = 'check_violation',
            hint = 'Spec §33: the customer is optional or required by configuration.';
  end if;

  v_number := app.next_document_number(
    v_dealer, p_branch_id, 'COUNTER_INVOICE',
    app.financial_year_token(v_dealer, p_invoice_date));

  insert into public.service_invoices
    (dealer_id, branch_id, invoice_number, invoice_date, invoice_type,
     job_card_id, customer_id, created_by)
  values
    (v_dealer, p_branch_id, v_number, p_invoice_date, 'COUNTER',
     null, p_customer_id, auth.uid())
  returning id into v_id;

  invoice_id := v_id; invoice_number := v_number;
  return next;
end;
$$;

comment on function public.create_counter_invoice(uuid, uuid, date) is
  'Opens an over-the-counter invoice for accessories and spares (spec §33). '
  'Lines, posting and payment reuse the service billing engine, so there is one '
  'accounting path rather than two (spec §60.18).';

-- -----------------------------------------------------------------------------
-- The counter clerk has to be allowed to bill
-- -----------------------------------------------------------------------------
-- si_write and sl_write are FOR ALL and admitted only service.billing.create.
-- That governs the UPDATE half too, and posting an invoice updates it — so a
-- clerk holding inventory.counter_sale.create could have opened a counter
-- invoice and then been refused when posting it.
-- -----------------------------------------------------------------------------
drop policy if exists si_write on public.service_invoices;

create policy si_write on public.service_invoices for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('service.billing.create')
                  or app.has_permission('inventory.counter_sale.create'))))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('service.billing.create')
                  or app.has_permission('inventory.counter_sale.create'))));

drop policy if exists sl_write on public.service_lines;

create policy sl_write on public.service_lines for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('service.billing.create')
                  or app.has_permission('inventory.counter_sale.create'))))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('service.billing.create')
                  or app.has_permission('inventory.counter_sale.create'))));

-- Default: optional, which is how most counters run.
insert into public.system_settings (dealer_id, key, value, value_type, description, is_public)
select d.id, 'counter_sale.require_customer', 'false'::jsonb, 'boolean',
       'Require a customer on every counter sale (spec §33).', true
  from public.dealers d
on conflict on constraint system_settings_scope_key do nothing;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.create_counter_invoice(uuid, uuid, date) to authenticated';
  end if;
end;
$$;
