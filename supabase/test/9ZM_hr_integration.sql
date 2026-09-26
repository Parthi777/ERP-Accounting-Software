-- =============================================================================
-- TEST — the HR Payroll app connected: claims, people, payroll (0095)
-- =============================================================================
-- A claim approved in the HR app is booked here (Dr its head, Cr 2770 for the
-- employee) once its branch and head are mapped; the cashier pays it from the
-- cash book in one voucher; an approval taken back reverses an unpaid claim
-- and flags a paid one; a replayed webhook does nothing; payroll comes across
-- as a draft run that posts like any other. Webhook calls run with no user, as
-- the server's service client does.
-- =============================================================================

\echo '--- HR app integration ---'

create temporary table fixture_hr as
select d.id as dealer_id,
       (select id from public.branches where dealer_id = d.id and code = 'MAIN') as main_id,
       (select id from public.chart_of_accounts where dealer_id = d.id and code = '5900') as other_exp,
       (select id from public.chart_of_accounts where dealer_id = d.id and code = '2770') as claims_payable
  from public.dealers d where d.code = 'SBM';
grant select on fixture_hr to authenticated;

create or replace function pg_temp.hr_claim(p_id text, p_amount numeric, p_status text default 'APPROVED')
returns jsonb language sql as $$
  select jsonb_build_object(
    'id', p_id, 'claimNo', 7, 'voucherNo', 3, 'status', p_status, 'type', 'PETROL_EXPENSES',
    'typeLabel', 'Petrol Expenses', 'title', 'Fuel for PDI ' || p_id, 'amount', p_amount,
    'decidedAt', now(), 'decidedBy', 'Branch Manager', 'hasPhoto', true, 'hasDocument', false,
    'employee', jsonb_build_object('id', 'hre-1', 'code', 'HRE-0001', 'name', 'Karthik HR', 'branchId', 'hrb-main',
                                   'branchName', 'Main (HR)', 'mobile', '9840011111', 'status', 'ACTIVE'));
$$;

-- ── A claim arrives before anything is mapped ──────────────────────────────
do $$
declare f record;
begin
  select * into f from fixture_hr;
  perform app_test.assert_equals(
    public.hr_receive_event(f.dealer_id, 'evt-1', 'claim.approved', pg_temp.hr_claim('hrc-1', 450)),
    'WAITING_FOR_BRANCH', 'a claim from an unmapped HR branch waits');
  perform app_test.assert_equals(
    (select count(*)::int from public.hr_branch_map where dealer_id = f.dealer_id and hr_branch_id = 'hrb-main'), 1,
    'and its branch appears for mapping');
  perform app_test.assert_equals(
    public.hr_receive_event(f.dealer_id, 'evt-1', 'claim.approved', pg_temp.hr_claim('hrc-1', 450)),
    'DUPLICATE', 'a replayed webhook is recognised and does nothing');
end $$;

-- ── The accountant maps the branch; the pull brings the claim ─────────────
select app_test.login('22222222-2222-4222-8222-222222222222');
set role authenticated;
do $$
declare f record;
begin
  select * into f from fixture_hr;
  perform public.map_hr_branch('hrb-main', f.main_id);
end $$;
reset role;
select app_test.logout();

do $$
declare f record; v_claim public.employee_claims;
begin
  select * into f from fixture_hr;
  perform public.hr_sync_batch(f.dealer_id, jsonb_build_array(pg_temp.hr_claim('hrc-1', 450)), null,
                               '{"slug":"sbm","name":"SBM"}'::jsonb);
  select * into v_claim from public.employee_claims where dealer_id = f.dealer_id and hr_claim_id = 'hrc-1';
  perform app_test.assert_equals(v_claim.status, 'AWAITING_MAPPING', 'the pull brings the claim; its head is not mapped yet');
  perform app_test.assert_equals(
    (select external_ref || '|' || employee_code from public.employees where id = v_claim.employee_id), 'hre-1|HRE-0001',
    'and the employee is created, linked to the HR app');
  perform app_test.assert_equals(v_claim.accrual_journal_id is null, true, 'nothing is booked to an unmapped head');
end $$;

select app_test.login('22222222-2222-4222-8222-222222222222');
set role authenticated;
do $$
declare f record; v_claim public.employee_claims;
begin
  select * into f from fixture_hr;
  perform app_test.assert_raises(
    format($q$select public.map_hr_claim_head('PETROL_EXPENSES', %L)$q$,
      (select ledger_account_id from public.cash_accounts where branch_id = f.main_id)),
    'a claim is never booked straight to cash', 'not booked to cash');
  perform app_test.assert_equals(public.map_hr_claim_head('PETROL_EXPENSES', f.other_exp), 1,
    'mapping the head books the waiting claim');
  select * into v_claim from public.employee_claims where hr_claim_id = 'hrc-1';
  perform app_test.assert_equals(v_claim.status, 'APPROVED', 'which is now approved and payable');
  perform app_test.assert_equals(
    (select string_agg(c.code || ':' || l.debit::text || '/' || l.credit::text || coalesce(':' || l.party_type, ''), ',' order by c.code)
       from public.journal_entry_lines l join public.chart_of_accounts c on c.id = l.account_id
      where l.journal_entry_id = v_claim.accrual_journal_id),
    '2770:0.0000/450.0000:EMPLOYEE,5900:450.0000/0.0000', 'booked Dr the head, Cr 2770 for the employee');
end $$;
reset role;
select app_test.logout();

-- ── More claims: one booked at once, one taken back, one paid at the HR counter
do $$
declare f record;
begin
  select * into f from fixture_hr;
  perform app_test.assert_equals(
    public.hr_receive_event(f.dealer_id, 'evt-2', 'claim.approved', pg_temp.hr_claim('hrc-2', 120.50)),
    'APPROVED', 'with its head and branch mapped, a claim is booked on arrival');
  perform public.hr_receive_event(f.dealer_id, 'evt-3', 'claim.approved', pg_temp.hr_claim('hrc-3', 999));
  perform app_test.assert_equals(
    public.hr_receive_event(f.dealer_id, 'evt-4', 'claim.changed', pg_temp.hr_claim('hrc-3', 999, 'REJECTED')),
    'CANCELLED', 'an unpaid claim rejected in the HR app is cancelled here');
  perform app_test.assert_equals(
    (select sum(l.debit - l.credit) from public.journal_entry_lines l
       join public.journal_entries je on je.id = l.journal_entry_id
      where je.source_document_type = 'EMPLOYEE_CLAIM'
        and je.source_document_id = (select id from public.employee_claims where hr_claim_id = 'hrc-3')
        and l.account_id = f.other_exp),
    0::numeric, 'and its expense is reversed (the booking and its reversal net to nil)');
  perform app_test.assert_equals(
    (select reversal_journal_id is not null from public.employee_claims where hr_claim_id = 'hrc-3'), true,
    'by a reversal entry, not an edit');
  perform app_test.assert_equals(
    public.hr_receive_event(f.dealer_id, 'evt-5', 'claim.approved', pg_temp.hr_claim('hrc-9', 50, 'PAID')),
    'SKIPPED_PAID_IN_HR', 'a claim already paid at the HR counter is not brought here to be paid again');
end $$;

-- ── The cashier pays two claims in one voucher ────────────────────────────
select app_test.login('33333333-3333-4333-8333-333333333333');
set role authenticated;
do $$
declare
  f      record;
  v_ids  uuid[];
  v_pay  record;
  v_again record;
  v_rows int;
begin
  select * into f from fixture_hr;
  select array_agg(id order by hr_claim_id) into v_ids from public.employee_claims
   where hr_claim_id in ('hrc-1', 'hrc-2');
  perform app_test.assert_equals(coalesce(array_length(v_ids, 1), 0), 2, 'the cashier sees the claims to pay');
  select count(*)::int into v_rows from public.cash_transactions where branch_id = f.main_id;

  select * into v_pay from public.pay_employee_claims(v_ids, 'CASH', f.main_id, null, current_date, 'CV-9ZM', 'claims-9zm');
  perform app_test.assert_equals((select count(*)::int from public.cash_transactions where branch_id = f.main_id), v_rows + 1,
    'two claims are paid with one cash voucher');
  perform app_test.assert_equals((select amount from public.cash_transactions where id = v_pay.transaction_id), 570.50::numeric,
    'for their total');
  perform app_test.assert_equals(
    (select string_agg(distinct status || '/' || callback_status, ',') from public.employee_claims where id = any (v_ids)),
    'PAID/PENDING', 'both are paid and waiting to be reported to the HR app');
  select * into v_again from public.pay_employee_claims(v_ids, 'CASH', f.main_id, null, current_date, 'CV-9ZM', 'claims-9zm');
  perform app_test.assert_equals(v_again.transaction_id, v_pay.transaction_id, 'a replayed payment is the same payment');
  perform app_test.assert_raises(
    format($q$select public.pay_employee_claims(%L::uuid[], 'CASH', %L)$q$, v_ids, f.main_id),
    'a paid claim cannot be paid again', 'Only approved');
  perform app_test.assert_raises(
    format($q$select public.map_hr_claim_head('PETROL_EXPENSES', %L)$q$, f.other_exp),
    'the cashier cannot map claim heads', 'may not');
  perform app_test.assert_raises(
    format($q$select public.hr_receive_event(%L, 'evt-x', 'claim.approved', '{}'::jsonb)$q$, f.dealer_id),
    'nor act as the HR app''s webhook', 'permission denied');
end $$;
reset role;
select app_test.logout();

do $$
declare f record;
begin
  select * into f from fixture_hr;
  perform app_test.assert_equals(
    (select coalesce(sum(l.credit - l.debit), 0) from public.journal_entry_lines l
       join public.journal_entries je on je.id = l.journal_entry_id
      where l.account_id = f.claims_payable and je.status in ('POSTED', 'REVERSED')),
    0::numeric, 'Employee Claims Payable is cleared by the payment');
  perform public.hr_mark_callback(f.dealer_id, (select id from public.employee_claims where hr_claim_id = 'hrc-1'), true);
  perform app_test.assert_equals((select callback_status from public.employee_claims where hr_claim_id = 'hrc-1'), 'SENT',
    'the HR app acknowledging the payment is recorded');
  perform app_test.assert_equals(
    public.hr_receive_event(f.dealer_id, 'evt-6', 'claim.changed', pg_temp.hr_claim('hrc-2', 120.50, 'REJECTED')),
    'NEEDS_REVIEW', 'a paid claim taken back in the HR app is flagged, not undone');
end $$;

-- ── Payroll from the HR app ────────────────────────────────────────────────
select app_test.login('11111111-1111-4111-8111-111111111111');
set role authenticated;
do $$
declare v_runs int; v_run uuid; v_entry uuid;
begin
  v_runs := public.import_hr_payroll(date '2026-08-01', jsonb_build_array(jsonb_build_object(
    'employee', jsonb_build_object('id', 'hre-1', 'code', 'HRE-0001', 'name', 'Karthik HR', 'branchId', 'hrb-main', 'branchName', 'Main (HR)'),
    'gross', 20000, 'pf', 1800, 'esi', 150, 'professionalTax', 200, 'tds', 0, 'other', 0)));
  perform app_test.assert_equals(v_runs, 1, 'a month of HR payslips becomes one draft run per branch');
  select id into v_run from public.payroll_runs where source = 'HR' and period = date '2026-08-01';
  perform app_test.assert_equals((select net_pay from public.payroll_lines where run_id = v_run), 17850::numeric,
    'with the HR app''s figures');
  v_entry := public.post_payroll_run(v_run);
  perform app_test.assert_equals(v_entry is not null, true, 'and posts like any other payroll');
  perform app_test.assert_raises(
    $q$select public.import_hr_payroll(date '2026-08-01', '[{"employee":{"id":"hre-1","code":"HRE-0001","branchId":"hrb-main"},"gross":1}]'::jsonb)$q$,
    'a posted month is not imported over', 'already posted');
  perform app_test.assert_equals(
    (select sum(debit_balance) - sum(credit_balance) from public.trial_balance(current_date)), 0::numeric,
    'the trial balance nets to nil');
end $$;
reset role;
select app_test.logout();

-- ── Another dealer sees none of it ─────────────────────────────────────────
select app_test.login('cccccccc-1111-4111-8111-cccccccccccc');
set role authenticated;
do $$
begin
  perform app_test.assert_equals((select count(*)::int from public.employee_claims), 0, 'another dealer sees no claims');
  perform app_test.assert_equals((select count(*)::int from public.hr_branch_map), 0, 'nor the HR branch map');
end $$;
reset role;
select app_test.logout();
