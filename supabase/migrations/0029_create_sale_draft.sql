-- =============================================================================
-- 0029 — Drafting a vehicle sale
-- =============================================================================
-- Spec §19, §20, §42.
--
-- Builds a DRAFT invoice from the price version in force on the invoice date, one
-- line per price component. Header and lines are created together: a header with
-- no lines totals zero and looks like a real invoice for nothing.
--
-- The price version id is stored on the sale, so the invoice stays explainable
-- after ten more price changes (spec §42).
--
-- Rollback: drop function public.create_vehicle_sale_draft(...);
-- =============================================================================

create or replace function public.create_vehicle_sale_draft(
  p_customer_id  uuid,
  p_vehicle_id   uuid,
  p_invoice_date date default current_date,
  p_booking_id   uuid default null,
  p_sales_executive_id uuid default null,
  p_discount     numeric default 0,
  p_notes        text default null
)
returns table (sale_id uuid, invoice_number text, total_amount numeric)
language plpgsql
as $$
declare
  v_vehicle  public.vehicles;
  v_price    record;
  v_tax      record;
  v_dealer   uuid;
  v_year     text;
  v_number   text;
  v_sale     uuid;
  v_line     smallint := 0;
  v_hsn      text;
  v_model_tax text;
begin
  select * into v_vehicle from public.vehicles where id = p_vehicle_id for update;

  if v_vehicle.id is null then
    raise exception 'Vehicle not found.' using errcode = 'no_data_found';
  end if;
  if v_vehicle.status not in ('IN_STOCK', 'BOOKED') then
    raise exception 'Vehicle % is % and is not available for sale.', v_vehicle.chassis_no, v_vehicle.status
      using errcode = 'check_violation';
  end if;

  v_dealer := v_vehicle.dealer_id;

  -- The price in force on the invoice date, not today's price (spec §42).
  select * into v_price
    from public.resolve_vehicle_price(v_dealer, v_vehicle.model_id, v_vehicle.variant_id,
                                      v_vehicle.branch_id, p_invoice_date);

  if v_price.price_version_id is null then
    raise exception 'No price is configured for this model on %.', p_invoice_date
      using errcode = 'no_data_found',
            hint = 'Add a price version before selling this model.';
  end if;

  select m.tax_code, h.code into v_model_tax, v_hsn
    from public.vehicle_models m
    left join public.hsn_codes h on h.id = m.hsn_code_id
   where m.id = v_vehicle.model_id;

  select * into v_tax
    from public.resolve_tax_code(v_dealer, coalesce(v_price.tax_code, v_model_tax), p_invoice_date);

  v_year := app.financial_year_token(v_dealer, p_invoice_date);
  v_number := app.next_document_number(v_dealer, v_vehicle.branch_id, 'VEHICLE_INVOICE', v_year);

  insert into public.sales
    (dealer_id, branch_id, invoice_number, invoice_date, customer_id, vehicle_id,
     booking_id, price_version_id, sales_executive_id, notes, created_by)
  values
    (v_dealer, v_vehicle.branch_id, v_number, p_invoice_date, p_customer_id, p_vehicle_id,
     p_booking_id, v_price.price_version_id, p_sales_executive_id, p_notes, auth.uid())
  returning id into v_sale;

  -- ── One line per price component (spec §20) ───────────────────────────────
  -- Only the vehicle itself carries GST here; insurance and registration are
  -- pass-through in most dealer setups, and forwarding is taxed separately by
  -- configuration. A dealer whose treatment differs edits the lines before
  -- submitting, which is why the invoice is a draft first.
  if v_price.ex_showroom > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, hsn_code, quantity, unit_rate,
       taxable_value, tax_code, cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount,
       unit_cost, cost_amount)
    values
      (v_sale, v_dealer, v_line, 'VEHICLE',
       coalesce((select m.brand || ' ' || m.name from public.vehicle_models m where m.id = v_vehicle.model_id), 'Vehicle'),
       v_hsn, 1, v_price.ex_showroom, v_price.ex_showroom,
       v_tax.code, coalesce(v_tax.cgst_rate, 0), coalesce(v_tax.sgst_rate, 0),
       round(v_price.ex_showroom * coalesce(v_tax.cgst_rate, 0) / 100, 2),
       round(v_price.ex_showroom * coalesce(v_tax.sgst_rate, 0) / 100, 2),
       v_price.ex_showroom
         + round(v_price.ex_showroom * coalesce(v_tax.cgst_rate, 0) / 100, 2)
         + round(v_price.ex_showroom * coalesce(v_tax.sgst_rate, 0) / 100, 2),
       -- COGS uses what this specific unit cost, not the price master's figure.
       v_vehicle.purchase_cost, v_vehicle.purchase_cost);
  end if;

  if v_price.insurance > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'INSURANCE', 'Insurance', 1,
            v_price.insurance, v_price.insurance, v_price.insurance);
  end if;

  if v_price.registration > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'REGISTRATION', 'Registration (LTRT)', 1,
            v_price.registration, v_price.registration, v_price.registration);
  end if;

  if v_price.mandatory_accessories > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'ACCESSORY', 'Mandatory accessories', 1,
            v_price.mandatory_accessories, v_price.mandatory_accessories, v_price.mandatory_accessories);
  end if;

  if v_price.forwarding_charge > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'FORWARDING', 'Forwarding charges', 1,
            v_price.forwarding_charge, v_price.forwarding_charge, v_price.forwarding_charge);
  end if;

  if v_price.other_charges > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'OTHER_CHARGE', 'Other charges', 1,
            v_price.other_charges, v_price.other_charges, v_price.other_charges);
  end if;

  -- A discount beyond what the price version permits is a policy breach, not a
  -- rounding difference (spec §15).
  if p_discount > 0 then
    if p_discount > v_price.max_discount then
      raise exception 'A discount of % exceeds the maximum of % allowed on this price version.',
        p_discount, v_price.max_discount
        using errcode = 'check_violation';
    end if;
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       discount, taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'DISCOUNT', 'Discount', 1, 0, p_discount, 0, 0);
  end if;

  -- Reserve the chassis so no other draft can claim it (spec §49).
  if v_vehicle.status = 'IN_STOCK' then
    update public.vehicles set status = 'BOOKED', updated_by = auth.uid() where id = p_vehicle_id;
  end if;

  -- Converting a booking closes it.
  if p_booking_id is not null then
    update public.bookings
       set status = 'CONVERTED', converted_sale_id = v_sale, updated_by = auth.uid()
     where id = p_booking_id and status = 'OPEN';
  end if;

  sale_id := v_sale;
  invoice_number := v_number;
  select s.total_amount into total_amount from public.sales s where s.id = v_sale;
  return next;
end;
$$;

comment on function public.create_vehicle_sale_draft is
  'Builds a DRAFT invoice from the price version in force on the invoice date '
  '(spec §19, §20, §42). Header and lines are created together.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.create_vehicle_sale_draft(uuid, uuid, date, uuid, uuid, numeric, text) to authenticated';
  end if;
end;
$$;
