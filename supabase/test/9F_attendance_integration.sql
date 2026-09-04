-- =============================================================================
-- TEST — attendance mirrored from an external system
-- =============================================================================
-- Spec §12, §40, §48, §50, §59.
--
-- The guarantees asserted here:
--   * a pull writes the mirror, and pulling the same range twice writes the same
--     rows rather than doubling anyone's month (spec §50);
--   * a day corrected by hand is never overwritten by a later sync;
--   * a record whose external id matches nobody is counted, not guessed at;
--   * a vendor failure closes the run FAILED and leaves the mirror untouched;
--   * two employees cannot be mapped to one external record;
--   * days worked, leave and payable days come out of one function, so payroll
--     and the register cannot disagree;
--   * paid leave counts as worked only when the leave type says so.
-- =============================================================================

\echo '--- attendance integration ---'

-- start_attendance_sync() resolves the dealer from the session, as it must: a
-- sync belongs to whoever asked for it. The setup below therefore runs with a
-- user in context but WITHOUT `set role authenticated`, so RLS stays out of the
-- way while the fixtures are built. The permission checks at the foot of the
-- file switch role properly.
select app_test.login('11111111-1111-4111-8111-111111111111');   -- Rajesh Kumar, Dealer Owner

do $$
declare
  v_dealer  uuid;
  v_main    uuid;
  v_shift   uuid;
  v_cl      uuid;
  v_lop     uuid;
  v_alice   uuid;
  v_bob     uuid;
  v_run     uuid;
  v_res     record;
  v_sum     record;
  v_status  text;
  v_source  text;
  v_count   int;
  v_minutes int;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_main   from public.branches where dealer_id = v_dealer and code = 'MAIN';

  insert into public.shifts (dealer_id, code, name, starts_at, ends_at)
  values (v_dealer, 'ATT-GEN', 'Attendance test shift', '09:30', '18:30')
  returning id into v_shift;

  insert into public.leave_types (dealer_id, code, name, annual_quota, is_paid, counts_as_worked)
  values (v_dealer, 'ATT-CL', 'Casual', 12, true, true) returning id into v_cl;

  insert into public.leave_types (dealer_id, code, name, annual_quota, is_paid, counts_as_worked)
  values (v_dealer, 'ATT-LOP', 'Loss of pay', 0, false, false) returning id into v_lop;

  insert into public.employees
    (dealer_id, branch_id, employee_code, name, mobile, joining_date, shift_id, external_ref)
  values
    (v_dealer, v_main, 'ATT0001', 'Attendance Alice', '9840055201', date '2025-04-01', v_shift, 'EXT-1001')
  returning id into v_alice;

  -- Bob is deliberately left unmapped: his attendance can never arrive, and the
  -- point of the test is that this is counted rather than silently lost.
  insert into public.employees
    (dealer_id, branch_id, employee_code, name, mobile, joining_date, shift_id)
  values
    (v_dealer, v_main, 'ATT0002', 'Attendance Bob', '9840055202', date '2025-04-01', v_shift)
  returning id into v_bob;

  perform app_test.assert_raises(
    format('update public.employees set external_ref = ''EXT-1001'' where id = %L', v_bob),
    'two employees cannot be mapped to one external record');

  -- ═══ The first pull ══════════════════════════════════════════════════════
  v_run := public.start_attendance_sync(date '2026-09-01', date '2026-09-30');
  perform app_test.assert_equals(
    (select status from public.attendance_sync_runs where id = v_run), 'RUNNING',
    'the run is recorded before the vendor is called, so a crash leaves evidence');

  select * into v_res from public.import_attendance_days(v_run, jsonb_build_array(
    jsonb_build_object('external_ref', 'EXT-1001', 'date', '2026-09-01', 'status', 'PRESENT',
                       'first_in', '09:28', 'last_out', '18:35', 'worked_minutes', 487,
                       'late_minutes', 0, 'record_ref', 'att-1'),
    jsonb_build_object('external_ref', 'EXT-1001', 'date', '2026-09-02', 'status', 'PRESENT',
                       'first_in', '09:52', 'last_out', '18:31', 'worked_minutes', 459,
                       'late_minutes', 12, 'record_ref', 'att-2'),
    jsonb_build_object('external_ref', 'EXT-1001', 'date', '2026-09-03', 'status', 'LEAVE',
                       'leave_code', 'ATT-CL', 'record_ref', 'att-3'),
    jsonb_build_object('external_ref', 'EXT-1001', 'date', '2026-09-04', 'status', 'LEAVE',
                       'leave_code', 'ATT-LOP', 'record_ref', 'att-4'),
    jsonb_build_object('external_ref', 'EXT-1001', 'date', '2026-09-05', 'status', 'ABSENT',
                       'record_ref', 'att-5'),
    jsonb_build_object('external_ref', 'EXT-1001', 'date', '2026-09-06', 'status', 'WEEK_OFF',
                       'record_ref', 'att-6'),
    -- Nobody here has this id.
    jsonb_build_object('external_ref', 'EXT-9999', 'date', '2026-09-01', 'status', 'PRESENT',
                       'record_ref', 'att-x'),
    -- Outside the window the run declared.
    jsonb_build_object('external_ref', 'EXT-1001', 'date', '2026-10-15', 'status', 'PRESENT',
                       'record_ref', 'att-late')
  ));

  perform app_test.assert_equals(v_res.matched, 6, 'six records matched a mapped employee');
  perform app_test.assert_equals(v_res.unmatched, 1,
    'the record for an unknown id is counted, never guessed at');
  perform app_test.assert_equals(v_res.written, 6, 'and six days were written');

  select count(*)::int into v_count from public.attendance_days
   where employee_id = v_alice and attendance_date = date '2026-10-15';
  perform app_test.assert_equals(v_count, 0,
    'a record outside the requested window is not imported');

  -- Leave the dealer does not have a code for is still recorded as a day.
  select status into v_status from public.attendance_days
   where employee_id = v_alice and attendance_date = date '2026-09-03';
  perform app_test.assert_equals(v_status, 'LEAVE', 'a mapped leave code becomes leave');

  perform public.finish_attendance_sync(v_run, 'PARTIAL', null, null);
  perform app_test.assert_equals(
    (select status from public.attendance_sync_runs where id = v_run), 'PARTIAL',
    'a run with unmatched records finishes PARTIAL, not SUCCESS');
  perform app_test.assert_equals(
    (select finished_at is not null from public.attendance_sync_runs where id = v_run), true,
    'and is stamped as finished');

  -- ═══ A correction by hand ════════════════════════════════════════════════
  -- The device missed Alice's punch on the 5th; someone who was there fixes it.
  update public.attendance_days
     set status = 'PRESENT', first_in = '09:30', last_out = '18:30',
         worked_minutes = 480, source = 'MANUAL', remarks = 'Missed punch, confirmed by manager'
   where employee_id = v_alice and attendance_date = date '2026-09-05';

  -- ═══ Pulling the same range again ════════════════════════════════════════
  v_run := public.start_attendance_sync(date '2026-09-01', date '2026-09-30');

  select * into v_res from public.import_attendance_days(v_run, jsonb_build_array(
    jsonb_build_object('external_ref', 'EXT-1001', 'date', '2026-09-01', 'status', 'PRESENT',
                       'first_in', '09:28', 'last_out', '18:35', 'worked_minutes', 487,
                       'record_ref', 'att-1'),
    -- The vendor still says absent; the human said otherwise and outranks it.
    jsonb_build_object('external_ref', 'EXT-1001', 'date', '2026-09-05', 'status', 'ABSENT',
                       'record_ref', 'att-5')
  ));

  perform app_test.assert_equals(v_res.skipped_manual, 1,
    'a day corrected by hand is left alone by the next sync');
  perform app_test.assert_equals(v_res.written, 1, 'and only the untouched day is rewritten');

  select status, source into v_status, v_source from public.attendance_days
   where employee_id = v_alice and attendance_date = date '2026-09-05';
  perform app_test.assert_equals(v_status, 'PRESENT',
    'the correction survives — the person who fixed it knew more than the device');
  perform app_test.assert_equals(v_source, 'MANUAL', 'and it stays marked as corrected');

  select count(*)::int into v_count from public.attendance_days where employee_id = v_alice;
  perform app_test.assert_equals(v_count, 6,
    'pulling the same range twice does not double anyone''s month (spec §50)');

  perform public.finish_attendance_sync(v_run, 'SUCCESS', null, null);

  -- ═══ A vendor failure changes nothing ════════════════════════════════════
  v_run := public.start_attendance_sync(date '2026-09-01', date '2026-09-30');
  perform public.finish_attendance_sync(v_run, 'FAILED', 'Connection refused', null);

  select count(*)::int into v_count from public.attendance_days where employee_id = v_alice;
  perform app_test.assert_equals(v_count, 6,
    'a failed pull leaves the mirror exactly as it was (spec §40)');
  perform app_test.assert_equals(
    (select last_error from public.attendance_sync_runs where id = v_run), 'Connection refused',
    'and the vendor''s own error is kept for whoever has to ring them');

  -- ═══ The figures payroll will read ═══════════════════════════════════════
  select * into v_sum from public.attendance_summary(date '2026-09-01', date '2026-09-30', v_main)
   where employee_id = v_alice;

  perform app_test.assert_equals(v_sum.present_days, 3.00::numeric,
    'three days present — the 1st, the 2nd and the corrected 5th');
  perform app_test.assert_equals(v_sum.leave_days, 2.00::numeric, 'two days of leave');
  perform app_test.assert_equals(v_sum.paid_leave_days, 1.00::numeric,
    'of which one is paid: loss of pay is leave, and is not');
  perform app_test.assert_equals(v_sum.week_off_days, 1, 'and one week off');

  -- 3 present + 1 counted leave + 1 week off = 5. The LOP day is not paid for.
  perform app_test.assert_equals(v_sum.payable_days, 5.00::numeric,
    'payable days follow leave_types.counts_as_worked, not a guess');

  perform app_test.assert_equals(v_sum.late_count, 1, 'one late arrival is counted');

  -- ═══ The unmapped employee is visible, not invisible ═════════════════════
  select * into v_sum from public.attendance_summary(date '2026-09-01', date '2026-09-30', v_main)
   where employee_id = v_bob;

  perform app_test.assert_equals(v_sum.recorded_days, 0,
    'an unmapped employee has no attendance at all');
  perform app_test.assert_equals(v_sum.payable_days, 0.00::numeric,
    'which reads as zero payable days — so the screen must flag the mapping, '
    'or payroll pays them nothing for a month they worked');
end;
$$;

-- -----------------------------------------------------------------------------
-- Who may see a register
-- -----------------------------------------------------------------------------
set role authenticated;
select app_test.login('33333333-3333-4333-8333-333333333333');   -- Anand Raj, Cashier

do $$
declare v_count int;
begin
  select count(*)::int into v_count from public.attendance_days;
  perform app_test.assert_equals(v_count, 0,
    'a cashier holds no attendance permission and sees no one''s register');

  select count(*)::int into v_count from public.attendance_sync_runs;
  perform app_test.assert_equals(v_count, 0, 'nor the sync history');
end;
$$;

reset role;
set role authenticated;
select app_test.login('22222222-2222-4222-8222-222222222222');   -- Priya Venkatesh, Accounts

do $$
declare v_count int;
begin
  select count(*)::int into v_count from public.attendance_days;
  perform app_test.assert_equals(v_count > 0, true,
    'Accounts runs the register, and sees it');
end;
$$;

reset role;
select app_test.logout();
