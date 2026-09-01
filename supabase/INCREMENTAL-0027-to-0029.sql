-- =============================================================================
-- INCREMENTAL 0027 → 0029
-- =============================================================================
-- GENERATED FILE. Regenerate with:
--   FROM=0027 bash scripts/build-incremental.sh
--
-- For a database that ALREADY has migrations up to 0026.
-- Running the full ALL-IN-ONE.sql on such a database fails on the first table
-- that already exists; this contains only what is missing.
--
-- Wrapped in one transaction. If any statement fails the whole thing rolls back
-- and the database is left exactly as it was — there is no half-applied state to
-- clean up, and it is safe to fix the cause and run again.
--
-- Paste into the Supabase SQL Editor and Run.
-- =============================================================================

begin;



-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0027_default_accounting_rules.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0027 — Default accounting rules
-- =============================================================================
-- Spec §22 requires account mapping to be configuration rather than code, and
-- 0024 provides the table. But an unconfigured dealer cannot post anything: the
-- posting engine refuses rather than guessing, which is correct and also means a
-- fresh install has a sales screen that always errors.
--
-- This installs a sensible default mapping against the standard chart of accounts
-- from seed.sql, so posting works out of the box. Every rule remains editable —
-- a dealer whose chart differs simply repoints them.
--
-- Idempotent: existing rules are left alone, so a dealer who has customised a
-- mapping does not have it overwritten by a later run.
--
-- Rollback: delete from public.accounting_rules where description = 'Default mapping';
-- =============================================================================

create or replace function app.seed_default_accounting_rules(p_dealer_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_inserted integer := 0;
begin
  insert into public.accounting_rules (dealer_id, module, event, component, side, account_id, description)
  select p_dealer_id, r.module, r.event, r.component, r.side, c.id, 'Default mapping'
    from (values
      -- Vehicle sale (spec §20, §22). Each invoice component posts to its own
      -- account, which is why the price is held as components rather than a
      -- single on-road figure.
      ('SALES', 'INVOICE', 'RECEIVABLE',   'DEBIT',  '1300'),
      ('SALES', 'INVOICE', 'VEHICLE',      'CREDIT', '4100'),
      ('SALES', 'INVOICE', 'ACCESSORY',    'CREDIT', '4200'),
      ('SALES', 'INVOICE', 'FITTING',      'CREDIT', '4200'),
      ('SALES', 'INVOICE', 'SPARE',        'CREDIT', '4300'),
      ('SALES', 'INVOICE', 'LABOUR',       'CREDIT', '4400'),
      ('SALES', 'INVOICE', 'INSURANCE',    'CREDIT', '4800'),
      ('SALES', 'INVOICE', 'REGISTRATION', 'CREDIT', '4800'),
      ('SALES', 'INVOICE', 'FORWARDING',   'CREDIT', '4700'),
      ('SALES', 'INVOICE', 'OTHER_CHARGE', 'CREDIT', '4800'),
      ('SALES', 'INVOICE', 'DISCOUNT',     'DEBIT',  '4100'),
      ('SALES', 'INVOICE', 'CGST',         'CREDIT', '2300'),
      ('SALES', 'INVOICE', 'SGST',         'CREDIT', '2400'),
      ('SALES', 'INVOICE', 'IGST',         'CREDIT', '2500'),
      ('SALES', 'INVOICE', 'COGS',         'DEBIT',  '5100'),
      ('SALES', 'INVOICE', 'INVENTORY',    'CREDIT', '1500'),

      -- Booking advance (spec §18): a booking is money held, not revenue earned.
      ('BOOKING', 'ADVANCE', 'CASH',             'DEBIT',  '1100'),
      ('BOOKING', 'ADVANCE', 'BANK',             'DEBIT',  '1200'),
      ('BOOKING', 'ADVANCE', 'CUSTOMER_ADVANCE', 'CREDIT', '2100'),
      -- Applying the advance against an invoice clears the liability.
      ('BOOKING', 'APPLY',   'CUSTOMER_ADVANCE', 'DEBIT',  '2100'),
      ('BOOKING', 'APPLY',   'RECEIVABLE',       'CREDIT', '1300'),

      -- Service and counter sales (spec §32, §33).
      ('SERVICE', 'INVOICE', 'RECEIVABLE',   'DEBIT',  '1300'),
      ('SERVICE', 'INVOICE', 'LABOUR',       'CREDIT', '4400'),
      ('SERVICE', 'INVOICE', 'SPARE',        'CREDIT', '4300'),
      ('SERVICE', 'INVOICE', 'ACCESSORY',    'CREDIT', '4200'),
      ('SERVICE', 'INVOICE', 'OTHER_CHARGE', 'CREDIT', '4800'),
      ('SERVICE', 'INVOICE', 'CGST',         'CREDIT', '2300'),
      ('SERVICE', 'INVOICE', 'SGST',         'CREDIT', '2400'),
      ('SERVICE', 'INVOICE', 'IGST',         'CREDIT', '2500'),
      ('SERVICE', 'INVOICE', 'COGS',         'DEBIT',  '5300'),
      ('SERVICE', 'INVOICE', 'INVENTORY',    'CREDIT', '1700'),

      -- Cash and bank movements.
      ('CASH', 'RECEIPT', 'CASH',       'DEBIT',  '1100'),
      ('CASH', 'RECEIPT', 'RECEIVABLE', 'CREDIT', '1300'),
      ('CASH', 'PAYMENT', 'CASH',       'CREDIT', '1100'),
      ('CASH', 'PAYMENT', 'PAYABLE',    'DEBIT',  '2200'),
      ('BANK', 'RECEIPT', 'BANK',       'DEBIT',  '1200'),
      ('BANK', 'RECEIPT', 'RECEIVABLE', 'CREDIT', '1300'),
      ('BANK', 'PAYMENT', 'BANK',       'CREDIT', '1200'),
      ('BANK', 'PAYMENT', 'PAYABLE',    'DEBIT',  '2200'),

      -- Finance: disbursement settles the receivable; commission is income.
      ('FINANCE', 'DISBURSEMENT', 'BANK',               'DEBIT',  '1200'),
      ('FINANCE', 'DISBURSEMENT', 'FINANCE_RECEIVABLE', 'CREDIT', '1400'),
      ('FINANCE', 'INVOICE',      'FINANCE_RECEIVABLE', 'DEBIT',  '1400'),
      ('FINANCE', 'COMMISSION',   'BANK',               'DEBIT',  '1200'),
      ('FINANCE', 'COMMISSION',   'COMMISSION_INCOME',  'CREDIT', '4500'),

      -- Trade advance from a finance company (spec §26).
      ('TRADE_ADVANCE', 'RECEIVED',   'BANK',            'DEBIT',  '1200'),
      ('TRADE_ADVANCE', 'RECEIVED',   'FINANCE_PAYABLE', 'CREDIT', '2600'),
      ('TRADE_ADVANCE', 'ADJUSTMENT', 'FINANCE_PAYABLE', 'DEBIT',  '2600'),
      ('TRADE_ADVANCE', 'ADJUSTMENT', 'FINANCE_RECEIVABLE', 'CREDIT', '1400'),

      -- Stock receipt from a supplier.
      ('INVENTORY', 'PURCHASE', 'INVENTORY', 'DEBIT',  '1600'),
      ('INVENTORY', 'PURCHASE', 'PAYABLE',   'CREDIT', '2200'),
      ('INVENTORY', 'PURCHASE', 'VEHICLE_INVENTORY', 'DEBIT', '1500')
    ) as r(module, event, component, side, account_code)
    join public.chart_of_accounts c
      on c.dealer_id = p_dealer_id and c.code = r.account_code
   -- Leave an existing mapping alone: a dealer may have repointed it deliberately.
   where not exists (
     select 1 from public.accounting_rules ar
      where ar.dealer_id = p_dealer_id
        and ar.module = r.module and ar.event = r.event and ar.component = r.component
        and ar.branch_id is null
   );

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;

comment on function app.seed_default_accounting_rules(uuid) is
  'Installs the default account mapping for a dealer against the standard chart '
  'of accounts (spec §22). Idempotent: customised rules are never overwritten.';

-- Apply to every dealer that already exists.
do $$
declare
  d record;
  n integer;
begin
  for d in select id, code from public.dealers loop
    n := app.seed_default_accounting_rules(d.id);
    raise notice 'Dealer %: % default accounting rule(s) installed.', d.code, n;
  end loop;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function app.seed_default_accounting_rules(uuid) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0028_booking_and_sale_operations.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0028 — Public operations for bookings and sales
-- =============================================================================
-- PostgREST exposes only the `public` schema, so the engine in `app` is
-- unreachable from the application. These are the sanctioned entry points.
--
-- They are functions rather than a sequence of REST calls for the reason spec
-- §48 gives: each REST call is its own transaction, so creating a booking, its
-- receipt and its journal as three calls can leave two of the three written. A
-- booking with no journal is a receipt the books never saw.
--
-- Rollback: drop the functions below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.next_document_number() — thin wrapper over the app function
-- -----------------------------------------------------------------------------
create or replace function public.next_document_number(
  p_dealer_id      uuid,
  p_branch_id      uuid,
  p_doc_type       text,
  p_financial_year text
)
returns text
language sql
volatile
as $$
  select app.next_document_number(p_dealer_id, p_branch_id, p_doc_type, p_financial_year);
$$;

-- -----------------------------------------------------------------------------
-- public.create_booking_with_advance() — spec §18, atomically
-- -----------------------------------------------------------------------------
-- Booking, receipt and journal in one transaction. If the journal cannot post —
-- unconfigured accounts, a closed period — the booking is not created either,
-- so there is never a receipt the ledger does not know about.
-- -----------------------------------------------------------------------------
create or replace function public.create_booking_with_advance(
  p_customer_id       uuid,
  p_model_id          uuid,
  p_branch_id         uuid,
  p_booking_amount    numeric,
  p_advance_amount    numeric,
  p_payment_mode      text,
  p_variant_id        uuid default null,
  p_vehicle_id        uuid default null,
  p_expected_delivery date default null,
  p_sales_executive_id uuid default null,
  p_reference         text default null,
  p_notes             text default null
)
returns table (booking_id uuid, booking_number text, receipt_number text, journal_entry_id uuid)
language plpgsql
as $$
declare
  v_dealer_id uuid;
  v_year      text;
  v_booking   uuid;
  v_bnumber   text;
  v_rnumber   text;
  v_entry     uuid;
  v_debit_acc uuid;
  v_credit_acc uuid;
  v_cash_component text;
begin
  if p_advance_amount <= 0 then
    raise exception 'The advance amount must be greater than zero.'
      using errcode = 'check_violation';
  end if;
  if p_booking_amount > 0 and p_advance_amount > p_booking_amount then
    raise exception 'The advance cannot exceed the booking amount.'
      using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer_id from public.branches where id = p_branch_id;
  if v_dealer_id is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  v_year := app.financial_year_token(v_dealer_id, current_date);

  -- Resolve accounts before writing anything: an unconfigured mapping should
  -- fail before a booking number is consumed.
  v_cash_component := case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end;
  v_debit_acc  := app.require_account(v_dealer_id, 'BOOKING', 'ADVANCE', v_cash_component, p_branch_id);
  v_credit_acc := app.require_account(v_dealer_id, 'BOOKING', 'ADVANCE', 'CUSTOMER_ADVANCE', p_branch_id);

  v_bnumber := app.next_document_number(v_dealer_id, p_branch_id, 'BOOKING', v_year);
  v_rnumber := app.next_document_number(v_dealer_id, p_branch_id, 'RECEIPT', v_year);

  insert into public.bookings
    (dealer_id, branch_id, booking_number, customer_id, model_id, variant_id, vehicle_id,
     booking_amount, expected_delivery, sales_executive_id, notes, created_by)
  values
    (v_dealer_id, p_branch_id, v_bnumber, p_customer_id, p_model_id, p_variant_id, p_vehicle_id,
     p_booking_amount, p_expected_delivery, p_sales_executive_id, p_notes, auth.uid())
  returning id into v_booking;

  -- Spec §18: the advance is a liability until the sale is raised.
  v_entry := app.post_journal(
    v_dealer_id, p_branch_id, current_date, 'BOOKING',
    'Booking advance ' || v_bnumber,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit_acc, 'debit', p_advance_amount, 'credit', 0,
                         'narration', p_payment_mode || ' received'),
      jsonb_build_object('account_id', v_credit_acc, 'debit', 0, 'credit', p_advance_amount,
                         'narration', 'Customer advance',
                         'party_type', 'CUSTOMER', 'party_id', p_customer_id)
    ),
    'BOOKING', v_booking, 'booking:' || v_booking::text
  );

  insert into public.booking_payments
    (dealer_id, booking_id, receipt_number, amount, payment_mode, reference, journal_entry_id, created_by)
  values
    (v_dealer_id, v_booking, v_rnumber, p_advance_amount, p_payment_mode, p_reference, v_entry, auth.uid());

  -- Reserving a specific chassis takes it out of available stock (spec §13).
  if p_vehicle_id is not null then
    update public.vehicles set status = 'BOOKED', updated_by = auth.uid()
     where id = p_vehicle_id and status = 'IN_STOCK';
  end if;

  booking_id := v_booking; booking_number := v_bnumber;
  receipt_number := v_rnumber; journal_entry_id := v_entry;
  return next;
end;
$$;

comment on function public.create_booking_with_advance is
  'Creates a booking, its advance receipt and the journal in one transaction '
  '(spec §18). Any failure leaves none of the three.';

-- -----------------------------------------------------------------------------
-- public.record_sale_payment() — a receipt against an invoice
-- -----------------------------------------------------------------------------
create or replace function public.record_sale_payment(
  p_sale_id      uuid,
  p_amount       numeric,
  p_payment_mode text,
  p_reference    text default null,
  p_finance_company_id uuid default null
)
returns table (receipt_number text, journal_entry_id uuid)
language plpgsql
as $$
declare
  v_sale     public.sales;
  v_year     text;
  v_rnumber  text;
  v_entry    uuid;
  v_debit    uuid;
  v_credit   uuid;
  v_component text;
begin
  if p_amount <= 0 then
    raise exception 'The payment amount must be greater than zero.' using errcode = 'check_violation';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;
  if v_sale.id is null then
    raise exception 'Sale not found.' using errcode = 'no_data_found';
  end if;
  if v_sale.status not in ('POSTED', 'DELIVERED') then
    raise exception 'Payments can only be recorded against a posted invoice; this one is %.', v_sale.status
      using errcode = 'check_violation';
  end if;

  v_year := app.financial_year_token(v_sale.dealer_id, current_date);
  v_rnumber := app.next_document_number(v_sale.dealer_id, v_sale.branch_id, 'RECEIPT', v_year);

  -- Finance disbursement moves the debt to the finance company rather than
  -- settling it in cash (spec §27).
  if p_payment_mode = 'FINANCE' then
    v_component := 'FINANCE_RECEIVABLE';
    v_debit  := app.require_account(v_sale.dealer_id, 'FINANCE', 'INVOICE', 'FINANCE_RECEIVABLE', v_sale.branch_id);
  else
    v_component := case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end;
    v_debit := app.require_account(
      v_sale.dealer_id,
      case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
      'RECEIPT', v_component, v_sale.branch_id);
  end if;

  v_credit := app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'RECEIVABLE', v_sale.branch_id);

  v_entry := app.post_journal(
    v_sale.dealer_id, v_sale.branch_id, current_date,
    case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
    'Receipt ' || v_rnumber || ' against ' || v_sale.invoice_number,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', p_payment_mode || ' received'),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', 'Against ' || v_sale.invoice_number,
                         'party_type', 'CUSTOMER', 'party_id', v_sale.customer_id)
    ),
    'SALE_PAYMENT', p_sale_id, 'receipt:' || v_rnumber
  );

  insert into public.sale_payments
    (dealer_id, sale_id, receipt_number, amount, payment_mode, reference,
     finance_company_id, journal_entry_id, created_by)
  values
    (v_sale.dealer_id, p_sale_id, v_rnumber, p_amount, p_payment_mode, p_reference,
     p_finance_company_id, v_entry, auth.uid());

  receipt_number := v_rnumber; journal_entry_id := v_entry;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.deliver_vehicle() — spec §19, the final step
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
  v_number := app.next_document_number(v_sale.dealer_id, v_sale.branch_id, 'STOCK_TRANSFER', v_year);

  insert into public.deliveries
    (dealer_id, branch_id, sale_id, vehicle_id, delivery_number,
     delivered_by, received_by_name, odometer, remarks)
  values
    (v_sale.dealer_id, v_sale.branch_id, p_sale_id, v_sale.vehicle_id, v_number,
     auth.uid(), p_received_by, p_odometer, p_remarks);

  update public.vehicles set status = 'DELIVERED', updated_by = auth.uid()
   where id = v_sale.vehicle_id;

  update public.sales set status = 'DELIVERED', delivered_by = auth.uid()
   where id = p_sale_id;

  return v_number;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.next_document_number(uuid, uuid, text, text) to authenticated';
    execute 'grant execute on function public.create_booking_with_advance(uuid, uuid, uuid, numeric, numeric, text, uuid, uuid, date, uuid, text, text) to authenticated';
    execute 'grant execute on function public.record_sale_payment(uuid, numeric, text, text, uuid) to authenticated';
    execute 'grant execute on function public.deliver_vehicle(uuid, text, numeric, text) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0029_create_sale_draft.sql
-- ═══════════════════════════════════════════════════════════════════════════

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


commit;
