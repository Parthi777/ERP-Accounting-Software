-- =============================================================================
-- TEST — TDS on supplier bills (0093)
-- =============================================================================
-- The rates below are illustrative figures this test enters itself, as the
-- accountant would; no rate ships with the product. What is checked is the
-- mechanism: an unreviewed section deducts nothing; thresholds (single and
-- aggregate, catching up the year's earlier bills); a lower-deduction
-- certificate until its limit; the rate without PAN; the supplier paid net and
-- 2745 credited in the same journal; a deposit recorded against the deductions;
-- 2745 equal to its subledger throughout.
-- =============================================================================

\echo '--- TDS ---'

create temporary table fixture_tds as
with d as (select id from public.dealers where code = 'SBM'),
     s as (insert into public.suppliers (dealer_id, name, supplier_type, mobile, city, state, pan)
           select id, 'TDS Test Contractors Pvt Ltd', 'SERVICE', '9840077301', 'Chennai', 'Tamil Nadu', 'AABCT1234C'
             from d returning id)
select (select id from s) as supplier_id,
       (select b.id from public.branches b join d on b.dealer_id = d.id where b.code = 'MAIN') as branch_id,
       (select c.id from public.chart_of_accounts c join d on c.dealer_id = d.id where c.code = '5900') as expense_id,
       (select ba.id from public.bank_accounts ba join d on ba.dealer_id = d.id where ba.status = 'ACTIVE' order by ba.created_at limit 1) as bank_id;
grant select on fixture_tds to authenticated;

select app_test.login('22222222-2222-4222-8222-222222222222');
set role authenticated;

create or replace function pg_temp.tds_bill(p_ref text, p_amount numeric) returns uuid
language plpgsql as $$
declare f record; v_bill uuid;
begin
  select * into f from fixture_tds;
  insert into public.purchase_bills (dealer_id, branch_id, supplier_id, supplier_bill_number, bill_date, created_by)
  values (app.current_dealer_id(), f.branch_id, f.supplier_id, p_ref, current_date, auth.uid())
  returning id into v_bill;
  insert into public.purchase_bill_lines
    (purchase_bill_id, dealer_id, line_number, line_type, account_id, description, quantity, unit_rate,
     taxable_value, cgst_rate, sgst_rate, igst_rate, cgst_amount, sgst_amount, igst_amount, total_amount)
  values (v_bill, app.current_dealer_id(), 1, 'EXPENSE', f.expense_id, 'Showroom repair work', 1, p_amount,
          p_amount, 0, 0, 0, 0, 0, 0, p_amount);
  return v_bill;
end $$;

do $$
declare
  f        record;
  v_sec    uuid;
  v_b      uuid;
  v_entry  uuid;
  v_tds    uuid := app.require_account(app.current_dealer_id(), 'INVENTORY', 'PURCHASE', 'TDS_PAYABLE', null);
  v_check  record;
  v_rem    uuid;
  v_ids    uuid[];
begin
  select * into f from fixture_tds;

  insert into public.tds_deductor (dealer_id, tan, enabled) values (app.current_dealer_id(), 'CHES12345A', true)
  on conflict (dealer_id) do update set tan = excluded.tan, enabled = true;

  insert into public.tds_sections
    (dealer_id, code, act, section_ref, description, rate, rate_without_pan, single_threshold,
     aggregate_threshold, threshold_basis, effective_from, source_note, created_by)
  values
    (app.current_dealer_id(), 'CONTRACT', 'IT_2025', '393(1) Table Sl. No. 6(i)', 'Payment to contractors',
     2, 20, 30000, 100000, 'WHOLE_AGGREGATE', date '2026-04-01', 'Test fixture — illustrative figures only', auth.uid())
  returning id into v_sec;

  update public.suppliers set tds_section_code = 'CONTRACT', tds_payee_type = 'COMPANY', tds_pan_verified = true
   where id = f.supplier_id;

  -- ── Unreviewed: refused ────────────────────────────────────────────────
  v_b := pg_temp.tds_bill('TDS-1', 20000);
  perform app_test.assert_raises(format($q$select public.post_purchase_bill(%L)$q$, v_b),
    'a bill under an unreviewed section is refused', 'not been reviewed');
  perform app_test.assert_raises(
    format($q$update public.tds_sections set rate = 1 where id = %L$q$, v_sec),
    'a section''s rate is not edited in place', 'not edited');
  perform public.review_tds_section(v_sec);

  -- ── Below both thresholds: a nil deduction is still recorded ──────────
  perform public.post_purchase_bill(v_b);
  perform app_test.assert_equals(
    (select amount::text || '|' || rate_basis from public.tds_deductions where purchase_bill_id = v_b),
    '0.00|BELOW_THRESHOLD', '₹20,000 is below both thresholds: nothing deducted, but counted');
  v_b := pg_temp.tds_bill('TDS-2', 25000);
  perform public.post_purchase_bill(v_b);
  perform app_test.assert_equals((select amount from public.tds_deductions where purchase_bill_id = v_b), 0::numeric,
    '₹25,000 more: aggregate ₹45,000, still nothing');

  -- ── Crossing the single threshold catches up the year ─────────────────
  v_b := pg_temp.tds_bill('TDS-3', 60000);
  perform app_test.assert_equals((select amount from public.tds_preview(v_b)), 2100::numeric,
    'the preview shows the deduction before posting');
  v_entry := public.post_purchase_bill(v_b);
  perform app_test.assert_equals(
    (select deductible_base::text || '|' || amount::text from public.tds_deductions where purchase_bill_id = v_b),
    '105000.00|2100.00', '₹60,000 crosses the single threshold: 2% on it and the earlier ₹45,000');
  perform app_test.assert_equals(
    (select credit from public.journal_entry_lines where journal_entry_id = v_entry and party_type = 'SUPPLIER'),
    57900::numeric, 'the supplier is owed the bill less TDS');
  perform app_test.assert_equals(
    (select credit from public.journal_entry_lines where journal_entry_id = v_entry and account_id = v_tds),
    2100::numeric, 'and 2745 is credited with the TDS in the same journal');

  -- ── A lower-deduction certificate, until its limit ────────────────────
  update public.suppliers
     set ldc_number = 'LDC-TEST-1', ldc_rate = 0.5, ldc_valid_from = current_date - 30,
         ldc_valid_to = current_date + 30, ldc_limit = 50000
   where id = f.supplier_id;
  v_b := pg_temp.tds_bill('TDS-4', 40000);
  perform public.post_purchase_bill(v_b);
  perform app_test.assert_equals(
    (select amount::text || '|' || rate_basis from public.tds_deductions where purchase_bill_id = v_b),
    '200.00|CERTIFICATE', 'the certificate rate applies within its limit');
  v_b := pg_temp.tds_bill('TDS-5', 20000);
  perform public.post_purchase_bill(v_b);
  perform app_test.assert_equals(
    (select amount::text || '|' || rate_basis from public.tds_deductions where purchase_bill_id = v_b),
    '400.00|SECTION', 'beyond the certificate''s limit the section rate applies');

  -- ── PAN not verified ───────────────────────────────────────────────────
  update public.suppliers set tds_pan_verified = false, ldc_number = null, ldc_rate = null,
         ldc_valid_from = null, ldc_valid_to = null, ldc_limit = null
   where id = f.supplier_id;
  v_b := pg_temp.tds_bill('TDS-6', 10000);
  perform public.post_purchase_bill(v_b);
  perform app_test.assert_equals(
    (select amount::text || '|' || rate_basis from public.tds_deductions where purchase_bill_id = v_b),
    '2000.00|NO_PAN', 'without a verified PAN the higher rate applies');

  -- ── A bill marked as bearing no TDS ───────────────────────────────────
  v_b := pg_temp.tds_bill('TDS-7', 5000);
  update public.purchase_bills set tds_mode = 'NONE' where id = v_b;
  perform public.post_purchase_bill(v_b);
  perform app_test.assert_equals((select count(*)::int from public.tds_deductions where purchase_bill_id = v_b), 0,
    'a bill marked "no TDS" deducts nothing and records nothing');

  -- ── 2745 against its subledger ─────────────────────────────────────────
  select * into v_check from public.tds_control_check();
  perform app_test.assert_equals(v_check.unremitted, 4700::numeric, 'four deductions are waiting to be deposited');
  perform app_test.assert_equals(v_check.difference, 0::numeric, '2745 equals the undeposited deductions');

  -- ── The deposit ────────────────────────────────────────────────────────
  select array_agg(d.id) into v_ids from public.tds_deductions d
   where d.supplier_id = f.supplier_id and d.amount > 0 and d.status = 'POSTED' and d.remittance_id is null;
  perform app_test.assert_raises(
    format($q$select public.record_tds_remittance(%L, current_date, '00421', '12345', %L::uuid[])$q$, f.bank_id, v_ids),
    'a BSR code is seven digits', 'tds_remittances_bsr_check');
  v_rem := public.record_tds_remittance(f.bank_id, current_date, '00421', '0510308', v_ids, 'tds-9zk');
  perform app_test.assert_equals(public.record_tds_remittance(f.bank_id, current_date, '00421', '0510308', v_ids, 'tds-9zk'),
    v_rem, 'a replayed deposit is the same deposit');
  perform app_test.assert_equals((select amount from public.tds_remittances where id = v_rem), 4700::numeric,
    'the deposit covers the four deductions');
  select * into v_check from public.tds_control_check();
  perform app_test.assert_equals(v_check.ledger_balance::text || '|' || v_check.unremitted::text, '0.00|0.00',
    'after the deposit 2745 and its subledger are both nil');
  perform app_test.assert_raises(
    format($q$select public.record_tds_remittance(%L, current_date, '00422', '0510308', %L::uuid[])$q$, f.bank_id, v_ids),
    'a deduction is not deposited twice', 'already deposited');
  perform app_test.assert_raises(
    format($q$select public.cancel_purchase_bill(%L, 'Entered twice')$q$,
      (select purchase_bill_id from public.tds_deductions where id = v_ids[1])),
    'a bill whose TDS is deposited cannot be cancelled', 'deposited');

  perform app_test.assert_equals(
    (select count(*)::int from public.tds_register(current_date - 1, current_date + 1) where supplier_name = 'TDS Test Contractors Pvt Ltd'), 6,
    'the register lists every bill the section applied to');
  perform app_test.assert_equals(
    (select sum(debit_balance) - sum(credit_balance) from public.trial_balance(current_date)), 0::numeric,
    'the trial balance nets to nil');

  -- Leave later tests' bills alone.
  update public.tds_deductor set enabled = false where dealer_id = app.current_dealer_id();
end $$;

reset role;
select app_test.logout();

select app_test.login('33333333-3333-4333-8333-333333333333');
set role authenticated;
do $$
begin
  perform app_test.assert_raises(
    $q$insert into public.tds_sections (dealer_id, code, act, section_ref, description, rate, effective_from, source_note)
       values (app.current_dealer_id(), 'MINE', 'IT_2025', 'x', 'x', 1, current_date, 'made up by the cashier')$q$,
    'a cashier cannot enter a TDS section');
  perform app_test.assert_raises(
    $q$select public.record_tds_remittance(null, current_date, '1', '0510308', array[gen_random_uuid()])$q$,
    'nor record a TDS deposit', 'may not');
end $$;
reset role;
select app_test.logout();
