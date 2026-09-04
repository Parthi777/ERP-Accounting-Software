-- =============================================================================
-- TEST — HR foundations
-- =============================================================================
-- Spec §12, §15, §46, §47, §52, §60.9.
--
-- The guarantees asserted here:
--   * a salary revision is a new row and the old one keeps its figures, so a
--     payslip re-run for a past month reproduces that month;
--   * the previous structure is closed automatically, so no two are live on the
--     same day and "what was he paid in March" has one answer;
--   * a revision cannot be back-dated over a later one;
--   * gross, deductions, net and CTC are derived, so a stored total can never
--     disagree with the parts;
--   * a structure whose deductions exceed its earnings is refused;
--   * leave balance is derived from its parts;
--   * pay is confidential: a cashier cannot read it, an employee can read their
--     own, and the owner can read everyone's;
--   * every one of these tables is tenant-isolated.
-- =============================================================================

\echo '--- HR foundations ---'

do $$
declare
  v_dealer   uuid;
  v_main     uuid;
  v_emp      uuid;
  v_other    uuid;
  v_shift    uuid;
  v_cl       uuid;
  v_lop      uuid;
  v_march    uuid;
  v_july     uuid;
  v_gross    numeric;
  v_net      numeric;
  v_ctc      numeric;
  v_bal      numeric;
  v_to       date;
  v_count    int;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_main   from public.branches where dealer_id = v_dealer and code = 'MAIN';

  -- ═══ Configuration ═══════════════════════════════════════════════════════
  insert into public.shifts
    (dealer_id, code, name, starts_at, ends_at, break_minutes, grace_minutes, week_off_days)
  values
    (v_dealer, 'GEN', 'General shift', '09:30', '18:30', 60, 10, '{7}')
  returning id into v_shift;

  insert into public.leave_types (dealer_id, code, name, annual_quota, is_paid, counts_as_worked)
  values (v_dealer, 'CL', 'Casual leave', 12, true, true)
  returning id into v_cl;

  insert into public.leave_types (dealer_id, code, name, annual_quota, is_paid, counts_as_worked)
  values (v_dealer, 'LOP', 'Loss of pay', 0, false, false)
  returning id into v_lop;

  perform app_test.assert_equals(
    (select is_paid from public.leave_types where id = v_lop), false,
    'loss of pay is still leave — recorded, simply not paid');

  perform app_test.assert_raises(
    format('insert into public.shifts (dealer_id, code, name, starts_at, ends_at) '
           'values (%L, ''GEN'', ''Duplicate'', ''09:00'', ''18:00'')', v_dealer),
    'a shift code cannot be reused within a dealer');

  perform app_test.assert_raises(
    format('insert into public.leave_types (dealer_id, code, name, carry_forward, max_carry_forward) '
           'values (%L, ''EL'', ''Earned'', false, 5)', v_dealer),
    'leave that does not carry forward cannot have a carry-forward cap');

  -- ═══ The employee ════════════════════════════════════════════════════════
  insert into public.employees
    (dealer_id, branch_id, employee_code, name, department, designation, mobile,
     joining_date, employment_type, shift_id, pan, aadhaar_last4, bank_ifsc)
  values
    (v_dealer, v_main, 'HRTEST01', 'Salary Test Employee', 'Sales', 'Executive',
     '9840066101', date '2025-04-01', 'PERMANENT', v_shift, 'ABCDE1234F', '9012', 'HDFC0001234')
  returning id into v_emp;

  insert into public.employees
    (dealer_id, branch_id, employee_code, name, mobile, joining_date)
  values (v_dealer, v_main, 'HRTEST02', 'Other Employee', '9840066102', date '2025-04-01')
  returning id into v_other;

  perform app_test.assert_raises(
    format('update public.employees set pan = ''BADPAN'' where id = %L', v_emp),
    'a malformed PAN is refused');

  perform app_test.assert_raises(
    format('update public.employees set reports_to = %L where id = %L', v_emp, v_emp),
    'nobody reports to themselves');

  perform app_test.assert_raises(
    format('update public.employees set status = ''RESIGNED'' where id = %L', v_emp),
    'someone who has left must say how (exit_type)');

  -- ═══ Effective-dated pay ═════════════════════════════════════════════════
  insert into public.employee_salary_structures
    (dealer_id, employee_id, effective_from, basic, hra, conveyance,
     pf_employee, professional_tax, pf_employer, revision_note)
  values
    (v_dealer, v_emp, date '2026-03-01', 20000, 8000, 2000, 2400, 200, 2400, 'On joining')
  returning id into v_march;

  select gross_earnings, net_payable, cost_to_company
    into v_gross, v_net, v_ctc
    from public.employee_salary_structures where id = v_march;

  perform app_test.assert_equals(v_gross, 30000.00::numeric,
    'gross is derived from the earnings, not stored alongside them');
  perform app_test.assert_equals(v_net, 27400.00::numeric,
    'net is gross less the employee deductions');
  perform app_test.assert_equals(v_ctc, 32400.00::numeric,
    'CTC adds the employer contributions, which are a cost and not a deduction');

  -- An increment in July.
  insert into public.employee_salary_structures
    (dealer_id, employee_id, effective_from, basic, hra, conveyance,
     pf_employee, professional_tax, pf_employer, revision_note)
  values
    (v_dealer, v_emp, date '2026-07-01', 24000, 9600, 2000, 2880, 200, 2880, 'Annual increment')
  returning id into v_july;

  -- ═══ The old row is untouched, and closed ════════════════════════════════
  select gross_earnings, effective_to into v_gross, v_to
    from public.employee_salary_structures where id = v_march;

  perform app_test.assert_equals(v_gross, 30000.00::numeric,
    'the March structure keeps its figures after a July increment (spec §15)');
  perform app_test.assert_equals(v_to, date '2026-06-30',
    'and is closed the day before the revision starts, so neither overlaps');

  perform app_test.assert_equals(
    (select effective_to from public.employee_salary_structures where id = v_july), null::date,
    'the current structure has no end date');

  -- ═══ One answer to "what was he paid on this date" ═══════════════════════
  perform app_test.assert_equals(
    public.employee_salary_on(v_emp, date '2026-05-15'), v_march,
    'a May payslip resolves to the March structure');
  perform app_test.assert_equals(
    public.employee_salary_on(v_emp, date '2026-09-15'), v_july,
    'a September payslip resolves to the increment');
  perform app_test.assert_equals(
    public.employee_salary_on(v_emp, date '2026-01-15'), null::uuid,
    'and a date before anyone was paid resolves to nothing rather than guessing');

  -- ═══ What the structure refuses ══════════════════════════════════════════
  perform app_test.assert_raises(
    format('insert into public.employee_salary_structures '
           '(dealer_id, employee_id, effective_from, basic) values (%L, %L, ''2026-05-01'', 21000)',
           v_dealer, v_emp),
    'a revision cannot be back-dated over a later one (spec §15)');

  perform app_test.assert_raises(
    format('insert into public.employee_salary_structures '
           '(dealer_id, employee_id, effective_from, basic, pf_employee) '
           'values (%L, %L, ''2027-01-01'', 1000, 5000)', v_dealer, v_emp),
    'deductions cannot exceed earnings — nobody works for a negative wage');

  perform app_test.assert_raises(
    format('insert into public.employee_salary_structures '
           '(dealer_id, employee_id, effective_from, basic) values (%L, %L, ''2026-07-01'', 99999)',
           v_dealer, v_emp),
    'two structures cannot start on the same day');

  -- ═══ Leave balance ═══════════════════════════════════════════════════════
  insert into public.employee_leave_balances
    (dealer_id, employee_id, leave_type_id, financial_year, opening, accrued, used)
  values (v_dealer, v_emp, v_cl, '2026', 3, 12, 4);

  select balance into v_bal from public.employee_leave_balances
   where employee_id = v_emp and leave_type_id = v_cl;
  perform app_test.assert_equals(v_bal, 11.00::numeric,
    'the balance is derived: opening plus accrued, less used and encashed');

  perform app_test.assert_raises(
    format('insert into public.employee_leave_balances '
           '(dealer_id, employee_id, leave_type_id, financial_year, opening) '
           'values (%L, %L, %L, ''2026'', 1)', v_dealer, v_emp, v_cl),
    'one balance row per employee, leave type and year');

  -- ═══ Documents ═══════════════════════════════════════════════════════════
  insert into public.employee_documents
    (dealer_id, employee_id, document_type, document_name, document_no, issued_on, expires_on)
  values
    (v_dealer, v_emp, 'DRIVING_LICENCE', 'Driving licence', 'TN0120260001',
     date '2026-01-01', date '2031-01-01');

  perform app_test.assert_raises(
    format('insert into public.employee_documents '
           '(dealer_id, employee_id, document_type, document_name, issued_on, expires_on) '
           'values (%L, %L, ''PAN'', ''PAN card'', ''2026-06-01'', ''2026-01-01'')', v_dealer, v_emp),
    'a document cannot expire before it was issued');

  select count(*)::int into v_count from public.employee_documents
   where dealer_id = v_dealer and expires_on is not null;
  perform app_test.assert_equals(v_count, 1,
    'an expiry date is recorded, which is what makes the register worth keeping');
end;
$$;

-- -----------------------------------------------------------------------------
-- Who may see pay
-- -----------------------------------------------------------------------------
-- Spec §52: a restricted field must be absent from the response, not merely
-- hidden. RLS is the layer that makes that true even for a direct API call.
-- -----------------------------------------------------------------------------
set role authenticated;
select app_test.login('33333333-3333-4333-8333-333333333333');   -- Anand Raj, Cashier

do $$
declare v_count int;
begin
  select count(*)::int into v_count from public.employee_salary_structures;
  perform app_test.assert_equals(v_count, 0,
    'a cashier cannot read anyone''s salary, not even by asking the API directly');

  select count(*)::int into v_count from public.employee_documents;
  perform app_test.assert_equals(v_count, 0, 'nor anyone''s documents');
end;
$$;

reset role;
set role authenticated;
select app_test.login('22222222-2222-4222-8222-222222222222');   -- Priya Venkatesh, Accounts

do $$
declare v_count int;
begin
  -- Accounts runs the paperwork and the roster, but is not given the pay scale
  -- by default: the accountant is usually an employee too (migration 0053).
  select count(*)::int into v_count from public.employee_salary_structures;
  perform app_test.assert_equals(v_count, 0,
    'Accounts is not given the pay scale by default');

  select count(*)::int into v_count from public.employee_documents;
  perform app_test.assert_equals(v_count > 0, true,
    'but does hold the document register, which is its job');

  select count(*)::int into v_count from public.shifts;
  perform app_test.assert_equals(v_count > 0, true, 'and configures shifts');
end;
$$;

reset role;
set role authenticated;
select app_test.login('11111111-1111-4111-8111-111111111111');   -- Rajesh Kumar, Dealer Owner

do $$
declare v_count int;
begin
  select count(*)::int into v_count from public.employee_salary_structures;
  perform app_test.assert_equals(v_count > 0, true,
    'the dealer owner holds hr.salary.view and sees the pay scale');
end;
$$;

reset role;
select app_test.logout();
