-- =============================================================================
-- 0034 — GST returns and the e-invoice queue
-- =============================================================================
-- Spec §40.
--
-- Two things here, and it matters that they are separate:
--
--   Reporting   GSTR-1 style views over documents the dealer has already
--               issued. These are derived, never stored, so they cannot drift
--               from the invoices they summarise.
--
--   Queue       einvoices and eway_bills rows track what the GST portal has
--               been told. Enqueuing is a local act; whether the portal
--               responded is a separate fact. A failure there must never roll
--               back an accounting transaction that already happened.
--
-- Rollback: drop the functions below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.gstr1_summary() — outward supplies by section (spec §40)
-- -----------------------------------------------------------------------------
-- The B2B/B2C split turns on whether the customer has a GSTIN, which is what the
-- return itself turns on. A registered buyer whose GSTIN was never captured ends
-- up in B2C and cannot claim credit, so the count of missing GSTINs is worth
-- seeing next to the totals rather than buried.
-- -----------------------------------------------------------------------------
create or replace function public.gstr1_summary(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  section        text,
  document_count bigint,
  taxable_value  numeric(18, 4),
  cgst_amount    numeric(18, 4),
  sgst_amount    numeric(18, 4),
  igst_amount    numeric(18, 4),
  total_tax      numeric(18, 4),
  invoice_value  numeric(18, 4)
)
language sql
stable
as $$
  with docs as (
    select s.id, c.gstin, s.taxable_value, s.cgst_amount, s.sgst_amount, s.igst_amount,
           s.total_amount
      from public.sales s
      left join public.customers c on c.id = s.customer_id
     where s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select si.id, c.gstin, si.taxable_value, si.cgst_amount, si.sgst_amount, si.igst_amount,
           si.total_amount
      from public.service_invoices si
      left join public.customers c on c.id = si.customer_id
     where si.status = 'POSTED'
       and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
  )
  select case when nullif(btrim(coalesce(docs.gstin, '')), '') is not null then 'B2B' else 'B2C' end,
         count(*), sum(docs.taxable_value), sum(docs.cgst_amount), sum(docs.sgst_amount),
         sum(docs.igst_amount),
         sum(docs.cgst_amount + docs.sgst_amount + docs.igst_amount),
         sum(docs.total_amount)
    from docs
   group by 1
   order by 1;
$$;

-- -----------------------------------------------------------------------------
-- public.gst_document_register() — the invoice-level detail behind the return
-- -----------------------------------------------------------------------------
create or replace function public.gst_document_register(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null,
  p_section   text default null
)
returns table (
  document_type   text,
  document_id     uuid,
  document_number text,
  document_date   date,
  customer_name   text,
  gstin           text,
  place_of_supply text,
  section         text,
  taxable_value   numeric(18, 4),
  cgst_amount     numeric(18, 4),
  sgst_amount     numeric(18, 4),
  igst_amount     numeric(18, 4),
  invoice_value   numeric(18, 4),
  einvoice_status text,
  irn             text
)
language sql
stable
as $$
  with docs as (
    select 'SALE'::text as dtype, s.id, s.invoice_number, s.invoice_date,
           coalesce(c.name, 'Cash customer') as cname, c.gstin, c.state as pos,
           s.taxable_value, s.cgst_amount, s.sgst_amount, s.igst_amount, s.total_amount
      from public.sales s
      left join public.customers c on c.id = s.customer_id
     where s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select 'SERVICE_INVOICE', si.id, si.invoice_number, si.invoice_date,
           coalesce(c.name, 'Counter sale'), c.gstin, c.state,
           si.taxable_value, si.cgst_amount, si.sgst_amount, si.igst_amount, si.total_amount
      from public.service_invoices si
      left join public.customers c on c.id = si.customer_id
     where si.status = 'POSTED'
       and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
  )
  select d.dtype, d.id, d.invoice_number, d.invoice_date, d.cname, d.gstin, d.pos,
         case when nullif(btrim(coalesce(d.gstin, '')), '') is not null then 'B2B' else 'B2C' end,
         d.taxable_value, d.cgst_amount, d.sgst_amount, d.igst_amount, d.total_amount,
         -- No e-invoice row at all is a different state from one that failed.
         coalesce(e.status, 'NOT_REQUESTED'), e.irn
    from docs d
    left join public.einvoices e on e.document_type = d.dtype and e.document_id = d.id
   where p_section is null
      or p_section = (case when nullif(btrim(coalesce(d.gstin, '')), '') is not null then 'B2B' else 'B2C' end)
   order by d.invoice_date, d.invoice_number;
$$;

-- -----------------------------------------------------------------------------
-- public.queue_einvoice() — record the intent to file (spec §40)
-- -----------------------------------------------------------------------------
-- Creating the row is all this does. Whether the portal accepts it is recorded
-- later by whatever process talks to the portal, so a portal outage leaves a
-- retryable row rather than blocking the sale.
-- -----------------------------------------------------------------------------
create or replace function public.queue_einvoice(
  p_document_type text,
  p_document_id   uuid
)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid;
  v_number text;
  v_date   date;
  v_id     uuid;
  v_status text;
begin
  if p_document_type = 'SALE' then
    select dealer_id, invoice_number, invoice_date, status
      into v_dealer, v_number, v_date, v_status
      from public.sales where id = p_document_id;
  elsif p_document_type = 'SERVICE_INVOICE' then
    select dealer_id, invoice_number, invoice_date, status
      into v_dealer, v_number, v_date, v_status
      from public.service_invoices where id = p_document_id;
  else
    raise exception 'Unsupported document type %.', p_document_type using errcode = 'check_violation';
  end if;

  if v_dealer is null then
    raise exception 'Document not found.' using errcode = 'no_data_found';
  end if;

  -- An unposted invoice is not yet a supply, and filing one would report a sale
  -- the books do not carry.
  if v_status not in ('POSTED', 'DELIVERED') then
    raise exception 'Document % is % — only a posted invoice can be filed.', v_number, v_status
      using errcode = 'check_violation';
  end if;

  insert into public.einvoices
    (dealer_id, document_type, document_id, document_number, document_date, status, created_by)
  values
    (v_dealer, p_document_type, p_document_id, v_number, v_date, 'PENDING', auth.uid())
  on conflict on constraint einvoices_document_key do update
     set status = case
                    -- A generated e-invoice is not re-queued: it has an IRN.
                    when public.einvoices.status = 'GENERATED' then 'GENERATED'
                    else 'PENDING'
                  end,
         error_code = null,
         error_message = null
  returning id into v_id;

  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_einvoice_result() — what the portal said
-- -----------------------------------------------------------------------------
create or replace function public.record_einvoice_result(
  p_einvoice_id uuid,
  p_status      text,
  p_irn         text default null,
  p_ack_number  text default null,
  p_ack_date    timestamptz default null,
  p_qr_code     text default null,
  p_error_code  text default null,
  p_error       text default null,
  p_response    jsonb default null
)
returns void
language plpgsql
as $$
begin
  if p_status not in ('GENERATED', 'FAILED', 'CANCELLED') then
    raise exception 'Status must be GENERATED, FAILED or CANCELLED.' using errcode = 'check_violation';
  end if;
  if p_status = 'GENERATED' and (p_irn is null or p_ack_number is null) then
    raise exception 'A generated e-invoice must carry an IRN and acknowledgement number.'
      using errcode = 'check_violation';
  end if;
  if p_status = 'FAILED' and p_error is null then
    raise exception 'A failed e-invoice must record why.' using errcode = 'check_violation';
  end if;

  update public.einvoices
     set status = p_status,
         irn = coalesce(p_irn, irn),
         ack_number = coalesce(p_ack_number, ack_number),
         ack_date = coalesce(p_ack_date, ack_date),
         signed_qr_code = coalesce(p_qr_code, signed_qr_code),
         error_code = p_error_code,
         error_message = p_error,
         response_payload = coalesce(p_response, response_payload),
         attempt_count = attempt_count + 1,
         last_attempt_at = now()
   where id = p_einvoice_id;

  if not found then
    raise exception 'E-invoice record not found.' using errcode = 'no_data_found';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.queue_eway_bill() — spec §40
-- -----------------------------------------------------------------------------
create or replace function public.queue_eway_bill(
  p_document_type   text,
  p_document_id     uuid,
  p_transport_mode  text default 'ROAD',
  p_vehicle_number  text default null,
  p_distance_km     integer default null,
  p_transporter_id  text default null,
  p_transporter_name text default null
)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid;
  v_number text;
  v_id     uuid;
begin
  if p_document_type = 'SALE' then
    select dealer_id, invoice_number into v_dealer, v_number
      from public.sales where id = p_document_id;
  elsif p_document_type = 'SERVICE_INVOICE' then
    select dealer_id, invoice_number into v_dealer, v_number
      from public.service_invoices where id = p_document_id;
  elsif p_document_type = 'TRANSFER' then
    select dealer_id, transfer_number into v_dealer, v_number
      from public.vehicle_transfers where id = p_document_id;
  else
    raise exception 'Unsupported document type %.', p_document_type using errcode = 'check_violation';
  end if;

  if v_dealer is null then
    raise exception 'Document not found.' using errcode = 'no_data_found';
  end if;

  insert into public.eway_bills
    (dealer_id, document_type, document_id, document_number, status,
     transport_mode, vehicle_number, distance_km, transporter_id, transporter_name, created_by)
  values
    (v_dealer, p_document_type, p_document_id, v_number, 'PENDING',
     p_transport_mode, nullif(btrim(p_vehicle_number), ''), p_distance_km,
     nullif(btrim(p_transporter_id), ''), nullif(btrim(p_transporter_name), ''), auth.uid())
  on conflict on constraint eway_document_key do update
     set status = case when public.eway_bills.status = 'GENERATED' then 'GENERATED' else 'PENDING' end,
         transport_mode = excluded.transport_mode,
         vehicle_number = excluded.vehicle_number,
         distance_km = excluded.distance_km,
         error_message = null
  returning id into v_id;

  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.einvoice_queue() — what is waiting, what failed, what is missing
-- -----------------------------------------------------------------------------
-- Posted invoices with no e-invoice row at all appear here too. They are the
-- ones nobody has noticed, and leaving them out of the queue is how a return
-- gets filed short.
-- -----------------------------------------------------------------------------
create or replace function public.einvoice_queue(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  einvoice_id     uuid,
  document_type   text,
  document_id     uuid,
  document_number text,
  document_date   date,
  customer_name   text,
  gstin           text,
  invoice_value   numeric(18, 4),
  status          text,
  irn             text,
  ack_number      text,
  error_message   text,
  attempt_count   integer
)
language sql
stable
as $$
  with docs as (
    select 'SALE'::text as dtype, s.id, s.invoice_number, s.invoice_date,
           coalesce(c.name, 'Cash customer') as cname, c.gstin, s.total_amount
      from public.sales s
      left join public.customers c on c.id = s.customer_id
     where s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select 'SERVICE_INVOICE', si.id, si.invoice_number, si.invoice_date,
           coalesce(c.name, 'Counter sale'), c.gstin, si.total_amount
      from public.service_invoices si
      left join public.customers c on c.id = si.customer_id
     where si.status = 'POSTED'
       and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
  )
  select e.id, d.dtype, d.id, d.invoice_number, d.invoice_date, d.cname, d.gstin,
         d.total_amount,
         coalesce(e.status, 'NOT_REQUESTED'), e.irn, e.ack_number, e.error_message,
         coalesce(e.attempt_count, 0)
    from docs d
    left join public.einvoices e on e.document_type = d.dtype and e.document_id = d.id
   order by
     -- Failures first, then never-requested, then pending; the generated ones
     -- need no attention.
     case coalesce(e.status, 'NOT_REQUESTED')
       when 'FAILED' then 1 when 'NOT_REQUESTED' then 2 when 'PENDING' then 3 else 4 end,
     d.invoice_date desc;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.gstr1_summary(date, date, uuid) to authenticated';
    execute 'grant execute on function public.gst_document_register(date, date, uuid, text) to authenticated';
    execute 'grant execute on function public.queue_einvoice(text, uuid) to authenticated';
    execute 'grant execute on function public.record_einvoice_result(uuid, text, text, text, timestamptz, text, text, text, jsonb) to authenticated';
    execute 'grant execute on function public.queue_eway_bill(text, uuid, text, text, integer, text, text) to authenticated';
    execute 'grant execute on function public.einvoice_queue(date, date, uuid) to authenticated';
  end if;
end;
$$;
