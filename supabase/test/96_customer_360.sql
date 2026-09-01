-- =============================================================================
-- TEST — the customer's vehicles and their service rollup
-- =============================================================================
-- Spec §11, §32, §33.
--
-- The guarantees asserted here:
--   * delivering a vehicle records who now owns it, so the register is a
--     consequence of selling rather than a second thing to remember;
--   * a vehicle has exactly one current owner, enforced by an index rather than
--     by the writer remembering to check;
--   * a walk-in job card registers the vehicle by registration number, and a
--     second visit finds the first rather than creating another;
--   * the rollup counts visits and lifetime value from billed work only.
-- =============================================================================

\echo '--- customer 360 ---'

do $$
declare
  v_dealer   uuid;
  v_branch   uuid;
  v_alice    uuid;
  v_bob      uuid;
  v_hsn      uuid;
  v_model    uuid;
  v_variant  uuid;
  v_vehicle  uuid;
  v_sale     uuid;
  v_invoice  text;
  v_cv       uuid;
  v_cv2      uuid;
  v_job      uuid;
  v_job2     uuid;
  v_count    int;
  v_visits   int;
  v_value    numeric;
  v_owner    uuid;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_hsn from public.hsn_codes where dealer_id = v_dealer limit 1;

  insert into public.customers (dealer_id, name, mobile, city, state, state_code)
  values (v_dealer, 'Vehicle Owner Alice', '9840095001', 'Chennai', 'Tamil Nadu', '33')
  returning id into v_alice;

  insert into public.customers (dealer_id, name, mobile, city, state, state_code)
  values (v_dealer, 'Vehicle Owner Bob', '9840095002', 'Chennai', 'Tamil Nadu', '33')
  returning id into v_bob;

  insert into public.vehicle_models (dealer_id, brand, name, model_code, category, hsn_code_id)
  values (v_dealer, 'TVS', 'Sport 110', 'SPORT110', 'MOTORCYCLE', v_hsn) returning id into v_model;

  insert into public.vehicle_variants (dealer_id, model_id, name, variant_code, engine_cc)
  values (v_dealer, v_model, 'ES', 'SPORT110-ES', 109.7) returning id into v_variant;

  insert into public.vehicle_price_versions
    (dealer_id, model_id, variant_id, version_number, ex_showroom, insurance, registration,
     forwarding_charge, purchase_cost, effective_from, status, approved_at)
  values (v_dealer, v_model, v_variant, 1, 70000, 5000, 6000, 1000, 58000,
          date '2026-04-01', 'ACTIVE', now());

  insert into public.vehicles
    (dealer_id, branch_id, model_id, variant_id, chassis_no, engine_no, purchase_cost, purchase_invoice)
  values (v_dealer, v_branch, v_model, v_variant, 'MD680SP11N3D00001', 'SP1DN3000001', 58000, 'PINV-7701')
  returning id into v_vehicle;

  -- ═══ Delivery registers ownership ════════════════════════════════════════
  v_invoice := public.next_document_number(v_dealer, v_branch, 'VEHICLE_INVOICE',
                                           app.financial_year_token(v_dealer, current_date));

  insert into public.sales
    (dealer_id, branch_id, invoice_number, customer_id, vehicle_id, price_version_id)
  select v_dealer, v_branch, v_invoice, v_alice, v_vehicle,
         (select price_version_id from public.resolve_vehicle_price(
            v_dealer, v_model, v_variant, v_branch, current_date))
  returning id into v_sale;

  insert into public.sale_lines
    (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
     taxable_value, cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount,
     unit_cost, cost_amount)
  values
    (v_sale, v_dealer, 1, 'VEHICLE', 'TVS Sport 110 ES', 1, 70000, 70000,
     14, 14, 9800, 9800, 89600, 58000, 58000);

  update public.sales set status = 'SUBMITTED'             where id = v_sale;
  update public.sales set status = 'ACCOUNTS_VERIFICATION' where id = v_sale;
  update public.sales set status = 'APPROVED', approved_at = now() where id = v_sale;
  perform public.post_vehicle_sale(v_sale);
  perform public.deliver_vehicle(v_sale, 'Alice', 3.0, 'Handed over');

  select count(*)::int into v_count
    from public.customer_vehicles where vehicle_id = v_vehicle;
  perform app_test.assert_equals(v_count, 1,
    'delivering the vehicle registers it against the customer');

  select id, customer_id into v_cv, v_owner
    from public.customer_vehicles where vehicle_id = v_vehicle;
  perform app_test.assert_equals(v_owner, v_alice, 'and names the customer who took it');

  perform app_test.assert_equals(
    (select chassis_no from public.customer_vehicles where id = v_cv), 'MD680SP11N3D00001',
    'carrying the chassis, so the unit can be found by it later');

  -- ═══ One current owner ═══════════════════════════════════════════════════
  -- A vehicle cannot be registered to two customers at once. Note the normal
  -- flow cannot reach the upsert's conflict path — a delivered vehicle is
  -- terminal and cannot be returned or resold — so the index is what actually
  -- holds the invariant, and this is the assertion that proves it.
  perform app_test.assert_raises(
    format($f$insert into public.customer_vehicles (dealer_id, customer_id, vehicle_id, chassis_no)
             values (%L, %L, %L, 'MD680SP11N3D00001')$f$, v_dealer, v_bob, v_vehicle),
    'a vehicle cannot be registered to a second owner');

  select customer_id into v_owner from public.customer_vehicles where vehicle_id = v_vehicle;
  perform app_test.assert_equals(v_owner, v_alice, 'the recorded owner is unchanged');

  -- ═══ A walk-in registers by registration number ══════════════════════════
  select job_card_id into v_job
    from public.create_job_card(v_branch, v_alice, 'PAID', 'tn01ab9999', 12000,
                                'Engine noise');

  select customer_vehicle_id into v_cv2 from public.job_cards where id = v_job;
  perform app_test.assert_equals(v_cv2 is not null, true,
    'a walk-in job card registers the vehicle it is for');

  perform app_test.assert_equals(
    (select registration_no from public.customer_vehicles where id = v_cv2), 'TN01AB9999',
    'normalising the registration, so the next visit matches whatever case it is typed in');

  -- The second visit finds the first vehicle rather than creating another.
  select job_card_id into v_job2
    from public.create_job_card(v_branch, v_alice, 'PAID', 'TN01AB9999', 14500,
                                'Second service');

  select count(*)::int into v_count
    from public.customer_vehicles
   where dealer_id = v_dealer and registration_no = 'TN01AB9999';
  perform app_test.assert_equals(v_count, 1,
    'a returning vehicle is recognised rather than registered twice');

  perform app_test.assert_equals(
    (select customer_vehicle_id from public.job_cards where id = v_job2), v_cv2,
    'and both job cards point at the same vehicle');

  -- ═══ The rollup ══════════════════════════════════════════════════════════
  select visit_count, lifetime_value into v_visits, v_value
    from public.customer_service_summary(v_alice);

  perform app_test.assert_equals(v_visits, 2, 'the rollup counts both visits');
  perform app_test.assert_equals(v_value, 0::numeric,
    'and counts nothing as lifetime value until the work is billed');

  perform app_test.assert_equals(
    (select open_jobs from public.customer_service_summary(v_alice)), 2,
    'both jobs are still open');

  perform app_test.assert_equals(
    (select days_since_last from public.customer_service_summary(v_alice)), 0,
    'the last visit was today');

  -- A customer who has never been in does not appear at all.
  select count(*)::int into v_count from public.customer_service_summary(v_bob);
  perform app_test.assert_equals(v_count, 0,
    'a customer with no service history is not in the rollup');
end;
$$;
