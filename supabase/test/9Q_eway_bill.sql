-- =============================================================================
-- TEST — e-way bills (spec §40)
-- =============================================================================
-- An e-way bill is not paperwork a dealer chooses to raise. Goods above the
-- notified value may not move without one, and a vehicle stopped without it is
-- detained along with its consignment (s.68 CGST Act, Rule 138).
--
-- Until 0068 the table existed, queue_eway_bill() existed, and nothing called
-- either: the screen described a workflow with no code path behind it.
--
-- The guarantees asserted here:
--   * the threshold is read from configuration, not hard-coded — states differ
--     on intra-state movement and several use 1,00,000;
--   * validity is one day per 200km *or part thereof*, which is the boundary
--     everyone gets wrong;
--   * the payload carries what Rule 138 needs, with URP for an unregistered
--     buyer exactly as the invoice does;
--   * a failed filing leaves the sale untouched — spec §40 is explicit that an
--     external failure must not corrupt the accounting transaction;
--   * a document type that cannot be represented is refused rather than sent.
-- =============================================================================

\echo '--- e-way bills ---'

do $$
declare
  v_dealer uuid;
  v_sale   uuid;
  v_id     uuid;
  v_req    record;
  v_pay    jsonb;
  v_before int;
  v_after  int;
  v_status text;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_sale from public.sales
   where dealer_id = v_dealer and status in ('POSTED', 'DELIVERED')
   order by invoice_number limit 1;

  if v_sale is null then
    raise notice '  -- no posted sale here; skipping';
    return;
  end if;

  -- ── The threshold, and where it comes from ──────────────────────────────
  select * into v_req from public.eway_bill_required('SALE', v_sale);
  perform app_test.assert_equals(
    v_req.threshold, 50000::numeric,
    'the default threshold is the common 50,000'
  );
  perform app_test.assert_equals(
    v_req.required, v_req.consignment_value > v_req.threshold,
    'required is exactly "value above threshold"'
  );

  -- Configuration, not a constant: a dealer in a state using 1,00,000 sets it
  -- and the answer changes. Hard-coding would demand a bill that is not
  -- required, and a warning that cries wolf stops being read.
  -- A dealer-scoped row overriding the platform default, which is how a dealer
  -- in a state using 1,00,000 configures it.
  insert into public.system_settings (dealer_id, key, value, value_type, is_public)
  values (v_dealer, 'eway.threshold_intrastate', '99999999'::jsonb, 'number', true)
  on conflict on constraint system_settings_scope_key
    do update set value = '99999999'::jsonb;

  select * into v_req from public.eway_bill_required('SALE', v_sale);
  perform app_test.assert_equals(
    v_req.required, false,
    'raising the configured threshold removes the requirement'
  );

  delete from public.system_settings
   where dealer_id = v_dealer and key = 'eway.threshold_intrastate';

  select * into v_req from public.eway_bill_required('SALE', v_sale);
  perform app_test.assert_equals(
    v_req.threshold, 50000::numeric,
    'and removing the override falls back to the platform default'
  );

  -- ── Validity: one day per 200km OR PART THEREOF ─────────────────────────
  perform app_test.assert_equals(
    public.eway_expected_validity(200, timestamptz '2026-04-01 10:00+05:30'),
    timestamptz '2026-04-02 10:00+05:30',
    '200km is one day'
  );
  perform app_test.assert_equals(
    public.eway_expected_validity(201, timestamptz '2026-04-01 10:00+05:30'),
    timestamptz '2026-04-03 10:00+05:30',
    'and 201km is two — "or part thereof" is the boundary people get wrong'
  );
  perform app_test.assert_equals(
    public.eway_expected_validity(0, timestamptz '2026-04-01 10:00+05:30'),
    timestamptz '2026-04-02 10:00+05:30',
    'a journey with no distance recorded still gets a day, never zero'
  );

  -- ── Queue, and the payload it produces ──────────────────────────────────
  v_id := public.queue_eway_bill('SALE', v_sale, 'ROAD', 'TN37AB1234', 120, null, 'Local Carrier');
  v_pay := public.eway_bill_payload(v_id);

  perform app_test.assert_equals(
    v_pay->>'docNo', (select invoice_number from public.sales where id = v_sale),
    'the payload names the invoice it accompanies'
  );
  perform app_test.assert_equals(
    (v_pay->>'vehicleNo'), 'TN37AB1234', 'and the vehicle that will carry it'
  );
  perform app_test.assert_equals(
    (jsonb_array_length(v_pay->'itemList') > 0), true,
    'and itemises the consignment'
  );
  -- URP, exactly as the tax invoice does for an unregistered buyer.
  perform app_test.assert_equals(
    (v_pay->>'toGstin' = 'URP') = (select gstin is null from public.customers c
                                     join public.sales s on s.customer_id = c.id
                                    where s.id = v_sale),
    true,
    'an unregistered buyer is URP, as on the invoice'
  );

  -- ── Queueing twice is one bill, not two ─────────────────────────────────
  perform public.queue_eway_bill('SALE', v_sale, 'ROAD', 'TN37XY9999', 150);
  select count(*) into v_after from public.eway_bills
   where document_type = 'SALE' and document_id = v_sale;
  perform app_test.assert_equals(
    v_after, 1, 'one consignment has one e-way bill — the second call updates it'
  );
  perform app_test.assert_equals(
    (select vehicle_number from public.eway_bills where id = v_id), 'TN37XY9999',
    'and the corrected vehicle number replaces the old one'
  );

  -- ── A failed filing must not disturb the sale (spec §40) ────────────────
  select count(*) into v_before from public.journal_entry_lines l
    join public.journal_entries e on e.id = l.journal_entry_id
   where e.dealer_id = v_dealer;

  perform public.record_eway_request(v_id, v_pay);
  perform public.record_eway_result(v_id, 'FAILED', null, null, 'Portal unreachable', null);

  select status into v_status from public.sales where id = v_sale;
  perform app_test.assert_equals(
    v_status in ('POSTED', 'DELIVERED'), true,
    'the sale is still posted after the portal refused'
  );

  select count(*) into v_after from public.journal_entry_lines l
    join public.journal_entries e on e.id = l.journal_entry_id
   where e.dealer_id = v_dealer;
  perform app_test.assert_equals(
    v_after, v_before, 'and no ledger line moved'
  );

  perform app_test.assert_equals(
    (select attempt_count from public.eway_bills where id = v_id), 1,
    'the attempt was counted once, as the request left'
  );

  -- ── Then it succeeds, and is not filed twice ────────────────────────────
  perform public.record_eway_result(v_id, 'GENERATED', '181234567890',
            public.eway_expected_validity(150), null, '{"ok":true}'::jsonb);

  perform app_test.assert_equals(
    (select status from public.eway_bills where id = v_id), 'GENERATED',
    'a later attempt can succeed'
  );
  perform app_test.assert_raises(
    format('select public.record_eway_request(%L, ''{}''::jsonb)', v_id),
    'and a generated bill refuses to be filed again'
  );

  -- ── A bill must say why it failed, and carry a number when it did not ───
  perform app_test.assert_raises(
    format('select public.record_eway_result(%L, ''FAILED'', null, null, null, null)', v_id),
    'a failed bill must record a reason'
  );
  perform app_test.assert_raises(
    format('select public.record_eway_result(%L, ''GENERATED'', null, null, null, null)', v_id),
    'a generated bill must carry its number'
  );
end $$;

-- ── Only a sale can be filed automatically ────────────────────────────────
do $$
declare v_inv uuid; v_id uuid;
begin
  select id into v_inv from public.service_invoices where status = 'POSTED' limit 1;
  if v_inv is null then
    raise notice '  -- no posted service invoice; skipping';
    return;
  end if;

  v_id := public.queue_eway_bill('SERVICE_INVOICE', v_inv, 'ROAD', 'TN01AA1111', 10);

  -- Refused rather than sent: a service invoice moves under a delivery challan,
  -- and a sale-shaped body would be rejected by the portal for reasons nobody
  -- reading the error could act on.
  perform app_test.assert_raises(
    format('select public.eway_bill_payload(%L)', v_id),
    'a service invoice is refused rather than sent in a sale-shaped body'
  );
  perform app_test.assert_equals(
    (select status from public.eway_bills where id = v_id), 'PENDING',
    'but it is still tracked, so nobody forgets it needs raising on the portal'
  );
end $$;
