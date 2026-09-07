-- =============================================================================
-- TEST — input tax credit reporting
-- =============================================================================
-- Spec §16, §24, §40, §41.
--
-- The guarantees asserted here:
--   * a posted purchase bill's tax reaches the ITC report, grouped by the HSN
--     of the thing bought — resolved through the item, since a purchase line
--     carries no HSN of its own;
--   * a debit note nets OFF the same HSN rather than appearing separately, so
--     the figure a dealer claims is what they are actually entitled to;
--   * the period filter is honoured, so last month's ITC is not claimed twice;
--   * output tax and input tax are reported by different functions and never
--     mixed — gst_summary() must not move when a purchase is posted.
-- =============================================================================

\echo '--- gst input tax ---'

do $$
declare
  v_dealer   uuid;
  v_main     uuid;
  v_supplier uuid;
  v_hsn      uuid;
  v_item     uuid;
  v_bill     uuid;
  v_line     uuid;
  v_ret      uuid;
  v_cgst     numeric;
  v_out      numeric;
  v_out2     numeric;
  v_count    int;
  v_other    uuid;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_main   from public.branches where dealer_id = v_dealer and code = 'MAIN';

  insert into public.hsn_codes (dealer_id, code, code_type, description)
  values (v_dealer, '87141091', 'HSN', 'ITC test parts')
  on conflict do nothing;
  select id into v_hsn from public.hsn_codes where dealer_id = v_dealer and code = '87141091';

  insert into public.suppliers (dealer_id, name, supplier_type, city, state)
  values (v_dealer, 'ITC Test Supplies', 'GOODS', 'Erode', 'Tamil Nadu')
  returning id into v_supplier;

  insert into public.inventory_items
    (dealer_id, item_code, name, item_type, hsn_code_id, standard_cost, selling_price)
  values (v_dealer, 'ITC-PART-01', 'ITC Test Part', 'SPARE', v_hsn, 1000, 1500)
  returning id into v_item;

  -- ═══ Output tax before we touch anything ═════════════════════════════════
  select coalesce(sum(total_tax), 0) into v_out
    from public.gst_summary(current_date - 400, current_date + 1);

  -- ═══ A bill of 100 units at 1,000 with 9+9 ═══════════════════════════════
  insert into public.purchase_bills
    (dealer_id, branch_id, supplier_id, supplier_bill_number, bill_date)
  values (v_dealer, v_main, v_supplier, 'ITC/2026/01', current_date)
  returning id into v_bill;

  insert into public.purchase_bill_lines
    (purchase_bill_id, dealer_id, line_number, line_type, item_id, source, description,
     quantity, unit_rate, taxable_value, cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount)
  values
    (v_bill, v_dealer, 1, 'SPARE', v_item, 'LOCAL', 'ITC Test Part',
     100, 1000, 100000, 9, 9, 9000, 9000, 118000)
  returning id into v_line;

  perform app_test.assert_equals(
    (select count(*)::int from public.gst_input_summary(current_date, current_date)
      where hsn_code = '87141091'),
    0, 'a draft bill contributes nothing to input tax credit');

  perform public.post_purchase_bill(v_bill);

  select cgst_amount into v_cgst
    from public.gst_input_summary(current_date, current_date) where hsn_code = '87141091';
  perform app_test.assert_equals(v_cgst, 9000.0000::numeric,
    'a posted bill''s input CGST reaches the ITC report');

  perform app_test.assert_equals(
    (select taxable_value from public.gst_input_summary(current_date, current_date)
      where hsn_code = '87141091'),
    100000.0000::numeric, 'with the taxable value it was bought at');

  perform app_test.assert_equals(
    (select total_tax from public.gst_input_summary(current_date, current_date)
      where hsn_code = '87141091'),
    18000.0000::numeric, 'and the whole claim is CGST plus SGST');

  -- The HSN came from the item, because a purchase line carries none itself.
  perform app_test.assert_equals(
    (select description from public.gst_input_summary(current_date, current_date)
      where hsn_code = '87141091'),
    'ITC test parts', 'the HSN is resolved through the item that was bought');

  -- ═══ Output tax has not moved ════════════════════════════════════════════
  select coalesce(sum(total_tax), 0) into v_out2
    from public.gst_summary(current_date - 400, current_date + 1);
  perform app_test.assert_equals(v_out2, v_out,
    'buying stock does not change output tax — the two sides are separate reports');

  -- ═══ A quarter goes back ═════════════════════════════════════════════════
  select r.return_id into v_ret
    from public.post_purchase_return(
      v_bill,
      jsonb_build_array(jsonb_build_object('bill_line_id', v_line, 'quantity', 25)),
      'Damaged in transit') r;

  perform app_test.assert_equals(
    (select cgst_amount from public.gst_input_summary(current_date, current_date)
      where hsn_code = '87141091'),
    6750.0000::numeric,
    'a debit note nets OFF the claim — 25 of 100 returned leaves three quarters');

  perform app_test.assert_equals(
    (select count(*)::int from public.gst_input_summary(current_date, current_date)
      where hsn_code = '87141091'),
    1, 'and does so in the same HSN row, not as a separate line to be missed');

  -- ═══ The period filter ═══════════════════════════════════════════════════
  perform app_test.assert_equals(
    (select count(*)::int from public.gst_input_summary(
       current_date + 1, current_date + 30) where hsn_code = '87141091'),
    0, 'a period that excludes the bill claims nothing from it');

  -- ═══ Another tenant holding the same HSN must not double the claim ═══════
  -- hsn_codes is dealer-scoped, so the same code legitimately exists in two
  -- tenants. A description lookup written as a join on code alone matches once
  -- per tenant and silently doubles every figure — correct under RLS, wrong for
  -- anything reading with it bypassed. This is that regression.
  insert into public.dealers (code, legal_name, city, state, state_code)
  values ('ITCX', 'Same HSN Different Tenant Motors', 'Salem', 'Tamil Nadu', '33')
  returning id into v_other;

  insert into public.hsn_codes (dealer_id, code, code_type, description)
  values (v_other, '87141091', 'HSN', 'Another tenant''s copy of the same code');

  if v_other is not null then
    perform app_test.assert_equals(
      (select count(*)::int from public.gst_input_summary(current_date, current_date)
        where hsn_code = '87141091'),
      1, 'the same HSN code in another tenant does not split the row');

    perform app_test.assert_equals(
      (select cgst_amount from public.gst_input_summary(current_date, current_date)
        where hsn_code = '87141091'),
      6750.0000::numeric,
      'nor double the claim — the description travels with the line, not by code');

    perform app_test.assert_equals(
      (select description from public.gst_input_summary(current_date, current_date)
        where hsn_code = '87141091'),
      'ITC test parts', 'and the description is this tenant''s, not the other one''s');
  end if;

  -- hsn_codes cascades with the dealer, so this takes the copy with it.
  delete from public.dealers where id = v_other;

  -- ═══ Reversing the note restores the claim ═══════════════════════════════
  perform public.cancel_purchase_return(v_ret, 'Supplier would not accept the return');

  perform app_test.assert_equals(
    (select cgst_amount from public.gst_input_summary(current_date, current_date)
      where hsn_code = '87141091'),
    9000.0000::numeric, 'and a reversed note gives the claim back');
end;
$$;
