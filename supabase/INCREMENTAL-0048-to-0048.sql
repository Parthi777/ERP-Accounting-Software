-- =============================================================================
-- INCREMENTAL 0048 → 0048
-- =============================================================================
-- GENERATED FILE. Regenerate with:
--   FROM=0048 bash scripts/build-incremental.sh
--
-- For a database that ALREADY has migrations up to 0047.
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
-- SOURCE: supabase/migrations/0048_einvoice_payload.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0048 — E-invoice payload and request recording
-- =============================================================================
-- Spec §40.
--
-- The queue from 0034 knows what to file and what came back, but nothing ever
-- built the document the portal actually wants, and request_payload — a column
-- spec §40 asks for by name — has never been written by anything.
--
-- Two functions:
--   * einvoice_payload()        builds the IRP document from the invoice;
--   * record_einvoice_request() stores it and counts the attempt, BEFORE the
--     call goes out.
--
-- Recording the request first matters. If the process dies mid-flight, or the
-- portal accepts a document and the reply is lost, the row still shows exactly
-- what was sent and that an attempt was made — which is the difference between
-- "we never filed" and "we do not know whether we filed".
--
-- The payload follows the NIC IRP schema (version 1.1): TranDtls, DocDtls,
-- SellerDtls, BuyerDtls, ItemList, ValDtls. Field names are the portal's, not
-- this schema's, which is why they are camel-cased and abbreviated here and
-- nowhere else.
--
-- Rollback: drop public.einvoice_payload(uuid) and public.record_einvoice_request(uuid, jsonb),
--           and restore public.record_einvoice_result(...) from 0034.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.einvoice_payload() — spec §40
-- -----------------------------------------------------------------------------
create or replace function public.einvoice_payload(p_einvoice_id uuid)
returns jsonb
language plpgsql
stable
as $$
declare
  v_e        public.einvoices;
  v_seller   record;
  v_buyer    record;
  v_totals   record;
  v_items    jsonb;
  v_intra    boolean;
begin
  select * into v_e from public.einvoices where id = p_einvoice_id;
  if v_e.id is null then
    raise exception 'E-invoice not found.' using errcode = 'no_data_found';
  end if;

  -- ── Seller: the branch that raised it, falling back to the dealer ─────────
  -- A branch may have its own GSTIN; where it does not, the dealer's applies.
  if v_e.document_type = 'SALE' then
    select coalesce(b.gstin, d.gstin) as gstin, d.legal_name as name,
           b.address_line1, b.city, b.pincode, coalesce(b.state_code, d.state_code) as state_code
      into v_seller
      from public.sales s
      join public.branches b on b.id = s.branch_id
      join public.dealers d  on d.id = s.dealer_id
     where s.id = v_e.document_id;
  else
    select coalesce(b.gstin, d.gstin) as gstin, d.legal_name as name,
           b.address_line1, b.city, b.pincode, coalesce(b.state_code, d.state_code) as state_code
      into v_seller
      from public.service_invoices si
      join public.branches b on b.id = si.branch_id
      join public.dealers d  on d.id = si.dealer_id
     where si.id = v_e.document_id;
  end if;

  if v_seller.gstin is null then
    raise exception 'The branch raising % has no GSTIN, and neither has the dealer.',
      v_e.document_number
      using errcode = 'check_violation',
            hint = 'An e-invoice cannot be filed without the seller''s GSTIN.';
  end if;

  -- ── Buyer, totals and lines ──────────────────────────────────────────────
  if v_e.document_type = 'SALE' then
    select c.name, c.gstin, c.address_line1, c.city, c.pincode, c.state_code
      into v_buyer
      from public.sales s left join public.customers c on c.id = s.customer_id
     where s.id = v_e.document_id;

    select taxable_value, cgst_amount, sgst_amount, igst_amount, total_amount, discount_amount
      into v_totals
      from public.sales where id = v_e.document_id;

    select jsonb_agg(item order by item_no)
      into v_items
      from (
        select row_number() over (order by l.line_number) as item_no,
               jsonb_build_object(
                 'SlNo',      row_number() over (order by l.line_number)::text,
                 'PrdDesc',   left(l.description, 300),
                 'IsServc',   case when l.line_type in ('LABOUR', 'FORWARDING', 'OTHER_CHARGE') then 'Y' else 'N' end,
                 'HsnCd',     coalesce(l.hsn_code, '9999'),
                 'Qty',       l.quantity,
                 'Unit',      'NOS',
                 'UnitPrice', l.unit_rate,
                 'TotAmt',    round(l.unit_rate * l.quantity, 2),
                 'Discount',  l.discount,
                 'AssAmt',    l.taxable_value,
                 'GstRt',     coalesce(l.cgst_rate, 0) + coalesce(l.sgst_rate, 0) + coalesce(l.igst_rate, 0),
                 'CgstAmt',   l.cgst_amount,
                 'SgstAmt',   l.sgst_amount,
                 'IgstAmt',   l.igst_amount,
                 'TotItemVal', l.total_amount) as item
          from public.sale_lines l where l.sale_id = v_e.document_id
      ) numbered;
  else
    select c.name, c.gstin, c.address_line1, c.city, c.pincode, c.state_code
      into v_buyer
      from public.service_invoices si left join public.customers c on c.id = si.customer_id
     where si.id = v_e.document_id;

    select taxable_value, cgst_amount, sgst_amount, igst_amount, total_amount, discount_amount
      into v_totals
      from public.service_invoices where id = v_e.document_id;

    select jsonb_agg(item order by item_no)
      into v_items
      from (
        select row_number() over (order by l.line_number) as item_no,
               jsonb_build_object(
                 'SlNo',      row_number() over (order by l.line_number)::text,
                 'PrdDesc',   left(l.description, 300),
                 'IsServc',   case when l.line_type = 'LABOUR' then 'Y' else 'N' end,
                 'HsnCd',     coalesce(l.hsn_code, '9999'),
                 'Qty',       l.quantity,
                 'Unit',      'NOS',
                 'UnitPrice', l.unit_rate,
                 'TotAmt',    round(l.unit_rate * l.quantity, 2),
                 'Discount',  l.discount,
                 'AssAmt',    l.taxable_value,
                 'GstRt',     coalesce(l.cgst_rate, 0) + coalesce(l.sgst_rate, 0) + coalesce(l.igst_rate, 0),
                 'CgstAmt',   l.cgst_amount,
                 'SgstAmt',   l.sgst_amount,
                 'IgstAmt',   l.igst_amount,
                 'TotItemVal', l.total_amount) as item
          from public.service_lines l where l.invoice_id = v_e.document_id
      ) numbered;
  end if;

  if v_items is null then
    raise exception 'Invoice % has no lines to file.', v_e.document_number
      using errcode = 'check_violation';
  end if;

  -- Intra-state when buyer and seller are in the same state. B2C with no state
  -- recorded is treated as intra-state, which is what the tax on the invoice
  -- already assumed when CGST/SGST were charged.
  v_intra := coalesce(v_buyer.state_code, v_seller.state_code) = v_seller.state_code;

  return jsonb_build_object(
    'Version', '1.1',
    'TranDtls', jsonb_build_object(
      'TaxSch', 'GST',
      -- B2B where the buyer has a GSTIN; otherwise a B2C supply.
      'SupTyp', case when v_buyer.gstin is not null then 'B2B' else 'B2C' end,
      'RegRev', 'N',
      'IgstOnIntra', case when v_intra then 'N' else 'Y' end),
    'DocDtls', jsonb_build_object(
      'Typ', 'INV',
      'No',  v_e.document_number,
      'Dt',  to_char(v_e.document_date, 'DD/MM/YYYY')),
    'SellerDtls', jsonb_build_object(
      'Gstin',  v_seller.gstin,
      'LglNm',  v_seller.name,
      'Addr1',  coalesce(v_seller.address_line1, v_seller.city, 'NA'),
      'Loc',    coalesce(v_seller.city, 'NA'),
      'Pin',    coalesce(v_seller.pincode, '000000')::int,
      'Stcd',   v_seller.state_code),
    'BuyerDtls', jsonb_build_object(
      -- URP ("unregistered person") is the portal's own marker for a B2C buyer.
      'Gstin',  coalesce(v_buyer.gstin, 'URP'),
      'LglNm',  coalesce(v_buyer.name, 'Cash customer'),
      'Pos',    coalesce(v_buyer.state_code, v_seller.state_code),
      'Addr1',  coalesce(v_buyer.address_line1, v_buyer.city, 'NA'),
      'Loc',    coalesce(v_buyer.city, 'NA'),
      'Pin',    coalesce(v_buyer.pincode, '000000')::int,
      'Stcd',   coalesce(v_buyer.state_code, v_seller.state_code)),
    'ItemList', v_items,
    'ValDtls', jsonb_build_object(
      'AssVal',    v_totals.taxable_value,
      'CgstVal',   v_totals.cgst_amount,
      'SgstVal',   v_totals.sgst_amount,
      'IgstVal',   v_totals.igst_amount,
      'Discount',  coalesce(v_totals.discount_amount, 0),
      'TotInvVal', v_totals.total_amount)
  );
end;
$$;

comment on function public.einvoice_payload(uuid) is
  'Builds the IRP document (NIC schema 1.1) for a queued e-invoice (spec §40). '
  'Field names are the portal''s, not this schema''s.';

-- -----------------------------------------------------------------------------
-- public.record_einvoice_request() — what we sent, and that we tried
-- -----------------------------------------------------------------------------
-- Called before the request leaves. If the reply never arrives, the row still
-- shows the payload and a raised attempt count, so nobody has to guess whether
-- the portal saw it.
--
-- The count itself is the trigger's, not this function's — see the redefinition
-- of app.einvoice_attempt() below.
-- -----------------------------------------------------------------------------
create or replace function public.record_einvoice_request(
  p_einvoice_id uuid,
  p_payload     jsonb
)
returns void
language plpgsql
as $$
begin
  update public.einvoices
     set request_payload = p_payload,
         -- A document being retried is in flight, not failed, so it goes back to
         -- PENDING as the previous error is cleared. Leaving it FAILED with no
         -- message would violate einvoices_failed_check, and rightly: a failed
         -- row must always say why it failed.
         status          = 'PENDING',
         error_code      = null,
         error_message   = null
   where id = p_einvoice_id
     and status <> 'GENERATED';

  if not found then
    raise exception 'That e-invoice is already generated, or does not exist.'
      using errcode = 'check_violation';
  end if;
end;
$$;

comment on function public.record_einvoice_request(uuid, jsonb) is
  'Stores the payload and counts the attempt before transmission (spec §40), so '
  'a lost reply still leaves evidence of what was sent.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.einvoice_payload(uuid) to authenticated';
    execute 'grant execute on function public.record_einvoice_request(uuid, jsonb) to authenticated';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_einvoice_result() — the outcome of an attempt, not a new one
-- -----------------------------------------------------------------------------
-- 0034 incremented attempt_count here, which was right while nothing recorded
-- the request: the result was the only evidence an attempt had happened. Now
-- that record_einvoice_request() counts the attempt as it goes out, counting
-- again here would make every filing look like two, and "3 attempts" on a row
-- that was tried twice is the kind of number nobody can act on.
--
-- The attempt is made when the request leaves. This records how it ended.
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
         last_attempt_at = now()
   where id = p_einvoice_id;

  if not found then
    raise exception 'E-invoice record not found.' using errcode = 'no_data_found';
  end if;
end;
$$;

comment on function public.record_einvoice_result(uuid, text, text, text, timestamptz, text, text, text, jsonb) is
  'Records how a filing attempt ended (spec §40). The attempt itself is counted '
  'by record_einvoice_request() when the request goes out.';


-- -----------------------------------------------------------------------------
-- app.einvoice_attempt() — count attempts when they are made, not when they land
-- -----------------------------------------------------------------------------
-- 0024 put retry bookkeeping in the database rather than the caller, which is
-- right. It counted on the transition to GENERATED or FAILED — the only evidence
-- available while nothing recorded the outgoing request.
--
-- Two problems with leaving it there. record_einvoice_result() *also*
-- incremented, so every completed filing counted twice. And an attempt whose
-- reply never arrives never reached a terminal status, so it was never counted
-- at all — the one case where knowing an attempt was made matters most.
--
-- So the count moves to where the attempt actually starts: a new request
-- payload going out. One filing, one attempt, counted even when the reply is
-- lost.
-- -----------------------------------------------------------------------------
create or replace function app.einvoice_attempt()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'UPDATE' and new.request_payload is distinct from old.request_payload then
    new.attempt_count := old.attempt_count + 1;
    new.last_attempt_at := now();
  end if;
  return new;
end;
$$;


commit;
