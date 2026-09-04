-- =============================================================================
-- 0053 — HR foundations: the employee record an ERP actually needs
-- =============================================================================
-- Spec §4, §5, §12, §15, §46, §47, §52, §60.7, §60.19.
--
-- public.employees (0003) is an identity and little else: a code, a name, a
-- department, a designation, a mobile and two dates. That is enough to attribute
-- a sale to a salesman, which is all it has ever been asked to do.
--
-- It is not enough to run HR. There is nowhere to record what someone is paid,
-- which shift they work, what leave they are entitled to, or which documents the
-- dealer holds for them — so Attendance has nothing to measure against and
-- Payroll has nothing to compute from. This migration is the record those two
-- modules will stand on, and it is deliberately built first for that reason.
--
-- ── What is added ───────────────────────────────────────────────────────────
--
--   employees                     gains the personal, statutory and employment
--                                 fields an HR record needs
--   shifts                        working patterns, dealer-scoped
--   leave_types                   CL / SL / EL / LOP, with quotas
--   employee_salary_structures    effective-dated pay, never overwritten
--   employee_leave_balances       entitlement and what is left of it
--   employee_documents            what the dealer holds, and when it expires
--
-- ── Pay is effective-dated, not edited ──────────────────────────────────────
--
-- Salary follows the pattern vehicle prices use (spec §15, §60.9): a revision is
-- a new row with its own effective_from, and the old one stays exactly as it
-- was. A payslip run for March next year must reproduce March's figures, which
-- is impossible if a July increment overwrote them. The same reason invoices do
-- not change when a price list does.
--
-- ── Pay is confidential ─────────────────────────────────────────────────────
--
-- Spec §52 requires restricted financial fields to be absent from the API
-- response, not merely hidden by the UI. Salary is exactly that kind of field —
-- more so than margin, because it is personal data about a colleague. It gets
-- its own permission, its own RLS policy, and an entry in the redaction map on
-- the way out (src/lib/permissions/index.ts).
--
-- Rollback: drop table public.employee_documents, public.employee_leave_balances,
--           public.employee_salary_structures, public.leave_types, public.shifts;
--           alter table public.employees drop column ... (the columns added below);
--           delete from public.permissions where module = 'hr';
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The employee record grows up
-- -----------------------------------------------------------------------------
-- Added to the existing table rather than kept in a satellite: every one of
-- these is one-to-one with the employee and is read whenever the employee is.
-- A join table here would buy nothing and cost a join on every screen.
-- -----------------------------------------------------------------------------
alter table public.employees
  add column if not exists date_of_birth     date,
  add column if not exists gender            text,
  add column if not exists blood_group       text,
  add column if not exists personal_email    text,
  add column if not exists emergency_contact text,
  add column if not exists emergency_mobile  text,

  add column if not exists address_line1     text,
  add column if not exists address_line2     text,
  add column if not exists city              text,
  add column if not exists state             text,
  add column if not exists pincode           text,

  -- Statutory identifiers. Held because payroll and PF/ESI filing need them.
  add column if not exists pan               text,
  add column if not exists aadhaar_last4     text,
  add column if not exists uan               text,
  add column if not exists esi_number        text,

  -- Where salary is paid. The account number is the dealer's own record of it.
  add column if not exists bank_account_name text,
  add column if not exists bank_account_no   text,
  add column if not exists bank_ifsc         text,

  add column if not exists employment_type   text not null default 'PERMANENT',
  add column if not exists probation_until   date,
  add column if not exists confirmed_on      date,
  add column if not exists exit_type         text,
  add column if not exists exit_reason       text,

  add column if not exists reports_to        uuid,
  add column if not exists shift_id          uuid;

comment on column public.employees.aadhaar_last4 is
  'Last four digits only. The full number is not the dealer''s to keep, and a '
  'partial one is enough to confirm a document already sighted.';

alter table public.employees
  add constraint employees_gender_check check (
    gender is null or gender in ('MALE', 'FEMALE', 'OTHER')
  ),
  add constraint employees_employment_type_check check (
    employment_type in ('PERMANENT', 'PROBATION', 'CONTRACT', 'INTERN', 'CONSULTANT')
  ),
  add constraint employees_exit_type_check check (
    exit_type is null or exit_type in ('RESIGNATION', 'TERMINATION', 'RETIREMENT', 'END_OF_CONTRACT', 'ABSCONDED')
  ),
  add constraint employees_pan_check check (pan is null or pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  add constraint employees_aadhaar_last4_check check (aadhaar_last4 is null or aadhaar_last4 ~ '^[0-9]{4}$'),
  add constraint employees_uan_check check (uan is null or uan ~ '^[0-9]{12}$'),
  add constraint employees_ifsc_check check (bank_ifsc is null or bank_ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$'),
  add constraint employees_pincode_check check (pincode is null or pincode ~ '^[1-9][0-9]{5}$'),
  add constraint employees_emergency_mobile_check check (
    emergency_mobile is null or emergency_mobile ~ '^[6-9][0-9]{9}$'
  ),
  -- Someone who has left must say how, so an exit report is not guesswork.
  add constraint employees_exit_shape_check check (
    status not in ('RESIGNED', 'TERMINATED') or exit_type is not null
  ),
  -- Nobody reports to themselves.
  add constraint employees_reports_to_check check (reports_to is null or reports_to <> id),
  add constraint employees_reports_to_tenant_fkey
    foreign key (reports_to, dealer_id) references public.employees (id, dealer_id);

create index employees_reports_to_idx on public.employees (reports_to) where reports_to is not null;

-- -----------------------------------------------------------------------------
-- shifts — the working pattern a day is measured against
-- -----------------------------------------------------------------------------
-- Dealer-scoped, not branch-scoped: a showroom and a workshop in the same
-- dealership run different shifts, but the pattern itself is defined once and
-- assigned per employee.
-- -----------------------------------------------------------------------------
create table public.shifts (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null references public.dealers (id) on delete restrict,

  code           text not null,
  name           text not null,

  starts_at      time not null,
  ends_at        time not null,
  break_minutes  smallint not null default 0,

  -- Minutes after starts_at that are still "on time". Without it every employee
  -- who arrives at 09:00:30 is late, and the register becomes noise.
  grace_minutes  smallint not null default 0,

  -- ISO weekday numbers that are off: 1 = Monday … 7 = Sunday.
  week_off_days  smallint[] not null default '{7}',

  -- Below this, the day counts as absent; below full_day_minutes, a half day.
  half_day_minutes smallint not null default 240,
  full_day_minutes smallint not null default 480,

  status         text not null default 'ACTIVE',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid,
  updated_by     uuid,

  constraint shifts_dealer_code_key unique (dealer_id, code),
  constraint shifts_id_dealer_key   unique (id, dealer_id),
  constraint shifts_status_check    check (status in ('ACTIVE', 'INACTIVE')),
  constraint shifts_code_check      check (code ~ '^[A-Z0-9_-]{1,20}$'),
  constraint shifts_break_check     check (break_minutes between 0 and 480),
  constraint shifts_grace_check     check (grace_minutes between 0 and 120),
  constraint shifts_minutes_check   check (
    half_day_minutes > 0 and full_day_minutes > half_day_minutes and full_day_minutes <= 1440
  ),
  -- A shift may cross midnight, so ends_at < starts_at is legitimate; what is
  -- not legitimate is a shift of no length at all.
  constraint shifts_span_check      check (ends_at <> starts_at),
  constraint shifts_week_off_check  check (
    week_off_days <@ array[1,2,3,4,5,6,7]::smallint[]
  )
);

comment on table public.shifts is
  'Working patterns (spec §12). Attendance measures a day against the employee''s '
  'shift; a day with no shift has nothing to be late for.';

create index shifts_dealer_status_idx on public.shifts (dealer_id, status);

alter table public.employees
  add constraint employees_shift_tenant_fkey
  foreign key (shift_id, dealer_id) references public.shifts (id, dealer_id);

create index employees_shift_idx on public.employees (shift_id) where shift_id is not null;

-- -----------------------------------------------------------------------------
-- leave_types — what leave exists, and how much of it
-- -----------------------------------------------------------------------------
create table public.leave_types (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null references public.dealers (id) on delete restrict,

  code              text not null,
  name              text not null,

  annual_quota      numeric(6, 2) not null default 0,
  -- Unpaid leave still has to be recorded: payroll needs to know the day was
  -- taken in order to deduct it.
  is_paid           boolean not null default true,
  carry_forward     boolean not null default false,
  max_carry_forward numeric(6, 2) not null default 0,
  -- Whether a day of this leave counts as a day worked for payroll.
  counts_as_worked  boolean not null default true,

  status            text not null default 'ACTIVE',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid,
  updated_by        uuid,

  constraint leave_types_dealer_code_key unique (dealer_id, code),
  constraint leave_types_id_dealer_key   unique (id, dealer_id),
  constraint leave_types_code_check      check (code ~ '^[A-Z0-9_-]{1,20}$'),
  constraint leave_types_status_check    check (status in ('ACTIVE', 'INACTIVE')),
  constraint leave_types_quota_check     check (annual_quota >= 0 and max_carry_forward >= 0),
  constraint leave_types_carry_check     check (
    carry_forward or max_carry_forward = 0
  )
);

comment on table public.leave_types is
  'Leave a dealer grants (spec §12). is_paid and counts_as_worked are what '
  'payroll reads: loss of pay is still leave, it simply is not paid.';

create index leave_types_dealer_status_idx on public.leave_types (dealer_id, status);

-- -----------------------------------------------------------------------------
-- employee_salary_structures — effective-dated pay
-- -----------------------------------------------------------------------------
-- A revision is a new row, never an edit (spec §15, §60.9). The March payslip
-- has to reproduce March's figures however many increments have happened since,
-- exactly as an invoice keeps the price it was raised at.
-- -----------------------------------------------------------------------------
create table public.employee_salary_structures (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null references public.dealers (id) on delete restrict,
  employee_id       uuid not null,

  effective_from    date not null,
  -- Closed by the next revision. Null means "current".
  effective_to      date,

  -- Earnings, monthly.
  basic             numeric(14, 2) not null default 0,
  hra               numeric(14, 2) not null default 0,
  conveyance        numeric(14, 2) not null default 0,
  medical_allowance numeric(14, 2) not null default 0,
  special_allowance numeric(14, 2) not null default 0,
  other_allowance   numeric(14, 2) not null default 0,

  -- Statutory deductions, monthly.
  pf_employee       numeric(14, 2) not null default 0,
  esi_employee      numeric(14, 2) not null default 0,
  professional_tax  numeric(14, 2) not null default 0,
  other_deduction   numeric(14, 2) not null default 0,

  -- Employer contributions: a cost to the dealer, not a deduction from the
  -- employee, so they are kept apart from the two columns above.
  pf_employer       numeric(14, 2) not null default 0,
  esi_employer      numeric(14, 2) not null default 0,

  -- Derived, so a stored figure can never disagree with the parts it came from.
  gross_earnings    numeric(14, 2) generated always as (
    basic + hra + conveyance + medical_allowance + special_allowance + other_allowance
  ) stored,
  total_deductions  numeric(14, 2) generated always as (
    pf_employee + esi_employee + professional_tax + other_deduction
  ) stored,
  net_payable       numeric(14, 2) generated always as (
    basic + hra + conveyance + medical_allowance + special_allowance + other_allowance
    - pf_employee - esi_employee - professional_tax - other_deduction
  ) stored,
  cost_to_company   numeric(14, 2) generated always as (
    basic + hra + conveyance + medical_allowance + special_allowance + other_allowance
    + pf_employer + esi_employer
  ) stored,

  revision_note     text,
  created_at        timestamptz not null default now(),
  created_by        uuid,

  constraint ess_employee_from_key unique (employee_id, effective_from),
  constraint ess_id_dealer_key     unique (id, dealer_id),
  constraint ess_employee_tenant_fkey
    foreign key (employee_id, dealer_id) references public.employees (id, dealer_id) on delete cascade,
  constraint ess_amounts_check check (
    basic >= 0 and hra >= 0 and conveyance >= 0 and medical_allowance >= 0
    and special_allowance >= 0 and other_allowance >= 0
    and pf_employee >= 0 and esi_employee >= 0 and professional_tax >= 0
    and other_deduction >= 0 and pf_employer >= 0 and esi_employer >= 0
  ),
  constraint ess_range_check check (effective_to is null or effective_to >= effective_from),
  -- Nobody works for a negative wage; if deductions exceed earnings the
  -- structure is wrong, and finding out at payroll time is too late.
  constraint ess_net_check check (
    basic + hra + conveyance + medical_allowance + special_allowance + other_allowance
    >= pf_employee + esi_employee + professional_tax + other_deduction
  )
);

comment on table public.employee_salary_structures is
  'Effective-dated pay (spec §15). A revision is a new row; the old one is never '
  'edited, so a payslip re-run for a past month reproduces that month exactly.';

create index ess_employee_idx on public.employee_salary_structures (employee_id, effective_from desc);
create index ess_dealer_idx   on public.employee_salary_structures (dealer_id, effective_from desc);

-- -----------------------------------------------------------------------------
-- employee_leave_balances — entitlement, and what is left of it
-- -----------------------------------------------------------------------------
-- One row per employee, leave type and year. `used` is maintained by the
-- Attendance module when leave is approved; it is a column here rather than a
-- count over leave applications so a balance check is one lookup rather than an
-- aggregate over a growing table.
-- -----------------------------------------------------------------------------
create table public.employee_leave_balances (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null references public.dealers (id) on delete restrict,
  employee_id    uuid not null,
  leave_type_id  uuid not null,

  -- Financial year, as the token app.financial_year_token() issues.
  financial_year text not null,

  opening        numeric(6, 2) not null default 0,
  accrued        numeric(6, 2) not null default 0,
  used           numeric(6, 2) not null default 0,
  encashed       numeric(6, 2) not null default 0,

  balance        numeric(6, 2) generated always as (opening + accrued - used - encashed) stored,

  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid,
  updated_by     uuid,

  constraint elb_employee_type_year_key unique (employee_id, leave_type_id, financial_year),
  constraint elb_id_dealer_key unique (id, dealer_id),
  constraint elb_employee_tenant_fkey
    foreign key (employee_id, dealer_id) references public.employees (id, dealer_id) on delete cascade,
  constraint elb_type_tenant_fkey
    foreign key (leave_type_id, dealer_id) references public.leave_types (id, dealer_id),
  constraint elb_amounts_check check (
    opening >= 0 and accrued >= 0 and used >= 0 and encashed >= 0
  ),
  constraint elb_year_check check (financial_year ~ '^[0-9]{4}$')
);

comment on table public.employee_leave_balances is
  'Leave entitlement per employee, type and year (spec §12). `used` is written '
  'by leave approval in the Attendance module; `balance` is derived from the parts.';

create index elb_employee_idx on public.employee_leave_balances (employee_id, financial_year);
create index elb_dealer_year_idx on public.employee_leave_balances (dealer_id, financial_year);

-- -----------------------------------------------------------------------------
-- employee_documents — what the dealer holds, and when it runs out
-- -----------------------------------------------------------------------------
-- The file itself lives in Supabase Storage; this is the record of it. Expiry is
-- the column that earns the table: a driving licence or a work permit that has
-- lapsed is a liability nobody notices until someone looks.
-- -----------------------------------------------------------------------------
create table public.employee_documents (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null references public.dealers (id) on delete restrict,
  employee_id    uuid not null,

  document_type  text not null,
  document_name  text not null,
  document_no    text,

  issued_on      date,
  expires_on     date,

  -- Object path in Supabase Storage. Never a public URL (spec §47).
  storage_path   text,

  notes          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid,
  updated_by     uuid,

  constraint ed_id_dealer_key unique (id, dealer_id),
  constraint ed_employee_tenant_fkey
    foreign key (employee_id, dealer_id) references public.employees (id, dealer_id) on delete cascade,
  constraint ed_type_check check (document_type in (
    'AADHAAR', 'PAN', 'PASSPORT', 'DRIVING_LICENCE', 'OFFER_LETTER', 'CONTRACT',
    'EDUCATION', 'EXPERIENCE', 'BANK_PROOF', 'ADDRESS_PROOF', 'PHOTO', 'OTHER'
  )),
  constraint ed_dates_check check (expires_on is null or issued_on is null or expires_on >= issued_on),
  constraint ed_name_check check (length(btrim(document_name)) between 1 and 150)
);

comment on table public.employee_documents is
  'Documents held for an employee (spec §46, §47). The file is in Storage; this '
  'is the register, and expires_on is what makes it worth keeping.';

create index ed_employee_idx on public.employee_documents (employee_id);
create index ed_expiry_idx on public.employee_documents (dealer_id, expires_on)
  where expires_on is not null;

-- -----------------------------------------------------------------------------
-- A salary revision closes the one before it
-- -----------------------------------------------------------------------------
-- Kept by trigger rather than asked of the caller: "the previous structure ends
-- the day before this one starts" is a fact about the data, and a caller who
-- forgets it leaves two structures live on the same date with no way to say
-- which one a payslip should use.
-- -----------------------------------------------------------------------------
create or replace function app.salary_structures_close_previous()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.employee_salary_structures
     set effective_to = new.effective_from - 1
   where employee_id = new.employee_id
     and id <> new.id
     and effective_from < new.effective_from
     and (effective_to is null or effective_to >= new.effective_from);

  -- A revision dated before an existing one is a correction to history, which
  -- payroll cannot represent: the month it would change may already be paid.
  if exists (
    select 1 from public.employee_salary_structures
     where employee_id = new.employee_id
       and id <> new.id
       and effective_from > new.effective_from
  ) then
    raise exception
      'A later salary structure already exists for this employee. Add the revision after it, not before.'
      using errcode = 'check_violation',
            hint = 'Spec §15: effective-dated records are appended, never back-dated over.';
  end if;

  return new;
end;
$$;

create trigger salary_structures_close_previous
  after insert on public.employee_salary_structures
  for each row execute function app.salary_structures_close_previous();

-- -----------------------------------------------------------------------------
-- public.employee_salary_on() — what someone was paid on a given date
-- -----------------------------------------------------------------------------
-- The one place that answers "which structure applies", so payroll, a payslip
-- re-run and the screen can never pick different ones.
-- -----------------------------------------------------------------------------
create or replace function public.employee_salary_on(
  p_employee_id uuid,
  p_as_on       date default current_date
)
returns uuid
language sql
stable
as $$
  select s.id
    from public.employee_salary_structures s
   where s.employee_id = p_employee_id
     and s.effective_from <= p_as_on
     and (s.effective_to is null or s.effective_to >= p_as_on)
   order by s.effective_from desc
   limit 1;
$$;

comment on function public.employee_salary_on(uuid, date) is
  'The salary structure in force for an employee on a date (spec §15, §42). One '
  'answer, so a payslip and the screen behind it cannot disagree.';

create trigger shifts_set_updated_at before update on public.shifts
  for each row execute function app.set_updated_at();
create trigger leave_types_set_updated_at before update on public.leave_types
  for each row execute function app.set_updated_at();
create trigger elb_set_updated_at before update on public.employee_leave_balances
  for each row execute function app.set_updated_at();
create trigger ed_set_updated_at before update on public.employee_documents
  for each row execute function app.set_updated_at();

-- Salary is personal data about a colleague; every touch of it is logged (§46).
create trigger shifts_audit after insert or update or delete on public.shifts
  for each row execute function app.audit_trigger();
create trigger leave_types_audit after insert or update or delete on public.leave_types
  for each row execute function app.audit_trigger();
create trigger ess_audit after insert or update or delete on public.employee_salary_structures
  for each row execute function app.audit_trigger();
create trigger elb_audit after insert or update or delete on public.employee_leave_balances
  for each row execute function app.audit_trigger();
create trigger ed_audit after insert or update or delete on public.employee_documents
  for each row execute function app.audit_trigger();

-- -----------------------------------------------------------------------------
-- Row Level Security
-- -----------------------------------------------------------------------------
-- Shifts and leave types are configuration: anyone who may see the employee
-- master may read them. Salary and documents are not — they carry personal data
-- and get permissions of their own, so a branch manager who may see the roster
-- does not thereby see what everyone is paid (spec §47, §52).
-- -----------------------------------------------------------------------------
alter table public.shifts                     enable row level security;
alter table public.leave_types                enable row level security;
alter table public.employee_salary_structures enable row level security;
alter table public.employee_leave_balances    enable row level security;
alter table public.employee_documents         enable row level security;

create policy shifts_select on public.shifts
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('masters.employees.view'))
  );

create policy shifts_write on public.shifts
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('hr.settings.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('hr.settings.manage'))
  );

create policy leave_types_select on public.leave_types
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('masters.employees.view'))
  );

create policy leave_types_write on public.leave_types
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('hr.settings.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('hr.settings.manage'))
  );

-- Salary: the permission, or your own. An employee linked to a login may read
-- their own structure and nobody else's — the row is about them.
create policy salary_structures_select on public.employee_salary_structures
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and (app.has_permission('hr.salary.view')
             or exists (
               select 1 from public.employees e
                where e.id = employee_salary_structures.employee_id
                  and e.user_id = auth.uid()
             )))
  );

create policy salary_structures_write on public.employee_salary_structures
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('hr.salary.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('hr.salary.manage'))
  );

create policy leave_balances_select on public.employee_leave_balances
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and (app.has_permission('hr.leave.view')
             or exists (
               select 1 from public.employees e
                where e.id = employee_leave_balances.employee_id
                  and e.user_id = auth.uid()
             )))
  );

create policy leave_balances_write on public.employee_leave_balances
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('hr.leave.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('hr.leave.manage'))
  );

create policy employee_documents_select on public.employee_documents
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and (app.has_permission('hr.documents.view')
             or exists (
               select 1 from public.employees e
                where e.id = employee_documents.employee_id
                  and e.user_id = auth.uid()
             )))
  );

create policy employee_documents_write on public.employee_documents
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('hr.documents.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('hr.documents.manage'))
  );

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update, delete on public.shifts to authenticated';
    execute 'grant select, insert, update, delete on public.leave_types to authenticated';
    execute 'grant select, insert, update, delete on public.employee_salary_structures to authenticated';
    execute 'grant select, insert, update, delete on public.employee_leave_balances to authenticated';
    execute 'grant select, insert, update, delete on public.employee_documents to authenticated';
    execute 'grant all on public.shifts to service_role';
    execute 'grant all on public.leave_types to service_role';
    execute 'grant all on public.employee_salary_structures to service_role';
    execute 'grant all on public.employee_leave_balances to service_role';
    execute 'grant all on public.employee_documents to service_role';
    execute 'grant execute on function public.employee_salary_on(uuid, date) to authenticated';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Permissions
-- -----------------------------------------------------------------------------
-- hr.salary.view is marked sensitive: spec §52 requires such fields to be absent
-- from the API response, not merely hidden, and src/lib/permissions/index.ts
-- strips them on the way out.
--
-- Granted to DEALER_OWNER only. Accounts is deliberately NOT given salary by
-- default — a dealership's accountant is usually also an employee, and "can see
-- the ledger" is not the same decision as "can see what colleagues earn". A
-- dealer who wants it can grant it; the reverse, discovering it was on all
-- along, is not recoverable.
-- -----------------------------------------------------------------------------
insert into public.permissions (code, module, description, is_sensitive) values
  ('hr.settings.manage',  'hr', 'Manage shifts and leave types',            false),
  ('hr.salary.view',      'hr', 'View employee salary structures',          true),
  ('hr.salary.manage',    'hr', 'Set and revise employee salary structures', true),
  ('hr.leave.view',       'hr', 'View employee leave balances',             false),
  ('hr.leave.manage',     'hr', 'Set and adjust leave balances',            false),
  ('hr.documents.view',   'hr', 'View employee documents',                  false),
  ('hr.documents.manage', 'hr', 'Upload and manage employee documents',     false)
on conflict (code) do update
  set module        = excluded.module,
      description   = excluded.description,
      is_sensitive  = excluded.is_sensitive;

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join (values
    ('hr.settings.manage'), ('hr.salary.view'), ('hr.salary.manage'),
    ('hr.leave.view'), ('hr.leave.manage'),
    ('hr.documents.view'), ('hr.documents.manage')
  ) as p(code)
 where r.is_system and r.code = 'DEALER_OWNER'
on conflict do nothing;

-- Accounts runs the roster and the paperwork, but not the pay scale.
insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join (values
    ('hr.settings.manage'), ('hr.leave.view'), ('hr.leave.manage'),
    ('hr.documents.view'), ('hr.documents.manage')
  ) as p(code)
 where r.is_system and r.code = 'ACCOUNTS'
on conflict do nothing;
