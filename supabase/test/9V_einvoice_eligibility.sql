-- =============================================================================
-- TEST — what may be filed on the IRP, and what the portal would have refused
-- =============================================================================
-- Spec §16, §40, §55.
--
-- 99_einvoice_payload.sql asserts the payload's shape against a B2B sale, which
-- is the one case that was already right. The cases below are the ones nothing
-- looked at: a buyer with no GSTIN, an inter-state supply, a line with no HSN,
-- and an address with no pincode. All four would have reached the portal and
-- come back as errors.
--
-- The guarantees asserted here:
--   * a B2C invoice is refused before a request is built, because e-invoicing
--     does not apply to it — and for a two-wheeler dealer this is most of the
--     day's sales, not a corner;
--   * SupTyp is one of the portal's own values, never 'B2C';
--   * IgstOnIntra means what the portal means by it — 'Y' only for IGST on an
--     intra-state supply, 'N' for the ordinary inter-state one;
--   * a missing HSN or pincode stops the document here, with a sentence naming
--     the record, rather than at the portal with an error code;
--   * the queue carries the reason, so the screen can disable File and say why.
-- =============================================================================

\echo '--- e-invoice eligibility ---'

do $$
declare
  v_dealer   uuid;
  v_branch   uuid;
  v_b2b      uuid;   -- sale to a registered buyer
  v_b2c      uuid;   -- sale to a walk-in
  v_cust_b2b uuid;
  v_cust_b2c uuid;
  v_eid      uuid;
  v_payload  jsonb;
  v_reason   text;
  v_line     uuid;
  v_hsn      uuid;
  v_model    uuid;
  v_variant  uuid;
  v_veh_b2b  uuid;
  v_veh_b2c  uuid;
  v_hsn_code text;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id, code into v_hsn, v_hsn_code
    from public.hsn_codes where dealer_id = v_dealer limit 1;

  -- Two customers, alike except for the one field that decides this.
  insert into public.customers
    (dealer_id, name, customer_type, mobile, city, state, state_code, gstin, address_line1, pincode)
  values (v_dealer, 'Registered Buyer Traders', 'BUSINESS', '9840090001', 'Chennai',
          'Tamil Nadu', '33', '33AABCR1234M1Z5', '12 Anna Salai', '600002')
  returning id into v_cust_b2b;

  insert into public.customers
    (dealer_id, name, mobile, city, state, state_code, address_line1, pincode)
  values (v_dealer, 'Walk In Buyer', '9840090002', 'Chennai', 'Tamil Nadu', '33',
          '4 Gandhi Road', '600002')
  returning id into v_cust_b2c;

  -- Stock and a price, because sales.vehicle_id is not null and post_vehicle_sale
  -- resolves a price version. The sale has to be posted for real: a trigger
  -- refuses a POSTED sale that carries no journal.
  insert into public.vehicle_models (dealer_id, brand, name, model_code, category, hsn_code_id)
  values (v_dealer, 'TVS', 'Jupiter Elig', 'JUPELIG', 'SCOOTER', v_hsn) returning id into v_model;

  insert into public.vehicle_variants (dealer_id, model_id, name, variant_code, engine_cc)
  values (v_dealer, v_model, 'Standard', 'JUPELIG-STD', 109.7) returning id into v_variant;

  insert into public.vehicle_price_versions
    (dealer_id, model_id, variant_id, version_number, ex_showroom, insurance, registration,
     forwarding_charge, purchase_cost, effective_from, status, approved_at)
  values (v_dealer, v_model, v_variant, 1, 100000, 5000, 8000, 1500, 90000,
          date '2026-04-01', 'ACTIVE', now());

  insert into public.vehicles
    (dealer_id, branch_id, model_id, variant_id, chassis_no, engine_no, purchase_cost, purchase_invoice)
  values (v_dealer, v_branch, v_model, v_variant, 'MD6ELIG00000000B2B', 'ELIGB2B00001', 90000, 'PINV-ELIG-1')
  returning id into v_veh_b2b;

  insert into public.vehicles
    (dealer_id, branch_id, model_id, variant_id, chassis_no, engine_no, purchase_cost, purchase_invoice)
  values (v_dealer, v_branch, v_model, v_variant, 'MD6ELIG00000000B2C', 'ELIGB2C00001', 90000, 'PINV-ELIG-2')
  returning id into v_veh_b2c;

  -- Both sales through the real path, so every guard on the way is satisfied.
  select sale_id into v_b2b from public.create_vehicle_sale_draft(v_cust_b2b, v_veh_b2b);
  select sale_id into v_b2c from public.create_vehicle_sale_draft(v_cust_b2c, v_veh_b2c);

  foreach v_eid in array array[v_b2b, v_b2c] loop
    update public.sales set status = 'SUBMITTED'             where id = v_eid;
    update public.sales set status = 'ACCOUNTS_VERIFICATION' where id = v_eid;
    update public.sales set status = 'APPROVED', approved_at = now() where id = v_eid;
    perform public.post_vehicle_sale(v_eid);
  end loop;

  -- The vehicle line, which is the one that carries GST and so the one the HSN
  -- assertions below are about.
  select id into v_line from public.sale_lines
   where sale_id = v_b2b and line_type = 'VEHICLE' limit 1;

  -- ═══ The case that is most of the dealer's day ═══════════════════════════
  v_reason := public.einvoice_blockers('SALE', v_b2c);
  perform app_test.assert_equals(v_reason is not null, true,
    'a sale to a buyer with no GSTIN is not filable');
  perform app_test.assert_equals(v_reason like '%B2C%', true,
    'and the reason says so in words the person pressing File can act on');

  perform app_test.assert_raises(
    format('select public.queue_einvoice(''SALE'', %L)', v_b2c),
    'queueing a B2C sale is refused, so it never becomes a PENDING row');

  -- ═══ A registered buyer goes through ═════════════════════════════════════
  perform app_test.assert_equals(public.einvoice_blockers('SALE', v_b2b), null,
    'a sale to a registered buyer has nothing blocking it');

  v_eid := public.queue_einvoice('SALE', v_b2b);
  v_payload := public.einvoice_payload(v_eid);

  perform app_test.assert_equals(v_payload -> 'TranDtls' ->> 'SupTyp', 'B2B',
    'SupTyp is one of the portal''s values — B2C is not among them');
  perform app_test.assert_equals(v_payload -> 'BuyerDtls' ->> 'Gstin', '33AABCR1234M1Z5',
    'the buyer GSTIN is sent, not URP');
  perform app_test.assert_equals(
    (v_payload -> 'SellerDtls' ->> 'Pin') ~ '^[1-9][0-9]{5}$', true,
    'the seller pincode is a real six-digit number, not zero');
  perform app_test.assert_equals(v_payload -> 'ItemList' -> 0 ->> 'HsnCd', v_hsn_code,
    'the HSN is the model''s own, never a filler');

  -- ═══ IgstOnIntra means what the portal means ═════════════════════════════
  perform app_test.assert_equals(v_payload -> 'TranDtls' ->> 'IgstOnIntra', 'N',
    'an ordinary intra-state supply with CGST/SGST is not flagged');

  -- Move the buyer to another state. A posted sale's invoice values are
  -- immutable, so the tax cannot be rewritten underneath it — only the
  -- customer's address, which is what decides the place of supply.
  update public.customers set state_code = '29', pincode = '560001' where id = v_cust_b2b;

  v_payload := public.einvoice_payload(v_eid);
  perform app_test.assert_equals(v_payload -> 'TranDtls' ->> 'IgstOnIntra', 'N',
    'an inter-state supply is not flagged either — Pos and Stcd already say that');
  perform app_test.assert_equals(v_payload -> 'BuyerDtls' ->> 'Pos', '29',
    'the place of supply is the buyer''s state');

  update public.customers set state_code = '33', pincode = '600002' where id = v_cust_b2b;

  -- The 'Y' branch — IGST charged while both parties are in one state — is not
  -- reachable from here, and the reason is worth recording: 
  -- create_vehicle_sale_draft writes cgst_rate and sgst_rate and never
  -- igst_rate, so a vehicle sale is taxed as intra-state whoever the buyer is
  -- and wherever they are. Until that is fixed there is no posted sale in this
  -- system carrying IGST for the flag to describe. See the note in 0074.

  -- ═══ Master-data gaps stop here, not at the portal ═══════════════════════
  -- A third sale, left as a DRAFT so its lines can still be edited: a posted
  -- one is immutable, and einvoice_blockers() reads the document whatever its
  -- status.
  declare
    v_veh3  uuid;
    v_sale3 uuid;
  begin
    insert into public.vehicles
      (dealer_id, branch_id, model_id, variant_id, chassis_no, engine_no, purchase_cost, purchase_invoice)
    values (v_dealer, v_branch, v_model, v_variant, 'MD6ELIG00000000HSN', 'ELIGHSN00001', 90000, 'PINV-ELIG-3')
    returning id into v_veh3;

    select sale_id into v_sale3 from public.create_vehicle_sale_draft(v_cust_b2b, v_veh3);

    perform app_test.assert_equals(public.einvoice_blockers('SALE', v_sale3), null,
      'the draft has nothing blocking it to begin with');

    -- Rates set here rather than relied upon: whether the seeded HSN carries an
    -- active tax code is not what this assertion is about, and a line at 0% would
    -- pass the filter for the wrong reason.
    update public.sale_lines
       set hsn_code = null, cgst_rate = 9, sgst_rate = 9,
           cgst_amount = 9000, sgst_amount = 9000
     where sale_id = v_sale3 and line_type = 'VEHICLE';

    v_reason := public.einvoice_blockers('SALE', v_sale3);
    perform app_test.assert_equals(v_reason like '%HSN%', true,
      'a taxed line with no HSN blocks the filing rather than going out as 9999');

    -- An untaxed pass-through charge is a different matter: insurance and
    -- registration are written without an HSN by create_vehicle_sale_draft, and
    -- blocking on those would block every vehicle invoice this system makes.
    update public.sale_lines set hsn_code = v_hsn_code
     where sale_id = v_sale3 and line_type = 'VEHICLE';
    perform app_test.assert_equals(public.einvoice_blockers('SALE', v_sale3), null,
      'while the untaxed insurance and registration lines, which never had one, do not');
  end;

  update public.customers set pincode = null where id = v_cust_b2b;
  v_reason := public.einvoice_blockers('SALE', v_b2b);
  perform app_test.assert_equals(v_reason like '%pincode%', true,
    'a customer with no pincode is named, rather than filed as pin zero');
  perform app_test.assert_equals(v_reason like '%Registered Buyer Traders%', true,
    'and named by name, so the record to fix is obvious');
  update public.customers set pincode = '600002' where id = v_cust_b2b;

  -- ═══ The queue carries the reason ════════════════════════════════════════
  select blocked_reason into v_reason
    from public.einvoice_queue(current_date - 1, current_date + 1, v_branch)
   where document_id = v_b2c;
  perform app_test.assert_equals(v_reason is not null, true,
    'the queue tells the screen why File must be disabled for the B2C row');

  select blocked_reason into v_reason
    from public.einvoice_queue(current_date - 1, current_date + 1, v_branch)
   where document_id = v_b2b;
  perform app_test.assert_equals(v_reason, null,
    'and leaves the filable one alone');
end;
$$;
