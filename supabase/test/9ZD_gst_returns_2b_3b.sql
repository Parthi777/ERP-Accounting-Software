-- =============================================================================
-- TEST — GSTR-2B matching, ITC claims, GSTR-3B, cross-checks, filing (0085)
-- =============================================================================
-- Checklist §08 (2B matching; personal purchases not claimed), §09 (GSTR-1,
-- GSTR-3B working and set-off, cross-return checks — Test C: books and returns
-- agree; Test D: a ₹18,000 difference between filed returns is flagged — and
-- filing evidence with sign-off). Runs in the ACPT tenant after 9Y and 9ZC.
-- =============================================================================

\echo '--- GST returns: 2B, 3B, cross-checks and filing ---'

-- Fixture: ACPT gets a GSTIN, its supplier one too, and a second person —
-- an accountant — so a return can be signed off by someone other than its preparer.
do $$
declare
  v_dealer uuid := (select id from public.dealers where code = 'ACPT');
begin
  update public.dealers set gstin = '33AACCA1234A1Z5' where id = v_dealer;
  update public.suppliers set gstin = '33AAAFA1111A1Z1' where dealer_id = v_dealer and name = 'Alpha Traders';

  insert into auth.users (id, email) values ('cccccccc-2222-4222-8222-cccccccccccc', 'accounts@acceptance.example')
  on conflict (id) do nothing;
  insert into public.user_profiles (id, dealer_id, full_name, email, status, has_all_branch_access)
  values ('cccccccc-2222-4222-8222-cccccccccccc', v_dealer, 'Acceptance Accountant', 'accounts@acceptance.example', 'ACTIVE', true)
  on conflict (id) do nothing;
  insert into public.user_roles (user_id, role_id)
  select 'cccccccc-2222-4222-8222-cccccccccccc', id from public.roles where code = 'ACCOUNTS' and is_system
  on conflict do nothing;
end $$;

select app_test.login('cccccccc-1111-4111-8111-cccccccccccc');
set role authenticated;

do $$
declare
  v_gstin  text := '33AACCA1234A1Z5';
  v_period date := date_trunc('month', current_date)::date;
  v_import uuid;
  v_stock  uuid := (select id from public.purchase_bills where supplier_bill_number = 'AT/STOCK/001');
  v_comp   uuid := (select id from public.purchase_bills where supplier_bill_number = 'AT/COMP/001');
  v_gta    uuid := (select id from public.purchase_bills where supplier_bill_number = 'GTA/77');
  r        record;
begin
  -- The owner's phone (9ZC) is posted: a personal purchase, in the books and in 2B.
  perform public.post_purchase_bill((select id from public.purchase_bills where supplier_bill_number = 'AT/PERSONAL/1'));

  -- ── GSTR-2B import and matching ──────────────────────────────────────────
  v_import := public.import_gstr2b(v_gstin, current_date, jsonb_build_array(
    jsonb_build_object('supplier_gstin', '33AAAFA1111A1Z1', 'document_number', 'at-comp-001',
      'document_date', current_date, 'taxable_value', 100000, 'cgst', 9000, 'sgst', 9000),
    jsonb_build_object('supplier_gstin', '33AAAFA1111A1Z1', 'document_number', 'AT/STOCK/001',
      'document_date', current_date, 'taxable_value', 500000, 'cgst', 44000, 'sgst', 44000),
    jsonb_build_object('supplier_gstin', '33AAAFA1111A1Z1', 'document_number', 'AT/PERSONAL/1',
      'document_date', current_date, 'taxable_value', 20000, 'cgst', 1800, 'sgst', 1800),
    jsonb_build_object('supplier_gstin', '33AAAFA1111A1Z1', 'document_number', 'AT/NEVER/9',
      'document_date', current_date, 'taxable_value', 1000, 'cgst', 90, 'sgst', 90)
  ), '2B-test.csv');

  perform app_test.assert_equals(
    (select string_agg(document_number || ':' || match_status, ', ' order by match_status)
       from public.gstr2b_lines where import_id = v_import),
    'at-comp-001:MATCHED, AT/PERSONAL/1:NOT_CLAIMABLE, AT/NEVER/9:NOT_IN_BOOKS, AT/STOCK/001:VALUE_MISMATCH',
    '2B lines are matched on supplier GSTIN and document number, whatever its punctuation or case');
  perform app_test.assert_equals(
    (select count(*)::int from public.gstr2b_reconciliation(v_import)
      where side = 'BOOKS' and match_status = 'NOT_IN_2B' and document_number = 'AT/STAFF/001'), 1,
    'a bill in the books that the 2B does not carry is NOT_IN_2B');
  perform app_test.assert_raises(
    format($q$select public.import_gstr2b(%L, current_date, '[{"supplier_gstin":"BAD","document_number":"X"}]'::jsonb)$q$, v_gstin),
    'a 2B file with an unusable line is refused whole');

  -- ── ITC claim controls ───────────────────────────────────────────────────
  select * into r from public.itc_claimable(v_gstin, current_date) where purchase_bill_id = v_comp;
  perform app_test.assert_equals(r.claimable and r.cgst_amount = 9000 and r.sgst_amount = 9000, true,
    'credit on a bill in 2B is claimable');
  select * into r from public.itc_claimable(v_gstin, current_date) where purchase_bill_id = v_stock;
  perform app_test.assert_equals(r.claimable and r.cgst_amount = 44000 and r.sgst_amount = 44000, true,
    'where 2B and the books differ, the lower is claimed (44,000 not 45,000)');
  perform app_test.assert_equals(
    (select count(*)::int from public.itc_claimable(v_gstin, current_date)
      where purchase_bill_id = (select id from public.purchase_bills where supplier_bill_number = 'AT/PERSONAL/1')), 0,
    'a personal purchase is never offered for claim, though it is in 2B');
  perform app_test.assert_equals(
    (select claimable from public.itc_claimable(v_gstin, current_date) where purchase_bill_id = v_gta and claim_kind = 'RCM'),
    true, 'reverse-charge credit is claimable without 2B');
  perform app_test.assert_equals(
    (select bool_and(not claimable) from public.itc_claimable(v_gstin, current_date)
      where claim_kind = 'INVOICE' and purchase_bill_id not in (v_comp, v_stock)), true,
    'credit on bills not yet in 2B waits');

  -- ── GSTR-3B working ──────────────────────────────────────────────────────
  perform app_test.assert_equals(
    (select taxable_value || '/' || cgst_amount || '/' || sgst_amount from public.gstr3b_working(v_gstin, current_date)
      where section = '3.1(d)'),
    '10000.0000/250.0000/250.0000', '3.1(d): the GTA freight under reverse charge');
  perform app_test.assert_equals(
    (select taxable_value from public.gstr3b_working(v_gstin, current_date) where section = '3.1(c)'),
    500::numeric, '3.1(c): the exempt charge');
  -- Test C: the books, GSTR-1 and GSTR-3B agree on output tax.
  perform app_test.assert_equals(
    (select string_agg(check_code || ':' || status, ', ' order by check_code) from public.gst_cross_checks(v_gstin, current_date)
      where check_code in ('BOOKS_VS_GSTR1', 'GSTR1_VS_GSTR3B')),
    'BOOKS_VS_GSTR1:OK, GSTR1_VS_GSTR3B:OK',
    'Test C: output tax in the ledger, GSTR-1 and GSTR-3B are the same figure');

  -- Set-off: every rupee of liability is paid by credit or cash, and credit
  -- used plus credit left is the credit there was.
  for r in select * from public.gstr3b_setoff(v_gstin, current_date) loop
    perform app_test.assert_equals(r.paid_by_igst + r.paid_by_cgst + r.paid_by_sgst + r.cash_payable - r.rcm_liability,
      r.liability, format('%s: liability = credit used + cash', r.tax_head));
  end loop;
  perform app_test.assert_equals(
    (select cash_payable >= rcm_liability and rcm_liability = 250 from public.gstr3b_setoff(v_gstin, current_date)
      where tax_head = 'CGST'), true,
    'reverse-charge tax is paid in cash, never from credit');
  perform app_test.assert_equals(
    (select sum(paid_by_cgst) filter (where tax_head = 'SGST') + sum(paid_by_sgst) filter (where tax_head = 'CGST')
       from public.gstr3b_setoff(v_gstin, current_date)), 0::numeric,
    'CGST credit never pays SGST, nor SGST credit CGST');
end $$;

-- ── Filing: prepared by the owner, signed off by the accountant ────────────
do $$
declare
  v_gstin text := '33AACCA1234A1Z5';
  v_r1    uuid;
  v_r3    uuid;
begin
  v_r1 := public.prepare_gst_return('GSTR1', v_gstin, current_date);
  v_r3 := public.prepare_gst_return('GSTR3B', v_gstin, current_date);
  perform app_test.assert_raises(format('select public.sign_off_gst_return(%L)', v_r1),
    'the preparer cannot sign off their own return');
  perform app_test.assert_raises(
    format($q$select public.record_gst_filing(%L, 'AA330000000001X', current_date, 1, 0, 0, 0)$q$, v_r1),
    'a return cannot be filed before it is signed off');
end $$;

reset role;
select app_test.login('cccccccc-2222-4222-8222-cccccccccccc');
set role authenticated;

do $$
declare
  v_gstin text := '33AACCA1234A1Z5';
  v_r1    public.gst_returns;
  v_r3    public.gst_returns;
  v_tax   numeric;
  v_bank  uuid;
  v_entry uuid;
begin
  select * into v_r1 from public.gst_returns where gstin = v_gstin and return_type = 'GSTR1';
  select * into v_r3 from public.gst_returns where gstin = v_gstin and return_type = 'GSTR3B';
  perform public.sign_off_gst_return(v_r1.id);
  perform public.sign_off_gst_return(v_r3.id);

  v_tax := (v_r1.computed->'totals'->>'cgst')::numeric;
  -- GSTR-1 filed as computed; GSTR-3B filed ₹18,000 short on output tax.
  perform public.record_gst_filing(v_r1.id, 'AA3309240000011', current_date,
    (v_r1.computed->'totals'->>'taxable')::numeric, 0, v_tax, v_tax);
  perform public.record_gst_filing(v_r3.id, 'AA3309240000012', current_date,
    (v_r1.computed->'totals'->>'taxable')::numeric, 0, v_tax - 9000, v_tax - 9000,
    0, 53000, 53000, 'CPIN2409001', 'CIN2409001', 1000);

  perform app_test.assert_equals(
    (select difference || ':' || status from public.gst_cross_checks(v_gstin, current_date)
      where check_code = 'FILED_GSTR1_VS_FILED_GSTR3B'),
    '18000.0000:DIFFERENCE', 'Test D: GSTR-1 and GSTR-3B as filed differ by ₹18,000, and it is flagged');
  perform app_test.assert_equals(
    (select status from public.gst_cross_checks(v_gstin, current_date) where check_code = 'FILED_VS_COMPUTED_GSTR3B'),
    'DIFFERENCE', 'and the 3B is shown short against the books');

  perform app_test.assert_equals(
    (select count(*)::int > 0 from public.gst_filed_documents where return_id = v_r1.id), true,
    'a filed GSTR-1 freezes the documents it reported');
  perform app_test.assert_equals(
    (select count(*)::int from public.itc_claim_lines where return_id = v_r3.id
      and purchase_bill_id in (select id from public.purchase_bills where supplier_bill_number in ('AT/COMP/001', 'AT/STOCK/001', 'GTA/77'))), 3,
    'a filed GSTR-3B records the credit it claimed, bill by bill');
  perform app_test.assert_equals(
    (select count(*)::int from public.itc_claimable(v_gstin, current_date) where purchase_bill_id in
      (select id from public.purchase_bills where supplier_bill_number in ('AT/COMP/001', 'AT/STOCK/001'))), 0,
    'so it can never be claimed again');

  perform app_test.assert_raises(format($q$update public.gst_returns set arn = 'CHANGED00' where id = %L$q$, v_r1.id),
    'a filed return is permanent');
  perform app_test.assert_raises(format($q$select public.prepare_gst_return('GSTR1', %L, current_date)$q$, v_gstin),
    'and cannot be re-prepared');

  -- The set-off posts: output tax cleared by credit and cash, the bank book written.
  select id into v_bank from public.bank_accounts limit 1;
  v_entry := public.post_gst_setoff(v_r3.id, v_bank);
  perform app_test.assert_equals(
    (select total_debit = total_credit and total_debit > 0 from public.journal_entries where id = v_entry), true,
    'the set-off journal balances');
  perform app_test.assert_equals(public.post_gst_setoff(v_r3.id, v_bank), v_entry, 'and posts once');
  perform app_test.assert_equals(
    (select string_agg(check_code || ':' || status, ', ') from public.gst_cross_checks(v_gstin, current_date)
      where check_code = 'BOOKS_VS_GSTR1'),
    'BOOKS_VS_GSTR1:OK', 'the set-off does not disturb the books-to-GSTR-1 check');
  perform app_test.assert_equals(
    (select sum(debit_balance) - sum(credit_balance) from public.trial_balance(current_date)), 0::numeric,
    'the trial balance still balances');
end $$;

-- ── Amendments: a document posted into a filed month ─────────────────────
reset role;
select app_test.login('cccccccc-1111-4111-8111-cccccccccccc');
set role authenticated;

do $$
declare
  v_gstin text := '33AACCA1234A1Z5';
  r       record;
begin
  select invoice_id into r from public.create_counter_invoice(
    (select id from public.branches limit 1),
    (select id from public.customers where name = 'Acceptance Customer'));
  perform public.add_service_line(r.invoice_id, 'OTHER_CHARGE', 'Late charge', 1, 1000, null, 'GST18');
  perform public.post_service_invoice(r.invoice_id);

  perform app_test.assert_equals(
    (select kind from public.gstr1_amendments(v_gstin, (date_trunc('month', current_date) + interval '1 month')::date)
      where document_id = r.invoice_id),
    'MISSED_IN_FILING', 'an invoice dated in a filed month is flagged for the next GSTR-1');
end $$;

reset role;
select app_test.logout();
