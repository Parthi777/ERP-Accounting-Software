-- =============================================================================
-- INCREMENTAL 0089 → 0089
-- =============================================================================
-- GENERATED FILE. Regenerate with:
--   FROM=0089 bash scripts/build-incremental.sh
--
-- For a database that ALREADY has migrations up to 0088.
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
-- SOURCE: supabase/migrations/0089_posting_authority.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0089 — Who may post what: posting authority and the sale workflow
-- =============================================================================
-- Spec §6, §19, §47, §53. Found by the spec review of 25 Sep 2026.
--
-- 0088 made the posting engine (app.post_journal, app.reverse_journal) run as
-- definer, so a cashier's bill or receipt could post. Before that, the journal
-- table's own RLS — accounting users only — had been the one thing standing
-- between several public functions and the ledger, because those functions do
-- not check a permission themselves:
--
--   post_opening_balances   wrote nothing else RLS guards → any dealer user
--                           could post opening balances;
--   post_vehicle_sale,       relied on sales_update, which admits anyone with
--   return_vehicle_sale      sales.create;
--   refund_booking_advance  relied on bookings_update (bookings.create).
--
-- And the sale workflow itself was never guarded by permission: sales_guard
-- checks which status may follow which, not who is moving it. With sales.create
-- a cashier could PATCH their own sale SUBMITTED → ACCOUNTS_VERIFICATION →
-- APPROVED and post it, skipping the accountant (spec §19, §53).
--
-- Two guards, at the level every path passes through:
--
--   * journal_entries_authority — before a journal is written by a signed-in
--     user, the user must hold a permission that fits its source document type
--     (a sale: sales.post; a booking refund: bookings.refund; opening balances
--     or a manual journal: the accountant's; …). A reversal is also allowed
--     with accounting.journals.reverse. A type not in the map needs
--     accounting.journals.post. Migrations, seeds and system jobs (no user)
--     are not checked.
--
--   * sales_status_authority — each status change of a sale needs its own
--     permission: submit, verify, approve, post, deliver, cancel, return.
--
-- Also: quick bills report each head under its own HSN/SAC, and the service
-- history includes bills made without a job card (see below).
--
-- Rollback: drop both triggers and app.posting_permissions(); restore
--           create_quick_bill() from 0088.
-- =============================================================================

create or replace function app.posting_permissions(p_source_document_type text)
returns text[]
language sql
immutable
as $$
  select case p_source_document_type
    when 'SALE'               then array['sales.post', 'sales.cancel', 'sales.return']
    when 'SALE_RETURN'        then array['sales.return']
    when 'SALE_PAYMENT'       then array['sales.create', 'sales.post', 'cashbook.receipts.create']
    when 'BOOKING'            then array['bookings.create', 'bookings.cancel']
    when 'BOOKING_APPLY'      then array['sales.post', 'bookings.convert']
    when 'BOOKING_REFUND'     then array['bookings.refund']
    when 'SERVICE_INVOICE'    then array['service.billing.create', 'inventory.counter_sale.create']
    when 'SERVICE_RECEIPT'    then array['service.payments.collect', 'service.billing.create', 'inventory.counter_sale.create']
    when 'CASH_BOOK'          then array['cashbook.receipts.create', 'cashbook.payments.create']
    when 'BANK_BOOK'          then array['bank.book.record', 'cashbook.receipts.create', 'cashbook.payments.create']
    when 'CONTRA'             then array['bank.book.record', 'bank.reconcile']
    when 'BANK_ACCOUNT'       then array['bank.accounts.manage']
    when 'PURCHASE_BILL'      then array['purchases.post', 'purchases.create', 'purchases.cancel']
    when 'PURCHASE_RETURN'    then array['purchases.return', 'purchases.cancel']
    when 'STOCK_ADJUSTMENT'   then array['inventory.stock.adjust', 'inventory.stock.approve', 'vehicles.stock.adjust']
    when 'STOCK_DAMAGE'       then array['inventory.stock.adjust']
    when 'BRANCH_TRANSFER'    then array['inventory.stock.transfer', 'vehicles.transfers.manage']
    when 'FINANCE_APPLICATION' then array['finance.applications.manage']
    when 'FINANCE_SETTLEMENT' then array['finance.settlements.manage']
    when 'TRADE_ADVANCE'      then array['finance.trade_advance.manage']
    when 'GST_NOTE'           then array['gst.notes.manage']
    when 'GST_SETOFF'         then array['gst.returns.file']
    when 'ITC_ADJUSTMENT'     then array['gst.itc.manage']
    when 'DEPRECIATION'       then array['assets.manage']
    when 'ASSET_DISPOSAL'     then array['assets.manage']
    when 'LOAN'               then array['loans.manage']
    when 'PAYROLL'            then array['hr.payroll.run']
    when 'PAYROLL_PAYMENT'    then array['hr.payroll.run']
    when 'MANUAL_JOURNAL'     then array['accounting.journals.post', 'accounting.journals.approve']
    when 'OPENING_BALANCE'    then array['accounting.journals.post']
    else array['accounting.journals.post']
  end;
$$;

comment on function app.posting_permissions(text) is
  'The permissions any one of which lets a signed-in user write a journal of this '
  'source document type (0089). Unknown types need accounting.journals.post.';

create or replace function app.journal_entries_authority()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- No user: a migration, a seed, a system job. Their callers are trusted.
  if auth.uid() is null or app.is_platform_admin() then
    return new;
  end if;
  if new.reversal_of_id is not null and app.has_permission('accounting.journals.reverse') then
    return new;
  end if;
  if exists (select 1 from unnest(app.posting_permissions(new.source_document_type)) p
              where app.has_permission(p)) then
    return new;
  end if;
  raise exception 'You may not post a % entry.', lower(replace(coalesce(new.source_document_type, 'journal'), '_', ' '))
    using errcode = 'insufficient_privilege',
          hint = 'Posting needs one of: ' || array_to_string(app.posting_permissions(new.source_document_type), ', ');
end;
$$;

create trigger journal_entries_authority
  before insert on public.journal_entries
  for each row execute function app.journal_entries_authority();

-- -----------------------------------------------------------------------------
-- Each step of the sale workflow needs its own permission (spec §19)
-- -----------------------------------------------------------------------------
create or replace function app.sales_status_authority()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_needed text[];
begin
  if auth.uid() is null or app.is_platform_admin() or new.status is not distinct from old.status then
    return new;
  end if;
  v_needed := case new.status
    when 'SUBMITTED'             then array['sales.submit']
    when 'ACCOUNTS_VERIFICATION' then array['sales.verify']
    when 'APPROVED'              then array['sales.approve']
    when 'POSTED'                then array['sales.post']
    when 'DELIVERED'             then array['sales.deliver']
    when 'CANCELLED'             then array['sales.cancel']
    when 'RETURNED'              then array['sales.return']
    -- Back to draft: the accountant returns it for correction, or whoever
    -- submitted it recalls it before verification.
    when 'DRAFT'                 then case when old.status = 'SUBMITTED'
                                           then array['sales.submit', 'sales.verify', 'sales.approve']
                                           else array['sales.verify', 'sales.approve'] end
    else array['sales.approve']
  end;
  if not exists (select 1 from unnest(v_needed) p where app.has_permission(p)) then
    raise exception 'You may not move sale % from % to %.', old.invoice_number, old.status, new.status
      using errcode = 'insufficient_privilege',
            hint = 'Needs: ' || array_to_string(v_needed, ' or ');
  end if;
  return new;
end;
$$;

create trigger sales_status_authority
  before update of status on public.sales
  for each row execute function app.sales_status_authority();

-- -----------------------------------------------------------------------------
-- Quick bills report each head under its own HSN/SAC
-- -----------------------------------------------------------------------------
-- 0088 took the HSN from the head's tax code. GST18 carries 87112019 —
-- motorcycles — so labour and water wash (services, SAC) and spares (8714)
-- would all have reached GSTR-1's HSN summary as vehicles. Each head now has
-- its own code: the dealer setting quick_bill.hsn_codes, over these defaults —
--   SPARES, ACCESSORIES 8714 (parts and accessories of motorcycles)
--   LABOUR, WATERWASH   998714 (maintenance and repair of motorcycles)
--   CONSUMABLES, OTHER  the tax code's HSN, until the accountant sets one.
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
  v_hsns     jsonb;
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

  -- The HSN or SAC each head is reported under. A tax code carries one HSN,
  -- which for GST18 is the vehicle's own — right for no line on a service bill.
  select coalesce((select s.value from public.system_settings s
                    where s.key = 'quick_bill.hsn_codes' and (s.dealer_id = v_dealer or s.dealer_id is null)
                    order by s.dealer_id nulls last limit 1), '{}'::jsonb)
         || '{}'::jsonb
    into v_hsns;
  v_hsns := jsonb_build_object('SPARES', '8714', 'ACCESSORIES', '8714', 'LABOUR', '998714', 'WATERWASH', '998714')
            || v_hsns;

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
    v_hsn := coalesce(nullif(btrim(v_hsns ->> v_head), ''), v_rate.hsn);

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


-- -----------------------------------------------------------------------------
-- Service history includes bills made without a job card (spec §32)
-- -----------------------------------------------------------------------------
-- 0088 bills a service directly, with the vehicle number on the bill. The
-- service history and the per-customer rollup still read only job cards, so
-- every service billed since would have been missing from both. A visit is now
-- a job card (with its bill) or a service bill that had none.
create or replace function app.service_visits()
returns table (
  visit_id uuid, customer_id uuid, branch_id uuid, visit_date date, reference text,
  registration_no text, odometer numeric, service_type text, complaint text, status text,
  invoice_number text, invoice_total numeric, paid_amount numeric, is_open boolean
)
language sql
stable
as $$
  select j.id, j.customer_id, j.branch_id, j.job_date, j.job_card_number,
         j.registration_no, j.odometer, j.service_type, j.complaint, j.status,
         i.invoice_number, i.total_amount, i.paid_amount,
         j.status in ('OPEN', 'IN_PROGRESS', 'READY')
    from public.job_cards j
    left join public.service_invoices i on i.job_card_id = j.id and i.status <> 'CANCELLED'
  union all
  select i.id, i.customer_id, i.branch_id, i.invoice_date, i.invoice_number,
         i.vehicle_registration, null, 'SERVICE', null, i.status,
         i.invoice_number, i.total_amount, i.paid_amount, false
    from public.service_invoices i
   where i.invoice_type = 'SERVICE' and i.job_card_id is null and i.status <> 'CANCELLED';
$$;

create or replace function public.service_history(
  p_customer_id     uuid default null,
  p_registration_no text default null
)
returns table (
  job_card_id     uuid,
  job_card_number text,
  job_date        date,
  customer_name   text,
  registration_no text,
  odometer        numeric(10, 1),
  service_type    text,
  complaint       text,
  status          text,
  invoice_number  text,
  invoice_total   numeric(18, 4),
  paid_amount     numeric(18, 4)
)
language sql
stable
as $$
  select v.visit_id, v.reference, v.visit_date, c.name, v.registration_no, v.odometer::numeric(10, 1),
         v.service_type, v.complaint, v.status, v.invoice_number, v.invoice_total, v.paid_amount
    from app.service_visits() v
    join public.customers c on c.id = v.customer_id
   where (p_customer_id is null or v.customer_id = p_customer_id)
     and (p_registration_no is null
          or upper(regexp_replace(coalesce(v.registration_no, ''), '[^A-Za-z0-9]', '', 'g'))
             like upper(regexp_replace(p_registration_no, '[^A-Za-z0-9%]', '', 'g')))
   order by v.visit_date desc, v.reference desc;
$$;

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
         count(distinct v.visit_id)::int,
         min(v.visit_date),
         max(v.visit_date),
         (current_date - max(v.visit_date))::int,
         coalesce(sum(v.invoice_total), 0)::numeric(18, 4),
         count(distinct v.visit_id) filter (where v.is_open)::int
    from public.customers c
    join app.service_visits() v on v.customer_id = c.id
   where (p_customer_id is null or c.id = p_customer_id)
     and (p_branch_id is null or v.branch_id = p_branch_id)
   group by c.id, c.customer_code, c.name, c.mobile
   order by max(v.visit_date) desc;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function app.service_visits() to authenticated';
  end if;
end $$;

insert into public.schema_migrations (version, name)
values ('0089', 'posting_authority') on conflict (version) do nothing;


commit;
