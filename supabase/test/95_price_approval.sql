-- =============================================================================
-- TEST — the price approval workflow
-- =============================================================================
-- Spec §15, §17, §42, §60.9.
--
-- The guarantees asserted here:
--   * a price reaches ACTIVE only through DRAFT → SUBMITTED → APPROVED, never by
--     being saved;
--   * the step cannot be skipped, and a rejection says why;
--   * nobody approves their own submission, or the review is decorative;
--   * activating supersedes the incumbent, so exactly one price is live per
--     scope and the old one keeps the window it applied to;
--   * a live price's figures are immutable, so an invoice raised under it stays
--     explainable (spec §60.9).
-- =============================================================================

\echo '--- price approval ---'

do $$
declare
  v_dealer  uuid;
  v_hsn     uuid;
  v_model   uuid;
  v_variant uuid;
  v_first   uuid;
  v_second  uuid;
  v_status  text;
  v_count   int;
  v_to      date;
  v_active  numeric;
  v_user_a  uuid := '11111111-1111-4111-8111-111111111111';
  v_user_b  uuid := '22222222-2222-4222-8222-222222222222';
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_hsn from public.hsn_codes where dealer_id = v_dealer limit 1;

  insert into public.vehicle_models (dealer_id, brand, name, model_code, category, hsn_code_id)
  values (v_dealer, 'TVS', 'Ntorq 125', 'NTORQ125', 'SCOOTER', v_hsn) returning id into v_model;

  insert into public.vehicle_variants (dealer_id, model_id, name, variant_code, engine_cc)
  values (v_dealer, v_model, 'Race XP', 'NTORQ125-RXP', 124.8) returning id into v_variant;

  -- ═══ A draft is not a price ══════════════════════════════════════════════
  insert into public.vehicle_price_versions
    (dealer_id, model_id, variant_id, version_number, ex_showroom, insurance, registration,
     forwarding_charge, purchase_cost, effective_from, status)
  values (v_dealer, v_model, v_variant, 1, 88000, 6500, 8000, 1400, 72000,
          date '2026-05-01', 'DRAFT')
  returning id into v_first;

  perform app_test.assert_equals(
    (select price_version_id from public.resolve_vehicle_price(
       v_dealer, v_model, v_variant, null, date '2026-06-01')) is null, true,
    'a draft price is not used for a sale');

  -- ═══ The order cannot be skipped ═════════════════════════════════════════
  perform app_test.assert_raises(
    format('select public.decide_price_version(%L, ''APPROVE'')', v_first),
    'a draft cannot be approved without being submitted');

  perform app_test.assert_raises(
    format('select public.decide_price_version(%L, ''ACTIVATE'')', v_first),
    'a draft cannot go live');

  -- ═══ Submit, then approve — by someone else ══════════════════════════════
  perform app_test.login(v_user_a);
  v_status := public.decide_price_version(v_first, 'SUBMIT');
  perform app_test.assert_equals(v_status, 'SUBMITTED', 'the draft is submitted');

  perform app_test.assert_equals(
    (select submitted_by from public.vehicle_price_versions where id = v_first), v_user_a,
    'and records who submitted it');

  perform app_test.assert_raises(
    format('select public.decide_price_version(%L, ''APPROVE'')', v_first),
    'the person who submitted a price cannot approve it themselves');

  perform app_test.login(v_user_b);
  v_status := public.decide_price_version(v_first, 'APPROVE');
  perform app_test.assert_equals(v_status, 'APPROVED', 'a second pair of eyes approves it');

  perform app_test.assert_equals(
    (select approved_by from public.vehicle_price_versions where id = v_first), v_user_b,
    'and the approver is recorded, not the submitter');

  -- Still not live: approval and activation are separate acts.
  perform app_test.assert_equals(
    (select price_version_id from public.resolve_vehicle_price(
       v_dealer, v_model, v_variant, null, date '2026-06-01')) is null, true,
    'an approved price is still not the price until it is activated');

  v_status := public.decide_price_version(v_first, 'ACTIVATE');
  perform app_test.assert_equals(v_status, 'ACTIVE', 'the approved price goes live');

  perform app_test.assert_equals(
    (select price_version_id from public.resolve_vehicle_price(
       v_dealer, v_model, v_variant, null, date '2026-06-01')), v_first,
    'and is now what a sale on that date is priced from');

  -- ═══ Rejection ═══════════════════════════════════════════════════════════
  insert into public.vehicle_price_versions
    (dealer_id, model_id, variant_id, version_number, ex_showroom, insurance, registration,
     forwarding_charge, purchase_cost, effective_from, status)
  values (v_dealer, v_model, v_variant, 2, 99000, 6500, 8000, 1400, 72000,
          date '2026-08-01', 'DRAFT')
  returning id into v_second;

  perform app_test.login(v_user_a);
  perform public.decide_price_version(v_second, 'SUBMIT');

  perform app_test.login(v_user_b);
  perform app_test.assert_raises(
    format('select public.decide_price_version(%L, ''REJECT'')', v_second),
    'a rejection must say why');

  v_status := public.decide_price_version(v_second, 'REJECT', 'Ex-showroom does not match the circular');
  perform app_test.assert_equals(v_status, 'REJECTED', 'the price is rejected');

  perform app_test.assert_equals(
    (select notes like '%does not match the circular%'
       from public.vehicle_price_versions where id = v_second), true,
    'and the reason is kept on the version');

  -- ═══ Activation supersedes the incumbent ═════════════════════════════════
  update public.vehicle_price_versions set status = 'DRAFT', notes = null where id = v_second;
  perform app_test.login(v_user_a);
  perform public.decide_price_version(v_second, 'SUBMIT');
  perform app_test.login(v_user_b);
  perform public.decide_price_version(v_second, 'APPROVE');
  perform public.decide_price_version(v_second, 'ACTIVATE');

  select count(*)::int into v_count
    from public.vehicle_price_versions
   where model_id = v_model and variant_id = v_variant and status = 'ACTIVE';
  perform app_test.assert_equals(v_count, 1,
    'exactly one price is live for a scope at a time');

  select status, effective_to into v_status, v_to
    from public.vehicle_price_versions where id = v_first;
  perform app_test.assert_equals(v_status, 'SUPERSEDED', 'the incumbent is superseded');
  perform app_test.assert_equals(v_to, date '2026-07-31',
    'and its window closes the day before the new one opens');

  -- History still answers "what was the price on that date" (spec §42).
  perform app_test.assert_equals(
    (select price_version_id from public.resolve_vehicle_price(
       v_dealer, v_model, v_variant, null, date '2026-06-15')), v_first,
    'a sale in June is still priced from the version that was live then');

  perform app_test.assert_equals(
    (select price_version_id from public.resolve_vehicle_price(
       v_dealer, v_model, v_variant, null, date '2026-09-01')), v_second,
    'and a sale in September from the new one');

  -- ═══ A live price cannot be edited (spec §60.9) ══════════════════════════
  select ex_showroom into v_active from public.vehicle_price_versions where id = v_second;
  perform app_test.assert_raises(
    format('update public.vehicle_price_versions set ex_showroom = 1 where id = %L', v_second),
    'an active price''s figures are immutable');

  perform app_test.assert_equals(
    (select ex_showroom from public.vehicle_price_versions where id = v_second), v_active,
    'so the figure an invoice was raised against cannot move under it');

  perform app_test.logout();
end;
$$;
