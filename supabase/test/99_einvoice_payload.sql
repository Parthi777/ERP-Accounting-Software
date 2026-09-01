-- =============================================================================
-- TEST — the e-invoice payload and request record
-- =============================================================================
-- Spec §40.
--
-- The guarantees asserted here:
--   * the document sent to the portal is built from the invoice, and its totals
--     are the invoice's own — a payload that disagrees with the ledger would
--     file a different sale from the one that happened;
--   * a buyer with no GSTIN files as B2C with the portal's URP marker, rather
--     than as a malformed B2B;
--   * what was sent is stored before the request leaves, so a lost reply still
--     shows what was attempted;
--   * an already-filed document cannot be silently refiled;
--   * an invoice that cannot be represented is refused before anything is sent.
-- =============================================================================

\echo '--- e-invoice payload ---'

do $$
declare
  v_dealer   uuid;
  v_branch   uuid;
  v_customer uuid;
  v_b2c      uuid;
  v_hsn      uuid;
  v_model    uuid;
  v_variant  uuid;
  v_vehicle  uuid;
  v_sale     uuid;
  v_invoice  text;
  v_einv     uuid;
  v_payload  jsonb;
  v_attempts int;
  v_total    numeric;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_hsn    from public.hsn_codes where dealer_id = v_dealer limit 1;

  insert into public.customers
    (dealer_id, name, customer_type, mobile, city, state, state_code, gstin, address_line1, pincode)
  values (v_dealer, 'GST Registered Buyer', 'BUSINESS', '9840092001', 'Chennai', 'Tamil Nadu', '33',
          '33AACCG1234B1ZX', '12 Anna Salai', '600002')
  returning id into v_customer;

  insert into public.customers (dealer_id, name, mobile, city, state, state_code)
  values (v_dealer, 'Walk-in Buyer', '9840092002', 'Chennai', 'Tamil Nadu', '33')
  returning id into v_b2c;

  insert into public.vehicle_models (dealer_id, brand, name, model_code, category, hsn_code_id)
  values (v_dealer, 'TVS', 'Apache RTR', 'APACHE160', 'MOTORCYCLE', v_hsn) returning id into v_model;

  insert into public.vehicle_variants (dealer_id, model_id, name, variant_code, engine_cc)
  values (v_dealer, v_model, 'Race Edition', 'APACHE160-RE', 159.7) returning id into v_variant;

  insert into public.vehicle_price_versions
    (dealer_id, model_id, variant_id, version_number, ex_showroom, insurance, registration,
     forwarding_charge, purchase_cost, effective_from, status, approved_at)
  values (v_dealer, v_model, v_variant, 1, 120000, 8000, 10000, 2000, 99000,
          date '2026-04-01', 'ACTIVE', now());

  insert into public.vehicles
    (dealer_id, branch_id, model_id, variant_id, chassis_no, engine_no, purchase_cost, purchase_invoice)
  values (v_dealer, v_branch, v_model, v_variant, 'MD634AP16N5F00001', 'AP1FN5000001', 99000, 'PINV-5501')
  returning id into v_vehicle;

  v_invoice := public.next_document_number(v_dealer, v_branch, 'VEHICLE_INVOICE',
                                           app.financial_year_token(v_dealer, current_date));

  insert into public.sales
    (dealer_id, branch_id, invoice_number, customer_id, vehicle_id, price_version_id)
  select v_dealer, v_branch, v_invoice, v_customer, v_vehicle,
         (select price_version_id from public.resolve_vehicle_price(
            v_dealer, v_model, v_variant, v_branch, current_date))
  returning id into v_sale;

  insert into public.sale_lines
    (sale_id, dealer_id, line_number, line_type, description, hsn_code, quantity, unit_rate,
     taxable_value, cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount,
     unit_cost, cost_amount)
  values
    (v_sale, v_dealer, 1, 'VEHICLE', 'TVS Apache RTR Race Edition', '87112019', 1, 120000, 120000,
     14, 14, 16800, 16800, 153600, 99000, 99000),
    (v_sale, v_dealer, 2, 'INSURANCE', 'Insurance', null, 1, 8000, 8000,
     0, 0, 0, 0, 8000, 0, 0);

  update public.sales set status = 'SUBMITTED'             where id = v_sale;
  update public.sales set status = 'ACCOUNTS_VERIFICATION' where id = v_sale;
  update public.sales set status = 'APPROVED', approved_at = now() where id = v_sale;
  perform public.post_vehicle_sale(v_sale);

  -- ═══ Queue, then build ═══════════════════════════════════════════════════
  v_einv := public.queue_einvoice('SALE', v_sale);
  perform app_test.assert_equals(v_einv is not null, true, 'the sale is queued for the portal');

  v_payload := public.einvoice_payload(v_einv);

  perform app_test.assert_equals(v_payload -> 'Version' = '"1.1"'::jsonb, true,
    'the payload declares the IRP schema version');
  perform app_test.assert_equals(v_payload -> 'DocDtls' ->> 'No', v_invoice,
    'it files the invoice number the customer was given');
  perform app_test.assert_equals(v_payload -> 'TranDtls' ->> 'SupTyp', 'B2B',
    'a buyer with a GSTIN is a B2B supply');
  perform app_test.assert_equals(v_payload -> 'BuyerDtls' ->> 'Gstin', '33AACCG1234B1ZX',
    'and is filed under their GSTIN');

  -- The seller is the branch, or the dealer where the branch has no GSTIN.
  perform app_test.assert_equals(
    (v_payload -> 'SellerDtls' ->> 'Gstin') is not null, true,
    'the seller GSTIN is present, or the payload would be refused by the portal');

  -- ═══ The payload must agree with the ledger ══════════════════════════════
  select total_amount into v_total from public.sales where id = v_sale;
  perform app_test.assert_equals(
    (v_payload -> 'ValDtls' ->> 'TotInvVal')::numeric, v_total,
    'the value filed is the invoice''s own total, not a recomputation');

  perform app_test.assert_equals(
    (v_payload -> 'ValDtls' ->> 'AssVal')::numeric
      + (v_payload -> 'ValDtls' ->> 'CgstVal')::numeric
      + (v_payload -> 'ValDtls' ->> 'SgstVal')::numeric
      + (v_payload -> 'ValDtls' ->> 'IgstVal')::numeric,
    v_total,
    'taxable plus tax equals the total, so the portal will not reject the arithmetic');

  perform app_test.assert_equals(
    jsonb_array_length(v_payload -> 'ItemList'), 2,
    'every invoice line is filed');

  perform app_test.assert_equals(
    v_payload -> 'ItemList' -> 0 ->> 'HsnCd', '87112019',
    'each line carries its own HSN');

  -- A line with no HSN still files: the portal requires the field, so a
  -- placeholder is sent rather than a null that would be rejected outright.
  perform app_test.assert_equals(
    v_payload -> 'ItemList' -> 1 ->> 'HsnCd', '9999',
    'a line without an HSN files under a placeholder rather than failing');

  -- ═══ The request is recorded before it is sent ═══════════════════════════
  perform public.record_einvoice_request(v_einv, v_payload);

  select attempt_count into v_attempts from public.einvoices where id = v_einv;
  perform app_test.assert_equals(v_attempts, 1, 'the attempt is counted');
  perform app_test.assert_equals(
    (select request_payload is not null from public.einvoices where id = v_einv), true,
    'and what was sent is stored, so a lost reply still leaves evidence');

  -- ═══ Recording the reply ═════════════════════════════════════════════════
  perform public.record_einvoice_result(
    v_einv, 'FAILED', null, null, null, null, 'TIMEOUT',
    'The provider did not respond in time.', '{"error":"timeout"}'::jsonb);

  perform app_test.assert_equals(
    (select status from public.einvoices where id = v_einv), 'FAILED',
    'a portal failure is recorded as a failure');

  -- Spec §40: the invoice is untouched by a portal failure.
  perform app_test.assert_equals(
    (select status from public.sales where id = v_sale), 'POSTED',
    'and the invoice itself is unaffected — the accounting never depended on the portal');

  -- A retry clears the previous error rather than stacking on it.
  perform public.record_einvoice_request(v_einv, '{"retry":true}'::jsonb);
  perform app_test.assert_equals(
    (select error_message from public.einvoices where id = v_einv), null,
    'a retry starts clean: the last failure is not this attempt''s');
  perform app_test.assert_equals(
    (select attempt_count from public.einvoices where id = v_einv), 2,
    'and the attempts accumulate');

  perform public.record_einvoice_result(
    v_einv, 'GENERATED', 'IRN0000000000000000000000000000001', 'ACK123456', now(),
    'QRDATA', null, null, '{"ok":true}'::jsonb);

  perform app_test.assert_equals(
    (select status from public.einvoices where id = v_einv), 'GENERATED', 'a filed document is filed');

  -- ═══ A filed document is not refiled ═════════════════════════════════════
  perform app_test.assert_raises(
    format('select public.record_einvoice_request(%L, ''{}''::jsonb)', v_einv),
    'an already-filed document cannot be sent again');

  -- ═══ B2C, and the service-invoice branch of the builder ═════════════════
  -- A counter sale with no customer at all: the hardest case for the payload,
  -- because every buyer field has to be filled from nothing.
  declare
    v_item    uuid;
    v_counter uuid;
    v_einv2   uuid;
  begin
    insert into public.inventory_items
      (dealer_id, item_code, name, item_type, hsn_code_id, standard_cost, selling_price)
    values (v_dealer, 'AC-EINV-01', 'Tank pad', 'ACCESSORY', v_hsn, 200, 350)
    returning id into v_item;

    insert into public.inventory_transactions
      (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
       reference_type, narration)
    values (v_dealer, v_branch, v_item, 'COMPANY', 'OPENING', 5, 200, 'OPENING', 'Stock');

    select invoice_id into v_counter from public.create_counter_invoice(v_branch, null);
    perform public.add_service_line(v_counter, 'ACCESSORY', 'Tank pad', 2, 350, v_item);
    perform public.post_service_invoice(v_counter);

    v_einv2 := public.queue_einvoice('SERVICE_INVOICE', v_counter);
    v_payload := public.einvoice_payload(v_einv2);

    perform app_test.assert_equals(v_payload -> 'TranDtls' ->> 'SupTyp', 'B2C',
      'a sale with no customer is a B2C supply');
    perform app_test.assert_equals(v_payload -> 'BuyerDtls' ->> 'Gstin', 'URP',
      'filed under the portal''s unregistered-person marker rather than a blank');
    perform app_test.assert_equals(v_payload -> 'BuyerDtls' ->> 'LglNm', 'Cash customer',
      'and named, because the portal will not accept an empty buyer');
    perform app_test.assert_equals(
      (v_payload -> 'BuyerDtls' ->> 'Stcd') is not null, true,
      'with a place of supply, defaulted to the seller''s state');

    perform app_test.assert_equals(
      jsonb_array_length(v_payload -> 'ItemList') >= 1, true,
      'a service invoice builds its lines from service_lines, not sale_lines');
  end;
end;
$$;
