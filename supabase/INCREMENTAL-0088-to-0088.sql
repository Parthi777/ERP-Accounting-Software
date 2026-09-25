-- =============================================================================
-- INCREMENTAL 0088 → 0088
-- =============================================================================
-- GENERATED FILE. Regenerate with:
--   FROM=0088 bash scripts/build-incremental.sh
--
-- For a database that ALREADY has migrations up to 0087.
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
-- SOURCE: supabase/migrations/0088_quick_billing_and_cashier_scope.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0088 — Quick service and counter bills; the cashier's scope
-- =============================================================================
-- Spec §6, §32, §33, §36. Raised by the dealer:
--
--   "service billing only needs customer name, vehicle no and mobile no; if
--    anyone matches previous customer data, map it to that customer. In service
--    billing there is no deep data — they only enter spares value, labour
--    value, waterwash value and other consumables value."
--
--   "in counter sales remove the spares stock; the cashier only enters the cash
--    value of the product and types the product name."
--
--   "cashiers can only enter sales, receipts and payments; journals are only
--    edited by the accountant; cashiers see only their own location."
--
-- ── A bill in one step ─────────────────────────────────────────────────────
--
-- create_quick_bill() takes the customer's name, mobile and vehicle number,
-- a value for each head, and the money received, and in one transaction:
--
--   finds the customer — by mobile, else by vehicle number — or creates one,
--     and remembers the vehicle against them;
--   opens a service or counter invoice (no job card, no item, no stock);
--   splits each value into taxable value and GST at the rate configured for
--     that head (the value typed is what the customer pays: GST-inclusive);
--   posts it — revenue by head, output GST, the customer's receivable;
--   records the payment and returns the receipt number for printing.
--
-- Heads and where they post:
--   SPARES → 4300 Spare Sales        ACCESSORIES → 4200 Accessories Sales
--   LABOUR → 4400 Service Labour     WATERWASH   → 4410 Waterwash Income (new)
--   CONSUMABLES → 4420 Consumables Sales (new)     OTHER → 4800 Other Income
--
-- The tax code per head is the dealer setting quick_bill.tax_codes (default
-- GST18 for every head), so a rate change is configuration, not code.
--
-- Counter and service lines carry no item, so no stock moves and no cost of
-- sales is booked: stock and cost are corrected by the accountant's periodic
-- count, as the dealer decided. (Stock-item lines on older bills are
-- unaffected.)
--
-- ── Service without job cards ──────────────────────────────────────────────
--
-- A service invoice no longer needs a job card; it carries the vehicle number
-- itself (service_invoices.vehicle_registration).
--
-- ── The cashier ────────────────────────────────────────────────────────────
--
-- CASHIER holds exactly: customers (find, add, see balance), bookings, vehicle
-- sales (draft and submit), service and counter bills with payment, and cash
-- receipts and payments. No journals, no inventory, no reports. Branch
-- isolation is the existing can_access_branch() (a cashier is given one
-- branch and not all-branch access). Billing users may now read the bills and
-- payments they make without needing job-card or inventory permissions.
--
-- Rollback: drop create_quick_bill(), app.match_or_create_customer(); restore
--           si_job_card_shape_check, sl_type_check and the select policies from
--           0023/0047; restore the CASHIER grants from seed.sql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Service invoices without a job card; two new heads
-- -----------------------------------------------------------------------------
alter table public.service_invoices
  add column if not exists vehicle_registration text;

alter table public.service_invoices drop constraint si_job_card_shape_check;
alter table public.service_invoices add constraint si_job_card_shape_check
  check (invoice_type = 'SERVICE' or job_card_id is null);

alter table public.service_lines drop constraint sl_type_check;
alter table public.service_lines add constraint sl_type_check
  check (line_type in ('LABOUR', 'SPARE', 'ACCESSORY', 'OTHER_CHARGE', 'DISCOUNT', 'WATERWASH', 'CONSUMABLES'));

create index if not exists si_vehicle_registration_idx
  on public.service_invoices (dealer_id, vehicle_registration) where vehicle_registration is not null;

-- -----------------------------------------------------------------------------
-- Accounts and rules for the new heads
-- -----------------------------------------------------------------------------
create or replace function app.seed_quick_bill_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
declare
  v_added integer := 0;
  a       record;
begin
  for a in select * from (values
      ('4410', 'Waterwash Income'),
      ('4420', 'Consumables Sales')) as t(code, name)
  loop
    insert into public.chart_of_accounts
      (dealer_id, code, name, account_type, normal_balance, is_group, parent_id, is_system, is_branch_scoped)
    select p_dealer_id, a.code, a.name, 'INCOME', 'CREDIT', false, p.id, true, true
      from public.chart_of_accounts p
     where p.dealer_id = p_dealer_id and p.code = '4000' and p.is_group
    on conflict on constraint coa_dealer_code_key do nothing;
    if found then v_added := v_added + 1; end if;
  end loop;

  insert into public.accounting_rules (dealer_id, module, event, component, side, account_id, description)
  select p_dealer_id, 'SERVICE', 'INVOICE', r.component, 'CREDIT', c.id, 'Default mapping'
    from (values ('WATERWASH', '4410'), ('CONSUMABLES', '4420')) as r(component, code)
    join public.chart_of_accounts c on c.dealer_id = p_dealer_id and c.code = r.code
                                   and not c.is_group and c.account_type = 'INCOME'
   where not exists (select 1 from public.accounting_rules x
                      where x.dealer_id = p_dealer_id and x.module = 'SERVICE' and x.event = 'INVOICE'
                        and x.component = r.component and x.branch_id is null and x.status = 'ACTIVE');

  -- GST-inclusive values are split at the rate configured per head.
  insert into public.system_settings (dealer_id, key, value, value_type, description, is_public)
  values (p_dealer_id, 'quick_bill.tax_codes',
          '{"SPARES":"GST18","ACCESSORIES":"GST18","LABOUR":"GST18","WATERWASH":"GST18","CONSUMABLES":"GST18","OTHER":"GST18"}'::jsonb,
          'json', 'GST code applied to each head of a quick service or counter bill (values entered are GST-inclusive).', true)
  on conflict on constraint system_settings_scope_key do nothing;

  return v_added;
end;
$$;

do $$
declare d record;
begin
  for d in select id from public.dealers loop
    perform app.seed_quick_bill_accounts(d.id);
  end loop;
end $$;

alter function app.seed_chart_of_accounts(uuid) rename to seed_chart_of_accounts_0087;

create or replace function app.seed_chart_of_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
begin
  return app.seed_chart_of_accounts_0087(p_dealer_id) + app.seed_quick_bill_accounts(p_dealer_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- The customer, found or added
-- -----------------------------------------------------------------------------
-- Mobile first (it is unique per dealer), then the vehicle number; otherwise a
-- new customer. The vehicle is remembered against whoever it turned out to be,
-- unless it is already someone's. Definer, so a cashier can record the vehicle
-- without holding customers.edit; it checks the caller's dealer and branch.
create or replace function app.match_or_create_customer(
  p_branch_id uuid,
  p_name      text,
  p_mobile    text,
  p_vehicle   text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_dealer   uuid := app.current_dealer_id();
  v_branch   public.branches;
  v_mobile   text := nullif(right(regexp_replace(coalesce(p_mobile, ''), '[^0-9]', '', 'g'), 10), '');
  v_vehicle  text := nullif(upper(regexp_replace(coalesce(p_vehicle, ''), '[^A-Za-z0-9]', '', 'g')), '');
  v_customer uuid;
begin
  select * into v_branch from public.branches where id = p_branch_id and dealer_id = v_dealer;
  if v_branch.id is null or not app.can_access_branch(p_branch_id) then
    raise exception 'You do not have access to that branch.' using errcode = 'insufficient_privilege';
  end if;
  if v_mobile is not null and v_mobile !~ '^[6-9][0-9]{9}$' then
    raise exception 'Enter a 10-digit mobile number starting 6–9.' using errcode = 'check_violation';
  end if;

  if v_mobile is not null then
    select id into v_customer from public.customers where dealer_id = v_dealer and mobile = v_mobile;
  end if;
  if v_customer is null and v_vehicle is not null then
    select customer_id into v_customer from public.customer_vehicles
     where dealer_id = v_dealer and upper(regexp_replace(registration_no, '[^A-Za-z0-9]', '', 'g')) = v_vehicle
     limit 1;
  end if;

  if v_customer is null then
    if coalesce(btrim(p_name), '') = '' then
      raise exception 'Enter the customer''s name.' using errcode = 'check_violation';
    end if;
    if v_mobile is null then
      raise exception 'Enter the customer''s mobile number.' using errcode = 'check_violation';
    end if;
    insert into public.customers
      (dealer_id, name, mobile, city, state, state_code, origin_branch_id, created_by)
    values
      (v_dealer, btrim(p_name), v_mobile, v_branch.city, v_branch.state, v_branch.state_code, p_branch_id, auth.uid())
    returning id into v_customer;
  end if;

  if v_vehicle is not null and not exists (
       select 1 from public.customer_vehicles
        where dealer_id = v_dealer and upper(regexp_replace(registration_no, '[^A-Za-z0-9]', '', 'g')) = v_vehicle) then
    insert into public.customer_vehicles (dealer_id, customer_id, registration_no)
    values (v_dealer, v_customer, v_vehicle);
  end if;

  return v_customer;
end;
$$;

-- The rate for a head, read past the tax master's RLS: a cashier bills at the
-- configured rate without being able to open or change the master itself.
create or replace function app.quick_bill_rate(p_dealer_id uuid, p_code text, p_on date)
returns table (tax_code_id uuid, cgst_rate numeric, sgst_rate numeric, hsn text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select t.id, t.cgst_rate, t.sgst_rate, h.code
    from public.tax_codes t
    left join public.hsn_codes h on h.id = t.hsn_code_id
   where t.dealer_id = p_dealer_id and t.code = p_code and t.status = 'ACTIVE'
     and t.effective_from <= p_on and (t.effective_to is null or t.effective_to >= p_on)
   order by t.effective_from desc
   limit 1;
$$;

-- -----------------------------------------------------------------------------
-- public.create_quick_bill()
-- -----------------------------------------------------------------------------
-- p_lines: [{ "head": "SPARES" | "ACCESSORIES" | "LABOUR" | "WATERWASH" |
--             "CONSUMABLES" | "OTHER", "amount": 850, "description": "optional" }]
-- Amounts are what the customer pays, GST included.
create or replace function public.create_quick_bill(
  p_kind            text,
  p_branch_id       uuid,
  p_customer_name   text,
  p_mobile          text,
  p_vehicle_no      text,
  p_lines           jsonb,
  p_payment_mode    text default 'CASH',
  p_amount_received numeric default null,
  p_reference       text default null,
  p_date            date default current_date,
  p_idempotency_key text default null
)
returns table (invoice_id uuid, invoice_number text, customer_id uuid,
               total_amount numeric, receipt_number text, balance_due numeric)
language plpgsql
as $$
declare
  v_dealer   uuid := app.current_dealer_id();
  v_existing public.service_invoices;
  v_customer uuid;
  v_invoice  uuid;
  v_number   text;
  v_series   text;
  v_codes    jsonb;
  v_line     jsonb;
  v_head     text;
  v_type     text;
  v_amount   numeric;
  v_code     text;
  v_rate     record;
  v_hsn      text;
  v_taxable  numeric;
  v_tax      numeric;
  v_cgst     numeric;
  v_n        smallint := 0;
  v_total    numeric;
  v_receive  numeric;
  v_pay      record;
  v_vehicle  text := nullif(upper(regexp_replace(coalesce(p_vehicle_no, ''), '[^A-Za-z0-9]', '', 'g')), '');
begin
  if v_dealer is null then
    raise exception 'Only a dealer user can bill.' using errcode = 'insufficient_privilege';
  end if;
  if p_kind = 'SERVICE' and not app.has_permission('service.billing.create') then
    raise exception 'You may not make service bills.' using errcode = 'insufficient_privilege';
  end if;
  if p_kind = 'COUNTER' and not (app.has_permission('inventory.counter_sale.create') or app.has_permission('service.billing.create')) then
    raise exception 'You may not make counter bills.' using errcode = 'insufficient_privilege';
  end if;
  if p_kind not in ('SERVICE', 'COUNTER') then
    raise exception 'A quick bill is a SERVICE or a COUNTER bill.' using errcode = 'check_violation';
  end if;

  -- A repeated submission returns the bill it already made.
  if p_idempotency_key is not null then
    select * into v_existing from public.service_invoices
     where dealer_id = v_dealer and idempotency_key = 'quick:' || p_idempotency_key;
    if v_existing.id is not null then
      invoice_id := v_existing.id; invoice_number := v_existing.invoice_number;
      customer_id := v_existing.customer_id; total_amount := v_existing.total_amount;
      select p.receipt_number into receipt_number from public.service_payments p
       where p.invoice_id = v_existing.id order by p.created_at limit 1;
      balance_due := v_existing.total_amount - v_existing.paid_amount;
      return next;
      return;
    end if;
  end if;

  if jsonb_typeof(p_lines) <> 'array'
     or not exists (select 1 from jsonb_array_elements(p_lines) l where coalesce((l ->> 'amount')::numeric, 0) > 0) then
    raise exception 'Enter at least one amount.' using errcode = 'check_violation';
  end if;
  if p_kind = 'SERVICE' and v_vehicle is null then
    raise exception 'Enter the vehicle number.' using errcode = 'check_violation';
  end if;

  v_customer := app.match_or_create_customer(p_branch_id, p_customer_name, p_mobile, p_vehicle_no);

  select coalesce((select s.value from public.system_settings s
                    where s.key = 'quick_bill.tax_codes' and (s.dealer_id = v_dealer or s.dealer_id is null)
                    order by s.dealer_id nulls last limit 1), '{}'::jsonb)
    into v_codes;

  -- SERVICE_INVOICE for a workshop bill, COUNTER_INVOICE for a counter sale.
  v_series := case when p_kind = 'SERVICE' then 'SERVICE_INVOICE' else 'COUNTER_INVOICE' end;
  v_number := app.next_document_number(v_dealer, p_branch_id, v_series, app.financial_year_token(v_dealer, p_date));

  insert into public.service_invoices
    (dealer_id, branch_id, invoice_number, invoice_date, invoice_type, job_card_id, customer_id,
     vehicle_registration, idempotency_key, created_by)
  values
    (v_dealer, p_branch_id, v_number, p_date, p_kind, null, v_customer,
     v_vehicle, case when p_idempotency_key is null then null else 'quick:' || p_idempotency_key end, auth.uid())
  returning id into v_invoice;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_amount := round(coalesce((v_line ->> 'amount')::numeric, 0), 2);
    continue when v_amount = 0;
    if v_amount < 0 then
      raise exception 'An amount cannot be negative.' using errcode = 'check_violation';
    end if;
    v_head := upper(coalesce(v_line ->> 'head', ''));
    v_type := case v_head when 'SPARES' then 'SPARE' when 'ACCESSORIES' then 'ACCESSORY'
                          when 'LABOUR' then 'LABOUR' when 'WATERWASH' then 'WATERWASH'
                          when 'CONSUMABLES' then 'CONSUMABLES' when 'OTHER' then 'OTHER_CHARGE' end;
    if v_type is null then
      raise exception 'Unknown bill head "%".', v_head using errcode = 'check_violation';
    end if;

    v_code := coalesce(v_codes ->> v_head, 'GST18');
    select * into v_rate from app.quick_bill_rate(v_dealer, v_code, p_date);
    if v_rate.tax_code_id is null then
      raise exception 'No GST code % in force for %. Ask the accountant to set it in the quick bill settings.',
        v_code, lower(v_head) using errcode = 'check_violation';
    end if;
    v_hsn := v_rate.hsn;

    -- The value typed is what the customer pays; the tax is inside it.
    v_taxable := round(v_amount * 100 / (100 + v_rate.cgst_rate + v_rate.sgst_rate), 2);
    v_tax     := v_amount - v_taxable;
    v_cgst    := round(v_tax / 2, 2);
    v_n := v_n + 1;

    insert into public.service_lines
      (dealer_id, invoice_id, line_number, line_type, description, item_id, hsn_code, quantity, unit_rate,
       discount, taxable_value, tax_code, cgst_rate, sgst_rate, igst_rate, cgst_amount, sgst_amount, igst_amount,
       total_amount)
    values
      (v_dealer, v_invoice, v_n, v_type,
       coalesce(nullif(btrim(v_line ->> 'description'), ''),
                case v_head when 'SPARES' then 'Spares' when 'ACCESSORIES' then 'Accessories'
                            when 'LABOUR' then 'Labour' when 'WATERWASH' then 'Water wash'
                            when 'CONSUMABLES' then 'Other consumables' else 'Other charges' end),
       null, v_hsn, 1, v_taxable, 0, v_taxable, v_code, v_rate.cgst_rate, v_rate.sgst_rate, 0,
       v_cgst, v_tax - v_cgst, 0, v_amount);
  end loop;

  -- post_service_invoice() stamps its key on the invoice; the same key keeps the
  -- replay lookup above working.
  perform public.post_service_invoice(v_invoice, case when p_idempotency_key is null then null else 'quick:' || p_idempotency_key end);

  select si.total_amount into v_total from public.service_invoices si where si.id = v_invoice;
  -- "Cash paid is filled automatically": received defaults to the whole bill.
  v_receive := round(coalesce(p_amount_received, v_total), 2);
  if v_receive < 0 or v_receive > v_total then
    raise exception 'Amount received must be between 0 and the bill total %.', v_total using errcode = 'check_violation';
  end if;

  if v_receive > 0 then
    select * into v_pay from public.record_service_payment(
      v_invoice, v_receive, coalesce(nullif(upper(p_payment_mode), ''), 'CASH'), p_reference, p_date,
      case when p_idempotency_key is null then null else 'quick-pay:' || p_idempotency_key end);
    receipt_number := v_pay.receipt_number;
  end if;

  invoice_id := v_invoice; invoice_number := v_number; customer_id := v_customer;
  total_amount := v_total;
  balance_due := v_total - v_receive;
  return next;
end;
$$;

comment on function public.create_quick_bill(text, uuid, text, text, text, jsonb, text, numeric, text, date, text) is
  'One-step service or counter bill (spec §32, §33): customer matched by mobile or '
  'vehicle number, or added; GST-inclusive values split per head; posted; payment '
  'recorded with a receipt. No job card, no stock. Idempotent.';

-- -----------------------------------------------------------------------------
-- Posting must not depend on who is posting
-- -----------------------------------------------------------------------------
-- resolve_account() read accounting_rules under the caller's RLS, which admits
-- only holders of accounting.coa.view. Every posting so far was made by an
-- owner or accountant, so it never showed; a cashier or counter clerk posting a
-- bill got "No accounting rule for …". The mapping is configuration the
-- posting engine needs whoever triggers it, so it is read as definer — for the
-- caller's own dealer only (or with no tenant, as migrations and seeds run).
create or replace function public.resolve_account(
  p_dealer_id uuid,
  p_module    text,
  p_event     text,
  p_component text,
  p_branch_id uuid default null
)
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select r.account_id
    from public.accounting_rules r
   where r.dealer_id = p_dealer_id
     and (app.current_dealer_id() is null or p_dealer_id = app.current_dealer_id())
     and r.module = p_module
     and r.event = p_event
     and r.component = p_component
     and r.status = 'ACTIVE'
     and (r.branch_id is null or r.branch_id = p_branch_id)
   order by (r.branch_id is not null) desc, r.priority
   limit 1;
$$;

-- The posting engine writes the ledger on behalf of the document function that
-- called it. journal_entries' RLS admits only accounting users, so a bill or a
-- receipt raised by a cashier could not post at all. The engine is not
-- reachable through the API (schema app); authority is checked where it
-- belongs — by each public function, on the document it posts. The two public
-- functions that post nothing but a journal check the accountant's permission
-- themselves, so a cashier still cannot write or reverse a journal.
alter function app.post_journal(uuid, uuid, date, text, text, jsonb, text, uuid, text, uuid, text)
  security definer set search_path = public, pg_temp;
alter function app.reverse_journal(uuid, text, date)
  security definer set search_path = public, pg_temp;

create or replace function public.post_manual_journal(
  p_entry_date      date,
  p_narration       text,
  p_lines           jsonb,
  p_branch_id       uuid default null,
  p_idempotency_key text default null
)
returns table (journal_entry_id uuid, entry_number text)
language plpgsql
as $$
begin
  if not app.has_permission('accounting.journals.post') then
    raise exception 'Only the accountant can post journal entries.' using errcode = 'insufficient_privilege';
  end if;
  if p_branch_id is not null and not app.can_access_branch(p_branch_id) then
    raise exception 'You do not have access to that branch.' using errcode = 'insufficient_privilege';
  end if;
  if app.setting_enabled(app.current_dealer_id(), 'approvals.manual_journal') then
    raise exception 'Manual journals need approval at this dealer. Submit it for approval instead.'
      using errcode = 'insufficient_privilege',
            hint = 'A second person with accounting.journals.approve posts it.';
  end if;
  return query select * from app.post_manual_journal_core(
    p_entry_date, p_narration, p_lines, p_branch_id, p_idempotency_key);
end;
$$;

create or replace function public.reverse_journal_entry(
  p_journal_entry_id uuid,
  p_reason           text,
  p_reversal_date    date default current_date
)
returns table (journal_entry_id uuid, entry_number text)
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_je     public.journal_entries;
  v_entry  uuid;
begin
  if not app.has_permission('accounting.journals.reverse') then
    raise exception 'Only the accountant can reverse journal entries.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_je from public.journal_entries where id = p_journal_entry_id;
  if v_je.id is null then
    raise exception 'Journal entry not found.' using errcode = 'no_data_found';
  end if;
  if v_dealer is null or v_je.dealer_id <> v_dealer or not app.can_access_branch(v_je.branch_id) then
    raise exception 'That journal belongs to another dealer or branch.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'A reversal must say why.'
      using errcode = 'check_violation',
            hint = 'Spec §23: the reason is part of the record, not optional.';
  end if;

  v_entry := app.reverse_journal(p_journal_entry_id, btrim(p_reason), p_reversal_date);

  journal_entry_id := v_entry;
  select je.entry_number into entry_number from public.journal_entries je where je.id = v_entry;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- Billing users read what they bill, within their own branch
-- -----------------------------------------------------------------------------
-- si_write and sl_write are FOR ALL, which governs reading as well — and they
-- had no branch condition, so any billing user saw every branch's bills.
drop policy if exists si_write on public.service_invoices;
create policy si_write on public.service_invoices for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.can_access_branch(branch_id)
             and (app.has_permission('service.billing.create') or app.has_permission('inventory.counter_sale.create'))))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.can_access_branch(branch_id)
             and (app.has_permission('service.billing.create') or app.has_permission('inventory.counter_sale.create'))));

drop policy if exists sl_write on public.service_lines;
create policy sl_write on public.service_lines for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and exists (select 1 from public.service_invoices si where si.id = invoice_id and app.can_access_branch(si.branch_id))
             and (app.has_permission('service.billing.create') or app.has_permission('inventory.counter_sale.create'))))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and exists (select 1 from public.service_invoices si where si.id = invoice_id and app.can_access_branch(si.branch_id))
             and (app.has_permission('service.billing.create') or app.has_permission('inventory.counter_sale.create'))));

-- Two more FOR ALL / SELECT policies a cashier reaches without a branch
-- condition: the day closings of every branch, and every branch's vehicle
-- movements. A cashier works one location.
drop policy if exists cdc_write on public.cash_day_closings;
create policy cdc_write on public.cash_day_closings for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.can_access_branch(branch_id)
             and (app.has_permission('cashbook.day_close') or app.has_permission('cashbook.day_reopen')
                  or app.has_permission('cashbook.receipts.create'))))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.can_access_branch(branch_id)
             and (app.has_permission('cashbook.day_close') or app.has_permission('cashbook.day_reopen')
                  or app.has_permission('cashbook.receipts.create'))));

drop policy if exists vst_select on public.vehicle_stock_transactions;
create policy vst_select on public.vehicle_stock_transactions for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.can_access_branch(branch_id)
             and app.has_permission('vehicles.stock.view')));

drop policy if exists si_select on public.service_invoices;
create policy si_select on public.service_invoices for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id)
         and (app.has_permission('service.jobcards.view') or app.has_permission('inventory.view')
              or app.has_permission('service.billing.create') or app.has_permission('inventory.counter_sale.create'))));

drop policy if exists sl_select on public.service_lines;
create policy sl_select on public.service_lines for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and exists (select 1 from public.service_invoices si where si.id = invoice_id and app.can_access_branch(si.branch_id))
         and (app.has_permission('service.jobcards.view') or app.has_permission('inventory.view')
              or app.has_permission('service.billing.create') or app.has_permission('inventory.counter_sale.create'))));

drop policy if exists sp_select on public.service_payments;
create policy sp_select on public.service_payments for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and exists (select 1 from public.service_invoices si where si.id = invoice_id and app.can_access_branch(si.branch_id))
         and (app.has_permission('service.jobcards.view') or app.has_permission('inventory.view')
              or app.has_permission('service.billing.create') or app.has_permission('inventory.counter_sale.create')
              or app.has_permission('service.payments.collect'))));

-- -----------------------------------------------------------------------------
-- A party's statement, readable by whoever may see that party's balance
-- -----------------------------------------------------------------------------
-- party_ledger() reads journal lines under the caller's RLS, which admits only
-- accounting.journals.view — so a cashier, who may see a customer's balance
-- (spec §6), saw an empty ledger. party_statement() checks the permission that
-- fits the party instead, and adds what the dealer's own ledgers show: the
-- account on the other side of each entry (tax lines left out when there is
-- anything else) and the entry's id to open it.
create or replace function public.party_statement(
  p_party_type text,
  p_party_id   uuid,
  p_from       date,
  p_to         date
)
returns table (
  entry_id        uuid,
  entry_date      date,
  entry_number    text,
  source_module   text,
  narration       text,
  contra          text,
  debit           numeric(18, 4),
  credit          numeric(18, 4),
  running_balance numeric(18, 4)
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_dealer  uuid := app.current_dealer_id();
  v_opening numeric;
begin
  if v_dealer is null then
    raise exception 'Only a dealer user can read a ledger.' using errcode = 'insufficient_privilege';
  end if;
  if not (app.has_permission('accounting.ledgers.view')
          or (p_party_type = 'CUSTOMER' and app.has_permission('customers.view_ledger'))
          or (p_party_type = 'SUPPLIER' and app.has_permission('masters.suppliers.view'))
          or (p_party_type = 'FINANCE_COMPANY' and app.has_permission('finance.companies.view'))) then
    raise exception 'You may not see this ledger.' using errcode = 'insufficient_privilege';
  end if;

  select coalesce(sum(l.debit - l.credit), 0) into v_opening
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where je.dealer_id = v_dealer and l.party_type = p_party_type and l.party_id = p_party_id
     and je.status in ('POSTED', 'REVERSED') and je.entry_date < p_from;

  return query
  with taxes as (
    select r.account_id from public.accounting_rules r
     where r.dealer_id = v_dealer
       and r.component in ('CGST', 'SGST', 'IGST', 'INPUT_CGST', 'INPUT_SGST', 'INPUT_IGST')
  )
  select je.id, je.entry_date, je.entry_number, je.source_module,
         coalesce(l.narration, je.narration),
         coalesce(
           (select string_agg(distinct c2.name, ', ')
              from public.journal_entry_lines l2 join public.chart_of_accounts c2 on c2.id = l2.account_id
             where l2.journal_entry_id = je.id and l2.id <> l.id
               and not (l2.party_type is not distinct from l.party_type and l2.party_id is not distinct from l.party_id)
               and l2.account_id not in (select account_id from taxes)),
           (select string_agg(distinct c2.name, ', ')
              from public.journal_entry_lines l2 join public.chart_of_accounts c2 on c2.id = l2.account_id
             where l2.journal_entry_id = je.id and l2.id <> l.id)),
         l.debit, l.credit,
         (v_opening + sum(l.debit - l.credit) over (order by je.entry_date, je.entry_number, l.line_number
                                                    rows between unbounded preceding and current row))::numeric(18, 4)
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where je.dealer_id = v_dealer
     and l.party_type = p_party_type and l.party_id = p_party_id
     and je.status in ('POSTED', 'REVERSED')
     and je.entry_date between p_from and p_to
   order by je.entry_date, je.entry_number, l.line_number;
end;
$$;

create or replace function public.party_statement_opening(p_party_type text, p_party_id uuid, p_as_on date)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(sum(l.debit - l.credit), 0)
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where je.dealer_id = app.current_dealer_id()
     and (app.has_permission('accounting.ledgers.view')
          or (p_party_type = 'CUSTOMER' and app.has_permission('customers.view_ledger'))
          or (p_party_type = 'SUPPLIER' and app.has_permission('masters.suppliers.view'))
          or (p_party_type = 'FINANCE_COMPANY' and app.has_permission('finance.companies.view')))
     and l.party_type = p_party_type and l.party_id = p_party_id
     and je.status in ('POSTED', 'REVERSED') and je.entry_date < p_as_on;
$$;

-- -----------------------------------------------------------------------------
-- The cashier: sales, receipts and payments — nothing else
-- -----------------------------------------------------------------------------
delete from public.role_permissions rp
 using public.roles r
 where r.id = rp.role_id and r.code = 'CASHIER' and r.is_system;

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  join public.permissions p on p.code in (
    'dashboard.view',
    'customers.view', 'customers.create', 'customers.view_ledger',
    'bookings.view', 'bookings.create',
    'sales.view', 'sales.create', 'sales.submit',
    'vehicles.stock.view', 'vehicles.pricing.view',
    'service.billing.create', 'service.payments.collect',
    'inventory.counter_sale.create',
    'cashbook.view', 'cashbook.receipts.create', 'cashbook.payments.create')
 where r.code = 'CASHIER' and r.is_system
on conflict do nothing;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.create_quick_bill(text, uuid, text, text, text, jsonb, text, numeric, text, date, text) to authenticated';
    execute 'grant execute on function public.party_statement(text, uuid, date, date) to authenticated';
    execute 'grant execute on function public.party_statement_opening(text, uuid, date) to authenticated';
  end if;
end $$;

insert into public.schema_migrations (version, name)
values ('0088', 'quick_billing_and_cashier_scope') on conflict (version) do nothing;


commit;
