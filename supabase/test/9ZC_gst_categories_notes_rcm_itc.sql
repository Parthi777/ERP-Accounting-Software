-- =============================================================================
-- TEST — tax categories, credit/debit notes, reverse charge, ITC (0084)
-- =============================================================================
-- Checklist §04 tax categories, §05 credit/debit notes and bill of supply, §08
-- reverse charge and ITC categories / reversal. Runs in the ACPT tenant that
-- 9Y provisioned, against its posted counter invoice and purchase bills.
-- =============================================================================

\echo '--- tax categories, notes, reverse charge and ITC ---'

select app_test.login('cccccccc-1111-4111-8111-cccccccccccc');
set role authenticated;

do $$
declare
  v_dealer   uuid := app.current_dealer_id();
  v_branch   uuid;
  v_customer uuid;
  v_supplier uuid;
  v_gta      uuid;
  v_invoice  uuid;
  v_stock    uuid;
  v_bill     uuid;
  v_entry    uuid;
  v_note     uuid;
  v_note2    uuid;
  v_before   numeric;
  v_lines    text;
  r          record;
  acc        text;
begin
  select id into v_branch from public.branches where dealer_id = v_dealer;
  select id into v_customer from public.customers where dealer_id = v_dealer and name = 'Acceptance Customer';
  select id into v_supplier from public.suppliers where dealer_id = v_dealer and name = 'Alpha Traders';
  select id into v_invoice from public.service_invoices
   where dealer_id = v_dealer and customer_id = v_customer and status = 'POSTED' and taxable_value = 450000;
  select id into v_stock from public.purchase_bills where supplier_bill_number = 'AT/STOCK/001';

  -- ── Tax categories ────────────────────────────────────────────────────────
  perform app_test.assert_equals(
    (select string_agg(code || ':' || tax_category, ', ' order by code) from public.tax_codes
      where tax_category <> 'TAXABLE'),
    'EXEMPT:EXEMPT, NIL_RATED:NIL_RATED, NON_GST:NON_GST',
    'a provisioned dealer has nil-rated, exempt and non-GST codes');
  perform app_test.assert_raises(
    format($q$insert into public.tax_codes (dealer_id, code, name, cgst_rate, sgst_rate, igst_rate, effective_from, tax_category)
              values (%L, 'EXEMPT_BAD', 'Exempt with a rate', 9, 9, 18, current_date, 'EXEMPT')$q$, v_dealer),
    'an exempt code cannot carry a rate');

  -- An exempt charge on an invoice is reported as an exempt supply.
  select invoice_id into r from public.create_counter_invoice(v_branch, v_customer);
  perform public.add_service_line(r.invoice_id, 'OTHER_CHARGE', 'Insurance facilitation', 1, 500, null, 'EXEMPT');
  perform public.post_service_invoice(r.invoice_id);
  perform app_test.assert_equals(
    (select taxable_value || '/' || total_tax from public.gst_supply_categories(current_date, current_date)
      where direction = 'OUTWARD' and tax_category = 'EXEMPT'),
    '500.0000/0.0000', 'GSTR-3B 3.1(c): the exempt supply is reported apart from taxable ones');
  perform app_test.assert_equals(
    (select sum(taxable_value) from public.gst_supply_categories(current_date, current_date)
      where direction = 'OUTWARD'),
    (select sum(taxable_value) from public.gstr1_summary(current_date, current_date)
      where section in ('B2B', 'B2C')),
    'and the categories add up to every invoice in GSTR-1');

  -- ── Reverse charge ────────────────────────────────────────────────────────
  insert into public.suppliers (dealer_id, name, supplier_type, mobile, city, state)
  values (v_dealer, 'Road Freight GTA', 'SERVICE', '9840044444', 'Chennai', 'Tamil Nadu')
  returning id into v_gta;
  insert into public.purchase_bills (dealer_id, branch_id, supplier_id, supplier_bill_number, bill_date)
  values (v_dealer, v_branch, v_gta, 'GTA/77', current_date) returning id into v_bill;
  insert into public.purchase_bill_lines
    (purchase_bill_id, dealer_id, line_number, line_type, account_id, hsn_sac, reverse_charge,
     description, quantity, unit_rate, taxable_value, cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount)
  values (v_bill, v_dealer, 1, 'EXPENSE',
          (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '5900'),
          '996511', true, 'Freight inward', 1, 10000, 10000, 2.5, 2.5, 250, 250, 10000);
  perform app_test.assert_raises(
    format($q$insert into public.purchase_bill_lines
      (purchase_bill_id, dealer_id, line_number, line_type, account_id, reverse_charge,
       description, quantity, unit_rate, taxable_value, cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount)
      select %L, %L, 2, 'EXPENSE', id, true, 'x', 1, 100, 100, 2.5, 2.5, 2.5, 2.5, 105
        from public.chart_of_accounts where dealer_id = %L and code = '5900'$q$, v_bill, v_dealer, v_dealer),
    'a reverse-charge line that owes the supplier the tax is refused');
  perform app_test.assert_equals(
    (select total_amount || '/' || cgst_amount || '/' || reverse_charge_tax from public.purchase_bills where id = v_bill),
    '10000.0000/0.0000/500.0000',
    'a reverse-charge bill owes the supplier the value only; the 500 of tax is the dealer''s');
  v_entry := public.post_purchase_bill(v_bill);
  perform app_test.assert_equals(
    (select string_agg(c.code || case when l.debit > 0 then ' Dr ' || l.debit::numeric(18, 0) else ' Cr ' || l.credit::numeric(18, 0) end, ', ' order by c.code)
       from public.journal_entry_lines l join public.chart_of_accounts c on c.id = l.account_id
      where l.journal_entry_id = v_entry),
    '1900 Dr 250, 1910 Dr 250, 2200 Cr 10000, 2590 Cr 500, 5900 Dr 10000',
    'RCM: expense and input tax Dr; supplier Cr for the value, GST Payable (RCM) Cr for the tax');

  -- ── ITC categories ────────────────────────────────────────────────────────
  insert into public.purchase_bills (dealer_id, branch_id, supplier_id, supplier_bill_number, bill_date)
  values (v_dealer, v_branch, v_supplier, 'AT/PERSONAL/1', current_date) returning id into v_bill;
  insert into public.purchase_bill_lines
    (purchase_bill_id, dealer_id, line_number, line_type, account_id, itc_category,
     description, quantity, unit_rate, taxable_value, cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount)
  values (v_bill, v_dealer, 1, 'EXPENSE',
          (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '3400'),
          'PERSONAL', 'Owner''s phone', 1, 20000, 20000, 9, 9, 1800, 1800, 23600);
  perform app_test.assert_equals(
    (select itc_eligible from public.purchase_bill_lines where purchase_bill_id = v_bill), false,
    'a PERSONAL purchase is never claimed');
  perform app_test.assert_raises(
    format($q$insert into public.purchase_bill_lines
      (purchase_bill_id, dealer_id, line_number, line_type, item_id, source, itc_category,
       description, quantity, unit_rate, taxable_value, total_amount)
      select %L, %L, 9, 'ACCESSORY', id, 'LOCAL', 'BLOCKED', 'x', 1, 1, 1, 1
        from public.inventory_items where item_code = 'ACC-KIT-01'$q$, v_bill, v_dealer),
    'stock is bought for business; its credit cannot be categorised away');

  -- ── A credit note to the customer ─────────────────────────────────────────
  select coalesce(sum(taxable_value), 0) into v_before
    from public.gst_summary(current_date, current_date) where hsn_code = '87141090';
  v_note := public.issue_gst_note(
    'CREDIT', 'SERVICE_INVOICE', v_invoice, 10000, 18,
    (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '4200'),
    'DISCOUNT', 'Post-sale volume discount', current_date, null, true, null, 'acpt-cn-1');
  perform app_test.assert_equals(
    public.issue_gst_note('CREDIT', 'SERVICE_INVOICE', v_invoice, 10000, 18,
      (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '4200'),
      'DISCOUNT', 'Post-sale volume discount', current_date, null, true, null, 'acpt-cn-1'),
    v_note, 'a repeated submission returns the same note');
  perform app_test.assert_equals(
    (select note_number ~ '^CN-[0-9]{4}-[0-9]{6}$' from public.gst_notes where id = v_note), true,
    'credit notes are numbered CN-YYYY-NNNNNN');
  perform app_test.assert_equals(
    (select string_agg(c.code || case when l.debit > 0 then ' Dr ' || l.debit::numeric(18, 0) else ' Cr ' || l.credit::numeric(18, 0) end, ', ' order by c.code)
       from public.journal_entry_lines l join public.chart_of_accounts c on c.id = l.account_id
      where l.journal_entry_id = (select journal_entry_id from public.gst_notes where id = v_note)),
    '1300 Cr 11800, 2300 Dr 900, 2400 Dr 900, 4200 Dr 10000',
    'a credit note takes back sales and output tax and reduces what the customer owes');
  perform app_test.assert_equals(
    (select taxable_value from public.gstr1_summary(current_date, current_date) where section = 'CDNUR'),
    -10000::numeric, 'GSTR-1: a note to an unregistered customer is CDNUR, negative');
  perform app_test.assert_equals(
    (select taxable_value from public.gst_summary(current_date, current_date) where hsn_code = '87141090'),
    v_before - 10000, 'and it nets against the HSN of the invoice it amends');
  perform app_test.assert_raises(
    format($q$select public.issue_gst_note('CREDIT', 'SERVICE_INVOICE', %L, 440001, 18, %L, 'OTHER', 'Too much')$q$,
      v_invoice, (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '4200')),
    'credit notes cannot take back more than was invoiced');

  -- A debit note, then cancelling the credit note.
  v_note2 := public.issue_gst_note(
    'DEBIT', 'SERVICE_INVOICE', v_invoice, 2000, 18,
    (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '4800'),
    'PRICE_REVISION', 'Freight recovered');
  perform app_test.assert_equals(
    (select total_amount from public.gst_notes where id = v_note2), 2360::numeric,
    'a debit note adds value and tax: 2,000 + 360');
  perform public.cancel_gst_note(v_note, 'Discount withdrawn');
  perform app_test.assert_equals(
    (select taxable_value from public.gstr1_summary(current_date, current_date) where section = 'CDNUR'),
    2000::numeric, 'a cancelled credit note leaves the return; the debit note stays');
  perform app_test.assert_raises(
    format($q$update public.gst_notes set taxable_value = 1 where id = %L$q$, v_note2),
    'a posted note cannot be edited');

  -- ── A supplier's credit note ──────────────────────────────────────────────
  select coalesce(sum(total_tax), 0) into v_before from public.gst_input_summary(current_date, current_date);
  v_note := public.issue_gst_note(
    'CREDIT', 'PURCHASE_BILL', v_stock, 5000, 18,
    (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '4800'),
    'DISCOUNT', 'Quarterly purchase discount', current_date, 'AT/CN/12');
  perform app_test.assert_equals(
    (select string_agg(c.code || case when l.debit > 0 then ' Dr ' || l.debit::numeric(18, 0) else ' Cr ' || l.credit::numeric(18, 0) end, ', ' order by c.code)
       from public.journal_entry_lines l join public.chart_of_accounts c on c.id = l.account_id
      where l.journal_entry_id = (select journal_entry_id from public.gst_notes where id = v_note)),
    '1900 Cr 450, 1910 Cr 450, 2200 Dr 5900, 4800 Cr 5000',
    'a supplier''s credit note reduces the payable and the input tax claimed');
  perform app_test.assert_equals(
    (select coalesce(sum(total_tax), 0) from public.gst_input_summary(current_date, current_date)),
    v_before - 900, 'and the input-tax summary with it');

  -- ── ITC reversal and re-claim ─────────────────────────────────────────────
  v_note := public.record_itc_adjustment('REVERSAL', 'RULE_42', v_branch, 100, 100, 0, 'Common credit on exempt turnover');
  perform app_test.assert_equals(
    (select string_agg(c.code || case when l.debit > 0 then ' Dr ' || l.debit::numeric(18, 0) else ' Cr ' || l.credit::numeric(18, 0) end, ', ' order by c.code)
       from public.journal_entry_lines l join public.chart_of_accounts c on c.id = l.account_id
      where l.journal_entry_id = (select journal_entry_id from public.itc_adjustments where id = v_note)),
    '1900 Cr 100, 1910 Cr 100, 5990 Dr 200', 'a reversal takes credit out of input tax into 5990');
  perform public.record_itc_adjustment('RECLAIM', 'RULE_42', v_branch, 75, 75, 0, 'Recomputed at year end');
  perform app_test.assert_raises(
    format($q$select public.record_itc_adjustment('RECLAIM', 'RULE_42', %L, 50, 50, 0, 'Too much')$q$, v_branch),
    'a re-claim cannot exceed what was reversed');
  perform app_test.assert_raises(
    format($q$update public.itc_adjustments set note = 'changed' where id = %L$q$, v_note),
    'an ITC adjustment is permanent');

  -- Rule 37: 180 days on, the unpaid supplier bills show their credit as due.
  select * into r from public.itc_rule37_candidates(current_date + 200)
   where bill_number = (select bill_number from public.purchase_bills where id = v_stock);
  perform app_test.assert_equals(r.cgst_due > 0 and r.cgst_due = r.sgst_due, true,
    'rule 37: an unpaid bill older than 180 days has credit due for reversal');
  perform public.record_itc_adjustment('REVERSAL', 'RULE_37', v_branch, r.cgst_due, r.sgst_due, r.igst_due,
    'Supplier unpaid after 180 days', current_date, v_stock);
  perform app_test.assert_equals(
    (select count(*)::int from public.itc_rule37_candidates(current_date + 200) where purchase_bill_id = v_stock), 0,
    'and once reversed it is no longer due');

  -- Every journal above balanced; so does the book.
  perform app_test.assert_equals(
    (select sum(debit_balance) - sum(credit_balance) from public.trial_balance(current_date)), 0::numeric,
    'the trial balance still balances');
end $$;

reset role;
select app_test.logout();
