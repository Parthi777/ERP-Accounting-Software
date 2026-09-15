-- =============================================================================
-- 0068 — E-way bills: the document that has to travel with the vehicle
-- =============================================================================
-- Spec §40, §41, §55.
--
-- What existed. 0024 created public.eway_bills, 0034 added queue_eway_bill(),
-- and the GST screen listed the rows. Nothing has ever called the queue
-- function: `queueEwayBillAction` had no callers anywhere in the product, so a
-- row could only ever be created by typing SQL. The screen's own empty state
-- said bills "are queued from a sale or a stock transfer", describing a path
-- that did not exist.
--
-- Why it matters more than a missing screen. An e-way bill is not paperwork the
-- dealer chooses to raise. Goods above the notified value may not move without
-- one, and a vehicle stopped without it is detained along with its consignment
-- (s.68 CGST Act, Rule 138). E-invoicing was built end to end in 0048; this is
-- the half of the same obligation that was left as a table.
--
-- ── What this adds ──────────────────────────────────────────────────────────
--
--   eway_bill_payload()     the EWB-1 document, built from what was sold
--   record_eway_request()   stores it before transmission, counts the attempt
--   record_eway_result()    records how the attempt ended
--   eway_bill_required()    whether the threshold is met, per configuration
--   eway_expected_validity() one day per 200km, which is the rule in Rule 138
--
-- The shape deliberately mirrors 0048. One integration pattern for both halves
-- of GST filing is easier to reason about than two, and the provider adapter on
-- the TypeScript side is shared.
--
-- ── The threshold is configuration, not a constant ──────────────────────────
--
-- ₹50,000 is the common figure and it is not universal: states set their own
-- limit for movement within the state, and several use ₹1,00,000. Hard-coding
-- 50000 would be wrong for those dealers in the direction that matters — it
-- would demand a bill that is not required, and the dealer would stop trusting
-- the warning. Two settings, defaulting to the common case.
--
-- Rollback: drop the four functions; delete the two settings. The table and
-- queue_eway_bill() predate this migration.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Thresholds
-- -----------------------------------------------------------------------------
-- Platform defaults, with dealer_id null. A dealer-scoped row of the same key
-- overrides them, which is how system_settings is meant to work and is the only
-- shape that survives provisioning: a per-dealer insert here would cover the
-- dealers that existed when this migration ran and no one onboarded afterwards.
-- Migrations run before any dealer exists at all, so that insert would have
-- created nothing whatsoever.
insert into public.system_settings (dealer_id, key, value, value_type, description, is_public)
values
  (null, 'eway.threshold_interstate', '50000'::jsonb, 'number',
   'Consignment value above which an e-way bill is required for movement to another state (Rule 138).', true),
  (null, 'eway.threshold_intrastate', '50000'::jsonb, 'number',
   'The same, for movement within the state. States differ — several use 1,00,000. Add a dealer-scoped row to override.', true)
on conflict on constraint system_settings_scope_key do nothing;

-- -----------------------------------------------------------------------------
-- public.eway_bill_required() — is one needed for this document?
-- -----------------------------------------------------------------------------
-- Returns the answer and the reasoning, because "no" is a claim the dealer is
-- relying on and they should be able to see why.
-- -----------------------------------------------------------------------------
create or replace function public.eway_bill_required(
  p_document_type text,
  p_document_id   uuid
)
returns table (required boolean, consignment_value numeric, threshold numeric, interstate boolean)
language plpgsql
stable
as $$
declare
  v_dealer   uuid;
  v_value    numeric(18, 4);
  v_from     text;
  v_to       text;
  v_key      text;
begin
  if p_document_type = 'SALE' then
    select s.dealer_id, s.total_amount,
           coalesce(b.state_code, d.state_code), coalesce(c.state_code, coalesce(b.state_code, d.state_code))
      into v_dealer, v_value, v_from, v_to
      from public.sales s
      join public.branches b on b.id = s.branch_id
      join public.dealers  d on d.id = s.dealer_id
      join public.customers c on c.id = s.customer_id
     where s.id = p_document_id;

  elsif p_document_type = 'SERVICE_INVOICE' then
    select si.dealer_id, si.total_amount,
           coalesce(b.state_code, d.state_code), coalesce(c.state_code, coalesce(b.state_code, d.state_code))
      into v_dealer, v_value, v_from, v_to
      from public.service_invoices si
      join public.branches b on b.id = si.branch_id
      join public.dealers  d on d.id = si.dealer_id
      left join public.customers c on c.id = si.customer_id
     where si.id = p_document_id;

  elsif p_document_type = 'TRANSFER' then
    -- A branch transfer moves stock the dealer still owns. It needs a bill on
    -- the same value test: the goods are on a public road either way.
    select t.dealer_id,
           coalesce(v.purchase_cost, 0),
           coalesce(bf.state_code, d.state_code),
           coalesce(bt.state_code, d.state_code)
      into v_dealer, v_value, v_from, v_to
      from public.vehicle_transfers t
      join public.dealers  d  on d.id = t.dealer_id
      join public.branches bf on bf.id = t.from_branch_id
      join public.branches bt on bt.id = t.to_branch_id
      left join public.vehicles v on v.id = t.vehicle_id
     where t.id = p_document_id;
  else
    raise exception 'Unsupported document type %.', p_document_type using errcode = 'check_violation';
  end if;

  if v_dealer is null then
    raise exception 'Document not found.' using errcode = 'no_data_found';
  end if;

  interstate := coalesce(v_from, '') <> coalesce(v_to, '');
  v_key := case when interstate then 'eway.threshold_interstate' else 'eway.threshold_intrastate' end;

  select coalesce((value #>> '{}')::numeric, 50000) into threshold
    from public.system_settings
   where key = v_key and (dealer_id = v_dealer or dealer_id is null)
   order by dealer_id nulls last
   limit 1;

  threshold := coalesce(threshold, 50000);
  consignment_value := coalesce(v_value, 0);
  required := consignment_value > threshold;
  return next;
end;
$$;

comment on function public.eway_bill_required(text, uuid) is
  'Whether Rule 138 requires an e-way bill for this document, with the value and '
  'threshold it was judged against. The threshold is configuration: states differ '
  'on movement within the state, and several use 1,00,000.';

-- -----------------------------------------------------------------------------
-- public.eway_expected_validity() — how long the bill will be good for
-- -----------------------------------------------------------------------------
-- Rule 138(10): one day per 200km or part thereof, counted from generation. The
-- portal is the authority and its answer is stored when it replies; this is what
-- to expect, so a dispatcher can see whether the journey fits before sending.
-- -----------------------------------------------------------------------------
create or replace function public.eway_expected_validity(
  p_distance_km integer,
  p_from        timestamptz default now()
)
returns timestamptz
language sql
immutable
as $$
  select p_from + (greatest(ceil(coalesce(p_distance_km, 0)::numeric / 200), 1) || ' days')::interval;
$$;

comment on function public.eway_expected_validity(integer, timestamptz) is
  'One day per 200km or part thereof (Rule 138(10)). Indicative: the portal '
  'assigns the real validity and record_eway_result stores what it said.';

-- -----------------------------------------------------------------------------
-- public.eway_bill_payload() — the EWB-1 document
-- -----------------------------------------------------------------------------
create or replace function public.eway_bill_payload(p_eway_id uuid)
returns jsonb
language plpgsql
stable
as $$
declare
  v_e      public.eway_bills;
  v_seller record;
  v_buyer  record;
  v_items  jsonb;
  v_total  numeric(18, 4) := 0;
begin
  select * into v_e from public.eway_bills where id = p_eway_id;
  if v_e.id is null then
    raise exception 'E-way bill not found.' using errcode = 'no_data_found';
  end if;

  if v_e.document_type <> 'SALE' then
    -- Service invoices and branch transfers can be queued and tracked, but the
    -- payload for each is a different document under Rule 138 (delivery challan
    -- rather than tax invoice). Refusing is better than sending a sale-shaped
    -- body and having the portal reject it for reasons nobody can read.
    raise exception 'Only a sale can be filed automatically yet; % must be raised on the portal.',
      v_e.document_type using errcode = 'feature_not_supported';
  end if;

  select coalesce(b.gstin, d.gstin) as gstin,
         d.legal_name as name,
         b.address_line1, b.city, b.pincode,
         coalesce(b.state_code, d.state_code) as state_code
    into v_seller
    from public.sales s
    join public.branches b on b.id = s.branch_id
    join public.dealers  d on d.id = s.dealer_id
   where s.id = v_e.document_id;

  select c.gstin, c.name, c.address_line1, c.city, c.pincode,
         coalesce(c.state_code, v_seller.state_code) as state_code
    into v_buyer
    from public.sales s
    join public.customers c on c.id = s.customer_id
   where s.id = v_e.document_id;

  select jsonb_agg(jsonb_build_object(
           'productName', l.description,
           'hsnCode',     coalesce(l.hsn_code, ''),
           'quantity',    l.quantity,
           'taxableAmount', l.taxable_value,
           'cgstRate',    coalesce(l.cgst_rate, 0),
           'sgstRate',    coalesce(l.sgst_rate, 0),
           'igstRate',    coalesce(l.igst_rate, 0)
         ) order by l.line_number),
         sum(l.total_amount)
    into v_items, v_total
    from public.sale_lines l
   where l.sale_id = v_e.document_id;

  return jsonb_build_object(
    'supplyType',   'O',                      -- outward
    'subSupplyType','1',                      -- supply
    'docType',      'INV',
    'docNo',        v_e.document_number,
    'docDate',      to_char((select invoice_date from public.sales where id = v_e.document_id), 'DD/MM/YYYY'),
    'fromGstin',    coalesce(v_seller.gstin, 'URP'),
    'fromTrdName',  v_seller.name,
    'fromAddr1',    coalesce(v_seller.address_line1, ''),
    'fromPlace',    coalesce(v_seller.city, ''),
    'fromPincode',  coalesce(v_seller.pincode, ''),
    'fromStateCode', v_seller.state_code,
    -- An unregistered buyer is URP, exactly as on the invoice itself.
    'toGstin',      coalesce(v_buyer.gstin, 'URP'),
    'toTrdName',    v_buyer.name,
    'toAddr1',      coalesce(v_buyer.address_line1, ''),
    'toPlace',      coalesce(v_buyer.city, ''),
    'toPincode',    coalesce(v_buyer.pincode, ''),
    'toStateCode',  v_buyer.state_code,
    'totalValue',   v_total,
    'transMode',    case v_e.transport_mode
                      when 'ROAD' then '1' when 'RAIL' then '2'
                      when 'AIR'  then '3' when 'SHIP' then '4' else '1' end,
    'transDistance', coalesce(v_e.distance_km, 0)::text,
    'vehicleNo',    coalesce(v_e.vehicle_number, ''),
    'transporterId', coalesce(v_e.transporter_id, ''),
    'transporterName', coalesce(v_e.transporter_name, ''),
    'itemList',     coalesce(v_items, '[]'::jsonb)
  );
end;
$$;

comment on function public.eway_bill_payload(uuid) is
  'The EWB-1 body for a sale (spec §40). Refuses a service invoice or a transfer: '
  'each moves under a different document and a sale-shaped body would be rejected '
  'by the portal for reasons nobody could read.';

-- -----------------------------------------------------------------------------
-- Request and result, as 0048 does for e-invoices
-- -----------------------------------------------------------------------------
create or replace function public.record_eway_request(p_eway_id uuid, p_payload jsonb)
returns void
language plpgsql
as $$
begin
  update public.eway_bills
     set request_payload = p_payload,
         status          = 'PENDING',
         error_message   = null,
         -- Counted as the request leaves, so a lost reply still leaves evidence
         -- that an attempt was made.
         attempt_count   = attempt_count + 1,
         updated_at      = now()
   where id = p_eway_id
     and status <> 'GENERATED';

  if not found then
    raise exception 'That e-way bill is already generated, or does not exist.'
      using errcode = 'check_violation';
  end if;
end;
$$;

create or replace function public.record_eway_result(
  p_eway_id     uuid,
  p_status      text,
  p_number      text default null,
  p_valid_until timestamptz default null,
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
  if p_status = 'GENERATED' and p_number is null then
    raise exception 'A generated e-way bill must carry its number.' using errcode = 'check_violation';
  end if;
  if p_status = 'FAILED' and p_error is null then
    raise exception 'A failed e-way bill must record why.' using errcode = 'check_violation';
  end if;

  update public.eway_bills
     set status           = p_status,
         eway_bill_number = coalesce(p_number, eway_bill_number),
         generated_at     = case when p_status = 'GENERATED' then coalesce(generated_at, now()) else generated_at end,
         valid_until      = coalesce(p_valid_until, valid_until),
         error_message    = p_error,
         response_payload = coalesce(p_response, response_payload),
         updated_at       = now()
   where id = p_eway_id;

  if not found then
    raise exception 'E-way bill record not found.' using errcode = 'no_data_found';
  end if;
end;
$$;

comment on function public.record_eway_result(uuid, text, text, timestamptz, text, jsonb) is
  'The outcome of one attempt (spec §40, §55). A portal failure never disturbs '
  'the invoice: the sale stays posted and the bill is retried.';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  execute 'grant execute on function public.eway_bill_required(text, uuid) to authenticated';
  execute 'grant execute on function public.eway_expected_validity(integer, timestamptz) to authenticated';
  execute 'grant execute on function public.eway_bill_payload(uuid) to authenticated';
  execute 'grant execute on function public.record_eway_request(uuid, jsonb) to authenticated';
  execute 'grant execute on function public.record_eway_result(uuid, text, text, timestamptz, text, jsonb) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0068', 'eway_bill') on conflict (version) do nothing;
