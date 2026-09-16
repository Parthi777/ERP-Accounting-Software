-- =============================================================================
-- INCREMENTAL 0074 → 0074
-- =============================================================================
-- GENERATED FILE. Regenerate with:
--   FROM=0074 bash scripts/build-incremental.sh
--
-- For a database that ALREADY has migrations up to 0073.
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
-- SOURCE: supabase/migrations/0074_einvoice_eligibility.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0074 — The e-invoices the portal would have rejected
-- =============================================================================
-- Spec §16, §40, §55.
--
-- Nothing here has ever run against a real IRP. The client is genuine and its
-- 22 unit tests pass, but they mock fetch — they assert how a reply is handled,
-- never whether the portal would accept what was sent. Four things in the body
-- would have come back as errors, and the first is not an edge case for a
-- two-wheeler dealer: it is most of their business.
--
-- 1. B2C INVOICES ARE QUEUED AND FILED, AND CANNOT BE.
--
--    einvoice_payload() sets TranDtls.SupTyp to 'B2C' when the buyer has no
--    GSTIN. 'B2C' is not one of the values the NIC schema takes — the list is
--    B2B, SEZWP, SEZWOP, EXPWP, EXPWOP, DEXP — because e-invoicing under rule
--    48(4) does not apply to B2C supplies at all. A B2C sale has no IRN to get;
--    what a large taxpayer owes on a B2C invoice is a dynamic QR code under rule
--    46(r), which is a different mechanism and not this one.
--
--    queue_einvoice() has no eligibility test, einvoice_queue() offers every
--    posted invoice, and the screen shows "No GSTIN — B2C" beside a File button
--    that is just as enabled as any other. Nearly every vehicle a dealer sells
--    goes to an individual with no GSTIN, so pointing this at the live portal
--    would have produced a column of failures, each one correct.
--
-- 2. IgstOnIntra IS INVERTED.
--
--    The flag means "IGST is charged although buyer and seller are in the same
--    state" — an intra-state supply taxed as inter-state, which is rare and
--    specific. The body sets it to 'Y' for every *inter*-state sale, which is
--    the ordinary case and the opposite of what the flag says. The portal reads
--    a document claiming an intra-state supply while POS names another state,
--    and rejects the contradiction.
--
-- 3. A TAXED LINE WITH NO HSN IS FILED AS '9999'.
--
--    '9999' is not an HSN. Filing one puts a fabricated classification on a
--    statutory document, and unlike a rejected request that survives being
--    accepted.
--
--    The rule added below is narrower than "every line needs an HSN", because
--    that would block every vehicle invoice this system produces:
--    create_vehicle_sale_draft gives the VEHICLE line an HSN from the model and
--    gives INSURANCE, REGISTRATION, FORWARDING and OTHER_CHARGE none, since they
--    are pass-through charges at zero GST. A line that carries GST is a supply
--    and must be classified; a zero-rated pass-through is a different question,
--    and an open one — see the note at the foot of this file.
--
-- 4. A MISSING PINCODE IS FILED AS ZERO.
--
--    coalesce(pincode, '000000')::int is 0, which is not a pincode, and ::int
--    raises outright on a pincode with a space or a letter in it — a cast error
--    from inside a payload builder, which names nothing the user can act on.
--
-- WHAT CHANGES.
--
-- The rule throughout is that a document which cannot be filed says so before
-- the request leaves, naming the record and the field, rather than after it,
-- naming an IRP error code (spec §55). einvoice_blockers() is that test, and it
-- is the same test in all three places that need it: the queue lists it, the
-- payload builder refuses on it, and queue_einvoice() will not enqueue past it.
--
-- Rollback: restore public.einvoice_payload(uuid) from 0048,
--           public.queue_einvoice(text, uuid) and public.einvoice_queue(date,
--           date, uuid) from 0034; drop function public.einvoice_blockers(text,
--           uuid).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.einvoice_blockers() — why this document cannot be filed, or null
-- -----------------------------------------------------------------------------
-- One sentence, or null when the document is filable. Returned by the queue so
-- the screen can disable File and say why, and raised by the payload builder so
-- an API caller gets the same answer.
-- -----------------------------------------------------------------------------
create or replace function public.einvoice_blockers(
  p_document_type text,
  p_document_id   uuid
)
returns text
language plpgsql
stable
as $$
declare
  v_seller  record;
  v_buyer   record;
  v_missing int;
begin
  if p_document_type = 'SALE' then
    select coalesce(b.gstin, d.gstin) as gstin, b.pincode,
           coalesce(b.state_code, d.state_code) as state_code
      into v_seller
      from public.sales s
      join public.branches b on b.id = s.branch_id
      join public.dealers d on d.id = s.dealer_id
     where s.id = p_document_id;

    select c.name, c.gstin, c.pincode, c.state_code into v_buyer
      from public.sales s left join public.customers c on c.id = s.customer_id
     where s.id = p_document_id;

    select count(*)::int into v_missing from public.sale_lines l
     where l.sale_id = p_document_id
       and coalesce(btrim(l.hsn_code), '') = ''
       and coalesce(l.cgst_rate, 0) + coalesce(l.sgst_rate, 0) + coalesce(l.igst_rate, 0) > 0;
  elsif p_document_type = 'SERVICE_INVOICE' then
    select coalesce(b.gstin, d.gstin) as gstin, b.pincode,
           coalesce(b.state_code, d.state_code) as state_code
      into v_seller
      from public.service_invoices si
      join public.branches b on b.id = si.branch_id
      join public.dealers d on d.id = si.dealer_id
     where si.id = p_document_id;

    select c.name, c.gstin, c.pincode, c.state_code into v_buyer
      from public.service_invoices si left join public.customers c on c.id = si.customer_id
     where si.id = p_document_id;

    select count(*)::int into v_missing from public.service_lines l
     where l.invoice_id = p_document_id
       and coalesce(btrim(l.hsn_code), '') = ''
       and coalesce(l.cgst_rate, 0) + coalesce(l.sgst_rate, 0) + coalesce(l.igst_rate, 0) > 0;
  else
    return 'Only a vehicle sale or a service invoice can be filed.';
  end if;

  -- The one that decides most of them.
  if coalesce(btrim(v_buyer.gstin), '') = '' then
    return 'No customer GSTIN — a B2C supply is not filed on the IRP. '
        || 'Add the GSTIN if this buyer is registered.';
  end if;

  if coalesce(btrim(v_seller.gstin), '') = '' then
    return 'The branch raising this invoice has no GSTIN, and neither has the dealer.';
  end if;
  if coalesce(btrim(v_seller.state_code), '') !~ '^[0-9]{2}$' then
    return 'The branch has no valid state code.';
  end if;
  if coalesce(btrim(v_seller.pincode), '') !~ '^[0-9]{6}$' then
    return 'The branch has no valid six-digit pincode.';
  end if;
  if coalesce(btrim(v_buyer.pincode), '') !~ '^[0-9]{6}$' then
    return format('%s has no valid six-digit pincode.', coalesce(v_buyer.name, 'The customer'));
  end if;
  if coalesce(btrim(v_buyer.state_code), '') !~ '^[0-9]{2}$' then
    return format('%s has no valid state code, and it is the place of supply.',
                  coalesce(v_buyer.name, 'The customer'));
  end if;
  if v_missing > 0 then
    return format('%s taxed line(s) have no HSN/SAC code. A line carrying GST has to '
               || 'be classified, and the portal will not take a guess.', v_missing);
  end if;

  return null;
end;
$$;

comment on function public.einvoice_blockers(text, uuid) is
  'Why this document cannot be filed on the IRP, or null when it can (spec §40, '
  '§55). One test, read by the queue, the payload builder and queue_einvoice, so '
  'the screen and the API cannot disagree about what is filable.';

-- -----------------------------------------------------------------------------
-- public.einvoice_payload() — corrected, and refusing what it cannot build
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
  v_blocker  text;
begin
  select * into v_e from public.einvoices where id = p_einvoice_id;
  if v_e.id is null then
    raise exception 'E-invoice not found.' using errcode = 'no_data_found';
  end if;

  -- The same test the screen applied, applied again here: an API caller reaching
  -- past the queue gets the same answer, and it is a sentence rather than an
  -- error code from the portal (spec §55).
  v_blocker := public.einvoice_blockers(v_e.document_type, v_e.document_id);
  if v_blocker is not null then
    raise exception 'Invoice % cannot be filed: %', v_e.document_number, v_blocker
      using errcode = 'check_violation';
  end if;

  -- ── Seller: the branch that raised it, falling back to the dealer ─────────
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
                 -- A taxed line always has one by now; einvoice_blockers() saw
                 -- to that. The fallback is reached only by a zero-rated
                 -- pass-through charge — see the note at the foot of 0074.
                 'HsnCd',     coalesce(nullif(btrim(l.hsn_code), ''), '9999'),
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
                 -- A taxed line always has one by now; einvoice_blockers() saw
                 -- to that. The fallback is reached only by a zero-rated
                 -- pass-through charge — see the note at the foot of 0074.
                 'HsnCd',     coalesce(nullif(btrim(l.hsn_code), ''), '9999'),
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

  -- Both state codes are present and valid by now — einvoice_blockers() would
  -- have turned the document back otherwise.
  v_intra := v_buyer.state_code = v_seller.state_code;

  return jsonb_build_object(
    'Version', '1.1',
    'TranDtls', jsonb_build_object(
      'TaxSch', 'GST',
      -- Every document reaching here has a registered buyer: the rest were
      -- turned away. B2C is absent from this enum because it is absent from the
      -- portal's.
      'SupTyp', 'B2B',
      'RegRev', 'N',
      -- "IGST although both parties are in one state" — not "this is an
      -- inter-state supply", which is what Pos and Stcd already say.
      'IgstOnIntra', case when v_intra and coalesce(v_totals.igst_amount, 0) > 0
                         then 'Y' else 'N' end),
    'DocDtls', jsonb_build_object(
      'Typ', 'INV',
      'No',  v_e.document_number,
      'Dt',  to_char(v_e.document_date, 'DD/MM/YYYY')),
    'SellerDtls', jsonb_build_object(
      'Gstin',  v_seller.gstin,
      'LglNm',  v_seller.name,
      'Addr1',  coalesce(v_seller.address_line1, v_seller.city, 'NA'),
      'Loc',    coalesce(v_seller.city, 'NA'),
      'Pin',    btrim(v_seller.pincode)::int,
      'Stcd',   v_seller.state_code),
    'BuyerDtls', jsonb_build_object(
      'Gstin',  btrim(v_buyer.gstin),
      'LglNm',  v_buyer.name,
      'Pos',    v_buyer.state_code,
      'Addr1',  coalesce(v_buyer.address_line1, v_buyer.city, 'NA'),
      'Loc',    coalesce(v_buyer.city, 'NA'),
      'Pin',    btrim(v_buyer.pincode)::int,
      'Stcd',   v_buyer.state_code),
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
  'Field names are the portal''s, not this schema''s. Refuses anything '
  'einvoice_blockers() names, so a document is turned back with a sentence '
  'rather than an IRP error code.';

-- -----------------------------------------------------------------------------
-- public.queue_einvoice() — will not enqueue what cannot be filed
-- -----------------------------------------------------------------------------
create or replace function public.queue_einvoice(
  p_document_type text,
  p_document_id   uuid
)
returns uuid
language plpgsql
as $$
declare
  v_dealer  uuid;
  v_number  text;
  v_date    date;
  v_id      uuid;
  v_status  text;
  v_blocker text;
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

  -- Refused here rather than at transmission, so a B2C sale never becomes a
  -- PENDING row that somebody has to explain later.
  v_blocker := public.einvoice_blockers(p_document_type, p_document_id);
  if v_blocker is not null then
    raise exception 'Invoice % cannot be filed: %', v_number, v_blocker
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
                  end
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.queue_einvoice(text, uuid) is
  'Queues a posted invoice for the IRP (spec §40), refusing anything '
  'einvoice_blockers() names — a B2C supply above all, which has no IRN to get.';

-- -----------------------------------------------------------------------------
-- public.einvoice_queue() — carries the reason, so the screen can show it
-- -----------------------------------------------------------------------------
-- A column cannot be added to a function's result with `create or replace`, so
-- the old one is dropped first. Same reason as 0071.
-- -----------------------------------------------------------------------------
drop function if exists public.einvoice_queue(date, date, uuid);

create function public.einvoice_queue(
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
  attempt_count   integer,
  blocked_reason  text
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
         coalesce(e.attempt_count, 0),
         -- Null once an IRN exists: a filed document is not re-examined for
         -- blockers it no longer has to pass.
         case when e.status = 'GENERATED' then null
              else public.einvoice_blockers(d.dtype, d.id) end
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
    execute 'grant execute on function public.einvoice_blockers(text, uuid) to authenticated';
    execute 'grant execute on function public.einvoice_queue(date, date, uuid) to authenticated';
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- STILL OPEN, and only the portal can settle it
-- -----------------------------------------------------------------------------
-- Insurance, registration and forwarding go out as ItemList lines with zero GST
-- and HsnCd '9999', and their amounts are inside AssVal. Collected as a pure
-- agent they are arguably not supplies at all, and the NIC schema has a place
-- for exactly that: ValDtls.OthChrg, which sits outside the item list and
-- outside the assessable value.
--
-- Moving them there changes AssVal, the item totals and how TotInvVal
-- reconciles, so it is not a change to make against a mocked fetch. It is the
-- first thing to put through the sandbox, and the answer decides whether '9999'
-- ever leaves this file.
-- -----------------------------------------------------------------------------

insert into public.schema_migrations (version, name)
values ('0074', 'einvoice_eligibility') on conflict (version) do nothing;


commit;
