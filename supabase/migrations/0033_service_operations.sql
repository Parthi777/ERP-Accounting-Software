-- =============================================================================
-- 0033 — Service operations: job cards, billing, posting and payment
-- =============================================================================
-- Spec §32, §33.
--
-- The workshop flow: job card → work done → invoice → post → collect. Spares
-- consumed on a job leave stock LOCAL-before-COMPANY (spec §31), the same order
-- as a vehicle fitting, and the source is recorded on each line so the invoice
-- stays explainable.
--
-- Rollback: drop the functions below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.create_job_card() — spec §32
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
begin
  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  v_number := app.next_document_number(
    v_dealer, p_branch_id, 'JOB_CARD', app.financial_year_token(v_dealer, p_job_date));

  insert into public.job_cards
    (dealer_id, branch_id, job_card_number, job_date, customer_id, customer_vehicle_id,
     registration_no, odometer, service_type, complaint, service_advisor_id, technician_id,
     promised_at, created_by)
  values
    (v_dealer, p_branch_id, v_number, p_job_date, p_customer_id, p_customer_vehicle_id,
     nullif(btrim(p_registration_no), ''), p_odometer, p_service_type, p_complaint,
     p_service_advisor_id, p_technician_id, p_promised_at, auth.uid())
  returning id into v_id;

  job_card_id := v_id; job_card_number := v_number;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.create_service_invoice() — a draft bill for a job card (spec §32)
-- -----------------------------------------------------------------------------
create or replace function public.create_service_invoice(
  p_job_card_id  uuid,
  p_invoice_date date default current_date
)
returns table (invoice_id uuid, invoice_number text)
language plpgsql
as $$
declare
  v_job    public.job_cards;
  v_number text;
  v_id     uuid;
begin
  select * into v_job from public.job_cards where id = p_job_card_id for update;

  if v_job.id is null then
    raise exception 'Job card not found.' using errcode = 'no_data_found';
  end if;
  if v_job.status in ('INVOICED', 'CLOSED', 'CANCELLED') then
    raise exception 'Job card % is % and cannot be billed again.', v_job.job_card_number, v_job.status
      using errcode = 'check_violation';
  end if;

  -- One open bill per job card. A second draft would let two people bill the
  -- same work without either seeing the other.
  if exists (
    select 1 from public.service_invoices
     where job_card_id = p_job_card_id and status in ('DRAFT', 'POSTED')
  ) then
    raise exception 'This job card already has an invoice.' using errcode = 'unique_violation';
  end if;

  v_number := app.next_document_number(
    v_job.dealer_id, v_job.branch_id, 'SERVICE_INVOICE',
    app.financial_year_token(v_job.dealer_id, p_invoice_date));

  insert into public.service_invoices
    (dealer_id, branch_id, invoice_number, invoice_date, invoice_type,
     job_card_id, customer_id, created_by)
  values
    (v_job.dealer_id, v_job.branch_id, v_number, p_invoice_date, 'SERVICE',
     p_job_card_id, v_job.customer_id, auth.uid())
  returning id into v_id;

  invoice_id := v_id; invoice_number := v_number;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.add_service_line() — labour or a part (spec §32, §33)
-- -----------------------------------------------------------------------------
-- A spare line resolves its cost and its stock source here rather than at
-- posting, so the operator sees on the draft which stock the part will come out
-- of, and so an out-of-stock part is refused while the bill can still be changed.
-- -----------------------------------------------------------------------------
create or replace function public.add_service_line(
  p_invoice_id  uuid,
  p_line_type   text,
  p_description text,
  p_quantity    numeric,
  p_unit_rate   numeric,
  p_item_id     uuid default null,
  p_tax_code    text default null,
  p_discount    numeric default 0
)
returns uuid
language plpgsql
as $$
declare
  v_invoice   public.service_invoices;
  v_line      smallint;
  v_tax       record;
  v_taxable   numeric(18, 4);
  v_hsn       text;
  v_cost      numeric(18, 4) := 0;
  v_available numeric(14, 3);
  v_source    text;
  v_id        uuid;
  v_cgst      numeric(18, 4) := 0;
  v_sgst      numeric(18, 4) := 0;
  v_cgst_rate numeric(6, 3)  := 0;
  v_sgst_rate numeric(6, 3)  := 0;
begin
  select * into v_invoice from public.service_invoices where id = p_invoice_id for update;

  if v_invoice.id is null then
    raise exception 'Invoice not found.' using errcode = 'no_data_found';
  end if;
  if v_invoice.status <> 'DRAFT' then
    raise exception 'Invoice % is % and can no longer be edited.', v_invoice.invoice_number, v_invoice.status
      using errcode = 'check_violation';
  end if;
  if p_quantity <= 0 then
    raise exception 'Quantity must be greater than zero.' using errcode = 'check_violation';
  end if;

  v_taxable := round(p_quantity * p_unit_rate, 2) - coalesce(p_discount, 0);
  if v_taxable < 0 then
    raise exception 'The discount is more than the line value.' using errcode = 'check_violation';
  end if;

  -- ── A part comes out of stock, LOCAL before COMPANY (spec §31) ─────────────
  if p_item_id is not null and p_line_type in ('SPARE', 'ACCESSORY') then
    select h.code into v_hsn
      from public.inventory_items i
      left join public.hsn_codes h on h.id = i.hsn_code_id
     where i.id = p_item_id;

    -- allocate_stock reports a shortfall as a row of its own rather than by
    -- returning less, so the shortfall must be looked for explicitly — summing
    -- the quantities would count it as if it had been allocated. Blocking here,
    -- while the bill is still a draft, beats failing at posting with the
    -- customer waiting (spec §31).
    select a.quantity into v_available
      from public.allocate_stock(p_item_id, v_invoice.branch_id, p_quantity) a
     where a.source = 'SHORTFALL';

    if v_available is not null then
      raise exception 'Not enough stock: short by % of %.', v_available, p_quantity
        using errcode = 'check_violation',
              hint = 'Transfer stock in, or reduce the quantity.';
    end if;

    select coalesce(sum(a.quantity * a.unit_cost), 0),
           -- The source shown on the line is where the first unit comes from;
           -- a split allocation is recorded per movement at posting.
           min(a.source) filter (where a.source = 'LOCAL')
    into v_cost, v_source
      from public.allocate_stock(p_item_id, v_invoice.branch_id, p_quantity) a;

    v_source := coalesce(v_source, 'COMPANY');
  end if;

  -- The rates stay in scalars: a `record` that was never assigned raises on
  -- first access, so an untaxed line would fail at the INSERT below.
  if p_tax_code is not null then
    select * into v_tax from public.resolve_tax_code(v_invoice.dealer_id, p_tax_code, v_invoice.invoice_date);
    v_cgst_rate := coalesce(v_tax.cgst_rate, 0);
    v_sgst_rate := coalesce(v_tax.sgst_rate, 0);
    v_cgst := round(v_taxable * v_cgst_rate / 100, 2);
    v_sgst := round(v_taxable * v_sgst_rate / 100, 2);
  end if;

  select coalesce(max(line_number), 0) + 1 into v_line
    from public.service_lines where invoice_id = p_invoice_id;

  insert into public.service_lines
    (invoice_id, dealer_id, line_number, line_type, description, item_id, hsn_code,
     quantity, unit_rate, discount, taxable_value, tax_code,
     cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount,
     unit_cost, cost_amount, stock_source)
  values
    (p_invoice_id, v_invoice.dealer_id, v_line, p_line_type, p_description, p_item_id, v_hsn,
     p_quantity, p_unit_rate, coalesce(p_discount, 0), v_taxable, p_tax_code,
     v_cgst_rate, v_sgst_rate, v_cgst, v_sgst,
     v_taxable + v_cgst + v_sgst,
     case when p_quantity > 0 then round(v_cost / p_quantity, 4) else 0 end, v_cost, v_source)
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.remove_service_line(p_line_id uuid)
returns void
language plpgsql
as $$
declare v_status text;
begin
  select i.status into v_status
    from public.service_lines l
    join public.service_invoices i on i.id = l.invoice_id
   where l.id = p_line_id;

  if v_status is null then
    raise exception 'Line not found.' using errcode = 'no_data_found';
  end if;
  if v_status <> 'DRAFT' then
    raise exception 'This invoice is % and can no longer be edited.', v_status
      using errcode = 'check_violation';
  end if;

  delete from public.service_lines where id = p_line_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.post_service_invoice() — one transaction (spec §32, §48)
-- -----------------------------------------------------------------------------
-- Revenue, GST, COGS and stock relief happen together or not at all. A service
-- invoice whose journal posted but whose spares never left stock is a workshop
-- that has sold parts it still believes it holds.
-- -----------------------------------------------------------------------------
create or replace function public.post_service_invoice(
  p_invoice_id      uuid,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_invoice public.service_invoices;
  v_line    record;
  v_lines   jsonb := '[]'::jsonb;
  v_entry   uuid;
  v_dealer  uuid;
  v_branch  uuid;
  v_cogs    numeric(18, 4) := 0;
  v_remaining numeric(14, 3);
  v_alloc   record;
begin
  select * into v_invoice from public.service_invoices where id = p_invoice_id for update;

  if v_invoice.id is null then
    raise exception 'Invoice not found.' using errcode = 'no_data_found';
  end if;
  if v_invoice.status = 'POSTED' then
    -- Idempotent: a retried request returns the entry the first one wrote.
    return v_invoice.journal_entry_id;
  end if;
  if v_invoice.status <> 'DRAFT' then
    raise exception 'Invoice % is % and cannot be posted.', v_invoice.invoice_number, v_invoice.status
      using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.service_lines where invoice_id = p_invoice_id) then
    raise exception 'Invoice % has no lines.', v_invoice.invoice_number
      using errcode = 'check_violation';
  end if;

  v_dealer := v_invoice.dealer_id;
  v_branch := v_invoice.branch_id;

  -- ── Revenue, one line per component ───────────────────────────────────────
  for v_line in
    select line_type, sum(taxable_value) as taxable
      from public.service_lines
     where invoice_id = p_invoice_id and line_type <> 'DISCOUNT'
     group by line_type
     having sum(taxable_value) > 0
  loop
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', v_line.line_type, v_branch),
      'debit', 0, 'credit', v_line.taxable,
      'narration', v_invoice.invoice_number || ' — ' || v_line.line_type);
  end loop;

  -- ── GST ───────────────────────────────────────────────────────────────────
  if v_invoice.cgst_amount > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'CGST', v_branch),
      'debit', 0, 'credit', v_invoice.cgst_amount, 'narration', 'CGST');
  end if;
  if v_invoice.sgst_amount > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'SGST', v_branch),
      'debit', 0, 'credit', v_invoice.sgst_amount, 'narration', 'SGST');
  end if;
  if v_invoice.igst_amount > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'IGST', v_branch),
      'debit', 0, 'credit', v_invoice.igst_amount, 'narration', 'IGST');
  end if;

  -- ── The customer owes the total ───────────────────────────────────────────
  v_lines := v_lines || jsonb_build_object(
    'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'RECEIVABLE', v_branch),
    'debit', v_invoice.total_amount, 'credit', 0,
    'narration', v_invoice.invoice_number,
    'party_type', case when v_invoice.customer_id is not null then 'CUSTOMER' end,
    'party_id', v_invoice.customer_id);

  -- A discount reduces what is owed, so it is a debit against revenue.
  for v_line in
    select sum(taxable_value + discount) as amount
      from public.service_lines
     where invoice_id = p_invoice_id and line_type = 'DISCOUNT'
     having sum(taxable_value + discount) > 0
  loop
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'LABOUR', v_branch),
      'debit', v_line.amount, 'credit', 0, 'narration', 'Discount');
  end loop;

  -- ── Stock relief and COGS (spec §31) ──────────────────────────────────────
  for v_line in
    select id, item_id, quantity, unit_rate
      from public.service_lines
     where invoice_id = p_invoice_id and item_id is not null
     order by line_number
  loop
    v_remaining := v_line.quantity;

    for v_alloc in
      select * from public.allocate_stock(v_line.item_id, v_branch, v_line.quantity)
    loop
      -- Stock can have moved since the line was drafted, so the shortfall is
      -- checked again here. 'SHORTFALL' is not a stock source and must never
      -- reach inventory_transactions.
      if v_alloc.source = 'SHORTFALL' then
        raise exception 'Insufficient stock to post this invoice: short by % on one line.', v_alloc.quantity
          using errcode = 'check_violation',
                hint = 'Spec §31: block rather than overselling.';
      end if;

      -- Quantity is signed: negative issues. One movement per source, never
      -- merged, so the ledger shows which stock the part actually came out of.
      insert into public.inventory_transactions
        (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
         reference_type, reference_id, reference_number, narration, created_by)
      values
        (v_dealer, v_branch, v_line.item_id, v_alloc.source, 'CONSUMPTION',
         -v_alloc.quantity, v_alloc.unit_cost,
         'SERVICE_INVOICE', p_invoice_id, v_invoice.invoice_number,
         'Consumed on ' || v_invoice.invoice_number, auth.uid());

      v_cogs := v_cogs + round(v_alloc.quantity * v_alloc.unit_cost, 2);
      v_remaining := v_remaining - v_alloc.quantity;
    end loop;

    if v_remaining > 0 then
      raise exception 'Not enough stock to fulfil line for item %.', v_line.item_id
        using errcode = 'check_violation';
    end if;
  end loop;

  if v_cogs > 0 then
    v_lines := v_lines
      || jsonb_build_object(
           'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'COGS', v_branch),
           'debit', v_cogs, 'credit', 0, 'narration', 'Cost of parts consumed')
      || jsonb_build_object(
           'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'INVENTORY', v_branch),
           'debit', 0, 'credit', v_cogs, 'narration', 'Parts issued from stock');
  end if;

  v_entry := app.post_journal(
    v_dealer, v_branch, v_invoice.invoice_date, 'SERVICE',
    'Service invoice ' || v_invoice.invoice_number,
    v_lines, 'SERVICE_INVOICE', p_invoice_id,
    coalesce(p_idempotency_key, 'service:' || p_invoice_id::text));

  update public.service_invoices
     set status = 'POSTED', posted_at = now(), journal_entry_id = v_entry,
         total_cost = v_cogs, idempotency_key = coalesce(p_idempotency_key, 'service:' || p_invoice_id::text),
         updated_by = auth.uid()
   where id = p_invoice_id;

  -- The job card is billed, which is what closes it to further work.
  if v_invoice.job_card_id is not null then
    update public.job_cards
       set status = 'INVOICED', updated_by = auth.uid()
     where id = v_invoice.job_card_id;
  end if;

  return v_entry;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_service_payment() — spec §32
-- -----------------------------------------------------------------------------
create or replace function public.record_service_payment(
  p_invoice_id   uuid,
  p_amount       numeric,
  p_payment_mode text default 'CASH',
  p_reference    text default null,
  p_date         date default current_date
)
returns table (payment_id uuid, receipt_number text, balance_due numeric)
language plpgsql
as $$
declare
  v_invoice public.service_invoices;
  v_number  text;
  v_entry   uuid;
  v_debit   uuid;
  v_credit  uuid;
  v_id      uuid;
  v_balance numeric(18, 4);
begin
  select * into v_invoice from public.service_invoices where id = p_invoice_id for update;

  if v_invoice.id is null then
    raise exception 'Invoice not found.' using errcode = 'no_data_found';
  end if;
  if v_invoice.status <> 'POSTED' then
    raise exception 'Invoice % is % — only a posted invoice can take a payment.',
      v_invoice.invoice_number, v_invoice.status using errcode = 'check_violation';
  end if;
  if p_amount <= 0 then
    raise exception 'The payment amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_amount > v_invoice.total_amount - v_invoice.paid_amount then
    raise exception 'That is more than the % outstanding on this invoice.',
      v_invoice.total_amount - v_invoice.paid_amount using errcode = 'check_violation';
  end if;

  v_number := app.next_document_number(
    v_invoice.dealer_id, v_invoice.branch_id, 'RECEIPT',
    app.financial_year_token(v_invoice.dealer_id, p_date));

  v_debit := app.require_account(
    v_invoice.dealer_id,
    case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
    'RECEIPT',
    case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
    v_invoice.branch_id);

  v_credit := app.require_account(v_invoice.dealer_id, 'SERVICE', 'INVOICE', 'RECEIVABLE', v_invoice.branch_id);

  v_entry := app.post_journal(
    v_invoice.dealer_id, v_invoice.branch_id, p_date,
    case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
    'Receipt ' || v_number || ' against ' || v_invoice.invoice_number,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', v_number),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', v_invoice.invoice_number,
                         'party_type', case when v_invoice.customer_id is not null then 'CUSTOMER' end,
                         'party_id', v_invoice.customer_id)
    ),
    'SERVICE_RECEIPT', p_invoice_id, null);

  insert into public.service_payments
    (dealer_id, invoice_id, receipt_number, payment_date, amount, payment_mode,
     reference, journal_entry_id, created_by)
  values
    (v_invoice.dealer_id, p_invoice_id, v_number, p_date, p_amount, p_payment_mode,
     p_reference, v_entry, auth.uid())
  returning id into v_id;

  select si.total_amount - si.paid_amount into v_balance
    from public.service_invoices si where si.id = p_invoice_id;

  payment_id := v_id; receipt_number := v_number; balance_due := v_balance;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.service_history() — spec §33
-- -----------------------------------------------------------------------------
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
  select j.id, j.job_card_number, j.job_date, c.name, j.registration_no, j.odometer,
         j.service_type, j.complaint, j.status,
         i.invoice_number, i.total_amount, i.paid_amount
    from public.job_cards j
    join public.customers c on c.id = j.customer_id
    left join public.service_invoices i
      on i.job_card_id = j.id and i.status <> 'CANCELLED'
   where (p_customer_id is null or j.customer_id = p_customer_id)
     and (p_registration_no is null or j.registration_no ilike p_registration_no)
   order by j.job_date desc, j.job_card_number desc;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.create_job_card(uuid, uuid, text, text, numeric, text, uuid, uuid, uuid, timestamptz, date) to authenticated';
    execute 'grant execute on function public.create_service_invoice(uuid, date) to authenticated';
    execute 'grant execute on function public.add_service_line(uuid, text, text, numeric, numeric, uuid, text, numeric) to authenticated';
    execute 'grant execute on function public.remove_service_line(uuid) to authenticated';
    execute 'grant execute on function public.post_service_invoice(uuid, text) to authenticated';
    execute 'grant execute on function public.record_service_payment(uuid, numeric, text, text, date) to authenticated';
    execute 'grant execute on function public.service_history(uuid, text) to authenticated';
  end if;
end;
$$;
