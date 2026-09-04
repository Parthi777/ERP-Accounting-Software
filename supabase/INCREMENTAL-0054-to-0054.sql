-- =============================================================================
-- INCREMENTAL 0054 → 0054
-- =============================================================================
-- GENERATED FILE. Regenerate with:
--   FROM=0054 bash scripts/build-incremental.sh
--
-- For a database that ALREADY has migrations up to 0053.
-- Running the full ALL-IN-ONE.sql on such a database fails on the first table
-- that already exists; this contains only what is missing.
--
-- Wrapped in one transaction. If any statement fails the whole thing rolls back
-- and the database is left exactly as it was — there is no half-applied state to
-- clean up, and it is safe to fix the cause and run again.
--
-- Paste into the Supabase SQL Editor and Run.
-- =============================================================================

begin;



-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0054_attendance_integration.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0054 — Attendance, mirrored from an external system
-- =============================================================================
-- Spec §12, §40, §46, §47, §48, §50, §52, §59.
--
-- The dealer already runs an attendance SaaS. Rebuilding punch-in here would
-- give them two registers that disagree by lunchtime, so this does not do that:
-- it MIRRORS the external record into this database and leaves the other system
-- as the source of truth for who clocked in.
--
-- ── Why mirror rather than query live ───────────────────────────────────────
--
-- Three reasons, and each on its own would be enough:
--
--   1. Payroll has to reproduce March next year. A payslip that depends on a
--      vendor being reachable — or on the subscription still being paid — is a
--      payslip that stops existing when the contract ends.
--   2. Reports have to join attendance to branches, departments and salary
--      structures. The vendor cannot do that; it does not know what a branch is
--      here. Spec §59 wants reports reconciling with data held here.
--   3. A vendor outage must never block payroll. Mirrored data is simply stale,
--      and "last synced three days ago" is a state a person can act on.
--
-- This is the same rule spec §40 sets for the tax portal: build an integration
-- layer, and never let an external failure corrupt what is already recorded.
--
-- ── The one rule that stops the sync fighting a human ───────────────────────
--
-- A day corrected by hand is never overwritten by a later sync. Someone who
-- fixes a missed punch has more information than the device did, and a sync
-- that silently reverted them would teach everyone to stop correcting anything.
-- `source` is what carries that: SYNC rows are refreshed, MANUAL rows are left.
--
-- Rollback: drop table public.attendance_days, public.attendance_sync_runs;
--           drop function public.import_attendance_days(uuid, jsonb),
--                         public.start_attendance_sync(date, date),
--                         public.finish_attendance_sync(uuid, text, text);
--           alter table public.employees drop column external_ref;
--           delete from public.permissions where code like 'hr.attendance%';
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The join between the two systems
-- -----------------------------------------------------------------------------
-- The attendance app has its own id for each person, and it is not ours. This
-- column is the mapping, and it is the whole integration in one field: without
-- it every sync would have to guess, and guessing wrong attributes one person's
-- attendance to another.
-- -----------------------------------------------------------------------------
alter table public.employees
  add column if not exists external_ref text;

comment on column public.employees.external_ref is
  'This employee''s id in the external attendance system (spec §40). Unique per '
  'dealer: two employees mapped to one external record would split one person''s '
  'attendance across both.';

create unique index employees_external_ref_key
  on public.employees (dealer_id, external_ref)
  where external_ref is not null;

-- -----------------------------------------------------------------------------
-- attendance_sync_runs — what was fetched, when, and what went wrong
-- -----------------------------------------------------------------------------
-- Modelled on the e-invoice queue (0034, 0048): the attempt is recorded before
-- the call, so a run that dies mid-flight leaves evidence rather than nothing.
-- -----------------------------------------------------------------------------
create table public.attendance_sync_runs (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null references public.dealers (id) on delete restrict,

  from_date      date not null,
  to_date        date not null,

  status         text not null default 'RUNNING',

  fetched_count   integer not null default 0,
  -- Rows whose external_ref matched an employee here.
  matched_count   integer not null default 0,
  -- Rows that did not. The count that matters: unmatched attendance is somebody
  -- whose pay will be wrong, and it is silent unless it is counted.
  unmatched_count integer not null default 0,
  written_count   integer not null default 0,
  -- Days left alone because a person had corrected them by hand.
  skipped_manual_count integer not null default 0,

  -- For the operator, and for whoever has to ring the vendor.
  last_error     text,
  error_detail   jsonb,

  started_at     timestamptz not null default now(),
  finished_at    timestamptz,
  triggered_by   uuid,

  constraint asr_id_dealer_key unique (id, dealer_id),
  constraint asr_status_check check (status in ('RUNNING', 'SUCCESS', 'PARTIAL', 'FAILED')),
  constraint asr_range_check  check (to_date >= from_date),
  constraint asr_counts_check check (
    fetched_count >= 0 and matched_count >= 0 and unmatched_count >= 0
    and written_count >= 0 and skipped_manual_count >= 0
  ),
  -- A finished run says how it finished.
  constraint asr_finished_check check (
    status = 'RUNNING' or finished_at is not null
  )
);

comment on table public.attendance_sync_runs is
  'One pull from the external attendance system (spec §40). Its counts are how '
  'anyone knows whether the mirror is complete, and unmatched_count is the one '
  'that means somebody''s pay will be wrong.';

create index asr_dealer_started_idx on public.attendance_sync_runs (dealer_id, started_at desc);
create index asr_status_idx on public.attendance_sync_runs (dealer_id, status);

-- -----------------------------------------------------------------------------
-- attendance_days — one row per employee per day
-- -----------------------------------------------------------------------------
create table public.attendance_days (
  id              uuid primary key default gen_random_uuid(),
  dealer_id       uuid not null references public.dealers (id) on delete restrict,
  branch_id       uuid not null,
  employee_id     uuid not null,

  attendance_date date not null,

  status          text not null,
  -- Null when the day was not worked. Times rather than timestamps: the day is
  -- already known, and a shift that crosses midnight is described by the shift.
  first_in        time,
  last_out        time,

  worked_minutes       integer not null default 0,
  late_minutes         integer not null default 0,
  early_exit_minutes   integer not null default 0,
  overtime_minutes     integer not null default 0,

  -- Set when status = 'LEAVE'. Payroll reads leave_types.is_paid through this
  -- to decide whether the day is paid.
  leave_type_id   uuid,

  -- SYNC rows are refreshed by the next pull; MANUAL rows are never overwritten.
  source          text not null default 'SYNC',
  -- The vendor's own id for the record, so a re-pull updates rather than doubles.
  external_ref    text,
  sync_run_id     uuid,

  remarks         text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  created_by      uuid,
  updated_by      uuid,

  -- One day, one row, one person. This is what makes a re-pull idempotent
  -- (spec §50) rather than a way to double someone's month.
  constraint ad_employee_date_key unique (employee_id, attendance_date),
  constraint ad_id_dealer_key unique (id, dealer_id),
  constraint ad_employee_tenant_fkey
    foreign key (employee_id, dealer_id) references public.employees (id, dealer_id) on delete cascade,
  constraint ad_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint ad_leave_type_tenant_fkey
    foreign key (leave_type_id, dealer_id) references public.leave_types (id, dealer_id),
  constraint ad_sync_run_tenant_fkey
    foreign key (sync_run_id, dealer_id) references public.attendance_sync_runs (id, dealer_id),

  constraint ad_status_check check (status in (
    'PRESENT', 'ABSENT', 'HALF_DAY', 'LEAVE', 'WEEK_OFF', 'HOLIDAY'
  )),
  constraint ad_source_check check (source in ('SYNC', 'MANUAL')),
  constraint ad_minutes_check check (
    worked_minutes between 0 and 1440
    and late_minutes >= 0 and early_exit_minutes >= 0 and overtime_minutes >= 0
  ),
  -- A leave day says which leave; anything else does not pretend to.
  constraint ad_leave_shape_check check (
    (status = 'LEAVE' and leave_type_id is not null)
    or (status <> 'LEAVE' and leave_type_id is null)
  ),
  -- A day nobody worked has no clock times to show.
  constraint ad_times_shape_check check (
    status in ('PRESENT', 'HALF_DAY') or (first_in is null and last_out is null)
  )
);

comment on table public.attendance_days is
  'The attendance mirror (spec §12, §40). The external system stays the source '
  'of truth for who clocked in; this is the copy payroll and the reports read, '
  'so neither depends on that system being reachable.';
comment on column public.attendance_days.source is
  'SYNC rows are refreshed by the next pull. MANUAL rows never are: someone who '
  'corrected a missed punch knew more than the device did.';

create index ad_employee_date_idx on public.attendance_days (employee_id, attendance_date desc);
create index ad_dealer_date_idx   on public.attendance_days (dealer_id, attendance_date desc);
create index ad_branch_date_idx   on public.attendance_days (branch_id, attendance_date desc);
create index ad_run_idx           on public.attendance_days (sync_run_id) where sync_run_id is not null;

create trigger attendance_days_set_updated_at before update on public.attendance_days
  for each row execute function app.set_updated_at();
create trigger attendance_days_audit after insert or update or delete on public.attendance_days
  for each row execute function app.audit_trigger();
create trigger attendance_sync_runs_audit after insert or update or delete on public.attendance_sync_runs
  for each row execute function app.audit_trigger();

-- -----------------------------------------------------------------------------
-- public.start_attendance_sync() — record the attempt before making it
-- -----------------------------------------------------------------------------
-- The row exists before the vendor is called, so a run that dies mid-flight
-- leaves a RUNNING row somebody can see rather than no evidence at all — the
-- same reason record_einvoice_request() writes before transmission (0048).
-- -----------------------------------------------------------------------------
create or replace function public.start_attendance_sync(
  p_from date,
  p_to   date
)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_run    uuid;
begin
  if v_dealer is null then
    raise exception 'No dealer in context.' using errcode = 'insufficient_privilege';
  end if;
  if p_to < p_from then
    raise exception 'The end of the range comes before its start.'
      using errcode = 'check_violation';
  end if;
  -- A year at a time is already generous; an unbounded range is how a sync
  -- becomes a denial of service against the vendor and against this database.
  if p_to - p_from > 366 then
    raise exception 'Sync at most a year at a time.' using errcode = 'check_violation';
  end if;

  insert into public.attendance_sync_runs (dealer_id, from_date, to_date, triggered_by)
  values (v_dealer, p_from, p_to, auth.uid())
  returning id into v_run;

  return v_run;
end;
$$;

comment on function public.start_attendance_sync(date, date) is
  'Opens a sync run before the external system is called (spec §40), so a run '
  'that fails mid-flight leaves evidence rather than silence.';

-- -----------------------------------------------------------------------------
-- public.import_attendance_days() — the mirror is written here, not by the client
-- -----------------------------------------------------------------------------
-- Takes what the vendor returned, already normalised by the client, as:
--
--   [{"external_ref": "E-4417", "date": "2026-09-01", "status": "PRESENT",
--     "first_in": "09:28", "last_out": "18:35", "worked_minutes": 487,
--     "late_minutes": 0, "record_ref": "att_99182"}, …]
--
-- Matching by external_ref only — never by name, and never by a fuzzy guess. An
-- unmatched row is counted and skipped, because attributing one person's
-- attendance to another is worse than a gap somebody can see and fix.
-- -----------------------------------------------------------------------------
create or replace function public.import_attendance_days(
  p_run_id uuid,
  p_rows   jsonb
)
returns table (
  matched        integer,
  unmatched      integer,
  written        integer,
  skipped_manual integer
)
language plpgsql
as $$
declare
  v_run       public.attendance_sync_runs;
  v_row       jsonb;
  v_emp       record;
  v_matched   integer := 0;
  v_unmatched integer := 0;
  v_written   integer := 0;
  v_skipped   integer := 0;
  v_status    text;
  v_date      date;
  v_leave     uuid;
begin
  select * into v_run from public.attendance_sync_runs where id = p_run_id for update;
  if v_run.id is null then
    raise exception 'Sync run not found.' using errcode = 'no_data_found';
  end if;
  if v_run.status <> 'RUNNING' then
    raise exception 'Sync run % has already finished.', p_run_id using errcode = 'check_violation';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'Attendance rows must be a list.' using errcode = 'invalid_parameter_value';
  end if;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_date := (v_row ->> 'date')::date;

    -- Outside the window the run declared is a vendor bug, not data: importing
    -- it would put rows into a month nobody asked to re-sync.
    continue when v_date is null or v_date < v_run.from_date or v_date > v_run.to_date;

    select e.id, e.branch_id, e.dealer_id
      into v_emp
      from public.employees e
     where e.dealer_id = v_run.dealer_id
       and e.external_ref = (v_row ->> 'external_ref');

    if not found then
      v_unmatched := v_unmatched + 1;
      continue;
    end if;

    v_matched := v_matched + 1;

    -- A day someone corrected by hand outranks the device.
    if exists (
      select 1 from public.attendance_days d
       where d.employee_id = v_emp.id
         and d.attendance_date = v_date
         and d.source = 'MANUAL'
    ) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    v_status := coalesce(upper(v_row ->> 'status'), 'ABSENT');
    if v_status not in ('PRESENT', 'ABSENT', 'HALF_DAY', 'LEAVE', 'WEEK_OFF', 'HOLIDAY') then
      v_status := 'ABSENT';
    end if;

    -- Leave arrives as the vendor's own code; it is only usable if this dealer
    -- has a leave type with that code. Otherwise the day is still recorded —
    -- just not as leave, because an unmapped leave type would fail the shape
    -- constraint and lose the whole day.
    v_leave := null;
    if v_status = 'LEAVE' then
      select lt.id into v_leave
        from public.leave_types lt
       where lt.dealer_id = v_run.dealer_id
         and lt.code = upper(coalesce(v_row ->> 'leave_code', ''));
      if v_leave is null then
        v_status := 'ABSENT';
      end if;
    end if;

    insert into public.attendance_days
      (dealer_id, branch_id, employee_id, attendance_date, status,
       first_in, last_out, worked_minutes, late_minutes, early_exit_minutes,
       overtime_minutes, leave_type_id, source, external_ref, sync_run_id,
       remarks, created_by)
    values
      (v_run.dealer_id, v_emp.branch_id, v_emp.id, v_date, v_status,
       case when v_status in ('PRESENT', 'HALF_DAY') then (v_row ->> 'first_in')::time end,
       case when v_status in ('PRESENT', 'HALF_DAY') then (v_row ->> 'last_out')::time end,
       greatest(coalesce((v_row ->> 'worked_minutes')::integer, 0), 0),
       greatest(coalesce((v_row ->> 'late_minutes')::integer, 0), 0),
       greatest(coalesce((v_row ->> 'early_exit_minutes')::integer, 0), 0),
       greatest(coalesce((v_row ->> 'overtime_minutes')::integer, 0), 0),
       v_leave, 'SYNC', v_row ->> 'record_ref', p_run_id,
       v_row ->> 'remarks', auth.uid())
    on conflict (employee_id, attendance_date) do update
      set status             = excluded.status,
          first_in           = excluded.first_in,
          last_out           = excluded.last_out,
          worked_minutes     = excluded.worked_minutes,
          late_minutes       = excluded.late_minutes,
          early_exit_minutes = excluded.early_exit_minutes,
          overtime_minutes   = excluded.overtime_minutes,
          leave_type_id      = excluded.leave_type_id,
          external_ref       = excluded.external_ref,
          sync_run_id        = excluded.sync_run_id,
          remarks            = excluded.remarks,
          updated_by         = auth.uid();

    v_written := v_written + 1;
  end loop;

  update public.attendance_sync_runs
     set fetched_count        = fetched_count + jsonb_array_length(p_rows),
         matched_count        = matched_count + v_matched,
         unmatched_count      = unmatched_count + v_unmatched,
         written_count        = written_count + v_written,
         skipped_manual_count = skipped_manual_count + v_skipped
   where id = p_run_id;

  matched := v_matched; unmatched := v_unmatched;
  written := v_written; skipped_manual := v_skipped;
  return next;
end;
$$;

comment on function public.import_attendance_days(uuid, jsonb) is
  'Writes a batch of external attendance into the mirror (spec §40, §50). '
  'Matches on external_ref only; a manually corrected day is never overwritten.';

-- -----------------------------------------------------------------------------
-- public.finish_attendance_sync() — close the run, however it ended
-- -----------------------------------------------------------------------------
create or replace function public.finish_attendance_sync(
  p_run_id uuid,
  p_status text,
  p_error  text default null,
  p_detail jsonb default null
)
returns void
language plpgsql
as $$
begin
  if p_status not in ('SUCCESS', 'PARTIAL', 'FAILED') then
    raise exception 'A sync ends SUCCESS, PARTIAL or FAILED; got %.', p_status
      using errcode = 'check_violation';
  end if;

  update public.attendance_sync_runs
     set status       = p_status,
         last_error   = p_error,
         error_detail = p_detail,
         finished_at  = now()
   where id = p_run_id and status = 'RUNNING';
end;
$$;

comment on function public.finish_attendance_sync(uuid, text, text, jsonb) is
  'Closes a sync run. A vendor failure ends the run FAILED and changes nothing '
  'that was already mirrored (spec §40).';

-- -----------------------------------------------------------------------------
-- public.attendance_summary() — days worked, for payroll and the register
-- -----------------------------------------------------------------------------
-- The one place that turns days into the figures payroll needs, so the payslip
-- and the register on screen can never disagree about a month.
--
-- Paid leave counts as worked when the leave type says so, which is what
-- leave_types.counts_as_worked was added for in 0053.
-- -----------------------------------------------------------------------------
create or replace function public.attendance_summary(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  employee_id     uuid,
  employee_code   text,
  employee_name   text,
  branch_name     text,
  present_days    numeric(6, 2),
  leave_days      numeric(6, 2),
  paid_leave_days numeric(6, 2),
  absent_days     integer,
  week_off_days   integer,
  holiday_days    integer,
  payable_days    numeric(6, 2),
  late_count      integer,
  overtime_minutes integer,
  recorded_days   integer
)
language sql
stable
as $$
  select e.id, e.employee_code, e.name, b.name,
         coalesce(sum(case d.status when 'PRESENT' then 1 when 'HALF_DAY' then 0.5 else 0 end), 0),
         coalesce(sum(case when d.status = 'LEAVE' then 1 else 0 end), 0),
         coalesce(sum(case when d.status = 'LEAVE' and lt.is_paid then 1 else 0 end), 0),
         coalesce(sum(case when d.status = 'ABSENT' then 1 else 0 end), 0)::integer,
         coalesce(sum(case when d.status = 'WEEK_OFF' then 1 else 0 end), 0)::integer,
         coalesce(sum(case when d.status = 'HOLIDAY' then 1 else 0 end), 0)::integer,
         -- What payroll pays for: days worked, plus leave the dealer said counts,
         -- plus the week offs and holidays a monthly salary already covers.
         coalesce(sum(
           case d.status
             when 'PRESENT'  then 1
             when 'HALF_DAY' then 0.5
             when 'WEEK_OFF' then 1
             when 'HOLIDAY'  then 1
             when 'LEAVE'    then case when lt.counts_as_worked then 1 else 0 end
             else 0
           end), 0),
         coalesce(sum(case when d.late_minutes > 0 then 1 else 0 end), 0)::integer,
         coalesce(sum(d.overtime_minutes), 0)::integer,
         count(d.id)::integer
    from public.employees e
    join public.branches b on b.id = e.branch_id
    left join public.attendance_days d
           on d.employee_id = e.id
          and d.attendance_date between p_from and p_to
    left join public.leave_types lt on lt.id = d.leave_type_id
   where e.status in ('ACTIVE', 'ON_LEAVE')
     and (p_branch_id is null or e.branch_id = p_branch_id)
   group by e.id, e.employee_code, e.name, b.name
   order by e.employee_code;
$$;

comment on function public.attendance_summary(date, date, uuid) is
  'Days worked, on leave and payable for a period (spec §12). The one place '
  'that turns days into what payroll pays for, so nothing can disagree with it.';

-- -----------------------------------------------------------------------------
-- Row Level Security
-- -----------------------------------------------------------------------------
alter table public.attendance_days      enable row level security;
alter table public.attendance_sync_runs enable row level security;

create policy attendance_days_select on public.attendance_days
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and (
          (app.can_access_branch(branch_id) and app.has_permission('hr.attendance.view'))
          -- Everyone may see their own register, which is the record they are
          -- most entitled to and most likely to spot a mistake in.
          or exists (
            select 1 from public.employees e
             where e.id = attendance_days.employee_id and e.user_id = auth.uid()
          )
        ))
  );

create policy attendance_days_write on public.attendance_days
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and (app.has_permission('hr.attendance.edit') or app.has_permission('hr.attendance.sync')))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and (app.has_permission('hr.attendance.edit') or app.has_permission('hr.attendance.sync')))
  );

create policy attendance_sync_runs_select on public.attendance_sync_runs
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('hr.attendance.view'))
  );

create policy attendance_sync_runs_write on public.attendance_sync_runs
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('hr.attendance.sync'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('hr.attendance.sync'))
  );

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update, delete on public.attendance_days to authenticated';
    execute 'grant select, insert, update, delete on public.attendance_sync_runs to authenticated';
    execute 'grant all on public.attendance_days to service_role';
    execute 'grant all on public.attendance_sync_runs to service_role';
    execute 'grant execute on function public.start_attendance_sync(date, date) to authenticated';
    execute 'grant execute on function public.import_attendance_days(uuid, jsonb) to authenticated';
    execute 'grant execute on function public.finish_attendance_sync(uuid, text, text, jsonb) to authenticated';
    execute 'grant execute on function public.attendance_summary(date, date, uuid) to authenticated';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Permissions
-- -----------------------------------------------------------------------------
insert into public.permissions (code, module, description, is_sensitive) values
  ('hr.attendance.view', 'hr', 'View the attendance register',                    false),
  ('hr.attendance.sync', 'hr', 'Pull attendance from the external system',        false),
  ('hr.attendance.edit', 'hr', 'Correct an attendance day by hand',               false),
  ('hr.mapping.manage',  'hr', 'Map employees to the external attendance system', false)
on conflict (code) do update
  set module      = excluded.module,
      description = excluded.description;

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join (values
    ('hr.attendance.view'), ('hr.attendance.sync'), ('hr.attendance.edit'), ('hr.mapping.manage')
  ) as p(code)
 where r.is_system and r.code in ('DEALER_OWNER', 'ACCOUNTS')
on conflict do nothing;


commit;
