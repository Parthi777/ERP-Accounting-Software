-- =============================================================================
-- TEST — quick service and counter bills, and the cashier's scope (0088)
-- =============================================================================
-- The cashier (branch MAIN only) bills a service by name, mobile and vehicle
-- number with four GST-inclusive values; the next visit is matched to the same
-- customer by vehicle number; a counter sale is a product name and a value.
-- Every bill posts, the cash is received, and the cashier cannot write
-- journals or reach another branch.
-- =============================================================================

\echo '--- quick billing and the cashier ---'

-- Fixture: the demo dealer's 18% code is GST18_ACC (made by 98_counter_sales).
update public.system_settings
   set value = '{"SPARES":"GST18_ACC","ACCESSORIES":"GST18_ACC","LABOUR":"GST18_ACC","WATERWASH":"GST18_ACC","CONSUMABLES":"GST18_ACC","OTHER":"GST18_ACC"}'::jsonb
 where key = 'quick_bill.tax_codes' and dealer_id = (select id from public.dealers where code = 'SBM');

select app_test.login('33333333-3333-4333-8333-333333333333');
set role authenticated;

do $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_main   uuid;
  v_north  uuid;
  r        record;
  r2       record;
  v_cust   uuid;
  v_before int;
begin
  select id into v_main  from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_north from public.branches where dealer_id = v_dealer and code = 'NORTH';

  -- ── A service bill: 760 spares, 500 labour, 150 wash, 90 consumables ────
  select * into r from public.create_quick_bill('SERVICE', v_main, 'Booman K', '9876501234', 'tn 34 az 1434',
    jsonb_build_array(
      jsonb_build_object('head', 'SPARES', 'amount', 760),
      jsonb_build_object('head', 'LABOUR', 'amount', 500),
      jsonb_build_object('head', 'WATERWASH', 'amount', 150),
      jsonb_build_object('head', 'CONSUMABLES', 'amount', 90)),
    'CASH', null, null, current_date, 'qb-1');

  perform app_test.assert_equals(r.total_amount, 1500::numeric,
    'the bill comes to what was typed: the values are GST-inclusive');
  perform app_test.assert_equals(r.balance_due, 0::numeric, 'the cash received is the whole bill by default');
  perform app_test.assert_equals(r.receipt_number ~ '^REC-', true, 'and a receipt is issued for printing');
  perform app_test.assert_equals(
    (select taxable_value || '/' || cgst_amount || '/' || sgst_amount from public.service_lines
      where invoice_id = r.invoice_id and line_type = 'SPARE'),
    '644.0700/57.9700/57.9600', 'spares 760 at 18% inclusive: 644.07 + CGST 57.97 + SGST 57.96');
  perform app_test.assert_equals(
    (select job_card_id is null and vehicle_registration = 'TN34AZ1434' from public.service_invoices where id = r.invoice_id),
    true, 'a service bill needs no job card and carries the vehicle number');
  perform app_test.assert_equals(
    (select count(*)::int from public.inventory_transactions where reference_id = r.invoice_id), 0,
    'and moves no stock');
  v_cust := r.customer_id;

  -- ── The same vehicle again, typed differently, no mobile ────────────────
  select * into r2 from public.create_quick_bill('SERVICE', v_main, '', null, 'TN-34-AZ-1434',
    jsonb_build_array(jsonb_build_object('head', 'LABOUR', 'amount', 300)), 'UPI', 100, 'UPI-77', current_date, 'qb-2');
  perform app_test.assert_equals(r2.customer_id, v_cust, 'the vehicle number finds the same customer');
  perform app_test.assert_equals(r2.balance_due, 200::numeric, 'a part payment leaves the rest on their account');
  perform app_test.assert_equals(
    (select count(*)::int from public.customers where mobile = '9876501234'), 1, 'no duplicate customer');

  -- Replayed, the same bill comes back.
  perform app_test.assert_equals(
    (select invoice_id from public.create_quick_bill('SERVICE', v_main, '', null, 'TN34AZ1434',
       jsonb_build_array(jsonb_build_object('head', 'LABOUR', 'amount', 300)), 'UPI', 100, 'UPI-77', current_date, 'qb-2')),
    r2.invoice_id, 'a repeated submission returns the same bill');

  -- ── A counter sale: a product name and a value ──────────────────────────
  select * into r from public.create_quick_bill('COUNTER', v_main, 'Walk-in Kumar', '9876501299', null,
    jsonb_build_array(jsonb_build_object('head', 'SPARES', 'amount', 118, 'description', 'Brake shoe')),
    'CASH', null, null, current_date, 'qb-3');
  perform app_test.assert_equals(
    (select invoice_type || ' ' || (invoice_number ~ '^CSI-')::text from public.service_invoices where id = r.invoice_id),
    'COUNTER true', 'a counter bill is numbered in the counter series');
  perform app_test.assert_equals(
    (select description || ' ' || taxable_value::numeric(18, 2) from public.service_lines where invoice_id = r.invoice_id),
    'Brake shoe 100.00', 'the typed product name is the line, 118 inclusive of 18%');

  -- ── The cashier's limits ────────────────────────────────────────────────
  perform app_test.assert_raises(
    format($q$select * from public.create_quick_bill('SERVICE', %L, 'X', '9876501288', 'TN01AA0001',
      '[{"head":"LABOUR","amount":10}]'::jsonb)$q$, v_north),
    'a cashier cannot bill in another branch');
  perform app_test.assert_raises(
    $q$select public.post_manual_journal(current_date, 'cashier journal', '[]'::jsonb)$q$,
    'a cashier cannot post journals');
  perform app_test.assert_equals(
    (select count(*)::int from public.service_invoices where branch_id <> v_main), 0,
    'and sees no other branch''s bills');
  perform app_test.assert_equals(app.has_permission('inventory.view'), false, 'nor the inventory');
  perform app_test.assert_raises(
    format($q$select * from public.create_quick_bill('SERVICE', %L, 'Y', '1234567890', 'TN01AA0002',
      '[{"head":"LABOUR","amount":10}]'::jsonb)$q$, v_main),
    'a mobile number must be a real one');
end $$;

reset role;
select app_test.logout();

-- The ledger side, which the cashier is not allowed to read.
do $$
declare v_inv uuid;
begin
  select id into v_inv from public.service_invoices
   where vehicle_registration = 'TN34AZ1434' order by created_at limit 1;
  perform app_test.assert_equals(
    (select string_agg(c.code || ' Cr ' || l.credit::numeric(18, 2), ', ' order by c.code)
       from public.journal_entry_lines l join public.chart_of_accounts c on c.id = l.account_id
      where l.journal_entry_id = (select journal_entry_id from public.service_invoices where id = v_inv)
        and c.code in ('4300', '4400', '4410', '4420')),
    '4300 Cr 644.07, 4400 Cr 423.73, 4410 Cr 127.12, 4420 Cr 76.27',
    'each head posts to its own income account');
  perform app_test.assert_equals(
    (select amount from public.cash_transactions where journal_entry_id =
       (select journal_entry_id from public.service_payments where invoice_id = v_inv)), 1500::numeric,
    'the cash book takes the 1,500');
  perform app_test.assert_equals(
    (select created_by from public.journal_entries where id =
       (select journal_entry_id from public.service_invoices where id = v_inv)),
    '33333333-3333-4333-8333-333333333333'::uuid, 'the journal remembers the cashier who raised it');
end $$;
