-- =============================================================================
-- ALL-IN-ONE.sql — every migration and seed, concatenated in order
-- =============================================================================
-- GENERATED FILE. Do not edit; edit the sources and regenerate with
--   bash scripts/build-all-in-one.sh
--
-- For pasting into the Supabase SQL Editor in a single run instead of applying
-- the migrations one file at a time. Wrapped in one transaction: if any statement
-- fails, the whole thing rolls back and the database is left untouched — you will
-- never end up with a half-applied schema.
--
-- Run once, on an empty project. Re-running fails on the first CREATE TABLE,
-- which is the intended signal that there is nothing to do.
--
-- This is the production bundle: schema, permission catalogue and system roles,
-- and no demo data. For an evaluation database that comes with a dealer, three
-- branches and a populated ledger, use ALL-IN-ONE-WITH-DEMO.sql.
-- =============================================================================

begin;



-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0001_extensions_and_app_schema.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0001 — Foundations: app schema, shared trigger helpers
-- =============================================================================
-- Purpose: create the `app` schema that holds every helper function used by RLS
--          policies and triggers, plus the two triggers every table reuses.
--
-- Deliberately NO extensions. `gen_random_uuid()` is core PostgreSQL since 13,
-- and case-insensitive text is handled with `lower()` unique indexes rather than
-- citext. This keeps migrations portable and verifiable against vanilla Postgres.
--
-- Rollback: drop schema app cascade;
-- =============================================================================

create schema if not exists app;

comment on schema app is
  'Server-side helper functions for RLS, auditing and document numbering. '
  'Never queried directly by the application; referenced from policies and triggers.';

-- The `app` schema is machinery, not data. Clients may execute the specific
-- functions granted below, but must not be able to create objects here.
revoke all on schema app from public;
grant usage on schema app to public;

-- -----------------------------------------------------------------------------
-- app.set_updated_at() — keeps updated_at honest regardless of what the caller sends
-- -----------------------------------------------------------------------------
create or replace function app.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

comment on function app.set_updated_at() is
  'BEFORE UPDATE trigger. Stamps updated_at server-side so a client cannot backdate a change.';

-- -----------------------------------------------------------------------------
-- app.forbid_mutation() — for append-only tables (audit_logs)
-- -----------------------------------------------------------------------------
create or replace function app.forbid_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception '% is append-only; % is not permitted.', tg_table_name, tg_op
    using errcode = '42501';
end;
$$;

comment on function app.forbid_mutation() is
  'BEFORE UPDATE OR DELETE trigger for append-only tables. Spec §46 (audit trail integrity).';


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0002_organization.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0002 — Organization: dealers and branches
-- =============================================================================
-- Spec §4, §5. The tenant root is `dealers`; every tenant-sensitive row in the
-- system carries dealer_id, and branch-specific rows additionally carry branch_id.
--
-- Note the `unique (id, dealer_id)` on both tables. It looks redundant next to the
-- primary key, but it is what lets every downstream table declare a COMPOSITE
-- foreign key `(branch_id, dealer_id) -> branches(id, dealer_id)`. That makes it
-- structurally impossible to attach Dealer A's record to Dealer B's branch — the
-- database rejects it, no application code involved (spec §60.4, §60.5).
--
-- Rollback: drop table public.branches, public.dealers;
-- =============================================================================

create table public.dealers (
  id              uuid primary key default gen_random_uuid(),
  code            text not null,
  legal_name      text not null,
  trade_name      text,

  gstin           text,
  pan             text,

  address_line1   text,
  address_line2   text,
  city            text,
  state           text,
  state_code      text,
  pincode         text,
  phone           text,
  email           text,

  -- Financial-year start month, 4 = April (Indian FY). Drives period generation.
  fy_start_month  smallint not null default 4,

  status          text not null default 'ACTIVE',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  created_by      uuid,
  updated_by      uuid,

  constraint dealers_code_key           unique (code),
  constraint dealers_status_check       check (status in ('ACTIVE', 'SUSPENDED', 'CLOSED')),
  constraint dealers_fy_month_check     check (fy_start_month between 1 and 12),
  constraint dealers_code_format_check  check (code ~ '^[A-Z0-9_-]{2,20}$'),
  constraint dealers_gstin_format_check check (
    gstin is null or gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[0-9A-Z]{1}Z[0-9A-Z]{1}$'
  ),
  constraint dealers_pan_format_check   check (pan is null or pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  constraint dealers_pincode_check      check (pincode is null or pincode ~ '^[1-9][0-9]{5}$')
);

comment on table public.dealers is 'Tenant root. Every tenant-sensitive record is scoped to a dealer (spec §4).';
comment on column public.dealers.fy_start_month is 'Financial year start month; 4 = April for Indian FY.';

create table public.branches (
  id              uuid primary key default gen_random_uuid(),
  dealer_id       uuid not null references public.dealers (id) on delete restrict,
  code            text not null,
  name            text not null,

  gstin           text,
  address_line1   text,
  address_line2   text,
  city            text,
  state           text,
  state_code      text,
  pincode         text,
  phone           text,
  email           text,

  is_head_office  boolean not null default false,
  status          text not null default 'ACTIVE',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  created_by      uuid,
  updated_by      uuid,

  constraint branches_dealer_code_key    unique (dealer_id, code),
  -- Target for composite foreign keys from every branch-scoped table.
  constraint branches_id_dealer_key      unique (id, dealer_id),
  constraint branches_status_check       check (status in ('ACTIVE', 'SUSPENDED', 'CLOSED')),
  constraint branches_code_format_check  check (code ~ '^[A-Z0-9_-]{2,20}$'),
  constraint branches_gstin_format_check check (
    gstin is null or gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[0-9A-Z]{1}Z[0-9A-Z]{1}$'
  ),
  constraint branches_pincode_check      check (pincode is null or pincode ~ '^[1-9][0-9]{5}$')
);

comment on table public.branches is 'Operational unit within a dealer (spec §5). Branch-level data is scoped here.';
comment on constraint branches_id_dealer_key on public.branches is
  'Enables composite FKs (branch_id, dealer_id) elsewhere, making cross-tenant branch references impossible.';

-- Exactly one head office per dealer.
create unique index branches_one_head_office_idx
  on public.branches (dealer_id)
  where is_head_office;

create trigger dealers_set_updated_at
  before update on public.dealers
  for each row execute function app.set_updated_at();

create trigger branches_set_updated_at
  before update on public.branches
  for each row execute function app.set_updated_at();


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0003_identity.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0003 — Identity: user profiles, roles, permissions, branch access, employees
-- =============================================================================
-- Spec §5, §6, §12. Authentication itself lives in Supabase's `auth.users`;
-- everything the ERP needs to make an authorization decision lives here.
--
-- Authorization is permission-based, never role-name-based. Roles are rows that
-- bundle permission codes, so a dealer can define its own roles without a code
-- change (spec §6, §47).
--
-- Rollback: drop tables in reverse order of creation.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- permissions — global reference data, one row per capability in the system
-- -----------------------------------------------------------------------------
create table public.permissions (
  code        text primary key,
  module      text not null,
  description text not null,
  -- Permissions guarding cost/margin/profit visibility (spec §10, §52).
  is_sensitive boolean not null default false,
  created_at  timestamptz not null default now(),

  constraint permissions_code_format_check check (code ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$')
);

comment on table public.permissions is
  'Capability catalogue. Mirrored in src/lib/permissions/registry.ts; '
  'scripts/check-permissions-sync.ts fails the build if the two drift apart.';

-- -----------------------------------------------------------------------------
-- roles — system roles (dealer_id null) and dealer-defined roles
-- -----------------------------------------------------------------------------
create table public.roles (
  id          uuid primary key default gen_random_uuid(),
  dealer_id   uuid references public.dealers (id) on delete cascade,
  code        text not null,
  name        text not null,
  description text,
  is_system   boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid,
  updated_by  uuid,

  constraint roles_code_format_check check (code ~ '^[A-Z][A-Z0-9_]{1,40}$'),
  constraint roles_system_shape_check check (
    (is_system and dealer_id is null) or (not is_system and dealer_id is not null)
  )
);

-- System role codes are globally unique; dealer role codes are unique per dealer.
create unique index roles_system_code_key
  on public.roles (code) where dealer_id is null;

create unique index roles_dealer_code_key
  on public.roles (dealer_id, code) where dealer_id is not null;

comment on table public.roles is
  'Role definitions. System roles (spec §6) ship with the product; dealers may add their own.';

create table public.role_permissions (
  role_id         uuid not null references public.roles (id) on delete cascade,
  permission_code text not null references public.permissions (code) on delete cascade,
  granted_at      timestamptz not null default now(),
  granted_by      uuid,

  primary key (role_id, permission_code)
);

-- -----------------------------------------------------------------------------
-- user_profiles — the ERP's view of an authenticated user
-- -----------------------------------------------------------------------------
create table public.user_profiles (
  id                     uuid primary key references auth.users (id) on delete cascade,
  dealer_id              uuid references public.dealers (id) on delete restrict,

  full_name              text not null,
  email                  text not null,
  mobile                 text,

  -- Platform admins (spec §6) sit above the tenant model and have no dealer.
  is_platform_admin      boolean not null default false,

  -- Dealer owners and accounts staff see every branch; branch staff are limited
  -- to the rows in user_branches.
  has_all_branch_access  boolean not null default false,
  default_branch_id      uuid references public.branches (id) on delete set null,

  status                 text not null default 'ACTIVE',
  last_login_at          timestamptz,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  created_by             uuid,
  updated_by             uuid,

  constraint user_profiles_status_check check (status in ('ACTIVE', 'SUSPENDED', 'DISABLED')),
  -- A user belongs to exactly one tenant, or is a platform admin belonging to none.
  constraint user_profiles_tenant_shape_check check (
    (is_platform_admin and dealer_id is null)
    or (not is_platform_admin and dealer_id is not null)
  ),
  -- Target for composite FKs from user_roles / user_branches.
  constraint user_profiles_id_dealer_key unique (id, dealer_id),
  -- The default branch must belong to the user's own dealer. Not enforced for
  -- platform admins (dealer_id null) or users with no default set — MATCH SIMPLE
  -- skips the check when any referencing column is null, which is what we want.
  constraint user_profiles_default_branch_tenant_fkey
    foreign key (default_branch_id, dealer_id) references public.branches (id, dealer_id)
);

create unique index user_profiles_email_key on public.user_profiles (lower(email));

comment on table public.user_profiles is
  'Tenant, branch access and status for each authenticated user. '
  'Resolved server-side by getTenantContext(); never trusted from the client (spec §47).';

-- -----------------------------------------------------------------------------
-- user_roles / user_branches
-- -----------------------------------------------------------------------------
create table public.user_roles (
  user_id     uuid not null references public.user_profiles (id) on delete cascade,
  role_id     uuid not null references public.roles (id) on delete cascade,
  assigned_at timestamptz not null default now(),
  assigned_by uuid,

  primary key (user_id, role_id)
);

create table public.user_branches (
  user_id    uuid not null references public.user_profiles (id) on delete cascade,
  branch_id  uuid not null references public.branches (id) on delete cascade,
  dealer_id  uuid not null,
  granted_at timestamptz not null default now(),
  granted_by uuid,

  primary key (user_id, branch_id),
  -- Both halves must agree on the tenant: the branch must belong to dealer_id,
  -- and the user must belong to the same dealer.
  constraint user_branches_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id) on delete cascade,
  constraint user_branches_user_tenant_fkey
    foreign key (user_id, dealer_id) references public.user_profiles (id, dealer_id) on delete cascade
);

comment on table public.user_branches is
  'Explicit branch grants for users without has_all_branch_access. '
  'Branch switching validates against this table before setting the active-branch cookie.';

-- -----------------------------------------------------------------------------
-- employees — spec §12. Employee ID is mandatory and transactions retain attribution.
-- -----------------------------------------------------------------------------
create table public.employees (
  id            uuid primary key default gen_random_uuid(),
  dealer_id     uuid not null references public.dealers (id) on delete restrict,
  branch_id     uuid not null,
  employee_code text not null,

  name          text not null,
  department    text,
  designation   text,
  mobile        text,
  email         text,
  joining_date  date,
  leaving_date  date,

  -- Optional link to a login. Employees without system access have none.
  user_id       uuid references public.user_profiles (id) on delete set null,

  status        text not null default 'ACTIVE',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid,
  updated_by    uuid,

  constraint employees_dealer_code_key unique (dealer_id, employee_code),
  constraint employees_id_dealer_key   unique (id, dealer_id),
  constraint employees_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  -- A linked login must belong to the same dealer as the employee record.
  constraint employees_user_tenant_fkey
    foreign key (user_id, dealer_id) references public.user_profiles (id, dealer_id),
  constraint employees_status_check check (status in ('ACTIVE', 'ON_LEAVE', 'RESIGNED', 'TERMINATED')),
  constraint employees_dates_check   check (leaving_date is null or joining_date is null or leaving_date >= joining_date)
);

comment on table public.employees is 'Employee master (spec §12). employee_code is mandatory and dealer-unique.';

create trigger roles_set_updated_at
  before update on public.roles
  for each row execute function app.set_updated_at();

create trigger user_profiles_set_updated_at
  before update on public.user_profiles
  for each row execute function app.set_updated_at();

create trigger employees_set_updated_at
  before update on public.employees
  for each row execute function app.set_updated_at();


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0004_rls_helpers.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0004 — RLS helper functions
-- =============================================================================
-- Every policy in 0009 is written in terms of these five functions.
--
-- All of them are SECURITY DEFINER. This is not optional: a policy on
-- user_profiles that reads user_profiles to decide visibility would re-enter its
-- own policy and recurse until Postgres aborts the query. SECURITY DEFINER makes
-- the lookup run as the function owner, bypassing RLS for that read only.
--
-- Each function pins `search_path` so a caller cannot shadow `public` with a
-- temp-schema table and trick a definer-rights function into reading forged data.
--
-- Rollback: drop the functions; policies in 0009 depend on them.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- app.is_platform_admin() — spec §6, platform admins sit above the tenant model
-- -----------------------------------------------------------------------------
create or replace function app.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select up.is_platform_admin
       from public.user_profiles up
      where up.id = auth.uid()
        and up.status = 'ACTIVE'),
    false
  );
$$;

-- -----------------------------------------------------------------------------
-- app.current_dealer_id() — the tenant of the authenticated user
-- -----------------------------------------------------------------------------
create or replace function app.current_dealer_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select up.dealer_id
    from public.user_profiles up
   where up.id = auth.uid()
     and up.status = 'ACTIVE';
$$;

comment on function app.current_dealer_id() is
  'Tenant of the current session, resolved from the JWT. Returns NULL for platform '
  'admins and unauthenticated callers, so `dealer_id = app.current_dealer_id()` is '
  'false for both — deny by default (spec §4).';

-- -----------------------------------------------------------------------------
-- app.has_all_branch_access() — dealer owners and accounts see every branch
-- -----------------------------------------------------------------------------
create or replace function app.has_all_branch_access()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select up.has_all_branch_access or up.is_platform_admin
       from public.user_profiles up
      where up.id = auth.uid()
        and up.status = 'ACTIVE'),
    false
  );
$$;

-- -----------------------------------------------------------------------------
-- app.can_access_branch(uuid) — branch-level narrowing (spec §60.5)
-- -----------------------------------------------------------------------------
create or replace function app.can_access_branch(p_branch_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select app.has_all_branch_access()
      or exists (
           select 1
             from public.user_branches ub
            where ub.user_id = auth.uid()
              and ub.branch_id = p_branch_id
         );
$$;

-- -----------------------------------------------------------------------------
-- app.has_permission(text) — the single authorization primitive
-- -----------------------------------------------------------------------------
create or replace function app.has_permission(p_code text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select app.is_platform_admin()
      or exists (
           select 1
             from public.user_roles ur
             join public.role_permissions rp on rp.role_id = ur.role_id
            where ur.user_id = auth.uid()
              and rp.permission_code = p_code
         );
$$;

comment on function app.has_permission(text) is
  'True when the session holds the given permission code through any assigned role. '
  'Policies gate writes on permissions, never on role names, so roles stay data (spec §6).';

-- -----------------------------------------------------------------------------
-- Grants: executable by logged-in users only. `anon` gets nothing.
-- -----------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function app.is_platform_admin()          to authenticated';
    execute 'grant execute on function app.current_dealer_id()          to authenticated';
    execute 'grant execute on function app.has_all_branch_access()      to authenticated';
    execute 'grant execute on function app.can_access_branch(uuid)      to authenticated';
    execute 'grant execute on function app.has_permission(text)         to authenticated';
  end if;
end;
$$;

revoke execute on function app.is_platform_admin()     from public;
revoke execute on function app.current_dealer_id()     from public;
revoke execute on function app.has_all_branch_access() from public;
revoke execute on function app.can_access_branch(uuid) from public;
revoke execute on function app.has_permission(text)    from public;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0005_audit.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0005 — Audit trail
-- =============================================================================
-- Spec §46. Append-only log of every sensitive action, with the tenant, the user,
-- the entity, and the before/after state.
--
-- The table is protected by app.forbid_mutation(): rows can be inserted, never
-- updated or deleted. An audit log that can be rewritten is not an audit log.
--
-- Rollback: drop table public.audit_logs; drop function app.audit_trigger();
-- =============================================================================

create table public.audit_logs (
  id              bigint generated always as identity primary key,

  dealer_id       uuid,
  branch_id       uuid,

  user_id         uuid,
  user_email      text,

  action          text not null,
  entity_type     text not null,
  entity_id       text,

  old_data        jsonb,
  new_data        jsonb,
  changed_fields  text[],

  -- Required for reversals and adjustments (spec §23, §36).
  reason          text,

  ip_address      inet,
  user_agent      text,
  session_id      text,
  request_id      text,

  created_at      timestamptz not null default now(),

  constraint audit_logs_action_check check (action in (
    'CREATE', 'UPDATE', 'DELETE',
    'APPROVE', 'REJECT', 'POST', 'CANCEL', 'REVERSE',
    'LOGIN', 'LOGIN_FAILED', 'LOGOUT', 'BRANCH_SWITCH',
    'PERMISSION_CHANGE', 'ROLE_CHANGE',
    'STOCK_ADJUST', 'PRICE_CHANGE', 'GST_CHANGE',
    'DAY_CLOSE', 'RECONCILE',
    'IMPORT', 'EXPORT'
  ))
);

comment on table public.audit_logs is
  'Append-only audit trail (spec §46). Writes come from app.audit_trigger() for table '
  'changes and from recordAudit() in the service layer for non-table events.';

create trigger audit_logs_append_only
  before update or delete on public.audit_logs
  for each row execute function app.forbid_mutation();

-- -----------------------------------------------------------------------------
-- app.audit_trigger() — generic row auditor
-- -----------------------------------------------------------------------------
-- Attach to any table with `after insert or update or delete ... for each row`.
-- Reads dealer_id / branch_id out of the row itself via JSONB, so one function
-- serves tables with different shapes.
-- -----------------------------------------------------------------------------
create or replace function app.audit_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_old        jsonb;
  v_new        jsonb;
  v_row        jsonb;
  v_action     text;
  v_changed    text[];
  v_dealer_id  uuid;
  v_branch_id  uuid;
  v_entity_id  text;
begin
  if tg_op = 'INSERT' then
    v_action := 'CREATE';
    v_new    := to_jsonb(new);
    v_row    := v_new;
  elsif tg_op = 'UPDATE' then
    v_action := 'UPDATE';
    v_old    := to_jsonb(old);
    v_new    := to_jsonb(new);
    v_row    := v_new;

    -- Record only the fields that actually moved; ignore the updated_at stamp.
    select array_agg(key order by key)
      into v_changed
      from jsonb_each(v_new)
     where key not in ('updated_at', 'updated_by')
       and v_new -> key is distinct from v_old -> key;

    if v_changed is null then
      return null;  -- nothing of substance changed
    end if;
  else
    v_action := 'DELETE';
    v_old    := to_jsonb(old);
    v_row    := v_old;
  end if;

  v_dealer_id := nullif(v_row ->> 'dealer_id', '')::uuid;
  v_branch_id := nullif(v_row ->> 'branch_id', '')::uuid;
  -- Join tables have no `id`; fall back to the composite key's leading column so
  -- the row is still addressable from the log.
  v_entity_id := coalesce(v_row ->> 'id', v_row ->> 'code', v_row ->> 'user_id', v_row ->> 'role_id');

  insert into public.audit_logs (
    dealer_id, branch_id, user_id, action, entity_type, entity_id,
    old_data, new_data, changed_fields
  )
  values (
    v_dealer_id, v_branch_id, auth.uid(), v_action, tg_table_name, v_entity_id,
    v_old, v_new, v_changed
  );

  return null;  -- AFTER trigger; return value is ignored
end;
$$;

comment on function app.audit_trigger() is
  'Generic AFTER row trigger writing to audit_logs. Tenant columns are read from the '
  'row via JSONB so the same function works across differently shaped tables.';

-- -----------------------------------------------------------------------------
-- Attach to the Phase 1 tables that carry compliance weight
-- -----------------------------------------------------------------------------
create trigger dealers_audit
  after insert or update or delete on public.dealers
  for each row execute function app.audit_trigger();

create trigger branches_audit
  after insert or update or delete on public.branches
  for each row execute function app.audit_trigger();

create trigger user_profiles_audit
  after insert or update or delete on public.user_profiles
  for each row execute function app.audit_trigger();

create trigger roles_audit
  after insert or update or delete on public.roles
  for each row execute function app.audit_trigger();

create trigger role_permissions_audit
  after insert or update or delete on public.role_permissions
  for each row execute function app.audit_trigger();

create trigger user_roles_audit
  after insert or update or delete on public.user_roles
  for each row execute function app.audit_trigger();

create trigger user_branches_audit
  after insert or update or delete on public.user_branches
  for each row execute function app.audit_trigger();

create trigger employees_audit
  after insert or update or delete on public.employees
  for each row execute function app.audit_trigger();


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0006_document_sequences.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0006 — Document numbering
-- =============================================================================
-- Spec §45: financial document numbers are never generated in frontend JavaScript.
-- app.next_document_number() increments under a row lock, so two cashiers hitting
-- "save" at the same instant get different invoice numbers (spec §49).
--
-- Rollback: drop function app.next_document_number(...); drop table public.document_sequences;
-- =============================================================================

create table public.document_sequences (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null references public.dealers (id) on delete cascade,
  -- NULL for dealer-wide sequences (e.g. journal numbers shared across branches).
  branch_id      uuid,

  doc_type       text not null,
  -- The year token that appears inside the number, e.g. '2026' in INV-2026-000001.
  financial_year text not null,

  prefix         text not null,
  padding        smallint not null default 6,
  last_number    bigint not null default 0,

  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),

  constraint document_sequences_scope_key
    unique nulls not distinct (dealer_id, branch_id, doc_type, financial_year),
  constraint document_sequences_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id) on delete cascade,
  constraint document_sequences_doc_type_check check (doc_type ~ '^[A-Z][A-Z0-9_]{1,30}$'),
  constraint document_sequences_prefix_check   check (prefix ~ '^[A-Z]{1,6}$'),
  constraint document_sequences_padding_check  check (padding between 3 and 12),
  constraint document_sequences_last_number_check check (last_number >= 0)
);

comment on table public.document_sequences is
  'Per dealer/branch/document-type/year counters (spec §45). Never bypassed by the client.';

create trigger document_sequences_set_updated_at
  before update on public.document_sequences
  for each row execute function app.set_updated_at();

-- -----------------------------------------------------------------------------
-- app.next_document_number() — atomic, gap-free within a committed transaction
-- -----------------------------------------------------------------------------
-- The UPDATE ... RETURNING takes a row-level lock for the duration of the calling
-- transaction, so concurrent callers serialize on this row rather than colliding.
-- Numbers are consumed on rollback only if the whole transaction rolls back, which
-- is the behaviour financial documents want (no reserved-then-abandoned numbers).
-- -----------------------------------------------------------------------------
create or replace function app.next_document_number(
  p_dealer_id      uuid,
  p_branch_id      uuid,
  p_doc_type       text,
  p_financial_year text
)
returns text
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_prefix  text;
  v_padding smallint;
  v_number  bigint;
begin
  update public.document_sequences ds
     set last_number = ds.last_number + 1
   where ds.dealer_id = p_dealer_id
     and ds.branch_id is not distinct from p_branch_id
     and ds.doc_type = p_doc_type
     and ds.financial_year = p_financial_year
  returning ds.prefix, ds.padding, ds.last_number
       into v_prefix, v_padding, v_number;

  if not found then
    raise exception
      'No document sequence configured for dealer %, branch %, type %, year %.',
      p_dealer_id, coalesce(p_branch_id::text, '(dealer-wide)'), p_doc_type, p_financial_year
      using errcode = 'no_data_found',
            hint = 'Insert a row into document_sequences before issuing this document type.';
  end if;

  return v_prefix || '-' || p_financial_year || '-' || lpad(v_number::text, v_padding, '0');
end;
$$;

comment on function app.next_document_number(uuid, uuid, text, text) is
  'Returns the next number for a document scope, e.g. INV-2026-000001. '
  'Row-locked, so it is safe under concurrent sales (spec §45, §49).';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function app.next_document_number(uuid, uuid, text, text) to authenticated';
  end if;
end;
$$;

revoke execute on function app.next_document_number(uuid, uuid, text, text) from public;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0007_accounting_core.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0007 — Accounting core: chart of accounts, periods, journals
-- =============================================================================
-- Spec §21–§24. Every module in the product eventually posts through these three
-- tables; there is exactly one accounting engine (spec §60.18).
--
-- This migration creates the SCHEMA and its integrity rules — the balance check,
-- the immutability trigger, the reversal linkage. The posting service that writes
-- through it arrives with the business modules (Phase 4+).
--
-- Three rules are enforced by the database, not by application code:
--   1. A posted journal balances: total_debit = total_credit (spec §22).
--   2. A posted journal cannot be edited or deleted (spec §23, §60.12).
--   3. Correction happens through reversal, and a reversal records who and why.
--
-- Rollback: drop tables journal_entry_lines, journal_entries, accounting_periods,
--           chart_of_accounts; drop the app.journal_* functions.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- chart_of_accounts — spec §24
-- -----------------------------------------------------------------------------
create table public.chart_of_accounts (
  id              uuid primary key default gen_random_uuid(),
  dealer_id       uuid not null references public.dealers (id) on delete restrict,

  code            text not null,
  name            text not null,
  account_type    text not null,
  account_subtype text,

  parent_id       uuid,

  -- Which side increases this account. Used for ledger presentation and for
  -- deriving balances without hard-coding sign logic per report.
  normal_balance  text not null,

  -- Group accounts are headers; only leaf accounts may be posted to.
  is_group        boolean not null default false,
  -- System accounts are created by seed/migration and cannot be deleted by users.
  is_system       boolean not null default false,
  -- When true, ledger balances are meaningful per branch (cash, bank, stock).
  is_branch_scoped boolean not null default false,

  status          text not null default 'ACTIVE',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  created_by      uuid,
  updated_by      uuid,

  constraint coa_dealer_code_key unique (dealer_id, code),
  constraint coa_id_dealer_key   unique (id, dealer_id),
  constraint coa_parent_tenant_fkey
    foreign key (parent_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint coa_type_check check (
    account_type in ('ASSET', 'LIABILITY', 'EQUITY', 'INCOME', 'EXPENSE')
  ),
  constraint coa_normal_balance_check check (normal_balance in ('DEBIT', 'CREDIT')),
  constraint coa_status_check check (status in ('ACTIVE', 'INACTIVE')),
  constraint coa_code_format_check check (code ~ '^[0-9A-Z][0-9A-Z._-]{0,29}$'),
  -- Assets and expenses are debit-normal; liabilities, equity and income are credit-normal.
  constraint coa_normal_balance_matches_type_check check (
    (account_type in ('ASSET', 'EXPENSE') and normal_balance = 'DEBIT')
    or (account_type in ('LIABILITY', 'EQUITY', 'INCOME') and normal_balance = 'CREDIT')
  ),
  constraint coa_no_self_parent_check check (parent_id is null or parent_id <> id)
);

comment on table public.chart_of_accounts is
  'Dealer-scoped chart of accounts (spec §24). Account IDs are resolved through '
  'accounting rules at posting time and are never hard-coded in the frontend (spec §22).';

-- -----------------------------------------------------------------------------
-- accounting_periods — spec §44
-- -----------------------------------------------------------------------------
create table public.accounting_periods (
  id         uuid primary key default gen_random_uuid(),
  dealer_id  uuid not null references public.dealers (id) on delete cascade,

  name       text not null,
  start_date date not null,
  end_date   date not null,
  status     text not null default 'OPEN',

  closed_at  timestamptz,
  closed_by  uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint accounting_periods_range_key  unique (dealer_id, start_date, end_date),
  constraint accounting_periods_id_dealer_key unique (id, dealer_id),
  constraint accounting_periods_dates_check check (end_date >= start_date),
  constraint accounting_periods_status_check check (status in ('OPEN', 'CLOSED', 'LOCKED'))
);

create index accounting_periods_dealer_range_idx
  on public.accounting_periods (dealer_id, start_date, end_date);

-- A dealer's periods must not overlap. An exclusion constraint would be the
-- natural tool but needs btree_gist; a trigger keeps this migration extension-free.
create or replace function app.accounting_periods_no_overlap()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_conflict text;
begin
  select ap.name
    into v_conflict
    from public.accounting_periods ap
   where ap.dealer_id = new.dealer_id
     and ap.id <> new.id
     and ap.start_date <= new.end_date
     and ap.end_date   >= new.start_date
   limit 1;

  if found then
    raise exception 'Accounting period % overlaps existing period %.', new.name, v_conflict
      using errcode = 'exclusion_violation';
  end if;

  return new;
end;
$$;

create trigger accounting_periods_no_overlap
  before insert or update on public.accounting_periods
  for each row execute function app.accounting_periods_no_overlap();

-- -----------------------------------------------------------------------------
-- journal_entries — spec §21, §22, §23
-- -----------------------------------------------------------------------------
create table public.journal_entries (
  id                   uuid primary key default gen_random_uuid(),
  dealer_id            uuid not null references public.dealers (id) on delete restrict,
  branch_id            uuid not null,

  entry_number         text not null,
  entry_date           date not null,
  period_id            uuid,

  -- Which business module raised this accounting event (spec §21).
  source_module        text not null,
  source_document_type text,
  source_document_id   uuid,

  narration            text,
  status               text not null default 'DRAFT',

  -- Maintained by trigger from the lines; never written directly by the client.
  total_debit          numeric(18, 4) not null default 0,
  total_credit         numeric(18, 4) not null default 0,

  -- Reversal linkage (spec §23).
  reversal_of_id       uuid,
  reversed_by_id       uuid,
  reversal_reason      text,

  -- Duplicate-submission protection for financial endpoints (spec §50).
  idempotency_key      text,

  posted_at            timestamptz,
  posted_by            uuid,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  created_by           uuid,
  updated_by           uuid,

  constraint journal_entries_dealer_number_key unique (dealer_id, entry_number),
  constraint journal_entries_id_dealer_key     unique (id, dealer_id),
  constraint journal_entries_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint journal_entries_period_tenant_fkey
    foreign key (period_id, dealer_id) references public.accounting_periods (id, dealer_id),
  constraint journal_entries_reversal_of_fkey
    foreign key (reversal_of_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint journal_entries_reversed_by_fkey
    foreign key (reversed_by_id, dealer_id) references public.journal_entries (id, dealer_id),

  constraint journal_entries_status_check check (status in ('DRAFT', 'POSTED', 'REVERSED')),
  constraint journal_entries_module_check check (source_module in (
    'SALES', 'BOOKING', 'SERVICE', 'ACCESSORY', 'SPARE',
    'FINANCE', 'TRADE_ADVANCE', 'CASH', 'BANK',
    'EXPENSE', 'INVENTORY', 'MANUAL', 'OPENING'
  )),
  constraint journal_entries_totals_sign_check check (total_debit >= 0 and total_credit >= 0),

  -- Rule 1: a posted journal balances (spec §22).
  constraint journal_entries_balanced_check check (
    status = 'DRAFT' or total_debit = total_credit
  ),
  constraint journal_entries_posted_nonzero_check check (
    status = 'DRAFT' or total_debit > 0
  ),
  constraint journal_entries_posted_stamp_check check (
    status = 'DRAFT' or posted_at is not null
  ),
  -- A reversal must say why (spec §23).
  constraint journal_entries_reversal_reason_check check (
    reversal_of_id is null or reversal_reason is not null
  ),
  constraint journal_entries_no_self_reversal_check check (
    (reversal_of_id is null or reversal_of_id <> id)
    and (reversed_by_id is null or reversed_by_id <> id)
  )
);

comment on table public.journal_entries is
  'Journal header. Posted entries are immutable; corrections are made by posting a '
  'reversal and a corrected entry (spec §23, §60.12, §60.13).';

-- Idempotency keys are unique per dealer where present (spec §50).
create unique index journal_entries_idempotency_key
  on public.journal_entries (dealer_id, idempotency_key)
  where idempotency_key is not null;

-- -----------------------------------------------------------------------------
-- journal_entry_lines
-- -----------------------------------------------------------------------------
create table public.journal_entry_lines (
  id               uuid primary key default gen_random_uuid(),
  journal_entry_id uuid not null,
  dealer_id        uuid not null,

  line_number      smallint not null,
  account_id       uuid not null,
  -- Optional narrower scope than the header, for branch-scoped accounts.
  branch_id        uuid,

  debit            numeric(18, 4) not null default 0,
  credit           numeric(18, 4) not null default 0,

  narration        text,

  -- Subsidiary-ledger pointer: which customer / supplier / finance company this
  -- line belongs to, so party ledgers reconcile to the general ledger (spec §25).
  party_type       text,
  party_id         uuid,

  created_at       timestamptz not null default now(),

  constraint jel_entry_line_key unique (journal_entry_id, line_number),
  constraint jel_entry_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id) on delete cascade,
  constraint jel_account_tenant_fkey
    foreign key (account_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint jel_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint jel_amounts_sign_check check (debit >= 0 and credit >= 0),
  -- A line is a debit or a credit, never both and never neither.
  constraint jel_one_sided_check check (
    (debit > 0 and credit = 0) or (credit > 0 and debit = 0)
  ),
  constraint jel_line_number_check check (line_number > 0),
  constraint jel_party_shape_check check (
    (party_type is null and party_id is null) or (party_type is not null and party_id is not null)
  ),
  constraint jel_party_type_check check (
    party_type is null or party_type in ('CUSTOMER', 'SUPPLIER', 'FINANCE_COMPANY', 'EMPLOYEE')
  )
);

comment on table public.journal_entry_lines is
  'Journal detail. Every line is one-sided; the header''s balance check is enforced at posting.';

-- -----------------------------------------------------------------------------
-- Posting guard: recompute totals from lines, and refuse to post an unbalanced entry
-- -----------------------------------------------------------------------------
-- This is where the double-entry rule actually bites. The CHECK constraint above
-- can only compare the columns it is given; this trigger makes sure those columns
-- reflect the lines rather than whatever the caller supplied.
-- -----------------------------------------------------------------------------
create or replace function app.journal_entries_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_debit  numeric(18, 4);
  v_credit numeric(18, 4);
  v_lines  integer;
begin
  if tg_op = 'DELETE' then
    if old.status <> 'DRAFT' then
      raise exception
        'Journal % is % and cannot be deleted. Post a reversal instead.', old.entry_number, old.status
        using errcode = 'insufficient_privilege',
              hint = 'Spec §23: corrections use reversal, not deletion.';
    end if;
    return old;
  end if;

  -- Entries are born as drafts. Forcing everything through the DRAFT -> POSTED
  -- transition below means the line-level balance check can never be skipped by
  -- inserting a pre-posted row with hand-written totals.
  if tg_op = 'INSERT' then
    if new.status <> 'DRAFT' then
      raise exception 'Journal entries must be created as DRAFT, then posted; got %.', new.status
        using errcode = 'check_violation',
              hint = 'Insert the header and its lines, then update status to POSTED.';
    end if;
    return new;
  end if;

  -- DRAFT -> POSTED: derive the totals from the lines and verify the entry balances.
  if old.status = 'DRAFT' and new.status = 'POSTED' then
    select coalesce(sum(l.debit), 0), coalesce(sum(l.credit), 0), count(*)
      into v_debit, v_credit, v_lines
      from public.journal_entry_lines l
     where l.journal_entry_id = old.id;

    if v_lines < 2 then
      raise exception 'Journal % needs at least two lines to post; found %.', old.entry_number, v_lines
        using errcode = 'check_violation';
    end if;

    if v_debit <> v_credit then
      raise exception
        'Journal % does not balance: debit % <> credit %.', old.entry_number, v_debit, v_credit
        using errcode = 'check_violation',
              hint = 'Spec §22: total debit must equal total credit.';
    end if;

    new.total_debit  := v_debit;
    new.total_credit := v_credit;
    new.posted_at    := coalesce(new.posted_at, now());
    return new;
  end if;

  -- POSTED is immutable except for recording that it has since been reversed.
  if old.status = 'POSTED' then
    if new.status = 'REVERSED'
       and old.reversed_by_id is null
       and new.reversed_by_id is not null
       and new.reversal_reason is not null
       and (to_jsonb(new) - 'status' - 'reversed_by_id' - 'reversal_reason' - 'updated_at' - 'updated_by')
           = (to_jsonb(old) - 'status' - 'reversed_by_id' - 'reversal_reason' - 'updated_at' - 'updated_by')
    then
      return new;
    end if;

    raise exception 'Journal % is POSTED and immutable.', old.entry_number
      using errcode = 'insufficient_privilege',
            hint = 'Spec §23: post a reversal and a corrected entry instead of editing.';
  end if;

  if old.status = 'REVERSED' then
    raise exception 'Journal % is REVERSED and immutable.', old.entry_number
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end;
$$;

create trigger journal_entries_guard
  before insert or update or delete on public.journal_entries
  for each row execute function app.journal_entries_guard();

-- -----------------------------------------------------------------------------
-- Line guard: lines may only change while the header is DRAFT
-- -----------------------------------------------------------------------------
create or replace function app.journal_lines_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_entry_id uuid := coalesce(new.journal_entry_id, old.journal_entry_id);
  v_status   text;
  v_number   text;
begin
  select je.status, je.entry_number
    into v_status, v_number
    from public.journal_entries je
   where je.id = v_entry_id;

  -- Header already gone (ON DELETE CASCADE): let the cascade proceed.
  if v_status is null then
    return coalesce(new, old);
  end if;

  if v_status <> 'DRAFT' then
    raise exception 'Cannot % lines of journal %: it is %.', lower(tg_op), v_number, v_status
      using errcode = 'insufficient_privilege',
            hint = 'Spec §23: posted journals are immutable.';
  end if;

  return coalesce(new, old);
end;
$$;

create trigger journal_lines_guard
  before insert or update or delete on public.journal_entry_lines
  for each row execute function app.journal_lines_guard();

-- -----------------------------------------------------------------------------
-- Totals stay in sync with the lines while the entry is still a draft
-- -----------------------------------------------------------------------------
create or replace function app.journal_sync_totals()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_entry_id uuid := coalesce(new.journal_entry_id, old.journal_entry_id);
begin
  update public.journal_entries je
     set total_debit  = coalesce(t.debit, 0),
         total_credit = coalesce(t.credit, 0)
    from (
      select sum(l.debit) as debit, sum(l.credit) as credit
        from public.journal_entry_lines l
       where l.journal_entry_id = v_entry_id
    ) t
   where je.id = v_entry_id
     and je.status = 'DRAFT';

  return null;
end;
$$;

create trigger journal_lines_sync_totals
  after insert or update or delete on public.journal_entry_lines
  for each row execute function app.journal_sync_totals();

create trigger chart_of_accounts_set_updated_at
  before update on public.chart_of_accounts
  for each row execute function app.set_updated_at();

create trigger accounting_periods_set_updated_at
  before update on public.accounting_periods
  for each row execute function app.set_updated_at();

create trigger journal_entries_set_updated_at
  before update on public.journal_entries
  for each row execute function app.set_updated_at();

create trigger chart_of_accounts_audit
  after insert or update or delete on public.chart_of_accounts
  for each row execute function app.audit_trigger();

create trigger journal_entries_audit
  after insert or update or delete on public.journal_entries
  for each row execute function app.audit_trigger();


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0008_system_settings.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0008 — System settings
-- =============================================================================
-- Spec §44. Configuration that must be data rather than code: accounting policy
-- switches, allocation rules, feature toggles. Platform-level rows have a NULL
-- dealer_id; a dealer row of the same key overrides it.
--
-- Rollback: drop table public.system_settings;
-- =============================================================================

create table public.system_settings (
  id          uuid primary key default gen_random_uuid(),
  dealer_id   uuid references public.dealers (id) on delete cascade,

  key         text not null,
  value       jsonb not null,
  value_type  text not null default 'json',
  description text,

  -- Settings the UI may read (never secrets).
  is_public   boolean not null default false,

  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  updated_by  uuid,

  constraint system_settings_scope_key unique nulls not distinct (dealer_id, key),
  constraint system_settings_key_format_check check (key ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'),
  constraint system_settings_value_type_check check (
    value_type in ('json', 'string', 'number', 'boolean')
  )
);

comment on table public.system_settings is
  'Configuration as data. A dealer-scoped row overrides the platform row with the same key.';

create trigger system_settings_set_updated_at
  before update on public.system_settings
  for each row execute function app.set_updated_at();

create trigger system_settings_audit
  after insert or update or delete on public.system_settings
  for each row execute function app.audit_trigger();


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0009_rls_policies.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0009 — Row Level Security
-- =============================================================================
-- Spec §4, §47, §60.20. RLS is the second line of defense: even if a service-layer
-- check is missed, a query issued with a user's JWT cannot reach another dealer's
-- rows.
--
-- Policy shape, applied uniformly:
--   SELECT  — platform admin, or row belongs to my dealer (and my branch, if the
--             row is branch-specific)
--   WRITE   — the same tenant test AND an explicit permission code
--
-- Two things worth noting:
--   * ENABLE, deliberately not FORCE. The helper functions in 0004 are SECURITY
--     DEFINER and owned by the migration role, which is also the table owner —
--     forcing RLS would subject those lookups to the very policies they exist to
--     answer, and `app.current_dealer_id()` would recurse into the user_profiles
--     policy. Client sessions connect as `authenticated`, never as the owner, so
--     policies still apply to every request that comes from a browser.
--   * The service_role key bypasses RLS entirely by design. It is server-only and
--     must never reach the browser (spec §47).
--
-- Rollback: drop the policies, then `alter table ... disable row level security`.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Enable on every table
-- -----------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array[
    'dealers', 'branches',
    'permissions', 'roles', 'role_permissions',
    'user_profiles', 'user_roles', 'user_branches', 'employees',
    'audit_logs', 'document_sequences',
    'chart_of_accounts', 'accounting_periods', 'journal_entries', 'journal_entry_lines',
    'system_settings'
  ]
  loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end;
$$;

-- =============================================================================
-- dealers — a user sees only their own dealer; only platform admins create them
-- =============================================================================
create policy dealers_select on public.dealers
  for select to authenticated
  using (app.is_platform_admin() or id = app.current_dealer_id());

create policy dealers_update on public.dealers
  for update to authenticated
  using (
    app.is_platform_admin()
    or (id = app.current_dealer_id() and app.has_permission('admin.dealers.manage'))
  )
  with check (
    app.is_platform_admin()
    or (id = app.current_dealer_id() and app.has_permission('admin.dealers.manage'))
  );

create policy dealers_insert on public.dealers
  for insert to authenticated
  with check (app.is_platform_admin());

create policy dealers_delete on public.dealers
  for delete to authenticated
  using (app.is_platform_admin());

-- =============================================================================
-- branches
-- =============================================================================
create policy branches_select on public.branches
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.can_access_branch(id))
  );

create policy branches_insert on public.branches
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.branches.manage'))
  );

create policy branches_update on public.branches
  for update to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.branches.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.branches.manage'))
  );

create policy branches_delete on public.branches
  for delete to authenticated
  using (app.is_platform_admin());

-- =============================================================================
-- permissions — global read-only catalogue
-- =============================================================================
create policy permissions_select on public.permissions
  for select to authenticated
  using (true);

create policy permissions_write on public.permissions
  for all to authenticated
  using (app.is_platform_admin())
  with check (app.is_platform_admin());

-- =============================================================================
-- roles — system roles readable by all; dealer roles scoped to the dealer
-- =============================================================================
create policy roles_select on public.roles
  for select to authenticated
  using (
    app.is_platform_admin()
    or dealer_id is null
    or dealer_id = app.current_dealer_id()
  );

create policy roles_insert on public.roles
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and not is_system
        and app.has_permission('admin.roles.manage'))
  );

create policy roles_update on public.roles
  for update to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and not is_system
        and app.has_permission('admin.roles.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and not is_system
        and app.has_permission('admin.roles.manage'))
  );

create policy roles_delete on public.roles
  for delete to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and not is_system
        and app.has_permission('admin.roles.manage'))
  );

-- =============================================================================
-- role_permissions — visible for roles you can see, writable with the permission
-- =============================================================================
create policy role_permissions_select on public.role_permissions
  for select to authenticated
  using (
    exists (
      select 1 from public.roles r
       where r.id = role_permissions.role_id
         and (app.is_platform_admin() or r.dealer_id is null or r.dealer_id = app.current_dealer_id())
    )
  );

create policy role_permissions_write on public.role_permissions
  for all to authenticated
  using (
    app.is_platform_admin()
    or (app.has_permission('admin.roles.manage')
        and exists (
          select 1 from public.roles r
           where r.id = role_permissions.role_id
             and r.dealer_id = app.current_dealer_id()
             and not r.is_system
        ))
  )
  with check (
    app.is_platform_admin()
    or (app.has_permission('admin.roles.manage')
        and exists (
          select 1 from public.roles r
           where r.id = role_permissions.role_id
             and r.dealer_id = app.current_dealer_id()
             and not r.is_system
        ))
  );

-- =============================================================================
-- user_profiles — always see yourself; see colleagues with the users permission
-- =============================================================================
create policy user_profiles_select on public.user_profiles
  for select to authenticated
  using (
    id = auth.uid()
    or app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.users.view'))
  );

create policy user_profiles_insert on public.user_profiles
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.users.manage'))
  );

-- A user may update their own profile, but not their tenant, admin flag or branch
-- reach — those are privilege escalation vectors and require admin.users.manage.
create policy user_profiles_update on public.user_profiles
  for update to authenticated
  using (
    id = auth.uid()
    or app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.users.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.users.manage'))
    or (
      id = auth.uid()
      and dealer_id is not distinct from app.current_dealer_id()
      and not is_platform_admin
      -- Read the current value through the SECURITY DEFINER helper rather than a
      -- subquery on this same table, which would re-enter this policy.
      and has_all_branch_access = app.has_all_branch_access()
    )
  );

create policy user_profiles_delete on public.user_profiles
  for delete to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.users.manage'))
  );

-- =============================================================================
-- user_roles / user_branches — your own grants are readable; changes need admin
-- =============================================================================
create policy user_roles_select on public.user_roles
  for select to authenticated
  using (
    user_id = auth.uid()
    or app.is_platform_admin()
    or (app.has_permission('admin.users.view')
        and exists (
          select 1 from public.user_profiles up
           where up.id = user_roles.user_id and up.dealer_id = app.current_dealer_id()
        ))
  );

create policy user_roles_write on public.user_roles
  for all to authenticated
  using (
    app.is_platform_admin()
    or (app.has_permission('admin.users.manage')
        and exists (
          select 1 from public.user_profiles up
           where up.id = user_roles.user_id and up.dealer_id = app.current_dealer_id()
        ))
  )
  with check (
    app.is_platform_admin()
    or (app.has_permission('admin.users.manage')
        and exists (
          select 1 from public.user_profiles up
           where up.id = user_roles.user_id and up.dealer_id = app.current_dealer_id()
        ))
  );

create policy user_branches_select on public.user_branches
  for select to authenticated
  using (
    user_id = auth.uid()
    or app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.users.view'))
  );

create policy user_branches_write on public.user_branches
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.users.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.users.manage'))
  );

-- =============================================================================
-- employees
-- =============================================================================
create policy employees_select on public.employees
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and app.has_permission('masters.employees.view'))
  );

create policy employees_write on public.employees
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('masters.employees.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('masters.employees.manage'))
  );

-- =============================================================================
-- audit_logs — readable with the permission, never writable from a session.
-- Inserts come from SECURITY DEFINER triggers and the service role only, so there
-- is deliberately no INSERT policy here (spec §46).
-- =============================================================================
create policy audit_logs_select on public.audit_logs
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.audit.view'))
  );

-- =============================================================================
-- document_sequences — read to preview the next number, manage to reconfigure
-- =============================================================================
create policy document_sequences_select on public.document_sequences
  for select to authenticated
  using (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy document_sequences_write on public.document_sequences
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.settings.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.settings.manage'))
  );

-- =============================================================================
-- chart_of_accounts
-- =============================================================================
create policy chart_of_accounts_select on public.chart_of_accounts
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.coa.view'))
  );

create policy chart_of_accounts_write on public.chart_of_accounts
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.coa.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.coa.manage'))
  );

-- =============================================================================
-- accounting_periods
-- =============================================================================
create policy accounting_periods_select on public.accounting_periods
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.journals.view'))
  );

create policy accounting_periods_write on public.accounting_periods
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.periods.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.periods.manage'))
  );

-- =============================================================================
-- journal_entries / journal_entry_lines
-- Note there is no DELETE policy: journals are corrected by reversal, and the
-- 0007 trigger refuses to delete anything already posted (spec §23, §60.12).
-- =============================================================================
create policy journal_entries_select on public.journal_entries
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and app.has_permission('accounting.journals.view'))
  );

create policy journal_entries_insert on public.journal_entries
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and app.has_permission('accounting.journals.create'))
  );

create policy journal_entries_update on public.journal_entries
  for update to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and app.has_permission('accounting.journals.post'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and app.has_permission('accounting.journals.post'))
  );

create policy journal_entry_lines_select on public.journal_entry_lines
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and exists (
          select 1 from public.journal_entries je
           where je.id = journal_entry_lines.journal_entry_id
             and app.can_access_branch(je.branch_id)
        )
        and app.has_permission('accounting.journals.view'))
  );

create policy journal_entry_lines_write on public.journal_entry_lines
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.journals.create'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.journals.create'))
  );

-- =============================================================================
-- system_settings — public settings readable by all; secrets stay server-side
-- =============================================================================
create policy system_settings_select on public.system_settings
  for select to authenticated
  using (
    app.is_platform_admin()
    or (
      (dealer_id is null or dealer_id = app.current_dealer_id())
      and (is_public or app.has_permission('admin.settings.view'))
    )
  );

create policy system_settings_write on public.system_settings
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.settings.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.settings.manage'))
  );


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0010_indexes.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0010 — Indexes
-- =============================================================================
-- Spec §57.7. Two categories:
--   * Tenant-leading indexes. Every RLS policy filters on dealer_id first, so
--     dealer_id belongs at the front of almost every composite index.
--   * Foreign-key indexes. Postgres does not create these automatically, and
--     without them a cascade or a join scans the child table.
--
-- Rollback: drop index ...;
-- =============================================================================

-- Organization ---------------------------------------------------------------
create index branches_dealer_idx            on public.branches (dealer_id) where status = 'ACTIVE';
create index branches_dealer_name_idx       on public.branches (dealer_id, name);

-- Identity -------------------------------------------------------------------
create index user_profiles_dealer_idx       on public.user_profiles (dealer_id) where status = 'ACTIVE';
create index user_profiles_default_branch_idx on public.user_profiles (default_branch_id);
create index roles_dealer_idx               on public.roles (dealer_id);
create index role_permissions_permission_idx on public.role_permissions (permission_code);
create index user_roles_role_idx            on public.user_roles (role_id);
create index user_branches_branch_idx       on public.user_branches (branch_id);
create index user_branches_dealer_idx       on public.user_branches (dealer_id);

-- Employees: the two lookups the UI actually performs (spec §12).
create index employees_dealer_branch_idx    on public.employees (dealer_id, branch_id) where status = 'ACTIVE';
create index employees_name_search_idx      on public.employees (dealer_id, lower(name));
create index employees_mobile_idx           on public.employees (dealer_id, mobile) where mobile is not null;
create index employees_user_idx             on public.employees (user_id) where user_id is not null;

-- Audit ----------------------------------------------------------------------
-- The audit screen is "show me recent activity for this tenant", newest first.
create index audit_logs_dealer_time_idx     on public.audit_logs (dealer_id, created_at desc);
create index audit_logs_entity_idx          on public.audit_logs (entity_type, entity_id, created_at desc);
create index audit_logs_user_time_idx       on public.audit_logs (user_id, created_at desc);
create index audit_logs_branch_time_idx     on public.audit_logs (branch_id, created_at desc) where branch_id is not null;

-- Accounting -----------------------------------------------------------------
create index coa_dealer_type_idx            on public.chart_of_accounts (dealer_id, account_type) where status = 'ACTIVE';
create index coa_parent_idx                 on public.chart_of_accounts (parent_id) where parent_id is not null;

create index accounting_periods_dealer_status_idx on public.accounting_periods (dealer_id, status);

-- Ledger and trial-balance queries are "this dealer, this date range".
create index journal_entries_dealer_date_idx    on public.journal_entries (dealer_id, entry_date desc);
create index journal_entries_branch_date_idx    on public.journal_entries (branch_id, entry_date desc);
create index journal_entries_status_idx         on public.journal_entries (dealer_id, status) where status = 'DRAFT';
create index journal_entries_source_idx         on public.journal_entries (source_document_type, source_document_id)
  where source_document_id is not null;
create index journal_entries_period_idx         on public.journal_entries (period_id) where period_id is not null;
create index journal_entries_reversal_of_idx    on public.journal_entries (reversal_of_id) where reversal_of_id is not null;
create index journal_entries_reversed_by_idx    on public.journal_entries (reversed_by_id) where reversed_by_id is not null;

-- Account ledger: every line for one account, plus the FK index for cascades.
create index jel_account_idx                on public.journal_entry_lines (account_id);
create index jel_entry_idx                  on public.journal_entry_lines (journal_entry_id);
create index jel_branch_idx                 on public.journal_entry_lines (branch_id) where branch_id is not null;
-- Subsidiary ledgers (customer / finance company outstanding).
create index jel_party_idx                  on public.journal_entry_lines (party_type, party_id)
  where party_id is not null;

-- Sequences and settings -----------------------------------------------------
create index document_sequences_dealer_idx  on public.document_sequences (dealer_id, doc_type);
create index system_settings_dealer_idx     on public.system_settings (dealer_id);


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0011_grants.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0011 — Role grants
-- =============================================================================
-- RLS narrows what a privilege can reach; it does not grant the privilege. A
-- table with perfect policies and no GRANT is unreadable, and a table with a
-- GRANT and no policy is wide open. Both halves are set here explicitly rather
-- than relying on Supabase's default privileges, so the same result holds on a
-- plain Postgres server.
--
-- `anon` (unauthenticated) receives nothing at all. Every read in this product
-- requires a session.
--
-- Rollback: revoke the grants below.
-- =============================================================================

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  grant usage on schema public to authenticated, anon, service_role;

  -- Baseline: logged-in users may attempt any DML. Policies decide the outcome.
  execute 'grant select, insert, update, delete on all tables in schema public to authenticated';
  execute 'grant usage, select on all sequences in schema public to authenticated';

  -- Audit trail is written by SECURITY DEFINER triggers and the service role only.
  -- Removing INSERT here means a compromised session cannot forge log entries even
  -- if an INSERT policy is added by mistake later (spec §46).
  execute 'revoke insert, update, delete on public.audit_logs from authenticated';

  -- Journals are corrected by reversal, never deleted (spec §23, §60.12). The
  -- trigger in 0007 enforces this too; withholding the privilege makes it two
  -- independent barriers rather than one.
  execute 'revoke delete on public.journal_entries from authenticated';
  execute 'revoke delete on public.journal_entry_lines from authenticated';

  -- Only platform administration creates or removes tenants, and it does so
  -- through the service role.
  execute 'revoke delete on public.dealers from authenticated';

  -- The permission catalogue is release-managed, not user-editable.
  execute 'revoke insert, update, delete on public.permissions from authenticated';

  -- Unauthenticated callers get nothing.
  execute 'revoke all on all tables in schema public from anon';

  -- The service role is the server-side escape hatch: it bypasses RLS by design
  -- and must never be exposed to the browser (spec §47).
  execute 'grant all on all tables in schema public to service_role';
  execute 'grant all on all sequences in schema public to service_role';
end;
$$;

-- Future tables inherit the same baseline, so a migration that forgets its grants
-- still produces a table that authenticated users can reach under RLS.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'alter default privileges in schema public grant select, insert, update, delete on tables to authenticated';
    execute 'alter default privileges in schema public grant usage, select on sequences to authenticated';
    execute 'alter default privileges in schema public grant all on tables to service_role';
    execute 'alter default privileges in schema public grant all on sequences to service_role';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0012_reporting_functions.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0012 — Reporting: account balances
-- =============================================================================
-- The dashboard and every accounting report ask the same question: what are the
-- balances of each account, for this branch, over this date range. Doing that by
-- fetching journal lines into the application and summing them there would move
-- megabytes to add them up, so it is a database function.
--
-- SECURITY INVOKER (the default) is important here: the function runs with the
-- caller's privileges, so the RLS policies on journal_entries, journal_entry_lines
-- and chart_of_accounts all still apply. Tenant isolation is not bypassed to make
-- reporting convenient.
--
-- Balance-sheet accounts need a cumulative balance; profit-and-loss accounts need
-- the movement within the period. Both are returned so the caller picks the right
-- one per account type rather than issuing two queries.
--
-- Rollback: drop function public.account_balances(date, date, uuid);
-- =============================================================================

create or replace function public.account_balances(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  account_id        uuid,
  account_code      text,
  account_name      text,
  account_type      text,
  normal_balance    text,
  period_debit      numeric(18, 4),
  period_credit     numeric(18, 4),
  closing_debit     numeric(18, 4),
  closing_credit    numeric(18, 4),
  -- Signed balance in the account's own normal direction: positive means the
  -- account is where you would expect it to be.
  period_movement   numeric(18, 4),
  closing_balance   numeric(18, 4)
)
language sql
stable
as $$
  select
    coa.id,
    coa.code,
    coa.name,
    coa.account_type,
    coa.normal_balance,

    coalesce(sum(l.debit)  filter (where je.entry_date between p_from and p_to), 0),
    coalesce(sum(l.credit) filter (where je.entry_date between p_from and p_to), 0),
    coalesce(sum(l.debit)  filter (where je.entry_date <= p_to), 0),
    coalesce(sum(l.credit) filter (where je.entry_date <= p_to), 0),

    case when coa.normal_balance = 'DEBIT'
      then coalesce(sum(l.debit)  filter (where je.entry_date between p_from and p_to), 0)
         - coalesce(sum(l.credit) filter (where je.entry_date between p_from and p_to), 0)
      else coalesce(sum(l.credit) filter (where je.entry_date between p_from and p_to), 0)
         - coalesce(sum(l.debit)  filter (where je.entry_date between p_from and p_to), 0)
    end,

    case when coa.normal_balance = 'DEBIT'
      then coalesce(sum(l.debit)  filter (where je.entry_date <= p_to), 0)
         - coalesce(sum(l.credit) filter (where je.entry_date <= p_to), 0)
      else coalesce(sum(l.credit) filter (where je.entry_date <= p_to), 0)
         - coalesce(sum(l.debit)  filter (where je.entry_date <= p_to), 0)
    end

  from public.chart_of_accounts coa
  left join public.journal_entry_lines l
    on l.account_id = coa.id
  left join public.journal_entries je
    on je.id = l.journal_entry_id
   -- Only posted entries count. Drafts are not yet part of the books (spec §19).
   and je.status in ('POSTED', 'REVERSED')
   and (p_branch_id is null or je.branch_id = p_branch_id)
  where not coa.is_group
    and coa.status = 'ACTIVE'
  group by coa.id, coa.code, coa.name, coa.account_type, coa.normal_balance
  order by coa.code;
$$;

comment on function public.account_balances(date, date, uuid) is
  'Per-account debit/credit totals for a period and cumulatively to the end date. '
  'SECURITY INVOKER, so RLS scopes it to the caller''s dealer and branches.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.account_balances(date, date, uuid) to authenticated';
  end if;
end;
$$;

revoke execute on function public.account_balances(date, date, uuid) from public;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0013_customers.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0013 — Customer master
-- =============================================================================
-- Spec §11, §60.6. A dealer-level master: customers belong to the dealer, not to
-- a branch, so a customer who books at one branch and services at another is one
-- record rather than two.
--
-- The Customer ID is mandatory and auto-generated (spec §60.6). It is issued by
-- the same row-locked sequence mechanism as invoices (§45), never by the client,
-- so two cashiers creating customers at the same instant cannot collide.
--
-- Rollback: drop table public.customers; drop function app.financial_year_token(uuid, date),
--           app.customers_assign_code();
-- =============================================================================

-- -----------------------------------------------------------------------------
-- app.financial_year_token() — the year token used inside document numbers
-- -----------------------------------------------------------------------------
-- Reads the dealer's own fy_start_month (4 = April for Indian FY), so a dealer on
-- a non-standard financial year numbers its documents correctly.
-- -----------------------------------------------------------------------------
create or replace function app.financial_year_token(p_dealer_id uuid, p_date date default current_date)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case
           when extract(month from p_date) >= coalesce(d.fy_start_month, 4)
           then extract(year from p_date)::int
           else extract(year from p_date)::int - 1
         end::text
    from public.dealers d
   where d.id = p_dealer_id;
$$;

comment on function app.financial_year_token(uuid, date) is
  'Financial-year token for document numbering, e.g. 2026 in CUST-2026-000001.';

create table public.customers (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null references public.dealers (id) on delete restrict,

  -- Mandatory, dealer-unique, server-issued (spec §11, §60.6).
  customer_code     text not null,

  name              text not null,
  customer_type     text not null default 'INDIVIDUAL',

  mobile            text not null,
  alternate_mobile  text,
  email             text,

  address_line1     text,
  address_line2     text,
  city              text,
  state             text,
  state_code        text,
  pincode           text,

  gstin             text,
  pan               text,

  -- Where the customer was first registered. Informational: the record stays
  -- visible dealer-wide, because a customer is not branch property.
  origin_branch_id  uuid,

  notes             text,
  status            text not null default 'ACTIVE',

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid,
  updated_by        uuid,

  constraint customers_dealer_code_key unique (dealer_id, customer_code),
  constraint customers_id_dealer_key   unique (id, dealer_id),
  constraint customers_origin_branch_tenant_fkey
    foreign key (origin_branch_id, dealer_id) references public.branches (id, dealer_id),

  constraint customers_type_check   check (customer_type in ('INDIVIDUAL', 'BUSINESS')),
  constraint customers_status_check check (status in ('ACTIVE', 'INACTIVE', 'BLOCKED')),
  constraint customers_name_check   check (length(btrim(name)) between 2 and 150),
  -- Ten digits, first digit 6-9: the Indian mobile numbering plan.
  constraint customers_mobile_check check (mobile ~ '^[6-9][0-9]{9}$'),
  constraint customers_alt_mobile_check check (
    alternate_mobile is null or alternate_mobile ~ '^[6-9][0-9]{9}$'
  ),
  constraint customers_email_check check (email is null or email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[a-zA-Z]{2,}$'),
  constraint customers_gstin_check check (
    gstin is null or gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[0-9A-Z]{1}Z[0-9A-Z]{1}$'
  ),
  constraint customers_pan_check     check (pan is null or pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  constraint customers_pincode_check check (pincode is null or pincode ~ '^[1-9][0-9]{5}$'),
  -- A business customer registered under GST must carry a GSTIN.
  constraint customers_business_gstin_check check (
    customer_type <> 'BUSINESS' or gstin is not null
  )
);

comment on table public.customers is
  'Customer master (spec §11). Dealer-scoped, not branch-scoped: one customer record '
  'serves every branch the customer deals with.';
comment on column public.customers.customer_code is
  'Auto-generated, dealer-unique, issued server-side. Never supplied by the client.';

-- The same mobile number twice within a dealer is almost always a duplicate
-- record. Enforced only for active customers so a blocked record does not
-- prevent re-registering the person later.
create unique index customers_dealer_mobile_key
  on public.customers (dealer_id, mobile)
  where status = 'ACTIVE';

-- -----------------------------------------------------------------------------
-- Customer ID assignment
-- -----------------------------------------------------------------------------
-- Runs BEFORE INSERT, so the code is issued by the database under the same row
-- lock that protects invoice numbers. The sequence row is created on first use,
-- which means a newly provisioned dealer needs no manual setup — unlike financial
-- documents, where an unconfigured sequence should be a loud error rather than an
-- assumption.
-- -----------------------------------------------------------------------------
create or replace function app.customers_assign_code()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_year text;
begin
  if new.customer_code is not null and btrim(new.customer_code) <> '' then
    return new;  -- an explicit code (data migration) is respected
  end if;

  v_year := app.financial_year_token(new.dealer_id, coalesce(new.created_at::date, current_date));

  insert into public.document_sequences (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
  values (new.dealer_id, null, 'CUSTOMER', v_year, 'CUST', 6)
  on conflict on constraint document_sequences_scope_key do nothing;

  new.customer_code := app.next_document_number(new.dealer_id, null, 'CUSTOMER', v_year);
  return new;
end;
$$;

create trigger customers_assign_code
  before insert on public.customers
  for each row execute function app.customers_assign_code();

create trigger customers_set_updated_at
  before update on public.customers
  for each row execute function app.set_updated_at();

create trigger customers_audit
  after insert or update or delete on public.customers
  for each row execute function app.audit_trigger();

-- -----------------------------------------------------------------------------
-- Row Level Security
-- -----------------------------------------------------------------------------
alter table public.customers enable row level security;

create policy customers_select on public.customers
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('customers.view'))
  );

create policy customers_insert on public.customers
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('customers.create'))
  );

create policy customers_update on public.customers
  for update to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('customers.edit'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('customers.edit'))
  );

-- No DELETE policy. A customer with transactions behind them must never vanish;
-- set status to INACTIVE or BLOCKED instead.

-- -----------------------------------------------------------------------------
-- Indexes — spec §11 requires search by ID, mobile and name
-- -----------------------------------------------------------------------------
create index customers_dealer_name_idx   on public.customers (dealer_id, lower(name));
create index customers_dealer_status_idx on public.customers (dealer_id, status);
create index customers_alt_mobile_idx    on public.customers (dealer_id, alternate_mobile)
  where alternate_mobile is not null;
create index customers_gstin_idx         on public.customers (dealer_id, gstin) where gstin is not null;
create index customers_created_idx       on public.customers (dealer_id, created_at desc);
create index customers_origin_branch_idx on public.customers (origin_branch_id) where origin_branch_id is not null;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.customers to authenticated';
    execute 'grant all on public.customers to service_role';
    execute 'grant execute on function app.financial_year_token(uuid, date) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0014_tax_and_hsn.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0014 — Tax master: HSN/SAC codes and effective-dated tax codes
-- =============================================================================
-- Spec §16, §60.11. GST is configuration-driven: no rate is ever hard-coded in
-- UI or service logic. Rates are effective-dated, so a historical invoice keeps
-- the rate that applied on its date even after the master changes.
--
-- Rollback: drop table public.tax_codes, public.hsn_codes;
-- =============================================================================

create table public.hsn_codes (
  id          uuid primary key default gen_random_uuid(),
  dealer_id   uuid not null references public.dealers (id) on delete cascade,
  code        text not null,
  -- HSN for goods, SAC for services (labour).
  code_type   text not null default 'HSN',
  description text not null,
  status      text not null default 'ACTIVE',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid,
  updated_by  uuid,

  constraint hsn_dealer_code_key unique (dealer_id, code),
  constraint hsn_id_dealer_key   unique (id, dealer_id),
  constraint hsn_type_check   check (code_type in ('HSN', 'SAC')),
  constraint hsn_status_check check (status in ('ACTIVE', 'INACTIVE')),
  constraint hsn_code_check   check (code ~ '^[0-9]{4,8}$')
);

comment on table public.hsn_codes is 'HSN (goods) and SAC (services) codes, dealer-scoped (spec §16).';

-- -----------------------------------------------------------------------------
-- tax_codes — effective-dated GST rates
-- -----------------------------------------------------------------------------
-- The CGST/SGST split and the IGST rate are stored rather than derived, because
-- they are not always exactly half: cess and special rates exist. `total_rate` is
-- generated so it can never disagree with its components.
-- -----------------------------------------------------------------------------
create table public.tax_codes (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null references public.dealers (id) on delete cascade,

  code           text not null,
  name           text not null,
  hsn_code_id    uuid,

  cgst_rate      numeric(6, 3) not null default 0,
  sgst_rate      numeric(6, 3) not null default 0,
  igst_rate      numeric(6, 3) not null default 0,
  cess_rate      numeric(6, 3) not null default 0,

  -- Intra-state supply uses CGST + SGST; inter-state uses IGST.
  total_rate     numeric(6, 3) generated always as (cgst_rate + sgst_rate + cess_rate) stored,

  effective_from date not null,
  effective_to   date,

  status         text not null default 'ACTIVE',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid,
  updated_by     uuid,

  constraint tax_codes_id_dealer_key unique (id, dealer_id),
  constraint tax_codes_hsn_tenant_fkey
    foreign key (hsn_code_id, dealer_id) references public.hsn_codes (id, dealer_id),
  constraint tax_codes_code_check   check (code ~ '^[A-Z][A-Z0-9_]{1,30}$'),
  constraint tax_codes_status_check check (status in ('ACTIVE', 'INACTIVE')),
  constraint tax_codes_rates_check  check (
    cgst_rate >= 0 and sgst_rate >= 0 and igst_rate >= 0 and cess_rate >= 0
    and cgst_rate <= 50 and sgst_rate <= 50 and igst_rate <= 50
  ),
  -- IGST equals the intra-state total: 9+9 intra maps to 18 inter.
  constraint tax_codes_igst_matches_check check (igst_rate = cgst_rate + sgst_rate),
  constraint tax_codes_dates_check check (effective_to is null or effective_to >= effective_from)
);

comment on table public.tax_codes is
  'Effective-dated GST rates (spec §16). Invoices resolve the rate applicable on '
  'their document date, so history never changes when a rate is updated.';

-- One open-ended version per code: the current rate is unambiguous.
create unique index tax_codes_open_version_key
  on public.tax_codes (dealer_id, code)
  where effective_to is null;

create index tax_codes_lookup_idx on public.tax_codes (dealer_id, code, effective_from desc);
create index hsn_codes_dealer_idx on public.hsn_codes (dealer_id, status);

-- -----------------------------------------------------------------------------
-- app.resolve_tax_code() — the rate applicable to a document date
-- -----------------------------------------------------------------------------
-- Every taxed line resolves its rate through this function. Nothing else should
-- read tax_codes directly to pick a rate, or the effective-dating is bypassed.
-- -----------------------------------------------------------------------------
create or replace function public.resolve_tax_code(
  p_dealer_id uuid,
  p_code      text,
  p_on_date   date default current_date
)
returns table (
  tax_code_id uuid,
  code        text,
  cgst_rate   numeric(6, 3),
  sgst_rate   numeric(6, 3),
  igst_rate   numeric(6, 3),
  cess_rate   numeric(6, 3),
  total_rate  numeric(6, 3)
)
language sql
stable
as $$
  select t.id, t.code, t.cgst_rate, t.sgst_rate, t.igst_rate, t.cess_rate, t.total_rate
    from public.tax_codes t
   where t.dealer_id = p_dealer_id
     and t.code = p_code
     and t.status = 'ACTIVE'
     and t.effective_from <= p_on_date
     and (t.effective_to is null or t.effective_to >= p_on_date)
   order by t.effective_from desc
   limit 1;
$$;

comment on function public.resolve_tax_code(uuid, text, date) is
  'The tax rate in force for a code on a given date (spec §16). Used by every '
  'taxed document so historical invoices keep their original rates.';

create trigger hsn_codes_set_updated_at before update on public.hsn_codes
  for each row execute function app.set_updated_at();
create trigger tax_codes_set_updated_at before update on public.tax_codes
  for each row execute function app.set_updated_at();

create trigger hsn_codes_audit after insert or update or delete on public.hsn_codes
  for each row execute function app.audit_trigger();
-- Spec §46 lists GST changes explicitly among audited actions.
create trigger tax_codes_audit after insert or update or delete on public.tax_codes
  for each row execute function app.audit_trigger();

alter table public.hsn_codes enable row level security;
alter table public.tax_codes enable row level security;

create policy hsn_codes_select on public.hsn_codes for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('masters.hsn.view')));
create policy hsn_codes_write on public.hsn_codes for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('masters.hsn.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('masters.hsn.manage')));

create policy tax_codes_select on public.tax_codes for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('masters.tax.view')));
create policy tax_codes_write on public.tax_codes for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('masters.tax.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('masters.tax.manage')));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update, delete on public.hsn_codes, public.tax_codes to authenticated';
    execute 'grant all on public.hsn_codes, public.tax_codes to service_role';
    execute 'grant execute on function public.resolve_tax_code(uuid, text, date) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0015_vehicle_catalogue.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0015 — Vehicle catalogue: models, variants, colours
-- =============================================================================
-- Spec §13, §44. The catalogue is what a dealer *sells*; migration 0018 adds the
-- physical vehicles they *hold*. Keeping them apart is what makes chassis-level
-- stock possible (spec §60.8) — a model is a type, a vehicle is an object.
--
-- Rollback: drop table public.vehicle_colours, public.vehicle_variants, public.vehicle_models;
-- =============================================================================

create table public.vehicle_models (
  id            uuid primary key default gen_random_uuid(),
  dealer_id     uuid not null references public.dealers (id) on delete cascade,

  brand         text not null,
  name          text not null,
  model_code    text not null,
  -- Segment drives the dashboard's revenue-by-category split.
  category      text not null default 'SCOOTER',
  fuel_type     text not null default 'PETROL',

  hsn_code_id   uuid,
  tax_code      text,

  status        text not null default 'ACTIVE',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid,
  updated_by    uuid,

  constraint vehicle_models_dealer_code_key unique (dealer_id, model_code),
  constraint vehicle_models_id_dealer_key   unique (id, dealer_id),
  constraint vehicle_models_hsn_tenant_fkey
    foreign key (hsn_code_id, dealer_id) references public.hsn_codes (id, dealer_id),
  constraint vehicle_models_category_check check (
    category in ('SCOOTER', 'MOTORCYCLE', 'MOPED', 'ELECTRIC', 'THREE_WHEELER')
  ),
  constraint vehicle_models_fuel_check   check (fuel_type in ('PETROL', 'ELECTRIC', 'CNG', 'HYBRID')),
  constraint vehicle_models_status_check check (status in ('ACTIVE', 'DISCONTINUED')),
  constraint vehicle_models_code_check   check (model_code ~ '^[A-Z0-9][A-Z0-9._-]{1,29}$')
);

comment on table public.vehicle_models is 'Vehicle model master (spec §44). A type, not a physical unit.';

create table public.vehicle_variants (
  id           uuid primary key default gen_random_uuid(),
  dealer_id    uuid not null,
  model_id     uuid not null,

  name         text not null,
  variant_code text not null,
  -- Specification fields a dealer actually quotes on.
  engine_cc    numeric(6, 1),
  transmission text,
  brake_type   text,
  start_type   text,

  status       text not null default 'ACTIVE',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  created_by   uuid,
  updated_by   uuid,

  constraint vehicle_variants_dealer_code_key unique (dealer_id, variant_code),
  constraint vehicle_variants_id_dealer_key   unique (id, dealer_id),
  constraint vehicle_variants_model_tenant_fkey
    foreign key (model_id, dealer_id) references public.vehicle_models (id, dealer_id) on delete cascade,
  constraint vehicle_variants_status_check check (status in ('ACTIVE', 'DISCONTINUED')),
  constraint vehicle_variants_code_check   check (variant_code ~ '^[A-Z0-9][A-Z0-9._-]{1,29}$'),
  constraint vehicle_variants_cc_check     check (engine_cc is null or engine_cc between 0 and 2000)
);

comment on table public.vehicle_variants is 'Variant beneath a model (spec §44). Pricing attaches at this level.';

create table public.vehicle_colours (
  id          uuid primary key default gen_random_uuid(),
  dealer_id   uuid not null,
  variant_id  uuid not null,

  name        text not null,
  colour_code text,
  hex         text,

  status      text not null default 'ACTIVE',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint vehicle_colours_variant_name_key unique (variant_id, name),
  constraint vehicle_colours_id_dealer_key    unique (id, dealer_id),
  constraint vehicle_colours_variant_tenant_fkey
    foreign key (variant_id, dealer_id) references public.vehicle_variants (id, dealer_id) on delete cascade,
  constraint vehicle_colours_status_check check (status in ('ACTIVE', 'DISCONTINUED')),
  constraint vehicle_colours_hex_check    check (hex is null or hex ~ '^#[0-9A-Fa-f]{6}$')
);

create index vehicle_models_dealer_idx   on public.vehicle_models (dealer_id, status);
create index vehicle_models_brand_idx    on public.vehicle_models (dealer_id, brand);
create index vehicle_models_hsn_idx      on public.vehicle_models (hsn_code_id) where hsn_code_id is not null;
create index vehicle_variants_model_idx  on public.vehicle_variants (model_id, status);
create index vehicle_variants_dealer_idx on public.vehicle_variants (dealer_id, status);
create index vehicle_colours_variant_idx on public.vehicle_colours (variant_id, status);

create trigger vehicle_models_set_updated_at before update on public.vehicle_models
  for each row execute function app.set_updated_at();
create trigger vehicle_variants_set_updated_at before update on public.vehicle_variants
  for each row execute function app.set_updated_at();
create trigger vehicle_colours_set_updated_at before update on public.vehicle_colours
  for each row execute function app.set_updated_at();

create trigger vehicle_models_audit after insert or update or delete on public.vehicle_models
  for each row execute function app.audit_trigger();
create trigger vehicle_variants_audit after insert or update or delete on public.vehicle_variants
  for each row execute function app.audit_trigger();

alter table public.vehicle_models   enable row level security;
alter table public.vehicle_variants enable row level security;
alter table public.vehicle_colours  enable row level security;

do $$
declare t text;
begin
  foreach t in array array['vehicle_models', 'vehicle_variants', 'vehicle_colours'] loop
    execute format($f$
      create policy %1$s_select on public.%1$I for select to authenticated
        using (app.is_platform_admin()
               or (dealer_id = app.current_dealer_id() and app.has_permission('vehicles.models.view')))
    $f$, t);
    execute format($f$
      create policy %1$s_write on public.%1$I for all to authenticated
        using (app.is_platform_admin()
               or (dealer_id = app.current_dealer_id() and app.has_permission('vehicles.models.manage')))
        with check (app.is_platform_admin()
               or (dealer_id = app.current_dealer_id() and app.has_permission('vehicles.models.manage')))
    $f$, t);
  end loop;

  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update, delete on public.vehicle_models, public.vehicle_variants, public.vehicle_colours to authenticated';
    execute 'grant all on public.vehicle_models, public.vehicle_variants, public.vehicle_colours to service_role';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0016_inventory_items.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0016 — Accessory and spare item master, and finance companies
-- =============================================================================
-- Spec §28, §29, §25.
--
-- Accessories and spares share one table with an `item_type` discriminator: they
-- have identical structure and identical stock mechanics (spec §29, "same
-- architecture as accessories"), and one table means one stock ledger rather than
-- two that must be kept in step.
--
-- What must NOT be merged is LOCAL and COMPANY stock (spec §28, §60.16). That
-- separation lives on the stock rows in 0020, not here — the item is the same
-- product regardless of who supplied it; the lot is what differs.
--
-- Rollback: drop table public.finance_companies, public.inventory_items;
-- =============================================================================

create table public.inventory_items (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null references public.dealers (id) on delete cascade,

  item_code      text not null,
  name           text not null,
  item_type      text not null,

  brand          text,
  category       text,
  uom            text not null default 'NOS',

  hsn_code_id    uuid,
  tax_code       text,

  -- Indicative only. The cost that matters is on the stock lot (0020), because
  -- two lots of the same item can be bought at different prices.
  standard_cost  numeric(18, 4) not null default 0,
  selling_price  numeric(18, 4) not null default 0,

  reorder_level  numeric(14, 3) not null default 0,
  is_fitment     boolean not null default false,

  status         text not null default 'ACTIVE',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid,
  updated_by     uuid,

  constraint inventory_items_dealer_code_key unique (dealer_id, item_code),
  constraint inventory_items_id_dealer_key   unique (id, dealer_id),
  constraint inventory_items_hsn_tenant_fkey
    foreign key (hsn_code_id, dealer_id) references public.hsn_codes (id, dealer_id),
  constraint inventory_items_type_check   check (item_type in ('ACCESSORY', 'SPARE')),
  constraint inventory_items_status_check check (status in ('ACTIVE', 'INACTIVE')),
  constraint inventory_items_uom_check    check (uom in ('NOS', 'SET', 'PAIR', 'LTR', 'KG', 'MTR', 'BOX')),
  constraint inventory_items_code_check   check (item_code ~ '^[A-Z0-9][A-Z0-9._/-]{1,29}$'),
  constraint inventory_items_price_check  check (standard_cost >= 0 and selling_price >= 0),
  constraint inventory_items_reorder_check check (reorder_level >= 0)
);

comment on table public.inventory_items is
  'Accessory and spare master (spec §28, §29). LOCAL/COMPANY separation lives on '
  'the stock lots, not here — the item is the same product whoever supplied it.';
comment on column public.inventory_items.is_fitment is
  'Can be fitted to a vehicle at sale, making it eligible for the mapping in 0020.';

create index inventory_items_dealer_type_idx on public.inventory_items (dealer_id, item_type, status);
create index inventory_items_name_idx        on public.inventory_items (dealer_id, lower(name));
create index inventory_items_hsn_idx         on public.inventory_items (hsn_code_id) where hsn_code_id is not null;
create index inventory_items_fitment_idx     on public.inventory_items (dealer_id) where is_fitment;

-- =============================================================================
-- finance_companies — spec §25, §60. Each keeps a SEPARATE ledger.
-- =============================================================================
create table public.finance_companies (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null references public.dealers (id) on delete cascade,

  code              text not null,
  name              text not null,
  contact_person    text,
  mobile            text,
  email             text,

  gstin             text,
  -- The subsidiary ledger account this company's balance rolls up into.
  ledger_account_id uuid,

  commission_percent numeric(6, 3) not null default 0,
  status            text not null default 'ACTIVE',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid,
  updated_by        uuid,

  constraint finance_companies_dealer_code_key unique (dealer_id, code),
  constraint finance_companies_id_dealer_key   unique (id, dealer_id),
  constraint finance_companies_account_tenant_fkey
    foreign key (ledger_account_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint finance_companies_status_check check (status in ('ACTIVE', 'INACTIVE')),
  constraint finance_companies_code_check   check (code ~ '^[A-Z0-9][A-Z0-9._-]{1,29}$'),
  constraint finance_companies_commission_check check (commission_percent between 0 and 100),
  constraint finance_companies_gstin_check check (
    gstin is null or gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[0-9A-Z]{1}Z[0-9A-Z]{1}$'
  ),
  constraint finance_companies_mobile_check check (mobile is null or mobile ~ '^[6-9][0-9]{9}$')
);

comment on table public.finance_companies is
  'Finance companies (spec §25). Balances are never combined into one generic '
  'figure — each company has its own ledger account and its own running balance.';

create index finance_companies_dealer_idx  on public.finance_companies (dealer_id, status);
create index finance_companies_account_idx on public.finance_companies (ledger_account_id)
  where ledger_account_id is not null;

create trigger inventory_items_set_updated_at before update on public.inventory_items
  for each row execute function app.set_updated_at();
create trigger finance_companies_set_updated_at before update on public.finance_companies
  for each row execute function app.set_updated_at();

create trigger inventory_items_audit after insert or update or delete on public.inventory_items
  for each row execute function app.audit_trigger();
create trigger finance_companies_audit after insert or update or delete on public.finance_companies
  for each row execute function app.audit_trigger();

alter table public.inventory_items    enable row level security;
alter table public.finance_companies  enable row level security;

create policy inventory_items_select on public.inventory_items for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('inventory.view')));
create policy inventory_items_write on public.inventory_items for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('inventory.items.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('inventory.items.manage')));

create policy finance_companies_select on public.finance_companies for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('finance.companies.view')));
create policy finance_companies_write on public.finance_companies for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('finance.companies.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('finance.companies.manage')));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update, delete on public.inventory_items, public.finance_companies to authenticated';
    execute 'grant all on public.inventory_items, public.finance_companies to service_role';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0017_vehicle_stock.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0017 — Vehicle stock: chassis-level inventory and transfers
-- =============================================================================
-- Spec §13, §35, §60.8. "Never represent vehicle inventory only as quantity.
-- Every physical vehicle must be individually traceable."
--
-- So there is no quantity column anywhere here. One row is one motorcycle, with
-- its own chassis number, its own purchase cost, and its own status. Stock counts
-- are derived by counting rows.
--
-- Concurrency (spec §49): two cashiers must not sell the same chassis. The status
-- transition is guarded by a trigger, and the sale path takes SELECT ... FOR
-- UPDATE on the row, so the second attempt blocks and then fails the check.
--
-- Rollback: drop table public.vehicle_transfers, public.vehicle_stock_transactions,
--           public.vehicles;
-- =============================================================================

create table public.vehicles (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null references public.dealers (id) on delete restrict,
  branch_id         uuid not null,

  model_id          uuid not null,
  variant_id        uuid,
  colour_id         uuid,

  -- The physical identity of the unit. Chassis is globally unique per dealer.
  chassis_no        text not null,
  engine_no         text not null,
  key_no            text,
  model_year        smallint,

  purchase_invoice  text,
  purchase_date     date,
  purchase_cost     numeric(18, 4) not null default 0,
  stock_date        date not null default current_date,

  status            text not null default 'IN_STOCK',

  -- Set once the vehicle leaves stock; lets a sale be traced from the unit.
  sale_id           uuid,
  registration_no   text,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid,
  updated_by        uuid,

  constraint vehicles_dealer_chassis_key unique (dealer_id, chassis_no),
  constraint vehicles_dealer_engine_key  unique (dealer_id, engine_no),
  constraint vehicles_id_dealer_key      unique (id, dealer_id),
  constraint vehicles_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint vehicles_model_tenant_fkey
    foreign key (model_id, dealer_id) references public.vehicle_models (id, dealer_id),
  constraint vehicles_variant_tenant_fkey
    foreign key (variant_id, dealer_id) references public.vehicle_variants (id, dealer_id),
  constraint vehicles_colour_tenant_fkey
    foreign key (colour_id, dealer_id) references public.vehicle_colours (id, dealer_id),

  constraint vehicles_status_check check (status in (
    'IN_STOCK', 'BOOKED', 'SOLD_PENDING_DELIVERY', 'DELIVERED', 'TRANSFERRED', 'CANCELLED'
  )),
  constraint vehicles_cost_check     check (purchase_cost >= 0),
  constraint vehicles_chassis_check  check (chassis_no ~ '^[A-Z0-9]{6,25}$'),
  constraint vehicles_engine_check   check (engine_no ~ '^[A-Z0-9]{6,25}$'),
  constraint vehicles_year_check     check (model_year is null or model_year between 1980 and 2100)
);

comment on table public.vehicles is
  'Chassis-level vehicle stock (spec §13, §60.8). One row is one physical vehicle. '
  'There is deliberately no quantity column.';

-- Registration numbers are unique once assigned.
create unique index vehicles_registration_key
  on public.vehicles (dealer_id, registration_no)
  where registration_no is not null;

create index vehicles_branch_status_idx on public.vehicles (branch_id, status);
create index vehicles_dealer_status_idx on public.vehicles (dealer_id, status);
create index vehicles_model_idx         on public.vehicles (model_id, status);
create index vehicles_variant_idx       on public.vehicles (variant_id) where variant_id is not null;
create index vehicles_colour_idx        on public.vehicles (colour_id) where colour_id is not null;
-- Stock ageing: how long has this unit been sitting (spec §41).
create index vehicles_ageing_idx        on public.vehicles (dealer_id, stock_date) where status = 'IN_STOCK';
create index vehicles_sale_idx          on public.vehicles (sale_id) where sale_id is not null;

-- -----------------------------------------------------------------------------
-- Status transitions
-- -----------------------------------------------------------------------------
-- A vehicle's life runs one way. Encoding the legal moves here means no service,
-- however buggy, can put a DELIVERED unit back into stock and sell it twice.
-- -----------------------------------------------------------------------------
create or replace function app.vehicles_guard_status()
returns trigger
language plpgsql
as $$
declare
  v_allowed text[];
begin
  if tg_op = 'INSERT' then
    if new.status <> 'IN_STOCK' then
      raise exception 'A vehicle enters stock as IN_STOCK, not %.', new.status
        using errcode = 'check_violation';
    end if;
    return new;
  end if;

  if new.status = old.status then
    return new;
  end if;

  v_allowed := case old.status
    when 'IN_STOCK'              then array['BOOKED', 'SOLD_PENDING_DELIVERY', 'TRANSFERRED', 'CANCELLED']
    when 'BOOKED'                then array['IN_STOCK', 'SOLD_PENDING_DELIVERY', 'CANCELLED']
    when 'SOLD_PENDING_DELIVERY' then array['DELIVERED', 'IN_STOCK', 'CANCELLED']
    when 'TRANSFERRED'           then array['IN_STOCK', 'CANCELLED']
    -- Terminal. A delivered vehicle is the customer's; a cancelled one is out.
    when 'DELIVERED'             then array[]::text[]
    when 'CANCELLED'             then array[]::text[]
    else array[]::text[]
  end;

  if not (new.status = any (v_allowed)) then
    raise exception 'Vehicle % cannot move from % to %.', old.chassis_no, old.status, new.status
      using errcode = 'check_violation',
            hint = 'Spec §13 defines the vehicle status lifecycle.';
  end if;

  return new;
end;
$$;

create trigger vehicles_guard_status
  before insert or update on public.vehicles
  for each row execute function app.vehicles_guard_status();

-- -----------------------------------------------------------------------------
-- vehicle_stock_transactions — immutable movement log (spec §34)
-- -----------------------------------------------------------------------------
create table public.vehicle_stock_transactions (
  id               bigint generated always as identity primary key,
  dealer_id        uuid not null,
  branch_id        uuid not null,
  vehicle_id       uuid not null,

  transaction_type text not null,
  reference_type   text,
  reference_id     uuid,

  from_status      text,
  to_status        text,
  from_branch_id   uuid,
  to_branch_id     uuid,

  value            numeric(18, 4) not null default 0,
  narration        text,

  created_at       timestamptz not null default now(),
  created_by       uuid,

  constraint vst_vehicle_tenant_fkey
    foreign key (vehicle_id, dealer_id) references public.vehicles (id, dealer_id) on delete cascade,
  constraint vst_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint vst_type_check check (transaction_type in (
    'OPENING', 'PURCHASE', 'SALE', 'RETURN',
    'TRANSFER_OUT', 'TRANSFER_IN', 'ADJUSTMENT', 'REVERSAL', 'STATUS_CHANGE'
  ))
);

comment on table public.vehicle_stock_transactions is
  'Append-only vehicle movement log (spec §34). Never updated, never deleted.';

create trigger vehicle_stock_transactions_append_only
  before update or delete on public.vehicle_stock_transactions
  for each row execute function app.forbid_mutation();

create index vst_vehicle_idx     on public.vehicle_stock_transactions (vehicle_id, created_at desc);
create index vst_dealer_time_idx on public.vehicle_stock_transactions (dealer_id, created_at desc);
create index vst_branch_time_idx on public.vehicle_stock_transactions (branch_id, created_at desc);
create index vst_reference_idx   on public.vehicle_stock_transactions (reference_type, reference_id)
  where reference_id is not null;

-- Every status change writes a movement row automatically, so the log cannot be
-- forgotten by a caller.
create or replace function app.vehicles_log_movement()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.vehicle_stock_transactions
      (dealer_id, branch_id, vehicle_id, transaction_type, to_status, to_branch_id, value, created_by)
    values (new.dealer_id, new.branch_id, new.id, 'PURCHASE', new.status, new.branch_id,
            new.purchase_cost, new.created_by);
    return null;
  end if;

  if new.status is distinct from old.status or new.branch_id is distinct from old.branch_id then
    insert into public.vehicle_stock_transactions
      (dealer_id, branch_id, vehicle_id, transaction_type,
       from_status, to_status, from_branch_id, to_branch_id, value, created_by)
    values (new.dealer_id, new.branch_id, new.id,
            case when new.branch_id is distinct from old.branch_id then 'TRANSFER_IN' else 'STATUS_CHANGE' end,
            old.status, new.status, old.branch_id, new.branch_id, new.purchase_cost, new.updated_by);
  end if;

  return null;
end;
$$;

create trigger vehicles_log_movement
  after insert or update on public.vehicles
  for each row execute function app.vehicles_log_movement();

-- -----------------------------------------------------------------------------
-- vehicle_transfers — branch to branch, with an in-transit state (spec §35)
-- -----------------------------------------------------------------------------
create table public.vehicle_transfers (
  id              uuid primary key default gen_random_uuid(),
  dealer_id       uuid not null references public.dealers (id) on delete restrict,

  transfer_number text not null,
  vehicle_id      uuid not null,
  from_branch_id  uuid not null,
  to_branch_id    uuid not null,

  status          text not null default 'IN_TRANSIT',
  dispatched_at   timestamptz not null default now(),
  dispatched_by   uuid,
  received_at     timestamptz,
  received_by     uuid,
  remarks         text,

  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint vehicle_transfers_number_key unique (dealer_id, transfer_number),
  constraint vehicle_transfers_id_dealer_key unique (id, dealer_id),
  constraint vehicle_transfers_vehicle_tenant_fkey
    foreign key (vehicle_id, dealer_id) references public.vehicles (id, dealer_id),
  constraint vehicle_transfers_from_tenant_fkey
    foreign key (from_branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint vehicle_transfers_to_tenant_fkey
    foreign key (to_branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint vehicle_transfers_status_check check (status in ('IN_TRANSIT', 'RECEIVED', 'CANCELLED')),
  constraint vehicle_transfers_branches_differ_check check (from_branch_id <> to_branch_id),
  constraint vehicle_transfers_received_check check (
    status <> 'RECEIVED' or received_at is not null
  )
);

create index vehicle_transfers_vehicle_idx on public.vehicle_transfers (vehicle_id);
create index vehicle_transfers_status_idx  on public.vehicle_transfers (dealer_id, status);
create index vehicle_transfers_to_idx      on public.vehicle_transfers (to_branch_id, status);

create trigger vehicles_set_updated_at before update on public.vehicles
  for each row execute function app.set_updated_at();
create trigger vehicle_transfers_set_updated_at before update on public.vehicle_transfers
  for each row execute function app.set_updated_at();

create trigger vehicles_audit after insert or update or delete on public.vehicles
  for each row execute function app.audit_trigger();
create trigger vehicle_transfers_audit after insert or update or delete on public.vehicle_transfers
  for each row execute function app.audit_trigger();

alter table public.vehicles                   enable row level security;
alter table public.vehicle_stock_transactions enable row level security;
alter table public.vehicle_transfers          enable row level security;

create policy vehicles_select on public.vehicles for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and app.can_access_branch(branch_id)
             and app.has_permission('vehicles.stock.view')));

create policy vehicles_insert on public.vehicles for insert to authenticated
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('vehicles.stock.upload')));

create policy vehicles_update on public.vehicles for update to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('vehicles.stock.adjust') or app.has_permission('sales.create'))))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('vehicles.stock.adjust') or app.has_permission('sales.create'))));

-- Movement history is read-only from a session; rows come from the trigger.
create policy vst_select on public.vehicle_stock_transactions for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('vehicles.stock.view')));

create policy vehicle_transfers_select on public.vehicle_transfers for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('vehicles.transfers.view')));
create policy vehicle_transfers_write on public.vehicle_transfers for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('vehicles.transfers.manage')))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('vehicles.transfers.manage')));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.vehicles to authenticated';
    execute 'grant select on public.vehicle_stock_transactions to authenticated';
    execute 'grant select, insert, update on public.vehicle_transfers to authenticated';
    execute 'grant all on public.vehicles, public.vehicle_stock_transactions, public.vehicle_transfers to service_role';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0018_vehicle_pricing.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0018 — Vehicle pricing: effective-dated versions
-- =============================================================================
-- Spec §15, §17, §42, §60.9, §60.10. The central rule: "Do NOT update one price
-- field and destroy history."
--
-- A price is therefore never edited in place. Each change creates a new version
-- with its own effective_from, and a sale records the version id it used. Asking
-- "what was the price on that date?" (spec §42) becomes a lookup, not a guess —
-- and it stays answerable even after ten more price changes.
--
-- Rollback: drop table public.vehicle_price_versions;
-- =============================================================================

create table public.vehicle_price_versions (
  id                    uuid primary key default gen_random_uuid(),
  dealer_id             uuid not null references public.dealers (id) on delete cascade,

  model_id              uuid not null,
  variant_id            uuid,
  -- NULL means the price applies dealer-wide; a branch may override.
  branch_id             uuid,

  version_number        integer not null,

  -- Components, spec §15. Held separately because the invoice itemises them and
  -- because each maps to a different ledger account at posting.
  ex_showroom           numeric(18, 4) not null default 0,
  insurance             numeric(18, 4) not null default 0,
  registration          numeric(18, 4) not null default 0,  -- LTRT
  mandatory_accessories numeric(18, 4) not null default 0,
  forwarding_charge     numeric(18, 4) not null default 0,
  other_charges         numeric(18, 4) not null default 0,

  -- What the dealer paid. Restricted: only roles with vehicles.view_cost see it.
  purchase_cost         numeric(18, 4) not null default 0,

  max_discount          numeric(18, 4) not null default 0,
  tax_code              text,

  total_on_road         numeric(18, 4) generated always as (
    ex_showroom + insurance + registration + mandatory_accessories
    + forwarding_charge + other_charges
  ) stored,

  effective_from        date not null,
  effective_to          date,

  -- Spec §15 offers an optional approval flow; it is implemented.
  status                text not null default 'DRAFT',
  submitted_at          timestamptz,
  submitted_by          uuid,
  approved_at           timestamptz,
  approved_by           uuid,

  notes                 text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  created_by            uuid,
  updated_by            uuid,

  constraint vpv_id_dealer_key unique (id, dealer_id),
  constraint vpv_model_tenant_fkey
    foreign key (model_id, dealer_id) references public.vehicle_models (id, dealer_id) on delete cascade,
  constraint vpv_variant_tenant_fkey
    foreign key (variant_id, dealer_id) references public.vehicle_variants (id, dealer_id) on delete cascade,
  constraint vpv_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),

  constraint vpv_status_check check (status in ('DRAFT', 'SUBMITTED', 'APPROVED', 'ACTIVE', 'SUPERSEDED', 'REJECTED')),
  constraint vpv_amounts_check check (
    ex_showroom >= 0 and insurance >= 0 and registration >= 0
    and mandatory_accessories >= 0 and forwarding_charge >= 0 and other_charges >= 0
    and purchase_cost >= 0 and max_discount >= 0
  ),
  constraint vpv_dates_check   check (effective_to is null or effective_to >= effective_from),
  constraint vpv_version_check check (version_number > 0),
  constraint vpv_approved_check check (status not in ('APPROVED', 'ACTIVE') or approved_at is not null)
);

comment on table public.vehicle_price_versions is
  'Effective-dated vehicle prices (spec §15). Never updated in place: a change is '
  'a new version, and a sale records the version it used (spec §42, §60.9).';
comment on column public.vehicle_price_versions.purchase_cost is
  'Restricted. Withheld from roles lacking vehicles.view_cost (spec §52).';

-- One live price per scope. The partial unique index is what makes "the current
-- price" a single unambiguous row rather than a judgement call.
create unique index vpv_active_scope_key
  on public.vehicle_price_versions (dealer_id, model_id, coalesce(variant_id, '00000000-0000-0000-0000-000000000000'::uuid), coalesce(branch_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where status = 'ACTIVE';

create unique index vpv_version_key
  on public.vehicle_price_versions (dealer_id, model_id, coalesce(variant_id, '00000000-0000-0000-0000-000000000000'::uuid), coalesce(branch_id, '00000000-0000-0000-0000-000000000000'::uuid), version_number);

create index vpv_lookup_idx on public.vehicle_price_versions (dealer_id, model_id, effective_from desc);
create index vpv_variant_idx on public.vehicle_price_versions (variant_id) where variant_id is not null;
create index vpv_status_idx  on public.vehicle_price_versions (dealer_id, status);

-- -----------------------------------------------------------------------------
-- Immutability once ACTIVE
-- -----------------------------------------------------------------------------
-- An ACTIVE version has been used to price real invoices. Editing it would
-- rewrite what those invoices claim to have charged, which spec §60.10 forbids.
-- -----------------------------------------------------------------------------
create or replace function app.vpv_guard()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    if old.status in ('ACTIVE', 'SUPERSEDED') then
      raise exception 'Price version % is % and cannot be deleted.', old.version_number, old.status
        using errcode = 'insufficient_privilege',
              hint = 'Spec §60.9: price history is immutable. Supersede it with a new version.';
    end if;
    return old;
  end if;

  if tg_op = 'UPDATE' and old.status in ('ACTIVE', 'SUPERSEDED') then
    -- Only the lifecycle columns may move: an active version becomes superseded
    -- when a newer one takes over, and nothing else about it may change.
    --
    -- The immutable columns are listed explicitly rather than compared with
    -- `to_jsonb(new) - 'status' - ...`. A BEFORE trigger does not see generated
    -- columns populated in NEW, so `total_on_road` would always read as changed
    -- and every update would be rejected.
    if new.ex_showroom           is distinct from old.ex_showroom
    or new.insurance             is distinct from old.insurance
    or new.registration          is distinct from old.registration
    or new.mandatory_accessories is distinct from old.mandatory_accessories
    or new.forwarding_charge     is distinct from old.forwarding_charge
    or new.other_charges         is distinct from old.other_charges
    or new.purchase_cost         is distinct from old.purchase_cost
    or new.max_discount          is distinct from old.max_discount
    or new.tax_code              is distinct from old.tax_code
    or new.effective_from        is distinct from old.effective_from
    or new.model_id              is distinct from old.model_id
    or new.variant_id            is distinct from old.variant_id
    or new.branch_id             is distinct from old.branch_id
    or new.version_number        is distinct from old.version_number then
      raise exception 'Price version % is % and its amounts are immutable.', old.version_number, old.status
        using errcode = 'insufficient_privilege',
              hint = 'Create a new version instead of editing this one (spec §15).';
    end if;
  end if;

  return new;
end;
$$;

create trigger vpv_guard
  before update or delete on public.vehicle_price_versions
  for each row execute function app.vpv_guard();

-- -----------------------------------------------------------------------------
-- public.resolve_vehicle_price() — the price in force on a date
-- -----------------------------------------------------------------------------
-- Resolution order is most-specific-first: a branch+variant price beats a
-- dealer-wide model price. Sales call this and store the returned id, so the
-- invoice remains explainable years later.
-- -----------------------------------------------------------------------------
create or replace function public.resolve_vehicle_price(
  p_dealer_id  uuid,
  p_model_id   uuid,
  p_variant_id uuid default null,
  p_branch_id  uuid default null,
  p_on_date    date default current_date
)
returns table (
  price_version_id      uuid,
  version_number        integer,
  ex_showroom           numeric(18, 4),
  insurance             numeric(18, 4),
  registration          numeric(18, 4),
  mandatory_accessories numeric(18, 4),
  forwarding_charge     numeric(18, 4),
  other_charges         numeric(18, 4),
  total_on_road         numeric(18, 4),
  max_discount          numeric(18, 4),
  tax_code              text
)
language sql
stable
as $$
  select v.id, v.version_number, v.ex_showroom, v.insurance, v.registration,
         v.mandatory_accessories, v.forwarding_charge, v.other_charges,
         v.total_on_road, v.max_discount, v.tax_code
    from public.vehicle_price_versions v
   where v.dealer_id = p_dealer_id
     and v.model_id = p_model_id
     and v.status in ('ACTIVE', 'SUPERSEDED')
     and v.effective_from <= p_on_date
     and (v.effective_to is null or v.effective_to >= p_on_date)
     and (v.variant_id is null or v.variant_id = p_variant_id)
     and (v.branch_id  is null or v.branch_id  = p_branch_id)
   order by
     -- Most specific scope wins, then the most recent effective date.
     (v.branch_id  is not null) desc,
     (v.variant_id is not null) desc,
     v.effective_from desc,
     v.version_number desc
   limit 1;
$$;

comment on function public.resolve_vehicle_price(uuid, uuid, uuid, uuid, date) is
  'The price in force for a model/variant/branch on a date (spec §15, §42). '
  'Historical invoices resolve their original price through this, never through '
  'the current master.';

create trigger vpv_set_updated_at before update on public.vehicle_price_versions
  for each row execute function app.set_updated_at();

-- Price changes are explicitly audited (spec §46).
create trigger vpv_audit after insert or update or delete on public.vehicle_price_versions
  for each row execute function app.audit_trigger();

alter table public.vehicle_price_versions enable row level security;

create policy vpv_select on public.vehicle_price_versions for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('vehicles.pricing.view')));

create policy vpv_insert on public.vehicle_price_versions for insert to authenticated
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('vehicles.pricing.manage')));

create policy vpv_update on public.vehicle_price_versions for update to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('vehicles.pricing.manage') or app.has_permission('vehicles.pricing.approve'))))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('vehicles.pricing.manage') or app.has_permission('vehicles.pricing.approve'))));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.vehicle_price_versions to authenticated';
    execute 'grant all on public.vehicle_price_versions to service_role';
    execute 'grant execute on function public.resolve_vehicle_price(uuid, uuid, uuid, uuid, date) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0019_inventory_stock.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0019 — Accessory and spare stock: lots, ledger, fitment mapping
-- =============================================================================
-- Spec §28, §29, §30, §31, §34, §60.16, §60.17, §60.22.
--
-- The rule that shapes this file: LOCAL and COMPANY stock must stay separately
-- traceable and must never be merged. So the stock row is keyed by
-- (item, branch, source) — three lots of the same item at the same branch cannot
-- exist, but a LOCAL lot and a COMPANY lot can, and they hold their own
-- quantities and their own costs.
--
-- Quantity is maintained by trigger from the ledger, never written directly
-- (spec §34, §60.22: "No silent stock adjustments"). Every movement leaves a row.
--
-- Rollback: drop table public.accessory_vehicle_mappings, public.inventory_transactions,
--           public.inventory_stock;
-- =============================================================================

create table public.inventory_stock (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null references public.dealers (id) on delete cascade,
  branch_id      uuid not null,
  item_id        uuid not null,

  -- The separation spec §60.16 requires. Part of the key, not an attribute.
  source         text not null,

  quantity       numeric(14, 3) not null default 0,
  -- Weighted average cost for this lot. Recomputed on receipt, held on issue.
  average_cost   numeric(18, 4) not null default 0,
  stock_value    numeric(18, 4) generated always as (quantity * average_cost) stored,

  updated_at     timestamptz not null default now(),

  constraint inventory_stock_lot_key unique (item_id, branch_id, source),
  constraint inventory_stock_id_dealer_key unique (id, dealer_id),
  constraint inventory_stock_item_tenant_fkey
    foreign key (item_id, dealer_id) references public.inventory_items (id, dealer_id) on delete cascade,
  constraint inventory_stock_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint inventory_stock_source_check check (source in ('LOCAL', 'COMPANY')),
  constraint inventory_stock_cost_check   check (average_cost >= 0)
);

comment on table public.inventory_stock is
  'One row per item / branch / source lot (spec §28, §60.16). LOCAL and COMPANY '
  'are never merged. Quantity is maintained by trigger from inventory_transactions.';

create index inventory_stock_branch_idx on public.inventory_stock (branch_id, item_id);
create index inventory_stock_item_idx   on public.inventory_stock (item_id);
create index inventory_stock_dealer_idx on public.inventory_stock (dealer_id);
create index inventory_stock_onhand_idx on public.inventory_stock (dealer_id, branch_id) where quantity > 0;

-- =============================================================================
-- inventory_transactions — the immutable stock ledger (spec §34)
-- =============================================================================
create table public.inventory_transactions (
  id               bigint generated always as identity primary key,
  dealer_id        uuid not null,
  branch_id        uuid not null,
  item_id          uuid not null,
  source           text not null,

  transaction_type text not null,

  -- Signed: positive receives, negative issues. One column rather than separate
  -- in/out columns, so the running balance is a plain sum.
  quantity         numeric(14, 3) not null,
  unit_cost        numeric(18, 4) not null default 0,
  value            numeric(18, 4) generated always as (quantity * unit_cost) stored,

  -- Balance after this movement, for a ledger view that needs no window function.
  balance_after    numeric(14, 3) not null default 0,

  reference_type   text,
  reference_id     uuid,
  reference_number text,
  narration        text,
  reason           text,

  created_at       timestamptz not null default now(),
  created_by       uuid,

  constraint inventory_transactions_item_tenant_fkey
    foreign key (item_id, dealer_id) references public.inventory_items (id, dealer_id) on delete cascade,
  constraint inventory_transactions_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint inventory_transactions_source_check check (source in ('LOCAL', 'COMPANY')),
  constraint inventory_transactions_type_check check (transaction_type in (
    'OPENING', 'PURCHASE', 'SALE', 'CONSUMPTION', 'RETURN',
    'TRANSFER_OUT', 'TRANSFER_IN', 'ADJUSTMENT', 'REVERSAL'
  )),
  constraint inventory_transactions_quantity_check check (quantity <> 0),
  constraint inventory_transactions_cost_check check (unit_cost >= 0),
  -- An adjustment must say why (spec §60.22).
  constraint inventory_transactions_adjustment_reason_check check (
    transaction_type <> 'ADJUSTMENT' or reason is not null
  )
);

comment on table public.inventory_transactions is
  'Append-only stock ledger (spec §34). Current stock is derived from these rows; '
  'quantities are never overwritten directly.';

create trigger inventory_transactions_append_only
  before update or delete on public.inventory_transactions
  for each row execute function app.forbid_mutation();

create index it_item_time_idx    on public.inventory_transactions (item_id, created_at desc);
create index it_branch_time_idx  on public.inventory_transactions (branch_id, created_at desc);
create index it_dealer_time_idx  on public.inventory_transactions (dealer_id, created_at desc);
create index it_reference_idx    on public.inventory_transactions (reference_type, reference_id)
  where reference_id is not null;
create index it_lot_idx          on public.inventory_transactions (item_id, branch_id, source, created_at desc);

-- -----------------------------------------------------------------------------
-- The ledger drives the stock row, not the other way round
-- -----------------------------------------------------------------------------
-- BEFORE INSERT so balance_after is computed under the same row lock that updates
-- the lot. Two concurrent issues of the same item serialise here, which is what
-- stops a race from overselling (spec §49).
-- -----------------------------------------------------------------------------
create or replace function app.inventory_apply_movement()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_stock      public.inventory_stock;
  v_new_qty    numeric(14, 3);
  v_new_cost   numeric(18, 4);
  v_allow_neg  boolean;
begin
  -- Lock the lot for the rest of this transaction, creating it if absent.
  insert into public.inventory_stock (dealer_id, branch_id, item_id, source, quantity, average_cost)
  values (new.dealer_id, new.branch_id, new.item_id, new.source, 0, 0)
  on conflict on constraint inventory_stock_lot_key do nothing;

  select * into v_stock
    from public.inventory_stock
   where item_id = new.item_id and branch_id = new.branch_id and source = new.source
     for update;

  v_new_qty := v_stock.quantity + new.quantity;

  if v_new_qty < 0 then
    select coalesce((value)::text = 'true', false) into v_allow_neg
      from public.system_settings
     where key = 'inventory.allow_negative_stock'
       and (dealer_id = new.dealer_id or dealer_id is null)
     order by dealer_id nulls last
     limit 1;

    if not coalesce(v_allow_neg, false) then
      raise exception
        'Insufficient % stock: % available, % requested.',
        new.source, v_stock.quantity, abs(new.quantity)
        using errcode = 'check_violation',
              hint = 'Spec §33: stock cannot go negative unless explicitly configured.';
    end if;
  end if;

  -- Weighted average, recomputed only on receipt. An issue leaves cost alone, so
  -- COGS uses the cost the stock was actually carried at.
  if new.quantity > 0 and new.unit_cost > 0 then
    v_new_cost := case
      when v_new_qty = 0 then v_stock.average_cost
      else round(((v_stock.quantity * v_stock.average_cost) + (new.quantity * new.unit_cost)) / v_new_qty, 4)
    end;
  else
    v_new_cost := v_stock.average_cost;
    if new.quantity < 0 and new.unit_cost = 0 then
      new.unit_cost := v_stock.average_cost;   -- issue at carrying cost
    end if;
  end if;

  update public.inventory_stock
     set quantity = v_new_qty,
         average_cost = v_new_cost,
         updated_at = now()
   where id = v_stock.id;

  new.balance_after := v_new_qty;
  return new;
end;
$$;

create trigger inventory_apply_movement
  before insert on public.inventory_transactions
  for each row execute function app.inventory_apply_movement();

-- =============================================================================
-- accessory_vehicle_mappings — fitment templates (spec §30)
-- =============================================================================
create table public.accessory_vehicle_mappings (
  id          uuid primary key default gen_random_uuid(),
  dealer_id   uuid not null references public.dealers (id) on delete cascade,

  model_id    uuid not null,
  variant_id  uuid,
  item_id     uuid not null,

  quantity    numeric(14, 3) not null default 1,
  -- Whether the fitting is offered by default when "extra fittings?" is answered yes.
  is_default  boolean not null default true,
  priority    smallint not null default 100,

  status      text not null default 'ACTIVE',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint avm_scope_key unique nulls not distinct (model_id, variant_id, item_id),
  constraint avm_model_tenant_fkey
    foreign key (model_id, dealer_id) references public.vehicle_models (id, dealer_id) on delete cascade,
  constraint avm_variant_tenant_fkey
    foreign key (variant_id, dealer_id) references public.vehicle_variants (id, dealer_id) on delete cascade,
  constraint avm_item_tenant_fkey
    foreign key (item_id, dealer_id) references public.inventory_items (id, dealer_id) on delete cascade,
  constraint avm_quantity_check check (quantity > 0),
  constraint avm_status_check   check (status in ('ACTIVE', 'INACTIVE'))
);

comment on table public.accessory_vehicle_mappings is
  'Which accessories are fitted to which model (spec §30). Drives the automatic '
  'fitting allocation at sale, which must remain auditable (spec §60.17).';

create index avm_model_idx on public.accessory_vehicle_mappings (model_id, status);
create index avm_item_idx  on public.accessory_vehicle_mappings (item_id);

-- -----------------------------------------------------------------------------
-- public.allocate_stock() — LOCAL before COMPANY (spec §31)
-- -----------------------------------------------------------------------------
-- Returns the split without consuming anything, so a sale screen can show the
-- customer exactly where the stock is coming from before committing. The actual
-- consumption inserts one ledger row per source, which is what makes the
-- allocation auditable rather than hidden (spec §31, "Never hide the source").
-- -----------------------------------------------------------------------------
create or replace function public.allocate_stock(
  p_item_id   uuid,
  p_branch_id uuid,
  p_quantity  numeric
)
returns table (source text, quantity numeric, unit_cost numeric, available numeric)
language plpgsql
stable
as $$
declare
  v_needed numeric := p_quantity;
  v_local  numeric := 0;
  v_lcost  numeric := 0;
  v_comp   numeric := 0;
  v_ccost  numeric := 0;
  v_take   numeric;
begin
  select coalesce(s.quantity, 0), coalesce(s.average_cost, 0) into v_local, v_lcost
    from public.inventory_stock s
   where s.item_id = p_item_id and s.branch_id = p_branch_id and s.source = 'LOCAL';

  select coalesce(s.quantity, 0), coalesce(s.average_cost, 0) into v_comp, v_ccost
    from public.inventory_stock s
   where s.item_id = p_item_id and s.branch_id = p_branch_id and s.source = 'COMPANY';

  v_local := coalesce(v_local, 0);
  v_comp  := coalesce(v_comp, 0);

  -- Rule 1: consume LOCAL first.
  if v_needed > 0 and v_local > 0 then
    v_take := least(v_needed, v_local);
    source := 'LOCAL'; quantity := v_take; unit_cost := v_lcost; available := v_local;
    return next;
    v_needed := v_needed - v_take;
  end if;

  -- Rule 2: fall through to COMPANY for the remainder.
  if v_needed > 0 and v_comp > 0 then
    v_take := least(v_needed, v_comp);
    source := 'COMPANY'; quantity := v_take; unit_cost := v_ccost; available := v_comp;
    return next;
    v_needed := v_needed - v_take;
  end if;

  -- Rule 3: report the shortfall rather than silently under-allocating.
  if v_needed > 0 then
    source := 'SHORTFALL'; quantity := v_needed; unit_cost := 0; available := v_local + v_comp;
    return next;
  end if;
end;
$$;

comment on function public.allocate_stock(uuid, uuid, numeric) is
  'Splits a required quantity across LOCAL then COMPANY stock (spec §31). Returns '
  'a SHORTFALL row when stock is insufficient rather than partially allocating.';

create trigger inventory_stock_set_updated_at before update on public.inventory_stock
  for each row execute function app.set_updated_at();
create trigger avm_set_updated_at before update on public.accessory_vehicle_mappings
  for each row execute function app.set_updated_at();
create trigger avm_audit after insert or update or delete on public.accessory_vehicle_mappings
  for each row execute function app.audit_trigger();

alter table public.inventory_stock             enable row level security;
alter table public.inventory_transactions      enable row level security;
alter table public.accessory_vehicle_mappings  enable row level security;

create policy inventory_stock_select on public.inventory_stock for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and app.can_access_branch(branch_id)
             and app.has_permission('inventory.view')));

create policy inventory_transactions_select on public.inventory_transactions for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and app.can_access_branch(branch_id)
             and app.has_permission('inventory.ledger.view')));

create policy inventory_transactions_insert on public.inventory_transactions for insert to authenticated
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('inventory.stock.upload')
                  or app.has_permission('inventory.stock.adjust')
                  or app.has_permission('inventory.stock.transfer')
                  or app.has_permission('inventory.counter_sale.create')
                  or app.has_permission('sales.create')
                  or app.has_permission('service.billing.create'))));

create policy avm_select on public.accessory_vehicle_mappings for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('inventory.view')));
create policy avm_write on public.accessory_vehicle_mappings for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('inventory.items.manage')))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('inventory.items.manage')));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select on public.inventory_stock to authenticated';
    execute 'grant select, insert on public.inventory_transactions to authenticated';
    execute 'grant select, insert, update, delete on public.accessory_vehicle_mappings to authenticated';
    execute 'grant all on public.inventory_stock, public.inventory_transactions, public.accessory_vehicle_mappings to service_role';
    execute 'grant execute on function public.allocate_stock(uuid, uuid, numeric) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0020_bookings_and_sales.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0020 — Bookings, vehicle sales, deliveries
-- =============================================================================
-- Spec §18, §19, §20, §48, §50.
--
-- The sale workflow is DRAFT → SUBMITTED → ACCOUNTS_VERIFICATION → APPROVED →
-- POSTED → DELIVERED (spec §19), and financial posting happens only after
-- approval. The transition guard below encodes that; no service can skip a step.
--
-- Every sale line stores its own tax breakdown (spec §20) rather than deriving it
-- at read time, because the rate that applied on the invoice date must survive
-- later changes to the tax master (spec §16).
--
-- Rollback: drop table public.deliveries, public.sale_payments, public.sale_lines,
--           public.sales, public.booking_payments, public.bookings;
-- =============================================================================

-- =============================================================================
-- bookings — spec §18
-- =============================================================================
create table public.bookings (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null references public.dealers (id) on delete restrict,
  branch_id         uuid not null,

  booking_number    text not null,
  booking_date      date not null default current_date,

  customer_id       uuid not null,
  model_id          uuid not null,
  variant_id        uuid,
  colour_id         uuid,
  -- Optional: a booking may be against a model, or reserve a specific chassis.
  vehicle_id        uuid,

  expected_delivery date,
  booking_amount    numeric(18, 4) not null default 0,
  received_amount   numeric(18, 4) not null default 0,

  sales_executive_id uuid,
  status            text not null default 'OPEN',

  -- Set when the booking becomes a sale.
  converted_sale_id uuid,
  cancelled_reason  text,
  notes             text,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid,
  updated_by        uuid,

  constraint bookings_number_key    unique (dealer_id, booking_number),
  constraint bookings_id_dealer_key unique (id, dealer_id),
  constraint bookings_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint bookings_customer_tenant_fkey
    foreign key (customer_id, dealer_id) references public.customers (id, dealer_id),
  constraint bookings_model_tenant_fkey
    foreign key (model_id, dealer_id) references public.vehicle_models (id, dealer_id),
  constraint bookings_variant_tenant_fkey
    foreign key (variant_id, dealer_id) references public.vehicle_variants (id, dealer_id),
  constraint bookings_vehicle_tenant_fkey
    foreign key (vehicle_id, dealer_id) references public.vehicles (id, dealer_id),
  constraint bookings_employee_tenant_fkey
    foreign key (sales_executive_id, dealer_id) references public.employees (id, dealer_id),
  constraint bookings_status_check check (status in ('OPEN', 'CONVERTED', 'CANCELLED', 'EXPIRED')),
  constraint bookings_amount_check check (booking_amount >= 0 and received_amount >= 0),
  constraint bookings_cancel_reason_check check (status <> 'CANCELLED' or cancelled_reason is not null)
);

comment on table public.bookings is
  'Vehicle bookings (spec §18). The advance posts to Customer Advances, not to '
  'revenue, unless accounting policy says otherwise.';

create index bookings_customer_idx  on public.bookings (customer_id, booking_date desc);
create index bookings_branch_idx    on public.bookings (branch_id, status);
create index bookings_dealer_date_idx on public.bookings (dealer_id, booking_date desc);
create index bookings_vehicle_idx   on public.bookings (vehicle_id) where vehicle_id is not null;
create index bookings_open_idx      on public.bookings (dealer_id) where status = 'OPEN';

create table public.booking_payments (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null,
  booking_id     uuid not null,

  receipt_number text not null,
  payment_date   date not null default current_date,
  amount         numeric(18, 4) not null,
  payment_mode   text not null,
  reference      text,

  journal_entry_id uuid,
  status         text not null default 'RECEIVED',

  created_at     timestamptz not null default now(),
  created_by     uuid,

  constraint booking_payments_receipt_key unique (dealer_id, receipt_number),
  constraint booking_payments_booking_tenant_fkey
    foreign key (booking_id, dealer_id) references public.bookings (id, dealer_id) on delete cascade,
  constraint booking_payments_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint booking_payments_amount_check check (amount > 0),
  constraint booking_payments_mode_check check (payment_mode in (
    'CASH', 'CARD', 'UPI', 'NEFT', 'RTGS', 'IMPS', 'CHEQUE', 'DD', 'FINANCE'
  )),
  constraint booking_payments_status_check check (status in ('RECEIVED', 'REVERSED'))
);

create index booking_payments_booking_idx on public.booking_payments (booking_id);
create index booking_payments_date_idx    on public.booking_payments (dealer_id, payment_date desc);

-- Keep the booking's received total in step with its receipts.
create or replace function app.bookings_sync_received()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_booking uuid := coalesce(new.booking_id, old.booking_id);
begin
  update public.bookings b
     set received_amount = coalesce((
           select sum(p.amount) from public.booking_payments p
            where p.booking_id = v_booking and p.status = 'RECEIVED'
         ), 0)
   where b.id = v_booking;
  return null;
end;
$$;

create trigger booking_payments_sync
  after insert or update or delete on public.booking_payments
  for each row execute function app.bookings_sync_received();

-- =============================================================================
-- sales — spec §19, §20
-- =============================================================================
create table public.sales (
  id                 uuid primary key default gen_random_uuid(),
  dealer_id          uuid not null references public.dealers (id) on delete restrict,
  branch_id          uuid not null,

  invoice_number     text not null,
  invoice_date       date not null default current_date,

  customer_id        uuid not null,
  vehicle_id         uuid not null,
  booking_id         uuid,

  -- The exact price version used, so the invoice stays explainable (spec §42).
  price_version_id   uuid,

  sales_executive_id uuid,

  -- Totals, maintained by trigger from the lines.
  taxable_value      numeric(18, 4) not null default 0,
  cgst_amount        numeric(18, 4) not null default 0,
  sgst_amount        numeric(18, 4) not null default 0,
  igst_amount        numeric(18, 4) not null default 0,
  cess_amount        numeric(18, 4) not null default 0,
  discount_amount    numeric(18, 4) not null default 0,
  total_amount       numeric(18, 4) not null default 0,

  -- Cost side. Restricted from roles without sales.view_cost (spec §52).
  total_cost         numeric(18, 4) not null default 0,

  paid_amount        numeric(18, 4) not null default 0,
  finance_amount     numeric(18, 4) not null default 0,
  balance_amount     numeric(18, 4) generated always as (
    total_amount - paid_amount - finance_amount
  ) stored,

  status             text not null default 'DRAFT',

  submitted_at       timestamptz, submitted_by uuid,
  verified_at        timestamptz, verified_by  uuid,
  approved_at        timestamptz, approved_by  uuid,
  posted_at          timestamptz, posted_by    uuid,
  delivered_at       timestamptz, delivered_by uuid,
  cancelled_at       timestamptz, cancelled_by uuid,
  cancelled_reason   text,
  rejection_reason   text,

  journal_entry_id   uuid,
  -- Duplicate-submission protection (spec §50).
  idempotency_key    text,
  notes              text,

  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  created_by         uuid,
  updated_by         uuid,

  constraint sales_invoice_key   unique (dealer_id, invoice_number),
  constraint sales_id_dealer_key unique (id, dealer_id),
  constraint sales_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint sales_customer_tenant_fkey
    foreign key (customer_id, dealer_id) references public.customers (id, dealer_id),
  constraint sales_vehicle_tenant_fkey
    foreign key (vehicle_id, dealer_id) references public.vehicles (id, dealer_id),
  constraint sales_booking_tenant_fkey
    foreign key (booking_id, dealer_id) references public.bookings (id, dealer_id),
  constraint sales_price_version_tenant_fkey
    foreign key (price_version_id, dealer_id) references public.vehicle_price_versions (id, dealer_id),
  constraint sales_employee_tenant_fkey
    foreign key (sales_executive_id, dealer_id) references public.employees (id, dealer_id),
  constraint sales_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),

  constraint sales_status_check check (status in (
    'DRAFT', 'SUBMITTED', 'ACCOUNTS_VERIFICATION', 'APPROVED', 'POSTED', 'DELIVERED', 'CANCELLED', 'RETURNED'
  )),
  constraint sales_amounts_check check (
    taxable_value >= 0 and cgst_amount >= 0 and sgst_amount >= 0 and igst_amount >= 0
    and cess_amount >= 0 and discount_amount >= 0 and total_amount >= 0
    and paid_amount >= 0 and finance_amount >= 0 and total_cost >= 0
  ),
  -- Intra-state and inter-state are mutually exclusive on one invoice.
  constraint sales_gst_mode_check check (
    (igst_amount = 0) or (cgst_amount = 0 and sgst_amount = 0)
  ),
  constraint sales_posted_journal_check check (status not in ('POSTED', 'DELIVERED') or journal_entry_id is not null),
  constraint sales_cancel_reason_check check (status <> 'CANCELLED' or cancelled_reason is not null)
);

comment on table public.sales is
  'Vehicle sale invoice (spec §19, §20). Financial posting happens at APPROVED → '
  'POSTED, never before (spec §19).';
comment on column public.sales.total_cost is
  'Restricted. Withheld from roles lacking sales.view_cost (spec §52).';

create unique index sales_idempotency_key
  on public.sales (dealer_id, idempotency_key) where idempotency_key is not null;

-- One live sale per vehicle: a chassis cannot be on two open invoices (spec §49).
create unique index sales_vehicle_active_key
  on public.sales (vehicle_id)
  where status not in ('CANCELLED', 'RETURNED');

create index sales_customer_idx    on public.sales (customer_id, invoice_date desc);
create index sales_branch_date_idx on public.sales (branch_id, invoice_date desc);
create index sales_dealer_date_idx on public.sales (dealer_id, invoice_date desc);
create index sales_status_idx      on public.sales (dealer_id, status);
create index sales_booking_idx     on public.sales (booking_id) where booking_id is not null;
create index sales_executive_idx   on public.sales (sales_executive_id) where sales_executive_id is not null;

-- -----------------------------------------------------------------------------
-- sale_lines — spec §20, every component itemised with its own tax
-- -----------------------------------------------------------------------------
create table public.sale_lines (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null,
  sale_id        uuid not null,

  line_number    smallint not null,
  line_type      text not null,

  description    text not null,
  item_id        uuid,
  hsn_code       text,

  quantity       numeric(14, 3) not null default 1,
  unit_rate      numeric(18, 4) not null default 0,
  discount       numeric(18, 4) not null default 0,
  taxable_value  numeric(18, 4) not null default 0,

  tax_code       text,
  cgst_rate      numeric(6, 3) not null default 0,
  sgst_rate      numeric(6, 3) not null default 0,
  igst_rate      numeric(6, 3) not null default 0,
  cgst_amount    numeric(18, 4) not null default 0,
  sgst_amount    numeric(18, 4) not null default 0,
  igst_amount    numeric(18, 4) not null default 0,
  cess_amount    numeric(18, 4) not null default 0,

  total_amount   numeric(18, 4) not null default 0,

  -- Cost and allocation source, for margin and for the audit of spec §31.
  unit_cost      numeric(18, 4) not null default 0,
  cost_amount    numeric(18, 4) not null default 0,
  stock_source   text,

  created_at     timestamptz not null default now(),

  constraint sale_lines_line_key unique (sale_id, line_number),
  constraint sale_lines_sale_tenant_fkey
    foreign key (sale_id, dealer_id) references public.sales (id, dealer_id) on delete cascade,
  constraint sale_lines_item_tenant_fkey
    foreign key (item_id, dealer_id) references public.inventory_items (id, dealer_id),
  constraint sale_lines_type_check check (line_type in (
    'VEHICLE', 'INSURANCE', 'REGISTRATION', 'ACCESSORY', 'FITTING',
    'FORWARDING', 'OTHER_CHARGE', 'DISCOUNT', 'SPARE', 'LABOUR'
  )),
  constraint sale_lines_source_check check (stock_source is null or stock_source in ('LOCAL', 'COMPANY')),
  constraint sale_lines_amounts_check check (
    quantity > 0 and unit_rate >= 0 and discount >= 0 and taxable_value >= 0
    and cgst_amount >= 0 and sgst_amount >= 0 and igst_amount >= 0 and total_amount >= 0
  )
);

comment on table public.sale_lines is
  'Invoice lines (spec §20). stock_source records whether a fitting came from '
  'LOCAL or COMPANY stock, so the allocation is visible on the invoice (spec §31).';

create index sale_lines_sale_idx on public.sale_lines (sale_id, line_number);
create index sale_lines_item_idx on public.sale_lines (item_id) where item_id is not null;

create table public.sale_payments (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null,
  sale_id          uuid not null,

  receipt_number   text not null,
  payment_date     date not null default current_date,
  amount           numeric(18, 4) not null,
  payment_mode     text not null,
  reference        text,

  finance_company_id uuid,
  journal_entry_id uuid,
  status           text not null default 'RECEIVED',

  created_at       timestamptz not null default now(),
  created_by       uuid,

  constraint sale_payments_receipt_key unique (dealer_id, receipt_number),
  constraint sale_payments_sale_tenant_fkey
    foreign key (sale_id, dealer_id) references public.sales (id, dealer_id) on delete cascade,
  constraint sale_payments_finance_tenant_fkey
    foreign key (finance_company_id, dealer_id) references public.finance_companies (id, dealer_id),
  constraint sale_payments_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint sale_payments_amount_check check (amount > 0),
  constraint sale_payments_mode_check check (payment_mode in (
    'CASH', 'CARD', 'UPI', 'NEFT', 'RTGS', 'IMPS', 'CHEQUE', 'DD', 'FINANCE', 'BOOKING_ADVANCE'
  )),
  constraint sale_payments_status_check check (status in ('RECEIVED', 'REVERSED'))
);

create index sale_payments_sale_idx on public.sale_payments (sale_id);
create index sale_payments_date_idx on public.sale_payments (dealer_id, payment_date desc);

create table public.deliveries (
  id              uuid primary key default gen_random_uuid(),
  dealer_id       uuid not null,
  branch_id       uuid not null,
  sale_id         uuid not null,
  vehicle_id      uuid not null,

  delivery_number text not null,
  delivered_at    timestamptz not null default now(),
  delivered_by    uuid,
  received_by_name text,
  odometer        numeric(10, 1),
  remarks         text,

  created_at      timestamptz not null default now(),

  constraint deliveries_number_key unique (dealer_id, delivery_number),
  constraint deliveries_sale_key   unique (sale_id),
  constraint deliveries_sale_tenant_fkey
    foreign key (sale_id, dealer_id) references public.sales (id, dealer_id) on delete cascade,
  constraint deliveries_vehicle_tenant_fkey
    foreign key (vehicle_id, dealer_id) references public.vehicles (id, dealer_id),
  constraint deliveries_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id)
);

create index deliveries_vehicle_idx on public.deliveries (vehicle_id);
create index deliveries_date_idx    on public.deliveries (dealer_id, delivered_at desc);

-- -----------------------------------------------------------------------------
-- Sale workflow guard — spec §19
-- -----------------------------------------------------------------------------
create or replace function app.sales_guard()
returns trigger
language plpgsql
as $$
declare
  v_allowed text[];
begin
  if tg_op = 'DELETE' then
    if old.status <> 'DRAFT' then
      raise exception 'Sale % is % and cannot be deleted.', old.invoice_number, old.status
        using errcode = 'insufficient_privilege',
              hint = 'Cancel it, or post a sales return.';
    end if;
    return old;
  end if;

  if tg_op = 'INSERT' then
    if new.status <> 'DRAFT' then
      raise exception 'A sale is created as DRAFT, not %.', new.status
        using errcode = 'check_violation';
    end if;
    return new;
  end if;

  if new.status = old.status then
    -- A posted invoice's figures are fixed; only the payment tally may move.
    -- Columns are compared explicitly: `balance_amount` is generated, and a
    -- BEFORE trigger does not see generated columns populated in NEW, so a
    -- subtractive JSONB comparison would flag every update as a change.
    if old.status in ('POSTED', 'DELIVERED')
       and (new.taxable_value   is distinct from old.taxable_value
         or new.cgst_amount     is distinct from old.cgst_amount
         or new.sgst_amount     is distinct from old.sgst_amount
         or new.igst_amount     is distinct from old.igst_amount
         or new.cess_amount     is distinct from old.cess_amount
         or new.discount_amount is distinct from old.discount_amount
         or new.total_amount    is distinct from old.total_amount
         or new.total_cost      is distinct from old.total_cost
         or new.invoice_number  is distinct from old.invoice_number
         or new.invoice_date    is distinct from old.invoice_date
         or new.customer_id     is distinct from old.customer_id
         or new.vehicle_id      is distinct from old.vehicle_id
         or new.journal_entry_id is distinct from old.journal_entry_id) then
      raise exception 'Sale % is % and its invoice values are immutable.', old.invoice_number, old.status
        using errcode = 'insufficient_privilege',
              hint = 'Spec §23: correct it with a reversal and a fresh invoice.';
    end if;
    return new;
  end if;

  v_allowed := case old.status
    when 'DRAFT'                 then array['SUBMITTED', 'CANCELLED']
    when 'SUBMITTED'             then array['ACCOUNTS_VERIFICATION', 'DRAFT', 'CANCELLED']
    when 'ACCOUNTS_VERIFICATION' then array['APPROVED', 'DRAFT', 'CANCELLED']
    when 'APPROVED'              then array['POSTED', 'CANCELLED']
    when 'POSTED'                then array['DELIVERED', 'RETURNED']
    when 'DELIVERED'             then array['RETURNED']
    else array[]::text[]
  end;

  if not (new.status = any (v_allowed)) then
    raise exception 'Sale % cannot move from % to %.', old.invoice_number, old.status, new.status
      using errcode = 'check_violation',
            hint = 'Spec §19 defines the sale workflow.';
  end if;

  -- Posting requires the accounting entry to exist (spec §19, §48).
  if new.status = 'POSTED' and new.journal_entry_id is null then
    raise exception 'Sale % cannot be POSTED without a journal entry.', old.invoice_number
      using errcode = 'check_violation',
            hint = 'Spec §48: an invoice without its accounting effect is not permitted.';
  end if;

  new.posted_at    := case when new.status = 'POSTED'    then coalesce(new.posted_at, now())    else new.posted_at end;
  new.delivered_at := case when new.status = 'DELIVERED' then coalesce(new.delivered_at, now()) else new.delivered_at end;
  return new;
end;
$$;

create trigger sales_guard
  before insert or update or delete on public.sales
  for each row execute function app.sales_guard();

-- Lines may only change while the invoice is still being prepared.
create or replace function app.sale_lines_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status text;
  v_sale uuid := coalesce(new.sale_id, old.sale_id);
begin
  select status into v_status from public.sales where id = v_sale;
  if v_status is null then
    return coalesce(new, old);
  end if;
  if v_status not in ('DRAFT', 'SUBMITTED', 'ACCOUNTS_VERIFICATION') then
    raise exception 'Cannot % lines of a % sale.', lower(tg_op), v_status
      using errcode = 'insufficient_privilege';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger sale_lines_guard
  before insert or update or delete on public.sale_lines
  for each row execute function app.sale_lines_guard();

-- Invoice totals are derived from the lines, never supplied by the caller.
create or replace function app.sales_sync_totals()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sale uuid := coalesce(new.sale_id, old.sale_id);
begin
  update public.sales s
     set taxable_value   = coalesce(t.taxable, 0),
         cgst_amount     = coalesce(t.cgst, 0),
         sgst_amount     = coalesce(t.sgst, 0),
         igst_amount     = coalesce(t.igst, 0),
         cess_amount     = coalesce(t.cess, 0),
         discount_amount = coalesce(t.discount, 0),
         total_amount    = coalesce(t.total, 0),
         total_cost      = coalesce(t.cost, 0)
    from (
      select sum(l.taxable_value) taxable, sum(l.cgst_amount) cgst, sum(l.sgst_amount) sgst,
             sum(l.igst_amount) igst, sum(l.cess_amount) cess, sum(l.discount) discount,
             sum(l.total_amount) total, sum(l.cost_amount) cost
        from public.sale_lines l where l.sale_id = v_sale
    ) t
   where s.id = v_sale
     and s.status in ('DRAFT', 'SUBMITTED', 'ACCOUNTS_VERIFICATION');
  return null;
end;
$$;

create trigger sale_lines_sync_totals
  after insert or update or delete on public.sale_lines
  for each row execute function app.sales_sync_totals();

create or replace function app.sales_sync_payments()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sale uuid := coalesce(new.sale_id, old.sale_id);
begin
  update public.sales s
     set paid_amount = coalesce((
           select sum(p.amount) from public.sale_payments p
            where p.sale_id = v_sale and p.status = 'RECEIVED' and p.payment_mode <> 'FINANCE'
         ), 0),
         finance_amount = coalesce((
           select sum(p.amount) from public.sale_payments p
            where p.sale_id = v_sale and p.status = 'RECEIVED' and p.payment_mode = 'FINANCE'
         ), 0)
   where s.id = v_sale;
  return null;
end;
$$;

create trigger sale_payments_sync
  after insert or update or delete on public.sale_payments
  for each row execute function app.sales_sync_payments();

create trigger bookings_set_updated_at before update on public.bookings
  for each row execute function app.set_updated_at();
create trigger sales_set_updated_at before update on public.sales
  for each row execute function app.set_updated_at();

create trigger bookings_audit after insert or update or delete on public.bookings
  for each row execute function app.audit_trigger();
create trigger sales_audit after insert or update or delete on public.sales
  for each row execute function app.audit_trigger();
create trigger deliveries_audit after insert or update or delete on public.deliveries
  for each row execute function app.audit_trigger();

alter table public.bookings         enable row level security;
alter table public.booking_payments enable row level security;
alter table public.sales            enable row level security;
alter table public.sale_lines       enable row level security;
alter table public.sale_payments    enable row level security;
alter table public.deliveries       enable row level security;

create policy bookings_select on public.bookings for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('bookings.view')));
create policy bookings_insert on public.bookings for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('bookings.create')));
create policy bookings_update on public.bookings for update to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('bookings.create') or app.has_permission('bookings.cancel')
              or app.has_permission('bookings.convert'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy booking_payments_select on public.booking_payments for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bookings.view')));
create policy booking_payments_insert on public.booking_payments for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bookings.create')));

create policy sales_select on public.sales for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('sales.view')));
create policy sales_insert on public.sales for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('sales.create')));
create policy sales_update on public.sales for update to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('sales.create') or app.has_permission('sales.submit')
              or app.has_permission('sales.verify') or app.has_permission('sales.approve')
              or app.has_permission('sales.post') or app.has_permission('sales.deliver')
              or app.has_permission('sales.cancel'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy sale_lines_select on public.sale_lines for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('sales.view')));
create policy sale_lines_write on public.sale_lines for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('sales.create')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('sales.create')));

create policy sale_payments_select on public.sale_payments for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('sales.view')));
create policy sale_payments_insert on public.sale_payments for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('sales.create')));

create policy deliveries_select on public.deliveries for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('sales.view')));
create policy deliveries_insert on public.deliveries for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('sales.deliver')));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.bookings, public.sales to authenticated';
    execute 'grant select, insert on public.booking_payments, public.sale_payments, public.deliveries to authenticated';
    execute 'grant select, insert, update, delete on public.sale_lines to authenticated';
    execute 'grant all on public.bookings, public.booking_payments, public.sales, public.sale_lines, public.sale_payments, public.deliveries to service_role';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0021_finance.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0021 — Finance: HP applications, trade advances, settlements
-- =============================================================================
-- Spec §25, §26, §27, §60.
--
-- The rule that shapes this: "Never combine all finance companies into one
-- generic balance." Every transaction carries finance_company_id, and the running
-- balance is per company. `finance_transactions` is the subsidiary ledger that
-- reconciles to the general ledger through the party-tagged journal lines.
--
-- Rollback: drop table public.finance_settlements, public.finance_transactions,
--           public.finance_applications;
-- =============================================================================

create table public.finance_applications (
  id                  uuid primary key default gen_random_uuid(),
  dealer_id           uuid not null references public.dealers (id) on delete restrict,
  branch_id           uuid not null,

  application_number  text not null,
  application_date    date not null default current_date,

  customer_id         uuid not null,
  finance_company_id  uuid not null,
  vehicle_id          uuid,
  sale_id             uuid,

  loan_amount         numeric(18, 4) not null default 0,
  down_payment        numeric(18, 4) not null default 0,
  tenure_months       smallint,
  interest_rate       numeric(6, 3),

  approval_status     text not null default 'PENDING',
  approved_amount     numeric(18, 4),
  approved_at         timestamptz,

  disbursement_status text not null default 'PENDING',
  disbursed_amount    numeric(18, 4) not null default 0,
  disbursed_at        timestamptz,
  dd_number           text,
  bank_reference      text,

  -- Restricted: commission is a sensitive figure (spec §52).
  commission_amount   numeric(18, 4) not null default 0,

  pending_amount      numeric(18, 4) generated always as (
    coalesce(approved_amount, loan_amount) - disbursed_amount
  ) stored,

  rejection_reason    text,
  notes               text,

  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid,
  updated_by          uuid,

  constraint fa_number_key    unique (dealer_id, application_number),
  constraint fa_id_dealer_key unique (id, dealer_id),
  constraint fa_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint fa_customer_tenant_fkey
    foreign key (customer_id, dealer_id) references public.customers (id, dealer_id),
  constraint fa_company_tenant_fkey
    foreign key (finance_company_id, dealer_id) references public.finance_companies (id, dealer_id),
  constraint fa_vehicle_tenant_fkey
    foreign key (vehicle_id, dealer_id) references public.vehicles (id, dealer_id),
  constraint fa_sale_tenant_fkey
    foreign key (sale_id, dealer_id) references public.sales (id, dealer_id),
  constraint fa_approval_check     check (approval_status in ('PENDING', 'APPROVED', 'REJECTED', 'CANCELLED')),
  constraint fa_disbursement_check check (disbursement_status in ('PENDING', 'PARTIAL', 'DISBURSED', 'CANCELLED')),
  constraint fa_amounts_check      check (
    loan_amount >= 0 and down_payment >= 0 and disbursed_amount >= 0 and commission_amount >= 0
    and (approved_amount is null or approved_amount >= 0)
  ),
  constraint fa_approved_amount_check check (approval_status <> 'APPROVED' or approved_amount is not null),
  constraint fa_rejection_check       check (approval_status <> 'REJECTED' or rejection_reason is not null),
  constraint fa_tenure_check          check (tenure_months is null or tenure_months between 1 and 120)
);

comment on table public.finance_applications is 'HP / finance applications (spec §27).';
comment on column public.finance_applications.commission_amount is
  'Restricted. Withheld from roles lacking finance.commission.view (spec §52).';

create index fa_customer_idx  on public.finance_applications (customer_id, application_date desc);
create index fa_company_idx   on public.finance_applications (finance_company_id, approval_status);
create index fa_branch_idx    on public.finance_applications (branch_id, application_date desc);
create index fa_sale_idx      on public.finance_applications (sale_id) where sale_id is not null;
create index fa_pending_idx   on public.finance_applications (dealer_id)
  where disbursement_status in ('PENDING', 'PARTIAL');

-- =============================================================================
-- finance_transactions — the per-company subsidiary ledger (spec §26)
-- =============================================================================
create table public.finance_transactions (
  id                 bigint generated always as identity primary key,
  dealer_id          uuid not null,
  branch_id          uuid not null,
  finance_company_id uuid not null,

  transaction_date   date not null default current_date,
  transaction_type   text not null,

  -- Signed against the dealer's position with this company: a credit increases
  -- what the company owes the dealer, a debit reduces it.
  debit              numeric(18, 4) not null default 0,
  credit             numeric(18, 4) not null default 0,
  balance_after      numeric(18, 4) not null default 0,

  reference_type     text,
  reference_id       uuid,
  reference_number   text,
  narration          text,

  application_id     uuid,
  sale_id            uuid,
  journal_entry_id   uuid,

  created_at         timestamptz not null default now(),
  created_by         uuid,

  constraint ft_company_tenant_fkey
    foreign key (finance_company_id, dealer_id) references public.finance_companies (id, dealer_id),
  constraint ft_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint ft_application_tenant_fkey
    foreign key (application_id, dealer_id) references public.finance_applications (id, dealer_id),
  constraint ft_sale_tenant_fkey
    foreign key (sale_id, dealer_id) references public.sales (id, dealer_id),
  constraint ft_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint ft_type_check check (transaction_type in (
    'ADVANCE_RECEIVED', 'VEHICLE_ADJUSTMENT', 'SETTLEMENT',
    'REFUND', 'COMMISSION', 'MANUAL_ADJUSTMENT', 'DISBURSEMENT'
  )),
  constraint ft_amounts_check check (debit >= 0 and credit >= 0),
  -- One-sided, like a journal line.
  constraint ft_one_sided_check check ((debit > 0 and credit = 0) or (credit > 0 and debit = 0))
);

comment on table public.finance_transactions is
  'Per-finance-company ledger (spec §25, §26). Never aggregated into a single '
  'generic balance across companies.';

create trigger finance_transactions_append_only
  before update or delete on public.finance_transactions
  for each row execute function app.forbid_mutation();

create index ft_company_date_idx on public.finance_transactions (finance_company_id, transaction_date desc);
create index ft_dealer_date_idx  on public.finance_transactions (dealer_id, transaction_date desc);
create index ft_reference_idx    on public.finance_transactions (reference_type, reference_id)
  where reference_id is not null;

-- Running balance per company, computed under a row lock so concurrent postings
-- cannot both read the same prior balance.
create or replace function app.finance_transactions_balance()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prev numeric(18, 4);
begin
  perform 1 from public.finance_companies
   where id = new.finance_company_id for update;

  select coalesce(balance_after, 0) into v_prev
    from public.finance_transactions
   where finance_company_id = new.finance_company_id
   order by id desc
   limit 1;

  new.balance_after := coalesce(v_prev, 0) + new.credit - new.debit;
  return new;
end;
$$;

create trigger finance_transactions_balance
  before insert on public.finance_transactions
  for each row execute function app.finance_transactions_balance();

create table public.finance_settlements (
  id                 uuid primary key default gen_random_uuid(),
  dealer_id          uuid not null,
  finance_company_id uuid not null,

  settlement_number  text not null,
  settlement_date    date not null default current_date,
  from_date          date,
  to_date            date,

  gross_amount       numeric(18, 4) not null default 0,
  commission_amount  numeric(18, 4) not null default 0,
  deductions         numeric(18, 4) not null default 0,
  net_amount         numeric(18, 4) generated always as (
    gross_amount - commission_amount - deductions
  ) stored,

  status             text not null default 'DRAFT',
  journal_entry_id   uuid,
  notes              text,

  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  created_by         uuid,

  constraint fs_number_key unique (dealer_id, settlement_number),
  constraint fs_id_dealer_key unique (id, dealer_id),
  constraint fs_company_tenant_fkey
    foreign key (finance_company_id, dealer_id) references public.finance_companies (id, dealer_id),
  constraint fs_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint fs_status_check  check (status in ('DRAFT', 'POSTED', 'CANCELLED')),
  constraint fs_amounts_check check (gross_amount >= 0 and commission_amount >= 0 and deductions >= 0),
  constraint fs_dates_check   check (to_date is null or from_date is null or to_date >= from_date)
);

create index fs_company_idx on public.finance_settlements (finance_company_id, settlement_date desc);

-- -----------------------------------------------------------------------------
-- public.finance_company_ledger() — opening + credits − debits = closing (§26)
-- -----------------------------------------------------------------------------
create or replace function public.finance_company_ledger(
  p_company_id uuid,
  p_from       date,
  p_to         date
)
returns table (
  transaction_date date,
  transaction_type text,
  reference_number text,
  narration        text,
  debit            numeric(18, 4),
  credit           numeric(18, 4),
  balance_after    numeric(18, 4)
)
language sql
stable
as $$
  -- Opening row: everything before the window, collapsed to one line.
  select p_from, 'OPENING'::text, null::text, 'Opening balance'::text,
         0::numeric(18, 4), 0::numeric(18, 4),
         coalesce((
           select ft.balance_after from public.finance_transactions ft
            where ft.finance_company_id = p_company_id and ft.transaction_date < p_from
            order by ft.id desc limit 1
         ), 0)
  union all
  select ft.transaction_date, ft.transaction_type, ft.reference_number, ft.narration,
         ft.debit, ft.credit, ft.balance_after
    from public.finance_transactions ft
   where ft.finance_company_id = p_company_id
     and ft.transaction_date between p_from and p_to
   order by 1, 7;
$$;

comment on function public.finance_company_ledger(uuid, date, date) is
  'Daily ledger view for one finance company (spec §26): opening, movements, closing.';

create trigger fa_set_updated_at before update on public.finance_applications
  for each row execute function app.set_updated_at();
create trigger fs_set_updated_at before update on public.finance_settlements
  for each row execute function app.set_updated_at();
create trigger fa_audit after insert or update or delete on public.finance_applications
  for each row execute function app.audit_trigger();

alter table public.finance_applications enable row level security;
alter table public.finance_transactions enable row level security;
alter table public.finance_settlements  enable row level security;

create policy fa_select on public.finance_applications for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('finance.applications.view')));
create policy fa_write on public.finance_applications for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('finance.applications.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('finance.applications.manage')));

create policy ft_select on public.finance_transactions for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('finance.trade_advance.view')));
create policy ft_insert on public.finance_transactions for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('finance.trade_advance.manage')
              or app.has_permission('finance.settlements.manage')
              or app.has_permission('sales.post'))));

create policy fs_select on public.finance_settlements for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('finance.trade_advance.view')));
create policy fs_write on public.finance_settlements for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('finance.settlements.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('finance.settlements.manage')));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.finance_applications, public.finance_settlements to authenticated';
    execute 'grant select, insert on public.finance_transactions to authenticated';
    execute 'grant all on public.finance_applications, public.finance_transactions, public.finance_settlements to service_role';
    execute 'grant execute on function public.finance_company_ledger(uuid, date, date) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0022_cash_and_bank.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0022 — Cash book, day closing, bank accounts and reconciliation
-- =============================================================================
-- Spec §36, §37, §38, §39, §60.14, §60.15.
--
-- The daily cash book is mandatory and so is the daily close. Once a day is
-- CLOSED its transactions are frozen — spec §36: "After close: no direct edits.
-- Only reversal/adjustment with permission." That is enforced by a trigger here,
-- not by a UI that hides the edit button.
--
-- Rollback: drop table public.bank_reconciliations, public.bank_statement_lines,
--           public.bank_transactions, public.bank_accounts,
--           public.cash_day_closings, public.cash_transactions, public.cash_accounts;
-- =============================================================================

create table public.cash_accounts (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null references public.dealers (id) on delete cascade,
  branch_id         uuid not null,

  name              text not null,
  ledger_account_id uuid not null,
  opening_balance   numeric(18, 4) not null default 0,
  current_balance   numeric(18, 4) not null default 0,

  status            text not null default 'ACTIVE',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  -- One cash account per branch (spec §36: "Each branch has a cash account").
  constraint cash_accounts_branch_key unique (branch_id),
  constraint cash_accounts_id_dealer_key unique (id, dealer_id),
  constraint cash_accounts_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id) on delete cascade,
  constraint cash_accounts_ledger_tenant_fkey
    foreign key (ledger_account_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint cash_accounts_status_check check (status in ('ACTIVE', 'INACTIVE'))
);

-- -----------------------------------------------------------------------------
-- cash_day_closings — spec §36
-- -----------------------------------------------------------------------------
create table public.cash_day_closings (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null,
  branch_id         uuid not null,
  cash_account_id   uuid not null,

  business_date     date not null,
  status            text not null default 'OPEN',

  opening_balance   numeric(18, 4) not null default 0,
  total_receipts    numeric(18, 4) not null default 0,
  total_payments    numeric(18, 4) not null default 0,
  expected_closing  numeric(18, 4) generated always as (
    opening_balance + total_receipts - total_payments
  ) stored,

  physical_cash     numeric(18, 4),
  -- The number that matters at close: counted minus expected.
  difference        numeric(18, 4),

  denominations     jsonb,
  counted_at        timestamptz,
  counted_by        uuid,
  closed_at         timestamptz,
  closed_by         uuid,
  reopened_at       timestamptz,
  reopened_by       uuid,
  reopen_reason     text,
  remarks           text,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint cdc_branch_date_key unique (branch_id, business_date),
  constraint cdc_id_dealer_key   unique (id, dealer_id),
  constraint cdc_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint cdc_account_tenant_fkey
    foreign key (cash_account_id, dealer_id) references public.cash_accounts (id, dealer_id),
  constraint cdc_status_check check (status in ('OPEN', 'IN_PROGRESS', 'COUNTED', 'CLOSED')),
  constraint cdc_counted_check check (status <> 'COUNTED' or physical_cash is not null),
  constraint cdc_closed_check  check (status <> 'CLOSED' or (physical_cash is not null and closed_at is not null)),
  constraint cdc_reopen_check  check (reopened_at is null or reopen_reason is not null)
);

comment on table public.cash_day_closings is
  'Mandatory daily cash close (spec §36, §60.15). OPEN → IN_PROGRESS → COUNTED → CLOSED.';

create index cdc_branch_date_idx on public.cash_day_closings (branch_id, business_date desc);
create index cdc_open_idx        on public.cash_day_closings (dealer_id) where status <> 'CLOSED';

create table public.cash_transactions (
  id               bigint generated always as identity primary key,
  dealer_id        uuid not null,
  branch_id        uuid not null,
  cash_account_id  uuid not null,

  business_date    date not null default current_date,
  transaction_time timestamptz not null default now(),

  direction        text not null,
  amount           numeric(18, 4) not null,
  balance_after    numeric(18, 4) not null default 0,

  particular       text not null,
  reference_type   text,
  reference_id     uuid,
  reference_number text,

  customer_id      uuid,
  journal_entry_id uuid,
  status           text not null default 'ACTIVE',

  created_at       timestamptz not null default now(),
  created_by       uuid,

  constraint ct_account_tenant_fkey
    foreign key (cash_account_id, dealer_id) references public.cash_accounts (id, dealer_id),
  constraint ct_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint ct_customer_tenant_fkey
    foreign key (customer_id, dealer_id) references public.customers (id, dealer_id),
  constraint ct_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint ct_direction_check check (direction in ('RECEIPT', 'PAYMENT')),
  constraint ct_amount_check    check (amount > 0),
  constraint ct_status_check    check (status in ('ACTIVE', 'REVERSED'))
);

comment on table public.cash_transactions is 'Daily cash book entries (spec §37).';

create index ct_branch_date_idx  on public.cash_transactions (branch_id, business_date desc, transaction_time);
create index ct_account_date_idx on public.cash_transactions (cash_account_id, business_date desc);
create index ct_reference_idx    on public.cash_transactions (reference_type, reference_id) where reference_id is not null;
create index ct_customer_idx     on public.cash_transactions (customer_id) where customer_id is not null;

-- -----------------------------------------------------------------------------
-- A closed day is frozen (spec §36, §60.23)
-- -----------------------------------------------------------------------------
create or replace function app.cash_transactions_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status text;
  v_prev   numeric(18, 4);
  v_row    public.cash_transactions;
begin
  v_row := coalesce(new, old);

  select status into v_status
    from public.cash_day_closings
   where branch_id = v_row.branch_id and business_date = v_row.business_date;

  if v_status = 'CLOSED' then
    raise exception 'The cash book for % is closed and cannot be changed.', v_row.business_date
      using errcode = 'insufficient_privilege',
            hint = 'Spec §36: reopen the day with permission, or post an adjustment.';
  end if;

  if tg_op = 'DELETE' then
    raise exception 'Cash book entries are not deleted; reverse them instead.'
      using errcode = 'insufficient_privilege';
  end if;

  if tg_op = 'INSERT' then
    -- Lock the account so two concurrent receipts cannot read the same balance.
    perform 1 from public.cash_accounts where id = new.cash_account_id for update;

    select coalesce(balance_after, 0) into v_prev
      from public.cash_transactions
     where cash_account_id = new.cash_account_id and status = 'ACTIVE'
     order by id desc limit 1;

    if v_prev is null then
      select opening_balance into v_prev from public.cash_accounts where id = new.cash_account_id;
    end if;

    new.balance_after := coalesce(v_prev, 0)
      + case when new.direction = 'RECEIPT' then new.amount else -new.amount end;
  end if;

  return new;
end;
$$;

create trigger cash_transactions_guard
  before insert or update or delete on public.cash_transactions
  for each row execute function app.cash_transactions_guard();

-- Keep the day sheet and the account balance in step with the entries.
create or replace function app.cash_sync_day()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.cash_transactions := coalesce(new, old);
begin
  update public.cash_day_closings d
     set total_receipts = coalesce((
           select sum(t.amount) from public.cash_transactions t
            where t.branch_id = v_row.branch_id and t.business_date = v_row.business_date
              and t.direction = 'RECEIPT' and t.status = 'ACTIVE'), 0),
         total_payments = coalesce((
           select sum(t.amount) from public.cash_transactions t
            where t.branch_id = v_row.branch_id and t.business_date = v_row.business_date
              and t.direction = 'PAYMENT' and t.status = 'ACTIVE'), 0),
         status = case when d.status = 'OPEN' then 'IN_PROGRESS' else d.status end
   where d.branch_id = v_row.branch_id and d.business_date = v_row.business_date;

  update public.cash_accounts a
     set current_balance = coalesce((
           select t.balance_after from public.cash_transactions t
            where t.cash_account_id = v_row.cash_account_id and t.status = 'ACTIVE'
            order by t.id desc limit 1), a.opening_balance)
   where a.id = v_row.cash_account_id;

  return null;
end;
$$;

create trigger cash_transactions_sync
  after insert or update on public.cash_transactions
  for each row execute function app.cash_sync_day();

-- The difference is computed at close, never typed in.
create or replace function app.cash_day_guard()
returns trigger
language plpgsql
as $$
begin
  if new.physical_cash is not null then
    new.difference := new.physical_cash - new.expected_closing;
  end if;

  if tg_op = 'UPDATE' and old.status = 'CLOSED' and new.status <> 'CLOSED' then
    if new.reopen_reason is null then
      raise exception 'Reopening a closed day requires a reason.'
        using errcode = 'check_violation';
    end if;
    new.reopened_at := now();
  end if;

  return new;
end;
$$;

create trigger cash_day_guard
  before insert or update on public.cash_day_closings
  for each row execute function app.cash_day_guard();

-- =============================================================================
-- Bank — spec §38, §39
-- =============================================================================
create table public.bank_accounts (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null references public.dealers (id) on delete cascade,
  branch_id         uuid,

  name              text not null,
  bank_name         text not null,
  account_number    text not null,
  ifsc              text,
  account_type      text not null default 'CURRENT',

  ledger_account_id uuid not null,
  opening_balance   numeric(18, 4) not null default 0,
  current_balance   numeric(18, 4) not null default 0,

  status            text not null default 'ACTIVE',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint bank_accounts_number_key   unique (dealer_id, account_number),
  constraint bank_accounts_id_dealer_key unique (id, dealer_id),
  constraint bank_accounts_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint bank_accounts_ledger_tenant_fkey
    foreign key (ledger_account_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint bank_accounts_type_check   check (account_type in ('CURRENT', 'SAVINGS', 'OD', 'CC')),
  constraint bank_accounts_status_check check (status in ('ACTIVE', 'INACTIVE', 'CLOSED')),
  constraint bank_accounts_ifsc_check   check (ifsc is null or ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$')
);

create index bank_accounts_dealer_idx on public.bank_accounts (dealer_id, status);
create index bank_accounts_branch_idx on public.bank_accounts (branch_id) where branch_id is not null;

create table public.bank_transactions (
  id                bigint generated always as identity primary key,
  dealer_id         uuid not null,
  bank_account_id   uuid not null,

  transaction_date  date not null default current_date,
  direction         text not null,
  amount            numeric(18, 4) not null,
  balance_after     numeric(18, 4) not null default 0,

  particular        text not null,
  reference_type    text,
  reference_id      uuid,
  reference_number  text,
  utr               text,
  instrument_number text,

  journal_entry_id  uuid,
  -- Reconciliation state (spec §39).
  reconciled        boolean not null default false,
  reconciliation_id uuid,
  status            text not null default 'ACTIVE',

  created_at        timestamptz not null default now(),
  created_by        uuid,

  constraint bt_account_tenant_fkey
    foreign key (bank_account_id, dealer_id) references public.bank_accounts (id, dealer_id),
  constraint bt_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint bt_direction_check check (direction in ('RECEIPT', 'PAYMENT')),
  constraint bt_amount_check    check (amount > 0),
  constraint bt_status_check    check (status in ('ACTIVE', 'REVERSED'))
);

create index bt_account_date_idx on public.bank_transactions (bank_account_id, transaction_date desc);
create index bt_unreconciled_idx on public.bank_transactions (bank_account_id) where not reconciled;
create index bt_utr_idx          on public.bank_transactions (dealer_id, utr) where utr is not null;
create index bt_reference_idx    on public.bank_transactions (reference_type, reference_id) where reference_id is not null;

create or replace function app.bank_transactions_balance()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_prev numeric(18, 4);
begin
  perform 1 from public.bank_accounts where id = new.bank_account_id for update;

  select coalesce(balance_after, 0) into v_prev
    from public.bank_transactions
   where bank_account_id = new.bank_account_id and status = 'ACTIVE'
   order by id desc limit 1;

  if v_prev is null then
    select opening_balance into v_prev from public.bank_accounts where id = new.bank_account_id;
  end if;

  new.balance_after := coalesce(v_prev, 0)
    + case when new.direction = 'RECEIPT' then new.amount else -new.amount end;
  return new;
end;
$$;

create trigger bank_transactions_balance
  before insert on public.bank_transactions
  for each row execute function app.bank_transactions_balance();

create or replace function app.bank_sync_balance()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.bank_accounts a
     set current_balance = coalesce((
           select t.balance_after from public.bank_transactions t
            where t.bank_account_id = a.id and t.status = 'ACTIVE'
            order by t.id desc limit 1), a.opening_balance)
   where a.id = coalesce(new.bank_account_id, old.bank_account_id);
  return null;
end;
$$;

create trigger bank_transactions_sync
  after insert or update on public.bank_transactions
  for each row execute function app.bank_sync_balance();

-- Imported statement lines, staged before matching (spec §39).
create table public.bank_statement_lines (
  id               bigint generated always as identity primary key,
  dealer_id        uuid not null,
  bank_account_id  uuid not null,

  import_batch     uuid not null,
  statement_date   date not null,
  value_date       date,
  narration        text not null,
  reference        text,
  utr              text,
  upi_id           text,
  cheque_number    text,

  debit            numeric(18, 4) not null default 0,
  credit           numeric(18, 4) not null default 0,
  running_balance  numeric(18, 4),

  match_status     text not null default 'UNMATCHED',
  matched_transaction_id bigint,
  reconciliation_id uuid,

  raw_row          jsonb,
  created_at       timestamptz not null default now(),
  created_by       uuid,

  constraint bsl_account_tenant_fkey
    foreign key (bank_account_id, dealer_id) references public.bank_accounts (id, dealer_id),
  constraint bsl_status_check check (match_status in ('UNMATCHED', 'MATCHED', 'PARTIAL', 'IGNORED')),
  constraint bsl_amounts_check check (debit >= 0 and credit >= 0),
  constraint bsl_one_sided_check check ((debit > 0 and credit = 0) or (credit > 0 and debit = 0)),
  -- Spec §39: never mark reconciled without recording the link.
  constraint bsl_matched_link_check check (
    match_status <> 'MATCHED' or matched_transaction_id is not null
  )
);

create index bsl_account_date_idx on public.bank_statement_lines (bank_account_id, statement_date desc);
create index bsl_status_idx       on public.bank_statement_lines (bank_account_id, match_status);
create index bsl_batch_idx        on public.bank_statement_lines (import_batch);
create index bsl_utr_idx          on public.bank_statement_lines (dealer_id, utr) where utr is not null;

-- Duplicate protection on re-import: the same line twice is rejected.
create unique index bsl_dedupe_key
  on public.bank_statement_lines (bank_account_id, statement_date, debit, credit, coalesce(utr, ''), md5(narration));

create table public.bank_reconciliations (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null,
  bank_account_id  uuid not null,

  reconciliation_number text not null,
  from_date        date not null,
  to_date          date not null,
  statement_closing_balance numeric(18, 4) not null default 0,
  book_closing_balance      numeric(18, 4) not null default 0,
  difference       numeric(18, 4) generated always as (
    statement_closing_balance - book_closing_balance
  ) stored,

  matched_count    integer not null default 0,
  unmatched_count  integer not null default 0,

  status           text not null default 'DRAFT',
  completed_at     timestamptz,
  completed_by     uuid,
  notes            text,

  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       uuid,

  constraint br_number_key unique (dealer_id, reconciliation_number),
  constraint br_id_dealer_key unique (id, dealer_id),
  constraint br_account_tenant_fkey
    foreign key (bank_account_id, dealer_id) references public.bank_accounts (id, dealer_id),
  constraint br_status_check check (status in ('DRAFT', 'COMPLETED', 'CANCELLED')),
  constraint br_dates_check  check (to_date >= from_date)
);

create index br_account_idx on public.bank_reconciliations (bank_account_id, to_date desc);

alter table public.bank_statement_lines
  add constraint bsl_reconciliation_fkey
  foreign key (reconciliation_id) references public.bank_reconciliations (id) on delete set null;

alter table public.bank_transactions
  add constraint bt_reconciliation_fkey
  foreign key (reconciliation_id) references public.bank_reconciliations (id) on delete set null;

alter table public.bank_statement_lines
  add constraint bsl_matched_transaction_fkey
  foreign key (matched_transaction_id) references public.bank_transactions (id) on delete set null;

create trigger cash_accounts_set_updated_at before update on public.cash_accounts
  for each row execute function app.set_updated_at();
create trigger cdc_set_updated_at before update on public.cash_day_closings
  for each row execute function app.set_updated_at();
create trigger bank_accounts_set_updated_at before update on public.bank_accounts
  for each row execute function app.set_updated_at();
create trigger br_set_updated_at before update on public.bank_reconciliations
  for each row execute function app.set_updated_at();

create trigger cdc_audit after insert or update or delete on public.cash_day_closings
  for each row execute function app.audit_trigger();
create trigger bank_accounts_audit after insert or update or delete on public.bank_accounts
  for each row execute function app.audit_trigger();
create trigger br_audit after insert or update or delete on public.bank_reconciliations
  for each row execute function app.audit_trigger();

alter table public.cash_accounts        enable row level security;
alter table public.cash_day_closings    enable row level security;
alter table public.cash_transactions    enable row level security;
alter table public.bank_accounts        enable row level security;
alter table public.bank_transactions    enable row level security;
alter table public.bank_statement_lines enable row level security;
alter table public.bank_reconciliations enable row level security;

create policy cash_accounts_select on public.cash_accounts for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('cashbook.view')));
create policy cash_accounts_write on public.cash_accounts for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('admin.settings.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('admin.settings.manage')));

create policy cdc_select on public.cash_day_closings for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('cashbook.view')));
create policy cdc_write on public.cash_day_closings for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('cashbook.day_close') or app.has_permission('cashbook.day_reopen')
              or app.has_permission('cashbook.receipts.create'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy ct_select on public.cash_transactions for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('cashbook.view')));
create policy ct_insert on public.cash_transactions for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('cashbook.receipts.create') or app.has_permission('cashbook.payments.create'))));

create policy bank_accounts_select on public.bank_accounts for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.accounts.view')));
create policy bank_accounts_write on public.bank_accounts for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.accounts.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.accounts.manage')));

create policy bt_select on public.bank_transactions for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.book.view')));
create policy bt_write on public.bank_transactions for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('bank.reconcile') or app.has_permission('cashbook.payments.create'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy bsl_select on public.bank_statement_lines for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.reconcile')));
create policy bsl_write on public.bank_statement_lines for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('bank.statement.import') or app.has_permission('bank.reconcile'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy br_select on public.bank_reconciliations for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.reconcile')));
create policy br_write on public.bank_reconciliations for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.reconcile')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('bank.reconcile')));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.cash_accounts, public.cash_day_closings, public.bank_accounts, public.bank_statement_lines, public.bank_reconciliations, public.bank_transactions to authenticated';
    execute 'grant select, insert on public.cash_transactions to authenticated';
    execute 'grant all on public.cash_accounts, public.cash_day_closings, public.cash_transactions, public.bank_accounts, public.bank_transactions, public.bank_statement_lines, public.bank_reconciliations to service_role';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0023_service.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0023 — Service: job cards, service billing, counter sales
-- =============================================================================
-- Spec §32, §33. Service consumes the same inventory as counter sales and posts
-- through the same accounting engine, so there is no separate stock or ledger
-- mechanism here — only the documents.
--
-- Counter sales (§33) reuse the service invoice with no job card attached: the
-- transaction is identical apart from the absence of a vehicle.
--
-- Rollback: drop table public.service_payments, public.service_lines,
--           public.service_invoices, public.job_cards, public.customer_vehicles;
-- =============================================================================

-- -----------------------------------------------------------------------------
-- customer_vehicles — spec §44. What the customer owns, whether we sold it or not.
-- -----------------------------------------------------------------------------
create table public.customer_vehicles (
  id              uuid primary key default gen_random_uuid(),
  dealer_id       uuid not null references public.dealers (id) on delete cascade,
  customer_id     uuid not null,

  -- Present when the unit came from our own stock; absent for a walk-in service.
  vehicle_id      uuid,
  model_id        uuid,
  variant_id      uuid,

  registration_no text,
  chassis_no      text,
  engine_no       text,
  colour          text,
  purchase_date   date,

  status          text not null default 'ACTIVE',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint cv_id_dealer_key unique (id, dealer_id),
  constraint cv_customer_tenant_fkey
    foreign key (customer_id, dealer_id) references public.customers (id, dealer_id) on delete cascade,
  constraint cv_vehicle_tenant_fkey
    foreign key (vehicle_id, dealer_id) references public.vehicles (id, dealer_id),
  constraint cv_model_tenant_fkey
    foreign key (model_id, dealer_id) references public.vehicle_models (id, dealer_id),
  constraint cv_status_check check (status in ('ACTIVE', 'SOLD', 'SCRAPPED')),
  -- Something must identify the vehicle, or the record is useless for search.
  constraint cv_identity_check check (
    registration_no is not null or chassis_no is not null or vehicle_id is not null
  )
);

create unique index cv_registration_key on public.customer_vehicles (dealer_id, registration_no)
  where registration_no is not null;
create index cv_customer_idx on public.customer_vehicles (customer_id);
create index cv_chassis_idx  on public.customer_vehicles (dealer_id, chassis_no) where chassis_no is not null;

-- -----------------------------------------------------------------------------
-- job_cards — spec §32
-- -----------------------------------------------------------------------------
create table public.job_cards (
  id                  uuid primary key default gen_random_uuid(),
  dealer_id           uuid not null references public.dealers (id) on delete restrict,
  branch_id           uuid not null,

  job_card_number     text not null,
  job_date            date not null default current_date,

  customer_id         uuid not null,
  customer_vehicle_id uuid,
  registration_no     text,
  odometer            numeric(10, 1),

  service_type        text not null default 'PAID',
  complaint           text,
  diagnosis           text,

  service_advisor_id  uuid,
  technician_id       uuid,

  promised_at         timestamptz,
  status              text not null default 'OPEN',
  closed_at           timestamptz,

  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid,
  updated_by          uuid,

  constraint jc_number_key    unique (dealer_id, job_card_number),
  constraint jc_id_dealer_key unique (id, dealer_id),
  constraint jc_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint jc_customer_tenant_fkey
    foreign key (customer_id, dealer_id) references public.customers (id, dealer_id),
  constraint jc_vehicle_tenant_fkey
    foreign key (customer_vehicle_id, dealer_id) references public.customer_vehicles (id, dealer_id),
  constraint jc_advisor_tenant_fkey
    foreign key (service_advisor_id, dealer_id) references public.employees (id, dealer_id),
  constraint jc_technician_tenant_fkey
    foreign key (technician_id, dealer_id) references public.employees (id, dealer_id),
  constraint jc_type_check   check (service_type in ('FREE', 'PAID', 'WARRANTY', 'ACCIDENT', 'RUNNING_REPAIR')),
  constraint jc_status_check check (status in ('OPEN', 'IN_PROGRESS', 'READY', 'INVOICED', 'CLOSED', 'CANCELLED'))
);

create index jc_customer_idx    on public.job_cards (customer_id, job_date desc);
create index jc_branch_date_idx on public.job_cards (branch_id, job_date desc);
create index jc_status_idx      on public.job_cards (dealer_id, status);
create index jc_vehicle_idx     on public.job_cards (customer_vehicle_id) where customer_vehicle_id is not null;

-- -----------------------------------------------------------------------------
-- service_invoices — also used for counter sales (spec §33)
-- -----------------------------------------------------------------------------
create table public.service_invoices (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null references public.dealers (id) on delete restrict,
  branch_id        uuid not null,

  invoice_number   text not null,
  invoice_date     date not null default current_date,
  -- SERVICE when a job card is attached, COUNTER for over-the-counter sales.
  invoice_type     text not null default 'SERVICE',

  job_card_id      uuid,
  customer_id      uuid,

  taxable_value    numeric(18, 4) not null default 0,
  cgst_amount      numeric(18, 4) not null default 0,
  sgst_amount      numeric(18, 4) not null default 0,
  igst_amount      numeric(18, 4) not null default 0,
  discount_amount  numeric(18, 4) not null default 0,
  total_amount     numeric(18, 4) not null default 0,
  total_cost       numeric(18, 4) not null default 0,
  paid_amount      numeric(18, 4) not null default 0,

  status           text not null default 'DRAFT',
  posted_at        timestamptz,
  journal_entry_id uuid,
  idempotency_key  text,

  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       uuid,
  updated_by       uuid,

  constraint si_number_key    unique (dealer_id, invoice_number),
  constraint si_id_dealer_key unique (id, dealer_id),
  constraint si_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint si_job_card_tenant_fkey
    foreign key (job_card_id, dealer_id) references public.job_cards (id, dealer_id),
  constraint si_customer_tenant_fkey
    foreign key (customer_id, dealer_id) references public.customers (id, dealer_id),
  constraint si_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint si_type_check   check (invoice_type in ('SERVICE', 'COUNTER')),
  constraint si_status_check check (status in ('DRAFT', 'POSTED', 'CANCELLED', 'RETURNED')),
  constraint si_amounts_check check (
    taxable_value >= 0 and total_amount >= 0 and paid_amount >= 0 and total_cost >= 0
  ),
  constraint si_gst_mode_check check ((igst_amount = 0) or (cgst_amount = 0 and sgst_amount = 0)),
  -- A service invoice needs its job card; a counter sale must not have one.
  constraint si_job_card_shape_check check (
    (invoice_type = 'SERVICE' and job_card_id is not null)
    or (invoice_type = 'COUNTER' and job_card_id is null)
  ),
  constraint si_posted_journal_check check (status <> 'POSTED' or journal_entry_id is not null)
);

create unique index si_idempotency_key on public.service_invoices (dealer_id, idempotency_key)
  where idempotency_key is not null;
create index si_branch_date_idx on public.service_invoices (branch_id, invoice_date desc);
create index si_customer_idx    on public.service_invoices (customer_id) where customer_id is not null;
create index si_job_card_idx    on public.service_invoices (job_card_id) where job_card_id is not null;
create index si_status_idx      on public.service_invoices (dealer_id, status);

create table public.service_lines (
  id            uuid primary key default gen_random_uuid(),
  dealer_id     uuid not null,
  invoice_id    uuid not null,

  line_number   smallint not null,
  line_type     text not null,

  description   text not null,
  item_id       uuid,
  hsn_code      text,

  quantity      numeric(14, 3) not null default 1,
  unit_rate     numeric(18, 4) not null default 0,
  discount      numeric(18, 4) not null default 0,
  taxable_value numeric(18, 4) not null default 0,

  tax_code      text,
  cgst_rate     numeric(6, 3) not null default 0,
  sgst_rate     numeric(6, 3) not null default 0,
  igst_rate     numeric(6, 3) not null default 0,
  cgst_amount   numeric(18, 4) not null default 0,
  sgst_amount   numeric(18, 4) not null default 0,
  igst_amount   numeric(18, 4) not null default 0,
  total_amount  numeric(18, 4) not null default 0,

  unit_cost     numeric(18, 4) not null default 0,
  cost_amount   numeric(18, 4) not null default 0,
  stock_source  text,

  created_at    timestamptz not null default now(),

  constraint sl_line_key unique (invoice_id, line_number),
  constraint sl_invoice_tenant_fkey
    foreign key (invoice_id, dealer_id) references public.service_invoices (id, dealer_id) on delete cascade,
  constraint sl_item_tenant_fkey
    foreign key (item_id, dealer_id) references public.inventory_items (id, dealer_id),
  constraint sl_type_check   check (line_type in ('LABOUR', 'SPARE', 'ACCESSORY', 'OTHER_CHARGE', 'DISCOUNT')),
  constraint sl_source_check check (stock_source is null or stock_source in ('LOCAL', 'COMPANY')),
  constraint sl_amounts_check check (quantity > 0 and unit_rate >= 0 and taxable_value >= 0)
);

create index sl_invoice_idx on public.service_lines (invoice_id, line_number);
create index sl_item_idx     on public.service_lines (item_id) where item_id is not null;

create table public.service_payments (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null,
  invoice_id     uuid not null,

  receipt_number text not null,
  payment_date   date not null default current_date,
  amount         numeric(18, 4) not null,
  payment_mode   text not null,
  reference      text,

  journal_entry_id uuid,
  status         text not null default 'RECEIVED',
  created_at     timestamptz not null default now(),
  created_by     uuid,

  constraint sp_receipt_key unique (dealer_id, receipt_number),
  constraint sp_invoice_tenant_fkey
    foreign key (invoice_id, dealer_id) references public.service_invoices (id, dealer_id) on delete cascade,
  constraint sp_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint sp_amount_check check (amount > 0),
  constraint sp_mode_check check (payment_mode in ('CASH', 'CARD', 'UPI', 'NEFT', 'RTGS', 'IMPS', 'CHEQUE')),
  constraint sp_status_check check (status in ('RECEIVED', 'REVERSED'))
);

create index sp_invoice_idx on public.service_payments (invoice_id);

-- Totals from the lines; a posted invoice is frozen.
create or replace function app.service_sync_totals()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_invoice uuid := coalesce(new.invoice_id, old.invoice_id);
begin
  update public.service_invoices s
     set taxable_value   = coalesce(t.taxable, 0),
         cgst_amount     = coalesce(t.cgst, 0),
         sgst_amount     = coalesce(t.sgst, 0),
         igst_amount     = coalesce(t.igst, 0),
         discount_amount = coalesce(t.discount, 0),
         total_amount    = coalesce(t.total, 0),
         total_cost      = coalesce(t.cost, 0)
    from (
      select sum(l.taxable_value) taxable, sum(l.cgst_amount) cgst, sum(l.sgst_amount) sgst,
             sum(l.igst_amount) igst, sum(l.discount) discount, sum(l.total_amount) total,
             sum(l.cost_amount) cost
        from public.service_lines l where l.invoice_id = v_invoice
    ) t
   where s.id = v_invoice and s.status = 'DRAFT';
  return null;
end;
$$;

create trigger service_lines_sync_totals
  after insert or update or delete on public.service_lines
  for each row execute function app.service_sync_totals();

create or replace function app.service_invoice_guard()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    if old.status <> 'DRAFT' then
      raise exception 'Service invoice % is % and cannot be deleted.', old.invoice_number, old.status
        using errcode = 'insufficient_privilege';
    end if;
    return old;
  end if;

  if tg_op = 'INSERT' then
    if new.status <> 'DRAFT' then
      raise exception 'A service invoice is created as DRAFT.'
        using errcode = 'check_violation';
    end if;
    return new;
  end if;

  if old.status = 'POSTED' and new.status = 'POSTED'
     and (new.taxable_value   is distinct from old.taxable_value
       or new.cgst_amount     is distinct from old.cgst_amount
       or new.sgst_amount     is distinct from old.sgst_amount
       or new.igst_amount     is distinct from old.igst_amount
       or new.discount_amount is distinct from old.discount_amount
       or new.total_amount    is distinct from old.total_amount
       or new.total_cost      is distinct from old.total_cost
       or new.invoice_number  is distinct from old.invoice_number
       or new.invoice_date    is distinct from old.invoice_date
       or new.journal_entry_id is distinct from old.journal_entry_id) then
    raise exception 'Service invoice % is POSTED and immutable.', old.invoice_number
      using errcode = 'insufficient_privilege';
  end if;

  if new.status = 'POSTED' and old.status = 'DRAFT' then
    if new.journal_entry_id is null then
      raise exception 'A service invoice cannot be POSTED without its journal entry.'
        using errcode = 'check_violation';
    end if;
    new.posted_at := coalesce(new.posted_at, now());
  end if;

  return new;
end;
$$;

create trigger service_invoice_guard
  before insert or update or delete on public.service_invoices
  for each row execute function app.service_invoice_guard();

create or replace function app.service_sync_payments()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_invoice uuid := coalesce(new.invoice_id, old.invoice_id);
begin
  update public.service_invoices s
     set paid_amount = coalesce((
           select sum(p.amount) from public.service_payments p
            where p.invoice_id = v_invoice and p.status = 'RECEIVED'), 0)
   where s.id = v_invoice;
  return null;
end;
$$;

create trigger service_payments_sync
  after insert or update or delete on public.service_payments
  for each row execute function app.service_sync_payments();

create trigger cv_set_updated_at before update on public.customer_vehicles
  for each row execute function app.set_updated_at();
create trigger jc_set_updated_at before update on public.job_cards
  for each row execute function app.set_updated_at();
create trigger si_set_updated_at before update on public.service_invoices
  for each row execute function app.set_updated_at();

create trigger jc_audit after insert or update or delete on public.job_cards
  for each row execute function app.audit_trigger();
create trigger si_audit after insert or update or delete on public.service_invoices
  for each row execute function app.audit_trigger();

alter table public.customer_vehicles enable row level security;
alter table public.job_cards         enable row level security;
alter table public.service_invoices  enable row level security;
alter table public.service_lines     enable row level security;
alter table public.service_payments  enable row level security;

create policy cv_select on public.customer_vehicles for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('customers.view')));
create policy cv_write on public.customer_vehicles for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('customers.edit') or app.has_permission('service.jobcards.create'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy jc_select on public.job_cards for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id) and app.has_permission('service.jobcards.view')));
create policy jc_write on public.job_cards for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('service.jobcards.create')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.has_permission('service.jobcards.create')));

create policy si_select on public.service_invoices for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and app.can_access_branch(branch_id)
         and (app.has_permission('service.jobcards.view') or app.has_permission('inventory.view'))));
create policy si_write on public.service_invoices for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('service.billing.create') or app.has_permission('inventory.counter_sale.create'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy sl_select on public.service_lines for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('service.jobcards.view') or app.has_permission('inventory.view'))));
create policy sl_write on public.service_lines for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('service.billing.create') or app.has_permission('inventory.counter_sale.create'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy sp_select on public.service_payments for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('service.jobcards.view') or app.has_permission('inventory.view'))));
create policy sp_insert on public.service_payments for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('service.payments.collect') or app.has_permission('inventory.counter_sale.create'))));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update, delete on public.customer_vehicles, public.job_cards, public.service_invoices, public.service_lines to authenticated';
    execute 'grant select, insert on public.service_payments to authenticated';
    execute 'grant all on public.customer_vehicles, public.job_cards, public.service_invoices, public.service_lines, public.service_payments to service_role';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0024_gst_and_accounting_rules.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0024 — GST integration layer and accounting rules
-- =============================================================================
-- Spec §22, §40.
--
-- Two independent concerns, both about not hard-coding things:
--
--   accounting_rules  Spec §22: "Exact account mapping must be configurable
--                     through accounting rules. Do not hard-code account IDs in
--                     frontend code." A rule maps (module, event, component) to
--                     an account, so posting logic never names an account.
--
--   einvoices         Spec §40: an integration layer, not a coupling. The
--                     e-invoice row is separate from the invoice, so a failure at
--                     the GST portal leaves the accounting transaction untouched
--                     and simply leaves a FAILED row to retry.
--
-- Rollback: drop table public.eway_bills, public.einvoices, public.accounting_rules;
-- =============================================================================

-- =============================================================================
-- accounting_rules — spec §22
-- =============================================================================
create table public.accounting_rules (
  id           uuid primary key default gen_random_uuid(),
  dealer_id    uuid not null references public.dealers (id) on delete cascade,

  -- Which business event this rule serves.
  module       text not null,
  event        text not null,
  -- Which part of the document: EX_SHOWROOM, CGST, VEHICLE_COGS, CASH, …
  component    text not null,

  -- Which side the component posts to, and where.
  side         text not null,
  account_id   uuid not null,

  -- Optional narrowing: a branch may post to a different account.
  branch_id    uuid,
  priority     smallint not null default 100,

  description  text,
  status       text not null default 'ACTIVE',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  created_by   uuid,
  updated_by   uuid,

  constraint ar_id_dealer_key unique (id, dealer_id),
  constraint ar_account_tenant_fkey
    foreign key (account_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint ar_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint ar_module_check check (module in (
    'SALES', 'BOOKING', 'SERVICE', 'ACCESSORY', 'SPARE', 'FINANCE',
    'TRADE_ADVANCE', 'CASH', 'BANK', 'EXPENSE', 'INVENTORY', 'MANUAL', 'OPENING'
  )),
  constraint ar_side_check   check (side in ('DEBIT', 'CREDIT')),
  constraint ar_status_check check (status in ('ACTIVE', 'INACTIVE'))
);

comment on table public.accounting_rules is
  'Maps a business event component to a ledger account (spec §22). Posting code '
  'resolves accounts through this table so no account id is ever hard-coded.';

create unique index ar_scope_key
  on public.accounting_rules (dealer_id, module, event, component,
                              coalesce(branch_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where status = 'ACTIVE';

create index ar_lookup_idx on public.accounting_rules (dealer_id, module, event, status);

-- -----------------------------------------------------------------------------
-- public.resolve_account() — the only way posting code finds an account
-- -----------------------------------------------------------------------------
create or replace function public.resolve_account(
  p_dealer_id uuid,
  p_module    text,
  p_event     text,
  p_component text,
  p_branch_id uuid default null
)
returns uuid
language sql
stable
as $$
  select r.account_id
    from public.accounting_rules r
   where r.dealer_id = p_dealer_id
     and r.module = p_module
     and r.event = p_event
     and r.component = p_component
     and r.status = 'ACTIVE'
     and (r.branch_id is null or r.branch_id = p_branch_id)
   -- A branch-specific rule beats the dealer-wide default.
   order by (r.branch_id is not null) desc, r.priority
   limit 1;
$$;

comment on function public.resolve_account(uuid, text, text, text, uuid) is
  'Resolves the ledger account for a posting component (spec §22). Returns NULL '
  'when unconfigured, which the posting service must treat as an error rather '
  'than guessing an account.';

-- =============================================================================
-- einvoices — spec §40
-- =============================================================================
create table public.einvoices (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null references public.dealers (id) on delete cascade,

  -- Polymorphic: a vehicle sale or a service invoice.
  document_type     text not null,
  document_id       uuid not null,
  document_number   text not null,
  document_date     date not null,

  status            text not null default 'PENDING',

  -- What the portal gave back.
  irn               text,
  ack_number        text,
  ack_date          timestamptz,
  signed_qr_code    text,
  signed_invoice    text,

  -- What we sent and what came back, for the audit reference §40 requires.
  request_payload   jsonb,
  response_payload  jsonb,
  error_code        text,
  error_message     text,

  attempt_count     integer not null default 0,
  last_attempt_at   timestamptz,
  cancelled_at      timestamptz,
  cancel_reason     text,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid,

  constraint einvoices_document_key unique (dealer_id, document_type, document_id),
  constraint einvoices_irn_key      unique (irn),
  constraint einvoices_type_check   check (document_type in ('SALE', 'SERVICE_INVOICE')),
  constraint einvoices_status_check check (status in ('PENDING', 'GENERATED', 'FAILED', 'CANCELLED')),
  -- A generated e-invoice must carry the portal's identifiers.
  constraint einvoices_generated_check check (
    status <> 'GENERATED' or (irn is not null and ack_number is not null)
  ),
  constraint einvoices_failed_check check (status <> 'FAILED' or error_message is not null),
  constraint einvoices_cancel_check check (cancelled_at is null or cancel_reason is not null)
);

comment on table public.einvoices is
  'E-invoice integration layer (spec §40). Separate from the invoice, so a portal '
  'failure never corrupts the accounting transaction — the document stays posted '
  'and this row records FAILED for retry.';

create index einvoices_status_idx   on public.einvoices (dealer_id, status);
create index einvoices_document_idx on public.einvoices (document_type, document_id);
create index einvoices_retry_idx    on public.einvoices (dealer_id, last_attempt_at) where status = 'FAILED';

create table public.eway_bills (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null references public.dealers (id) on delete cascade,

  document_type    text not null,
  document_id      uuid not null,
  document_number  text not null,

  status           text not null default 'PENDING',
  eway_bill_number text,
  generated_at     timestamptz,
  valid_until      timestamptz,

  transport_mode   text,
  vehicle_number   text,
  transporter_id   text,
  transporter_name text,
  distance_km      integer,

  request_payload  jsonb,
  response_payload jsonb,
  error_message    text,
  attempt_count    integer not null default 0,

  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       uuid,

  constraint eway_document_key unique (dealer_id, document_type, document_id),
  constraint eway_number_key   unique (eway_bill_number),
  constraint eway_type_check   check (document_type in ('SALE', 'SERVICE_INVOICE', 'TRANSFER')),
  constraint eway_status_check check (status in ('PENDING', 'GENERATED', 'FAILED', 'CANCELLED', 'EXPIRED')),
  constraint eway_mode_check   check (transport_mode is null or transport_mode in ('ROAD', 'RAIL', 'AIR', 'SHIP')),
  constraint eway_generated_check check (status <> 'GENERATED' or eway_bill_number is not null)
);

create index eway_status_idx   on public.eway_bills (dealer_id, status);
create index eway_document_idx on public.eway_bills (document_type, document_id);

-- Retry bookkeeping belongs to the database, not the caller.
create or replace function app.einvoice_attempt()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status
     and new.status in ('GENERATED', 'FAILED') then
    new.attempt_count := old.attempt_count + 1;
    new.last_attempt_at := now();
  end if;
  return new;
end;
$$;

create trigger einvoice_attempt before update on public.einvoices
  for each row execute function app.einvoice_attempt();

create trigger ar_set_updated_at before update on public.accounting_rules
  for each row execute function app.set_updated_at();
create trigger einvoices_set_updated_at before update on public.einvoices
  for each row execute function app.set_updated_at();
create trigger eway_set_updated_at before update on public.eway_bills
  for each row execute function app.set_updated_at();

create trigger ar_audit after insert or update or delete on public.accounting_rules
  for each row execute function app.audit_trigger();

alter table public.accounting_rules enable row level security;
alter table public.einvoices        enable row level security;
alter table public.eway_bills       enable row level security;

create policy ar_select on public.accounting_rules for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.coa.view')));
create policy ar_write on public.accounting_rules for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.coa.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.coa.manage')));

create policy einvoices_select on public.einvoices for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('gst.summary.view')));
create policy einvoices_write on public.einvoices for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('gst.einvoice.generate') or app.has_permission('gst.einvoice.retry'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy eway_select on public.eway_bills for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('gst.summary.view')));
create policy eway_write on public.eway_bills for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('gst.ewaybill.generate')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('gst.ewaybill.generate')));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update, delete on public.accounting_rules to authenticated';
    execute 'grant select, insert, update on public.einvoices, public.eway_bills to authenticated';
    execute 'grant all on public.accounting_rules, public.einvoices, public.eway_bills to service_role';
    execute 'grant execute on function public.resolve_account(uuid, text, text, text, uuid) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0025_posting_engine.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0025 — The posting engine
-- =============================================================================
-- Spec §21, §22, §48, §49, §50. The most important code in the product.
--
-- Spec §48 lists thirteen steps a vehicle sale must perform, and ends: "If any
-- critical step fails, rollback the transaction. Never create an invoice without
-- its accounting/inventory effects being consistent."
--
-- That guarantee cannot be made from application code talking to PostgREST: each
-- REST call is its own transaction, so a crash between "create invoice" and
-- "post journal" leaves the books wrong. So the whole sequence lives in one
-- PL/pgSQL function and runs in one transaction.
--
-- These are SECURITY INVOKER, so RLS still applies to every table they touch —
-- the posting engine has no more reach than the user who called it.
--
-- Rollback: drop the functions below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- app.post_journal() — the single entry point to the ledger
-- -----------------------------------------------------------------------------
-- Every module posts through this. Lines arrive as JSONB:
--   [{"account_id": "...", "debit": 100, "credit": 0, "narration": "...",
--     "party_type": "CUSTOMER", "party_id": "..."}]
--
-- Rejects an unbalanced set before writing anything, so a caller cannot leave a
-- half-built draft behind on failure.
-- -----------------------------------------------------------------------------
create or replace function app.post_journal(
  p_dealer_id       uuid,
  p_branch_id       uuid,
  p_entry_date      date,
  p_source_module   text,
  p_narration       text,
  p_lines           jsonb,
  p_source_document_type text default null,
  p_source_document_id   uuid default null,
  p_idempotency_key      text default null,
  -- Reversal linkage is supplied at creation, not stamped afterwards: the entry
  -- is POSTED by the time this function returns, and a posted journal is
  -- immutable (spec §23). There is no later moment to write it.
  p_reversal_of_id       uuid default null,
  p_reversal_reason      text default null
)
returns uuid
language plpgsql
as $$
declare
  v_entry_id  uuid;
  v_number    text;
  v_year      text;
  v_period_id uuid;
  v_debit     numeric(18, 4) := 0;
  v_credit    numeric(18, 4) := 0;
  v_line      jsonb;
  v_index     smallint := 0;
  v_existing  uuid;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    raise exception 'A journal needs at least two lines.'
      using errcode = 'check_violation';
  end if;

  -- Idempotency (spec §50): a repeated submission returns the original entry
  -- rather than posting a second one.
  if p_idempotency_key is not null then
    select id into v_existing
      from public.journal_entries
     where dealer_id = p_dealer_id and idempotency_key = p_idempotency_key;
    if v_existing is not null then
      return v_existing;
    end if;
  end if;

  -- Balance before touching anything.
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_debit  := v_debit  + coalesce((v_line ->> 'debit')::numeric, 0);
    v_credit := v_credit + coalesce((v_line ->> 'credit')::numeric, 0);
  end loop;

  if round(v_debit, 4) <> round(v_credit, 4) then
    raise exception 'Journal does not balance: debit % <> credit %.', v_debit, v_credit
      using errcode = 'check_violation',
            hint = 'Spec §22: total debit must equal total credit.';
  end if;

  v_year   := app.financial_year_token(p_dealer_id, p_entry_date);
  v_number := app.next_document_number(p_dealer_id, null, 'JOURNAL', v_year);

  select id into v_period_id
    from public.accounting_periods
   where dealer_id = p_dealer_id
     and p_entry_date between start_date and end_date
   limit 1;

  -- An entry dated into a closed period must not post (spec §44).
  if v_period_id is not null then
    if (select status from public.accounting_periods where id = v_period_id) <> 'OPEN' then
      raise exception 'The accounting period covering % is closed.', p_entry_date
        using errcode = 'insufficient_privilege';
    end if;
  end if;

  insert into public.journal_entries
    (dealer_id, branch_id, entry_number, entry_date, period_id, source_module,
     source_document_type, source_document_id, narration, idempotency_key,
     reversal_of_id, reversal_reason, created_by)
  values
    (p_dealer_id, p_branch_id, v_number, p_entry_date, v_period_id, p_source_module,
     p_source_document_type, p_source_document_id, p_narration, p_idempotency_key,
     p_reversal_of_id, p_reversal_reason, auth.uid())
  returning id into v_entry_id;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_index := v_index + 1;

    if (v_line ->> 'account_id') is null then
      raise exception 'Journal line % has no account. Check the accounting rules for this event.', v_index
        using errcode = 'check_violation',
              hint = 'Spec §22: accounts are resolved from accounting_rules, never hard-coded.';
    end if;

    insert into public.journal_entry_lines
      (journal_entry_id, dealer_id, line_number, account_id, branch_id,
       debit, credit, narration, party_type, party_id)
    values
      (v_entry_id, p_dealer_id, v_index, (v_line ->> 'account_id')::uuid, p_branch_id,
       coalesce((v_line ->> 'debit')::numeric, 0),
       coalesce((v_line ->> 'credit')::numeric, 0),
       v_line ->> 'narration',
       v_line ->> 'party_type',
       (v_line ->> 'party_id')::uuid);
  end loop;

  -- The trigger in 0007 recomputes totals from the lines and refuses to post
  -- anything unbalanced, so this is the second, independent check.
  update public.journal_entries set status = 'POSTED', posted_by = auth.uid()
   where id = v_entry_id;

  return v_entry_id;
end;
$$;

comment on function app.post_journal(uuid, uuid, date, text, text, jsonb, text, uuid, text, uuid, text) is
  'The single entry point to the ledger (spec §21, §60.18). Balances, numbers, '
  'and posts one journal atomically. Idempotent when given a key (spec §50).';

-- -----------------------------------------------------------------------------
-- app.reverse_journal() — the only way to undo a posting (spec §23)
-- -----------------------------------------------------------------------------
create or replace function app.reverse_journal(
  p_journal_entry_id uuid,
  p_reason           text,
  p_reversal_date    date default current_date
)
returns uuid
language plpgsql
as $$
declare
  v_original public.journal_entries;
  v_lines    jsonb;
  v_new_id   uuid;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reversal requires a reason.'
      using errcode = 'check_violation',
            hint = 'Spec §23: every reversal records reason, user, timestamp and reference.';
  end if;

  select * into v_original from public.journal_entries where id = p_journal_entry_id;

  if v_original.id is null then
    raise exception 'Journal entry not found.' using errcode = 'no_data_found';
  end if;
  if v_original.status <> 'POSTED' then
    raise exception 'Only a POSTED journal can be reversed; this one is %.', v_original.status
      using errcode = 'check_violation';
  end if;

  -- The mirror image: every debit becomes a credit and vice versa.
  select jsonb_agg(jsonb_build_object(
           'account_id', l.account_id,
           'debit',      l.credit,
           'credit',     l.debit,
           'narration',  coalesce(l.narration, '') || ' (reversal)',
           'party_type', l.party_type,
           'party_id',   l.party_id
         ) order by l.line_number)
    into v_lines
    from public.journal_entry_lines l
   where l.journal_entry_id = p_journal_entry_id;

  v_new_id := app.post_journal(
    v_original.dealer_id, v_original.branch_id, p_reversal_date,
    v_original.source_module,
    'Reversal of ' || v_original.entry_number || ' — ' || p_reason,
    v_lines,
    v_original.source_document_type, v_original.source_document_id,
    null,
    p_journal_entry_id, p_reason
  );

  -- Marking the original reversed is the one edit a posted journal permits.
  update public.journal_entries
     set status = 'REVERSED', reversed_by_id = v_new_id, reversal_reason = p_reason
   where id = p_journal_entry_id;

  return v_new_id;
end;
$$;

comment on function app.reverse_journal(uuid, text, date) is
  'Posts the mirror image of a journal and marks the original REVERSED (spec §23). '
  'The only sanctioned way to undo a posting.';

-- -----------------------------------------------------------------------------
-- app.require_account() — resolve or fail
-- -----------------------------------------------------------------------------
-- Posting must never guess. An unconfigured mapping puts the entry in the wrong
-- place, which is harder to find and fix than a refusal to post.
-- -----------------------------------------------------------------------------
create or replace function app.require_account(
  p_dealer_id uuid,
  p_module    text,
  p_event     text,
  p_component text,
  p_branch_id uuid
)
returns uuid
language plpgsql
stable
as $$
declare
  v_id uuid;
begin
  v_id := public.resolve_account(p_dealer_id, p_module, p_event, p_component, p_branch_id);
  if v_id is null then
    raise exception 'No accounting rule for %/%/%. Configure it before posting.',
      p_module, p_event, p_component
      using errcode = 'no_data_found',
            hint = 'Spec §22: account mapping is configuration, not code.';
  end if;
  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.post_vehicle_sale() — spec §48, all thirteen steps, one transaction
-- -----------------------------------------------------------------------------
create or replace function public.post_vehicle_sale(
  p_sale_id uuid,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_sale    public.sales;
  v_vehicle public.vehicles;
  v_lines   jsonb := '[]'::jsonb;
  v_entry   uuid;
  v_account uuid;
  v_line    record;
  v_cogs    numeric(18, 4) := 0;
begin
  -- Step 3: lock the sale and the vehicle. A second concurrent post blocks here
  -- and then fails the status check below (spec §49).
  select * into v_sale from public.sales where id = p_sale_id for update;

  if v_sale.id is null then
    raise exception 'Sale not found.' using errcode = 'no_data_found';
  end if;

  if v_sale.status <> 'APPROVED' then
    raise exception 'Sale % is % — only an APPROVED sale can be posted.', v_sale.invoice_number, v_sale.status
      using errcode = 'check_violation',
            hint = 'Spec §19: posting happens only after accounts approval.';
  end if;

  select * into v_vehicle from public.vehicles where id = v_sale.vehicle_id for update;

  if v_vehicle.status not in ('IN_STOCK', 'BOOKED') then
    raise exception 'Vehicle % is % and cannot be sold.', v_vehicle.chassis_no, v_vehicle.status
      using errcode = 'check_violation';
  end if;

  -- Step 8–10: build the journal from the invoice lines, resolving every account
  -- through accounting_rules.
  v_lines := v_lines || jsonb_build_array(jsonb_build_object(
    'account_id', app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'RECEIVABLE', v_sale.branch_id),
    'debit', v_sale.total_amount, 'credit', 0,
    'narration', 'Sale ' || v_sale.invoice_number,
    'party_type', 'CUSTOMER', 'party_id', v_sale.customer_id
  ));

  for v_line in
    select line_type, sum(taxable_value) taxable, sum(cost_amount) cost
      from public.sale_lines where sale_id = p_sale_id
     group by line_type
  loop
    if v_line.taxable > 0 then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'account_id', app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', v_line.line_type, v_sale.branch_id),
        'debit', 0, 'credit', v_line.taxable,
        'narration', v_line.line_type || ' revenue'
      ));
    end if;
    v_cogs := v_cogs + coalesce(v_line.cost, 0);
  end loop;

  if v_sale.cgst_amount > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'CGST', v_sale.branch_id),
      'debit', 0, 'credit', v_sale.cgst_amount, 'narration', 'Output CGST'));
  end if;
  if v_sale.sgst_amount > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'SGST', v_sale.branch_id),
      'debit', 0, 'credit', v_sale.sgst_amount, 'narration', 'Output SGST'));
  end if;
  if v_sale.igst_amount > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'IGST', v_sale.branch_id),
      'debit', 0, 'credit', v_sale.igst_amount, 'narration', 'Output IGST'));
  end if;

  -- Step 11: inventory relief and COGS recognition (spec §22).
  if v_cogs > 0 then
    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('account_id', app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'COGS', v_sale.branch_id),
                         'debit', v_cogs, 'credit', 0, 'narration', 'Cost of goods sold'),
      jsonb_build_object('account_id', app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'INVENTORY', v_sale.branch_id),
                         'debit', 0, 'credit', v_cogs, 'narration', 'Inventory relief'));
  end if;

  -- Steps 10 and 13: post atomically. Unbalanced input raises and the whole
  -- function rolls back, leaving neither invoice status nor stock changed.
  v_entry := app.post_journal(
    v_sale.dealer_id, v_sale.branch_id, v_sale.invoice_date, 'SALES',
    'Vehicle sale ' || v_sale.invoice_number, v_lines,
    'SALE', v_sale.id,
    coalesce(p_idempotency_key, 'sale:' || v_sale.id::text)
  );

  -- Step 12: vehicle status.
  update public.vehicles
     set status = 'SOLD_PENDING_DELIVERY', sale_id = v_sale.id, updated_by = auth.uid()
   where id = v_sale.vehicle_id;

  update public.sales
     set status = 'POSTED', journal_entry_id = v_entry, posted_by = auth.uid()
   where id = p_sale_id;

  return v_entry;
end;
$$;

comment on function public.post_vehicle_sale(uuid, text) is
  'Posts an approved vehicle sale: journal, inventory relief, COGS and vehicle '
  'status, in one transaction (spec §48). Any failure rolls the whole thing back.';

-- -----------------------------------------------------------------------------
-- public.consume_fitting_stock() — allocate, issue and record the source (§31)
-- -----------------------------------------------------------------------------
create or replace function public.consume_fitting_stock(
  p_sale_id   uuid,
  p_item_id   uuid,
  p_quantity  numeric,
  p_unit_rate numeric
)
returns void
language plpgsql
as $$
declare
  v_sale  public.sales;
  v_alloc record;
  v_next  smallint;
  v_item  public.inventory_items;
begin
  select * into v_sale from public.sales where id = p_sale_id for update;
  if v_sale.status not in ('DRAFT', 'SUBMITTED') then
    raise exception 'Fittings can only be added while the sale is being prepared.'
      using errcode = 'check_violation';
  end if;

  select * into v_item from public.inventory_items where id = p_item_id;

  select coalesce(max(line_number), 0) into v_next from public.sale_lines where sale_id = p_sale_id;

  -- One invoice line per source, so LOCAL and COMPANY consumption is visible on
  -- the document rather than hidden behind a single total (spec §31).
  for v_alloc in select * from public.allocate_stock(p_item_id, v_sale.branch_id, p_quantity) loop
    if v_alloc.source = 'SHORTFALL' then
      raise exception 'Insufficient stock for %: short by %.', v_item.name, v_alloc.quantity
        using errcode = 'check_violation',
              hint = 'Spec §31: block or route for approval rather than overselling.';
    end if;

    v_next := v_next + 1;

    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, item_id,
       quantity, unit_rate, taxable_value, total_amount,
       unit_cost, cost_amount, stock_source)
    values
      (p_sale_id, v_sale.dealer_id, v_next, 'FITTING',
       v_item.name || ' (' || v_alloc.source || ')', p_item_id,
       v_alloc.quantity, p_unit_rate, round(p_unit_rate * v_alloc.quantity, 4),
       round(p_unit_rate * v_alloc.quantity, 4),
       v_alloc.unit_cost, round(v_alloc.unit_cost * v_alloc.quantity, 4), v_alloc.source);

    insert into public.inventory_transactions
      (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
       reference_type, reference_id, reference_number, narration, created_by)
    values
      (v_sale.dealer_id, v_sale.branch_id, p_item_id, v_alloc.source, 'SALE',
       -v_alloc.quantity, v_alloc.unit_cost, 'SALE', p_sale_id, v_sale.invoice_number,
       'Fitted to ' || v_sale.invoice_number, auth.uid());
  end loop;
end;
$$;

comment on function public.consume_fitting_stock(uuid, uuid, numeric, numeric) is
  'Allocates LOCAL before COMPANY stock, writes one invoice line per source and '
  'one ledger row per source (spec §31: never hide the source).';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function app.post_journal(uuid, uuid, date, text, text, jsonb, text, uuid, text, uuid, text) to authenticated';
    execute 'grant execute on function app.require_account(uuid, text, text, text, uuid) to authenticated';
    execute 'grant execute on function app.reverse_journal(uuid, text, date) to authenticated';
    execute 'grant execute on function public.post_vehicle_sale(uuid, text) to authenticated';
    execute 'grant execute on function public.consume_fitting_stock(uuid, uuid, numeric, numeric) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0026_reports.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0026 — Reporting functions
-- =============================================================================
-- Spec §41, §43. Reports are database functions rather than application queries
-- for two reasons: aggregation belongs where the rows are, and SECURITY INVOKER
-- means RLS scopes every report to the caller's dealer and branches without the
-- report itself having to remember to filter (spec §43, "Consolidated reporting
-- must respect tenant isolation").
--
-- Rollback: drop the functions below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Trial balance — spec §41
-- -----------------------------------------------------------------------------
create or replace function public.trial_balance(
  p_as_on     date default current_date,
  p_branch_id uuid default null
)
returns table (
  account_id     uuid,
  account_code   text,
  account_name   text,
  account_type   text,
  debit_balance  numeric(18, 4),
  credit_balance numeric(18, 4)
)
language sql
stable
as $$
  select b.account_id, b.account_code, b.account_name, b.account_type,
         -- A balance shows on the side its account normally sits on; a negative
         -- balance flips to the other column rather than showing as a minus.
         case when b.closing_balance >= 0 and b.normal_balance = 'DEBIT'  then b.closing_balance
              when b.closing_balance <  0 and b.normal_balance = 'CREDIT' then -b.closing_balance
              else 0 end,
         case when b.closing_balance >= 0 and b.normal_balance = 'CREDIT' then b.closing_balance
              when b.closing_balance <  0 and b.normal_balance = 'DEBIT'  then -b.closing_balance
              else 0 end
    from public.account_balances(date '1900-01-01', p_as_on, p_branch_id) b
   where b.closing_debit <> 0 or b.closing_credit <> 0
   order by b.account_code;
$$;

comment on function public.trial_balance(date, uuid) is
  'Trial balance as at a date (spec §41). Totals are guaranteed equal because the '
  'database refuses to post an unbalanced journal.';

-- -----------------------------------------------------------------------------
-- Profit and loss — spec §41
-- -----------------------------------------------------------------------------
create or replace function public.profit_and_loss(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  section      text,
  account_code text,
  account_name text,
  amount       numeric(18, 4)
)
language sql
stable
as $$
  select case when b.account_type = 'INCOME' then 'INCOME' else 'EXPENSE' end,
         b.account_code, b.account_name, b.period_movement
    from public.account_balances(p_from, p_to, p_branch_id) b
   where b.account_type in ('INCOME', 'EXPENSE')
     and b.period_movement <> 0
   order by 1 desc, b.account_code;
$$;

comment on function public.profit_and_loss(date, date, uuid) is
  'Income and expense movement for a period (spec §41). Balance-sheet accounts are '
  'excluded: they carry cumulative balances, not period results.';

-- -----------------------------------------------------------------------------
-- Balance sheet — spec §41
-- -----------------------------------------------------------------------------
create or replace function public.balance_sheet(
  p_as_on     date default current_date,
  p_branch_id uuid default null
)
returns table (
  section      text,
  account_code text,
  account_name text,
  amount       numeric(18, 4)
)
language sql
stable
as $$
  select b.account_type, b.account_code, b.account_name, b.closing_balance
    from public.account_balances(date '1900-01-01', p_as_on, p_branch_id) b
   where b.account_type in ('ASSET', 'LIABILITY', 'EQUITY')
     and b.closing_balance <> 0
  union all
  -- Retained result to date. Without it the sheet cannot balance, because income
  -- and expense have not yet been closed into equity.
  select 'EQUITY', 'RESULT', 'Profit / (loss) to date',
         coalesce(sum(case when b.account_type = 'INCOME' then b.closing_balance
                           else -b.closing_balance end), 0)
    from public.account_balances(date '1900-01-01', p_as_on, p_branch_id) b
   where b.account_type in ('INCOME', 'EXPENSE')
  order by 1, 2;
$$;

comment on function public.balance_sheet(date, uuid) is
  'Assets, liabilities and equity as at a date (spec §41), including the retained '
  'result so the statement balances.';

-- -----------------------------------------------------------------------------
-- Vehicle stock with ageing — spec §41
-- -----------------------------------------------------------------------------
create or replace function public.vehicle_stock_report(
  p_branch_id uuid default null
)
returns table (
  vehicle_id     uuid,
  chassis_no     text,
  engine_no      text,
  brand          text,
  model_name     text,
  variant_name   text,
  branch_name    text,
  status         text,
  stock_date     date,
  age_days       integer,
  age_bucket     text,
  purchase_cost  numeric(18, 4)
)
language sql
stable
as $$
  select v.id, v.chassis_no, v.engine_no, m.brand, m.name, vr.name, b.name,
         v.status, v.stock_date,
         (current_date - v.stock_date)::integer,
         case
           when current_date - v.stock_date <=  30 then '0-30'
           when current_date - v.stock_date <=  60 then '31-60'
           when current_date - v.stock_date <=  90 then '61-90'
           when current_date - v.stock_date <= 180 then '91-180'
           else '180+'
         end,
         v.purchase_cost
    from public.vehicles v
    join public.vehicle_models m on m.id = v.model_id
    left join public.vehicle_variants vr on vr.id = v.variant_id
    join public.branches b on b.id = v.branch_id
   where v.status = 'IN_STOCK'
     and (p_branch_id is null or v.branch_id = p_branch_id)
   order by v.stock_date;
$$;

comment on function public.vehicle_stock_report(uuid) is
  'Chassis-level stock with ageing buckets (spec §41). Rows, not quantities.';

-- -----------------------------------------------------------------------------
-- Accessory and spare stock, LOCAL/COMPANY split — spec §28
-- -----------------------------------------------------------------------------
create or replace function public.inventory_stock_report(
  p_branch_id uuid default null,
  p_item_type text default null
)
returns table (
  item_id       uuid,
  item_code     text,
  item_name     text,
  item_type     text,
  branch_name   text,
  local_qty     numeric(14, 3),
  company_qty   numeric(14, 3),
  total_qty     numeric(14, 3),
  local_value   numeric(18, 4),
  company_value numeric(18, 4),
  total_value   numeric(18, 4)
)
language sql
stable
as $$
  select i.id, i.item_code, i.name, i.item_type, b.name,
         coalesce(sum(s.quantity)    filter (where s.source = 'LOCAL'), 0),
         coalesce(sum(s.quantity)    filter (where s.source = 'COMPANY'), 0),
         coalesce(sum(s.quantity), 0),
         coalesce(sum(s.stock_value) filter (where s.source = 'LOCAL'), 0),
         coalesce(sum(s.stock_value) filter (where s.source = 'COMPANY'), 0),
         coalesce(sum(s.stock_value), 0)
    from public.inventory_stock s
    join public.inventory_items i on i.id = s.item_id
    join public.branches b on b.id = s.branch_id
   where (p_branch_id is null or s.branch_id = p_branch_id)
     and (p_item_type is null or i.item_type = p_item_type)
   group by i.id, i.item_code, i.name, i.item_type, b.name
  having coalesce(sum(s.quantity), 0) <> 0
   order by i.item_code;
$$;

comment on function public.inventory_stock_report(uuid, text) is
  'Stock with the LOCAL / COMPANY split spec §28 requires displayed side by side.';

-- -----------------------------------------------------------------------------
-- Sales summary with margin — spec §41
-- -----------------------------------------------------------------------------
-- Margin is returned here; withholding it from unauthorised roles is the service
-- layer's job, because RLS cannot hide a column, only a row.
-- -----------------------------------------------------------------------------
create or replace function public.sales_summary(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null,
  p_group_by  text default 'MODEL'
)
returns table (
  group_key    text,
  group_label  text,
  unit_count   bigint,
  gross_amount numeric(18, 4),
  tax_amount   numeric(18, 4),
  cost_amount  numeric(18, 4),
  margin       numeric(18, 4)
)
language sql
stable
as $$
  select
    case p_group_by
      when 'BRANCH'   then b.id::text
      when 'EMPLOYEE' then coalesce(e.id::text, 'none')
      when 'DAY'      then s.invoice_date::text
      else m.id::text
    end,
    case p_group_by
      when 'BRANCH'   then b.name
      when 'EMPLOYEE' then coalesce(e.name, 'Unassigned')
      when 'DAY'      then to_char(s.invoice_date, 'DD Mon YYYY')
      else m.brand || ' ' || m.name
    end,
    count(*),
    sum(s.total_amount),
    sum(s.cgst_amount + s.sgst_amount + s.igst_amount + s.cess_amount),
    sum(s.total_cost),
    sum(s.taxable_value - s.total_cost)
  from public.sales s
  join public.vehicles v on v.id = s.vehicle_id
  join public.vehicle_models m on m.id = v.model_id
  join public.branches b on b.id = s.branch_id
  left join public.employees e on e.id = s.sales_executive_id
 where s.status in ('POSTED', 'DELIVERED')
   and s.invoice_date between p_from and p_to
   and (p_branch_id is null or s.branch_id = p_branch_id)
 group by 1, 2
 order by 4 desc;
$$;

comment on function public.sales_summary(date, date, uuid, text) is
  'Sales grouped by model, branch, employee or day (spec §41). Includes cost and '
  'margin; the service layer strips those for roles without permission (spec §52).';

-- -----------------------------------------------------------------------------
-- GST output summary — spec §41
-- -----------------------------------------------------------------------------
create or replace function public.gst_summary(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  hsn_code      text,
  description   text,
  taxable_value numeric(18, 4),
  cgst_amount   numeric(18, 4),
  sgst_amount   numeric(18, 4),
  igst_amount   numeric(18, 4),
  total_tax     numeric(18, 4),
  document_count bigint
)
language sql
stable
as $$
  -- Vehicle sales and service invoices carry the same tax shape, so they are
  -- unioned and grouped by HSN rather than reported separately.
  with lines as (
    select coalesce(l.hsn_code, 'UNSPECIFIED') hsn, l.taxable_value,
           l.cgst_amount, l.sgst_amount, l.igst_amount, s.id doc
      from public.sale_lines l
      join public.sales s on s.id = l.sale_id
     where s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select coalesce(l.hsn_code, 'UNSPECIFIED'), l.taxable_value,
           l.cgst_amount, l.sgst_amount, l.igst_amount, si.id
      from public.service_lines l
      join public.service_invoices si on si.id = l.invoice_id
     where si.status = 'POSTED'
       and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
  )
  select lines.hsn,
         coalesce(max(h.description), ''),
         sum(lines.taxable_value), sum(lines.cgst_amount), sum(lines.sgst_amount),
         sum(lines.igst_amount),
         sum(lines.cgst_amount + lines.sgst_amount + lines.igst_amount),
         count(distinct lines.doc)
    from lines
    left join public.hsn_codes h on h.code = lines.hsn
   group by lines.hsn
   order by lines.hsn;
$$;

comment on function public.gst_summary(date, date, uuid) is
  'HSN-wise output tax for a period (spec §41). Reads the tax stored on each line, '
  'not the current tax master, so historical figures never move (spec §16).';

-- -----------------------------------------------------------------------------
-- Customer ledger — spec §41
-- -----------------------------------------------------------------------------
create or replace function public.customer_ledger(
  p_customer_id uuid,
  p_from        date,
  p_to          date
)
returns table (
  entry_date    date,
  entry_number  text,
  narration     text,
  debit         numeric(18, 4),
  credit        numeric(18, 4),
  running_balance numeric(18, 4)
)
language sql
stable
as $$
  -- The subsidiary ledger is derived from party-tagged journal lines, so it
  -- reconciles to the receivable control account by construction.
  select je.entry_date, je.entry_number, coalesce(l.narration, je.narration),
         l.debit, l.credit,
         sum(l.debit - l.credit) over (order by je.entry_date, je.entry_number, l.line_number
                                       rows between unbounded preceding and current row)
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.party_type = 'CUSTOMER'
     and l.party_id = p_customer_id
     and je.status in ('POSTED', 'REVERSED')
     and je.entry_date between p_from and p_to
   order by je.entry_date, je.entry_number, l.line_number;
$$;

comment on function public.customer_ledger(uuid, date, date) is
  'Customer running account from the general ledger (spec §41), so the subsidiary '
  'ledger and the control account can never disagree.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.trial_balance(date, uuid) to authenticated';
    execute 'grant execute on function public.profit_and_loss(date, date, uuid) to authenticated';
    execute 'grant execute on function public.balance_sheet(date, uuid) to authenticated';
    execute 'grant execute on function public.vehicle_stock_report(uuid) to authenticated';
    execute 'grant execute on function public.inventory_stock_report(uuid, text) to authenticated';
    execute 'grant execute on function public.sales_summary(date, date, uuid, text) to authenticated';
    execute 'grant execute on function public.gst_summary(date, date, uuid) to authenticated';
    execute 'grant execute on function public.customer_ledger(uuid, date, date) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0027_default_accounting_rules.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0027 — Default accounting rules
-- =============================================================================
-- Spec §22 requires account mapping to be configuration rather than code, and
-- 0024 provides the table. But an unconfigured dealer cannot post anything: the
-- posting engine refuses rather than guessing, which is correct and also means a
-- fresh install has a sales screen that always errors.
--
-- This installs a sensible default mapping against the standard chart of accounts
-- from seed.sql, so posting works out of the box. Every rule remains editable —
-- a dealer whose chart differs simply repoints them.
--
-- Idempotent: existing rules are left alone, so a dealer who has customised a
-- mapping does not have it overwritten by a later run.
--
-- Rollback: delete from public.accounting_rules where description = 'Default mapping';
-- =============================================================================

create or replace function app.seed_default_accounting_rules(p_dealer_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_inserted integer := 0;
begin
  insert into public.accounting_rules (dealer_id, module, event, component, side, account_id, description)
  select p_dealer_id, r.module, r.event, r.component, r.side, c.id, 'Default mapping'
    from (values
      -- Vehicle sale (spec §20, §22). Each invoice component posts to its own
      -- account, which is why the price is held as components rather than a
      -- single on-road figure.
      ('SALES', 'INVOICE', 'RECEIVABLE',   'DEBIT',  '1300'),
      ('SALES', 'INVOICE', 'VEHICLE',      'CREDIT', '4100'),
      ('SALES', 'INVOICE', 'ACCESSORY',    'CREDIT', '4200'),
      ('SALES', 'INVOICE', 'FITTING',      'CREDIT', '4200'),
      ('SALES', 'INVOICE', 'SPARE',        'CREDIT', '4300'),
      ('SALES', 'INVOICE', 'LABOUR',       'CREDIT', '4400'),
      ('SALES', 'INVOICE', 'INSURANCE',    'CREDIT', '4800'),
      ('SALES', 'INVOICE', 'REGISTRATION', 'CREDIT', '4800'),
      ('SALES', 'INVOICE', 'FORWARDING',   'CREDIT', '4700'),
      ('SALES', 'INVOICE', 'OTHER_CHARGE', 'CREDIT', '4800'),
      ('SALES', 'INVOICE', 'DISCOUNT',     'DEBIT',  '4100'),
      ('SALES', 'INVOICE', 'CGST',         'CREDIT', '2300'),
      ('SALES', 'INVOICE', 'SGST',         'CREDIT', '2400'),
      ('SALES', 'INVOICE', 'IGST',         'CREDIT', '2500'),
      ('SALES', 'INVOICE', 'COGS',         'DEBIT',  '5100'),
      ('SALES', 'INVOICE', 'INVENTORY',    'CREDIT', '1500'),

      -- Booking advance (spec §18): a booking is money held, not revenue earned.
      ('BOOKING', 'ADVANCE', 'CASH',             'DEBIT',  '1100'),
      ('BOOKING', 'ADVANCE', 'BANK',             'DEBIT',  '1200'),
      ('BOOKING', 'ADVANCE', 'CUSTOMER_ADVANCE', 'CREDIT', '2100'),
      -- Applying the advance against an invoice clears the liability.
      ('BOOKING', 'APPLY',   'CUSTOMER_ADVANCE', 'DEBIT',  '2100'),
      ('BOOKING', 'APPLY',   'RECEIVABLE',       'CREDIT', '1300'),

      -- Service and counter sales (spec §32, §33).
      ('SERVICE', 'INVOICE', 'RECEIVABLE',   'DEBIT',  '1300'),
      ('SERVICE', 'INVOICE', 'LABOUR',       'CREDIT', '4400'),
      ('SERVICE', 'INVOICE', 'SPARE',        'CREDIT', '4300'),
      ('SERVICE', 'INVOICE', 'ACCESSORY',    'CREDIT', '4200'),
      ('SERVICE', 'INVOICE', 'OTHER_CHARGE', 'CREDIT', '4800'),
      ('SERVICE', 'INVOICE', 'CGST',         'CREDIT', '2300'),
      ('SERVICE', 'INVOICE', 'SGST',         'CREDIT', '2400'),
      ('SERVICE', 'INVOICE', 'IGST',         'CREDIT', '2500'),
      ('SERVICE', 'INVOICE', 'COGS',         'DEBIT',  '5300'),
      ('SERVICE', 'INVOICE', 'INVENTORY',    'CREDIT', '1700'),

      -- Cash and bank movements.
      ('CASH', 'RECEIPT', 'CASH',       'DEBIT',  '1100'),
      ('CASH', 'RECEIPT', 'RECEIVABLE', 'CREDIT', '1300'),
      ('CASH', 'PAYMENT', 'CASH',       'CREDIT', '1100'),
      ('CASH', 'PAYMENT', 'PAYABLE',    'DEBIT',  '2200'),
      ('BANK', 'RECEIPT', 'BANK',       'DEBIT',  '1200'),
      ('BANK', 'RECEIPT', 'RECEIVABLE', 'CREDIT', '1300'),
      ('BANK', 'PAYMENT', 'BANK',       'CREDIT', '1200'),
      ('BANK', 'PAYMENT', 'PAYABLE',    'DEBIT',  '2200'),

      -- Finance: disbursement settles the receivable; commission is income.
      ('FINANCE', 'DISBURSEMENT', 'BANK',               'DEBIT',  '1200'),
      ('FINANCE', 'DISBURSEMENT', 'FINANCE_RECEIVABLE', 'CREDIT', '1400'),
      ('FINANCE', 'INVOICE',      'FINANCE_RECEIVABLE', 'DEBIT',  '1400'),
      ('FINANCE', 'COMMISSION',   'BANK',               'DEBIT',  '1200'),
      ('FINANCE', 'COMMISSION',   'COMMISSION_INCOME',  'CREDIT', '4500'),

      -- Trade advance from a finance company (spec §26).
      ('TRADE_ADVANCE', 'RECEIVED',   'BANK',            'DEBIT',  '1200'),
      ('TRADE_ADVANCE', 'RECEIVED',   'FINANCE_PAYABLE', 'CREDIT', '2600'),
      ('TRADE_ADVANCE', 'ADJUSTMENT', 'FINANCE_PAYABLE', 'DEBIT',  '2600'),
      ('TRADE_ADVANCE', 'ADJUSTMENT', 'FINANCE_RECEIVABLE', 'CREDIT', '1400'),

      -- Stock receipt from a supplier.
      ('INVENTORY', 'PURCHASE', 'INVENTORY', 'DEBIT',  '1600'),
      ('INVENTORY', 'PURCHASE', 'PAYABLE',   'CREDIT', '2200'),
      ('INVENTORY', 'PURCHASE', 'VEHICLE_INVENTORY', 'DEBIT', '1500')
    ) as r(module, event, component, side, account_code)
    join public.chart_of_accounts c
      on c.dealer_id = p_dealer_id and c.code = r.account_code
   -- Leave an existing mapping alone: a dealer may have repointed it deliberately.
   where not exists (
     select 1 from public.accounting_rules ar
      where ar.dealer_id = p_dealer_id
        and ar.module = r.module and ar.event = r.event and ar.component = r.component
        and ar.branch_id is null
   );

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;

comment on function app.seed_default_accounting_rules(uuid) is
  'Installs the default account mapping for a dealer against the standard chart '
  'of accounts (spec §22). Idempotent: customised rules are never overwritten.';

-- Apply to every dealer that already exists.
do $$
declare
  d record;
  n integer;
begin
  for d in select id, code from public.dealers loop
    n := app.seed_default_accounting_rules(d.id);
    raise notice 'Dealer %: % default accounting rule(s) installed.', d.code, n;
  end loop;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function app.seed_default_accounting_rules(uuid) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0028_booking_and_sale_operations.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0028 — Public operations for bookings and sales
-- =============================================================================
-- PostgREST exposes only the `public` schema, so the engine in `app` is
-- unreachable from the application. These are the sanctioned entry points.
--
-- They are functions rather than a sequence of REST calls for the reason spec
-- §48 gives: each REST call is its own transaction, so creating a booking, its
-- receipt and its journal as three calls can leave two of the three written. A
-- booking with no journal is a receipt the books never saw.
--
-- Rollback: drop the functions below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.next_document_number() — thin wrapper over the app function
-- -----------------------------------------------------------------------------
create or replace function public.next_document_number(
  p_dealer_id      uuid,
  p_branch_id      uuid,
  p_doc_type       text,
  p_financial_year text
)
returns text
language sql
volatile
as $$
  select app.next_document_number(p_dealer_id, p_branch_id, p_doc_type, p_financial_year);
$$;

-- -----------------------------------------------------------------------------
-- public.create_booking_with_advance() — spec §18, atomically
-- -----------------------------------------------------------------------------
-- Booking, receipt and journal in one transaction. If the journal cannot post —
-- unconfigured accounts, a closed period — the booking is not created either,
-- so there is never a receipt the ledger does not know about.
-- -----------------------------------------------------------------------------
create or replace function public.create_booking_with_advance(
  p_customer_id       uuid,
  p_model_id          uuid,
  p_branch_id         uuid,
  p_booking_amount    numeric,
  p_advance_amount    numeric,
  p_payment_mode      text,
  p_variant_id        uuid default null,
  p_vehicle_id        uuid default null,
  p_expected_delivery date default null,
  p_sales_executive_id uuid default null,
  p_reference         text default null,
  p_notes             text default null
)
returns table (booking_id uuid, booking_number text, receipt_number text, journal_entry_id uuid)
language plpgsql
as $$
declare
  v_dealer_id uuid;
  v_year      text;
  v_booking   uuid;
  v_bnumber   text;
  v_rnumber   text;
  v_entry     uuid;
  v_debit_acc uuid;
  v_credit_acc uuid;
  v_cash_component text;
begin
  if p_advance_amount <= 0 then
    raise exception 'The advance amount must be greater than zero.'
      using errcode = 'check_violation';
  end if;
  if p_booking_amount > 0 and p_advance_amount > p_booking_amount then
    raise exception 'The advance cannot exceed the booking amount.'
      using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer_id from public.branches where id = p_branch_id;
  if v_dealer_id is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  v_year := app.financial_year_token(v_dealer_id, current_date);

  -- Resolve accounts before writing anything: an unconfigured mapping should
  -- fail before a booking number is consumed.
  v_cash_component := case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end;
  v_debit_acc  := app.require_account(v_dealer_id, 'BOOKING', 'ADVANCE', v_cash_component, p_branch_id);
  v_credit_acc := app.require_account(v_dealer_id, 'BOOKING', 'ADVANCE', 'CUSTOMER_ADVANCE', p_branch_id);

  v_bnumber := app.next_document_number(v_dealer_id, p_branch_id, 'BOOKING', v_year);
  v_rnumber := app.next_document_number(v_dealer_id, p_branch_id, 'RECEIPT', v_year);

  insert into public.bookings
    (dealer_id, branch_id, booking_number, customer_id, model_id, variant_id, vehicle_id,
     booking_amount, expected_delivery, sales_executive_id, notes, created_by)
  values
    (v_dealer_id, p_branch_id, v_bnumber, p_customer_id, p_model_id, p_variant_id, p_vehicle_id,
     p_booking_amount, p_expected_delivery, p_sales_executive_id, p_notes, auth.uid())
  returning id into v_booking;

  -- Spec §18: the advance is a liability until the sale is raised.
  v_entry := app.post_journal(
    v_dealer_id, p_branch_id, current_date, 'BOOKING',
    'Booking advance ' || v_bnumber,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit_acc, 'debit', p_advance_amount, 'credit', 0,
                         'narration', p_payment_mode || ' received'),
      jsonb_build_object('account_id', v_credit_acc, 'debit', 0, 'credit', p_advance_amount,
                         'narration', 'Customer advance',
                         'party_type', 'CUSTOMER', 'party_id', p_customer_id)
    ),
    'BOOKING', v_booking, 'booking:' || v_booking::text
  );

  insert into public.booking_payments
    (dealer_id, booking_id, receipt_number, amount, payment_mode, reference, journal_entry_id, created_by)
  values
    (v_dealer_id, v_booking, v_rnumber, p_advance_amount, p_payment_mode, p_reference, v_entry, auth.uid());

  -- Reserving a specific chassis takes it out of available stock (spec §13).
  if p_vehicle_id is not null then
    update public.vehicles set status = 'BOOKED', updated_by = auth.uid()
     where id = p_vehicle_id and status = 'IN_STOCK';
  end if;

  booking_id := v_booking; booking_number := v_bnumber;
  receipt_number := v_rnumber; journal_entry_id := v_entry;
  return next;
end;
$$;

comment on function public.create_booking_with_advance is
  'Creates a booking, its advance receipt and the journal in one transaction '
  '(spec §18). Any failure leaves none of the three.';

-- -----------------------------------------------------------------------------
-- public.record_sale_payment() — a receipt against an invoice
-- -----------------------------------------------------------------------------
create or replace function public.record_sale_payment(
  p_sale_id      uuid,
  p_amount       numeric,
  p_payment_mode text,
  p_reference    text default null,
  p_finance_company_id uuid default null
)
returns table (receipt_number text, journal_entry_id uuid)
language plpgsql
as $$
declare
  v_sale     public.sales;
  v_year     text;
  v_rnumber  text;
  v_entry    uuid;
  v_debit    uuid;
  v_credit   uuid;
  v_component text;
begin
  if p_amount <= 0 then
    raise exception 'The payment amount must be greater than zero.' using errcode = 'check_violation';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;
  if v_sale.id is null then
    raise exception 'Sale not found.' using errcode = 'no_data_found';
  end if;
  if v_sale.status not in ('POSTED', 'DELIVERED') then
    raise exception 'Payments can only be recorded against a posted invoice; this one is %.', v_sale.status
      using errcode = 'check_violation';
  end if;

  v_year := app.financial_year_token(v_sale.dealer_id, current_date);
  v_rnumber := app.next_document_number(v_sale.dealer_id, v_sale.branch_id, 'RECEIPT', v_year);

  -- Finance disbursement moves the debt to the finance company rather than
  -- settling it in cash (spec §27).
  if p_payment_mode = 'FINANCE' then
    v_component := 'FINANCE_RECEIVABLE';
    v_debit  := app.require_account(v_sale.dealer_id, 'FINANCE', 'INVOICE', 'FINANCE_RECEIVABLE', v_sale.branch_id);
  else
    v_component := case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end;
    v_debit := app.require_account(
      v_sale.dealer_id,
      case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
      'RECEIPT', v_component, v_sale.branch_id);
  end if;

  v_credit := app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'RECEIVABLE', v_sale.branch_id);

  v_entry := app.post_journal(
    v_sale.dealer_id, v_sale.branch_id, current_date,
    case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
    'Receipt ' || v_rnumber || ' against ' || v_sale.invoice_number,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', p_payment_mode || ' received'),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', 'Against ' || v_sale.invoice_number,
                         'party_type', 'CUSTOMER', 'party_id', v_sale.customer_id)
    ),
    'SALE_PAYMENT', p_sale_id, 'receipt:' || v_rnumber
  );

  insert into public.sale_payments
    (dealer_id, sale_id, receipt_number, amount, payment_mode, reference,
     finance_company_id, journal_entry_id, created_by)
  values
    (v_sale.dealer_id, p_sale_id, v_rnumber, p_amount, p_payment_mode, p_reference,
     p_finance_company_id, v_entry, auth.uid());

  receipt_number := v_rnumber; journal_entry_id := v_entry;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.deliver_vehicle() — spec §19, the final step
-- -----------------------------------------------------------------------------
create or replace function public.deliver_vehicle(
  p_sale_id      uuid,
  p_received_by  text default null,
  p_odometer     numeric default null,
  p_remarks      text default null
)
returns text
language plpgsql
as $$
declare
  v_sale    public.sales;
  v_year    text;
  v_number  text;
begin
  select * into v_sale from public.sales where id = p_sale_id for update;

  if v_sale.id is null then
    raise exception 'Sale not found.' using errcode = 'no_data_found';
  end if;
  if v_sale.status <> 'POSTED' then
    raise exception 'Only a POSTED sale can be delivered; this one is %.', v_sale.status
      using errcode = 'check_violation';
  end if;

  v_year := app.financial_year_token(v_sale.dealer_id, current_date);
  v_number := app.next_document_number(v_sale.dealer_id, v_sale.branch_id, 'STOCK_TRANSFER', v_year);

  insert into public.deliveries
    (dealer_id, branch_id, sale_id, vehicle_id, delivery_number,
     delivered_by, received_by_name, odometer, remarks)
  values
    (v_sale.dealer_id, v_sale.branch_id, p_sale_id, v_sale.vehicle_id, v_number,
     auth.uid(), p_received_by, p_odometer, p_remarks);

  update public.vehicles set status = 'DELIVERED', updated_by = auth.uid()
   where id = v_sale.vehicle_id;

  update public.sales set status = 'DELIVERED', delivered_by = auth.uid()
   where id = p_sale_id;

  return v_number;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.next_document_number(uuid, uuid, text, text) to authenticated';
    execute 'grant execute on function public.create_booking_with_advance(uuid, uuid, uuid, numeric, numeric, text, uuid, uuid, date, uuid, text, text) to authenticated';
    execute 'grant execute on function public.record_sale_payment(uuid, numeric, text, text, uuid) to authenticated';
    execute 'grant execute on function public.deliver_vehicle(uuid, text, numeric, text) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0029_create_sale_draft.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0029 — Drafting a vehicle sale
-- =============================================================================
-- Spec §19, §20, §42.
--
-- Builds a DRAFT invoice from the price version in force on the invoice date, one
-- line per price component. Header and lines are created together: a header with
-- no lines totals zero and looks like a real invoice for nothing.
--
-- The price version id is stored on the sale, so the invoice stays explainable
-- after ten more price changes (spec §42).
--
-- Rollback: drop function public.create_vehicle_sale_draft(...);
-- =============================================================================

create or replace function public.create_vehicle_sale_draft(
  p_customer_id  uuid,
  p_vehicle_id   uuid,
  p_invoice_date date default current_date,
  p_booking_id   uuid default null,
  p_sales_executive_id uuid default null,
  p_discount     numeric default 0,
  p_notes        text default null
)
returns table (sale_id uuid, invoice_number text, total_amount numeric)
language plpgsql
as $$
declare
  v_vehicle  public.vehicles;
  v_price    record;
  v_tax      record;
  v_dealer   uuid;
  v_year     text;
  v_number   text;
  v_sale     uuid;
  v_line     smallint := 0;
  v_hsn      text;
  v_model_tax text;
begin
  select * into v_vehicle from public.vehicles where id = p_vehicle_id for update;

  if v_vehicle.id is null then
    raise exception 'Vehicle not found.' using errcode = 'no_data_found';
  end if;
  if v_vehicle.status not in ('IN_STOCK', 'BOOKED') then
    raise exception 'Vehicle % is % and is not available for sale.', v_vehicle.chassis_no, v_vehicle.status
      using errcode = 'check_violation';
  end if;

  v_dealer := v_vehicle.dealer_id;

  -- The price in force on the invoice date, not today's price (spec §42).
  select * into v_price
    from public.resolve_vehicle_price(v_dealer, v_vehicle.model_id, v_vehicle.variant_id,
                                      v_vehicle.branch_id, p_invoice_date);

  if v_price.price_version_id is null then
    raise exception 'No price is configured for this model on %.', p_invoice_date
      using errcode = 'no_data_found',
            hint = 'Add a price version before selling this model.';
  end if;

  select m.tax_code, h.code into v_model_tax, v_hsn
    from public.vehicle_models m
    left join public.hsn_codes h on h.id = m.hsn_code_id
   where m.id = v_vehicle.model_id;

  select * into v_tax
    from public.resolve_tax_code(v_dealer, coalesce(v_price.tax_code, v_model_tax), p_invoice_date);

  v_year := app.financial_year_token(v_dealer, p_invoice_date);
  v_number := app.next_document_number(v_dealer, v_vehicle.branch_id, 'VEHICLE_INVOICE', v_year);

  insert into public.sales
    (dealer_id, branch_id, invoice_number, invoice_date, customer_id, vehicle_id,
     booking_id, price_version_id, sales_executive_id, notes, created_by)
  values
    (v_dealer, v_vehicle.branch_id, v_number, p_invoice_date, p_customer_id, p_vehicle_id,
     p_booking_id, v_price.price_version_id, p_sales_executive_id, p_notes, auth.uid())
  returning id into v_sale;

  -- ── One line per price component (spec §20) ───────────────────────────────
  -- Only the vehicle itself carries GST here; insurance and registration are
  -- pass-through in most dealer setups, and forwarding is taxed separately by
  -- configuration. A dealer whose treatment differs edits the lines before
  -- submitting, which is why the invoice is a draft first.
  if v_price.ex_showroom > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, hsn_code, quantity, unit_rate,
       taxable_value, tax_code, cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount,
       unit_cost, cost_amount)
    values
      (v_sale, v_dealer, v_line, 'VEHICLE',
       coalesce((select m.brand || ' ' || m.name from public.vehicle_models m where m.id = v_vehicle.model_id), 'Vehicle'),
       v_hsn, 1, v_price.ex_showroom, v_price.ex_showroom,
       v_tax.code, coalesce(v_tax.cgst_rate, 0), coalesce(v_tax.sgst_rate, 0),
       round(v_price.ex_showroom * coalesce(v_tax.cgst_rate, 0) / 100, 2),
       round(v_price.ex_showroom * coalesce(v_tax.sgst_rate, 0) / 100, 2),
       v_price.ex_showroom
         + round(v_price.ex_showroom * coalesce(v_tax.cgst_rate, 0) / 100, 2)
         + round(v_price.ex_showroom * coalesce(v_tax.sgst_rate, 0) / 100, 2),
       -- COGS uses what this specific unit cost, not the price master's figure.
       v_vehicle.purchase_cost, v_vehicle.purchase_cost);
  end if;

  if v_price.insurance > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'INSURANCE', 'Insurance', 1,
            v_price.insurance, v_price.insurance, v_price.insurance);
  end if;

  if v_price.registration > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'REGISTRATION', 'Registration (LTRT)', 1,
            v_price.registration, v_price.registration, v_price.registration);
  end if;

  if v_price.mandatory_accessories > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'ACCESSORY', 'Mandatory accessories', 1,
            v_price.mandatory_accessories, v_price.mandatory_accessories, v_price.mandatory_accessories);
  end if;

  if v_price.forwarding_charge > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'FORWARDING', 'Forwarding charges', 1,
            v_price.forwarding_charge, v_price.forwarding_charge, v_price.forwarding_charge);
  end if;

  if v_price.other_charges > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'OTHER_CHARGE', 'Other charges', 1,
            v_price.other_charges, v_price.other_charges, v_price.other_charges);
  end if;

  -- A discount beyond what the price version permits is a policy breach, not a
  -- rounding difference (spec §15).
  if p_discount > 0 then
    if p_discount > v_price.max_discount then
      raise exception 'A discount of % exceeds the maximum of % allowed on this price version.',
        p_discount, v_price.max_discount
        using errcode = 'check_violation';
    end if;
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       discount, taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'DISCOUNT', 'Discount', 1, 0, p_discount, 0, 0);
  end if;

  -- Reserve the chassis so no other draft can claim it (spec §49).
  if v_vehicle.status = 'IN_STOCK' then
    update public.vehicles set status = 'BOOKED', updated_by = auth.uid() where id = p_vehicle_id;
  end if;

  -- Converting a booking closes it.
  if p_booking_id is not null then
    update public.bookings
       set status = 'CONVERTED', converted_sale_id = v_sale, updated_by = auth.uid()
     where id = p_booking_id and status = 'OPEN';
  end if;

  sale_id := v_sale;
  invoice_number := v_number;
  select s.total_amount into total_amount from public.sales s where s.id = v_sale;
  return next;
end;
$$;

comment on function public.create_vehicle_sale_draft is
  'Builds a DRAFT invoice from the price version in force on the invoice date '
  '(spec §19, §20, §42). Header and lines are created together.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.create_vehicle_sale_draft(uuid, uuid, date, uuid, uuid, numeric, text) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0030_cash_operations.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0030 — Cash book operations
-- =============================================================================
-- Spec §36, §37, §60.14, §60.15. The cash book is mandatory and so is the daily
-- close, so these are the operations that make both usable.
--
-- Each is a function for the same reason as the sale: a receipt written without
-- its journal is money the books never saw.
--
-- Rollback: drop the functions below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Fix: the cash difference was always NULL (bug in 0022)
-- -----------------------------------------------------------------------------
-- app.cash_day_guard() computed `new.difference := new.physical_cash -
-- new.expected_closing`, but expected_closing is a *generated* column and
-- PostgreSQL does not populate generated columns in NEW during a BEFORE trigger —
-- they are computed after it returns. So new.expected_closing was NULL, the
-- subtraction was NULL, and difference was silently NULL on every close.
--
-- That is the one number the daily close exists to produce: cash short or over.
-- Recomputing it from the base columns, which *are* populated.
-- -----------------------------------------------------------------------------
create or replace function app.cash_day_guard()
returns trigger
language plpgsql
as $$
declare
  v_expected numeric(18, 4);
begin
  if new.physical_cash is not null then
    v_expected := new.opening_balance + new.total_receipts - new.total_payments;
    new.difference := new.physical_cash - v_expected;
  end if;

  if tg_op = 'UPDATE' and old.status = 'CLOSED' and new.status <> 'CLOSED' then
    if new.reopen_reason is null then
      raise exception 'Reopening a closed day requires a reason.'
        using errcode = 'check_violation';
    end if;
    new.reopened_at := now();
  end if;

  return new;
end;
$$;

-- Any day already closed with a NULL difference gets it computed now.
update public.cash_day_closings
   set difference = physical_cash - (opening_balance + total_receipts - total_payments)
 where physical_cash is not null and difference is null;

-- -----------------------------------------------------------------------------
-- public.ensure_cash_day() — every branch has an open day
-- -----------------------------------------------------------------------------
-- Opening the day is bookkeeping, not a decision. Rather than making a cashier
-- press "open day" before the first receipt, the day is created on demand with
-- its opening balance carried from the previous close.
-- -----------------------------------------------------------------------------
create or replace function public.ensure_cash_day(
  p_branch_id uuid,
  p_date      date default current_date
)
returns uuid
language plpgsql
as $$
declare
  v_dealer  uuid;
  v_account public.cash_accounts;
  v_day     uuid;
  v_opening numeric(18, 4);
begin
  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  select * into v_account from public.cash_accounts where branch_id = p_branch_id;

  -- A branch without a cash account cannot take cash (spec §36).
  if v_account.id is null then
    raise exception 'This branch has no cash account.'
      using errcode = 'no_data_found',
            hint = 'Create one under Administration → Settings before taking cash.';
  end if;

  select id into v_day
    from public.cash_day_closings
   where branch_id = p_branch_id and business_date = p_date;

  if v_day is not null then
    return v_day;
  end if;

  -- Carry forward from the most recent closed day, so the opening balance is
  -- never typed in and never disagrees with yesterday.
  select coalesce(physical_cash, expected_closing) into v_opening
    from public.cash_day_closings
   where branch_id = p_branch_id and business_date < p_date and status = 'CLOSED'
   order by business_date desc
   limit 1;

  if v_opening is null then
    v_opening := v_account.opening_balance;
  end if;

  insert into public.cash_day_closings
    (dealer_id, branch_id, cash_account_id, business_date, opening_balance, status)
  values (v_dealer, p_branch_id, v_account.id, p_date, v_opening, 'OPEN')
  returning id into v_day;

  return v_day;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_cash_transaction() — a receipt or a payment (spec §37)
-- -----------------------------------------------------------------------------
create or replace function public.record_cash_transaction(
  p_branch_id   uuid,
  p_direction   text,
  p_amount      numeric,
  p_particular  text,
  p_account_id  uuid,
  p_customer_id uuid default null,
  p_reference   text default null,
  p_date        date default current_date
)
returns table (transaction_id bigint, journal_entry_id uuid, balance_after numeric)
language plpgsql
as $$
declare
  v_dealer   uuid;
  v_account  public.cash_accounts;
  v_entry    uuid;
  v_cash_acc uuid;
  v_txn      bigint;
  v_balance  numeric(18, 4);
begin
  if p_amount <= 0 then
    raise exception 'The amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_direction not in ('RECEIPT', 'PAYMENT') then
    raise exception 'Direction must be RECEIPT or PAYMENT.' using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  select * into v_account from public.cash_accounts where branch_id = p_branch_id;

  if v_account.id is null then
    raise exception 'This branch has no cash account.' using errcode = 'no_data_found';
  end if;

  -- Opens the day if needed, and fails if it is already closed (spec §36).
  perform public.ensure_cash_day(p_branch_id, p_date);

  v_cash_acc := v_account.ledger_account_id;

  -- A receipt debits cash and credits whatever the money was for; a payment is
  -- the mirror. The contra account is chosen by the operator, because "what was
  -- this for" is a judgement the software cannot make.
  v_entry := app.post_journal(
    v_dealer, p_branch_id, p_date,
    'CASH',
    p_particular,
    case when p_direction = 'RECEIPT' then
      jsonb_build_array(
        jsonb_build_object('account_id', v_cash_acc, 'debit', p_amount, 'credit', 0,
                           'narration', p_particular),
        jsonb_build_object('account_id', p_account_id, 'debit', 0, 'credit', p_amount,
                           'narration', p_particular,
                           'party_type', case when p_customer_id is not null then 'CUSTOMER' end,
                           'party_id', p_customer_id)
      )
    else
      jsonb_build_array(
        jsonb_build_object('account_id', p_account_id, 'debit', p_amount, 'credit', 0,
                           'narration', p_particular,
                           'party_type', case when p_customer_id is not null then 'CUSTOMER' end,
                           'party_id', p_customer_id),
        jsonb_build_object('account_id', v_cash_acc, 'debit', 0, 'credit', p_amount,
                           'narration', p_particular)
      )
    end,
    'CASH_BOOK', null, null
  );

  insert into public.cash_transactions
    (dealer_id, branch_id, cash_account_id, business_date, direction, amount,
     particular, reference_number, customer_id, journal_entry_id, created_by)
  values
    (v_dealer, p_branch_id, v_account.id, p_date, p_direction, p_amount,
     p_particular, p_reference, p_customer_id, v_entry, auth.uid())
  returning id, cash_transactions.balance_after into v_txn, v_balance;

  transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.close_cash_day() — count, compare, close (spec §36)
-- -----------------------------------------------------------------------------
-- The difference between counted and expected is computed, never typed. A
-- cashier who could type the difference could type zero.
-- -----------------------------------------------------------------------------
create or replace function public.close_cash_day(
  p_branch_id     uuid,
  p_date          date,
  p_physical_cash numeric,
  p_denominations jsonb default null,
  p_remarks       text default null
)
returns table (expected numeric, counted numeric, difference numeric)
language plpgsql
as $$
declare
  v_day public.cash_day_closings;
begin
  if p_physical_cash is null or p_physical_cash < 0 then
    raise exception 'Enter the physical cash counted.' using errcode = 'check_violation';
  end if;

  select * into v_day
    from public.cash_day_closings
   where branch_id = p_branch_id and business_date = p_date
     for update;

  if v_day.id is null then
    raise exception 'No cash book exists for % at this branch.', p_date
      using errcode = 'no_data_found';
  end if;
  if v_day.status = 'CLOSED' then
    raise exception 'The cash book for % is already closed.', p_date
      using errcode = 'check_violation';
  end if;

  update public.cash_day_closings
     set physical_cash = p_physical_cash,
         denominations = p_denominations,
         remarks       = p_remarks,
         counted_at    = now(),
         counted_by    = auth.uid(),
         closed_at     = now(),
         closed_by     = auth.uid(),
         status        = 'CLOSED'
   where id = v_day.id;

  select cdc.expected_closing, cdc.physical_cash, cdc.difference
    into expected, counted, difference
    from public.cash_day_closings cdc where cdc.id = v_day.id;

  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.reopen_cash_day() — spec §36, with permission and a reason
-- -----------------------------------------------------------------------------
create or replace function public.reopen_cash_day(
  p_branch_id uuid,
  p_date      date,
  p_reason    text
)
returns void
language plpgsql
as $$
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'Reopening a closed day requires a reason.'
      using errcode = 'check_violation',
            hint = 'Spec §36: no silent edits after close.';
  end if;

  update public.cash_day_closings
     set status = 'COUNTED', reopened_at = now(), reopened_by = auth.uid(), reopen_reason = p_reason
   where branch_id = p_branch_id and business_date = p_date and status = 'CLOSED';

  if not found then
    raise exception 'No closed cash book found for % at this branch.', p_date
      using errcode = 'no_data_found';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.cash_book() — the day sheet (spec §37)
-- -----------------------------------------------------------------------------
create or replace function public.cash_book(
  p_branch_id uuid,
  p_date      date default current_date
)
returns table (
  transaction_time timestamptz,
  reference_number text,
  particular       text,
  receipt          numeric(18, 4),
  payment          numeric(18, 4),
  running_balance  numeric(18, 4),
  journal_entry_id uuid
)
language sql
stable
as $$
  select t.transaction_time, t.reference_number, t.particular,
         case when t.direction = 'RECEIPT' then t.amount else 0 end,
         case when t.direction = 'PAYMENT' then t.amount else 0 end,
         t.balance_after, t.journal_entry_id
    from public.cash_transactions t
   where t.branch_id = p_branch_id
     and t.business_date = p_date
     and t.status = 'ACTIVE'
   order by t.transaction_time, t.id;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.ensure_cash_day(uuid, date) to authenticated';
    execute 'grant execute on function public.record_cash_transaction(uuid, text, numeric, text, uuid, uuid, text, date) to authenticated';
    execute 'grant execute on function public.close_cash_day(uuid, date, numeric, jsonb, text) to authenticated';
    execute 'grant execute on function public.reopen_cash_day(uuid, date, text) to authenticated';
    execute 'grant execute on function public.cash_book(uuid, date) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0031_bank_operations.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0031 — Bank operations, statement import and reconciliation
-- =============================================================================
-- Spec §38, §39.
--
-- Reconciliation matches the bank's version of events against ours. The rule the
-- whole module turns on: a statement line is never marked reconciled without a
-- recorded link to the book entry it matched (enforced by bsl_matched_link_check
-- in 0022). Auto-matching proposes; nothing is silently accepted.
--
-- Rollback: drop the functions below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The reconciliation number needs a sequence (spec §45)
-- -----------------------------------------------------------------------------
-- Dealer-wide rather than branch-scoped, because a bank account need not belong
-- to a branch. Added for every accounting period already on file, so existing
-- dealers can reconcile without anyone editing a settings table first.
-- -----------------------------------------------------------------------------
insert into public.document_sequences (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
select distinct p.dealer_id, null::uuid, 'BANK_RECONCILIATION',
       app.financial_year_token(p.dealer_id, p.start_date), 'BRS', 6
  from public.accounting_periods p
on conflict on constraint document_sequences_scope_key do nothing;

-- -----------------------------------------------------------------------------
-- public.record_bank_transaction() — a bank receipt or payment (spec §38)
-- -----------------------------------------------------------------------------
create or replace function public.record_bank_transaction(
  p_bank_account_id uuid,
  p_direction       text,
  p_amount          numeric,
  p_particular      text,
  p_account_id      uuid,
  p_date            date default current_date,
  p_reference       text default null,
  p_utr             text default null,
  p_instrument      text default null
)
returns table (transaction_id bigint, journal_entry_id uuid, balance_after numeric)
language plpgsql
as $$
declare
  v_bank    public.bank_accounts;
  v_entry   uuid;
  v_txn     bigint;
  v_balance numeric(18, 4);
begin
  if p_amount <= 0 then
    raise exception 'The amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_direction not in ('RECEIPT', 'PAYMENT') then
    raise exception 'Direction must be RECEIPT or PAYMENT.' using errcode = 'check_violation';
  end if;

  select * into v_bank from public.bank_accounts where id = p_bank_account_id;
  if v_bank.id is null then
    raise exception 'Bank account not found.' using errcode = 'no_data_found';
  end if;
  if v_bank.status <> 'ACTIVE' then
    raise exception 'Bank account % is %.', v_bank.name, v_bank.status
      using errcode = 'check_violation';
  end if;

  v_entry := app.post_journal(
    v_bank.dealer_id, v_bank.branch_id, p_date,
    'BANK',
    p_particular,
    case when p_direction = 'RECEIPT' then
      jsonb_build_array(
        jsonb_build_object('account_id', v_bank.ledger_account_id, 'debit', p_amount, 'credit', 0,
                           'narration', p_particular),
        jsonb_build_object('account_id', p_account_id, 'debit', 0, 'credit', p_amount,
                           'narration', p_particular)
      )
    else
      jsonb_build_array(
        jsonb_build_object('account_id', p_account_id, 'debit', p_amount, 'credit', 0,
                           'narration', p_particular),
        jsonb_build_object('account_id', v_bank.ledger_account_id, 'debit', 0, 'credit', p_amount,
                           'narration', p_particular)
      )
    end,
    'BANK_BOOK', null, null
  );

  insert into public.bank_transactions
    (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
     reference_number, utr, instrument_number, journal_entry_id, created_by)
  values
    (v_bank.dealer_id, p_bank_account_id, p_date, p_direction, p_amount, p_particular,
     p_reference, nullif(btrim(p_utr), ''), nullif(btrim(p_instrument), ''), v_entry, auth.uid())
  returning id, bank_transactions.balance_after into v_txn, v_balance;

  transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.import_bank_statement() — stage rows for matching (spec §39)
-- -----------------------------------------------------------------------------
-- Takes the parsed rows as JSONB. Duplicate lines are skipped rather than
-- rejected, so re-importing an overlapping statement is safe: the unique index
-- bsl_dedupe_key is the authority on what counts as the same line.
-- -----------------------------------------------------------------------------
create or replace function public.import_bank_statement(
  p_bank_account_id uuid,
  p_rows            jsonb
)
returns table (import_batch uuid, imported integer, skipped integer)
language plpgsql
as $$
declare
  v_dealer   uuid;
  v_batch    uuid := gen_random_uuid();
  v_row      jsonb;
  v_imported integer := 0;
  v_skipped  integer := 0;
  v_debit    numeric(18, 4);
  v_credit   numeric(18, 4);
begin
  select dealer_id into v_dealer from public.bank_accounts where id = p_bank_account_id;
  if v_dealer is null then
    raise exception 'Bank account not found.' using errcode = 'no_data_found';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'No statement rows to import.' using errcode = 'check_violation';
  end if;

  for v_row in select * from jsonb_array_elements(p_rows)
  loop
    v_debit  := coalesce((v_row ->> 'debit')::numeric, 0);
    v_credit := coalesce((v_row ->> 'credit')::numeric, 0);

    -- A row that is neither a debit nor a credit carries no information, and one
    -- that is both is a parsing failure. Either way it is not silently kept.
    if (v_debit > 0) = (v_credit > 0) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    begin
      insert into public.bank_statement_lines
        (dealer_id, bank_account_id, import_batch, statement_date, value_date,
         narration, reference, utr, upi_id, cheque_number, debit, credit,
         running_balance, raw_row, created_by)
      values
        (v_dealer, p_bank_account_id, v_batch,
         (v_row ->> 'statement_date')::date,
         nullif(v_row ->> 'value_date', '')::date,
         coalesce(nullif(btrim(v_row ->> 'narration'), ''), '(no narration)'),
         nullif(btrim(v_row ->> 'reference'), ''),
         nullif(btrim(v_row ->> 'utr'), ''),
         nullif(btrim(v_row ->> 'upi_id'), ''),
         nullif(btrim(v_row ->> 'cheque_number'), ''),
         v_debit, v_credit,
         nullif(v_row ->> 'running_balance', '')::numeric,
         v_row, auth.uid());
      v_imported := v_imported + 1;
    exception
      when unique_violation then
        v_skipped := v_skipped + 1;
    end;
  end loop;

  import_batch := v_batch; imported := v_imported; skipped := v_skipped;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.suggest_bank_matches() — proposals, not decisions (spec §39)
-- -----------------------------------------------------------------------------
-- Confidence is ranked: an exact UTR match is near-certain; amount and date
-- together are likely; amount alone within a window is a hint. Nothing here
-- writes — a human accepts a match, which is what makes the audit trail mean
-- something.
-- -----------------------------------------------------------------------------
create or replace function public.suggest_bank_matches(
  p_bank_account_id uuid,
  p_date_window     integer default 5
)
returns table (
  statement_line_id bigint,
  statement_date    date,
  narration         text,
  debit             numeric(18, 4),
  credit            numeric(18, 4),
  transaction_id    bigint,
  transaction_date  date,
  particular        text,
  amount            numeric(18, 4),
  confidence        text,
  reason            text
)
language sql
stable
as $$
  with candidates as (
    select
      l.id as line_id, l.statement_date, l.narration, l.debit, l.credit, l.utr, l.cheque_number,
      t.id as txn_id, t.transaction_date, t.particular, t.amount,
      case
        when l.utr is not null and t.utr = l.utr                        then 'EXACT'
        when l.cheque_number is not null and t.instrument_number = l.cheque_number then 'EXACT'
        when t.transaction_date = l.statement_date                      then 'LIKELY'
        else 'POSSIBLE'
      end as confidence,
      case
        when l.utr is not null and t.utr = l.utr                        then 'UTR matches'
        when l.cheque_number is not null and t.instrument_number = l.cheque_number then 'Instrument number matches'
        when t.transaction_date = l.statement_date                      then 'Amount and date match'
        else 'Amount matches within ' || p_date_window || ' days'
      end as reason
    from public.bank_statement_lines l
    join public.bank_transactions t
      on  t.bank_account_id = l.bank_account_id
      and t.status = 'ACTIVE'
      and not t.reconciled
      -- Our receipt is the bank's credit; our payment is the bank's debit.
      and t.direction = case when l.credit > 0 then 'RECEIPT' else 'PAYMENT' end
      and t.amount = greatest(l.debit, l.credit)
      and t.transaction_date between l.statement_date - p_date_window
                                 and l.statement_date + p_date_window
    where l.bank_account_id = p_bank_account_id
      and l.match_status = 'UNMATCHED'
  ),
  ranked as (
    select *, row_number() over (
      partition by line_id
      order by case confidence when 'EXACT' then 1 when 'LIKELY' then 2 else 3 end,
               abs(transaction_date - statement_date), txn_id
    ) as rank_in_line
    from candidates
  )
  -- One proposal per line: the best one. A list of six equally plausible matches
  -- is not a suggestion, it is homework.
  select line_id, statement_date, narration, debit, credit,
         txn_id, transaction_date, particular, amount, confidence, reason
    from ranked
   where rank_in_line = 1
   order by statement_date, line_id;
$$;

-- -----------------------------------------------------------------------------
-- public.match_bank_line() — accept one match (spec §39)
-- -----------------------------------------------------------------------------
create or replace function public.match_bank_line(
  p_statement_line_id bigint,
  p_transaction_id    bigint
)
returns void
language plpgsql
as $$
declare
  v_line public.bank_statement_lines;
  v_txn  public.bank_transactions;
begin
  select * into v_line from public.bank_statement_lines where id = p_statement_line_id for update;
  select * into v_txn  from public.bank_transactions   where id = p_transaction_id    for update;

  if v_line.id is null then
    raise exception 'Statement line not found.' using errcode = 'no_data_found';
  end if;
  if v_txn.id is null then
    raise exception 'Bank entry not found.' using errcode = 'no_data_found';
  end if;
  if v_line.bank_account_id <> v_txn.bank_account_id then
    raise exception 'The statement line and the book entry belong to different bank accounts.'
      using errcode = 'check_violation';
  end if;
  if v_line.match_status = 'MATCHED' then
    raise exception 'That statement line is already matched.' using errcode = 'check_violation';
  end if;
  if v_txn.reconciled then
    raise exception 'That book entry is already reconciled.' using errcode = 'check_violation';
  end if;

  -- Matching two different amounts is how a reconciliation ends up balancing on
  -- paper and wrong in fact.
  if v_txn.amount <> greatest(v_line.debit, v_line.credit) then
    raise exception 'The amounts differ: statement % against book %.',
      greatest(v_line.debit, v_line.credit), v_txn.amount
      using errcode = 'check_violation';
  end if;

  update public.bank_statement_lines
     set match_status = 'MATCHED', matched_transaction_id = p_transaction_id
   where id = p_statement_line_id;

  update public.bank_transactions
     set reconciled = true
   where id = p_transaction_id;
end;
$$;

create or replace function public.unmatch_bank_line(p_statement_line_id bigint)
returns void
language plpgsql
as $$
declare v_txn bigint;
begin
  select matched_transaction_id into v_txn
    from public.bank_statement_lines where id = p_statement_line_id for update;

  update public.bank_statement_lines
     set match_status = 'UNMATCHED', matched_transaction_id = null
   where id = p_statement_line_id and reconciliation_id is null;

  if not found then
    raise exception 'That line is part of a completed reconciliation and cannot be unmatched.'
      using errcode = 'insufficient_privilege';
  end if;

  if v_txn is not null then
    update public.bank_transactions set reconciled = false where id = v_txn;
  end if;
end;
$$;

create or replace function public.ignore_bank_line(p_statement_line_id bigint)
returns void
language plpgsql
as $$
begin
  update public.bank_statement_lines
     set match_status = 'IGNORED'
   where id = p_statement_line_id and match_status = 'UNMATCHED';

  if not found then
    raise exception 'Only an unmatched line can be ignored.' using errcode = 'check_violation';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.complete_bank_reconciliation() — close the period (spec §39)
-- -----------------------------------------------------------------------------
create or replace function public.complete_bank_reconciliation(
  p_bank_account_id uuid,
  p_from_date       date,
  p_to_date         date,
  p_statement_closing numeric,
  p_notes           text default null
)
returns table (reconciliation_id uuid, number text, difference numeric,
               matched integer, unmatched integer)
language plpgsql
as $$
declare
  v_bank      public.bank_accounts;
  v_recon     uuid;
  v_number    text;
  v_book      numeric(18, 4);
  v_matched   integer;
  v_unmatched integer;
begin
  select * into v_bank from public.bank_accounts where id = p_bank_account_id;
  if v_bank.id is null then
    raise exception 'Bank account not found.' using errcode = 'no_data_found';
  end if;

  -- Every column is table-qualified below: this function has an OUT parameter
  -- called reconciliation_id, and an unqualified reference resolves to that
  -- rather than to the column.
  select count(*) filter (where l.match_status = 'MATCHED'),
         count(*) filter (where l.match_status = 'UNMATCHED')
    into v_matched, v_unmatched
    from public.bank_statement_lines l
   where l.bank_account_id = p_bank_account_id
     and l.statement_date between p_from_date and p_to_date
     and l.reconciliation_id is null;

  -- The book balance as at the closing date, from the entries themselves.
  select coalesce(v_bank.opening_balance + sum(
           case when direction = 'RECEIPT' then amount else -amount end), v_bank.opening_balance)
    into v_book
    from public.bank_transactions
   where bank_account_id = p_bank_account_id
     and status = 'ACTIVE'
     and transaction_date <= p_to_date;

  -- Dealer-wide, not branch-scoped: a bank account need not belong to a branch,
  -- so a branch-scoped sequence would have nothing to key on.
  v_number := app.next_document_number(
    v_bank.dealer_id, null, 'BANK_RECONCILIATION',
    app.financial_year_token(v_bank.dealer_id, p_to_date));

  insert into public.bank_reconciliations
    (dealer_id, bank_account_id, reconciliation_number, from_date, to_date,
     statement_closing_balance, book_closing_balance, matched_count, unmatched_count,
     status, completed_at, completed_by, notes, created_by)
  values
    (v_bank.dealer_id, p_bank_account_id, v_number, p_from_date, p_to_date,
     p_statement_closing, v_book, v_matched, v_unmatched,
     'COMPLETED', now(), auth.uid(), p_notes, auth.uid())
  returning id into v_recon;

  -- Stamp the lines and entries so a completed reconciliation cannot be
  -- retrospectively unpicked (unmatch_bank_line refuses once this is set).
  update public.bank_statement_lines l
     set reconciliation_id = v_recon
   where l.bank_account_id = p_bank_account_id
     and l.statement_date between p_from_date and p_to_date
     and l.reconciliation_id is null
     and l.match_status in ('MATCHED', 'IGNORED');

  update public.bank_transactions t
     set reconciliation_id = v_recon
   where t.bank_account_id = p_bank_account_id
     and t.reconciled and t.reconciliation_id is null
     and t.transaction_date <= p_to_date;

  reconciliation_id := v_recon;
  number            := v_number;
  matched           := v_matched;
  unmatched         := v_unmatched;
  select r.difference into difference from public.bank_reconciliations r where r.id = v_recon;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.bank_book() — the account's entries with running balance (spec §38)
-- -----------------------------------------------------------------------------
create or replace function public.bank_book(
  p_bank_account_id uuid,
  p_from_date       date default null,
  p_to_date         date default null
)
returns table (
  id               bigint,
  transaction_date date,
  particular       text,
  reference_number text,
  utr              text,
  receipt          numeric(18, 4),
  payment          numeric(18, 4),
  running_balance  numeric(18, 4),
  reconciled       boolean,
  journal_entry_id uuid
)
language sql
stable
as $$
  select t.id, t.transaction_date, t.particular, t.reference_number, t.utr,
         case when t.direction = 'RECEIPT' then t.amount else 0 end,
         case when t.direction = 'PAYMENT' then t.amount else 0 end,
         t.balance_after, t.reconciled, t.journal_entry_id
    from public.bank_transactions t
   where t.bank_account_id = p_bank_account_id
     and t.status = 'ACTIVE'
     and (p_from_date is null or t.transaction_date >= p_from_date)
     and (p_to_date   is null or t.transaction_date <= p_to_date)
   order by t.transaction_date, t.id;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.record_bank_transaction(uuid, text, numeric, text, uuid, date, text, text, text) to authenticated';
    execute 'grant execute on function public.import_bank_statement(uuid, jsonb) to authenticated';
    execute 'grant execute on function public.suggest_bank_matches(uuid, integer) to authenticated';
    execute 'grant execute on function public.match_bank_line(bigint, bigint) to authenticated';
    execute 'grant execute on function public.unmatch_bank_line(bigint) to authenticated';
    execute 'grant execute on function public.ignore_bank_line(bigint) to authenticated';
    execute 'grant execute on function public.complete_bank_reconciliation(uuid, date, date, numeric, text) to authenticated';
    execute 'grant execute on function public.bank_book(uuid, date, date) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0032_bank_entry_permission.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0032 — bank.book.record
-- =============================================================================
-- Writing a bank entry was, until now, reachable by anyone who could *view* the
-- bank book: there was no write permission for it in the catalogue. Spec §6 and
-- §47 want the check to name the thing being done, so this adds the code and
-- grants it exactly where the seed's own matrix would have put it — every role
-- that already holds the rest of the bank module.
--
-- Rollback: delete from public.role_permissions where permission_code = 'bank.book.record';
--           delete from public.permissions where code = 'bank.book.record';
-- =============================================================================

insert into public.permissions (code, module, description, is_sensitive)
values ('bank.book.record', 'bank', 'Record bank receipts and payments', false)
on conflict (code) do nothing;

-- ACCOUNTS holds the whole bank module; DEALER_OWNER holds everything bar
-- platform administration. Mirroring seed.sql rather than inventing a new rule.
insert into public.role_permissions (role_id, permission_code)
select r.id, 'bank.book.record'
  from public.roles r
 where r.is_system
   and r.code in ('DEALER_OWNER', 'ACCOUNTS')
on conflict do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0033_service_operations.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0033 — Service operations: job cards, billing, posting and payment
-- =============================================================================
-- Spec §32, §33.
--
-- The workshop flow: job card → work done → invoice → post → collect. Spares
-- consumed on a job leave stock LOCAL-before-COMPANY (spec §31), the same order
-- as a vehicle fitting, and the source is recorded on each line so the invoice
-- stays explainable.
--
-- Rollback: drop the functions below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.create_job_card() — spec §32
-- -----------------------------------------------------------------------------
create or replace function public.create_job_card(
  p_branch_id       uuid,
  p_customer_id     uuid,
  p_service_type    text default 'PAID',
  p_registration_no text default null,
  p_odometer        numeric default null,
  p_complaint       text default null,
  p_customer_vehicle_id uuid default null,
  p_service_advisor_id  uuid default null,
  p_technician_id       uuid default null,
  p_promised_at     timestamptz default null,
  p_job_date        date default current_date
)
returns table (job_card_id uuid, job_card_number text)
language plpgsql
as $$
declare
  v_dealer uuid;
  v_number text;
  v_id     uuid;
begin
  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  v_number := app.next_document_number(
    v_dealer, p_branch_id, 'JOB_CARD', app.financial_year_token(v_dealer, p_job_date));

  insert into public.job_cards
    (dealer_id, branch_id, job_card_number, job_date, customer_id, customer_vehicle_id,
     registration_no, odometer, service_type, complaint, service_advisor_id, technician_id,
     promised_at, created_by)
  values
    (v_dealer, p_branch_id, v_number, p_job_date, p_customer_id, p_customer_vehicle_id,
     nullif(btrim(p_registration_no), ''), p_odometer, p_service_type, p_complaint,
     p_service_advisor_id, p_technician_id, p_promised_at, auth.uid())
  returning id into v_id;

  job_card_id := v_id; job_card_number := v_number;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.create_service_invoice() — a draft bill for a job card (spec §32)
-- -----------------------------------------------------------------------------
create or replace function public.create_service_invoice(
  p_job_card_id  uuid,
  p_invoice_date date default current_date
)
returns table (invoice_id uuid, invoice_number text)
language plpgsql
as $$
declare
  v_job    public.job_cards;
  v_number text;
  v_id     uuid;
begin
  select * into v_job from public.job_cards where id = p_job_card_id for update;

  if v_job.id is null then
    raise exception 'Job card not found.' using errcode = 'no_data_found';
  end if;
  if v_job.status in ('INVOICED', 'CLOSED', 'CANCELLED') then
    raise exception 'Job card % is % and cannot be billed again.', v_job.job_card_number, v_job.status
      using errcode = 'check_violation';
  end if;

  -- One open bill per job card. A second draft would let two people bill the
  -- same work without either seeing the other.
  if exists (
    select 1 from public.service_invoices
     where job_card_id = p_job_card_id and status in ('DRAFT', 'POSTED')
  ) then
    raise exception 'This job card already has an invoice.' using errcode = 'unique_violation';
  end if;

  v_number := app.next_document_number(
    v_job.dealer_id, v_job.branch_id, 'SERVICE_INVOICE',
    app.financial_year_token(v_job.dealer_id, p_invoice_date));

  insert into public.service_invoices
    (dealer_id, branch_id, invoice_number, invoice_date, invoice_type,
     job_card_id, customer_id, created_by)
  values
    (v_job.dealer_id, v_job.branch_id, v_number, p_invoice_date, 'SERVICE',
     p_job_card_id, v_job.customer_id, auth.uid())
  returning id into v_id;

  invoice_id := v_id; invoice_number := v_number;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.add_service_line() — labour or a part (spec §32, §33)
-- -----------------------------------------------------------------------------
-- A spare line resolves its cost and its stock source here rather than at
-- posting, so the operator sees on the draft which stock the part will come out
-- of, and so an out-of-stock part is refused while the bill can still be changed.
-- -----------------------------------------------------------------------------
create or replace function public.add_service_line(
  p_invoice_id  uuid,
  p_line_type   text,
  p_description text,
  p_quantity    numeric,
  p_unit_rate   numeric,
  p_item_id     uuid default null,
  p_tax_code    text default null,
  p_discount    numeric default 0
)
returns uuid
language plpgsql
as $$
declare
  v_invoice   public.service_invoices;
  v_line      smallint;
  v_tax       record;
  v_taxable   numeric(18, 4);
  v_hsn       text;
  v_cost      numeric(18, 4) := 0;
  v_available numeric(14, 3);
  v_source    text;
  v_id        uuid;
  v_cgst      numeric(18, 4) := 0;
  v_sgst      numeric(18, 4) := 0;
  v_cgst_rate numeric(6, 3)  := 0;
  v_sgst_rate numeric(6, 3)  := 0;
begin
  select * into v_invoice from public.service_invoices where id = p_invoice_id for update;

  if v_invoice.id is null then
    raise exception 'Invoice not found.' using errcode = 'no_data_found';
  end if;
  if v_invoice.status <> 'DRAFT' then
    raise exception 'Invoice % is % and can no longer be edited.', v_invoice.invoice_number, v_invoice.status
      using errcode = 'check_violation';
  end if;
  if p_quantity <= 0 then
    raise exception 'Quantity must be greater than zero.' using errcode = 'check_violation';
  end if;

  v_taxable := round(p_quantity * p_unit_rate, 2) - coalesce(p_discount, 0);
  if v_taxable < 0 then
    raise exception 'The discount is more than the line value.' using errcode = 'check_violation';
  end if;

  -- ── A part comes out of stock, LOCAL before COMPANY (spec §31) ─────────────
  if p_item_id is not null and p_line_type in ('SPARE', 'ACCESSORY') then
    select h.code into v_hsn
      from public.inventory_items i
      left join public.hsn_codes h on h.id = i.hsn_code_id
     where i.id = p_item_id;

    -- allocate_stock reports a shortfall as a row of its own rather than by
    -- returning less, so the shortfall must be looked for explicitly — summing
    -- the quantities would count it as if it had been allocated. Blocking here,
    -- while the bill is still a draft, beats failing at posting with the
    -- customer waiting (spec §31).
    select a.quantity into v_available
      from public.allocate_stock(p_item_id, v_invoice.branch_id, p_quantity) a
     where a.source = 'SHORTFALL';

    if v_available is not null then
      raise exception 'Not enough stock: short by % of %.', v_available, p_quantity
        using errcode = 'check_violation',
              hint = 'Transfer stock in, or reduce the quantity.';
    end if;

    select coalesce(sum(a.quantity * a.unit_cost), 0),
           -- The source shown on the line is where the first unit comes from;
           -- a split allocation is recorded per movement at posting.
           min(a.source) filter (where a.source = 'LOCAL')
    into v_cost, v_source
      from public.allocate_stock(p_item_id, v_invoice.branch_id, p_quantity) a;

    v_source := coalesce(v_source, 'COMPANY');
  end if;

  -- The rates stay in scalars: a `record` that was never assigned raises on
  -- first access, so an untaxed line would fail at the INSERT below.
  if p_tax_code is not null then
    select * into v_tax from public.resolve_tax_code(v_invoice.dealer_id, p_tax_code, v_invoice.invoice_date);
    v_cgst_rate := coalesce(v_tax.cgst_rate, 0);
    v_sgst_rate := coalesce(v_tax.sgst_rate, 0);
    v_cgst := round(v_taxable * v_cgst_rate / 100, 2);
    v_sgst := round(v_taxable * v_sgst_rate / 100, 2);
  end if;

  select coalesce(max(line_number), 0) + 1 into v_line
    from public.service_lines where invoice_id = p_invoice_id;

  insert into public.service_lines
    (invoice_id, dealer_id, line_number, line_type, description, item_id, hsn_code,
     quantity, unit_rate, discount, taxable_value, tax_code,
     cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount,
     unit_cost, cost_amount, stock_source)
  values
    (p_invoice_id, v_invoice.dealer_id, v_line, p_line_type, p_description, p_item_id, v_hsn,
     p_quantity, p_unit_rate, coalesce(p_discount, 0), v_taxable, p_tax_code,
     v_cgst_rate, v_sgst_rate, v_cgst, v_sgst,
     v_taxable + v_cgst + v_sgst,
     case when p_quantity > 0 then round(v_cost / p_quantity, 4) else 0 end, v_cost, v_source)
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.remove_service_line(p_line_id uuid)
returns void
language plpgsql
as $$
declare v_status text;
begin
  select i.status into v_status
    from public.service_lines l
    join public.service_invoices i on i.id = l.invoice_id
   where l.id = p_line_id;

  if v_status is null then
    raise exception 'Line not found.' using errcode = 'no_data_found';
  end if;
  if v_status <> 'DRAFT' then
    raise exception 'This invoice is % and can no longer be edited.', v_status
      using errcode = 'check_violation';
  end if;

  delete from public.service_lines where id = p_line_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.post_service_invoice() — one transaction (spec §32, §48)
-- -----------------------------------------------------------------------------
-- Revenue, GST, COGS and stock relief happen together or not at all. A service
-- invoice whose journal posted but whose spares never left stock is a workshop
-- that has sold parts it still believes it holds.
-- -----------------------------------------------------------------------------
create or replace function public.post_service_invoice(
  p_invoice_id      uuid,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_invoice public.service_invoices;
  v_line    record;
  v_lines   jsonb := '[]'::jsonb;
  v_entry   uuid;
  v_dealer  uuid;
  v_branch  uuid;
  v_cogs    numeric(18, 4) := 0;
  v_remaining numeric(14, 3);
  v_alloc   record;
begin
  select * into v_invoice from public.service_invoices where id = p_invoice_id for update;

  if v_invoice.id is null then
    raise exception 'Invoice not found.' using errcode = 'no_data_found';
  end if;
  if v_invoice.status = 'POSTED' then
    -- Idempotent: a retried request returns the entry the first one wrote.
    return v_invoice.journal_entry_id;
  end if;
  if v_invoice.status <> 'DRAFT' then
    raise exception 'Invoice % is % and cannot be posted.', v_invoice.invoice_number, v_invoice.status
      using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.service_lines where invoice_id = p_invoice_id) then
    raise exception 'Invoice % has no lines.', v_invoice.invoice_number
      using errcode = 'check_violation';
  end if;

  v_dealer := v_invoice.dealer_id;
  v_branch := v_invoice.branch_id;

  -- ── Revenue, one line per component ───────────────────────────────────────
  for v_line in
    select line_type, sum(taxable_value) as taxable
      from public.service_lines
     where invoice_id = p_invoice_id and line_type <> 'DISCOUNT'
     group by line_type
     having sum(taxable_value) > 0
  loop
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', v_line.line_type, v_branch),
      'debit', 0, 'credit', v_line.taxable,
      'narration', v_invoice.invoice_number || ' — ' || v_line.line_type);
  end loop;

  -- ── GST ───────────────────────────────────────────────────────────────────
  if v_invoice.cgst_amount > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'CGST', v_branch),
      'debit', 0, 'credit', v_invoice.cgst_amount, 'narration', 'CGST');
  end if;
  if v_invoice.sgst_amount > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'SGST', v_branch),
      'debit', 0, 'credit', v_invoice.sgst_amount, 'narration', 'SGST');
  end if;
  if v_invoice.igst_amount > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'IGST', v_branch),
      'debit', 0, 'credit', v_invoice.igst_amount, 'narration', 'IGST');
  end if;

  -- ── The customer owes the total ───────────────────────────────────────────
  v_lines := v_lines || jsonb_build_object(
    'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'RECEIVABLE', v_branch),
    'debit', v_invoice.total_amount, 'credit', 0,
    'narration', v_invoice.invoice_number,
    'party_type', case when v_invoice.customer_id is not null then 'CUSTOMER' end,
    'party_id', v_invoice.customer_id);

  -- A discount reduces what is owed, so it is a debit against revenue.
  for v_line in
    select sum(taxable_value + discount) as amount
      from public.service_lines
     where invoice_id = p_invoice_id and line_type = 'DISCOUNT'
     having sum(taxable_value + discount) > 0
  loop
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'LABOUR', v_branch),
      'debit', v_line.amount, 'credit', 0, 'narration', 'Discount');
  end loop;

  -- ── Stock relief and COGS (spec §31) ──────────────────────────────────────
  for v_line in
    select id, item_id, quantity, unit_rate
      from public.service_lines
     where invoice_id = p_invoice_id and item_id is not null
     order by line_number
  loop
    v_remaining := v_line.quantity;

    for v_alloc in
      select * from public.allocate_stock(v_line.item_id, v_branch, v_line.quantity)
    loop
      -- Stock can have moved since the line was drafted, so the shortfall is
      -- checked again here. 'SHORTFALL' is not a stock source and must never
      -- reach inventory_transactions.
      if v_alloc.source = 'SHORTFALL' then
        raise exception 'Insufficient stock to post this invoice: short by % on one line.', v_alloc.quantity
          using errcode = 'check_violation',
                hint = 'Spec §31: block rather than overselling.';
      end if;

      -- Quantity is signed: negative issues. One movement per source, never
      -- merged, so the ledger shows which stock the part actually came out of.
      insert into public.inventory_transactions
        (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
         reference_type, reference_id, reference_number, narration, created_by)
      values
        (v_dealer, v_branch, v_line.item_id, v_alloc.source, 'CONSUMPTION',
         -v_alloc.quantity, v_alloc.unit_cost,
         'SERVICE_INVOICE', p_invoice_id, v_invoice.invoice_number,
         'Consumed on ' || v_invoice.invoice_number, auth.uid());

      v_cogs := v_cogs + round(v_alloc.quantity * v_alloc.unit_cost, 2);
      v_remaining := v_remaining - v_alloc.quantity;
    end loop;

    if v_remaining > 0 then
      raise exception 'Not enough stock to fulfil line for item %.', v_line.item_id
        using errcode = 'check_violation';
    end if;
  end loop;

  if v_cogs > 0 then
    v_lines := v_lines
      || jsonb_build_object(
           'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'COGS', v_branch),
           'debit', v_cogs, 'credit', 0, 'narration', 'Cost of parts consumed')
      || jsonb_build_object(
           'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'INVENTORY', v_branch),
           'debit', 0, 'credit', v_cogs, 'narration', 'Parts issued from stock');
  end if;

  v_entry := app.post_journal(
    v_dealer, v_branch, v_invoice.invoice_date, 'SERVICE',
    'Service invoice ' || v_invoice.invoice_number,
    v_lines, 'SERVICE_INVOICE', p_invoice_id,
    coalesce(p_idempotency_key, 'service:' || p_invoice_id::text));

  update public.service_invoices
     set status = 'POSTED', posted_at = now(), journal_entry_id = v_entry,
         total_cost = v_cogs, idempotency_key = coalesce(p_idempotency_key, 'service:' || p_invoice_id::text),
         updated_by = auth.uid()
   where id = p_invoice_id;

  -- The job card is billed, which is what closes it to further work.
  if v_invoice.job_card_id is not null then
    update public.job_cards
       set status = 'INVOICED', updated_by = auth.uid()
     where id = v_invoice.job_card_id;
  end if;

  return v_entry;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_service_payment() — spec §32
-- -----------------------------------------------------------------------------
create or replace function public.record_service_payment(
  p_invoice_id   uuid,
  p_amount       numeric,
  p_payment_mode text default 'CASH',
  p_reference    text default null,
  p_date         date default current_date
)
returns table (payment_id uuid, receipt_number text, balance_due numeric)
language plpgsql
as $$
declare
  v_invoice public.service_invoices;
  v_number  text;
  v_entry   uuid;
  v_debit   uuid;
  v_credit  uuid;
  v_id      uuid;
  v_balance numeric(18, 4);
begin
  select * into v_invoice from public.service_invoices where id = p_invoice_id for update;

  if v_invoice.id is null then
    raise exception 'Invoice not found.' using errcode = 'no_data_found';
  end if;
  if v_invoice.status <> 'POSTED' then
    raise exception 'Invoice % is % — only a posted invoice can take a payment.',
      v_invoice.invoice_number, v_invoice.status using errcode = 'check_violation';
  end if;
  if p_amount <= 0 then
    raise exception 'The payment amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_amount > v_invoice.total_amount - v_invoice.paid_amount then
    raise exception 'That is more than the % outstanding on this invoice.',
      v_invoice.total_amount - v_invoice.paid_amount using errcode = 'check_violation';
  end if;

  v_number := app.next_document_number(
    v_invoice.dealer_id, v_invoice.branch_id, 'RECEIPT',
    app.financial_year_token(v_invoice.dealer_id, p_date));

  v_debit := app.require_account(
    v_invoice.dealer_id,
    case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
    'RECEIPT',
    case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
    v_invoice.branch_id);

  v_credit := app.require_account(v_invoice.dealer_id, 'SERVICE', 'INVOICE', 'RECEIVABLE', v_invoice.branch_id);

  v_entry := app.post_journal(
    v_invoice.dealer_id, v_invoice.branch_id, p_date,
    case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
    'Receipt ' || v_number || ' against ' || v_invoice.invoice_number,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', v_number),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', v_invoice.invoice_number,
                         'party_type', case when v_invoice.customer_id is not null then 'CUSTOMER' end,
                         'party_id', v_invoice.customer_id)
    ),
    'SERVICE_RECEIPT', p_invoice_id, null);

  insert into public.service_payments
    (dealer_id, invoice_id, receipt_number, payment_date, amount, payment_mode,
     reference, journal_entry_id, created_by)
  values
    (v_invoice.dealer_id, p_invoice_id, v_number, p_date, p_amount, p_payment_mode,
     p_reference, v_entry, auth.uid())
  returning id into v_id;

  select si.total_amount - si.paid_amount into v_balance
    from public.service_invoices si where si.id = p_invoice_id;

  payment_id := v_id; receipt_number := v_number; balance_due := v_balance;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.service_history() — spec §33
-- -----------------------------------------------------------------------------
create or replace function public.service_history(
  p_customer_id     uuid default null,
  p_registration_no text default null
)
returns table (
  job_card_id     uuid,
  job_card_number text,
  job_date        date,
  customer_name   text,
  registration_no text,
  odometer        numeric(10, 1),
  service_type    text,
  complaint       text,
  status          text,
  invoice_number  text,
  invoice_total   numeric(18, 4),
  paid_amount     numeric(18, 4)
)
language sql
stable
as $$
  select j.id, j.job_card_number, j.job_date, c.name, j.registration_no, j.odometer,
         j.service_type, j.complaint, j.status,
         i.invoice_number, i.total_amount, i.paid_amount
    from public.job_cards j
    join public.customers c on c.id = j.customer_id
    left join public.service_invoices i
      on i.job_card_id = j.id and i.status <> 'CANCELLED'
   where (p_customer_id is null or j.customer_id = p_customer_id)
     and (p_registration_no is null or j.registration_no ilike p_registration_no)
   order by j.job_date desc, j.job_card_number desc;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.create_job_card(uuid, uuid, text, text, numeric, text, uuid, uuid, uuid, timestamptz, date) to authenticated';
    execute 'grant execute on function public.create_service_invoice(uuid, date) to authenticated';
    execute 'grant execute on function public.add_service_line(uuid, text, text, numeric, numeric, uuid, text, numeric) to authenticated';
    execute 'grant execute on function public.remove_service_line(uuid) to authenticated';
    execute 'grant execute on function public.post_service_invoice(uuid, text) to authenticated';
    execute 'grant execute on function public.record_service_payment(uuid, numeric, text, text, date) to authenticated';
    execute 'grant execute on function public.service_history(uuid, text) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0034_gst_reports.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0034 — GST returns and the e-invoice queue
-- =============================================================================
-- Spec §40.
--
-- Two things here, and it matters that they are separate:
--
--   Reporting   GSTR-1 style views over documents the dealer has already
--               issued. These are derived, never stored, so they cannot drift
--               from the invoices they summarise.
--
--   Queue       einvoices and eway_bills rows track what the GST portal has
--               been told. Enqueuing is a local act; whether the portal
--               responded is a separate fact. A failure there must never roll
--               back an accounting transaction that already happened.
--
-- Rollback: drop the functions below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.gstr1_summary() — outward supplies by section (spec §40)
-- -----------------------------------------------------------------------------
-- The B2B/B2C split turns on whether the customer has a GSTIN, which is what the
-- return itself turns on. A registered buyer whose GSTIN was never captured ends
-- up in B2C and cannot claim credit, so the count of missing GSTINs is worth
-- seeing next to the totals rather than buried.
-- -----------------------------------------------------------------------------
create or replace function public.gstr1_summary(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  section        text,
  document_count bigint,
  taxable_value  numeric(18, 4),
  cgst_amount    numeric(18, 4),
  sgst_amount    numeric(18, 4),
  igst_amount    numeric(18, 4),
  total_tax      numeric(18, 4),
  invoice_value  numeric(18, 4)
)
language sql
stable
as $$
  with docs as (
    select s.id, c.gstin, s.taxable_value, s.cgst_amount, s.sgst_amount, s.igst_amount,
           s.total_amount
      from public.sales s
      left join public.customers c on c.id = s.customer_id
     where s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select si.id, c.gstin, si.taxable_value, si.cgst_amount, si.sgst_amount, si.igst_amount,
           si.total_amount
      from public.service_invoices si
      left join public.customers c on c.id = si.customer_id
     where si.status = 'POSTED'
       and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
  )
  select case when nullif(btrim(coalesce(docs.gstin, '')), '') is not null then 'B2B' else 'B2C' end,
         count(*), sum(docs.taxable_value), sum(docs.cgst_amount), sum(docs.sgst_amount),
         sum(docs.igst_amount),
         sum(docs.cgst_amount + docs.sgst_amount + docs.igst_amount),
         sum(docs.total_amount)
    from docs
   group by 1
   order by 1;
$$;

-- -----------------------------------------------------------------------------
-- public.gst_document_register() — the invoice-level detail behind the return
-- -----------------------------------------------------------------------------
create or replace function public.gst_document_register(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null,
  p_section   text default null
)
returns table (
  document_type   text,
  document_id     uuid,
  document_number text,
  document_date   date,
  customer_name   text,
  gstin           text,
  place_of_supply text,
  section         text,
  taxable_value   numeric(18, 4),
  cgst_amount     numeric(18, 4),
  sgst_amount     numeric(18, 4),
  igst_amount     numeric(18, 4),
  invoice_value   numeric(18, 4),
  einvoice_status text,
  irn             text
)
language sql
stable
as $$
  with docs as (
    select 'SALE'::text as dtype, s.id, s.invoice_number, s.invoice_date,
           coalesce(c.name, 'Cash customer') as cname, c.gstin, c.state as pos,
           s.taxable_value, s.cgst_amount, s.sgst_amount, s.igst_amount, s.total_amount
      from public.sales s
      left join public.customers c on c.id = s.customer_id
     where s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select 'SERVICE_INVOICE', si.id, si.invoice_number, si.invoice_date,
           coalesce(c.name, 'Counter sale'), c.gstin, c.state,
           si.taxable_value, si.cgst_amount, si.sgst_amount, si.igst_amount, si.total_amount
      from public.service_invoices si
      left join public.customers c on c.id = si.customer_id
     where si.status = 'POSTED'
       and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
  )
  select d.dtype, d.id, d.invoice_number, d.invoice_date, d.cname, d.gstin, d.pos,
         case when nullif(btrim(coalesce(d.gstin, '')), '') is not null then 'B2B' else 'B2C' end,
         d.taxable_value, d.cgst_amount, d.sgst_amount, d.igst_amount, d.total_amount,
         -- No e-invoice row at all is a different state from one that failed.
         coalesce(e.status, 'NOT_REQUESTED'), e.irn
    from docs d
    left join public.einvoices e on e.document_type = d.dtype and e.document_id = d.id
   where p_section is null
      or p_section = (case when nullif(btrim(coalesce(d.gstin, '')), '') is not null then 'B2B' else 'B2C' end)
   order by d.invoice_date, d.invoice_number;
$$;

-- -----------------------------------------------------------------------------
-- public.queue_einvoice() — record the intent to file (spec §40)
-- -----------------------------------------------------------------------------
-- Creating the row is all this does. Whether the portal accepts it is recorded
-- later by whatever process talks to the portal, so a portal outage leaves a
-- retryable row rather than blocking the sale.
-- -----------------------------------------------------------------------------
create or replace function public.queue_einvoice(
  p_document_type text,
  p_document_id   uuid
)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid;
  v_number text;
  v_date   date;
  v_id     uuid;
  v_status text;
begin
  if p_document_type = 'SALE' then
    select dealer_id, invoice_number, invoice_date, status
      into v_dealer, v_number, v_date, v_status
      from public.sales where id = p_document_id;
  elsif p_document_type = 'SERVICE_INVOICE' then
    select dealer_id, invoice_number, invoice_date, status
      into v_dealer, v_number, v_date, v_status
      from public.service_invoices where id = p_document_id;
  else
    raise exception 'Unsupported document type %.', p_document_type using errcode = 'check_violation';
  end if;

  if v_dealer is null then
    raise exception 'Document not found.' using errcode = 'no_data_found';
  end if;

  -- An unposted invoice is not yet a supply, and filing one would report a sale
  -- the books do not carry.
  if v_status not in ('POSTED', 'DELIVERED') then
    raise exception 'Document % is % — only a posted invoice can be filed.', v_number, v_status
      using errcode = 'check_violation';
  end if;

  insert into public.einvoices
    (dealer_id, document_type, document_id, document_number, document_date, status, created_by)
  values
    (v_dealer, p_document_type, p_document_id, v_number, v_date, 'PENDING', auth.uid())
  on conflict on constraint einvoices_document_key do update
     set status = case
                    -- A generated e-invoice is not re-queued: it has an IRN.
                    when public.einvoices.status = 'GENERATED' then 'GENERATED'
                    else 'PENDING'
                  end,
         error_code = null,
         error_message = null
  returning id into v_id;

  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_einvoice_result() — what the portal said
-- -----------------------------------------------------------------------------
create or replace function public.record_einvoice_result(
  p_einvoice_id uuid,
  p_status      text,
  p_irn         text default null,
  p_ack_number  text default null,
  p_ack_date    timestamptz default null,
  p_qr_code     text default null,
  p_error_code  text default null,
  p_error       text default null,
  p_response    jsonb default null
)
returns void
language plpgsql
as $$
begin
  if p_status not in ('GENERATED', 'FAILED', 'CANCELLED') then
    raise exception 'Status must be GENERATED, FAILED or CANCELLED.' using errcode = 'check_violation';
  end if;
  if p_status = 'GENERATED' and (p_irn is null or p_ack_number is null) then
    raise exception 'A generated e-invoice must carry an IRN and acknowledgement number.'
      using errcode = 'check_violation';
  end if;
  if p_status = 'FAILED' and p_error is null then
    raise exception 'A failed e-invoice must record why.' using errcode = 'check_violation';
  end if;

  update public.einvoices
     set status = p_status,
         irn = coalesce(p_irn, irn),
         ack_number = coalesce(p_ack_number, ack_number),
         ack_date = coalesce(p_ack_date, ack_date),
         signed_qr_code = coalesce(p_qr_code, signed_qr_code),
         error_code = p_error_code,
         error_message = p_error,
         response_payload = coalesce(p_response, response_payload),
         attempt_count = attempt_count + 1,
         last_attempt_at = now()
   where id = p_einvoice_id;

  if not found then
    raise exception 'E-invoice record not found.' using errcode = 'no_data_found';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.queue_eway_bill() — spec §40
-- -----------------------------------------------------------------------------
create or replace function public.queue_eway_bill(
  p_document_type   text,
  p_document_id     uuid,
  p_transport_mode  text default 'ROAD',
  p_vehicle_number  text default null,
  p_distance_km     integer default null,
  p_transporter_id  text default null,
  p_transporter_name text default null
)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid;
  v_number text;
  v_id     uuid;
begin
  if p_document_type = 'SALE' then
    select dealer_id, invoice_number into v_dealer, v_number
      from public.sales where id = p_document_id;
  elsif p_document_type = 'SERVICE_INVOICE' then
    select dealer_id, invoice_number into v_dealer, v_number
      from public.service_invoices where id = p_document_id;
  elsif p_document_type = 'TRANSFER' then
    select dealer_id, transfer_number into v_dealer, v_number
      from public.vehicle_transfers where id = p_document_id;
  else
    raise exception 'Unsupported document type %.', p_document_type using errcode = 'check_violation';
  end if;

  if v_dealer is null then
    raise exception 'Document not found.' using errcode = 'no_data_found';
  end if;

  insert into public.eway_bills
    (dealer_id, document_type, document_id, document_number, status,
     transport_mode, vehicle_number, distance_km, transporter_id, transporter_name, created_by)
  values
    (v_dealer, p_document_type, p_document_id, v_number, 'PENDING',
     p_transport_mode, nullif(btrim(p_vehicle_number), ''), p_distance_km,
     nullif(btrim(p_transporter_id), ''), nullif(btrim(p_transporter_name), ''), auth.uid())
  on conflict on constraint eway_document_key do update
     set status = case when public.eway_bills.status = 'GENERATED' then 'GENERATED' else 'PENDING' end,
         transport_mode = excluded.transport_mode,
         vehicle_number = excluded.vehicle_number,
         distance_km = excluded.distance_km,
         error_message = null
  returning id into v_id;

  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.einvoice_queue() — what is waiting, what failed, what is missing
-- -----------------------------------------------------------------------------
-- Posted invoices with no e-invoice row at all appear here too. They are the
-- ones nobody has noticed, and leaving them out of the queue is how a return
-- gets filed short.
-- -----------------------------------------------------------------------------
create or replace function public.einvoice_queue(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  einvoice_id     uuid,
  document_type   text,
  document_id     uuid,
  document_number text,
  document_date   date,
  customer_name   text,
  gstin           text,
  invoice_value   numeric(18, 4),
  status          text,
  irn             text,
  ack_number      text,
  error_message   text,
  attempt_count   integer
)
language sql
stable
as $$
  with docs as (
    select 'SALE'::text as dtype, s.id, s.invoice_number, s.invoice_date,
           coalesce(c.name, 'Cash customer') as cname, c.gstin, s.total_amount
      from public.sales s
      left join public.customers c on c.id = s.customer_id
     where s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select 'SERVICE_INVOICE', si.id, si.invoice_number, si.invoice_date,
           coalesce(c.name, 'Counter sale'), c.gstin, si.total_amount
      from public.service_invoices si
      left join public.customers c on c.id = si.customer_id
     where si.status = 'POSTED'
       and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
  )
  select e.id, d.dtype, d.id, d.invoice_number, d.invoice_date, d.cname, d.gstin,
         d.total_amount,
         coalesce(e.status, 'NOT_REQUESTED'), e.irn, e.ack_number, e.error_message,
         coalesce(e.attempt_count, 0)
    from docs d
    left join public.einvoices e on e.document_type = d.dtype and e.document_id = d.id
   order by
     -- Failures first, then never-requested, then pending; the generated ones
     -- need no attention.
     case coalesce(e.status, 'NOT_REQUESTED')
       when 'FAILED' then 1 when 'NOT_REQUESTED' then 2 when 'PENDING' then 3 else 4 end,
     d.invoice_date desc;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.gstr1_summary(date, date, uuid) to authenticated';
    execute 'grant execute on function public.gst_document_register(date, date, uuid, text) to authenticated';
    execute 'grant execute on function public.queue_einvoice(text, uuid) to authenticated';
    execute 'grant execute on function public.record_einvoice_result(uuid, text, text, text, timestamptz, text, text, text, jsonb) to authenticated';
    execute 'grant execute on function public.queue_eway_bill(text, uuid, text, text, integer, text, text) to authenticated';
    execute 'grant execute on function public.einvoice_queue(date, date, uuid) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0035_mis_reports.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0035 — MIS reports
-- =============================================================================
-- Spec §41, §43.
--
-- Every figure is derived from posted documents. Nothing here is stored, cached
-- or maintained by trigger, so a report can be wrong only if the transactions
-- behind it are wrong — which is the property that makes a report worth reading.
--
-- Cost and margin appear in these result sets. Spec §10 and §52 require them to
-- be withheld from responses for roles without permission, which the service
-- layer does with scrubRestrictedFields(); it is not this layer's job, but it is
-- this layer's reason for keeping them in named columns rather than blending
-- them into a total.
--
-- Rollback: drop the functions below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.finance_summary() — spec §41
-- -----------------------------------------------------------------------------
create or replace function public.finance_summary(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  finance_company_id   uuid,
  finance_company_name text,
  application_count    bigint,
  approved_count       bigint,
  rejected_count       bigint,
  pending_count        bigint,
  loan_amount          numeric(18, 4),
  disbursed_amount     numeric(18, 4),
  pending_disbursement numeric(18, 4),
  commission_amount    numeric(18, 4)
)
language sql
stable
as $$
  select f.id, f.name,
         count(*),
         count(*) filter (where a.approval_status = 'APPROVED'),
         count(*) filter (where a.approval_status = 'REJECTED'),
         count(*) filter (where a.approval_status = 'PENDING'),
         sum(a.loan_amount),
         sum(a.disbursed_amount),
         -- Only approved business can be pending disbursement; a rejected
         -- application is not money anyone is waiting for.
         sum(case when a.approval_status = 'APPROVED'
                  then coalesce(a.approved_amount, a.loan_amount) - a.disbursed_amount
                  else 0 end),
         sum(a.commission_amount)
    from public.finance_applications a
    join public.finance_companies f on f.id = a.finance_company_id
   where a.application_date between p_from and p_to
     and (p_branch_id is null or a.branch_id = p_branch_id)
   group by f.id, f.name
   order by sum(a.loan_amount) desc;
$$;

-- -----------------------------------------------------------------------------
-- public.branch_performance() — spec §43
-- -----------------------------------------------------------------------------
-- One row per branch, with the streams that make up its result. The subqueries
-- are deliberate: joining sales, service and bookings in one query multiplies
-- rows against each other and inflates every total.
-- -----------------------------------------------------------------------------
create or replace function public.branch_performance(
  p_from date,
  p_to   date
)
returns table (
  branch_id         uuid,
  branch_code       text,
  branch_name       text,
  vehicle_units     bigint,
  vehicle_revenue   numeric(18, 4),
  vehicle_cost      numeric(18, 4),
  vehicle_margin    numeric(18, 4),
  service_jobs      bigint,
  service_revenue   numeric(18, 4),
  service_cost      numeric(18, 4),
  bookings_open     bigint,
  booking_advances  numeric(18, 4),
  cash_in_hand      numeric(18, 4),
  receivables       numeric(18, 4)
)
language sql
stable
as $$
  select b.id, b.code, b.name,
         coalesce(s.units, 0), coalesce(s.revenue, 0), coalesce(s.cost, 0),
         coalesce(s.revenue, 0) - coalesce(s.cost, 0),
         coalesce(v.jobs, 0), coalesce(v.revenue, 0), coalesce(v.cost, 0),
         coalesce(k.open_count, 0), coalesce(k.advances, 0),
         coalesce(c.current_balance, 0),
         coalesce(s.receivable, 0) + coalesce(v.receivable, 0)
    from public.branches b
    left join lateral (
      select count(*) units,
             sum(sa.taxable_value) revenue,
             sum(sa.total_cost) cost,
             sum(sa.total_amount - sa.paid_amount) receivable
        from public.sales sa
       where sa.branch_id = b.id
         and sa.status in ('POSTED', 'DELIVERED')
         and sa.invoice_date between p_from and p_to
    ) s on true
    left join lateral (
      select count(*) jobs,
             sum(si.taxable_value) revenue,
             sum(si.total_cost) cost,
             sum(si.total_amount - si.paid_amount) receivable
        from public.service_invoices si
       where si.branch_id = b.id
         and si.status = 'POSTED'
         and si.invoice_date between p_from and p_to
    ) v on true
    left join lateral (
      select count(*) filter (where bk.status = 'OPEN') open_count,
             sum(bk.received_amount) filter (where bk.status = 'OPEN') advances
        from public.bookings bk
       where bk.branch_id = b.id
         and bk.booking_date between p_from and p_to
    ) k on true
    left join public.cash_accounts c on c.branch_id = b.id
   where b.status = 'ACTIVE'
   order by coalesce(s.revenue, 0) desc, b.name;
$$;

-- -----------------------------------------------------------------------------
-- public.margin_report() — spec §41, restricted
-- -----------------------------------------------------------------------------
-- Margin by stream, because "our margin" means something different for a vehicle
-- than for a spare part, and a blended figure hides which one is failing.
-- -----------------------------------------------------------------------------
create or replace function public.margin_report(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  stream        text,
  document_count bigint,
  revenue       numeric(18, 4),
  cost          numeric(18, 4),
  margin        numeric(18, 4),
  margin_percent numeric(8, 3)
)
language sql
stable
as $$
  with streams as (
    select 'Vehicle sales'::text as stream, count(*)::bigint as documents,
           coalesce(sum(s.taxable_value), 0) as revenue,
           coalesce(sum(s.total_cost), 0) as cost
      from public.sales s
     where s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select 'Service and parts', count(*)::bigint,
           coalesce(sum(si.taxable_value), 0), coalesce(sum(si.total_cost), 0)
      from public.service_invoices si
     where si.status = 'POSTED'
       and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
    union all
    -- Commission has no cost of its own: it is margin in full.
    select 'Finance commission', count(*)::bigint,
           coalesce(sum(a.commission_amount), 0), 0
      from public.finance_applications a
     where a.commission_amount > 0
       and a.application_date between p_from and p_to
       and (p_branch_id is null or a.branch_id = p_branch_id)
  )
  select streams.stream, streams.documents, streams.revenue, streams.cost,
         streams.revenue - streams.cost,
         case when streams.revenue > 0
              then round((streams.revenue - streams.cost) * 100 / streams.revenue, 3)
              else 0 end
    from streams
   where streams.documents > 0
   order by streams.revenue - streams.cost desc;
$$;

-- -----------------------------------------------------------------------------
-- public.consolidated_mis() — the whole dealership on one line per stream
-- -----------------------------------------------------------------------------
-- Spec §43. Sales, service, cash, bank and receivables together, so the owner
-- does not have to open five screens and add them up.
-- -----------------------------------------------------------------------------
create or replace function public.consolidated_mis(
  p_from date,
  p_to   date
)
returns table (
  metric  text,
  category text,
  value   numeric(18, 4),
  count_value bigint
)
language sql
stable
as $$
  select 'Vehicles sold', 'Sales',
         coalesce(sum(s.total_amount), 0), count(*)::bigint
    from public.sales s
   where s.status in ('POSTED', 'DELIVERED') and s.invoice_date between p_from and p_to
  union all
  select 'Service invoices', 'Service',
         coalesce(sum(si.total_amount), 0), count(*)::bigint
    from public.service_invoices si
   where si.status = 'POSTED' and si.invoice_date between p_from and p_to
  union all
  select 'Bookings taken', 'Sales',
         coalesce(sum(b.received_amount), 0), count(*)::bigint
    from public.bookings b
   where b.booking_date between p_from and p_to
  union all
  select 'Cash collected', 'Collections',
         coalesce(sum(t.amount), 0), count(*)::bigint
    from public.cash_transactions t
   where t.direction = 'RECEIPT' and t.status = 'ACTIVE'
     and t.business_date between p_from and p_to
  union all
  select 'Cash paid out', 'Collections',
         coalesce(sum(t.amount), 0), count(*)::bigint
    from public.cash_transactions t
   where t.direction = 'PAYMENT' and t.status = 'ACTIVE'
     and t.business_date between p_from and p_to
  union all
  select 'Bank receipts', 'Collections',
         coalesce(sum(t.amount), 0), count(*)::bigint
    from public.bank_transactions t
   where t.direction = 'RECEIPT' and t.status = 'ACTIVE'
     and t.transaction_date between p_from and p_to
  union all
  -- Outstanding is as at now, not for the period: a receivable does not belong
  -- to the month it was raised in once it is still owed.
  select 'Receivable outstanding', 'Position',
         coalesce(sum(s.total_amount - s.paid_amount), 0), count(*)::bigint
    from public.sales s
   where s.status in ('POSTED', 'DELIVERED') and s.total_amount > s.paid_amount
  union all
  select 'Cash in hand', 'Position',
         coalesce(sum(c.current_balance), 0), count(*)::bigint
    from public.cash_accounts c where c.status = 'ACTIVE'
  union all
  select 'Bank balance', 'Position',
         coalesce(sum(a.current_balance), 0), count(*)::bigint
    from public.bank_accounts a where a.status = 'ACTIVE'
  union all
  select 'Vehicles in stock', 'Position',
         coalesce(sum(v.purchase_cost), 0), count(*)::bigint
    from public.vehicles v where v.status = 'IN_STOCK';
$$;

-- -----------------------------------------------------------------------------
-- public.inventory_movement_report() — what moved, and why
-- -----------------------------------------------------------------------------
create or replace function public.inventory_movement_report(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  item_id        uuid,
  item_code      text,
  item_name      text,
  item_type      text,
  received_qty   numeric(14, 3),
  issued_qty     numeric(14, 3),
  received_value numeric(18, 4),
  issued_value   numeric(18, 4),
  closing_qty    numeric(14, 3),
  closing_value  numeric(18, 4)
)
language sql
stable
as $$
  select i.id, i.item_code, i.name, i.item_type,
         coalesce(sum(t.quantity) filter (where t.quantity > 0), 0),
         coalesce(-sum(t.quantity) filter (where t.quantity < 0), 0),
         coalesce(sum(t.value) filter (where t.quantity > 0), 0),
         coalesce(-sum(t.value) filter (where t.quantity < 0), 0),
         coalesce(max(s.total_qty), 0),
         coalesce(max(s.total_value), 0)
    from public.inventory_items i
    left join public.inventory_transactions t
      on t.item_id = i.id
     and t.created_at::date between p_from and p_to
     and (p_branch_id is null or t.branch_id = p_branch_id)
    left join lateral (
      select sum(st.quantity) total_qty, sum(st.stock_value) total_value
        from public.inventory_stock st
       where st.item_id = i.id
         and (p_branch_id is null or st.branch_id = p_branch_id)
    ) s on true
   group by i.id, i.item_code, i.name, i.item_type
  having coalesce(sum(abs(t.quantity)), 0) > 0 or coalesce(max(s.total_qty), 0) > 0
   order by i.name;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.finance_summary(date, date, uuid) to authenticated';
    execute 'grant execute on function public.branch_performance(date, date) to authenticated';
    execute 'grant execute on function public.margin_report(date, date, uuid) to authenticated';
    execute 'grant execute on function public.consolidated_mis(date, date) to authenticated';
    execute 'grant execute on function public.inventory_movement_report(date, date, uuid) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0036_transfers_returns_adjustments.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0036 — Vehicle transfers, sales returns, and stock adjustments
-- =============================================================================
-- Spec §16, §21, §35.
--
-- What these three have in common: each moves value, so each writes a journal
-- alongside whatever it moves. A transfer that moves a chassis between branches
-- without moving its cost leaves both branches' stock values wrong; an
-- adjustment that changes quantity without touching the ledger leaves stock
-- value disagreeing with the balance sheet.
--
-- Rollback: drop the functions below and restore app.vehicles_log_movement()
-- from 0017.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- app.vehicles_log_movement() — teach the existing trigger these movements
-- -----------------------------------------------------------------------------
-- 0017 makes this trigger the sole writer of the vehicle stock ledger, "so the
-- log cannot be forgotten by a caller", and the table is append-only. A function
-- that both moves a vehicle and writes its own ledger row therefore produces two
-- rows for one movement, and no report can tell which of them is the movement.
--
-- So the functions below move the vehicle and leave the logging here. Two things
-- the trigger could not previously know:
--
--   * that leaving stock as TRANSFERRED is a TRANSFER_OUT and that coming back
--     from a sale is a RETURN — both derivable from the status pair;
--   * which document caused the movement, which is not derivable, so callers
--     pass it in `app.vehicle_movement_ref` as '<type>:<uuid>'. The setting is
--     transaction-local and each caller clears it immediately after the update,
--     so it can never leak onto an unrelated one.
-- -----------------------------------------------------------------------------
create or replace function app.vehicles_log_movement()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ref  text;
  v_type text;
  v_id   uuid;
begin
  if tg_op = 'INSERT' then
    insert into public.vehicle_stock_transactions
      (dealer_id, branch_id, vehicle_id, transaction_type, to_status, to_branch_id, value, created_by)
    values (new.dealer_id, new.branch_id, new.id, 'PURCHASE', new.status, new.branch_id,
            new.purchase_cost, new.created_by);
    return null;
  end if;

  if new.status is distinct from old.status or new.branch_id is distinct from old.branch_id then
    v_ref := nullif(current_setting('app.vehicle_movement_ref', true), '');
    if v_ref is not null then
      v_type := split_part(v_ref, ':', 1);
      v_id   := nullif(split_part(v_ref, ':', 2), '')::uuid;
    end if;

    insert into public.vehicle_stock_transactions
      (dealer_id, branch_id, vehicle_id, transaction_type,
       from_status, to_status, from_branch_id, to_branch_id, value,
       reference_type, reference_id, created_by)
    values (new.dealer_id, new.branch_id, new.id,
            case
              -- The branch moved, so the unit has arrived somewhere.
              when new.branch_id is distinct from old.branch_id then 'TRANSFER_IN'
              -- On its way: out of the source branch's stock, not yet anywhere.
              when new.status = 'TRANSFERRED'                    then 'TRANSFER_OUT'
              when old.status in ('SOLD_PENDING_DELIVERY', 'DELIVERED')
                   and new.status = 'IN_STOCK'                   then 'RETURN'
              else 'STATUS_CHANGE'
            end,
            old.status, new.status, old.branch_id, new.branch_id, new.purchase_cost,
            v_type, v_id, new.updated_by);
  end if;

  return null;
end;
$$;

comment on function app.vehicles_log_movement() is
  'Sole writer of the vehicle stock ledger (spec §34). Labels transfers and '
  'returns from the status pair and takes the causing document from the '
  'transaction-local setting app.vehicle_movement_ref.';

-- -----------------------------------------------------------------------------
-- public.dispatch_vehicle_transfer() — spec §16
-- -----------------------------------------------------------------------------
create or replace function public.dispatch_vehicle_transfer(
  p_vehicle_id   uuid,
  p_to_branch_id uuid,
  p_remarks      text default null
)
returns table (transfer_id uuid, transfer_number text)
language plpgsql
as $$
declare
  v_vehicle public.vehicles;
  v_number  text;
  v_id      uuid;
begin
  select * into v_vehicle from public.vehicles where id = p_vehicle_id for update;

  if v_vehicle.id is null then
    raise exception 'Vehicle not found.' using errcode = 'no_data_found';
  end if;
  if v_vehicle.status <> 'IN_STOCK' then
    raise exception 'Vehicle % is % — only a vehicle in stock can be transferred.',
      v_vehicle.chassis_no, v_vehicle.status using errcode = 'check_violation';
  end if;
  if v_vehicle.branch_id = p_to_branch_id then
    raise exception 'The vehicle is already at that branch.' using errcode = 'check_violation';
  end if;

  v_number := app.next_document_number(
    v_vehicle.dealer_id, v_vehicle.branch_id, 'STOCK_TRANSFER',
    app.financial_year_token(v_vehicle.dealer_id, current_date));

  insert into public.vehicle_transfers
    (dealer_id, transfer_number, vehicle_id, from_branch_id, to_branch_id,
     status, dispatched_by, remarks)
  values
    (v_vehicle.dealer_id, v_number, p_vehicle_id, v_vehicle.branch_id, p_to_branch_id,
     'IN_TRANSIT', auth.uid(), p_remarks)
  returning id into v_id;

  -- TRANSFERRED, not yet at the destination: a vehicle on a lorry is at neither
  -- branch, and showing it as available at either would let it be sold twice.
  -- The transfer document carries IN_TRANSIT; the vehicle carries TRANSFERRED,
  -- which is the status spec §13 defines and the only one app.vehicles_guard_status()
  -- will accept out of IN_STOCK and back again on receipt.
  --
  -- The TRANSFER_OUT ledger row is written by app.vehicles_log_movement().
  perform set_config('app.vehicle_movement_ref', 'VEHICLE_TRANSFER:' || v_id, true);

  update public.vehicles
     set status = 'TRANSFERRED', updated_by = auth.uid()
   where id = p_vehicle_id;

  perform set_config('app.vehicle_movement_ref', '', true);

  transfer_id := v_id; transfer_number := v_number;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.receive_vehicle_transfer() — spec §16
-- -----------------------------------------------------------------------------
create or replace function public.receive_vehicle_transfer(
  p_transfer_id uuid,
  p_remarks     text default null
)
returns void
language plpgsql
as $$
declare v_transfer public.vehicle_transfers;
begin
  select * into v_transfer from public.vehicle_transfers where id = p_transfer_id for update;

  if v_transfer.id is null then
    raise exception 'Transfer not found.' using errcode = 'no_data_found';
  end if;
  if v_transfer.status <> 'IN_TRANSIT' then
    raise exception 'Transfer % is % and cannot be received again.',
      v_transfer.transfer_number, v_transfer.status using errcode = 'check_violation';
  end if;

  update public.vehicle_transfers
     set status = 'RECEIVED', received_at = now(), received_by = auth.uid(),
         remarks = coalesce(p_remarks, remarks)
   where id = p_transfer_id;

  -- The TRANSFER_IN ledger row, at the destination branch, is written by
  -- app.vehicles_log_movement() off this update.
  perform set_config('app.vehicle_movement_ref', 'VEHICLE_TRANSFER:' || p_transfer_id, true);

  update public.vehicles
     set branch_id = v_transfer.to_branch_id, status = 'IN_STOCK', updated_by = auth.uid()
   where id = v_transfer.vehicle_id;

  perform set_config('app.vehicle_movement_ref', '', true);
end;
$$;

-- -----------------------------------------------------------------------------
-- public.transfer_inventory_stock() — spec §35
-- -----------------------------------------------------------------------------
-- The source lot is preserved across the move: local stock transferred to
-- another branch arrives as local stock. Merging it into company stock would
-- destroy the distinction spec §60.16 exists to keep.
-- -----------------------------------------------------------------------------
create or replace function public.transfer_inventory_stock(
  p_item_id        uuid,
  p_from_branch_id uuid,
  p_to_branch_id   uuid,
  p_quantity       numeric,
  p_source         text default 'COMPANY',
  p_remarks        text default null
)
returns void
language plpgsql
as $$
declare
  v_dealer    uuid;
  v_available numeric(14, 3);
  v_cost      numeric(18, 4);
begin
  if p_quantity <= 0 then
    raise exception 'Quantity must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_from_branch_id = p_to_branch_id then
    raise exception 'The source and destination branches are the same.' using errcode = 'check_violation';
  end if;
  if p_source not in ('LOCAL', 'COMPANY') then
    raise exception 'Source must be LOCAL or COMPANY.' using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer from public.inventory_items where id = p_item_id;
  if v_dealer is null then
    raise exception 'Item not found.' using errcode = 'no_data_found';
  end if;

  select quantity, average_cost into v_available, v_cost
    from public.inventory_stock
   where item_id = p_item_id and branch_id = p_from_branch_id and source = p_source
     for update;

  if coalesce(v_available, 0) < p_quantity then
    raise exception 'Only % in % stock at the source branch.', coalesce(v_available, 0), p_source
      using errcode = 'check_violation';
  end if;

  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
     reference_type, narration, created_by)
  values
    (v_dealer, p_from_branch_id, p_item_id, p_source, 'TRANSFER_OUT', -p_quantity, v_cost,
     'STOCK_TRANSFER', coalesce(p_remarks, 'Transferred out'), auth.uid()),
    (v_dealer, p_to_branch_id, p_item_id, p_source, 'TRANSFER_IN', p_quantity, v_cost,
     'STOCK_TRANSFER', coalesce(p_remarks, 'Transferred in'), auth.uid());
end;
$$;

-- -----------------------------------------------------------------------------
-- public.adjust_inventory_stock() — spec §35
-- -----------------------------------------------------------------------------
-- A reason is mandatory. An adjustment without one is indistinguishable from
-- theft, and the whole point of the stock ledger is that it can be questioned.
-- -----------------------------------------------------------------------------
create or replace function public.adjust_inventory_stock(
  p_item_id   uuid,
  p_branch_id uuid,
  p_source    text,
  p_quantity  numeric,
  p_reason    text
)
returns void
language plpgsql
as $$
declare
  v_dealer    uuid;
  v_available numeric(14, 3);
  v_cost      numeric(18, 4);
begin
  if p_quantity = 0 then
    raise exception 'An adjustment of zero changes nothing.' using errcode = 'check_violation';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A stock adjustment requires a reason.'
      using errcode = 'check_violation',
            hint = 'Spec §35: adjustments are auditable, so they must be explained.';
  end if;
  if p_source not in ('LOCAL', 'COMPANY') then
    raise exception 'Source must be LOCAL or COMPANY.' using errcode = 'check_violation';
  end if;

  select dealer_id, standard_cost into v_dealer, v_cost
    from public.inventory_items where id = p_item_id;

  if v_dealer is null then
    raise exception 'Item not found.' using errcode = 'no_data_found';
  end if;

  select quantity, average_cost into v_available, v_cost
    from public.inventory_stock
   where item_id = p_item_id and branch_id = p_branch_id and source = p_source
     for update;

  -- Stock cannot go negative: a count that says less than zero is a wrong count.
  if p_quantity < 0 and coalesce(v_available, 0) < abs(p_quantity) then
    raise exception 'Only % in stock — an adjustment of % would drive it negative.',
      coalesce(v_available, 0), p_quantity using errcode = 'check_violation';
  end if;

  if v_cost is null or v_cost = 0 then
    select standard_cost into v_cost from public.inventory_items where id = p_item_id;
  end if;

  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
     reference_type, narration, reason, created_by)
  values
    (v_dealer, p_branch_id, p_item_id, p_source, 'ADJUSTMENT', p_quantity, coalesce(v_cost, 0),
     'ADJUSTMENT', 'Stock adjustment', btrim(p_reason), auth.uid());
end;
$$;

-- -----------------------------------------------------------------------------
-- public.return_vehicle_sale() — spec §21
-- -----------------------------------------------------------------------------
-- A return is a reversal with a reason, never an edit. The original invoice
-- stays exactly as issued, its journal is reversed, and the vehicle comes back
-- into stock — which is only possible before it has been delivered.
-- -----------------------------------------------------------------------------
create or replace function public.return_vehicle_sale(
  p_sale_id uuid,
  p_reason  text
)
returns uuid
language plpgsql
as $$
declare
  v_sale    public.sales;
  v_entry   uuid;
  v_alloc   record;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A sales return requires a reason.'
      using errcode = 'check_violation',
            hint = 'Spec §21: the reason is part of the record, not optional.';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;

  if v_sale.id is null then
    raise exception 'Sale not found.' using errcode = 'no_data_found';
  end if;
  if v_sale.status <> 'POSTED' then
    raise exception 'Invoice % is % — only a posted, undelivered sale can be returned.',
      v_sale.invoice_number, v_sale.status using errcode = 'check_violation';
  end if;
  if v_sale.paid_amount > 0 then
    raise exception 'Invoice % has % received against it. Refund it before returning the sale.',
      v_sale.invoice_number, v_sale.paid_amount
      using errcode = 'check_violation';
  end if;

  -- The reversal carries the reason and points back at what it reverses.
  v_entry := app.reverse_journal(v_sale.journal_entry_id, btrim(p_reason), current_date);

  -- Fitted accessories go back into the lot they came out of.
  for v_alloc in
    select t.item_id, t.source, -t.quantity as qty, t.unit_cost
      from public.inventory_transactions t
     where t.reference_type = 'SALE' and t.reference_id = p_sale_id and t.quantity < 0
  loop
    insert into public.inventory_transactions
      (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
       reference_type, reference_id, narration, reason, created_by)
    values
      (v_sale.dealer_id, v_sale.branch_id, v_alloc.item_id, v_alloc.source, 'RETURN',
       v_alloc.qty, v_alloc.unit_cost, 'SALE_RETURN', p_sale_id,
       'Returned from ' || v_sale.invoice_number, btrim(p_reason), auth.uid());
  end loop;

  update public.sales
     set status = 'RETURNED', updated_by = auth.uid(), notes =
           coalesce(notes || E'\n', '') || 'Returned: ' || btrim(p_reason)
   where id = p_sale_id;

  -- The RETURN ledger row is written by app.vehicles_log_movement().
  perform set_config('app.vehicle_movement_ref', 'SALE_RETURN:' || p_sale_id, true);

  update public.vehicles
     set status = 'IN_STOCK', updated_by = auth.uid()
   where id = v_sale.vehicle_id;

  perform set_config('app.vehicle_movement_ref', '', true);

  return v_entry;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.dispatch_vehicle_transfer(uuid, uuid, text) to authenticated';
    execute 'grant execute on function public.receive_vehicle_transfer(uuid, text) to authenticated';
    execute 'grant execute on function public.transfer_inventory_stock(uuid, uuid, uuid, numeric, text, text) to authenticated';
    execute 'grant execute on function public.adjust_inventory_stock(uuid, uuid, text, numeric, text) to authenticated';
    execute 'grant execute on function public.return_vehicle_sale(uuid, text) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0037_customer_ledger_opening.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0037 — Customer ledger opening balance
-- =============================================================================
-- Spec §11, §41.
--
-- The customer ledger from 0026 computed its running balance across the
-- filtered window alone, so a ledger for August opened at zero however much the
-- customer owed on 31 July. Every balance on the page was then wrong by the
-- carried-forward amount, and the subsidiary ledger stopped agreeing with the
-- receivable control account — which is the one property §41 asks it to have.
--
-- Both functions here are invoker-rights, so RLS scopes them to the caller's
-- dealer exactly as it does a plain select.
--
-- Rollback: restore public.customer_ledger(uuid, date, date) from 0026 and
--           drop public.customer_ledger_opening(uuid, date).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.customer_ledger_opening() — what the customer owed before the window
-- -----------------------------------------------------------------------------
-- Returned separately rather than folded into the ledger because the opening
-- balance has to be shown even when the window contains no movements at all: a
-- customer who owes money and did nothing this month still has a balance, and a
-- statement that renders as empty would be read as "nothing outstanding".
-- -----------------------------------------------------------------------------
create or replace function public.customer_ledger_opening(
  p_customer_id uuid,
  p_as_on       date
)
returns numeric
language sql
stable
as $$
  select coalesce(sum(l.debit - l.credit), 0)::numeric(18, 4)
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.party_type = 'CUSTOMER'
     and l.party_id = p_customer_id
     and je.status in ('POSTED', 'REVERSED')
     and je.entry_date < p_as_on;
$$;

comment on function public.customer_ledger_opening(uuid, date) is
  'Customer balance carried into a date (spec §41). Debit positive: the customer owes.';

-- -----------------------------------------------------------------------------
-- public.customer_ledger() — the running account, seeded with the opening
-- -----------------------------------------------------------------------------
create or replace function public.customer_ledger(
  p_customer_id uuid,
  p_from        date,
  p_to          date
)
returns table (
  entry_date      date,
  entry_number    text,
  narration       text,
  debit           numeric(18, 4),
  credit          numeric(18, 4),
  running_balance numeric(18, 4)
)
language sql
stable
as $$
  -- The subsidiary ledger is derived from party-tagged journal lines, so it
  -- reconciles to the receivable control account by construction. The running
  -- balance starts from the carried-forward balance, so any row read on its own
  -- is the customer's actual position on that date rather than a total of the
  -- window that happens to be on screen.
  select je.entry_date, je.entry_number, coalesce(l.narration, je.narration),
         l.debit, l.credit,
         public.customer_ledger_opening(p_customer_id, p_from)
           + sum(l.debit - l.credit) over (order by je.entry_date, je.entry_number, l.line_number
                                           rows between unbounded preceding and current row)
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.party_type = 'CUSTOMER'
     and l.party_id = p_customer_id
     and je.status in ('POSTED', 'REVERSED')
     and je.entry_date between p_from and p_to
   order by je.entry_date, je.entry_number, l.line_number;
$$;

comment on function public.customer_ledger(uuid, date, date) is
  'Customer running account from the general ledger (spec §41), opening balance '
  'included, so the subsidiary ledger and the control account can never disagree.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.customer_ledger_opening(uuid, date) to authenticated';
    execute 'grant execute on function public.customer_ledger(uuid, date, date) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0038_delivery_document_sequence.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0038 — Delivery and transfer numbering
-- =============================================================================
-- Spec §45, §60.3, §60.5.
--
-- Two faults, one cause.
--
-- 1. public.deliver_vehicle() numbered delivery notes from the STOCK_TRANSFER
--    sequence, so a delivery note came out as TRF-2026-000004 and drew from the
--    same counter as inter-branch transfers. The delivery is labelled as though
--    it were a transfer, and the two series interleave, so each shows gaps that
--    read as missing documents to anyone auditing them.
--
-- 2. Both series were numbered from *branch-scoped* sequences that carry the
--    same prefix at every branch, while `vehicle_transfers_number_key` and
--    `deliveries_number_key` are unique per *dealer*. Two branches therefore
--    both generate TRF-2026-000001, and the second one to try is rejected by
--    the constraint. A single-branch dealer never sees it; a two-branch dealer
--    hits it on the second branch's first transfer, which is exactly the
--    multi-branch operation spec §60.3 requires to work from day one.
--
-- The sequence scope has to match the uniqueness scope, so both become
-- dealer-wide, the way JOURNAL already is in 0006. Branch is still recorded on
-- every row; it simply stops being part of how the number is allocated.
--
-- Existing numbers are left exactly as issued, and the dealer-wide counter
-- starts above the highest number any branch reached, so nothing is reissued.
--
-- Rollback: restore public.deliver_vehicle() and public.dispatch_vehicle_transfer()
--           from 0028 and 0036, and delete the dealer-wide DELIVERY and
--           STOCK_TRANSFER rows from public.document_sequences.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Dealer-wide sequences, carrying forward each dealer's highest branch counter
-- -----------------------------------------------------------------------------
-- Derived from the sequences that already exist rather than from branches, so
-- this covers the dealer/financial-year combinations actually in use and stays
-- correct for a dealer whose financial year is not the default.
-- next_document_number() raises when a scope has no row, so this backfill is
-- what stops the first transfer or delivery after this migration from failing.
-- -----------------------------------------------------------------------------
insert into public.document_sequences
  (dealer_id, branch_id, doc_type, financial_year, prefix, padding, last_number)
select ds.dealer_id, null::uuid, 'STOCK_TRANSFER', ds.financial_year, 'TRF', 6,
       max(ds.last_number)
  from public.document_sequences ds
 where ds.doc_type = 'STOCK_TRANSFER' and ds.branch_id is not null
 group by ds.dealer_id, ds.financial_year
on conflict on constraint document_sequences_scope_key do nothing;

-- Deliveries were drawing on the transfer counter, so the highest delivery
-- number issued is already covered by the figure carried forward above.
insert into public.document_sequences
  (dealer_id, branch_id, doc_type, financial_year, prefix, padding, last_number)
select distinct ds.dealer_id, null::uuid, 'DELIVERY', ds.financial_year, 'DN', 6, 0
  from public.document_sequences ds
 where ds.branch_id is not null
on conflict on constraint document_sequences_scope_key do nothing;

-- The branch-scoped transfer rows are left in place but no longer consulted;
-- dropping them would discard the record of what each branch had issued.

-- -----------------------------------------------------------------------------
-- public.deliver_vehicle() — spec §19, the final step
-- -----------------------------------------------------------------------------
create or replace function public.deliver_vehicle(
  p_sale_id      uuid,
  p_received_by  text default null,
  p_odometer     numeric default null,
  p_remarks      text default null
)
returns text
language plpgsql
as $$
declare
  v_sale    public.sales;
  v_year    text;
  v_number  text;
begin
  select * into v_sale from public.sales where id = p_sale_id for update;

  if v_sale.id is null then
    raise exception 'Sale not found.' using errcode = 'no_data_found';
  end if;
  if v_sale.status <> 'POSTED' then
    raise exception 'Only a POSTED sale can be delivered; this one is %.', v_sale.status
      using errcode = 'check_violation';
  end if;

  v_year := app.financial_year_token(v_sale.dealer_id, current_date);
  v_number := app.next_document_number(v_sale.dealer_id, null, 'DELIVERY', v_year);

  insert into public.deliveries
    (dealer_id, branch_id, sale_id, vehicle_id, delivery_number,
     delivered_by, received_by_name, odometer, remarks)
  values
    (v_sale.dealer_id, v_sale.branch_id, p_sale_id, v_sale.vehicle_id, v_number,
     auth.uid(), p_received_by, p_odometer, p_remarks);

  update public.vehicles set status = 'DELIVERED', updated_by = auth.uid()
   where id = v_sale.vehicle_id;

  update public.sales set status = 'DELIVERED', delivered_by = auth.uid()
   where id = p_sale_id;

  return v_number;
end;
$$;

comment on function public.deliver_vehicle(uuid, text, numeric, text) is
  'Records the handover and closes the sale (spec §19). Numbered from the '
  'dealer-wide DELIVERY series, which is its own (spec §45).';

-- -----------------------------------------------------------------------------
-- public.dispatch_vehicle_transfer() — spec §35, numbered dealer-wide
-- -----------------------------------------------------------------------------
create or replace function public.dispatch_vehicle_transfer(
  p_vehicle_id   uuid,
  p_to_branch_id uuid,
  p_remarks      text default null
)
returns table (transfer_id uuid, transfer_number text)
language plpgsql
as $$
declare
  v_vehicle public.vehicles;
  v_number  text;
  v_id      uuid;
begin
  select * into v_vehicle from public.vehicles where id = p_vehicle_id for update;

  if v_vehicle.id is null then
    raise exception 'Vehicle not found.' using errcode = 'no_data_found';
  end if;
  if v_vehicle.status <> 'IN_STOCK' then
    raise exception 'Vehicle % is % — only a vehicle in stock can be transferred.',
      v_vehicle.chassis_no, v_vehicle.status using errcode = 'check_violation';
  end if;
  if v_vehicle.branch_id = p_to_branch_id then
    raise exception 'The vehicle is already at that branch.' using errcode = 'check_violation';
  end if;

  -- Dealer-wide: the number has to be unique across the dealer, so it cannot be
  -- allocated from a per-branch counter that every branch starts at one.
  v_number := app.next_document_number(
    v_vehicle.dealer_id, null, 'STOCK_TRANSFER',
    app.financial_year_token(v_vehicle.dealer_id, current_date));

  insert into public.vehicle_transfers
    (dealer_id, transfer_number, vehicle_id, from_branch_id, to_branch_id,
     status, dispatched_by, remarks)
  values
    (v_vehicle.dealer_id, v_number, p_vehicle_id, v_vehicle.branch_id, p_to_branch_id,
     'IN_TRANSIT', auth.uid(), p_remarks)
  returning id into v_id;

  -- TRANSFERRED, not yet at the destination: a vehicle on a lorry is at neither
  -- branch, and showing it as available at either would let it be sold twice.
  -- The TRANSFER_OUT ledger row is written by app.vehicles_log_movement().
  perform set_config('app.vehicle_movement_ref', 'VEHICLE_TRANSFER:' || v_id, true);

  update public.vehicles
     set status = 'TRANSFERRED', updated_by = auth.uid()
   where id = p_vehicle_id;

  perform set_config('app.vehicle_movement_ref', '', true);

  transfer_id := v_id; transfer_number := v_number;
  return next;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0039_dealer_wide_document_numbering.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0039 — Dealer-wide document numbering
-- =============================================================================
-- Spec §45, §60.3, §60.5.
--
-- Seven document types still allocate their numbers from *branch-scoped*
-- counters while the tables that store them enforce *dealer-wide* uniqueness:
--
--   sales.invoice_number            sales_invoice_key            (dealer_id, …)
--   bookings.booking_number         bookings_number_key          (dealer_id, …)
--   booking_payments.receipt_number booking_payments_receipt_key (dealer_id, …)
--   sale_payments.receipt_number    sale_payments_receipt_key    (dealer_id, …)
--   service_payments.receipt_number sp_receipt_key               (dealer_id, …)
--   job_cards.job_card_number       jc_number_key                (dealer_id, …)
--   service_invoices.invoice_number si_number_key                (dealer_id, …)
--
-- Every branch's counter starts at 1 and every branch shares the same prefix, so
-- two branches both produce INV-2026-000001 and the second one to try is
-- rejected by the constraint. A single-branch dealer never sees it; a two-branch
-- dealer hits it on the second branch's first document of each type — which is
-- the multi-branch operation spec §60.3 requires to work from day one. 0038 hit
-- exactly this for transfers and deliveries; these are the remaining seven.
--
-- FIXED HERE RATHER THAN AT EACH CALL SITE.
--
-- 0038 fixed its two types by rewriting the functions that issue them to pass a
-- null branch. Repeating that for seven types means copying six large function
-- bodies into this migration — and three of them (record_sale_payment,
-- create_job_card, deliver_vehicle) are rewritten again by later migrations for
-- unrelated reasons. Every one of those rewrites would have to carry this fix
-- forward by hand, and the day one of them does not, the bug returns silently
-- with no test to catch it.
--
-- So the scope decision moves out of the call sites and into the sequence
-- allocator, where it belongs: **the scope of a document series is a property of
-- the document type, recorded in document_sequences, not of the code that asks
-- for a number.** A dealer-wide row, where one is configured, wins over the
-- branch the caller passed. Callers are unchanged and stay correct as they are
-- rewritten in future.
--
-- A type that genuinely wants a per-branch series still gets one: simply do not
-- configure a dealer-wide row for it. Nothing in the schema wants that today.
--
-- Existing numbers are left exactly as issued, and each dealer-wide counter
-- starts above the highest number any of that dealer's branches reached, so no
-- number is ever reissued.
--
-- Rollback: restore app.next_document_number() from 0006 and delete the
--           dealer-wide rows created below from public.document_sequences.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- app.next_document_number() — dealer-wide first, branch second
-- -----------------------------------------------------------------------------
create or replace function app.next_document_number(
  p_dealer_id      uuid,
  p_branch_id      uuid,
  p_doc_type       text,
  p_financial_year text
)
returns text
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_prefix  text;
  v_padding smallint;
  v_number  bigint;
begin
  -- A dealer-wide series, when configured, is authoritative for this type. The
  -- branch the caller passed is still recorded on the document; it simply is not
  -- what allocates the number (spec §45).
  update public.document_sequences ds
     set last_number = ds.last_number + 1
   where ds.dealer_id = p_dealer_id
     and ds.branch_id is null
     and ds.doc_type = p_doc_type
     and ds.financial_year = p_financial_year
  returning ds.prefix, ds.padding, ds.last_number
       into v_prefix, v_padding, v_number;

  if not found then
    update public.document_sequences ds
       set last_number = ds.last_number + 1
     where ds.dealer_id = p_dealer_id
       and ds.branch_id is not distinct from p_branch_id
       and ds.doc_type = p_doc_type
       and ds.financial_year = p_financial_year
    returning ds.prefix, ds.padding, ds.last_number
         into v_prefix, v_padding, v_number;
  end if;

  if not found then
    raise exception
      'No document sequence configured for dealer %, branch %, type %, year %.',
      p_dealer_id, coalesce(p_branch_id::text, '(dealer-wide)'), p_doc_type, p_financial_year
      using errcode = 'no_data_found',
            hint = 'Insert a row into document_sequences before issuing this document type.';
  end if;

  return v_prefix || '-' || p_financial_year || '-' || lpad(v_number::text, v_padding, '0');
end;
$$;

comment on function app.next_document_number(uuid, uuid, text, text) is
  'Returns the next number for a document scope, e.g. INV-2026-000001. '
  'A dealer-wide sequence takes precedence over a branch one, so a series that '
  'must be unique per dealer cannot be allocated from per-branch counters '
  '(spec §45, §60.3). Row-locked, so it is safe under concurrent sales (spec §49).';

-- -----------------------------------------------------------------------------
-- Dealer-wide rows for the seven types, carrying each dealer's highest counter
-- -----------------------------------------------------------------------------
-- Derived from the sequences that already exist rather than from branches, so
-- this covers the dealer / financial-year / prefix combinations actually in use
-- and stays correct for a dealer whose financial year is not the default.
--
-- PAYMENT and COUNTER_INVOICE are included although nothing issues them yet:
-- they are seeded per branch, so they carry the same latent collision and would
-- surface it the day something does.
-- -----------------------------------------------------------------------------
insert into public.document_sequences
  (dealer_id, branch_id, doc_type, financial_year, prefix, padding, last_number)
select ds.dealer_id, null::uuid, ds.doc_type, ds.financial_year, ds.prefix, max(ds.padding),
       max(ds.last_number)
  from public.document_sequences ds
 where ds.branch_id is not null
   and ds.doc_type in ('VEHICLE_INVOICE', 'BOOKING', 'RECEIPT', 'PAYMENT',
                       'JOB_CARD', 'SERVICE_INVOICE', 'COUNTER_INVOICE')
 group by ds.dealer_id, ds.doc_type, ds.financial_year, ds.prefix
on conflict on constraint document_sequences_scope_key do nothing;

-- The branch-scoped rows are left in place but are no longer consulted for these
-- types; dropping them would discard the record of what each branch had issued.

-- -----------------------------------------------------------------------------
-- Sequences for the finance documents built in 0043
-- -----------------------------------------------------------------------------
-- Created here, with the rest of the numbering, so that migration deals only
-- with finance. Dealer-wide from the start: finance_applications.application_number
-- and finance_settlements.settlement_number are both unique per dealer.
-- -----------------------------------------------------------------------------
insert into public.document_sequences
  (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
select distinct ds.dealer_id, null::uuid, d.doc_type, ds.financial_year, d.prefix, 6
  from public.document_sequences ds
 cross join (values ('FINANCE_APPLICATION', 'FA'), ('FINANCE_SETTLEMENT', 'FS')) as d(doc_type, prefix)
 where ds.branch_id is not null
on conflict on constraint document_sequences_scope_key do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0040_suppliers.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0040 — Supplier master
-- =============================================================================
-- Spec §24, §41, §44.
--
-- The chart of accounts has carried "Supplier Payables" (2200) since the first
-- seed, journal_entry_lines.party_type has always accepted 'SUPPLIER', and the
-- CASH/BANK PAYMENT rules post to 2200 — but there has never been a supplier
-- table to point party_id at, so the payable has only ever been a single lump
-- with no subsidiary detail behind it. Spec §41 asks for a supplier ledger; this
-- is the record it needs.
--
-- Dealer-scoped, not branch-scoped: a supplier deals with the dealer, and any
-- branch may buy from them. Modelled on public.customers (0013), including the
-- self-provisioning code trigger — a supplier code is an identifier, not a
-- financial document, so issuing one must never fail for want of configuration.
--
-- Rollback: drop table public.suppliers; drop function app.suppliers_assign_code();
--           delete from public.document_sequences where doc_type = 'SUPPLIER';
-- =============================================================================

create table public.suppliers (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null references public.dealers (id) on delete restrict,

  -- Mandatory, dealer-unique, server-issued (spec §60.6, as for customers).
  supplier_code     text not null,

  name              text not null,
  supplier_type     text not null default 'GOODS',

  contact_person    text,
  mobile            text,
  alternate_mobile  text,
  email             text,

  address_line1     text,
  address_line2     text,
  city              text,
  state             text,
  state_code        text,
  pincode           text,

  gstin             text,
  pan               text,

  -- Payment terms, for an ageing view of the payable.
  credit_days       smallint not null default 0,

  notes             text,
  status            text not null default 'ACTIVE',

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid,
  updated_by        uuid,

  constraint suppliers_dealer_code_key unique (dealer_id, supplier_code),
  -- Load-bearing: every composite tenant foreign key that ever points at a
  -- supplier depends on this, exactly as customers_id_dealer_key does.
  constraint suppliers_id_dealer_key   unique (id, dealer_id),

  constraint suppliers_type_check   check (supplier_type in ('GOODS', 'SERVICE', 'OEM')),
  constraint suppliers_status_check check (status in ('ACTIVE', 'INACTIVE', 'BLOCKED')),
  constraint suppliers_name_check   check (length(btrim(name)) between 2 and 150),
  constraint suppliers_mobile_check check (mobile is null or mobile ~ '^[6-9][0-9]{9}$'),
  constraint suppliers_alt_mobile_check check (
    alternate_mobile is null or alternate_mobile ~ '^[6-9][0-9]{9}$'
  ),
  constraint suppliers_email_check check (
    email is null or email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[a-zA-Z]{2,}$'
  ),
  constraint suppliers_gstin_check check (
    gstin is null or gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[0-9A-Z]{1}Z[0-9A-Z]{1}$'
  ),
  constraint suppliers_pan_check     check (pan is null or pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  constraint suppliers_pincode_check check (pincode is null or pincode ~ '^[1-9][0-9]{5}$'),
  constraint suppliers_credit_days_check check (credit_days between 0 and 365)
);

comment on table public.suppliers is
  'Supplier master (spec §41, §44). Dealer-scoped: a supplier serves every branch. '
  'party_id on a journal line tagged party_type = ''SUPPLIER'' points here.';
comment on column public.suppliers.supplier_code is
  'Auto-generated, dealer-unique, issued server-side. Never supplied by the client.';

-- The same GSTIN twice within a dealer is a duplicate record. Enforced only for
-- active suppliers, so a blocked record does not prevent re-registering later.
create unique index suppliers_dealer_gstin_key
  on public.suppliers (dealer_id, gstin)
  where gstin is not null and status = 'ACTIVE';

-- -----------------------------------------------------------------------------
-- Supplier code assignment
-- -----------------------------------------------------------------------------
-- Self-provisioning, like app.customers_assign_code(). A financial document
-- whose sequence is missing should fail loudly; an identifier should not, or a
-- newly provisioned dealer cannot record its first supplier without setup.
-- -----------------------------------------------------------------------------
create or replace function app.suppliers_assign_code()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_year text;
begin
  if new.supplier_code is not null and btrim(new.supplier_code) <> '' then
    return new;  -- an explicit code (data migration) is respected
  end if;

  v_year := app.financial_year_token(new.dealer_id, coalesce(new.created_at::date, current_date));

  insert into public.document_sequences (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
  values (new.dealer_id, null, 'SUPPLIER', v_year, 'SUPP', 6)
  on conflict on constraint document_sequences_scope_key do nothing;

  new.supplier_code := app.next_document_number(new.dealer_id, null, 'SUPPLIER', v_year);
  return new;
end;
$$;

create trigger suppliers_assign_code
  before insert on public.suppliers
  for each row execute function app.suppliers_assign_code();

create trigger suppliers_set_updated_at
  before update on public.suppliers
  for each row execute function app.set_updated_at();

create trigger suppliers_audit
  after insert or update or delete on public.suppliers
  for each row execute function app.audit_trigger();

-- -----------------------------------------------------------------------------
-- Row Level Security
-- -----------------------------------------------------------------------------
alter table public.suppliers enable row level security;

create policy suppliers_select on public.suppliers
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and (app.has_permission('masters.suppliers.view')
             or app.has_permission('accounting.ledgers.view')))
  );

create policy suppliers_insert on public.suppliers
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('masters.suppliers.manage'))
  );

create policy suppliers_update on public.suppliers
  for update to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('masters.suppliers.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('masters.suppliers.manage'))
  );

-- No DELETE policy. A supplier with postings behind them must never vanish;
-- set status to INACTIVE or BLOCKED instead.

-- -----------------------------------------------------------------------------
-- Indexes
-- -----------------------------------------------------------------------------
create index suppliers_dealer_name_idx   on public.suppliers (dealer_id, lower(name));
create index suppliers_dealer_status_idx on public.suppliers (dealer_id, status);
create index suppliers_mobile_idx        on public.suppliers (dealer_id, mobile) where mobile is not null;
create index suppliers_created_idx       on public.suppliers (dealer_id, created_at desc);

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.suppliers to authenticated';
    execute 'grant all on public.suppliers to service_role';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0041_party_ledger_and_supplier_payments.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0041 — Party ledger, and supplier tagging on money movements
-- =============================================================================
-- Spec §11, §41.
--
-- Two halves of one problem: a supplier ledger needs a query that can read a
-- party account, and it needs journal lines actually tagged with the supplier.
-- Neither existed. Every writer in the codebase hardcoded party_type='CUSTOMER',
-- so account 2200 (Supplier Payables) has only ever held an undifferentiated
-- total, and no subsidiary ledger could be derived from it.
--
-- 1. The ledger from 0037 is generalised over party type. customer_ledger and
--    customer_ledger_opening become thin wrappers, so everything already calling
--    them — src/server/services/accounting/ledger-service.ts and
--    supabase/test/90_customer_ledger.sql — keeps working untouched, and the two
--    party ledgers can never drift apart because there is only one of them.
--
-- 2. record_cash_transaction and record_bank_transaction learn about suppliers.
--    These are DROPPED and recreated rather than replaced: they gain a
--    parameter, and `create or replace` cannot change a signature. Leaving both
--    signatures in place would create an overload, which makes supabase.rpc()
--    ambiguous at runtime and makes scripts/generate-types.mjs emit the same key
--    twice — a TypeScript error. The old grants die with the old functions and
--    are reissued below.
--
-- Rollback: restore record_cash_transaction from 0030 and record_bank_transaction
--           from 0031 with their grants; drop public.party_ledger,
--           public.party_ledger_opening; restore customer_ledger and
--           customer_ledger_opening from 0037; drop the columns added below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.party_ledger_opening() — what a party's balance was before a date
-- -----------------------------------------------------------------------------
-- Debit positive throughout, for every party type. For a customer that reads as
-- "they owe us"; for a supplier the natural sign is the mirror, so a supplier
-- balance is normally negative here and the view labels it Cr. Keeping one
-- convention in the data and inverting only for display is what lets both
-- ledgers reconcile to their control accounts with the same arithmetic.
-- -----------------------------------------------------------------------------
create or replace function public.party_ledger_opening(
  p_party_type text,
  p_party_id   uuid,
  p_as_on      date
)
returns numeric
language sql
stable
as $$
  select coalesce(sum(l.debit - l.credit), 0)::numeric(18, 4)
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.party_type = p_party_type
     and l.party_id = p_party_id
     and je.status in ('POSTED', 'REVERSED')
     and je.entry_date < p_as_on;
$$;

comment on function public.party_ledger_opening(text, uuid, date) is
  'Balance carried into a date for any party (spec §41). Debit positive.';

-- -----------------------------------------------------------------------------
-- public.party_ledger() — the running account for any party
-- -----------------------------------------------------------------------------
create or replace function public.party_ledger(
  p_party_type text,
  p_party_id   uuid,
  p_from       date,
  p_to         date
)
returns table (
  entry_date      date,
  entry_number    text,
  narration       text,
  debit           numeric(18, 4),
  credit          numeric(18, 4),
  running_balance numeric(18, 4)
)
language sql
stable
as $$
  -- Derived from party-tagged journal lines, so a subsidiary ledger reconciles
  -- to its control account by construction. The running balance starts from the
  -- carried-forward balance, so any row read on its own is the party's actual
  -- position on that date rather than a total of the window on screen.
  select je.entry_date, je.entry_number, coalesce(l.narration, je.narration),
         l.debit, l.credit,
         public.party_ledger_opening(p_party_type, p_party_id, p_from)
           + sum(l.debit - l.credit) over (order by je.entry_date, je.entry_number, l.line_number
                                           rows between unbounded preceding and current row)
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.party_type = p_party_type
     and l.party_id = p_party_id
     and je.status in ('POSTED', 'REVERSED')
     and je.entry_date between p_from and p_to
   order by je.entry_date, je.entry_number, l.line_number;
$$;

comment on function public.party_ledger(text, uuid, date, date) is
  'Running account for any party from the general ledger (spec §41), opening '
  'balance included, so the subsidiary ledger and the control account agree.';

-- -----------------------------------------------------------------------------
-- The customer ledger becomes a wrapper — one implementation, two entry points
-- -----------------------------------------------------------------------------
create or replace function public.customer_ledger_opening(
  p_customer_id uuid,
  p_as_on       date
)
returns numeric
language sql
stable
as $$
  select public.party_ledger_opening('CUSTOMER', p_customer_id, p_as_on);
$$;

create or replace function public.customer_ledger(
  p_customer_id uuid,
  p_from        date,
  p_to          date
)
returns table (
  entry_date      date,
  entry_number    text,
  narration       text,
  debit           numeric(18, 4),
  credit          numeric(18, 4),
  running_balance numeric(18, 4)
)
language sql
stable
as $$
  select * from public.party_ledger('CUSTOMER', p_customer_id, p_from, p_to);
$$;

-- -----------------------------------------------------------------------------
-- Party columns on the money movements
-- -----------------------------------------------------------------------------
-- cash_transactions already carries customer_id; bank_transactions carried no
-- party at all, so a bank receipt from a customer could not be attributed.
alter table public.cash_transactions
  add column if not exists supplier_id uuid;

alter table public.bank_transactions
  add column if not exists supplier_id uuid,
  add column if not exists customer_id uuid;

alter table public.cash_transactions
  add constraint cash_transactions_supplier_tenant_fkey
  foreign key (supplier_id, dealer_id) references public.suppliers (id, dealer_id);

alter table public.bank_transactions
  add constraint bank_transactions_supplier_tenant_fkey
  foreign key (supplier_id, dealer_id) references public.suppliers (id, dealer_id);

alter table public.bank_transactions
  add constraint bank_transactions_customer_tenant_fkey
  foreign key (customer_id, dealer_id) references public.customers (id, dealer_id);

create index cash_transactions_supplier_idx on public.cash_transactions (supplier_id)
  where supplier_id is not null;
create index bank_transactions_supplier_idx on public.bank_transactions (supplier_id)
  where supplier_id is not null;
create index bank_transactions_customer_idx on public.bank_transactions (customer_id)
  where customer_id is not null;

-- -----------------------------------------------------------------------------
-- public.record_cash_transaction() — spec §37, now party-aware
-- -----------------------------------------------------------------------------
drop function if exists public.record_cash_transaction(uuid, text, numeric, text, uuid, uuid, text, date);

create function public.record_cash_transaction(
  p_branch_id   uuid,
  p_direction   text,
  p_amount      numeric,
  p_particular  text,
  p_account_id  uuid,
  p_customer_id uuid default null,
  p_reference   text default null,
  p_date        date default current_date,
  p_supplier_id uuid default null
)
returns table (transaction_id bigint, journal_entry_id uuid, balance_after numeric)
language plpgsql
as $$
declare
  v_dealer   uuid;
  v_account  public.cash_accounts;
  v_entry    uuid;
  v_cash_acc uuid;
  v_txn      bigint;
  v_balance  numeric(18, 4);
  v_party    text;
  v_party_id uuid;
begin
  if p_amount <= 0 then
    raise exception 'The amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_direction not in ('RECEIPT', 'PAYMENT') then
    raise exception 'Direction must be RECEIPT or PAYMENT.' using errcode = 'check_violation';
  end if;
  -- A journal line carries one party. Two would make the entry belong to both
  -- subsidiary ledgers and reconcile against neither.
  if p_customer_id is not null and p_supplier_id is not null then
    raise exception 'An entry belongs to a customer or a supplier, not both.'
      using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  select * into v_account from public.cash_accounts where branch_id = p_branch_id;

  if v_account.id is null then
    raise exception 'This branch has no cash account.' using errcode = 'no_data_found';
  end if;

  -- Opens the day if needed, and fails if it is already closed (spec §36).
  perform public.ensure_cash_day(p_branch_id, p_date);

  v_cash_acc := v_account.ledger_account_id;

  v_party := case
               when p_customer_id is not null then 'CUSTOMER'
               when p_supplier_id is not null then 'SUPPLIER'
             end;
  v_party_id := coalesce(p_customer_id, p_supplier_id);

  -- A receipt debits cash and credits whatever the money was for; a payment is
  -- the mirror. The contra account is chosen by the operator, because "what was
  -- this for" is a judgement the software cannot make.
  v_entry := app.post_journal(
    v_dealer, p_branch_id, p_date,
    'CASH',
    p_particular,
    case when p_direction = 'RECEIPT' then
      jsonb_build_array(
        jsonb_build_object('account_id', v_cash_acc, 'debit', p_amount, 'credit', 0,
                           'narration', p_particular),
        jsonb_build_object('account_id', p_account_id, 'debit', 0, 'credit', p_amount,
                           'narration', p_particular,
                           'party_type', v_party, 'party_id', v_party_id)
      )
    else
      jsonb_build_array(
        jsonb_build_object('account_id', p_account_id, 'debit', p_amount, 'credit', 0,
                           'narration', p_particular,
                           'party_type', v_party, 'party_id', v_party_id),
        jsonb_build_object('account_id', v_cash_acc, 'debit', 0, 'credit', p_amount,
                           'narration', p_particular)
      )
    end,
    'CASH_BOOK', null, null
  );

  insert into public.cash_transactions
    (dealer_id, branch_id, cash_account_id, business_date, direction, amount,
     particular, reference_number, customer_id, supplier_id, journal_entry_id, created_by)
  values
    (v_dealer, p_branch_id, v_account.id, p_date, p_direction, p_amount,
     p_particular, p_reference, p_customer_id, p_supplier_id, v_entry, auth.uid())
  returning id, cash_transactions.balance_after into v_txn, v_balance;

  transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_bank_transaction() — spec §38, now party-aware
-- -----------------------------------------------------------------------------
drop function if exists public.record_bank_transaction(uuid, text, numeric, text, uuid, date, text, text, text);

create function public.record_bank_transaction(
  p_bank_account_id uuid,
  p_direction       text,
  p_amount          numeric,
  p_particular      text,
  p_account_id      uuid,
  p_date            date default current_date,
  p_reference       text default null,
  p_utr             text default null,
  p_instrument      text default null,
  p_customer_id     uuid default null,
  p_supplier_id     uuid default null
)
returns table (transaction_id bigint, journal_entry_id uuid, balance_after numeric)
language plpgsql
as $$
declare
  v_bank     public.bank_accounts;
  v_entry    uuid;
  v_txn      bigint;
  v_balance  numeric(18, 4);
  v_party    text;
  v_party_id uuid;
begin
  if p_amount <= 0 then
    raise exception 'The amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_direction not in ('RECEIPT', 'PAYMENT') then
    raise exception 'Direction must be RECEIPT or PAYMENT.' using errcode = 'check_violation';
  end if;
  if p_customer_id is not null and p_supplier_id is not null then
    raise exception 'An entry belongs to a customer or a supplier, not both.'
      using errcode = 'check_violation';
  end if;

  select * into v_bank from public.bank_accounts where id = p_bank_account_id;
  if v_bank.id is null then
    raise exception 'Bank account not found.' using errcode = 'no_data_found';
  end if;
  if v_bank.status <> 'ACTIVE' then
    raise exception 'Bank account % is %.', v_bank.name, v_bank.status
      using errcode = 'check_violation';
  end if;

  v_party := case
               when p_customer_id is not null then 'CUSTOMER'
               when p_supplier_id is not null then 'SUPPLIER'
             end;
  v_party_id := coalesce(p_customer_id, p_supplier_id);

  v_entry := app.post_journal(
    v_bank.dealer_id, v_bank.branch_id, p_date,
    'BANK',
    p_particular,
    case when p_direction = 'RECEIPT' then
      jsonb_build_array(
        jsonb_build_object('account_id', v_bank.ledger_account_id, 'debit', p_amount, 'credit', 0,
                           'narration', p_particular),
        jsonb_build_object('account_id', p_account_id, 'debit', 0, 'credit', p_amount,
                           'narration', p_particular,
                           'party_type', v_party, 'party_id', v_party_id)
      )
    else
      jsonb_build_array(
        jsonb_build_object('account_id', p_account_id, 'debit', p_amount, 'credit', 0,
                           'narration', p_particular,
                           'party_type', v_party, 'party_id', v_party_id),
        jsonb_build_object('account_id', v_bank.ledger_account_id, 'debit', 0, 'credit', p_amount,
                           'narration', p_particular)
      )
    end,
    'BANK_BOOK', null, null
  );

  insert into public.bank_transactions
    (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
     reference_number, utr, instrument_number, customer_id, supplier_id,
     journal_entry_id, created_by)
  values
    (v_bank.dealer_id, p_bank_account_id, p_date, p_direction, p_amount, p_particular,
     p_reference, nullif(btrim(p_utr), ''), nullif(btrim(p_instrument), ''),
     p_customer_id, p_supplier_id, v_entry, auth.uid())
  returning id, bank_transactions.balance_after into v_txn, v_balance;

  transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
  return next;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.party_ledger(text, uuid, date, date) to authenticated';
    execute 'grant execute on function public.party_ledger_opening(text, uuid, date) to authenticated';
    execute 'grant execute on function public.customer_ledger(uuid, date, date) to authenticated';
    execute 'grant execute on function public.customer_ledger_opening(uuid, date) to authenticated';
    execute 'grant execute on function public.record_cash_transaction(uuid, text, numeric, text, uuid, uuid, text, date, uuid) to authenticated';
    execute 'grant execute on function public.record_bank_transaction(uuid, text, numeric, text, uuid, date, text, text, text, uuid, uuid) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0042_finance_accounting_rules.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0042 — Accounting rules for the remaining finance events
-- =============================================================================
-- Spec §22, §25, §26.
--
-- 0027 seeded FINANCE (DISBURSEMENT, INVOICE, COMMISSION) and TRADE_ADVANCE
-- (RECEIVED, ADJUSTMENT). Spec §26 lists six trade-advance transaction types and
-- finance_transactions.ft_type_check allows seven; four of them have no account
-- mapping, so posting one would fail at app.require_account() with "No accounting
-- rule for …". These are the missing four.
--
-- Added as a second seeder rather than by rewriting the 0027 function, so the
-- eighty rows of existing mappings are not duplicated into this file where the
-- two copies could drift. Both are idempotent and neither overwrites a mapping a
-- dealer has repointed deliberately.
--
-- Rollback: drop function app.seed_finance_accounting_rules(uuid); and
--           delete from public.accounting_rules
--            where module = 'TRADE_ADVANCE'
--              and event in ('SETTLEMENT', 'REFUND', 'COMMISSION', 'MANUAL_ADJUSTMENT');
-- =============================================================================

create or replace function app.seed_finance_accounting_rules(p_dealer_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_inserted integer := 0;
begin
  insert into public.accounting_rules (dealer_id, module, event, component, side, account_id, description)
  select p_dealer_id, r.module, r.event, r.component, r.side, c.id, 'Default mapping'
    from (values
      -- Settlement: the finance company pays what it owes. The receivable
      -- clears at gross; commission and deductions they withheld are the
      -- difference between gross and what actually arrived in the bank.
      ('TRADE_ADVANCE', 'SETTLEMENT', 'BANK',               'DEBIT',  '1200'),
      ('TRADE_ADVANCE', 'SETTLEMENT', 'FINANCE_RECEIVABLE', 'CREDIT', '1400'),
      ('TRADE_ADVANCE', 'SETTLEMENT', 'COMMISSION',         'DEBIT',  '5900'),
      ('TRADE_ADVANCE', 'SETTLEMENT', 'DEDUCTION',          'DEBIT',  '5900'),

      -- Refund: unused advance goes back, so the payable the dealer held clears.
      ('TRADE_ADVANCE', 'REFUND', 'FINANCE_PAYABLE', 'DEBIT',  '2600'),
      ('TRADE_ADVANCE', 'REFUND', 'BANK',            'CREDIT', '1200'),

      -- Commission earned but not yet received is receivable, not cash.
      ('TRADE_ADVANCE', 'COMMISSION', 'FINANCE_RECEIVABLE', 'DEBIT',  '1400'),
      ('TRADE_ADVANCE', 'COMMISSION', 'COMMISSION_INCOME',  'CREDIT', '4500'),

      -- A manual correction moves value between the two finance accounts. It
      -- exists because the ledger is append-only: a mistake is corrected by a
      -- further entry, never by editing the original (spec §23).
      ('TRADE_ADVANCE', 'MANUAL_ADJUSTMENT', 'FINANCE_RECEIVABLE', 'DEBIT',  '1400'),
      ('TRADE_ADVANCE', 'MANUAL_ADJUSTMENT', 'FINANCE_PAYABLE',    'CREDIT', '2600')
    ) as r(module, event, component, side, account_code)
    join public.chart_of_accounts c
      on c.dealer_id = p_dealer_id and c.code = r.account_code
   -- Leave an existing mapping alone: a dealer may have repointed it deliberately.
   where not exists (
     select 1 from public.accounting_rules ar
      where ar.dealer_id = p_dealer_id
        and ar.module = r.module and ar.event = r.event and ar.component = r.component
        and ar.branch_id is null
   );

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;

comment on function app.seed_finance_accounting_rules(uuid) is
  'Installs the trade-advance mappings spec §26 needs beyond those in 0027 '
  '(spec §22). Idempotent: customised rules are never overwritten.';

-- Apply to every dealer that already exists.
do $$
declare
  d record;
begin
  for d in select id from public.dealers loop
    perform app.seed_finance_accounting_rules(d.id);
  end loop;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function app.seed_finance_accounting_rules(uuid) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0043_finance_operations.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0043 — Finance operations
-- =============================================================================
-- Spec §25, §26, §27.
--
-- The finance tables have existed since 0021 with no way to write to them: no
-- function creates an application, records a trade advance, or posts a
-- settlement. Everything below is that missing half.
--
-- TWO CONVENTIONS, STATED ONCE AND HELD THROUGHOUT.
--
-- 1. The company side of every posting resolves through
--    app.require_account(… FINANCE_RECEIVABLE / FINANCE_PAYABLE …) and is
--    identified by party_type = 'FINANCE_COMPANY' + party_id.
--    finance_companies.ledger_account_id is NOT used for posting. Using both
--    would split one company's balance across two accounts, and neither would
--    reconcile to the subsidiary ledger.
--
-- 2. finance_transactions is the dealer's net position with a company:
--    **positive means the company owes the dealer.** A credit increases it, a
--    debit reduces it — which is what the BEFORE INSERT trigger in 0021 already
--    computes. balance_after is never written by these functions.
--
-- Also note ft_one_sided_check: exactly one of debit/credit must be strictly
-- positive, so a zero-amount ledger row is impossible and must be skipped rather
-- than written.
--
-- Rollback: drop the six functions below; restore the ft_insert policy and
--           public.record_sale_payment from 0021 and 0028; drop
--           public.finance_settlements.branch_id.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A settlement needs a branch
-- -----------------------------------------------------------------------------
-- journal_entries.branch_id is NOT NULL, and finance_settlements had no branch
-- at all. Backfilled to the head office rather than defaulted at post time, so
-- the branch is a recorded fact rather than a guess made later.
-- -----------------------------------------------------------------------------
alter table public.finance_settlements add column if not exists branch_id uuid;

update public.finance_settlements fs
   set branch_id = (
     select b.id from public.branches b
      where b.dealer_id = fs.dealer_id
      order by b.is_head_office desc, b.code
      limit 1)
 where fs.branch_id is null;

do $$
begin
  if exists (select 1 from public.finance_settlements where branch_id is null) then
    raise notice 'finance_settlements rows without a branch remain; leaving column nullable.';
  else
    execute 'alter table public.finance_settlements alter column branch_id set not null';
  end if;
end;
$$;

alter table public.finance_settlements
  add constraint fs_branch_tenant_fkey
  foreign key (branch_id, dealer_id) references public.branches (id, dealer_id);

-- -----------------------------------------------------------------------------
-- The insert policy has to admit the role that disburses
-- -----------------------------------------------------------------------------
-- ft_insert listed trade_advance.manage, settlements.manage and sales.post but
-- not finance.applications.manage — so disbursing an application, which is
-- exactly what that permission is for, was refused by RLS.
-- -----------------------------------------------------------------------------
drop policy if exists ft_insert on public.finance_transactions;

create policy ft_insert on public.finance_transactions
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and (app.has_permission('finance.trade_advance.manage')
             or app.has_permission('finance.settlements.manage')
             or app.has_permission('finance.applications.manage')
             or app.has_permission('sales.post')))
  );

comment on column public.finance_companies.ledger_account_id is
  'Reporting hint only. Posting resolves accounts through accounting_rules '
  '(spec §22); see 0043.';

-- -----------------------------------------------------------------------------
-- public.create_finance_application() — spec §27
-- -----------------------------------------------------------------------------
-- No journal: an application is a request, not a transaction. Nothing is owed
-- until the finance company approves and disburses.
-- -----------------------------------------------------------------------------
create or replace function public.create_finance_application(
  p_branch_id          uuid,
  p_customer_id        uuid,
  p_finance_company_id uuid,
  p_loan_amount        numeric,
  p_down_payment       numeric default 0,
  p_vehicle_id         uuid default null,
  p_sale_id            uuid default null,
  p_tenure_months      smallint default null,
  p_interest_rate      numeric default null,
  p_commission_amount  numeric default 0,
  p_application_date   date default current_date,
  p_notes              text default null
)
returns table (application_id uuid, application_number text)
language plpgsql
as $$
declare
  v_dealer uuid;
  v_number text;
  v_id     uuid;
begin
  if p_loan_amount <= 0 then
    raise exception 'The loan amount must be greater than zero.' using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  v_number := app.next_document_number(
    v_dealer, p_branch_id, 'FINANCE_APPLICATION',
    app.financial_year_token(v_dealer, p_application_date));

  insert into public.finance_applications
    (dealer_id, branch_id, application_number, application_date, customer_id,
     finance_company_id, vehicle_id, sale_id, loan_amount, down_payment,
     tenure_months, interest_rate, commission_amount, notes, created_by)
  values
    (v_dealer, p_branch_id, v_number, p_application_date, p_customer_id,
     p_finance_company_id, p_vehicle_id, p_sale_id, p_loan_amount, p_down_payment,
     p_tenure_months, p_interest_rate, coalesce(p_commission_amount, 0), p_notes, auth.uid())
  returning id into v_id;

  application_id := v_id; application_number := v_number;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.decide_finance_application() — approve or reject
-- -----------------------------------------------------------------------------
create or replace function public.decide_finance_application(
  p_application_id  uuid,
  p_decision        text,
  p_approved_amount numeric default null,
  p_rejection_reason text default null
)
returns void
language plpgsql
as $$
declare
  v_app public.finance_applications;
begin
  select * into v_app from public.finance_applications where id = p_application_id for update;

  if v_app.id is null then
    raise exception 'Application not found.' using errcode = 'no_data_found';
  end if;
  if v_app.approval_status <> 'PENDING' then
    raise exception 'Application % is already %.', v_app.application_number, v_app.approval_status
      using errcode = 'check_violation';
  end if;
  if p_decision not in ('APPROVED', 'REJECTED', 'CANCELLED') then
    raise exception 'The decision must be APPROVED, REJECTED or CANCELLED.'
      using errcode = 'check_violation';
  end if;

  -- Mirrors fa_approved_amount_check and fa_rejection_check, so the caller gets
  -- a sentence rather than a constraint violation.
  if p_decision = 'APPROVED' and p_approved_amount is null then
    raise exception 'An approval must state the amount approved.'
      using errcode = 'check_violation';
  end if;
  if p_decision = 'REJECTED' and coalesce(btrim(p_rejection_reason), '') = '' then
    raise exception 'A rejection must state a reason.'
      using errcode = 'check_violation';
  end if;

  update public.finance_applications
     set approval_status  = p_decision,
         approved_amount  = case when p_decision = 'APPROVED' then p_approved_amount else approved_amount end,
         approved_at      = case when p_decision = 'APPROVED' then now() else approved_at end,
         rejection_reason = case when p_decision = 'REJECTED' then btrim(p_rejection_reason) else rejection_reason end,
         disbursement_status = case when p_decision in ('REJECTED', 'CANCELLED') then 'CANCELLED'
                                    else disbursement_status end,
         updated_by = auth.uid()
   where id = p_application_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.disburse_finance_application() — spec §27
-- -----------------------------------------------------------------------------
-- Money arrives from the finance company against a vehicle already invoiced, so
-- the finance receivable clears and the bank rises. The bank book gets its row
-- in the same transaction, or the money would be in the ledger and not in the
-- bank book.
-- -----------------------------------------------------------------------------
create or replace function public.disburse_finance_application(
  p_application_id  uuid,
  p_amount          numeric,
  p_bank_account_id uuid,
  p_dd_number       text default null,
  p_bank_reference  text default null,
  p_date            date default current_date
)
-- Two ledger rows are written, so both ids are returned by name. A single
-- "transaction_id" would leave the caller guessing which one it held.
returns table (journal_entry_id uuid, bank_transaction_id bigint, finance_transaction_id bigint)
language plpgsql
as $$
declare
  v_app     public.finance_applications;
  v_bank    public.bank_accounts;
  v_entry   uuid;
  v_txn     bigint;
  v_fin     bigint;
  v_debit   uuid;
  v_credit  uuid;
  v_pending numeric(18, 4);
begin
  if p_amount <= 0 then
    raise exception 'The amount must be greater than zero.' using errcode = 'check_violation';
  end if;

  select * into v_app from public.finance_applications where id = p_application_id for update;
  if v_app.id is null then
    raise exception 'Application not found.' using errcode = 'no_data_found';
  end if;
  if v_app.approval_status <> 'APPROVED' then
    raise exception 'Application % is % — only an approved application can be disbursed.',
      v_app.application_number, v_app.approval_status using errcode = 'check_violation';
  end if;

  v_pending := coalesce(v_app.approved_amount, v_app.loan_amount) - v_app.disbursed_amount;
  if p_amount > v_pending then
    raise exception 'Only % is still to be disbursed on %.', v_pending, v_app.application_number
      using errcode = 'check_violation';
  end if;

  select * into v_bank from public.bank_accounts where id = p_bank_account_id;
  if v_bank.id is null then
    raise exception 'Bank account not found.' using errcode = 'no_data_found';
  end if;

  v_debit  := coalesce(v_bank.ledger_account_id,
                       app.require_account(v_app.dealer_id, 'FINANCE', 'DISBURSEMENT', 'BANK', v_app.branch_id));
  v_credit := app.require_account(v_app.dealer_id, 'FINANCE', 'DISBURSEMENT', 'FINANCE_RECEIVABLE', v_app.branch_id);

  v_entry := app.post_journal(
    v_app.dealer_id, v_app.branch_id, p_date, 'FINANCE',
    'Disbursement against ' || v_app.application_number,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', 'Received from finance company'),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', 'Against ' || v_app.application_number,
                         'party_type', 'FINANCE_COMPANY', 'party_id', v_app.finance_company_id)
    ),
    'FINANCE_APPLICATION', p_application_id,
    'fin-disb:' || p_application_id::text || ':' || p_amount::text || ':' || p_date::text
  );

  -- The bank book and reconciliation must see this like any other credit.
  insert into public.bank_transactions
    (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
     reference_number, journal_entry_id, created_by)
  values
    (v_app.dealer_id, p_bank_account_id, p_date, 'RECEIPT', p_amount,
     'Finance disbursement ' || v_app.application_number,
     coalesce(p_bank_reference, p_dd_number), v_entry, auth.uid())
  returning id into v_txn;

  -- Debit: the company owed the dealer and has now paid, so the position falls.
  insert into public.finance_transactions
    (dealer_id, branch_id, finance_company_id, transaction_date, transaction_type,
     debit, credit, reference_type, reference_id, reference_number, narration,
     application_id, sale_id, journal_entry_id, created_by)
  values
    (v_app.dealer_id, v_app.branch_id, v_app.finance_company_id, p_date, 'DISBURSEMENT',
     p_amount, 0, 'FINANCE_APPLICATION', p_application_id, v_app.application_number,
     'Disbursement received', p_application_id, v_app.sale_id, v_entry, auth.uid())
  returning id into v_fin;

  update public.finance_applications
     set disbursed_amount = disbursed_amount + p_amount,
         disbursed_at = p_date,
         dd_number = coalesce(p_dd_number, dd_number),
         bank_reference = coalesce(p_bank_reference, bank_reference),
         disbursement_status = case
           when disbursed_amount + p_amount >= coalesce(approved_amount, loan_amount) then 'DISBURSED'
           else 'PARTIAL' end,
         updated_by = auth.uid()
   where id = p_application_id;

  journal_entry_id := v_entry; bank_transaction_id := v_txn; finance_transaction_id := v_fin;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_trade_advance() — spec §26
-- -----------------------------------------------------------------------------
-- Six transaction types, each with its own pair of accounts. The mapping is
-- declared here rather than left to the caller so a trade advance cannot be
-- posted to whatever account someone picked in a form.
-- -----------------------------------------------------------------------------
create or replace function public.record_trade_advance(
  p_finance_company_id uuid,
  p_branch_id          uuid,
  p_type               text,
  p_amount             numeric,
  p_bank_account_id    uuid default null,
  p_date               date default current_date,
  p_narration          text default null,
  p_reference          text default null
)
returns table (transaction_id bigint, journal_entry_id uuid)
language plpgsql
as $$
declare
  v_dealer  uuid;
  v_company public.finance_companies;
  v_bank    public.bank_accounts;
  v_bank_acc uuid;
  v_debit   uuid;
  v_credit  uuid;
  v_entry   uuid;
  v_txn     bigint;
  v_debit_amt  numeric(18, 4) := 0;
  v_credit_amt numeric(18, 4) := 0;
  v_narration text;
begin
  -- ft_one_sided_check forbids a zero row, so this is not merely tidiness.
  if p_amount <= 0 then
    raise exception 'The amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_type not in ('ADVANCE_RECEIVED', 'VEHICLE_ADJUSTMENT', 'SETTLEMENT',
                    'REFUND', 'COMMISSION', 'MANUAL_ADJUSTMENT') then
    raise exception 'Unknown trade advance type %.', p_type using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  select * into v_company from public.finance_companies where id = p_finance_company_id;
  if v_company.id is null then
    raise exception 'Finance company not found.' using errcode = 'no_data_found';
  end if;

  if p_bank_account_id is not null then
    select * into v_bank from public.bank_accounts where id = p_bank_account_id;
  end if;

  v_narration := coalesce(p_narration, replace(initcap(replace(p_type, '_', ' ')), ' ', ' ')
                          || ' — ' || v_company.name);

  -- Money in or out needs a bank account; the internal moves do not.
  if p_type in ('ADVANCE_RECEIVED', 'SETTLEMENT', 'REFUND') and v_bank.id is null then
    raise exception 'A % needs the bank account the money moved through.', lower(replace(p_type, '_', ' '))
      using errcode = 'check_violation';
  end if;

  v_bank_acc := v_bank.ledger_account_id;

  if p_type = 'ADVANCE_RECEIVED' then
    -- The company funds the dealer ahead of sales: cash in, liability up.
    v_debit  := coalesce(v_bank_acc, app.require_account(v_dealer, 'TRADE_ADVANCE', 'RECEIVED', 'BANK', p_branch_id));
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'RECEIVED', 'FINANCE_PAYABLE', p_branch_id);
    v_debit_amt := p_amount;          -- the dealer holds their money, so the position falls
  elsif p_type = 'VEHICLE_ADJUSTMENT' then
    -- An advance is consumed by a vehicle the company financed.
    v_debit  := app.require_account(v_dealer, 'TRADE_ADVANCE', 'ADJUSTMENT', 'FINANCE_PAYABLE', p_branch_id);
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'ADJUSTMENT', 'FINANCE_RECEIVABLE', p_branch_id);
    v_credit_amt := p_amount;
  elsif p_type = 'SETTLEMENT' then
    v_debit  := coalesce(v_bank_acc, app.require_account(v_dealer, 'TRADE_ADVANCE', 'SETTLEMENT', 'BANK', p_branch_id));
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'SETTLEMENT', 'FINANCE_RECEIVABLE', p_branch_id);
    v_debit_amt := p_amount;
  elsif p_type = 'REFUND' then
    v_debit  := app.require_account(v_dealer, 'TRADE_ADVANCE', 'REFUND', 'FINANCE_PAYABLE', p_branch_id);
    v_credit := coalesce(v_bank_acc, app.require_account(v_dealer, 'TRADE_ADVANCE', 'REFUND', 'BANK', p_branch_id));
    v_credit_amt := p_amount;
  elsif p_type = 'COMMISSION' then
    v_debit  := app.require_account(v_dealer, 'TRADE_ADVANCE', 'COMMISSION', 'FINANCE_RECEIVABLE', p_branch_id);
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'COMMISSION', 'COMMISSION_INCOME', p_branch_id);
    v_credit_amt := p_amount;         -- earned but unpaid: the company owes more
  else -- MANUAL_ADJUSTMENT
    v_debit  := app.require_account(v_dealer, 'TRADE_ADVANCE', 'MANUAL_ADJUSTMENT', 'FINANCE_RECEIVABLE', p_branch_id);
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'MANUAL_ADJUSTMENT', 'FINANCE_PAYABLE', p_branch_id);
    v_credit_amt := p_amount;
  end if;

  v_entry := app.post_journal(
    v_dealer, p_branch_id, p_date, 'TRADE_ADVANCE', v_narration,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', v_narration,
                         'party_type', 'FINANCE_COMPANY', 'party_id', p_finance_company_id),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', v_narration,
                         'party_type', 'FINANCE_COMPANY', 'party_id', p_finance_company_id)
    ),
    'TRADE_ADVANCE', null, null
  );

  insert into public.finance_transactions
    (dealer_id, branch_id, finance_company_id, transaction_date, transaction_type,
     debit, credit, reference_type, reference_number, narration, journal_entry_id, created_by)
  values
    (v_dealer, p_branch_id, p_finance_company_id, p_date, p_type,
     v_debit_amt, v_credit_amt, 'TRADE_ADVANCE', p_reference, v_narration, v_entry, auth.uid())
  returning id into v_txn;

  -- Money that moved through a bank account belongs in the bank book too.
  if v_bank.id is not null and p_type in ('ADVANCE_RECEIVED', 'SETTLEMENT', 'REFUND') then
    insert into public.bank_transactions
      (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
       reference_number, journal_entry_id, created_by)
    values
      (v_dealer, p_bank_account_id, p_date,
       case when p_type = 'REFUND' then 'PAYMENT' else 'RECEIPT' end,
       p_amount, v_narration, p_reference, v_entry, auth.uid());
  end if;

  transaction_id := v_txn; journal_entry_id := v_entry;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.create_finance_settlement() / post_finance_settlement() — spec §26
-- -----------------------------------------------------------------------------
create or replace function public.create_finance_settlement(
  p_finance_company_id uuid,
  p_branch_id          uuid,
  p_from               date,
  p_to                 date,
  p_gross              numeric,
  p_commission         numeric default 0,
  p_deductions         numeric default 0,
  p_settlement_date    date default current_date,
  p_notes              text default null
)
returns table (settlement_id uuid, settlement_number text)
language plpgsql
as $$
declare
  v_dealer uuid;
  v_number text;
  v_id     uuid;
begin
  if p_gross <= 0 then
    raise exception 'The gross amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if coalesce(p_commission, 0) + coalesce(p_deductions, 0) > p_gross then
    raise exception 'Commission and deductions cannot exceed the gross amount.'
      using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  v_number := app.next_document_number(
    v_dealer, p_branch_id, 'FINANCE_SETTLEMENT',
    app.financial_year_token(v_dealer, p_settlement_date));

  insert into public.finance_settlements
    (dealer_id, branch_id, finance_company_id, settlement_number, settlement_date,
     from_date, to_date, gross_amount, commission_amount, deductions, notes, created_by)
  values
    (v_dealer, p_branch_id, p_finance_company_id, v_number, p_settlement_date,
     p_from, p_to, p_gross, coalesce(p_commission, 0), coalesce(p_deductions, 0),
     p_notes, auth.uid())
  returning id into v_id;

  settlement_id := v_id; settlement_number := v_number;
  return next;
end;
$$;

create or replace function public.post_finance_settlement(
  p_settlement_id   uuid,
  p_bank_account_id uuid
)
returns uuid
language plpgsql
as $$
declare
  v_s      public.finance_settlements;
  v_bank   public.bank_accounts;
  v_lines  jsonb;
  v_entry  uuid;
  v_bank_acc uuid;
begin
  select * into v_s from public.finance_settlements where id = p_settlement_id for update;
  if v_s.id is null then
    raise exception 'Settlement not found.' using errcode = 'no_data_found';
  end if;
  if v_s.status <> 'DRAFT' then
    raise exception 'Settlement % is % and cannot be posted again.', v_s.settlement_number, v_s.status
      using errcode = 'check_violation';
  end if;

  select * into v_bank from public.bank_accounts where id = p_bank_account_id;
  if v_bank.id is null then
    raise exception 'Bank account not found.' using errcode = 'no_data_found';
  end if;

  v_bank_acc := coalesce(v_bank.ledger_account_id,
                         app.require_account(v_s.dealer_id, 'TRADE_ADVANCE', 'SETTLEMENT', 'BANK', v_s.branch_id));

  -- The receivable clears at gross; what the company withheld is the difference
  -- between gross and what reached the bank. A zero commission or deduction adds
  -- no line: an empty line is noise in the journal and would be rejected as a
  -- finance_transactions row.
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_bank_acc, 'debit', v_s.net_amount, 'credit', 0,
                       'narration', 'Settlement ' || v_s.settlement_number)
  );

  if v_s.commission_amount > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', app.require_account(v_s.dealer_id, 'TRADE_ADVANCE', 'SETTLEMENT', 'COMMISSION', v_s.branch_id),
      'debit', v_s.commission_amount, 'credit', 0, 'narration', 'Commission withheld'));
  end if;

  if v_s.deductions > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', app.require_account(v_s.dealer_id, 'TRADE_ADVANCE', 'SETTLEMENT', 'DEDUCTION', v_s.branch_id),
      'debit', v_s.deductions, 'credit', 0, 'narration', 'Deductions'));
  end if;

  v_lines := v_lines || jsonb_build_array(jsonb_build_object(
    'account_id', app.require_account(v_s.dealer_id, 'TRADE_ADVANCE', 'SETTLEMENT', 'FINANCE_RECEIVABLE', v_s.branch_id),
    'debit', 0, 'credit', v_s.gross_amount, 'narration', 'Settled ' || v_s.settlement_number,
    'party_type', 'FINANCE_COMPANY', 'party_id', v_s.finance_company_id));

  v_entry := app.post_journal(
    v_s.dealer_id, v_s.branch_id, v_s.settlement_date, 'TRADE_ADVANCE',
    'Settlement ' || v_s.settlement_number, v_lines,
    'FINANCE_SETTLEMENT', p_settlement_id, 'fin-settle:' || p_settlement_id::text
  );

  insert into public.finance_transactions
    (dealer_id, branch_id, finance_company_id, transaction_date, transaction_type,
     debit, credit, reference_type, reference_id, reference_number, narration,
     journal_entry_id, created_by)
  values
    (v_s.dealer_id, v_s.branch_id, v_s.finance_company_id, v_s.settlement_date, 'SETTLEMENT',
     v_s.gross_amount, 0, 'FINANCE_SETTLEMENT', p_settlement_id, v_s.settlement_number,
     'Settlement posted', v_entry, auth.uid());

  insert into public.bank_transactions
    (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
     reference_number, journal_entry_id, created_by)
  values
    (v_s.dealer_id, p_bank_account_id, v_s.settlement_date, 'RECEIPT', v_s.net_amount,
     'Settlement ' || v_s.settlement_number, v_s.settlement_number, v_entry, auth.uid());

  update public.finance_settlements
     set status = 'POSTED', journal_entry_id = v_entry
   where id = p_settlement_id;

  return v_entry;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.create_finance_application(uuid, uuid, uuid, numeric, numeric, uuid, uuid, smallint, numeric, numeric, date, text) to authenticated';
    execute 'grant execute on function public.decide_finance_application(uuid, text, numeric, text) to authenticated';
    execute 'grant execute on function public.disburse_finance_application(uuid, numeric, uuid, text, text, date) to authenticated';
    execute 'grant execute on function public.record_trade_advance(uuid, uuid, text, numeric, uuid, date, text, text) to authenticated';
    execute 'grant execute on function public.create_finance_settlement(uuid, uuid, date, date, numeric, numeric, numeric, date, text) to authenticated';
    execute 'grant execute on function public.post_finance_settlement(uuid, uuid) to authenticated';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_sale_payment() — name the finance company on the receivable
-- -----------------------------------------------------------------------------
-- A sale settled by finance debits Finance Receivable, but the line carried no
-- party, so account 1400 held a total with no subsidiary detail behind it and
-- the company ledger could not see money owed against its own vehicles.
--
-- Only the party tagging and the VEHICLE_ADJUSTMENT row are new; the body is
-- otherwise 0028's. The numbering is untouched because 0039 fixed scope inside
-- app.next_document_number() rather than at each call site, so there is no
-- earlier fix here to carry forward.
-- -----------------------------------------------------------------------------
create or replace function public.record_sale_payment(
  p_sale_id      uuid,
  p_amount       numeric,
  p_payment_mode text,
  p_reference    text default null,
  p_finance_company_id uuid default null
)
returns table (receipt_number text, journal_entry_id uuid)
language plpgsql
as $$
declare
  v_sale     public.sales;
  v_year     text;
  v_rnumber  text;
  v_entry    uuid;
  v_debit    uuid;
  v_credit   uuid;
  v_component text;
  v_party    text;
  v_party_id uuid;
begin
  if p_amount <= 0 then
    raise exception 'The payment amount must be greater than zero.' using errcode = 'check_violation';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;
  if v_sale.id is null then
    raise exception 'Sale not found.' using errcode = 'no_data_found';
  end if;
  if v_sale.status not in ('POSTED', 'DELIVERED') then
    raise exception 'Payments can only be recorded against a posted invoice; this one is %.', v_sale.status
      using errcode = 'check_violation';
  end if;

  v_year := app.financial_year_token(v_sale.dealer_id, current_date);
  v_rnumber := app.next_document_number(v_sale.dealer_id, v_sale.branch_id, 'RECEIPT', v_year);

  -- Finance disbursement moves the debt to the finance company rather than
  -- settling it in cash (spec §27).
  if p_payment_mode = 'FINANCE' then
    if p_finance_company_id is null then
      raise exception 'A finance payment must name the finance company carrying the debt.'
        using errcode = 'check_violation';
    end if;
    v_component := 'FINANCE_RECEIVABLE';
    v_debit  := app.require_account(v_sale.dealer_id, 'FINANCE', 'INVOICE', 'FINANCE_RECEIVABLE', v_sale.branch_id);
    v_party := 'FINANCE_COMPANY';
    v_party_id := p_finance_company_id;
  else
    v_component := case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end;
    v_debit := app.require_account(
      v_sale.dealer_id,
      case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
      'RECEIPT', v_component, v_sale.branch_id);
  end if;

  v_credit := app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'RECEIVABLE', v_sale.branch_id);

  v_entry := app.post_journal(
    v_sale.dealer_id, v_sale.branch_id, current_date,
    case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
    'Receipt ' || v_rnumber || ' against ' || v_sale.invoice_number,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', p_payment_mode || ' received',
                         'party_type', v_party, 'party_id', v_party_id),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', 'Against ' || v_sale.invoice_number,
                         'party_type', 'CUSTOMER', 'party_id', v_sale.customer_id)
    ),
    'SALE_PAYMENT', p_sale_id, 'receipt:' || v_rnumber
  );

  insert into public.sale_payments
    (dealer_id, sale_id, receipt_number, amount, payment_mode, reference,
     finance_company_id, journal_entry_id, created_by)
  values
    (v_sale.dealer_id, p_sale_id, v_rnumber, p_amount, p_payment_mode, p_reference,
     p_finance_company_id, v_entry, auth.uid());

  -- The company now owes the dealer for this vehicle, so its position rises.
  if p_payment_mode = 'FINANCE' then
    insert into public.finance_transactions
      (dealer_id, branch_id, finance_company_id, transaction_date, transaction_type,
       debit, credit, reference_type, reference_id, reference_number, narration,
       sale_id, journal_entry_id, created_by)
    values
      (v_sale.dealer_id, v_sale.branch_id, p_finance_company_id, current_date, 'VEHICLE_ADJUSTMENT',
       0, p_amount, 'SALE', p_sale_id, v_sale.invoice_number,
       'Financed ' || v_sale.invoice_number, p_sale_id, v_entry, auth.uid());
  end if;

  receipt_number := v_rnumber; journal_entry_id := v_entry;
  return next;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0044_price_approval_workflow.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0044 — Price approval workflow
-- =============================================================================
-- Spec §15, §17, §60.9.
--
-- 0018 built a price version for an approval workflow it never got: the status
-- check allows DRAFT → SUBMITTED → APPROVED → ACTIVE, the table carries
-- submitted_at/submitted_by/approved_at/approved_by, and the permission
-- `vehicles.pricing.approve` exists — but nothing ever moves a version between
-- those states. createPriceVersion inserts ACTIVE with the approval stamps
-- pre-filled, so a price goes live the moment one person saves it. Spec §15 asks
-- for DRAFT → SUBMITTED → APPROVED → ACTIVE precisely because a price change is
-- what every future invoice is computed from.
--
-- Two things are fixed here:
--
-- 1. `masters.pricing.manage` granted no database access at all. The Masters
--    screen is gated on it, so a user holding only that permission passed the
--    page check and then saw nothing, because the RLS on this table knows only
--    `vehicles.pricing.*`. The policies now recognise both.
--
-- 2. public.decide_price_version() moves a version through the workflow, and is
--    the only way a price goes live. Activation supersedes the incumbent in the
--    same statement, because vpv_active_scope_key permits exactly one ACTIVE
--    price per scope.
--
-- Rollback: restore the three policies from 0018 and drop
--           public.decide_price_version(uuid, text, text).
-- =============================================================================

drop policy if exists vpv_select on public.vehicle_price_versions;
drop policy if exists vpv_insert on public.vehicle_price_versions;
drop policy if exists vpv_update on public.vehicle_price_versions;

create policy vpv_select on public.vehicle_price_versions for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('vehicles.pricing.view')
                  or app.has_permission('masters.pricing.manage'))));

create policy vpv_insert on public.vehicle_price_versions for insert to authenticated
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('vehicles.pricing.manage')
                  or app.has_permission('masters.pricing.manage'))));

create policy vpv_update on public.vehicle_price_versions for update to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('vehicles.pricing.manage')
                  or app.has_permission('vehicles.pricing.approve')
                  or app.has_permission('masters.pricing.manage'))))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('vehicles.pricing.manage')
                  or app.has_permission('vehicles.pricing.approve')
                  or app.has_permission('masters.pricing.manage'))));

-- -----------------------------------------------------------------------------
-- public.decide_price_version() — spec §15
-- -----------------------------------------------------------------------------
create or replace function public.decide_price_version(
  p_version_id uuid,
  p_action     text,
  p_reason     text default null
)
returns text
language plpgsql
as $$
declare
  v_v      public.vehicle_price_versions;
  v_status text;
begin
  select * into v_v from public.vehicle_price_versions where id = p_version_id for update;

  if v_v.id is null then
    raise exception 'Price version not found.' using errcode = 'no_data_found';
  end if;
  if p_action not in ('SUBMIT', 'APPROVE', 'REJECT', 'ACTIVATE') then
    raise exception 'Unknown action %.', p_action using errcode = 'check_violation';
  end if;

  if p_action = 'SUBMIT' then
    if v_v.status <> 'DRAFT' then
      raise exception 'Only a draft can be submitted; version % is %.', v_v.version_number, v_v.status
        using errcode = 'check_violation';
    end if;
    update public.vehicle_price_versions
       set status = 'SUBMITTED', submitted_at = now(), submitted_by = auth.uid()
     where id = p_version_id;
    v_status := 'SUBMITTED';

  elsif p_action = 'APPROVE' then
    if v_v.status <> 'SUBMITTED' then
      raise exception 'Only a submitted price can be approved; version % is %.',
        v_v.version_number, v_v.status using errcode = 'check_violation';
    end if;
    -- A price one person can write, submit and approve alone is not reviewed at
    -- all, and DEALER_OWNER holds both permissions.
    if v_v.submitted_by is not null and v_v.submitted_by = auth.uid() then
      raise exception 'A price must be approved by someone other than the person who submitted it.'
        using errcode = 'insufficient_privilege',
              hint = 'Spec §15: the approval step exists to be a second pair of eyes.';
    end if;
    update public.vehicle_price_versions
       set status = 'APPROVED', approved_at = now(), approved_by = auth.uid()
     where id = p_version_id;
    v_status := 'APPROVED';

  elsif p_action = 'REJECT' then
    if v_v.status <> 'SUBMITTED' then
      raise exception 'Only a submitted price can be rejected; version % is %.',
        v_v.version_number, v_v.status using errcode = 'check_violation';
    end if;
    if coalesce(btrim(p_reason), '') = '' then
      raise exception 'A rejection must say why.'
        using errcode = 'check_violation',
              hint = 'Spec §15: the reason is what makes the rejection reviewable.';
    end if;
    update public.vehicle_price_versions
       set status = 'REJECTED',
           notes = coalesce(notes || E'\n', '') || 'Rejected: ' || btrim(p_reason)
     where id = p_version_id;
    v_status := 'REJECTED';

  else -- ACTIVATE
    if v_v.status <> 'APPROVED' then
      raise exception 'Only an approved price can go live; version % is %.',
        v_v.version_number, v_v.status using errcode = 'check_violation';
    end if;

    -- Supersede the incumbent first: vpv_active_scope_key allows exactly one
    -- ACTIVE row per (dealer, model, variant, branch), so activating before
    -- retiring the old one would violate it.
    update public.vehicle_price_versions
       set status = 'SUPERSEDED',
           effective_to = v_v.effective_from - 1
     where dealer_id = v_v.dealer_id
       and model_id = v_v.model_id
       and coalesce(variant_id, '00000000-0000-0000-0000-000000000000'::uuid)
             = coalesce(v_v.variant_id, '00000000-0000-0000-0000-000000000000'::uuid)
       and coalesce(branch_id, '00000000-0000-0000-0000-000000000000'::uuid)
             = coalesce(v_v.branch_id, '00000000-0000-0000-0000-000000000000'::uuid)
       and status = 'ACTIVE'
       and id <> p_version_id;

    update public.vehicle_price_versions set status = 'ACTIVE' where id = p_version_id;
    v_status := 'ACTIVE';
  end if;

  return v_status;
end;
$$;

comment on function public.decide_price_version(uuid, text, text) is
  'Moves a price version through DRAFT → SUBMITTED → APPROVED → ACTIVE (spec §15). '
  'The only way a price goes live; activation supersedes the incumbent.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.decide_price_version(uuid, text, text) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0045_customer_vehicle_writer.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0045 — Somebody has to write customer_vehicles
-- =============================================================================
-- Spec §11, §32, §33.
--
-- customer_vehicles has existed since 0023 with no writer anywhere in the
-- codebase: job cards carry a free-text registration and never link to it, and
-- delivery never records that a customer now owns the unit. The table has always
-- been empty, so "which vehicles does this customer own" and "what is this
-- vehicle's service history" could not be answered at all.
--
-- Two writers, at the two moments ownership becomes a fact:
--   * delivery — the dealer sold it, so everything about it is known;
--   * a job card for a walk-in — the dealer did not sell it, but the workshop
--     now knows the registration, so the record starts from there.
--
-- Rollback: restore public.deliver_vehicle() from 0038 and public.create_job_card()
--           from 0033, drop index cv_vehicle_key, restore policy cv_write from
--           0023, and drop public.customer_service_summary(uuid, uuid).
-- =============================================================================

-- A vehicle has one current owner. Needed as an ON CONFLICT target, and it makes
-- a resold unit update to the new owner rather than accumulate rows.
create unique index if not exists cv_vehicle_key
  on public.customer_vehicles (vehicle_id) where vehicle_id is not null;

-- -----------------------------------------------------------------------------
-- The writer needs to be allowed to write
-- -----------------------------------------------------------------------------
-- cv_write is FOR ALL, so its USING clause governs the UPDATE half of an upsert.
-- It admitted customers.edit and service.jobcards.create — neither of which a
-- delivery clerk holds — so re-delivering a unit to a new owner would fail on
-- the conflict path while a first delivery succeeded. Adding sales.deliver makes
-- both work.
-- -----------------------------------------------------------------------------
drop policy if exists cv_write on public.customer_vehicles;

create policy cv_write on public.customer_vehicles for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('customers.edit')
                  or app.has_permission('service.jobcards.create')
                  or app.has_permission('sales.deliver'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

-- -----------------------------------------------------------------------------
-- public.deliver_vehicle() — spec §19, now recording ownership
-- -----------------------------------------------------------------------------
create or replace function public.deliver_vehicle(
  p_sale_id      uuid,
  p_received_by  text default null,
  p_odometer     numeric default null,
  p_remarks      text default null
)
returns text
language plpgsql
as $$
declare
  v_sale    public.sales;
  v_year    text;
  v_number  text;
begin
  select * into v_sale from public.sales where id = p_sale_id for update;

  if v_sale.id is null then
    raise exception 'Sale not found.' using errcode = 'no_data_found';
  end if;
  if v_sale.status <> 'POSTED' then
    raise exception 'Only a POSTED sale can be delivered; this one is %.', v_sale.status
      using errcode = 'check_violation';
  end if;

  v_year := app.financial_year_token(v_sale.dealer_id, current_date);
  v_number := app.next_document_number(v_sale.dealer_id, null, 'DELIVERY', v_year);

  insert into public.deliveries
    (dealer_id, branch_id, sale_id, vehicle_id, delivery_number,
     delivered_by, received_by_name, odometer, remarks)
  values
    (v_sale.dealer_id, v_sale.branch_id, p_sale_id, v_sale.vehicle_id, v_number,
     auth.uid(), p_received_by, p_odometer, p_remarks);

  -- The customer now owns this unit. Recorded here because delivery is the
  -- moment it becomes true, and everything needed is already known.
  insert into public.customer_vehicles
    (dealer_id, customer_id, vehicle_id, model_id, variant_id,
     chassis_no, engine_no, registration_no, purchase_date, status)
  select v_sale.dealer_id, v_sale.customer_id, v.id, v.model_id, v.variant_id,
         v.chassis_no, v.engine_no, v.registration_no, current_date, 'ACTIVE'
    from public.vehicles v
   where v.id = v_sale.vehicle_id
  on conflict (vehicle_id) where vehicle_id is not null
  do update set customer_id = excluded.customer_id,
                registration_no = coalesce(excluded.registration_no, public.customer_vehicles.registration_no),
                status = 'ACTIVE',
                updated_at = now();

  update public.vehicles set status = 'DELIVERED', updated_by = auth.uid()
   where id = v_sale.vehicle_id;

  update public.sales set status = 'DELIVERED', delivered_by = auth.uid()
   where id = p_sale_id;

  return v_number;
end;
$$;

comment on function public.deliver_vehicle(uuid, text, numeric, text) is
  'Records the handover, closes the sale and registers the customer as the '
  'vehicle''s owner (spec §19, §11).';

-- -----------------------------------------------------------------------------
-- public.create_job_card() — spec §32, now linking the vehicle
-- -----------------------------------------------------------------------------
create or replace function public.create_job_card(
  p_branch_id       uuid,
  p_customer_id     uuid,
  p_service_type    text default 'PAID',
  p_registration_no text default null,
  p_odometer        numeric default null,
  p_complaint       text default null,
  p_customer_vehicle_id uuid default null,
  p_service_advisor_id  uuid default null,
  p_technician_id       uuid default null,
  p_promised_at     timestamptz default null,
  p_job_date        date default current_date
)
returns table (job_card_id uuid, job_card_number text)
language plpgsql
as $$
declare
  v_dealer uuid;
  v_number text;
  v_id     uuid;
  v_reg    text;
  v_cv     uuid := p_customer_vehicle_id;
begin
  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  v_number := app.next_document_number(
    v_dealer, p_branch_id, 'JOB_CARD', app.financial_year_token(v_dealer, p_job_date));

  v_reg := nullif(upper(btrim(p_registration_no)), '');

  -- A walk-in the dealer never sold still has a vehicle, and the workshop now
  -- knows its registration. Registering it here is what lets the second visit
  -- find the first. cv_registration_key is partial, so ON CONFLICT has to repeat
  -- its predicate or Postgres will not match the index.
  if v_cv is null and v_reg is not null then
    insert into public.customer_vehicles
      (dealer_id, customer_id, registration_no, status)
    values (v_dealer, p_customer_id, v_reg, 'ACTIVE')
    on conflict (dealer_id, registration_no) where registration_no is not null
    do update set customer_id = excluded.customer_id, updated_at = now()
    returning id into v_cv;
  end if;

  insert into public.job_cards
    (dealer_id, branch_id, job_card_number, job_date, customer_id, customer_vehicle_id,
     registration_no, odometer, service_type, complaint, service_advisor_id, technician_id,
     promised_at, created_by)
  values
    (v_dealer, p_branch_id, v_number, p_job_date, p_customer_id, v_cv,
     v_reg, p_odometer, p_service_type, p_complaint,
     p_service_advisor_id, p_technician_id, p_promised_at, auth.uid())
  returning id into v_id;

  job_card_id := v_id; job_card_number := v_number;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.customer_service_summary() — spec §33
-- -----------------------------------------------------------------------------
-- A rollup per customer, not per visit. /service/history already answers "what
-- happened on this job"; the question this answers is "who has stopped coming,
-- and who is worth the most", which no per-visit list makes visible.
-- -----------------------------------------------------------------------------
create or replace function public.customer_service_summary(
  p_customer_id uuid default null,
  p_branch_id   uuid default null
)
returns table (
  customer_id     uuid,
  customer_code   text,
  customer_name   text,
  mobile          text,
  vehicle_count   int,
  visit_count     int,
  first_visit     date,
  last_visit      date,
  days_since_last int,
  lifetime_value  numeric(18, 4),
  open_jobs       int
)
language sql
stable
as $$
  select c.id, c.customer_code, c.name, c.mobile,
         (select count(*)::int from public.customer_vehicles cv
           where cv.customer_id = c.id and cv.status = 'ACTIVE'),
         count(distinct j.id)::int,
         min(j.job_date),
         max(j.job_date),
         (current_date - max(j.job_date))::int,
         coalesce(sum(i.total_amount), 0)::numeric(18, 4),
         count(distinct j.id) filter (where j.status in ('OPEN', 'IN_PROGRESS', 'READY'))::int
    from public.customers c
    join public.job_cards j on j.customer_id = c.id
    left join public.service_invoices i
      on i.job_card_id = j.id and i.status <> 'CANCELLED'
   where (p_customer_id is null or c.id = p_customer_id)
     and (p_branch_id is null or j.branch_id = p_branch_id)
   group by c.id, c.customer_code, c.name, c.mobile
   order by max(j.job_date) desc;
$$;

comment on function public.customer_service_summary(uuid, uuid) is
  'Per-customer service rollup (spec §33): visits, lifetime value and how long '
  'since the last one, for spotting customers who have stopped coming.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.customer_service_summary(uuid, uuid) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0046_booking_advances.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0046 — Booking advances: applied on sale, refundable on cancellation
-- =============================================================================
-- Spec §18, §23, §41.
--
-- 0027 seeded BOOKING/APPLY/CUSTOMER_ADVANCE and BOOKING/APPLY/RECEIVABLE, and
-- nothing has ever invoked them. Converting a booking marks it CONVERTED and
-- stops there, so account 2100 (Customer Advances) accumulates every advance the
-- dealer has ever taken and releases none of them. The liability grows forever
-- and the customer's receivable is overstated by the advance they already paid.
--
-- Two functions close that:
--   * app.apply_booking_advance() releases the advance when the sale posts;
--   * public.refund_booking_advance() returns it when a booking is cancelled.
--
-- REFUND IS NOT AUTOMATIC ON CANCELLATION, deliberately. A cancelled booking's
-- advance is often retained as a forfeit, and auto-refunding would post money
-- the dealer never paid. It is a separate act, separately permitted.
--
-- Existing data keeps its stale 2100 balance: this releases advances from here
-- on, and back-posting entries for historical bookings would put journals into
-- closed periods. /bookings/advances shows the control balance alongside the
-- derived figure so the difference is visible rather than papered over.
--
-- Rollback: drop trigger sales_apply_advance on public.sales, then drop
--           app.sales_apply_advance(), app.apply_booking_advance(uuid) and
--           public.refund_booking_advance(uuid, numeric, text, text, uuid, uuid, date).
--           post_vehicle_sale() is untouched by this migration.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- app.apply_booking_advance() — spec §18
-- -----------------------------------------------------------------------------
-- Dr Customer Advances / Cr Customer Receivable: the money the customer already
-- paid stops being a liability and settles part of what they now owe. Both lines
-- carry the customer, so their ledger shows the advance being used.
--
-- Idempotent on the sale, so posting twice applies once.
-- -----------------------------------------------------------------------------
create or replace function app.apply_booking_advance(p_sale_id uuid)
returns uuid
language plpgsql
as $$
declare
  v_sale    public.sales;
  v_advance numeric(18, 4);
  v_apply   numeric(18, 4);
  v_debit   uuid;
  v_credit  uuid;
begin
  select * into v_sale from public.sales where id = p_sale_id;

  if v_sale.id is null or v_sale.booking_id is null then
    return null;  -- a walk-in sale has no advance to release
  end if;

  select coalesce(sum(amount), 0) into v_advance
    from public.booking_payments
   where booking_id = v_sale.booking_id and status = 'RECEIVED';

  if v_advance <= 0 then
    return null;
  end if;

  -- Never release more than the invoice is worth: the remainder stays a
  -- liability until it is refunded or applied elsewhere.
  v_apply := least(v_advance, v_sale.total_amount);

  v_debit  := app.require_account(v_sale.dealer_id, 'BOOKING', 'APPLY', 'CUSTOMER_ADVANCE', v_sale.branch_id);
  v_credit := app.require_account(v_sale.dealer_id, 'BOOKING', 'APPLY', 'RECEIVABLE', v_sale.branch_id);

  return app.post_journal(
    v_sale.dealer_id, v_sale.branch_id, v_sale.invoice_date, 'BOOKING',
    'Advance applied to ' || v_sale.invoice_number,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', v_apply, 'credit', 0,
                         'narration', 'Advance applied',
                         'party_type', 'CUSTOMER', 'party_id', v_sale.customer_id),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', v_apply,
                         'narration', 'Against ' || v_sale.invoice_number,
                         'party_type', 'CUSTOMER', 'party_id', v_sale.customer_id)
    ),
    'BOOKING_APPLY', p_sale_id, 'booking-apply:' || p_sale_id::text
  );
end;
$$;

comment on function app.apply_booking_advance(uuid) is
  'Releases a booking advance from Customer Advances against the invoice it was '
  'taken for (spec §18). Idempotent on the sale.';

-- -----------------------------------------------------------------------------
-- The advance is released when the sale posts
-- -----------------------------------------------------------------------------
-- A trigger rather than a change to post_vehicle_sale(). Rewriting that function
-- here would mean copying its hundred-line body into this migration, where the
-- copy would have to be kept in step with the original by hand forever. It also
-- means the release happens however a sale reaches POSTED, not only down the one
-- code path — the same reasoning as app.vehicles_log_movement() in 0017.
--
-- AFTER UPDATE, so the sale journal already exists and both entries land in the
-- same transaction.
-- -----------------------------------------------------------------------------
create or replace function app.sales_apply_advance()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'POSTED' and old.status is distinct from 'POSTED' then
    perform app.apply_booking_advance(new.id);
  end if;
  return null;
end;
$$;

create trigger sales_apply_advance
  after update on public.sales
  for each row execute function app.sales_apply_advance();

-- -----------------------------------------------------------------------------
-- public.refund_booking_advance() — spec §18, §23
-- -----------------------------------------------------------------------------
create or replace function public.refund_booking_advance(
  p_booking_id      uuid,
  p_amount          numeric,
  p_mode            text,
  p_reason          text,
  p_cash_branch_id  uuid default null,
  p_bank_account_id uuid default null,
  p_date            date default current_date
)
returns table (journal_entry_id uuid)
language plpgsql
as $$
declare
  v_b        public.bookings;
  v_received numeric(18, 4);
  v_debit    uuid;
  v_credit   uuid;
  v_entry    uuid;
  v_bank     public.bank_accounts;
  v_cash     public.cash_accounts;
  v_branch   uuid;
begin
  if p_amount <= 0 then
    raise exception 'The refund must be greater than zero.' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'A refund must say why.'
      using errcode = 'check_violation',
            hint = 'Spec §23: the reason is part of the record, not optional.';
  end if;

  select * into v_b from public.bookings where id = p_booking_id for update;
  if v_b.id is null then
    raise exception 'Booking not found.' using errcode = 'no_data_found';
  end if;

  -- Only a cancelled booking. A refund against a live booking would leave the
  -- customer with a reservation they have not paid for.
  if v_b.status <> 'CANCELLED' then
    raise exception 'Booking % is % — cancel it before refunding the advance.',
      v_b.booking_number, v_b.status using errcode = 'check_violation';
  end if;

  select coalesce(sum(amount), 0) into v_received
    from public.booking_payments
   where booking_id = p_booking_id and status = 'RECEIVED';

  if p_amount > v_received then
    raise exception 'Only % was received against %.', v_received, v_b.booking_number
      using errcode = 'check_violation';
  end if;

  v_debit := app.require_account(v_b.dealer_id, 'BOOKING', 'APPLY', 'CUSTOMER_ADVANCE', v_b.branch_id);

  if p_mode = 'CASH' then
    v_branch := coalesce(p_cash_branch_id, v_b.branch_id);
    select * into v_cash from public.cash_accounts where branch_id = v_branch;
    if v_cash.id is null then
      raise exception 'That branch has no cash account.' using errcode = 'no_data_found';
    end if;
    v_credit := v_cash.ledger_account_id;
    -- The day guard applies: a closed day cannot take a payment (spec §36).
    perform public.ensure_cash_day(v_branch, p_date);
  else
    select * into v_bank from public.bank_accounts where id = p_bank_account_id;
    if v_bank.id is null then
      raise exception 'Choose the bank account the refund was paid from.'
        using errcode = 'no_data_found';
    end if;
    v_branch := coalesce(v_bank.branch_id, v_b.branch_id);
    v_credit := v_bank.ledger_account_id;
  end if;

  v_entry := app.post_journal(
    v_b.dealer_id, v_branch, p_date, 'BOOKING',
    'Advance refunded on ' || v_b.booking_number,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', btrim(p_reason),
                         'party_type', 'CUSTOMER', 'party_id', v_b.customer_id),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', 'Refund of booking advance')
    ),
    'BOOKING_REFUND', p_booking_id, 'booking-refund:' || p_booking_id::text || ':' || p_amount::text
  );

  if p_mode = 'CASH' then
    insert into public.cash_transactions
      (dealer_id, branch_id, cash_account_id, business_date, direction, amount,
       particular, customer_id, journal_entry_id, created_by)
    values
      (v_b.dealer_id, v_branch, v_cash.id, p_date, 'PAYMENT', p_amount,
       'Advance refund ' || v_b.booking_number, v_b.customer_id, v_entry, auth.uid());
  else
    insert into public.bank_transactions
      (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
       customer_id, journal_entry_id, created_by)
    values
      (v_b.dealer_id, p_bank_account_id, p_date, 'PAYMENT', p_amount,
       'Advance refund ' || v_b.booking_number, v_b.customer_id, v_entry, auth.uid());
  end if;

  -- Reversing the receipts is what makes bookings.received_amount fall: the
  -- trigger in 0020 recomputes it from the RECEIVED rows.
  update public.booking_payments
     set status = 'REVERSED'
   where booking_id = p_booking_id and status = 'RECEIVED';

  journal_entry_id := v_entry;
  return next;
end;
$$;

comment on function public.refund_booking_advance(uuid, numeric, text, text, uuid, uuid, date) is
  'Returns a cancelled booking''s advance, clearing the liability and writing the '
  'cash or bank payment (spec §18, §23). Never automatic: an advance is often forfeit.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.refund_booking_advance(uuid, numeric, text, text, uuid, uuid, date) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0047_counter_sales.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0047 — Counter sales
-- =============================================================================
-- Spec §33.
--
-- The last module of the specification with no implementation. Everything around
-- it has been in place since 0023: service_invoices.invoice_type accepts
-- 'COUNTER', si_job_card_check requires such an invoice to have no job card, the
-- COUNTER_INVOICE sequence is seeded, and inventory.counter_sale.create exists.
-- What was missing is the one function that starts the invoice — so the sequence
-- and the permission have never been used by anything.
--
-- Almost nothing new is needed, because a counter sale IS a service invoice
-- without a job card:
--   * add_service_line() already allocates stock LOCAL-before-COMPANY and
--     refuses to oversell (spec §31, §33);
--   * post_service_invoice() already posts revenue, GST, COGS and stock relief,
--     and already guards its job-card update with `if job_card_id is not null`,
--     so it works here unchanged;
--   * record_service_payment() already collects against it.
--
-- Reusing them is the point: a second billing engine for counter sales would be
-- a second place for the accounting to be wrong (spec §60.18).
--
-- Rollback: drop function public.create_counter_invoice(uuid, uuid, date); restore
--           policies si_write and sl_write from 0023; delete the
--           counter_sale.require_customer setting.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.create_counter_invoice() — spec §33
-- -----------------------------------------------------------------------------
-- The customer is optional by configuration. A walk-in buying a helmet for cash
-- is not worth a customer record, but a dealer who wants every sale attributable
-- turns the setting on and the invoice refuses to start without one.
-- -----------------------------------------------------------------------------
create or replace function public.create_counter_invoice(
  p_branch_id    uuid,
  p_customer_id  uuid default null,
  p_invoice_date date default current_date
)
returns table (invoice_id uuid, invoice_number text)
language plpgsql
as $$
declare
  v_dealer   uuid;
  v_number   text;
  v_id       uuid;
  v_required boolean;
begin
  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  select coalesce((value)::text = 'true', false) into v_required
    from public.system_settings
   where key = 'counter_sale.require_customer'
     and (dealer_id = v_dealer or dealer_id is null)
   order by dealer_id nulls last
   limit 1;

  if coalesce(v_required, false) and p_customer_id is null then
    raise exception 'This dealer requires a customer on every counter sale.'
      using errcode = 'check_violation',
            hint = 'Spec §33: the customer is optional or required by configuration.';
  end if;

  v_number := app.next_document_number(
    v_dealer, p_branch_id, 'COUNTER_INVOICE',
    app.financial_year_token(v_dealer, p_invoice_date));

  insert into public.service_invoices
    (dealer_id, branch_id, invoice_number, invoice_date, invoice_type,
     job_card_id, customer_id, created_by)
  values
    (v_dealer, p_branch_id, v_number, p_invoice_date, 'COUNTER',
     null, p_customer_id, auth.uid())
  returning id into v_id;

  invoice_id := v_id; invoice_number := v_number;
  return next;
end;
$$;

comment on function public.create_counter_invoice(uuid, uuid, date) is
  'Opens an over-the-counter invoice for accessories and spares (spec §33). '
  'Lines, posting and payment reuse the service billing engine, so there is one '
  'accounting path rather than two (spec §60.18).';

-- -----------------------------------------------------------------------------
-- The counter clerk has to be allowed to bill
-- -----------------------------------------------------------------------------
-- si_write and sl_write are FOR ALL and admitted only service.billing.create.
-- That governs the UPDATE half too, and posting an invoice updates it — so a
-- clerk holding inventory.counter_sale.create could have opened a counter
-- invoice and then been refused when posting it.
-- -----------------------------------------------------------------------------
drop policy if exists si_write on public.service_invoices;

create policy si_write on public.service_invoices for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('service.billing.create')
                  or app.has_permission('inventory.counter_sale.create'))))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('service.billing.create')
                  or app.has_permission('inventory.counter_sale.create'))));

drop policy if exists sl_write on public.service_lines;

create policy sl_write on public.service_lines for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('service.billing.create')
                  or app.has_permission('inventory.counter_sale.create'))))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('service.billing.create')
                  or app.has_permission('inventory.counter_sale.create'))));

-- Default: optional, which is how most counters run.
insert into public.system_settings (dealer_id, key, value, value_type, description, is_public)
select d.id, 'counter_sale.require_customer', 'false'::jsonb, 'boolean',
       'Require a customer on every counter sale (spec §33).', true
  from public.dealers d
on conflict on constraint system_settings_scope_key do nothing;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.create_counter_invoice(uuid, uuid, date) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0048_einvoice_payload.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0048 — E-invoice payload and request recording
-- =============================================================================
-- Spec §40.
--
-- The queue from 0034 knows what to file and what came back, but nothing ever
-- built the document the portal actually wants, and request_payload — a column
-- spec §40 asks for by name — has never been written by anything.
--
-- Two functions:
--   * einvoice_payload()        builds the IRP document from the invoice;
--   * record_einvoice_request() stores it and counts the attempt, BEFORE the
--     call goes out.
--
-- Recording the request first matters. If the process dies mid-flight, or the
-- portal accepts a document and the reply is lost, the row still shows exactly
-- what was sent and that an attempt was made — which is the difference between
-- "we never filed" and "we do not know whether we filed".
--
-- The payload follows the NIC IRP schema (version 1.1): TranDtls, DocDtls,
-- SellerDtls, BuyerDtls, ItemList, ValDtls. Field names are the portal's, not
-- this schema's, which is why they are camel-cased and abbreviated here and
-- nowhere else.
--
-- Rollback: drop public.einvoice_payload(uuid) and public.record_einvoice_request(uuid, jsonb),
--           and restore public.record_einvoice_result(...) from 0034.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.einvoice_payload() — spec §40
-- -----------------------------------------------------------------------------
create or replace function public.einvoice_payload(p_einvoice_id uuid)
returns jsonb
language plpgsql
stable
as $$
declare
  v_e        public.einvoices;
  v_seller   record;
  v_buyer    record;
  v_totals   record;
  v_items    jsonb;
  v_intra    boolean;
begin
  select * into v_e from public.einvoices where id = p_einvoice_id;
  if v_e.id is null then
    raise exception 'E-invoice not found.' using errcode = 'no_data_found';
  end if;

  -- ── Seller: the branch that raised it, falling back to the dealer ─────────
  -- A branch may have its own GSTIN; where it does not, the dealer's applies.
  if v_e.document_type = 'SALE' then
    select coalesce(b.gstin, d.gstin) as gstin, d.legal_name as name,
           b.address_line1, b.city, b.pincode, coalesce(b.state_code, d.state_code) as state_code
      into v_seller
      from public.sales s
      join public.branches b on b.id = s.branch_id
      join public.dealers d  on d.id = s.dealer_id
     where s.id = v_e.document_id;
  else
    select coalesce(b.gstin, d.gstin) as gstin, d.legal_name as name,
           b.address_line1, b.city, b.pincode, coalesce(b.state_code, d.state_code) as state_code
      into v_seller
      from public.service_invoices si
      join public.branches b on b.id = si.branch_id
      join public.dealers d  on d.id = si.dealer_id
     where si.id = v_e.document_id;
  end if;

  if v_seller.gstin is null then
    raise exception 'The branch raising % has no GSTIN, and neither has the dealer.',
      v_e.document_number
      using errcode = 'check_violation',
            hint = 'An e-invoice cannot be filed without the seller''s GSTIN.';
  end if;

  -- ── Buyer, totals and lines ──────────────────────────────────────────────
  if v_e.document_type = 'SALE' then
    select c.name, c.gstin, c.address_line1, c.city, c.pincode, c.state_code
      into v_buyer
      from public.sales s left join public.customers c on c.id = s.customer_id
     where s.id = v_e.document_id;

    select taxable_value, cgst_amount, sgst_amount, igst_amount, total_amount, discount_amount
      into v_totals
      from public.sales where id = v_e.document_id;

    select jsonb_agg(item order by item_no)
      into v_items
      from (
        select row_number() over (order by l.line_number) as item_no,
               jsonb_build_object(
                 'SlNo',      row_number() over (order by l.line_number)::text,
                 'PrdDesc',   left(l.description, 300),
                 'IsServc',   case when l.line_type in ('LABOUR', 'FORWARDING', 'OTHER_CHARGE') then 'Y' else 'N' end,
                 'HsnCd',     coalesce(l.hsn_code, '9999'),
                 'Qty',       l.quantity,
                 'Unit',      'NOS',
                 'UnitPrice', l.unit_rate,
                 'TotAmt',    round(l.unit_rate * l.quantity, 2),
                 'Discount',  l.discount,
                 'AssAmt',    l.taxable_value,
                 'GstRt',     coalesce(l.cgst_rate, 0) + coalesce(l.sgst_rate, 0) + coalesce(l.igst_rate, 0),
                 'CgstAmt',   l.cgst_amount,
                 'SgstAmt',   l.sgst_amount,
                 'IgstAmt',   l.igst_amount,
                 'TotItemVal', l.total_amount) as item
          from public.sale_lines l where l.sale_id = v_e.document_id
      ) numbered;
  else
    select c.name, c.gstin, c.address_line1, c.city, c.pincode, c.state_code
      into v_buyer
      from public.service_invoices si left join public.customers c on c.id = si.customer_id
     where si.id = v_e.document_id;

    select taxable_value, cgst_amount, sgst_amount, igst_amount, total_amount, discount_amount
      into v_totals
      from public.service_invoices where id = v_e.document_id;

    select jsonb_agg(item order by item_no)
      into v_items
      from (
        select row_number() over (order by l.line_number) as item_no,
               jsonb_build_object(
                 'SlNo',      row_number() over (order by l.line_number)::text,
                 'PrdDesc',   left(l.description, 300),
                 'IsServc',   case when l.line_type = 'LABOUR' then 'Y' else 'N' end,
                 'HsnCd',     coalesce(l.hsn_code, '9999'),
                 'Qty',       l.quantity,
                 'Unit',      'NOS',
                 'UnitPrice', l.unit_rate,
                 'TotAmt',    round(l.unit_rate * l.quantity, 2),
                 'Discount',  l.discount,
                 'AssAmt',    l.taxable_value,
                 'GstRt',     coalesce(l.cgst_rate, 0) + coalesce(l.sgst_rate, 0) + coalesce(l.igst_rate, 0),
                 'CgstAmt',   l.cgst_amount,
                 'SgstAmt',   l.sgst_amount,
                 'IgstAmt',   l.igst_amount,
                 'TotItemVal', l.total_amount) as item
          from public.service_lines l where l.invoice_id = v_e.document_id
      ) numbered;
  end if;

  if v_items is null then
    raise exception 'Invoice % has no lines to file.', v_e.document_number
      using errcode = 'check_violation';
  end if;

  -- Intra-state when buyer and seller are in the same state. B2C with no state
  -- recorded is treated as intra-state, which is what the tax on the invoice
  -- already assumed when CGST/SGST were charged.
  v_intra := coalesce(v_buyer.state_code, v_seller.state_code) = v_seller.state_code;

  return jsonb_build_object(
    'Version', '1.1',
    'TranDtls', jsonb_build_object(
      'TaxSch', 'GST',
      -- B2B where the buyer has a GSTIN; otherwise a B2C supply.
      'SupTyp', case when v_buyer.gstin is not null then 'B2B' else 'B2C' end,
      'RegRev', 'N',
      'IgstOnIntra', case when v_intra then 'N' else 'Y' end),
    'DocDtls', jsonb_build_object(
      'Typ', 'INV',
      'No',  v_e.document_number,
      'Dt',  to_char(v_e.document_date, 'DD/MM/YYYY')),
    'SellerDtls', jsonb_build_object(
      'Gstin',  v_seller.gstin,
      'LglNm',  v_seller.name,
      'Addr1',  coalesce(v_seller.address_line1, v_seller.city, 'NA'),
      'Loc',    coalesce(v_seller.city, 'NA'),
      'Pin',    coalesce(v_seller.pincode, '000000')::int,
      'Stcd',   v_seller.state_code),
    'BuyerDtls', jsonb_build_object(
      -- URP ("unregistered person") is the portal's own marker for a B2C buyer.
      'Gstin',  coalesce(v_buyer.gstin, 'URP'),
      'LglNm',  coalesce(v_buyer.name, 'Cash customer'),
      'Pos',    coalesce(v_buyer.state_code, v_seller.state_code),
      'Addr1',  coalesce(v_buyer.address_line1, v_buyer.city, 'NA'),
      'Loc',    coalesce(v_buyer.city, 'NA'),
      'Pin',    coalesce(v_buyer.pincode, '000000')::int,
      'Stcd',   coalesce(v_buyer.state_code, v_seller.state_code)),
    'ItemList', v_items,
    'ValDtls', jsonb_build_object(
      'AssVal',    v_totals.taxable_value,
      'CgstVal',   v_totals.cgst_amount,
      'SgstVal',   v_totals.sgst_amount,
      'IgstVal',   v_totals.igst_amount,
      'Discount',  coalesce(v_totals.discount_amount, 0),
      'TotInvVal', v_totals.total_amount)
  );
end;
$$;

comment on function public.einvoice_payload(uuid) is
  'Builds the IRP document (NIC schema 1.1) for a queued e-invoice (spec §40). '
  'Field names are the portal''s, not this schema''s.';

-- -----------------------------------------------------------------------------
-- public.record_einvoice_request() — what we sent, and that we tried
-- -----------------------------------------------------------------------------
-- Called before the request leaves. If the reply never arrives, the row still
-- shows the payload and a raised attempt count, so nobody has to guess whether
-- the portal saw it.
--
-- The count itself is the trigger's, not this function's — see the redefinition
-- of app.einvoice_attempt() below.
-- -----------------------------------------------------------------------------
create or replace function public.record_einvoice_request(
  p_einvoice_id uuid,
  p_payload     jsonb
)
returns void
language plpgsql
as $$
begin
  update public.einvoices
     set request_payload = p_payload,
         -- A document being retried is in flight, not failed, so it goes back to
         -- PENDING as the previous error is cleared. Leaving it FAILED with no
         -- message would violate einvoices_failed_check, and rightly: a failed
         -- row must always say why it failed.
         status          = 'PENDING',
         error_code      = null,
         error_message   = null
   where id = p_einvoice_id
     and status <> 'GENERATED';

  if not found then
    raise exception 'That e-invoice is already generated, or does not exist.'
      using errcode = 'check_violation';
  end if;
end;
$$;

comment on function public.record_einvoice_request(uuid, jsonb) is
  'Stores the payload and counts the attempt before transmission (spec §40), so '
  'a lost reply still leaves evidence of what was sent.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.einvoice_payload(uuid) to authenticated';
    execute 'grant execute on function public.record_einvoice_request(uuid, jsonb) to authenticated';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_einvoice_result() — the outcome of an attempt, not a new one
-- -----------------------------------------------------------------------------
-- 0034 incremented attempt_count here, which was right while nothing recorded
-- the request: the result was the only evidence an attempt had happened. Now
-- that record_einvoice_request() counts the attempt as it goes out, counting
-- again here would make every filing look like two, and "3 attempts" on a row
-- that was tried twice is the kind of number nobody can act on.
--
-- The attempt is made when the request leaves. This records how it ended.
-- -----------------------------------------------------------------------------
create or replace function public.record_einvoice_result(
  p_einvoice_id uuid,
  p_status      text,
  p_irn         text default null,
  p_ack_number  text default null,
  p_ack_date    timestamptz default null,
  p_qr_code     text default null,
  p_error_code  text default null,
  p_error       text default null,
  p_response    jsonb default null
)
returns void
language plpgsql
as $$
begin
  if p_status not in ('GENERATED', 'FAILED', 'CANCELLED') then
    raise exception 'Status must be GENERATED, FAILED or CANCELLED.' using errcode = 'check_violation';
  end if;
  if p_status = 'GENERATED' and (p_irn is null or p_ack_number is null) then
    raise exception 'A generated e-invoice must carry an IRN and acknowledgement number.'
      using errcode = 'check_violation';
  end if;
  if p_status = 'FAILED' and p_error is null then
    raise exception 'A failed e-invoice must record why.' using errcode = 'check_violation';
  end if;

  update public.einvoices
     set status = p_status,
         irn = coalesce(p_irn, irn),
         ack_number = coalesce(p_ack_number, ack_number),
         ack_date = coalesce(p_ack_date, ack_date),
         signed_qr_code = coalesce(p_qr_code, signed_qr_code),
         error_code = p_error_code,
         error_message = p_error,
         response_payload = coalesce(p_response, response_payload),
         last_attempt_at = now()
   where id = p_einvoice_id;

  if not found then
    raise exception 'E-invoice record not found.' using errcode = 'no_data_found';
  end if;
end;
$$;

comment on function public.record_einvoice_result(uuid, text, text, text, timestamptz, text, text, text, jsonb) is
  'Records how a filing attempt ended (spec §40). The attempt itself is counted '
  'by record_einvoice_request() when the request goes out.';


-- -----------------------------------------------------------------------------
-- app.einvoice_attempt() — count attempts when they are made, not when they land
-- -----------------------------------------------------------------------------
-- 0024 put retry bookkeeping in the database rather than the caller, which is
-- right. It counted on the transition to GENERATED or FAILED — the only evidence
-- available while nothing recorded the outgoing request.
--
-- Two problems with leaving it there. record_einvoice_result() *also*
-- incremented, so every completed filing counted twice. And an attempt whose
-- reply never arrives never reached a terminal status, so it was never counted
-- at all — the one case where knowing an attempt was made matters most.
--
-- So the count moves to where the attempt actually starts: a new request
-- payload going out. One filing, one attempt, counted even when the reply is
-- lost.
-- -----------------------------------------------------------------------------
create or replace function app.einvoice_attempt()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'UPDATE' and new.request_payload is distinct from old.request_payload then
    new.attempt_count := old.attempt_count + 1;
    new.last_attempt_at := now();
  end if;
  return new;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0049_cash_book_and_cogs_classification.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0049 — Money received reaches the cash and bank books; accessory cost reaches
--        the accessory accounts
-- =============================================================================
-- Spec §21, §24, §28, §36, §37, §38, §41, §59.
--
-- Two defects, both found by seeding a full set of trading data through the real
-- posting functions and then reconciling the reports against the ledger.
--
-- ── 1. The cash and bank books do not see money taken by other modules ───────
--
-- public.cash_book() reads public.cash_transactions, and public.bank_book() reads
-- public.bank_transactions. Only three functions have ever written to those
-- tables: record_cash_transaction, record_bank_transaction and (since 0046)
-- refund_booking_advance.
--
-- Meanwhile a booking advance, a vehicle sale receipt and a service receipt all
-- debit the cash or bank ledger account directly and write no subsidiary row at
-- all. So the money is in the general ledger and absent from the book that is
-- supposed to itemise it. On a representative day's trading that was ₹50,647.60
-- of receipts missing from the cash book — every cash receipt the business took
-- other than through the cash-book screen itself.
--
-- Spec §36 makes the daily cash book mandatory and §37 defines it as every
-- receipt and payment with a running balance; §59 requires reports to reconcile
-- with transaction data. A cash book that omits the takings is not a cash book,
-- and the day-close difference it computes is meaningless — expected closing was
-- being derived from a fraction of the day's movements.
--
-- Fixed by giving the three functions a shared helper that writes the subsidiary
-- row alongside the journal they already post.
--
-- ── 2. Accessory cost is charged to vehicle and spare accounts ──────────────
--
-- Accounts 1600 (Accessories Inventory) and 5200 (Accessories COGS) exist in
-- every dealer's chart of accounts and had never received a single entry.
--
-- post_vehicle_sale summed cost_amount across all invoice lines into one figure
-- and posted it to SALES/INVOICE/COGS → 5100, so accessories fitted to a vehicle
-- were charged to Vehicle COGS. post_service_invoice did the same into
-- SERVICE/INVOICE/COGS → 5300, so accessories sold over the counter were charged
-- to Spare COGS.
--
-- Spec §24 lists the accessory accounts separately and §41 requires an
-- accessories margin report for owners and accounts. Neither can be derived from
-- a ledger that never posts to them, and both the vehicle and the spare margin
-- were overstated in cost by the accessory content.
--
-- Fixed by classifying the cost by what was actually sold before posting it.
--
-- Rollback: restore public.create_booking_with_advance and public.record_sale_payment
--           from 0028, public.record_sale_payment from 0043, public.record_service_payment
--           and public.post_service_invoice from 0033, public.post_vehicle_sale
--           from 0025; drop app.record_money_movement and
--           app.seed_cogs_accounting_rules; delete the accounting_rules rows
--           whose description is 'Cost classification (0049)'.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Accounting rules for the accessory cost accounts
-- -----------------------------------------------------------------------------
-- Added as new components rather than by repointing COGS/INVENTORY, so a dealer
-- who has already mapped those to their own accounts keeps that mapping. The
-- existing COGS/INVENTORY components keep their meaning: the module's primary
-- stock — vehicles for a sale, spares for a service invoice.
create or replace function app.seed_cogs_accounting_rules(p_dealer_id uuid)
returns integer
language plpgsql
as $$
declare
  v_added integer := 0;
  v_rule  record;
  v_account uuid;
begin
  for v_rule in
    select * from (values
      ('SALES',   'INVOICE', 'ACCESSORY_COGS',      'DEBIT',  '5200'),
      ('SALES',   'INVOICE', 'ACCESSORY_INVENTORY', 'CREDIT', '1600'),
      ('SERVICE', 'INVOICE', 'ACCESSORY_COGS',      'DEBIT',  '5200'),
      ('SERVICE', 'INVOICE', 'ACCESSORY_INVENTORY', 'CREDIT', '1600')
    ) as t(module, event, component, side, account_code)
  loop
    select id into v_account
      from public.chart_of_accounts
     where dealer_id = p_dealer_id and code = v_rule.account_code;

    -- A dealer running a chart of accounts of their own may not have this code.
    -- Skipping is right: the posting paths below fall back to the module's
    -- existing COGS mapping when no accessory rule is configured, so nothing
    -- breaks — the split simply does not happen for them.
    continue when v_account is null;

    insert into public.accounting_rules
      (dealer_id, module, event, component, side, account_id, description)
    values
      (p_dealer_id, v_rule.module, v_rule.event, v_rule.component, v_rule.side,
       v_account, 'Cost classification (0049)')
    on conflict do nothing;

    if found then v_added := v_added + 1; end if;
  end loop;

  return v_added;
end;
$$;

comment on function app.seed_cogs_accounting_rules(uuid) is
  'Maps accessory cost and accessory stock relief to accounts 5200 and 1600 '
  '(spec §24). Skips any code the dealer does not have; the posting paths fall '
  'back to the module COGS mapping when a rule is absent.';

do $$
declare d record;
begin
  for d in select id from public.dealers loop
    perform app.seed_cogs_accounting_rules(d.id);
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- Every branch has a cash account — spec §36, now actually guaranteed
-- -----------------------------------------------------------------------------
-- cash_accounts has carried `unique (branch_id)` since 0022, but nothing ever
-- created the row: seed.sql does not, and neither does branch creation. Every
-- branch in existence has been without one, which is why nothing noticed that
-- receipts were not reaching the cash book — there was nowhere to put them.
--
-- SECURITY DEFINER because cash_accounts_write requires admin.settings.manage,
-- and the point is that this happens automatically rather than being remembered.
-- It only ever inserts a row for the branch being created, so there is nothing a
-- caller can steer.
create or replace function app.branches_ensure_cash_account()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account uuid;
begin
  v_account := public.resolve_account(new.dealer_id, 'CASH', 'RECEIPT', 'CASH', new.id);

  if v_account is null then
    select id into v_account from public.chart_of_accounts
     where dealer_id = new.dealer_id and code = '1100';
  end if;

  -- A branch can be created before the chart of accounts exists. Skipping leaves
  -- the backfill below to catch it once the accounts are in place.
  if v_account is null then
    return new;
  end if;

  insert into public.cash_accounts (dealer_id, branch_id, name, ledger_account_id)
  values (new.dealer_id, new.id, new.name || ' — Cash', v_account)
  on conflict (branch_id) do nothing;

  return new;
end;
$$;

drop trigger if exists branches_ensure_cash_account on public.branches;
create trigger branches_ensure_cash_account
  after insert on public.branches
  for each row execute function app.branches_ensure_cash_account();

-- The same logic, callable: a branch is often created before the chart of
-- accounts exists (seed.sql does exactly that), so the trigger above cannot
-- always succeed at insert time. seed.sql calls this once the accounts are in.
create or replace function app.ensure_branch_cash_accounts(p_dealer_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  b record;
  v_account uuid;
  v_made int := 0;
begin
  for b in
    select br.id, br.dealer_id, br.name
      from public.branches br
      left join public.cash_accounts ca on ca.branch_id = br.id
     where ca.id is null
       and (p_dealer_id is null or br.dealer_id = p_dealer_id)
  loop
    v_account := public.resolve_account(b.dealer_id, 'CASH', 'RECEIPT', 'CASH', b.id);
    if v_account is null then
      select id into v_account from public.chart_of_accounts
       where dealer_id = b.dealer_id and code = '1100';
    end if;
    continue when v_account is null;

    insert into public.cash_accounts (dealer_id, branch_id, name, ledger_account_id)
    values (b.dealer_id, b.id, b.name || ' — Cash', v_account)
    on conflict (branch_id) do nothing;
    v_made := v_made + 1;
  end loop;

  return v_made;
end;
$$;

comment on function app.ensure_branch_cash_accounts(uuid) is
  'Creates the missing per-branch cash account required by spec §36. Safe to '
  'call repeatedly; skips branches whose dealer has no cash ledger account yet.';

-- Backfill every branch that already exists.
do $$
declare v_made int;
begin
  v_made := app.ensure_branch_cash_accounts();
  if v_made > 0 then
    raise notice '0049: created % missing branch cash account(s).', v_made;
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- The roles that take the money must be allowed to write the book
-- -----------------------------------------------------------------------------
-- ct_insert admitted only cashbook.receipts.create / cashbook.payments.create,
-- which CASHIER and COUNTER_SALES hold but SALES_EXECUTIVE and SERVICE_ADVISOR
-- do not. Without this, the helper below would turn a sales executive's booking
-- advance and a service advisor's receipt — both already authorized, both
-- already posting a journal — into an RLS failure.
--
-- Same reasoning as 0043 adding finance.applications.manage to ft_insert and
-- 0045 adding sales.deliver to cv_write: the subsidiary row is part of the act
-- the user is already permitted to perform, not a separate privilege.
drop policy if exists ct_insert on public.cash_transactions;

create policy ct_insert on public.cash_transactions for insert to authenticated
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('cashbook.receipts.create')
                  or app.has_permission('cashbook.payments.create')
                  or app.has_permission('bookings.create')
                  or app.has_permission('bookings.refund')
                  or app.has_permission('sales.create')
                  or app.has_permission('service.payments.collect')
                  or app.has_permission('inventory.counter_sale.create'))));

drop policy if exists bt_write on public.bank_transactions;

create policy bt_write on public.bank_transactions for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('bank.reconcile')
                  or app.has_permission('cashbook.payments.create'))))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('bank.reconcile')
                  or app.has_permission('cashbook.payments.create')
                  or app.has_permission('bookings.create')
                  or app.has_permission('bookings.refund')
                  or app.has_permission('sales.create')
                  or app.has_permission('service.payments.collect')
                  or app.has_permission('inventory.counter_sale.create'))));

-- The USING clause stays narrow on purpose: taking a payment writes a row, it
-- does not amend or reconcile one. Only bank.reconcile and cashbook.payments.create
-- can touch a bank row after the fact.

-- -----------------------------------------------------------------------------
-- app.record_money_movement() — the subsidiary row behind a posted receipt
-- -----------------------------------------------------------------------------
-- Called after the journal is posted, by every function that takes or returns
-- money outside the cash-book and bank-book screens. It writes the cash or bank
-- row that makes the movement visible in the book, and nothing else — the
-- journal is already written and is not touched here.
--
-- Three modes, and the third is the interesting one:
--
--   CASH     — opens the day if needed and writes a cash_transactions row.
--   BANK etc — writes a bank_transactions row against the branch's account.
--   FINANCE  — writes nothing, deliberately. A sale settled by finance has moved
--              the debt to the finance company; no money has arrived yet, and it
--              must not appear in a book that says it has. The disbursement is
--              what hits the bank, and disburse_finance_application already
--              writes that row.
create or replace function app.record_money_movement(
  p_dealer_id   uuid,
  p_branch_id   uuid,
  p_date        date,
  p_mode        text,
  p_direction   text,      -- RECEIPT | PAYMENT
  p_amount      numeric,
  p_particular  text,
  p_reference   text,
  p_journal_entry_id uuid,
  p_customer_id uuid default null
)
returns void
language plpgsql
as $$
declare
  v_cash public.cash_accounts;
  v_bank uuid;
begin
  if p_mode = 'FINANCE' then
    return;
  end if;

  if p_mode = 'CASH' then
    select * into v_cash from public.cash_accounts
     where branch_id = p_branch_id and status = 'ACTIVE';

    -- A branch with no cash account cannot have a cash book. Silence here would
    -- reintroduce exactly the defect this migration exists to close.
    if v_cash.id is null then
      raise exception 'Branch has no active cash account, so this receipt cannot reach the cash book.'
        using errcode = 'no_data_found',
              hint = 'Create a cash account for the branch (spec §36: each branch has one).';
    end if;

    -- Opens the day, and refuses if it is already closed (spec §36).
    perform public.ensure_cash_day(p_branch_id, p_date);

    insert into public.cash_transactions
      (dealer_id, branch_id, cash_account_id, business_date, direction, amount,
       particular, reference_number, customer_id, journal_entry_id, created_by)
    values
      (p_dealer_id, p_branch_id, v_cash.id, p_date, p_direction, p_amount,
       p_particular, p_reference, p_customer_id, p_journal_entry_id, auth.uid());

    return;
  end if;

  -- Anything else settles through a bank account: the branch's own, else the
  -- dealer-wide one.
  select id into v_bank from public.bank_accounts
   where dealer_id = p_dealer_id and status = 'ACTIVE' and branch_id = p_branch_id
   order by created_at limit 1;

  if v_bank is null then
    select id into v_bank from public.bank_accounts
     where dealer_id = p_dealer_id and status = 'ACTIVE' and branch_id is null
     order by created_at limit 1;
  end if;

  -- Unlike cash, this one does not raise. A dealer may genuinely have no bank
  -- account configured yet and still take a UPI payment on day one; refusing the
  -- receipt would be a worse failure than a bank book that has nothing to show.
  -- The journal is posted either way, so no money is lost — only the subsidiary
  -- row is skipped, and it reappears as soon as an account exists.
  if v_bank is null then
    return;
  end if;

  insert into public.bank_transactions
    (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
     reference_number, customer_id, journal_entry_id, created_by)
  values
    (p_dealer_id, v_bank, p_date, p_direction, p_amount, p_particular,
     p_reference, p_customer_id, p_journal_entry_id, auth.uid());
end;
$$;

comment on function app.record_money_movement(uuid, uuid, date, text, text, numeric, text, text, uuid, uuid) is
  'Writes the cash_transactions or bank_transactions row behind a receipt that '
  'another module has already journalled, so the cash book (spec §37) and bank '
  'book (spec §38) show it. FINANCE writes nothing: the money has not arrived.';

-- -----------------------------------------------------------------------------
-- public.create_booking_with_advance() — spec §18
-- -----------------------------------------------------------------------------
-- Unchanged from 0028 apart from the closing call: the advance now reaches the
-- cash or bank book.
create or replace function public.create_booking_with_advance(
  p_customer_id       uuid,
  p_model_id          uuid,
  p_branch_id         uuid,
  p_booking_amount    numeric,
  p_advance_amount    numeric,
  p_payment_mode      text,
  p_variant_id        uuid default null,
  p_vehicle_id        uuid default null,
  p_expected_delivery date default null,
  p_sales_executive_id uuid default null,
  p_reference         text default null,
  p_notes             text default null
)
returns table (booking_id uuid, booking_number text, receipt_number text, journal_entry_id uuid)
language plpgsql
as $$
declare
  v_dealer_id uuid;
  v_year      text;
  v_booking   uuid;
  v_bnumber   text;
  v_rnumber   text;
  v_entry     uuid;
  v_debit_acc uuid;
  v_credit_acc uuid;
  v_cash_component text;
begin
  if p_advance_amount <= 0 then
    raise exception 'The advance amount must be greater than zero.'
      using errcode = 'check_violation';
  end if;
  if p_booking_amount > 0 and p_advance_amount > p_booking_amount then
    raise exception 'The advance cannot exceed the booking amount.'
      using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer_id from public.branches where id = p_branch_id;
  if v_dealer_id is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  v_year := app.financial_year_token(v_dealer_id, current_date);

  -- Resolve accounts before writing anything: an unconfigured mapping should
  -- fail before a booking number is consumed.
  v_cash_component := case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end;
  v_debit_acc  := app.require_account(v_dealer_id, 'BOOKING', 'ADVANCE', v_cash_component, p_branch_id);
  v_credit_acc := app.require_account(v_dealer_id, 'BOOKING', 'ADVANCE', 'CUSTOMER_ADVANCE', p_branch_id);

  v_bnumber := app.next_document_number(v_dealer_id, p_branch_id, 'BOOKING', v_year);
  v_rnumber := app.next_document_number(v_dealer_id, p_branch_id, 'RECEIPT', v_year);

  insert into public.bookings
    (dealer_id, branch_id, booking_number, customer_id, model_id, variant_id, vehicle_id,
     booking_amount, expected_delivery, sales_executive_id, notes, created_by)
  values
    (v_dealer_id, p_branch_id, v_bnumber, p_customer_id, p_model_id, p_variant_id, p_vehicle_id,
     p_booking_amount, p_expected_delivery, p_sales_executive_id, p_notes, auth.uid())
  returning id into v_booking;

  -- Spec §18: the advance is a liability until the sale is raised.
  v_entry := app.post_journal(
    v_dealer_id, p_branch_id, current_date, 'BOOKING',
    'Booking advance ' || v_bnumber,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit_acc, 'debit', p_advance_amount, 'credit', 0,
                         'narration', p_payment_mode || ' received'),
      jsonb_build_object('account_id', v_credit_acc, 'debit', 0, 'credit', p_advance_amount,
                         'narration', 'Customer advance',
                         'party_type', 'CUSTOMER', 'party_id', p_customer_id)
    ),
    'BOOKING', v_booking, 'booking:' || v_booking::text
  );

  insert into public.booking_payments
    (dealer_id, booking_id, receipt_number, amount, payment_mode, reference,
     journal_entry_id, created_by)
  values
    (v_dealer_id, v_booking, v_rnumber, p_advance_amount, p_payment_mode, p_reference,
     v_entry, auth.uid());

  -- Reserving a specific chassis takes it out of available stock (spec §13).
  if p_vehicle_id is not null then
    update public.vehicles set status = 'BOOKED', updated_by = auth.uid()
     where id = p_vehicle_id and status = 'IN_STOCK';
  end if;

  -- 0049: and into the cash or bank book, which is where the cashier looks.
  perform app.record_money_movement(
    v_dealer_id, p_branch_id, current_date, p_payment_mode, 'RECEIPT',
    p_advance_amount, 'Booking advance ' || v_bnumber, coalesce(p_reference, v_rnumber),
    v_entry, p_customer_id);

  booking_id := v_booking; booking_number := v_bnumber;
  receipt_number := v_rnumber; journal_entry_id := v_entry;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_sale_payment() — spec §19, §27
-- -----------------------------------------------------------------------------
-- Carries forward from 0043: the FINANCE_RECEIVABLE line stays party-tagged to
-- the finance company and a FINANCE payment still writes its finance_transactions
-- row. New in 0049: a cash or bank receipt reaches its book.
create or replace function public.record_sale_payment(
  p_sale_id      uuid,
  p_amount       numeric,
  p_payment_mode text,
  p_reference    text default null,
  p_finance_company_id uuid default null
)
returns table (receipt_number text, journal_entry_id uuid)
language plpgsql
as $$
declare
  v_sale     public.sales;
  v_year     text;
  v_rnumber  text;
  v_entry    uuid;
  v_debit    uuid;
  v_credit   uuid;
  v_component text;
  v_party    text;
  v_party_id uuid;
begin
  if p_amount <= 0 then
    raise exception 'The payment amount must be greater than zero.' using errcode = 'check_violation';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;
  if v_sale.id is null then
    raise exception 'Sale not found.' using errcode = 'no_data_found';
  end if;
  if v_sale.status not in ('POSTED', 'DELIVERED') then
    raise exception 'Payments can only be recorded against a posted invoice; this one is %.', v_sale.status
      using errcode = 'check_violation';
  end if;

  v_year := app.financial_year_token(v_sale.dealer_id, current_date);
  v_rnumber := app.next_document_number(v_sale.dealer_id, v_sale.branch_id, 'RECEIPT', v_year);

  -- Finance disbursement moves the debt to the finance company rather than
  -- settling it in cash (spec §27).
  if p_payment_mode = 'FINANCE' then
    if p_finance_company_id is null then
      raise exception 'A finance payment must name the finance company carrying the debt.'
        using errcode = 'check_violation';
    end if;
    v_component := 'FINANCE_RECEIVABLE';
    v_debit  := app.require_account(v_sale.dealer_id, 'FINANCE', 'INVOICE', 'FINANCE_RECEIVABLE', v_sale.branch_id);
    v_party := 'FINANCE_COMPANY';
    v_party_id := p_finance_company_id;
  else
    v_component := case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end;
    v_debit := app.require_account(
      v_sale.dealer_id,
      case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
      'RECEIPT', v_component, v_sale.branch_id);
  end if;

  v_credit := app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'RECEIVABLE', v_sale.branch_id);

  v_entry := app.post_journal(
    v_sale.dealer_id, v_sale.branch_id, current_date,
    case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
    'Receipt ' || v_rnumber || ' against ' || v_sale.invoice_number,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', p_payment_mode || ' received',
                         'party_type', v_party, 'party_id', v_party_id),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', 'Against ' || v_sale.invoice_number,
                         'party_type', 'CUSTOMER', 'party_id', v_sale.customer_id)
    ),
    'SALE_PAYMENT', p_sale_id, 'receipt:' || v_rnumber
  );

  insert into public.sale_payments
    (dealer_id, sale_id, receipt_number, amount, payment_mode, reference,
     finance_company_id, journal_entry_id, created_by)
  values
    (v_sale.dealer_id, p_sale_id, v_rnumber, p_amount, p_payment_mode, p_reference,
     p_finance_company_id, v_entry, auth.uid());

  -- The company now owes the dealer for this vehicle, so its position rises.
  if p_payment_mode = 'FINANCE' then
    insert into public.finance_transactions
      (dealer_id, branch_id, finance_company_id, transaction_date, transaction_type,
       debit, credit, reference_type, reference_id, reference_number, narration,
       sale_id, journal_entry_id, created_by)
    values
      (v_sale.dealer_id, v_sale.branch_id, p_finance_company_id, current_date, 'VEHICLE_ADJUSTMENT',
       0, p_amount, 'SALE', p_sale_id, v_sale.invoice_number,
       'Financed ' || v_sale.invoice_number, p_sale_id, v_entry, auth.uid());
  end if;

  -- 0049: FINANCE returns immediately inside the helper — no money has moved.
  perform app.record_money_movement(
    v_sale.dealer_id, v_sale.branch_id, current_date, p_payment_mode, 'RECEIPT',
    p_amount, 'Receipt ' || v_rnumber || ' — ' || v_sale.invoice_number,
    coalesce(p_reference, v_rnumber), v_entry, v_sale.customer_id);

  receipt_number := v_rnumber; journal_entry_id := v_entry;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_service_payment() — spec §32, §33
-- -----------------------------------------------------------------------------
-- Unchanged from 0033 apart from the closing call. Counter sales come through
-- here too, so this is what puts counter takings into the cash book.
create or replace function public.record_service_payment(
  p_invoice_id   uuid,
  p_amount       numeric,
  p_payment_mode text default 'CASH',
  p_reference    text default null,
  p_date         date default current_date
)
returns table (payment_id uuid, receipt_number text, balance_due numeric)
language plpgsql
as $$
declare
  v_invoice public.service_invoices;
  v_number  text;
  v_entry   uuid;
  v_debit   uuid;
  v_credit  uuid;
  v_id      uuid;
  v_balance numeric(18, 4);
begin
  select * into v_invoice from public.service_invoices where id = p_invoice_id for update;

  if v_invoice.id is null then
    raise exception 'Invoice not found.' using errcode = 'no_data_found';
  end if;
  if v_invoice.status <> 'POSTED' then
    raise exception 'Invoice % is % — only a posted invoice can take a payment.',
      v_invoice.invoice_number, v_invoice.status using errcode = 'check_violation';
  end if;
  if p_amount <= 0 then
    raise exception 'The payment amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_amount > v_invoice.total_amount - v_invoice.paid_amount then
    raise exception 'That is more than the % outstanding on this invoice.',
      v_invoice.total_amount - v_invoice.paid_amount using errcode = 'check_violation';
  end if;

  v_number := app.next_document_number(
    v_invoice.dealer_id, v_invoice.branch_id, 'RECEIPT',
    app.financial_year_token(v_invoice.dealer_id, p_date));

  v_debit := app.require_account(
    v_invoice.dealer_id,
    case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
    'RECEIPT',
    case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
    v_invoice.branch_id);

  v_credit := app.require_account(v_invoice.dealer_id, 'SERVICE', 'INVOICE', 'RECEIVABLE', v_invoice.branch_id);

  v_entry := app.post_journal(
    v_invoice.dealer_id, v_invoice.branch_id, p_date,
    case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
    'Receipt ' || v_number || ' against ' || v_invoice.invoice_number,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', v_number),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', v_invoice.invoice_number,
                         'party_type', case when v_invoice.customer_id is not null then 'CUSTOMER' end,
                         'party_id', v_invoice.customer_id)
    ),
    'SERVICE_RECEIPT', p_invoice_id, null);

  insert into public.service_payments
    (dealer_id, invoice_id, receipt_number, payment_date, amount, payment_mode,
     reference, journal_entry_id, created_by)
  values
    (v_invoice.dealer_id, p_invoice_id, v_number, p_date, p_amount, p_payment_mode,
     p_reference, v_entry, auth.uid())
  returning id into v_id;

  -- 0049: counter and workshop takings reach the cash book.
  perform app.record_money_movement(
    v_invoice.dealer_id, v_invoice.branch_id, p_date, p_payment_mode, 'RECEIPT',
    p_amount, 'Receipt ' || v_number || ' — ' || v_invoice.invoice_number,
    coalesce(p_reference, v_number), v_entry, v_invoice.customer_id);

  select si.total_amount - si.paid_amount into v_balance
    from public.service_invoices si where si.id = p_invoice_id;

  payment_id := v_id; receipt_number := v_number; balance_due := v_balance;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.post_vehicle_sale() — spec §19, §22, §24
-- -----------------------------------------------------------------------------
-- Carries forward from 0025 unchanged, except that the cost accumulator is split
-- in two: what came out of vehicle stock, and what came out of accessory stock.
-- FITTING and ACCESSORY lines are accessories; everything else with a cost is
-- the vehicle. Charges that carry no stock — insurance, registration, forwarding
-- — have no cost_amount and contribute to neither.
create or replace function public.post_vehicle_sale(
  p_sale_id uuid,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_sale    public.sales;
  v_vehicle public.vehicles;
  v_lines   jsonb := '[]'::jsonb;
  v_entry   uuid;
  v_line    record;
  v_cogs    numeric(18, 4) := 0;   -- vehicle stock
  v_acc_cogs numeric(18, 4) := 0;  -- accessory stock
  v_acc_debit  uuid;
  v_acc_credit uuid;
begin
  -- Step 3: lock the sale and the vehicle. A second concurrent post blocks here
  -- and then fails the status check below (spec §49).
  select * into v_sale from public.sales where id = p_sale_id for update;

  if v_sale.id is null then
    raise exception 'Sale not found.' using errcode = 'no_data_found';
  end if;

  if v_sale.status <> 'APPROVED' then
    raise exception 'Sale % is % — only an APPROVED sale can be posted.', v_sale.invoice_number, v_sale.status
      using errcode = 'check_violation',
            hint = 'Spec §19: posting happens only after accounts approval.';
  end if;

  select * into v_vehicle from public.vehicles where id = v_sale.vehicle_id for update;

  if v_vehicle.status not in ('IN_STOCK', 'BOOKED') then
    raise exception 'Vehicle % is % and cannot be sold.', v_vehicle.chassis_no, v_vehicle.status
      using errcode = 'check_violation';
  end if;

  -- Step 8–10: build the journal from the invoice lines, resolving every account
  -- through accounting_rules.
  v_lines := v_lines || jsonb_build_array(jsonb_build_object(
    'account_id', app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'RECEIVABLE', v_sale.branch_id),
    'debit', v_sale.total_amount, 'credit', 0,
    'narration', 'Sale ' || v_sale.invoice_number,
    'party_type', 'CUSTOMER', 'party_id', v_sale.customer_id
  ));

  for v_line in
    select line_type, sum(taxable_value) taxable, sum(cost_amount) cost
      from public.sale_lines where sale_id = p_sale_id
     group by line_type
  loop
    if v_line.taxable > 0 then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'account_id', app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', v_line.line_type, v_sale.branch_id),
        'debit', 0, 'credit', v_line.taxable,
        'narration', v_line.line_type || ' revenue'
      ));
    end if;

    -- 0049: accessory cost is accessory cost, whichever invoice it rides on.
    if v_line.line_type in ('FITTING', 'ACCESSORY') then
      v_acc_cogs := v_acc_cogs + coalesce(v_line.cost, 0);
    else
      v_cogs := v_cogs + coalesce(v_line.cost, 0);
    end if;
  end loop;

  if v_sale.cgst_amount > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'CGST', v_sale.branch_id),
      'debit', 0, 'credit', v_sale.cgst_amount, 'narration', 'Output CGST'));
  end if;
  if v_sale.sgst_amount > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'SGST', v_sale.branch_id),
      'debit', 0, 'credit', v_sale.sgst_amount, 'narration', 'Output SGST'));
  end if;
  if v_sale.igst_amount > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'IGST', v_sale.branch_id),
      'debit', 0, 'credit', v_sale.igst_amount, 'narration', 'Output IGST'));
  end if;

  -- Step 11: inventory relief and COGS recognition (spec §22).
  if v_cogs > 0 then
    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('account_id', app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'COGS', v_sale.branch_id),
                         'debit', v_cogs, 'credit', 0, 'narration', 'Vehicle cost of goods sold'),
      jsonb_build_object('account_id', app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'INVENTORY', v_sale.branch_id),
                         'debit', 0, 'credit', v_cogs, 'narration', 'Vehicle stock relieved'));
  end if;

  if v_acc_cogs > 0 then
    -- resolve_account rather than require_account: a dealer whose chart has no
    -- 1600/5200 keeps the pre-0049 behaviour instead of being unable to post.
    v_acc_debit  := public.resolve_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'ACCESSORY_COGS', v_sale.branch_id);
    v_acc_credit := public.resolve_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'ACCESSORY_INVENTORY', v_sale.branch_id);

    if v_acc_debit is null or v_acc_credit is null then
      v_acc_debit  := app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'COGS', v_sale.branch_id);
      v_acc_credit := app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'INVENTORY', v_sale.branch_id);
    end if;

    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('account_id', v_acc_debit, 'debit', v_acc_cogs, 'credit', 0,
                         'narration', 'Accessories cost of goods sold'),
      jsonb_build_object('account_id', v_acc_credit, 'debit', 0, 'credit', v_acc_cogs,
                         'narration', 'Accessory stock relieved'));
  end if;

  -- Steps 10 and 13: post atomically. Unbalanced input raises and the whole
  -- function rolls back, leaving neither invoice status nor stock changed.
  v_entry := app.post_journal(
    v_sale.dealer_id, v_sale.branch_id, v_sale.invoice_date, 'SALES',
    'Vehicle sale ' || v_sale.invoice_number, v_lines,
    'SALE', v_sale.id,
    coalesce(p_idempotency_key, 'sale:' || v_sale.id::text)
  );

  -- Step 12: vehicle status.
  update public.vehicles
     set status = 'SOLD_PENDING_DELIVERY', sale_id = v_sale.id, updated_by = auth.uid()
   where id = v_sale.vehicle_id;

  update public.sales
     set status = 'POSTED', journal_entry_id = v_entry, posted_by = auth.uid()
   where id = p_sale_id;

  return v_entry;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.post_service_invoice() — spec §32, §33, §24
-- -----------------------------------------------------------------------------
-- Carries forward from 0033 unchanged, except that stock relief is accumulated
-- per item type as it is allocated, so a counter sale of helmets no longer
-- charges Spare COGS.
create or replace function public.post_service_invoice(
  p_invoice_id      uuid,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_invoice public.service_invoices;
  v_dealer  uuid;
  v_branch  uuid;
  v_lines   jsonb := '[]'::jsonb;
  v_entry   uuid;
  v_line    record;
  v_alloc   record;
  v_cogs    numeric(18, 4) := 0;   -- spares
  v_acc_cogs numeric(18, 4) := 0;  -- accessories
  v_remaining numeric(14, 3);
  v_acc_debit  uuid;
  v_acc_credit uuid;
begin
  select * into v_invoice from public.service_invoices where id = p_invoice_id for update;

  if v_invoice.id is null then
    raise exception 'Invoice not found.' using errcode = 'no_data_found';
  end if;
  if v_invoice.status = 'POSTED' then
    -- Idempotent: a retried request returns the entry the first one wrote.
    return v_invoice.journal_entry_id;
  end if;
  if v_invoice.status <> 'DRAFT' then
    raise exception 'Invoice % is % and cannot be posted.', v_invoice.invoice_number, v_invoice.status
      using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.service_lines where invoice_id = p_invoice_id) then
    raise exception 'Invoice % has no lines.', v_invoice.invoice_number
      using errcode = 'check_violation';
  end if;

  v_dealer := v_invoice.dealer_id;
  v_branch := v_invoice.branch_id;

  -- ── Revenue, one line per component ───────────────────────────────────────
  for v_line in
    select line_type, sum(taxable_value) as taxable
      from public.service_lines
     where invoice_id = p_invoice_id and line_type <> 'DISCOUNT'
     group by line_type
     having sum(taxable_value) > 0
  loop
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', v_line.line_type, v_branch),
      'debit', 0, 'credit', v_line.taxable,
      'narration', v_invoice.invoice_number || ' — ' || v_line.line_type);
  end loop;

  -- ── GST ───────────────────────────────────────────────────────────────────
  if v_invoice.cgst_amount > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'CGST', v_branch),
      'debit', 0, 'credit', v_invoice.cgst_amount, 'narration', 'CGST');
  end if;
  if v_invoice.sgst_amount > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'SGST', v_branch),
      'debit', 0, 'credit', v_invoice.sgst_amount, 'narration', 'SGST');
  end if;
  if v_invoice.igst_amount > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'IGST', v_branch),
      'debit', 0, 'credit', v_invoice.igst_amount, 'narration', 'IGST');
  end if;

  -- ── The customer owes the total ───────────────────────────────────────────
  v_lines := v_lines || jsonb_build_object(
    'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'RECEIVABLE', v_branch),
    'debit', v_invoice.total_amount, 'credit', 0,
    'narration', v_invoice.invoice_number,
    'party_type', case when v_invoice.customer_id is not null then 'CUSTOMER' end,
    'party_id', v_invoice.customer_id);

  -- A discount reduces what is owed, so it is a debit against revenue.
  for v_line in
    select sum(taxable_value + discount) as amount
      from public.service_lines
     where invoice_id = p_invoice_id and line_type = 'DISCOUNT'
     having sum(taxable_value + discount) > 0
  loop
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'LABOUR', v_branch),
      'debit', v_line.amount, 'credit', 0, 'narration', 'Discount');
  end loop;

  -- ── Stock relief and COGS (spec §31) ──────────────────────────────────────
  -- item_type comes along for the ride so the cost can be classified (0049).
  for v_line in
    select sl.id, sl.item_id, sl.quantity, sl.unit_rate, sl.line_number, i.item_type
      from public.service_lines sl
      join public.inventory_items i on i.id = sl.item_id
     where sl.invoice_id = p_invoice_id and sl.item_id is not null
     order by sl.line_number
  loop
    v_remaining := v_line.quantity;

    for v_alloc in
      select * from public.allocate_stock(v_line.item_id, v_branch, v_line.quantity)
    loop
      -- Stock can have moved since the line was drafted, so the shortfall is
      -- checked again here. 'SHORTFALL' is not a stock source and must never
      -- reach inventory_transactions.
      if v_alloc.source = 'SHORTFALL' then
        raise exception 'Insufficient stock to post this invoice: short by % on one line.', v_alloc.quantity
          using errcode = 'check_violation',
                hint = 'Spec §31: block rather than overselling.';
      end if;

      -- Quantity is signed: negative issues. One movement per source, never
      -- merged, so the ledger shows which stock the part actually came out of.
      insert into public.inventory_transactions
        (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
         reference_type, reference_id, reference_number, narration, created_by)
      values
        (v_dealer, v_branch, v_line.item_id, v_alloc.source, 'CONSUMPTION',
         -v_alloc.quantity, v_alloc.unit_cost,
         'SERVICE_INVOICE', p_invoice_id, v_invoice.invoice_number,
         'Consumed on ' || v_invoice.invoice_number, auth.uid());

      if v_line.item_type = 'ACCESSORY' then
        v_acc_cogs := v_acc_cogs + round(v_alloc.quantity * v_alloc.unit_cost, 2);
      else
        v_cogs := v_cogs + round(v_alloc.quantity * v_alloc.unit_cost, 2);
      end if;
      v_remaining := v_remaining - v_alloc.quantity;
    end loop;

    if v_remaining > 0 then
      raise exception 'Not enough stock to fulfil line for item %.', v_line.item_id
        using errcode = 'check_violation';
    end if;
  end loop;

  if v_cogs > 0 then
    v_lines := v_lines
      || jsonb_build_object(
           'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'COGS', v_branch),
           'debit', v_cogs, 'credit', 0, 'narration', 'Cost of parts consumed')
      || jsonb_build_object(
           'account_id', app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'INVENTORY', v_branch),
           'debit', 0, 'credit', v_cogs, 'narration', 'Parts issued from stock');
  end if;

  if v_acc_cogs > 0 then
    v_acc_debit  := public.resolve_account(v_dealer, 'SERVICE', 'INVOICE', 'ACCESSORY_COGS', v_branch);
    v_acc_credit := public.resolve_account(v_dealer, 'SERVICE', 'INVOICE', 'ACCESSORY_INVENTORY', v_branch);

    if v_acc_debit is null or v_acc_credit is null then
      v_acc_debit  := app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'COGS', v_branch);
      v_acc_credit := app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'INVENTORY', v_branch);
    end if;

    v_lines := v_lines
      || jsonb_build_object('account_id', v_acc_debit, 'debit', v_acc_cogs, 'credit', 0,
                            'narration', 'Cost of accessories sold')
      || jsonb_build_object('account_id', v_acc_credit, 'debit', 0, 'credit', v_acc_cogs,
                            'narration', 'Accessories issued from stock');
  end if;

  v_entry := app.post_journal(
    v_dealer, v_branch, v_invoice.invoice_date, 'SERVICE',
    'Service invoice ' || v_invoice.invoice_number,
    v_lines, 'SERVICE_INVOICE', p_invoice_id,
    coalesce(p_idempotency_key, 'service:' || p_invoice_id::text));

  update public.service_invoices
     set status = 'POSTED', posted_at = now(), journal_entry_id = v_entry,
         total_cost = v_cogs + v_acc_cogs,
         idempotency_key = coalesce(p_idempotency_key, 'service:' || p_invoice_id::text),
         updated_by = auth.uid()
   where id = p_invoice_id;

  -- The job card is billed, which is what closes it to further work.
  if v_invoice.job_card_id is not null then
    update public.job_cards
       set status = 'INVOICED', updated_by = auth.uid()
     where id = v_invoice.job_card_id;
  end if;

  return v_entry;
end;
$$;

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------
-- create or replace preserves the grants on the public functions above; the new
-- app helper needs its own.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function app.record_money_movement(uuid, uuid, date, text, text, numeric, text, text, uuid, uuid) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0050_party_payment_allocation.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0050 — Bill-wise settlement: splitting a receipt across the bills it pays
-- =============================================================================
-- Spec §11, §21, §22, §23, §41, §49, §50, §60.24.
--
-- What is missing today. A cashier takes ₹50,000 from a customer and records it
-- through the cash book. That posts one credit to the customer's account, and
-- the customer ledger then shows a column of invoices on the debit side and a
-- column of receipts on the credit side with nothing connecting them. The
-- closing balance is right — it has always been right, it comes from the general
-- ledger — but the balance is the only thing the ledger can answer. It cannot say
-- WHICH invoices are still unpaid, which is the question a dealer actually asks
-- when they ring a customer.
--
-- That connection is the accountant's job, and it is a real step in the day's
-- procedure: the cashier records the money as it arrives, and Accounts then
-- allocates it against the bills it settles. This migration gives that step a
-- place to be recorded.
--
-- ── The design ──────────────────────────────────────────────────────────────
--
-- An allocation joins two JOURNAL LINES, not two business documents:
--
--     debit line (a bill)  ←── amount ──→  credit line (a receipt)
--
-- Everything that can ever reach a party ledger is already a party-tagged
-- journal line — a vehicle invoice, a service bill, a counter sale, a booking
-- advance, a cash receipt, a bank receipt, an opening balance, a hand-written
-- journal. Settling at line level therefore covers all of them without this
-- table ever learning what a sale or a job card is, and — the property that
-- matters — it settles against the exact rows the ledger is drawn from. So:
--
--     Σ unpaid bills  −  Σ unapplied receipts  =  the ledger closing balance
--
-- holds by construction rather than by reconciliation. That identity is what
-- "tallying the ledger" means here, and public.party_open_items() below returns
-- the two sides of it.
--
-- A credit may be knocked off against a debit in a different control account on
-- purpose: a booking advance sits in 2100 (Customer Advances) and the invoice it
-- pays for sits in 1200 (Customer Receivable). Refusing that would make the
-- commonest case in the business unrecordable.
--
-- ── What this does NOT do ───────────────────────────────────────────────────
--
-- It posts nothing. No journal is written, amended or reversed; posted entries
-- stay immutable (spec §23, §60.12, §60.23). An allocation is a statement about
-- entries that already exist, so getting one wrong costs nothing but re-doing
-- it, and no accounting figure anywhere moves when it changes.
--
-- Rollback: drop function public.allocate_party_payment(uuid, jsonb, text);
--           drop function public.party_open_items(text, uuid, boolean);
--           drop table public.party_allocations;
--           drop function app.party_allocations_guard();
--           alter table public.journal_entry_lines drop constraint jel_id_dealer_key;
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A journal line becomes addressable by a composite tenant key
-- -----------------------------------------------------------------------------
-- Every table in this schema that points at another carries (id, dealer_id)
-- rather than id alone, so a foreign key cannot cross a tenant boundary even if
-- the application asks it to. journal_entry_lines had never been the target of
-- one and so never needed the key; it is one now.
-- -----------------------------------------------------------------------------
alter table public.journal_entry_lines
  add constraint jel_id_dealer_key unique (id, dealer_id);

-- -----------------------------------------------------------------------------
-- party_allocations — which receipt paid which bill, and how much of it
-- -----------------------------------------------------------------------------
create table public.party_allocations (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null references public.dealers (id) on delete restrict,

  -- Denormalised from the two lines so the common query — "everything for this
  -- customer" — is one index lookup rather than a join through the journal. The
  -- guard below refuses any row where these disagree with the lines.
  party_type     text not null,
  party_id       uuid not null,

  -- The bill being settled, and the money settling it.
  debit_line_id  uuid not null,
  credit_line_id uuid not null,

  amount         numeric(18, 4) not null,

  note           text,

  created_at     timestamptz not null default now(),
  created_by     uuid,

  -- One link per pair. A second allocation between the same bill and the same
  -- receipt is not a second fact, it is the first one written twice (spec §50).
  constraint party_allocations_pair_key unique (debit_line_id, credit_line_id),

  constraint party_allocations_debit_tenant_fkey
    foreign key (debit_line_id, dealer_id)
    references public.journal_entry_lines (id, dealer_id) on delete cascade,
  constraint party_allocations_credit_tenant_fkey
    foreign key (credit_line_id, dealer_id)
    references public.journal_entry_lines (id, dealer_id) on delete cascade,

  constraint party_allocations_amount_check check (amount > 0),
  constraint party_allocations_distinct_lines_check check (debit_line_id <> credit_line_id),
  constraint party_allocations_party_type_check check (
    party_type in ('CUSTOMER', 'SUPPLIER', 'FINANCE_COMPANY', 'EMPLOYEE')
  )
);

comment on table public.party_allocations is
  'Bill-wise settlement (spec §41): links a credit journal line to the debit '
  'lines it pays. Posts nothing — journals stay immutable (spec §23) — so the '
  'subsidiary ledger keeps its balance and gains the detail behind it.';
comment on column public.party_allocations.party_type is
  'Copied from both lines and verified against them by app.party_allocations_guard().';

create index party_allocations_party_idx
  on public.party_allocations (dealer_id, party_type, party_id);
create index party_allocations_debit_idx  on public.party_allocations (debit_line_id);
create index party_allocations_credit_idx on public.party_allocations (credit_line_id);

-- The cash and bank books have always been reachable from a transaction to its
-- journal and never the other way round. party_open_items() below needs the
-- reverse, to put the cashier's own slip number on the row.
create index if not exists cash_transactions_journal_idx
  on public.cash_transactions (journal_entry_id) where journal_entry_id is not null;
create index if not exists bank_transactions_journal_idx
  on public.bank_transactions (journal_entry_id) where journal_entry_id is not null;

-- -----------------------------------------------------------------------------
-- app.party_allocations_guard() — the rules an allocation has to obey
-- -----------------------------------------------------------------------------
-- Five of them, and every one is a way an allocation could otherwise make the
-- ledger lie:
--
--   1. the bill side is a debit line and the payment side is a credit line;
--   2. both belong to the same party as the allocation claims;
--   3. both belong to entries that are actually in the ledger;
--   4. a bill cannot be settled for more than it is worth;
--   5. a receipt cannot be spread over more than it was.
--
-- SECURITY DEFINER so it can lock the two lines regardless of the caller's RLS
-- view of them; because it therefore bypasses RLS, it verifies the tenant of
-- every row it reads rather than assuming a policy already did.
-- -----------------------------------------------------------------------------
create or replace function app.party_allocations_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_debit    record;
  v_credit   record;
  v_taken    numeric(18, 4);
  v_headroom numeric(18, 4);
begin
  -- FOR UPDATE, not a plain read. Two accountants splitting two different
  -- receipts against the same invoice would otherwise both see the same
  -- headroom and both pass check 4, leaving the bill over-settled (spec §49).
  -- The lock is taken on the bill first and the receipt second, in that order,
  -- by every path into this table — so two concurrent splits queue rather than
  -- deadlock.
  select l.dealer_id, l.debit, l.credit, l.party_type, l.party_id,
         je.status, je.entry_number
    into v_debit
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.id = new.debit_line_id
     for no key update of l;

  if not found then
    raise exception 'The bill being settled no longer exists.'
      using errcode = 'no_data_found';
  end if;

  select l.dealer_id, l.debit, l.credit, l.party_type, l.party_id,
         je.status, je.entry_number
    into v_credit
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.id = new.credit_line_id
     for no key update of l;

  if not found then
    raise exception 'The receipt being split no longer exists.'
      using errcode = 'no_data_found';
  end if;

  -- 1. Sides. A journal line is one-sided by constraint, so this also rules out
  --    settling a bill with a bill or a receipt with a receipt.
  if v_debit.debit <= 0 then
    raise exception 'Entry % is not a bill: only a debit can be settled.', v_debit.entry_number
      using errcode = 'check_violation';
  end if;
  if v_credit.credit <= 0 then
    raise exception 'Entry % is not a payment: only a credit can settle a bill.', v_credit.entry_number
      using errcode = 'check_violation';
  end if;

  -- 2. Party, and with it the tenant. A split that reached across two customers
  --    would settle one person's bill with another person's money and leave
  --    both ledgers wrong.
  if v_debit.dealer_id <> new.dealer_id or v_credit.dealer_id <> new.dealer_id then
    raise exception 'A settlement cannot cross dealers.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_debit.party_type is distinct from new.party_type
     or v_debit.party_id is distinct from new.party_id
     or v_credit.party_type is distinct from new.party_type
     or v_credit.party_id is distinct from new.party_id then
    raise exception 'A payment can only be set against the same party''s own bills.'
      using errcode = 'check_violation';
  end if;

  -- 3. In the ledger. Both statuses are accepted because both are what
  --    public.party_ledger() reads: a reversed entry and its reversal are
  --    still on the statement, netting to nothing.
  if v_debit.status not in ('POSTED', 'REVERSED')
     or v_credit.status not in ('POSTED', 'REVERSED') then
    raise exception 'Only posted entries can be settled against each other.'
      using errcode = 'check_violation';
  end if;

  -- 4. The bill's remaining headroom.
  select coalesce(sum(a.amount), 0) into v_taken
    from public.party_allocations a
   where a.debit_line_id = new.debit_line_id
     and a.id <> new.id;

  v_headroom := round(v_debit.debit - v_taken, 4);
  if round(new.amount, 4) > v_headroom then
    raise exception 'Bill % has only % left to settle; % was allocated to it.',
      v_debit.entry_number, v_headroom, new.amount
      using errcode = 'check_violation';
  end if;

  -- 5. The receipt's remaining headroom.
  select coalesce(sum(a.amount), 0) into v_taken
    from public.party_allocations a
   where a.credit_line_id = new.credit_line_id
     and a.id <> new.id;

  v_headroom := round(v_credit.credit - v_taken, 4);
  if round(new.amount, 4) > v_headroom then
    raise exception 'Payment % has only % left to allocate; % was set against a bill.',
      v_credit.entry_number, v_headroom, new.amount
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

comment on function app.party_allocations_guard() is
  'Refuses any settlement that would make a party ledger disagree with itself: '
  'wrong side, wrong party, unposted entry, over-settled bill, over-spread payment.';

create trigger party_allocations_guard
  before insert or update on public.party_allocations
  for each row execute function app.party_allocations_guard();

create trigger party_allocations_audit
  after insert or update or delete on public.party_allocations
  for each row execute function app.audit_trigger();

-- -----------------------------------------------------------------------------
-- Row Level Security
-- -----------------------------------------------------------------------------
-- Reading a settlement is part of reading the ledger, so it follows the same
-- permissions the two ledgers do. Writing one is an accounting act and has a
-- permission of its own: a cashier records the money, Accounts decides what it
-- pays for (spec §6).
-- -----------------------------------------------------------------------------
alter table public.party_allocations enable row level security;

create policy party_allocations_select on public.party_allocations
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and (app.has_permission('accounting.ledgers.view')
             or app.has_permission('customers.view_ledger')
             or app.has_permission('masters.suppliers.view')))
  );

create policy party_allocations_insert on public.party_allocations
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.has_permission('accounting.allocations.manage'))
  );

-- Deletable, unlike almost everything else in this schema. An allocation is not
-- an accounting entry — nothing was posted and nothing is reversed by removing
-- one — so the correction mechanism for a wrong split is to unpick it, and the
-- audit trigger above records that it happened.
create policy party_allocations_delete on public.party_allocations
  for delete to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.has_permission('accounting.allocations.manage'))
  );

-- No UPDATE policy: public.allocate_party_payment() rewrites a receipt's split
-- wholesale, which keeps "what is this receipt against" a single decision rather
-- than a set of rows edited one at a time.

-- -----------------------------------------------------------------------------
-- public.party_open_items() — the two sides of the tally
-- -----------------------------------------------------------------------------
-- Every party-tagged line, with how much of it has been settled. Invoker-rights,
-- exactly like public.party_ledger(), so this view and the statement can never
-- show a user two different sets of rows.
-- -----------------------------------------------------------------------------
create or replace function public.party_open_items(
  p_party_type      text,
  p_party_id        uuid,
  p_include_settled boolean default false
)
returns table (
  line_id       uuid,
  entry_id      uuid,
  entry_date    date,
  entry_number  text,
  document_type text,
  document_ref  text,
  account_code  text,
  account_name  text,
  particulars   text,
  side          text,
  amount        numeric(18, 4),
  allocated     numeric(18, 4),
  outstanding   numeric(18, 4),
  age_days      integer
)
language sql
stable
as $$
  select l.id,
         je.id,
         je.entry_date,
         je.entry_number,
         je.source_document_type,
         -- The dealer knows this bill as "INV-2026-000042", not as the journal
         -- number the posting engine gave it. The cash and bank cases look the
         -- document up by journal rather than by id, because those two modules
         -- record the movement in their own book and leave source_document_id
         -- null — and a receipt the cashier can find by its slip number is the
         -- whole point of this screen. Falls back to the entry number for
         -- anything with no business document behind it — an opening balance, a
         -- manual journal — and for documents this user may not read.
         coalesce(
           case je.source_document_type
             when 'SALE' then
               (select s.invoice_number from public.sales s where s.id = je.source_document_id)
             when 'SERVICE_INVOICE' then
               (select si.invoice_number from public.service_invoices si where si.id = je.source_document_id)
             when 'BOOKING' then
               (select b.booking_number from public.bookings b where b.id = je.source_document_id)
             when 'CASH_BOOK' then
               (select ct.reference_number from public.cash_transactions ct
                 where ct.journal_entry_id = je.id and ct.reference_number is not null limit 1)
             when 'BANK_BOOK' then
               (select bt.reference_number from public.bank_transactions bt
                 where bt.journal_entry_id = je.id and bt.reference_number is not null limit 1)
           end,
           je.entry_number
         ),
         coa.code,
         coa.name,
         coalesce(l.narration, je.narration),
         case when l.debit > 0 then 'DEBIT' else 'CREDIT' end,
         greatest(l.debit, l.credit),
         coalesce(a.allocated, 0),
         round(greatest(l.debit, l.credit) - coalesce(a.allocated, 0), 4),
         (current_date - je.entry_date)::integer
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
    join public.chart_of_accounts coa on coa.id = l.account_id
    left join lateral (
      -- A line is one-sided, so at most one of the two columns can match it.
      select sum(pa.amount) as allocated
        from public.party_allocations pa
       where pa.debit_line_id = l.id or pa.credit_line_id = l.id
    ) a on true
   where l.party_type = p_party_type
     and l.party_id = p_party_id
     and je.status in ('POSTED', 'REVERSED')
     and (p_include_settled
          or round(greatest(l.debit, l.credit) - coalesce(a.allocated, 0), 4) <> 0)
   order by je.entry_date, je.entry_number, l.line_number;
$$;

comment on function public.party_open_items(text, uuid, boolean) is
  'Bills and payments with their settled and unsettled portions (spec §41). '
  'Unpaid bills less unapplied payments equals the ledger closing balance.';

-- -----------------------------------------------------------------------------
-- public.allocate_party_payment() — record how one payment was split
-- -----------------------------------------------------------------------------
-- Takes the whole split for one payment, not one line of it:
--
--   [{"debit_line_id": "…", "amount": 12000}, {"debit_line_id": "…", "amount": 8000}]
--
-- Replacing the set rather than appending to it makes the call idempotent — the
-- same submission twice leaves the same rows (spec §50) — and makes "what is
-- this receipt against" one decision the accountant can revise as a whole. An
-- empty array clears the split and returns the money to unapplied.
-- -----------------------------------------------------------------------------
create or replace function public.allocate_party_payment(
  p_credit_line_id uuid,
  p_allocations    jsonb default '[]'::jsonb,
  p_note           text default null
)
returns table (allocated numeric(18, 4), unapplied numeric(18, 4), bills integer)
language plpgsql
as $$
declare
  v_line  record;
  v_alloc record;
  v_count integer := 0;
  v_total numeric(18, 4) := 0;
begin
  if jsonb_typeof(p_allocations) <> 'array' then
    raise exception 'The split must be a list of bills and amounts.'
      using errcode = 'invalid_parameter_value';
  end if;

  select l.dealer_id, l.credit, l.party_type, l.party_id, je.status, je.entry_number
    into v_line
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.id = p_credit_line_id;

  -- Not found also covers "exists but this user may not read it": RLS makes the
  -- two indistinguishable here, which is the intent.
  if not found then
    raise exception 'That payment could not be found.' using errcode = 'no_data_found';
  end if;
  if v_line.credit <= 0 then
    raise exception 'Entry % is not a payment; only money received can be split.', v_line.entry_number
      using errcode = 'check_violation';
  end if;
  if v_line.party_type is null then
    raise exception 'Entry % is not attributed to a customer or supplier, so there is nothing to settle.',
      v_line.entry_number using errcode = 'check_violation';
  end if;

  -- The previous split goes first, so the headroom checks in the guard see the
  -- world as it will be and a re-submission of the same split is not read as a
  -- doubling of it.
  delete from public.party_allocations where credit_line_id = p_credit_line_id;

  for v_alloc in
    select (e ->> 'debit_line_id')::uuid as debit_line_id,
           round(sum((e ->> 'amount')::numeric), 4) as amount
      from jsonb_array_elements(p_allocations) e
     where nullif(e ->> 'debit_line_id', '') is not null
     group by 1
    having round(sum((e ->> 'amount')::numeric), 4) > 0
  loop
    insert into public.party_allocations
      (dealer_id, party_type, party_id, debit_line_id, credit_line_id, amount, note, created_by)
    values
      (v_line.dealer_id, v_line.party_type, v_line.party_id,
       v_alloc.debit_line_id, p_credit_line_id, v_alloc.amount,
       nullif(btrim(p_note), ''), auth.uid());

    v_count := v_count + 1;
    v_total := v_total + v_alloc.amount;
  end loop;

  allocated := v_total;
  unapplied := round(v_line.credit - v_total, 4);
  bills     := v_count;
  return next;
end;
$$;

comment on function public.allocate_party_payment(uuid, jsonb, text) is
  'Records the whole of one payment''s bill-wise split, replacing any earlier '
  'one (spec §41, §50). Writes no journal: posted entries are immutable (spec §23).';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, delete on public.party_allocations to authenticated';
    execute 'grant all on public.party_allocations to service_role';
    execute 'grant execute on function public.party_open_items(text, uuid, boolean) to authenticated';
    execute 'grant execute on function public.allocate_party_payment(uuid, jsonb, text) to authenticated';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- The permission that gates the split
-- -----------------------------------------------------------------------------
-- Inserted here as well as in seed.sql so a database that is upgraded rather
-- than re-seeded gains it, and so the ACCOUNTS and DEALER_OWNER roles — which
-- are granted the accounting module wholesale — pick it up.
-- -----------------------------------------------------------------------------
insert into public.permissions (code, module, description, is_sensitive) values
  ('accounting.allocations.manage', 'accounting',
   'Split payments against bills and settle party ledgers', false)
on conflict (code) do update
  set module      = excluded.module,
      description = excluded.description;

insert into public.role_permissions (role_id, permission_code)
select r.id, 'accounting.allocations.manage'
  from public.roles r
 where r.is_system and r.code in ('DEALER_OWNER', 'ACCOUNTS')
on conflict do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0051_sale_return_refund.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0051 — A sales return can refund the money it takes back
-- =============================================================================
-- Spec §19, §21, §23, §34, §36, §37, §38, §48, §59.
--
-- public.return_vehicle_sale() from 0036 refuses outright when anything has been
-- received against the invoice:
--
--     Invoice INV-… has 50000.0000 received against it. Refund it before
--     returning the sale.
--
-- Sound advice, except that there has never been anywhere in the product to do
-- it. A cash refund against a sale is not a cash-book payment (that would credit
-- cash and debit nothing meaningful), it is not a booking refund (0046 handles
-- only bookings), and the sale screens offer no such action. So every sale a
-- customer had paid for was unreturnable — which is most of them, and exactly
-- the ones a dealer actually needs to return.
--
-- The stock half already worked and is unchanged below: the vehicle goes back to
-- IN_STOCK through app.vehicles_log_movement(), and fitted accessories return to
-- the lot — LOCAL or COMPANY — that they were consumed from (spec §28, §31, §34).
--
-- ── The accounting ──────────────────────────────────────────────────────────
--
-- Three postings, one transaction (spec §48). Taking a ₹65,000 invoice with
-- ₹50,000 received:
--
--   1. the sale journal is reversed          Dr Revenue/Tax  Cr Receivable  65,000
--      leaving the customer ₹50,000 in credit — the dealer is holding money for
--      a sale that no longer exists;
--   2. the refund pays it back               Dr Receivable   Cr Cash/Bank   50,000
--      clearing the customer to nil and taking the notes out of the drawer;
--   3. the receipts are marked REVERSED, so sales.paid_amount falls to zero
--      through the trigger in 0020 rather than being written directly.
--
-- Refunding less than was received is allowed and does something specific: the
-- difference stays as a credit on the customer's ledger, visible as an
-- unallocated receipt in the bill-wise settlement view (0050). It is NOT quietly
-- turned into income — a retained cancellation charge is a decision someone has
-- to make and post, not a rounding of a refund.
--
-- The refund reaches the cash book or the bank book by writing the subsidiary
-- row alongside the journal, which is the rule 0049 established: money that
-- moves and is absent from the book that itemises it makes the day-close
-- meaningless (spec §36, §37, §38).
--
-- DROPped and recreated rather than replaced: the function gains parameters and
-- returns a row instead of a uuid, and `create or replace` can do neither.
-- Leaving both signatures in place would make supabase.rpc() ambiguous at
-- runtime and emit a duplicate key from scripts/generate-types.mjs.
--
-- Rollback: restore public.return_vehicle_sale(uuid, text) from 0036 and its grant.
-- =============================================================================

drop function if exists public.return_vehicle_sale(uuid, text);

create function public.return_vehicle_sale(
  p_sale_id         uuid,
  p_reason          text,
  -- 'CASH', 'BANK', or null when nothing was received and nothing is going back.
  p_refund_mode     text    default null,
  -- Defaults to everything received. Less is allowed; more is not.
  p_refund_amount   numeric default null,
  p_bank_account_id uuid    default null,
  -- The cheque number, UTR or voucher the money went out on.
  p_reference       text    default null,
  p_date            date    default current_date
)
returns table (
  reversal_entry_id uuid,
  refund_entry_id   uuid,
  refunded          numeric(18, 4),
  credit_left       numeric(18, 4)
)
language plpgsql
as $$
declare
  v_sale     public.sales;
  v_entry    uuid;
  v_refund   uuid;
  v_alloc    record;
  v_received numeric(18, 4);
  v_amount   numeric(18, 4);
  v_debit    uuid;
  v_credit   uuid;
  v_cash     public.cash_accounts;
  v_bank     public.bank_accounts;
  v_branch   uuid;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A sales return requires a reason.'
      using errcode = 'check_violation',
            hint = 'Spec §21: the reason is part of the record, not optional.';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;

  if v_sale.id is null then
    raise exception 'Sale not found.' using errcode = 'no_data_found';
  end if;
  if v_sale.status <> 'POSTED' then
    raise exception 'Invoice % is % — only a posted, undelivered sale can be returned.',
      v_sale.invoice_number, v_sale.status using errcode = 'check_violation';
  end if;

  -- What the customer actually paid. sales.paid_amount excludes FINANCE by
  -- construction (the trigger in 0020 splits the two), so money disbursed by a
  -- finance company is not refunded in cash here — that is a settlement with the
  -- financier, not a refund to the customer.
  v_received := coalesce(v_sale.paid_amount, 0);
  v_amount   := round(coalesce(p_refund_amount, v_received), 4);

  if v_received > 0 and coalesce(p_refund_mode, '') = '' then
    raise exception
      'Invoice % has % received against it. Say how it is being refunded — cash or bank.',
      v_sale.invoice_number, v_received
      using errcode = 'check_violation';
  end if;
  if v_amount > v_received then
    raise exception 'Only % was received against %; % cannot be refunded.',
      v_received, v_sale.invoice_number, v_amount
      using errcode = 'check_violation';
  end if;
  if v_amount < 0 then
    raise exception 'A refund cannot be negative.' using errcode = 'check_violation';
  end if;
  if p_refund_mode is not null and p_refund_mode not in ('CASH', 'BANK') then
    raise exception 'A refund is paid in cash or from a bank account; got %.', p_refund_mode
      using errcode = 'check_violation';
  end if;

  -- ── 1. Reverse the invoice ─────────────────────────────────────────────────
  -- The original is never edited or deleted; a second entry undoes it and
  -- carries the reason (spec §23, §60.12, §60.13).
  v_entry := app.reverse_journal(v_sale.journal_entry_id, btrim(p_reason), p_date);

  -- ── 2. Pay the money back ──────────────────────────────────────────────────
  if v_amount > 0 then
    -- The same receivable the invoice and its receipts used, so the customer's
    -- subsidiary ledger closes to nil rather than to two offsetting balances in
    -- different accounts.
    v_debit := app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'RECEIVABLE', v_sale.branch_id);

    if p_refund_mode = 'CASH' then
      select * into v_cash from public.cash_accounts where branch_id = v_sale.branch_id;
      if v_cash.id is null then
        raise exception 'This branch has no cash account, so a cash refund cannot be paid.'
          using errcode = 'no_data_found';
      end if;
      v_branch := v_sale.branch_id;
      v_credit := v_cash.ledger_account_id;
      -- A closed day cannot take a movement, in or out (spec §36).
      perform public.ensure_cash_day(v_branch, p_date);
    else
      select * into v_bank from public.bank_accounts where id = p_bank_account_id;
      if v_bank.id is null then
        raise exception 'Choose the bank account the refund is being paid from.'
          using errcode = 'no_data_found';
      end if;
      if v_bank.dealer_id <> v_sale.dealer_id then
        raise exception 'That bank account belongs to another dealer.'
          using errcode = 'insufficient_privilege';
      end if;
      v_branch := coalesce(v_bank.branch_id, v_sale.branch_id);
      v_credit := v_bank.ledger_account_id;
    end if;

    v_refund := app.post_journal(
      v_sale.dealer_id, v_branch, p_date, 'SALES',
      'Refund on return of ' || v_sale.invoice_number,
      jsonb_build_array(
        jsonb_build_object('account_id', v_debit, 'debit', v_amount, 'credit', 0,
                           'narration', btrim(p_reason),
                           'party_type', 'CUSTOMER', 'party_id', v_sale.customer_id),
        jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', v_amount,
                           'narration', 'Refund ' || v_sale.invoice_number)
      ),
      'SALE_RETURN', p_sale_id,
      -- One refund per return, however many times the button is pressed (spec §50).
      'sale-return-refund:' || p_sale_id::text
    );

    -- The book that itemises the movement, not just the ledger that totals it.
    if p_refund_mode = 'CASH' then
      insert into public.cash_transactions
        (dealer_id, branch_id, cash_account_id, business_date, direction, amount,
         particular, reference_number, customer_id, journal_entry_id, created_by)
      values
        (v_sale.dealer_id, v_branch, v_cash.id, p_date, 'PAYMENT', v_amount,
         'Sales return refund ' || v_sale.invoice_number, nullif(btrim(p_reference), ''),
         v_sale.customer_id, v_refund, auth.uid());
    else
      insert into public.bank_transactions
        (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
         reference_number, customer_id, journal_entry_id, created_by)
      values
        (v_sale.dealer_id, p_bank_account_id, p_date, 'PAYMENT', v_amount,
         'Sales return refund ' || v_sale.invoice_number, nullif(btrim(p_reference), ''),
         v_sale.customer_id, v_refund, auth.uid());
    end if;
  end if;

  -- ── 3. The receipts are no longer live ─────────────────────────────────────
  -- Marked, not deleted. sales.paid_amount falls out of the trigger in 0020
  -- rather than being written here, so the figure and its evidence cannot
  -- disagree. FINANCE rows are left alone: that money came from the financier.
  update public.sale_payments
     set status = 'REVERSED'
   where sale_id = p_sale_id and status = 'RECEIVED' and payment_mode <> 'FINANCE';

  -- ── 4. The stock comes back ────────────────────────────────────────────────
  -- Each accessory returns to the lot it was consumed from, so the LOCAL and
  -- COMPANY split stays true (spec §28, §31, §60.16).
  for v_alloc in
    select t.item_id, t.source, -t.quantity as qty, t.unit_cost
      from public.inventory_transactions t
     where t.reference_type = 'SALE' and t.reference_id = p_sale_id and t.quantity < 0
  loop
    insert into public.inventory_transactions
      (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
       reference_type, reference_id, narration, reason, created_by)
    values
      (v_sale.dealer_id, v_sale.branch_id, v_alloc.item_id, v_alloc.source, 'RETURN',
       v_alloc.qty, v_alloc.unit_cost, 'SALE_RETURN', p_sale_id,
       'Returned from ' || v_sale.invoice_number, btrim(p_reason), auth.uid());
  end loop;

  update public.sales
     set status = 'RETURNED', updated_by = auth.uid(), notes =
           coalesce(notes || E'\n', '') || 'Returned: ' || btrim(p_reason)
   where id = p_sale_id;

  -- The RETURN ledger row is written by app.vehicles_log_movement(), which reads
  -- this setting to record what the movement was for.
  perform set_config('app.vehicle_movement_ref', 'SALE_RETURN:' || p_sale_id, true);

  update public.vehicles
     set status = 'IN_STOCK', updated_by = auth.uid()
   where id = v_sale.vehicle_id;

  perform set_config('app.vehicle_movement_ref', '', true);

  reversal_entry_id := v_entry;
  refund_entry_id   := v_refund;
  refunded          := v_amount;
  -- What the dealer still holds for this customer: received, less refunded. Not
  -- income until someone posts it as income.
  credit_left       := round(v_received - v_amount, 4);
  return next;
end;
$$;

comment on function public.return_vehicle_sale(uuid, text, text, numeric, uuid, text, date) is
  'Returns a posted sale (spec §21): reverses the invoice, refunds what was '
  'received through the cash or bank book, reverses the receipts and puts the '
  'vehicle and its fitted accessories back into stock. One transaction (spec §48).';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.return_vehicle_sale(uuid, text, text, numeric, uuid, text, date) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0052_purchases.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0052 — Purchase bills: how stock and the payable get onto the books
-- =============================================================================
-- Spec §21, §22, §24, §28, §29, §34, §41, §44, §45, §48, §50, §59, §60.22.
--
-- The hole this fills. Migration 0027 seeded accounting rules for
-- INVENTORY/PURCHASE — inventory debit, payable credit — and in the two years of
-- migrations since, nothing has ever posted them. There is no purchase document
-- in the product at all. So:
--
--   * stock arrives through the CSV uploads (spec §14) which create the chassis
--     and the quantity but write no journal, so 1500/1600/1700 are never
--     debited — only credited, by COGS when the thing is sold;
--   * account 2200 Supplier Payables is only ever debited, by cash and bank
--     payments tagged to a supplier (0041). A supplier's subsidiary ledger has
--     the payments and none of the bills they pay;
--   * there is nowhere to record input GST, so no ITC is tracked. The chart of
--     accounts has Output CGST/SGST/IGST and no input counterpart.
--
-- A dealer running this today has a balance sheet where inventory drifts
-- negative with every sale and a supplier ledger that reads as though every
-- supplier owes the dealer money.
--
-- ── The document ────────────────────────────────────────────────────────────
--
-- One bill, three kinds of line, matching the three stock accounts:
--
--     VEHICLE   → 1500 Vehicle Inventory      (chassis-level, spec §13)
--     ACCESSORY → 1600 Accessories Inventory  (quantity, LOCAL/COMPANY lot §28)
--     SPARE     → 1700 Spare Inventory        (quantity, §29)
--     input GST → 1900/1910/1920              (added below)
--     total     → 2200 Supplier Payables, tagged with the supplier
--
-- Vehicle lines POINT AT a chassis the CSV upload already created rather than
-- creating one. Spec §14 makes the upload the way vehicle stock is registered,
-- and a second door into the same table is how the same chassis ends up in stock
-- twice. A unique index makes a vehicle billable exactly once, so the "not yet
-- billed" list is a fact rather than a convention.
--
-- Accessory and spare lines are the opposite: those items are counted, not
-- identified, so the bill CREATES the PURCHASE movement (spec §34 — quantity is
-- never written directly, it follows from movements).
--
-- ── Draft, then posted ──────────────────────────────────────────────────────
--
-- A bill is built as a DRAFT and edited freely. Posting is the moment it becomes
-- accounting: one transaction writes the journal, capitalises the vehicles,
-- moves the stock and freezes the bill (spec §48). After that it is immutable
-- and corrected only by reversal (spec §23).
--
-- Rollback: drop function public.post_purchase_bill(uuid, text);
--           drop function public.cancel_purchase_bill(uuid, text);
--           drop table public.purchase_bill_lines, public.purchase_bills;
--           drop function app.purchase_bills_assign_number(), app.purchase_bills_guard(),
--                         app.purchase_bill_lines_sync_totals(), app.seed_purchase_accounting_rules(uuid);
--           delete from public.chart_of_accounts where code in ('1900','1910','1920');
--           delete from public.document_sequences where doc_type = 'PURCHASE_BILL';
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Input GST — the asset side of the tax the dealer pays on a purchase
-- -----------------------------------------------------------------------------
-- Input tax credit is money the government owes back, so these are assets, and
-- they are deliberately NOT branch-scoped: a GST registration is per state, not
-- per showroom, and the return is filed on the registration.
-- -----------------------------------------------------------------------------
do $$
declare
  d      record;
  a      record;
  v_parent uuid;
begin
  for d in select id from public.dealers loop
    select id into v_parent from public.chart_of_accounts
     where dealer_id = d.id and code = '1000';

    for a in
      select * from (values
        ('1900', 'Input CGST'),
        ('1910', 'Input SGST'),
        ('1920', 'Input IGST')
      ) as t(code, name)
    loop
      insert into public.chart_of_accounts
        (dealer_id, code, name, account_type, normal_balance, is_group, parent_id,
         is_system, is_branch_scoped)
      values
        (d.id, a.code, a.name, 'ASSET', 'DEBIT', false, v_parent, true, false)
      on conflict on constraint coa_dealer_code_key do nothing;
    end loop;
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- The accounting rules a purchase resolves through
-- -----------------------------------------------------------------------------
-- Accounts are never hard-coded (spec §22); the posting function asks for a
-- component and the rule says which account that is for this dealer. 0027
-- already mapped INVENTORY / PURCHASE / INVENTORY, PAYABLE and VEHICLE_INVENTORY;
-- these are the ones it was missing.
-- -----------------------------------------------------------------------------
create or replace function app.seed_purchase_accounting_rules(p_dealer_id uuid)
returns integer
language plpgsql
as $$
declare
  v_added   integer := 0;
  v_rule    record;
  v_account uuid;
begin
  for v_rule in
    select * from (values
      ('INVENTORY', 'PURCHASE', 'ACCESSORY_INVENTORY', 'DEBIT', '1600'),
      ('INVENTORY', 'PURCHASE', 'SPARE_INVENTORY',     'DEBIT', '1700'),
      ('INVENTORY', 'PURCHASE', 'INPUT_CGST',          'DEBIT', '1900'),
      ('INVENTORY', 'PURCHASE', 'INPUT_SGST',          'DEBIT', '1910'),
      ('INVENTORY', 'PURCHASE', 'INPUT_IGST',          'DEBIT', '1920')
    ) as t(module, event, component, side, account_code)
  loop
    select id into v_account from public.chart_of_accounts
     where dealer_id = p_dealer_id and code = v_rule.account_code;
    continue when v_account is null;

    insert into public.accounting_rules
      (dealer_id, module, event, component, side, account_id, description)
    values
      (p_dealer_id, v_rule.module, v_rule.event, v_rule.component, v_rule.side,
       v_account, 'Purchase bills (0052)')
    on conflict do nothing;

    if found then v_added := v_added + 1; end if;
  end loop;

  return v_added;
end;
$$;

do $$
declare d record;
begin
  for d in select id from public.dealers loop
    perform app.seed_purchase_accounting_rules(d.id);
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- purchase_bills
-- -----------------------------------------------------------------------------
create table public.purchase_bills (
  id                  uuid primary key default gen_random_uuid(),
  dealer_id           uuid not null references public.dealers (id) on delete restrict,
  branch_id           uuid not null,

  -- Ours, for the audit trail and the document register (spec §45).
  bill_number         text not null,
  -- Theirs. Two suppliers may legitimately use the same number, so this is
  -- unique per supplier rather than per dealer.
  supplier_bill_number text not null,

  supplier_id         uuid not null,
  bill_date           date not null default current_date,
  due_date            date,

  status              text not null default 'DRAFT',

  -- Maintained from the lines by trigger; never written by the client.
  taxable_value       numeric(18, 4) not null default 0,
  cgst_amount         numeric(18, 4) not null default 0,
  sgst_amount         numeric(18, 4) not null default 0,
  igst_amount         numeric(18, 4) not null default 0,
  total_amount        numeric(18, 4) not null default 0,

  notes               text,
  journal_entry_id    uuid,

  posted_at           timestamptz,
  posted_by           uuid,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid,
  updated_by          uuid,

  constraint purchase_bills_number_key    unique (dealer_id, bill_number),
  constraint purchase_bills_id_dealer_key unique (id, dealer_id),
  -- The same bill keyed twice against one supplier is a duplicate, not a second
  -- purchase (spec §50).
  constraint purchase_bills_supplier_ref_key unique (supplier_id, supplier_bill_number),

  constraint purchase_bills_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint purchase_bills_supplier_tenant_fkey
    foreign key (supplier_id, dealer_id) references public.suppliers (id, dealer_id),
  constraint purchase_bills_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),

  constraint purchase_bills_status_check check (status in ('DRAFT', 'POSTED', 'CANCELLED')),
  constraint purchase_bills_amounts_check check (
    taxable_value >= 0 and cgst_amount >= 0 and sgst_amount >= 0
    and igst_amount >= 0 and total_amount >= 0
  ),
  constraint purchase_bills_supplier_ref_shape_check check (
    length(btrim(supplier_bill_number)) between 1 and 50
  ),
  constraint purchase_bills_due_check check (due_date is null or due_date >= bill_date),
  constraint purchase_bills_posted_stamp_check check (
    status <> 'POSTED' or (posted_at is not null and journal_entry_id is not null)
  )
);

comment on table public.purchase_bills is
  'Supplier bill (spec §24, §41). Brings stock onto the balance sheet and the '
  'payable onto the supplier ledger — the entry point 0027''s INVENTORY/PURCHASE '
  'rules were written for and never had.';

create index purchase_bills_supplier_idx on public.purchase_bills (supplier_id, bill_date desc);
create index purchase_bills_dealer_date_idx on public.purchase_bills (dealer_id, bill_date desc);
create index purchase_bills_branch_idx on public.purchase_bills (branch_id, bill_date desc);
create index purchase_bills_status_idx on public.purchase_bills (dealer_id, status);

-- -----------------------------------------------------------------------------
-- purchase_bill_lines
-- -----------------------------------------------------------------------------
create table public.purchase_bill_lines (
  id             uuid primary key default gen_random_uuid(),
  purchase_bill_id uuid not null,
  dealer_id      uuid not null,

  line_number    smallint not null,
  line_type      text not null,

  -- Exactly one of these, according to line_type. A vehicle is identified; an
  -- accessory or spare is counted.
  vehicle_id     uuid,
  item_id        uuid,
  -- Which lot a counted item joins (spec §28, §31). Meaningless for a vehicle.
  source         text,

  description    text not null,
  quantity       numeric(18, 3) not null,
  unit_rate      numeric(18, 4) not null,

  taxable_value  numeric(18, 4) not null,
  cgst_rate      numeric(6, 3) not null default 0,
  sgst_rate      numeric(6, 3) not null default 0,
  igst_rate      numeric(6, 3) not null default 0,
  cgst_amount    numeric(18, 4) not null default 0,
  sgst_amount    numeric(18, 4) not null default 0,
  igst_amount    numeric(18, 4) not null default 0,
  total_amount   numeric(18, 4) not null,

  created_at     timestamptz not null default now(),

  constraint pbl_bill_line_key unique (purchase_bill_id, line_number),
  constraint pbl_bill_tenant_fkey
    foreign key (purchase_bill_id, dealer_id)
    references public.purchase_bills (id, dealer_id) on delete cascade,
  constraint pbl_vehicle_tenant_fkey
    foreign key (vehicle_id, dealer_id) references public.vehicles (id, dealer_id),
  constraint pbl_item_tenant_fkey
    foreign key (item_id, dealer_id) references public.inventory_items (id, dealer_id),

  constraint pbl_type_check check (line_type in ('VEHICLE', 'ACCESSORY', 'SPARE')),
  constraint pbl_source_check check (source is null or source in ('LOCAL', 'COMPANY')),
  -- A vehicle line names a chassis and one of it; a counted line names an item,
  -- a lot and a quantity. Neither shape can borrow the other's columns.
  constraint pbl_shape_check check (
    (line_type = 'VEHICLE'
       and vehicle_id is not null and item_id is null and source is null and quantity = 1)
    or (line_type <> 'VEHICLE'
       and item_id is not null and vehicle_id is null and source is not null and quantity > 0)
  ),
  constraint pbl_amounts_check check (
    unit_rate >= 0 and taxable_value >= 0 and total_amount >= 0
    and cgst_amount >= 0 and sgst_amount >= 0 and igst_amount >= 0
  ),
  -- Intra-state is CGST+SGST, inter-state is IGST. Never both (spec §16).
  constraint pbl_tax_split_check check (
    (igst_amount = 0) or (cgst_amount = 0 and sgst_amount = 0)
  ),
  constraint pbl_line_number_check check (line_number > 0)
);

comment on table public.purchase_bill_lines is
  'What was bought. VEHICLE lines point at a chassis the upload already created '
  '(spec §14); ACCESSORY and SPARE lines create the stock movement (spec §34).';

-- Load-bearing: this is what makes "not yet billed" a fact rather than a habit.
-- One chassis, one purchase line, ever — so no vehicle can be capitalised twice
-- however many drafts are open at once (spec §49, §60.24).
create unique index purchase_bill_lines_vehicle_key
  on public.purchase_bill_lines (vehicle_id) where vehicle_id is not null;

create index purchase_bill_lines_bill_idx on public.purchase_bill_lines (purchase_bill_id);
create index purchase_bill_lines_item_idx on public.purchase_bill_lines (item_id) where item_id is not null;

-- -----------------------------------------------------------------------------
-- The bill's number, issued by the database
-- -----------------------------------------------------------------------------
-- Self-provisioning like the supplier code (0040): a purchase bill must not be
-- unrecordable because nobody configured a sequence first.
-- -----------------------------------------------------------------------------
create or replace function app.purchase_bills_assign_number()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_year text;
begin
  if new.bill_number is not null and btrim(new.bill_number) <> '' then
    return new;
  end if;

  v_year := app.financial_year_token(new.dealer_id, coalesce(new.bill_date, current_date));

  insert into public.document_sequences (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
  values (new.dealer_id, null, 'PURCHASE_BILL', v_year, 'PB', 6)
  on conflict on constraint document_sequences_scope_key do nothing;

  new.bill_number := app.next_document_number(new.dealer_id, null, 'PURCHASE_BILL', v_year);
  return new;
end;
$$;

create trigger purchase_bills_assign_number
  before insert on public.purchase_bills
  for each row execute function app.purchase_bills_assign_number();

-- -----------------------------------------------------------------------------
-- A posted bill is immutable, and lines only move while it is a draft
-- -----------------------------------------------------------------------------
create or replace function app.purchase_bills_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    if old.status <> 'DRAFT' then
      raise exception 'Purchase bill % is % and cannot be deleted.', old.bill_number, old.status
        using errcode = 'insufficient_privilege',
              hint = 'Spec §23: corrections use reversal, not deletion.';
    end if;
    return old;
  end if;

  if tg_op = 'UPDATE' and old.status = 'POSTED' then
    -- Only the reversal linkage the cancel path writes may change.
    if not (new.status = 'CANCELLED'
            and (to_jsonb(new) - 'status' - 'notes' - 'updated_at' - 'updated_by')
                = (to_jsonb(old) - 'status' - 'notes' - 'updated_at' - 'updated_by')) then
      raise exception 'Purchase bill % is POSTED and immutable.', old.bill_number
        using errcode = 'insufficient_privilege',
              hint = 'Spec §23: post a reversal instead of editing.';
    end if;
  end if;

  if tg_op = 'UPDATE' and old.status = 'CANCELLED' and new.status <> 'CANCELLED' then
    raise exception 'Purchase bill % is cancelled and cannot be reopened.', old.bill_number
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end;
$$;

create trigger purchase_bills_guard
  before update or delete on public.purchase_bills
  for each row execute function app.purchase_bills_guard();

create or replace function app.purchase_bill_lines_sync_totals()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_bill   uuid := coalesce(new.purchase_bill_id, old.purchase_bill_id);
  v_status text;
  v_number text;
begin
  select status, bill_number into v_status, v_number
    from public.purchase_bills where id = v_bill;

  -- Header already gone (ON DELETE CASCADE): let the cascade proceed.
  if v_status is null then
    return coalesce(new, old);
  end if;

  if v_status <> 'DRAFT' then
    raise exception 'Cannot % lines of purchase bill %: it is %.',
      lower(tg_op), v_number, v_status
      using errcode = 'insufficient_privilege';
  end if;

  -- The header's figures follow the lines rather than being sent alongside
  -- them, so a total can never disagree with what it totals.
  update public.purchase_bills b
     set taxable_value = coalesce(t.taxable, 0),
         cgst_amount   = coalesce(t.cgst, 0),
         sgst_amount   = coalesce(t.sgst, 0),
         igst_amount   = coalesce(t.igst, 0),
         total_amount  = coalesce(t.total, 0)
    from (
      select sum(l.taxable_value) as taxable, sum(l.cgst_amount) as cgst,
             sum(l.sgst_amount) as sgst, sum(l.igst_amount) as igst,
             sum(l.total_amount) as total
        from public.purchase_bill_lines l
       where l.purchase_bill_id = v_bill
    ) t
   where b.id = v_bill;

  return coalesce(new, old);
end;
$$;

create trigger purchase_bill_lines_sync
  after insert or update or delete on public.purchase_bill_lines
  for each row execute function app.purchase_bill_lines_sync_totals();

create trigger purchase_bills_set_updated_at
  before update on public.purchase_bills
  for each row execute function app.set_updated_at();

create trigger purchase_bills_audit
  after insert or update or delete on public.purchase_bills
  for each row execute function app.audit_trigger();

-- -----------------------------------------------------------------------------
-- Row Level Security
-- -----------------------------------------------------------------------------
alter table public.purchase_bills      enable row level security;
alter table public.purchase_bill_lines enable row level security;

create policy purchase_bills_select on public.purchase_bills
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and app.has_permission('purchases.view'))
  );

create policy purchase_bills_insert on public.purchase_bills
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and app.has_permission('purchases.create'))
  );

create policy purchase_bills_update on public.purchase_bills
  for update to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and (app.has_permission('purchases.create') or app.has_permission('purchases.post')))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and (app.has_permission('purchases.create') or app.has_permission('purchases.post')))
  );

-- A draft may be abandoned; the trigger above refuses anything further along.
create policy purchase_bills_delete on public.purchase_bills
  for delete to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and app.has_permission('purchases.create'))
  );

create policy purchase_bill_lines_select on public.purchase_bill_lines
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and exists (
          select 1 from public.purchase_bills b
           where b.id = purchase_bill_lines.purchase_bill_id
             and app.can_access_branch(b.branch_id)
        )
        and app.has_permission('purchases.view'))
  );

create policy purchase_bill_lines_write on public.purchase_bill_lines
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('purchases.create'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('purchases.create'))
  );

-- -----------------------------------------------------------------------------
-- public.post_purchase_bill() — the moment a bill becomes accounting
-- -----------------------------------------------------------------------------
-- One transaction (spec §48): journal, vehicle capitalisation, stock movement,
-- status. Any failure leaves the draft exactly as it was.
-- -----------------------------------------------------------------------------
create or replace function public.post_purchase_bill(
  p_bill_id         uuid,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_bill    public.purchase_bills;
  v_line    record;
  v_lines   jsonb := '[]'::jsonb;
  v_entry   uuid;
  v_count   integer;
  v_account uuid;
  v_veh     record;
  v_total   numeric(18, 4);
begin
  select * into v_bill from public.purchase_bills where id = p_bill_id for update;

  if v_bill.id is null then
    raise exception 'Purchase bill not found.' using errcode = 'no_data_found';
  end if;
  -- A repeated submission returns what the first one posted rather than posting
  -- a second time (spec §50), matching post_vehicle_sale and create_counter_invoice.
  -- The check has to be here as well as inside app.post_journal, because the
  -- stock movements below are not idempotent on their own.
  if v_bill.status = 'POSTED' then
    return v_bill.journal_entry_id;
  end if;
  if v_bill.status <> 'DRAFT' then
    raise exception 'Purchase bill % is % and cannot be posted.',
      v_bill.bill_number, v_bill.status using errcode = 'check_violation';
  end if;

  select count(*)::integer into v_count
    from public.purchase_bill_lines where purchase_bill_id = p_bill_id;
  if v_count = 0 then
    raise exception 'Purchase bill % has no lines.', v_bill.bill_number
      using errcode = 'check_violation';
  end if;
  if v_bill.total_amount <= 0 then
    raise exception 'Purchase bill % comes to nothing.', v_bill.bill_number
      using errcode = 'check_violation';
  end if;

  -- ── The stock side of every line, and the debits that mirror it ───────────
  for v_line in
    select * from public.purchase_bill_lines
     where purchase_bill_id = p_bill_id
     order by line_number
  loop
    if v_line.line_type = 'VEHICLE' then
      -- Locked, because two bills racing for the same chassis must not both
      -- believe they have it. The unique index would catch it at insert; this
      -- makes the failure happen before anything is posted (spec §49).
      select id, status, chassis_no into v_veh
        from public.vehicles where id = v_line.vehicle_id for update;

      if v_veh.id is null then
        raise exception 'The vehicle on line % no longer exists.', v_line.line_number
          using errcode = 'no_data_found';
      end if;
      -- A chassis that has been sold, transferred or cancelled since the draft
      -- was built is not stock this bill can capitalise.
      if v_veh.status <> 'IN_STOCK' then
        raise exception 'Chassis % is % and cannot be put on a purchase bill.',
          v_veh.chassis_no, v_veh.status using errcode = 'check_violation';
      end if;

      -- The cost the bill actually charges becomes the vehicle's cost, which is
      -- what COGS will later relieve. Recording the invoice and leaving the
      -- uploaded estimate in place would make the margin wrong for ever.
      update public.vehicles
         set purchase_cost    = v_line.taxable_value,
             purchase_invoice = coalesce(purchase_invoice, v_bill.supplier_bill_number),
             purchase_date    = coalesce(purchase_date, v_bill.bill_date),
             updated_by       = auth.uid()
       where id = v_line.vehicle_id;

      v_account := app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE',
                                       'VEHICLE_INVENTORY', v_bill.branch_id);
    else
      -- Counted stock arrives as a movement; the quantity follows from it
      -- (spec §34, §60.22). The lot identity is preserved (spec §28, §60.16).
      insert into public.inventory_transactions
        (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
         reference_type, reference_id, reference_number, narration, created_by)
      values
        (v_bill.dealer_id, v_bill.branch_id, v_line.item_id, v_line.source, 'PURCHASE',
         v_line.quantity, round(v_line.taxable_value / v_line.quantity, 4),
         'PURCHASE_BILL', p_bill_id, v_bill.bill_number,
         'Purchased on ' || v_bill.bill_number, auth.uid());

      v_account := app.require_account(
        v_bill.dealer_id, 'INVENTORY', 'PURCHASE',
        case when v_line.line_type = 'ACCESSORY' then 'ACCESSORY_INVENTORY'
             else 'SPARE_INVENTORY' end,
        v_bill.branch_id);
    end if;

    v_lines := v_lines || jsonb_build_object(
      'account_id', v_account, 'debit', v_line.taxable_value, 'credit', 0,
      'narration', v_line.description);
  end loop;

  -- ── Input GST: an asset, because the government owes it back ──────────────
  if v_bill.cgst_amount > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_CGST', v_bill.branch_id),
      'debit', v_bill.cgst_amount, 'credit', 0, 'narration', 'Input CGST ' || v_bill.bill_number);
  end if;
  if v_bill.sgst_amount > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_SGST', v_bill.branch_id),
      'debit', v_bill.sgst_amount, 'credit', 0, 'narration', 'Input SGST ' || v_bill.bill_number);
  end if;
  if v_bill.igst_amount > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_IGST', v_bill.branch_id),
      'debit', v_bill.igst_amount, 'credit', 0, 'narration', 'Input IGST ' || v_bill.bill_number);
  end if;

  -- ── And the one credit: what the dealer now owes this supplier ────────────
  -- Party-tagged, which is what puts the bill on the supplier's subsidiary
  -- ledger instead of leaving 2200 an undifferentiated lump (spec §41).
  select total_amount into v_total from public.purchase_bills where id = p_bill_id;

  v_lines := v_lines || jsonb_build_object(
    'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'PAYABLE', v_bill.branch_id),
    'debit', 0, 'credit', v_total,
    'narration', 'Bill ' || v_bill.supplier_bill_number,
    'party_type', 'SUPPLIER', 'party_id', v_bill.supplier_id);

  v_entry := app.post_journal(
    v_bill.dealer_id, v_bill.branch_id, v_bill.bill_date, 'INVENTORY',
    'Purchase ' || v_bill.bill_number || ' — ' || v_bill.supplier_bill_number,
    v_lines,
    'PURCHASE_BILL', p_bill_id,
    coalesce(p_idempotency_key, 'purchase-bill:' || p_bill_id::text)
  );

  update public.purchase_bills
     set status = 'POSTED', journal_entry_id = v_entry,
         posted_at = now(), posted_by = auth.uid(), updated_by = auth.uid()
   where id = p_bill_id;

  return v_entry;
end;
$$;

comment on function public.post_purchase_bill(uuid, text) is
  'Posts a purchase bill (spec §21, §48): stock onto the balance sheet, input '
  'GST to ITC, and the payable onto the supplier''s ledger. Idempotent (spec §50).';

-- -----------------------------------------------------------------------------
-- public.cancel_purchase_bill() — a draft is dropped, a posted bill is reversed
-- -----------------------------------------------------------------------------
create or replace function public.cancel_purchase_bill(
  p_bill_id uuid,
  p_reason  text
)
returns uuid
language plpgsql
as $$
declare
  v_bill  public.purchase_bills;
  v_line  record;
  v_entry uuid;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'Cancelling a purchase bill requires a reason.'
      using errcode = 'check_violation',
            hint = 'Spec §23: the reason is part of the record, not optional.';
  end if;

  select * into v_bill from public.purchase_bills where id = p_bill_id for update;
  if v_bill.id is null then
    raise exception 'Purchase bill not found.' using errcode = 'no_data_found';
  end if;
  if v_bill.status = 'CANCELLED' then
    raise exception 'Purchase bill % is already cancelled.', v_bill.bill_number
      using errcode = 'check_violation';
  end if;

  -- A draft never reached the ledger, so there is nothing to reverse. Deleting
  -- it releases its chassis back to the unbilled list.
  if v_bill.status = 'DRAFT' then
    delete from public.purchase_bills where id = p_bill_id;
    return null;
  end if;

  -- Posted: reverse the journal and take the stock back out again.
  v_entry := app.reverse_journal(v_bill.journal_entry_id, btrim(p_reason), current_date);

  for v_line in
    select * from public.purchase_bill_lines
     where purchase_bill_id = p_bill_id and line_type in ('ACCESSORY', 'SPARE')
  loop
    insert into public.inventory_transactions
      (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
       reference_type, reference_id, reference_number, narration, reason, created_by)
    values
      (v_bill.dealer_id, v_bill.branch_id, v_line.item_id, v_line.source, 'REVERSAL',
       -v_line.quantity, round(v_line.taxable_value / v_line.quantity, 4),
       'PURCHASE_BILL', p_bill_id, v_bill.bill_number,
       'Cancelled ' || v_bill.bill_number, btrim(p_reason), auth.uid());
  end loop;

  update public.purchase_bills
     set status = 'CANCELLED', updated_by = auth.uid(),
         notes = coalesce(notes || E'\n', '') || 'Cancelled: ' || btrim(p_reason)
   where id = p_bill_id;

  return v_entry;
end;
$$;

comment on function public.cancel_purchase_bill(uuid, text) is
  'Drops a draft, or reverses a posted bill and takes its stock back out '
  '(spec §23, §34). The vehicles it capitalised stay billed: their cost is real.';

-- -----------------------------------------------------------------------------
-- public.unbilled_vehicles() — the chassis a bill may still claim
-- -----------------------------------------------------------------------------
-- In stock, and on no purchase bill. Invoker-rights, so it shows only what the
-- caller's branches and permissions already allow them to see.
-- -----------------------------------------------------------------------------
create or replace function public.unbilled_vehicles(
  p_branch_id uuid default null,
  p_search    text default null
)
returns table (
  vehicle_id    uuid,
  chassis_no    text,
  engine_no     text,
  model_label   text,
  branch_name   text,
  purchase_cost numeric(18, 4),
  stock_date    date
)
language sql
stable
as $$
  select v.id, v.chassis_no, v.engine_no,
         m.name || coalesce(' ' || vr.name, ''),
         b.name, v.purchase_cost, v.stock_date
    from public.vehicles v
    join public.branches b on b.id = v.branch_id
    join public.vehicle_models m on m.id = v.model_id
    left join public.vehicle_variants vr on vr.id = v.variant_id
   where v.status = 'IN_STOCK'
     and (p_branch_id is null or v.branch_id = p_branch_id)
     and not exists (
       select 1 from public.purchase_bill_lines l where l.vehicle_id = v.id
     )
     and (
       p_search is null or btrim(p_search) = ''
       or v.chassis_no ilike '%' || btrim(p_search) || '%'
       or v.engine_no  ilike '%' || btrim(p_search) || '%'
       or m.name       ilike '%' || btrim(p_search) || '%'
     )
   order by v.stock_date desc nulls last, v.chassis_no
   limit 200;
$$;

comment on function public.unbilled_vehicles(uuid, text) is
  'Chassis in stock that no purchase bill has claimed (spec §13, §14).';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update, delete on public.purchase_bills to authenticated';
    execute 'grant select, insert, update, delete on public.purchase_bill_lines to authenticated';
    execute 'grant all on public.purchase_bills to service_role';
    execute 'grant all on public.purchase_bill_lines to service_role';
    execute 'grant execute on function public.post_purchase_bill(uuid, text) to authenticated';
    execute 'grant execute on function public.cancel_purchase_bill(uuid, text) to authenticated';
    execute 'grant execute on function public.unbilled_vehicles(uuid, text) to authenticated';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Permissions
-- -----------------------------------------------------------------------------
-- Inserted here as well as in seed.sql so an upgraded database gains them, and
-- granted to the roles that buy stock and account for it (spec §6).
-- -----------------------------------------------------------------------------
insert into public.permissions (code, module, description, is_sensitive) values
  ('purchases.view',   'purchases', 'View purchase bills',                    false),
  ('purchases.create', 'purchases', 'Create and edit draft purchase bills',   false),
  ('purchases.post',   'purchases', 'Post a purchase bill to the accounts',   false),
  ('purchases.cancel', 'purchases', 'Cancel or reverse a purchase bill',      false)
on conflict (code) do update
  set module      = excluded.module,
      description = excluded.description;

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join (values ('purchases.view'), ('purchases.create'), ('purchases.post'), ('purchases.cancel')) as p(code)
 where r.is_system and r.code in ('DEALER_OWNER', 'ACCOUNTS')
on conflict do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0053_hr_foundations.sql
-- ═══════════════════════════════════════════════════════════════════════════

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


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0055_dealer_status_gate.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0055 — A suspended dealer is actually suspended
-- =============================================================================
-- Spec §4, §6, §47, §60.3, §60.20.
--
-- public.dealers.status has accepted 'ACTIVE', 'SUSPENDED' and 'CLOSED' since
-- migration 0002. Nothing has ever read it.
--
-- app.current_dealer_id() is the function every RLS policy in the schema resolves
-- the tenant through, and it checks only that the USER is active:
--
--     select up.dealer_id from public.user_profiles up
--      where up.id = auth.uid() and up.status = 'ACTIVE';
--
-- So a dealer marked SUSPENDED keeps working exactly as before, for every one of
-- their users. There is no way to stop serving a tenant — not for non-payment,
-- not during a dispute, not when they leave. Marking them CLOSED changes a label
-- and nothing else.
--
-- One clause fixes it everywhere at once, which is the point of having a single
-- tenant-resolution function: 133 policies inherit the change without being
-- touched.
--
-- ── Why this ships on its own ───────────────────────────────────────────────
--
-- It alters what every policy in the database returns. That is worth deploying
-- and verifying by itself rather than inside a larger change, because the
-- failure mode in the other direction — a wrong predicate here — locks every
-- tenant out of everything simultaneously.
--
-- Platform admins are unaffected: app.is_platform_admin() is a separate check
-- that does not go through this function, so a suspended dealer can still be
-- administered, looked at and reactivated.
--
-- Rollback: restore app.current_dealer_id() from 0004.
-- =============================================================================

create or replace function app.current_dealer_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select up.dealer_id
    from public.user_profiles up
    join public.dealers d on d.id = up.dealer_id
   where up.id = auth.uid()
     and up.status = 'ACTIVE'
     -- The tenant has to be live too. Without this the status column is a label
     -- rather than a switch, and there is no way to stop serving a dealer.
     and d.status = 'ACTIVE';
$$;

comment on function app.current_dealer_id() is
  'Tenant of the current session, resolved from the JWT (spec §4). Returns NULL '
  'for platform admins, unauthenticated callers, inactive users AND suspended or '
  'closed dealers — so `dealer_id = app.current_dealer_id()` is false for all of '
  'them, and access ends everywhere at once. Deny by default.';


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0056_dealer_provisioning.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0056 — Provisioning a dealer: onboarding becomes a form, not a SQL script
-- =============================================================================
-- Spec §4, §6, §22, §24, §44, §45, §47, §48, §60.3.
--
-- Until now the only thing that has ever created a tenant is supabase/seed.sql —
-- a hand-run script hardcoded to one dealer. Admin → Dealers is read-only and
-- says so: "Platform administrators provision dealers." Onboarding the second
-- dealer meant editing SQL and running it against production.
--
-- This is that script turned into a function, so onboarding is six fields and a
-- button.
--
-- ── One transaction, or none of it ──────────────────────────────────────────
--
-- A half-provisioned tenant is worse than no tenant: the dealer logs in, raises
-- their first sale, and hits `No accounting rule for SALES/INVOICE/RECEIVABLE` —
-- a failure they cannot diagnose and nobody else can see. So the whole sequence
-- is one plpgsql function, and app.dealer_readiness() runs inside it before it
-- returns. A tenant that would not work never commits (spec §48).
--
-- The Supabase invite is deliberately NOT here. It is the one step Postgres
-- cannot roll back, so the service layer sends it after this commits: the worst
-- case then is a tenant with no invite sent, which the readiness check shows and
-- a Resend button fixes. Inside the transaction, a later failure would have
-- emailed someone a link to a dealership that no longer exists.
--
-- ── Rollback ────────────────────────────────────────────────────────────────
--
--   failed part-way   the transaction rolls back; nothing was written
--   created wrongly   public.purge_dealer(), which refuses once anything posted
--   has traded        status = 'CLOSED' (0055 makes that actually stop access)
--
-- Rollback: drop function public.purge_dealer(uuid, text),
--                         public.dealer_readiness(uuid),
--                         app.provision_dealer(...), app.seed_chart_of_accounts(uuid).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- app.seed_chart_of_accounts() — the accounts every dealer starts with
-- -----------------------------------------------------------------------------
-- Lifted verbatim from the loop in seed.sql so there is one implementation
-- rather than two that drift. Group headers are inserted before their children
-- because parent_id is resolved by code as it goes; `order by code` is what makes
-- that true, and is load-bearing rather than tidiness.
-- -----------------------------------------------------------------------------
create or replace function app.seed_chart_of_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
declare
  v_account record;
  v_parent  uuid;
  v_added   integer := 0;
begin
  for v_account in
    select * from (values
      ('1000', 'Assets',                    'ASSET',     'DEBIT',  true,  null,   false),
      ('1100', 'Cash',                      'ASSET',     'DEBIT',  false, '1000', true),
      ('1200', 'Bank',                      'ASSET',     'DEBIT',  false, '1000', true),
      ('1300', 'Customer Receivable',       'ASSET',     'DEBIT',  false, '1000', false),
      ('1400', 'Finance Receivable',        'ASSET',     'DEBIT',  false, '1000', false),
      ('1500', 'Vehicle Inventory',         'ASSET',     'DEBIT',  false, '1000', true),
      ('1600', 'Accessories Inventory',     'ASSET',     'DEBIT',  false, '1000', true),
      ('1700', 'Spare Inventory',           'ASSET',     'DEBIT',  false, '1000', true),
      ('1800', 'Other Receivables',         'ASSET',     'DEBIT',  false, '1000', false),
      ('1900', 'Input CGST',                'ASSET',     'DEBIT',  false, '1000', false),
      ('1910', 'Input SGST',                'ASSET',     'DEBIT',  false, '1000', false),
      ('1920', 'Input IGST',                'ASSET',     'DEBIT',  false, '1000', false),

      ('2000', 'Liabilities',               'LIABILITY', 'CREDIT', true,  null,   false),
      ('2100', 'Customer Advances',         'LIABILITY', 'CREDIT', false, '2000', false),
      ('2200', 'Supplier Payables',         'LIABILITY', 'CREDIT', false, '2000', false),
      ('2300', 'Output CGST',               'LIABILITY', 'CREDIT', false, '2000', false),
      ('2400', 'Output SGST',               'LIABILITY', 'CREDIT', false, '2000', false),
      ('2500', 'Output IGST',               'LIABILITY', 'CREDIT', false, '2000', false),
      ('2600', 'Finance Company Payable',   'LIABILITY', 'CREDIT', false, '2000', false),
      ('2700', 'Other Payables',            'LIABILITY', 'CREDIT', false, '2000', false),

      ('3000', 'Equity',                    'EQUITY',    'CREDIT', true,  null,   false),
      ('3100', 'Share Capital',             'EQUITY',    'CREDIT', false, '3000', false),
      ('3200', 'Retained Earnings',         'EQUITY',    'CREDIT', false, '3000', false),

      ('4000', 'Income',                    'INCOME',    'CREDIT', true,  null,   false),
      ('4100', 'Vehicle Sales',             'INCOME',    'CREDIT', false, '4000', true),
      ('4200', 'Accessories Sales',         'INCOME',    'CREDIT', false, '4000', true),
      ('4300', 'Spare Sales',               'INCOME',    'CREDIT', false, '4000', true),
      ('4400', 'Service Labour',            'INCOME',    'CREDIT', false, '4000', true),
      ('4500', 'Finance Commission',        'INCOME',    'CREDIT', false, '4000', true),
      ('4600', 'Insurance Commission',      'INCOME',    'CREDIT', false, '4000', true),
      ('4700', 'Forwarding Income',         'INCOME',    'CREDIT', false, '4000', true),
      ('4800', 'Other Income',              'INCOME',    'CREDIT', false, '4000', true),

      ('5000', 'Costs and Expenses',        'EXPENSE',   'DEBIT',  true,  null,   false),
      ('5100', 'Vehicle COGS',              'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5200', 'Accessories COGS',          'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5300', 'Spare COGS',                'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5400', 'Service Cost',              'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5500', 'Salaries',                  'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5600', 'Rent',                      'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5700', 'Utilities',                 'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5800', 'Bank Charges',              'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5900', 'Other Expenses',            'EXPENSE',   'DEBIT',  false, '5000', true)
    ) as t(code, name, account_type, normal_balance, is_group, parent_code, branch_scoped)
    order by code
  loop
    v_parent := null;
    if v_account.parent_code is not null then
      select id into v_parent from public.chart_of_accounts
       where dealer_id = p_dealer_id and code = v_account.parent_code;
    end if;

    insert into public.chart_of_accounts
      (dealer_id, code, name, account_type, normal_balance, is_group, parent_id,
       is_system, is_branch_scoped)
    values
      (p_dealer_id, v_account.code, v_account.name, v_account.account_type,
       v_account.normal_balance, v_account.is_group, v_parent, true,
       v_account.branch_scoped)
    on conflict on constraint coa_dealer_code_key do nothing;

    if found then v_added := v_added + 1; end if;
  end loop;

  return v_added;
end;
$$;

comment on function app.seed_chart_of_accounts(uuid) is
  'The accounts a dealer starts with (spec §24). One implementation, shared by '
  'seed.sql and app.provision_dealer(), so the two cannot drift.';

-- -----------------------------------------------------------------------------
-- public.dealer_readiness() — can this tenant actually trade?
-- -----------------------------------------------------------------------------
-- Provisioning runs this before it commits, and the screen runs it afterwards.
-- Each row is one thing that must be true before a dealer can raise an invoice;
-- the accounting-rule check counts rather than merely looks, because the way this
-- breaks in future is a new seeder nobody added to provisioning.
-- -----------------------------------------------------------------------------
create or replace function public.dealer_readiness(p_dealer_id uuid)
returns table (check_name text, ok boolean, detail text)
language sql
stable
as $$
  select 'Chart of accounts',
         count(*) >= 40,
         count(*) || ' accounts'
    from public.chart_of_accounts where dealer_id = p_dealer_id
  union all
  select 'Control accounts resolvable',
         count(*) = 4,
         count(*) || ' of 4 (1100 cash, 1300 receivable, 2200 payable, 1500 vehicle stock)'
    from public.chart_of_accounts
   where dealer_id = p_dealer_id and code in ('1100', '1300', '1500', '2200')
  union all
  -- 0027 seeds the core, 0042 finance, 0049 accessory cost, 0052 purchases. The
  -- number rises whenever a migration adds rules; a tenant below it is missing a
  -- seeder and will fail at posting time rather than here.
  select 'Accounting rules',
         count(*) >= 40,
         count(*) || ' rules across ' || count(distinct module) || ' modules'
    from public.accounting_rules where dealer_id = p_dealer_id
  union all
  select 'Branches',
         count(*) >= 1,
         count(*) || ' branch(es)'
    from public.branches where dealer_id = p_dealer_id
  union all
  select 'Cash account per branch',
         count(*) filter (where c.id is null) = 0,
         count(*) filter (where c.id is null) || ' branch(es) without one'
    from public.branches b
    left join public.cash_accounts c on c.branch_id = b.id
   where b.dealer_id = p_dealer_id
  union all
  select 'Document sequences',
         count(*) >= 9,
         count(*) || ' series for the current financial year'
    from public.document_sequences
   where dealer_id = p_dealer_id
     and financial_year = app.financial_year_token(p_dealer_id, current_date)
  union all
  select 'Accounting period open',
         count(*) >= 1,
         coalesce(min(name), 'none covering today')
    from public.accounting_periods
   where dealer_id = p_dealer_id and status = 'OPEN'
     and current_date between start_date and end_date
  union all
  select 'Owner login',
         count(*) >= 1,
         count(*) || ' active user(s) with DEALER_OWNER'
    from public.user_profiles up
    join public.user_roles ur on ur.user_id = up.id
    join public.roles r on r.id = ur.role_id
   where up.dealer_id = p_dealer_id and up.status = 'ACTIVE' and r.code = 'DEALER_OWNER'
  union all
  select 'Dealer is active',
         bool_or(status = 'ACTIVE'),
         coalesce(min(status), 'missing')
    from public.dealers where id = p_dealer_id;
$$;

comment on function public.dealer_readiness(uuid) is
  'One row per thing that must be true before a dealer can trade (spec §48). Run '
  'inside provisioning so a tenant that would not work never commits, and on the '
  'screen afterwards so the state is visible rather than assumed.';

-- -----------------------------------------------------------------------------
-- app.provision_dealer() — the whole onboarding, as one transaction
-- -----------------------------------------------------------------------------
-- Returns the new dealer and branch so the caller can send the invite and show
-- the readiness report. Raises rather than returning a failure: every failure
-- here should roll the whole thing back, and an exception is the only way to be
-- sure a caller cannot ignore one.
-- -----------------------------------------------------------------------------
create or replace function app.provision_dealer(
  p_code            text,
  p_legal_name      text,
  p_trade_name      text,
  p_state           text,
  p_state_code      text,
  p_owner_email     text,
  p_owner_name      text,
  p_owner_user_id   uuid,
  p_branch_name     text default 'Head Office',
  p_gstin           text default null,
  p_pan             text default null,
  p_city            text default null,
  p_phone           text default null,
  p_fy_start_month  smallint default 4
)
returns table (new_dealer_id uuid, new_branch_id uuid, accounts_created integer, rules_created integer)
language plpgsql
as $$
declare
  v_dealer   uuid;
  v_branch   uuid;
  v_accounts integer;
  v_rules    integer;
  v_year     text;
  v_owner    uuid;
  v_role     uuid;
  v_fy_start date;
  v_check    record;
  v_failed   text;
begin
  -- ── 1. Refuse before writing anything ────────────────────────────────────
  if not app.is_platform_admin() then
    raise exception 'Only a platform administrator can provision a dealer.'
      using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_code), '') = '' or coalesce(btrim(p_legal_name), '') = '' then
    raise exception 'A dealer needs a code and a legal name.' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_state_code), '') !~ '^[0-9]{2}$' then
    -- Not cosmetic: this decides CGST+SGST versus IGST on every invoice the
    -- dealer will ever raise (spec §16).
    raise exception 'A two-digit state code is required; got %.', p_state_code
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.dealers where upper(code) = upper(btrim(p_code))) then
    raise exception 'Dealer code % is already taken.', p_code using errcode = 'unique_violation';
  end if;
  -- Two tenants sharing a GSTIN would file each other's returns.
  if p_gstin is not null and exists (
    select 1 from public.dealers where gstin = upper(btrim(p_gstin))
  ) then
    raise exception 'GSTIN % already belongs to another dealer.', p_gstin
      using errcode = 'unique_violation';
  end if;
  if p_owner_user_id is null then
    raise exception 'The owner''s auth account must exist before provisioning.'
      using errcode = 'check_violation',
            hint = 'Create the Supabase Auth user first, then pass its id.';
  end if;
  if exists (select 1 from public.user_profiles where id = p_owner_user_id) then
    raise exception 'That login already belongs to a dealer.' using errcode = 'unique_violation';
  end if;

  -- ── 2. The dealer ────────────────────────────────────────────────────────
  insert into public.dealers
    (code, legal_name, trade_name, gstin, pan, city, state, state_code, phone,
     email, fy_start_month, status, created_by)
  values
    (upper(btrim(p_code)), btrim(p_legal_name), coalesce(nullif(btrim(p_trade_name), ''), btrim(p_legal_name)),
     upper(nullif(btrim(p_gstin), '')), upper(nullif(btrim(p_pan), '')),
     nullif(btrim(p_city), ''), btrim(p_state), btrim(p_state_code),
     nullif(btrim(p_phone), ''), lower(btrim(p_owner_email)),
     p_fy_start_month, 'ACTIVE', auth.uid())
  returning id into v_dealer;

  -- ── 3. The first branch ──────────────────────────────────────────────────
  -- Every sale, receipt and journal is branch-scoped, so a dealer without one
  -- cannot transact at all.
  insert into public.branches
    (dealer_id, code, name, city, state, state_code, phone, status, created_by)
  values
    (v_dealer, 'MAIN', coalesce(nullif(btrim(p_branch_name), ''), 'Head Office'),
     nullif(btrim(p_city), ''), btrim(p_state), btrim(p_state_code),
     nullif(btrim(p_phone), ''), 'ACTIVE', auth.uid())
  returning id into v_branch;

  -- ── 4. Chart of accounts ─────────────────────────────────────────────────
  v_accounts := app.seed_chart_of_accounts(v_dealer);

  -- ── 5. Every accounting-rule seeder ──────────────────────────────────────
  -- The list that grows. A migration adding rules adds a line here, and the
  -- readiness check below is the backstop when someone forgets.
  v_rules := app.seed_default_accounting_rules(v_dealer)
           + app.seed_finance_accounting_rules(v_dealer)
           + app.seed_cogs_accounting_rules(v_dealer)
           + app.seed_purchase_accounting_rules(v_dealer);

  -- ── 6. Document sequences ────────────────────────────────────────────────
  -- Financial documents only. Identifier sequences — customer, supplier,
  -- purchase-bill codes — self-provision on first use, deliberately: an
  -- identifier must never fail for want of setup, a financial document should.
  v_year := app.financial_year_token(v_dealer, current_date);

  insert into public.document_sequences
    (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
  values
    (v_dealer, null, 'VEHICLE_INVOICE',     v_year, 'INV', 6),
    (v_dealer, null, 'BOOKING',             v_year, 'BK',  6),
    (v_dealer, null, 'RECEIPT',             v_year, 'REC', 6),
    (v_dealer, null, 'PAYMENT',             v_year, 'PAY', 6),
    (v_dealer, null, 'JOB_CARD',            v_year, 'JC',  6),
    (v_dealer, null, 'SERVICE_INVOICE',     v_year, 'SVC', 6),
    (v_dealer, null, 'COUNTER_INVOICE',     v_year, 'CSI', 6),
    (v_dealer, null, 'JOURNAL',             v_year, 'JE',  6),
    (v_dealer, null, 'BANK_RECONCILIATION', v_year, 'BRS', 6),
    (v_dealer, null, 'DELIVERY',            v_year, 'DLV', 6)
  on conflict on constraint document_sequences_scope_key do nothing;

  -- ── 7. Cash account, and an open accounting period ───────────────────────
  -- Without a cash account, record_cash_transaction() raises "This branch has no
  -- cash account" the first time anyone takes money over the counter.
  perform app.ensure_branch_cash_accounts(v_dealer);

  v_fy_start := make_date(
    case when extract(month from current_date) >= p_fy_start_month
         then extract(year from current_date)::int
         else extract(year from current_date)::int - 1 end,
    p_fy_start_month, 1);

  insert into public.accounting_periods (dealer_id, name, start_date, end_date, status)
  values (
    v_dealer,
    'FY ' || to_char(v_fy_start, 'YYYY') || '-' || to_char(v_fy_start + interval '1 year' - interval '1 day', 'YY'),
    v_fy_start,
    (v_fy_start + interval '1 year' - interval '1 day')::date,
    'OPEN')
  on conflict (dealer_id, start_date, end_date) do nothing;

  -- ── 8. The owner ─────────────────────────────────────────────────────────
  insert into public.user_profiles
    (id, dealer_id, full_name, email, has_all_branch_access, default_branch_id, status)
  values
    (p_owner_user_id, v_dealer, btrim(p_owner_name), lower(btrim(p_owner_email)),
     true, v_branch, 'ACTIVE')
  returning id into v_owner;

  -- The system roles are global rows (dealer_id is null), so a new tenant needs
  -- none of its own — granting the role resolves all 123 permissions.
  select id into v_role from public.roles where code = 'DEALER_OWNER' and dealer_id is null;
  if v_role is null then
    raise exception 'The DEALER_OWNER system role is missing. Run seed.sql first.'
      using errcode = 'no_data_found';
  end if;

  insert into public.user_roles (user_id, role_id) values (v_owner, v_role)
  on conflict do nothing;

  -- ── 9. Refuse to commit a tenant that cannot trade ───────────────────────
  for v_check in select * from public.dealer_readiness(v_dealer) where not ok loop
    v_failed := coalesce(v_failed || '; ', '') || v_check.check_name || ' (' || v_check.detail || ')';
  end loop;

  if v_failed is not null then
    raise exception 'Provisioning would leave % unable to trade: %', p_code, v_failed
      using errcode = 'check_violation',
            hint = 'Nothing was written. Fix the cause and run again.';
  end if;

  new_dealer_id := v_dealer; new_branch_id := v_branch;
  accounts_created := v_accounts; rules_created := v_rules;
  return next;
end;
$$;

comment on function app.provision_dealer(text, text, text, text, text, text, text, uuid, text, text, text, text, text, smallint) is
  'Onboards a dealer in one transaction (spec §48): dealer, branch, chart of '
  'accounts, every accounting-rule seeder, document sequences, cash account, '
  'accounting period and owner. Refuses to commit a tenant that cannot trade. '
  'The invite email is sent by the caller AFTER this commits — it is the one '
  'step that cannot be rolled back.';

-- -----------------------------------------------------------------------------
-- public.purge_dealer() — undo an onboarding, while that is still honest
-- -----------------------------------------------------------------------------
-- For a tenant created by mistake. It refuses outright once anything has been
-- posted, rather than asking for confirmation: a posted journal is a statutory
-- record, it stays the dealer's whether or not they are still a customer, and a
-- confirmation dialog is a thing people click through.
--
-- The delete order below is the one scripts/remove-demo-dealer.sql works out —
-- 23 tables reference dealers with ON DELETE RESTRICT and 18 cascade, so a bare
-- `delete from dealers` fails immediately.
-- -----------------------------------------------------------------------------
create or replace function public.purge_dealer(
  p_dealer_id uuid,
  p_reason    text
)
returns void
language plpgsql
as $$
declare
  v_code text;
begin
  if not app.is_platform_admin() then
    raise exception 'Only a platform administrator can purge a dealer.'
      using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Purging a dealer requires a reason.' using errcode = 'check_violation';
  end if;

  select code into v_code from public.dealers where id = p_dealer_id;
  if v_code is null then
    raise exception 'Dealer not found.' using errcode = 'no_data_found';
  end if;

  -- The hard stop.
  if exists (
    select 1 from public.journal_entries
     where dealer_id = p_dealer_id and status in ('POSTED', 'REVERSED')
  ) then
    raise exception
      'Dealer % has posted journals and cannot be purged. Close it instead.', v_code
      using errcode = 'insufficient_privilege',
            hint = 'A posted ledger is a statutory record. Set status to CLOSED.';
  end if;

  -- Recorded before the rows go, because afterwards there is nothing to point at.
  insert into public.audit_logs
    (dealer_id, user_id, action, entity_type, entity_id, new_data, changed_fields)
  values
    (p_dealer_id, auth.uid(), 'DELETE', 'dealers', p_dealer_id::text,
     jsonb_build_object('code', v_code, 'reason', btrim(p_reason)), array['purged']);

  -- RESTRICT-referencing children first, deepest last-written first. Everything
  -- else cascades from public.dealers.
  delete from public.journal_entry_lines where dealer_id = p_dealer_id;
  delete from public.journal_entries      where dealer_id = p_dealer_id;
  delete from public.inventory_transactions where dealer_id = p_dealer_id;
  delete from public.vehicle_stock_transactions where dealer_id = p_dealer_id;
  delete from public.cash_transactions    where dealer_id = p_dealer_id;
  delete from public.bank_transactions    where dealer_id = p_dealer_id;
  delete from public.user_roles ur using public.user_profiles up
   where ur.user_id = up.id and up.dealer_id = p_dealer_id;
  delete from public.user_branches        where dealer_id = p_dealer_id;
  delete from public.user_profiles        where dealer_id = p_dealer_id;
  delete from public.accounting_rules     where dealer_id = p_dealer_id;
  -- Cash and bank accounts point AT the chart of accounts, so they go first;
  -- deleting the accounts underneath them fails on the ledger foreign key.
  delete from public.cash_accounts        where dealer_id = p_dealer_id;
  delete from public.bank_accounts        where dealer_id = p_dealer_id;
  -- Children before parents: the chart is self-referencing through parent_id.
  delete from public.chart_of_accounts    where dealer_id = p_dealer_id and parent_id is not null;
  delete from public.chart_of_accounts    where dealer_id = p_dealer_id;
  delete from public.branches             where dealer_id = p_dealer_id;
  delete from public.dealers              where id = p_dealer_id;
end;
$$;

comment on function public.purge_dealer(uuid, text) is
  'Deletes a mis-created tenant (spec §60.3). Refuses once any journal is POSTED '
  'or REVERSED — that ledger is the dealer''s statutory record. The owner''s '
  'Supabase Auth account survives and must be removed separately.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.dealer_readiness(uuid) to authenticated';
    execute 'grant execute on function public.purge_dealer(uuid, text) to authenticated';
    execute 'grant execute on function app.provision_dealer(text, text, text, text, text, text, text, uuid, text, text, text, text, text, smallint) to authenticated';
    execute 'grant execute on function app.seed_chart_of_accounts(uuid) to authenticated';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.provision_dealer() — the RPC surface
-- -----------------------------------------------------------------------------
-- PostgREST exposes `public` only, and app.provision_dealer() is where the work
-- lives (the app schema is where privileged machinery belongs, as with
-- app.post_journal). This is the thin wrapper the application calls.
-- -----------------------------------------------------------------------------
create or replace function public.provision_dealer(
  p_code            text,
  p_legal_name      text,
  p_trade_name      text,
  p_state           text,
  p_state_code      text,
  p_owner_email     text,
  p_owner_name      text,
  p_owner_user_id   uuid,
  p_branch_name     text default 'Head Office',
  p_gstin           text default null,
  p_pan             text default null,
  p_city            text default null,
  p_phone           text default null,
  p_fy_start_month  smallint default 4
)
returns table (new_dealer_id uuid, new_branch_id uuid, accounts_created integer, rules_created integer)
language sql
as $$
  select * from app.provision_dealer(
    p_code, p_legal_name, p_trade_name, p_state, p_state_code,
    p_owner_email, p_owner_name, p_owner_user_id, p_branch_name,
    p_gstin, p_pan, p_city, p_phone, p_fy_start_month);
$$;

comment on function public.provision_dealer(text, text, text, text, text, text, text, uuid, text, text, text, text, text, smallint) is
  'Onboards a dealer (spec §48). Thin wrapper over app.provision_dealer() so '
  'PostgREST can reach it; the permission check lives in the inner function.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.provision_dealer(text, text, text, text, text, text, text, uuid, text, text, text, text, text, smallint) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0057_purchase_returns.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0057 — Purchase returns: the debit note that sends bought stock back
-- =============================================================================
-- Spec §21, §22, §23, §24, §28, §29, §34, §41, §44, §45, §48, §50, §59, §60.22.
--
-- The hole this fills. 0052 gave the dealer a way to bring stock in and 0051
-- gave the customer a way to send it back out. Between them there is nothing
-- pointing at the supplier. Goods arrive damaged, the wrong variant is sent, a
-- carton is short — and today the only tool for any of it is
-- cancel_purchase_bill(), which reverses the WHOLE bill. So a dealer returning
-- three floor mats out of a bill of two hundred lines has to reverse the entire
-- consignment and re-key it, or leave the mats on the books for ever and let
-- inventory drift away from the shelf.
--
-- ── What a debit note is, and what it is not ────────────────────────────────
--
-- Cancelling a bill says "this purchase never happened". A return says "this
-- purchase happened, and some of it is going back". They are different facts and
-- the ledger has to be able to state both:
--
--     cancel_purchase_bill()   whole bill, reversal of the original journal
--     post_purchase_return()   part of a bill, a new journal of its own
--
-- The return is the mirror of the bill, line for line:
--
--     Dr  2200 Supplier Payables   (party-tagged)      total
--         Cr  1500 / 1600 / 1700   inventory                    at cost
--         Cr  1900 / 1910 / 1920   input GST reversed           ITC given back
--
-- It resolves the SAME accounting rules the purchase used (INVENTORY/PURCHASE)
-- and flips the side, rather than gaining rules of its own. That is deliberate:
-- a return has to relieve the very accounts the purchase raised, and a separate
-- mapping is a way for one dealer's misconfiguration to leave inventory
-- overstated for ever with a balanced journal to prove it.
--
-- ── Where the money goes ────────────────────────────────────────────────────
--
-- Nowhere, here. The debit note reduces what is owed; it does not move cash.
-- Posted, it becomes an unapplied DEBIT on the supplier's ledger, which is
-- exactly what 0050's bill-wise settlement was built to consume — knock it off
-- the bill it came from, or off the next one. If the supplier actually sends
-- money back, that is a cash or bank receipt tagged to the supplier (0041) and
-- allocated against this note, and it goes through the book that itemises it
-- like every other movement. Inventing a second money path here would put a
-- receipt in the ledger that the cash book had never heard of.
--
-- ── A returned vehicle is not a cancelled one ───────────────────────────────
--
-- Sending a chassis back needs it out of stock, and the obvious move — reusing
-- CANCELLED — is wrong twice over. It reads as "this record was a mistake" when
-- the truth is "this vehicle went back to the manufacturer", and CANCELLED is
-- terminal by design (0017), so reversing the return could never bring the
-- vehicle back. So vehicles gain RETURNED, whose only exit is back to IN_STOCK
-- when the note is reversed. The lifecycle stays a closed set of legal moves.
--
-- The chassis stays on its purchase bill line, and the unique index there means
-- it can never be billed again. That is correct: it was bought once, and it left.
--
-- Rollback: drop function public.post_purchase_return(uuid, jsonb, text, date, text, text);
--           drop function public.cancel_purchase_return(uuid, text);
--           drop function public.returnable_purchase_lines(uuid);
--           drop table public.purchase_return_lines, public.purchase_returns;
--           drop function app.purchase_returns_assign_number(), app.purchase_returns_guard();
--           restore app.vehicles_log_movement() and app.vehicles_guard_status() from 0036/0017;
--           alter table public.vehicles drop constraint vehicles_status_check, re-add without RETURNED;
--           delete from public.document_sequences where doc_type = 'PURCHASE_RETURN';
--           delete from public.permissions where code = 'purchases.return';
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A bill line becomes addressable by a composite tenant key
-- -----------------------------------------------------------------------------
-- Every foreign key in this schema carries (id, dealer_id) so it cannot cross a
-- tenant boundary even if the application asks it to. purchase_bill_lines had
-- never been the target of one; it is now.
-- -----------------------------------------------------------------------------
alter table public.purchase_bill_lines
  add constraint pbl_id_dealer_key unique (id, dealer_id);

-- -----------------------------------------------------------------------------
-- vehicles.status gains RETURNED
-- -----------------------------------------------------------------------------
alter table public.vehicles drop constraint vehicles_status_check;
alter table public.vehicles add constraint vehicles_status_check check (status in (
  'IN_STOCK', 'BOOKED', 'SOLD_PENDING_DELIVERY', 'DELIVERED', 'TRANSFERRED',
  'RETURNED', 'CANCELLED'
));

-- The lifecycle guard from 0017, with the two new moves. IN_STOCK is the only
-- way in, because a vehicle that is booked, sold or in transit is not the
-- dealer's to send back; IN_STOCK is the only way out, and only a reversal of
-- the debit note takes it.
create or replace function app.vehicles_guard_status()
returns trigger
language plpgsql
as $$
declare
  v_allowed text[];
begin
  if tg_op = 'INSERT' then
    if new.status <> 'IN_STOCK' then
      raise exception 'A vehicle enters stock as IN_STOCK, not %.', new.status
        using errcode = 'check_violation';
    end if;
    return new;
  end if;

  if new.status = old.status then
    return new;
  end if;

  v_allowed := case old.status
    when 'IN_STOCK'              then array['BOOKED', 'SOLD_PENDING_DELIVERY', 'TRANSFERRED', 'RETURNED', 'CANCELLED']
    when 'BOOKED'                then array['IN_STOCK', 'SOLD_PENDING_DELIVERY', 'CANCELLED']
    when 'SOLD_PENDING_DELIVERY' then array['DELIVERED', 'IN_STOCK', 'CANCELLED']
    when 'TRANSFERRED'           then array['IN_STOCK', 'CANCELLED']
    -- Sent back to the supplier. Comes back only if the debit note is reversed.
    when 'RETURNED'              then array['IN_STOCK']
    -- Terminal. A delivered vehicle is the customer's; a cancelled one is out.
    when 'DELIVERED'             then array[]::text[]
    when 'CANCELLED'             then array[]::text[]
    else array[]::text[]
  end;

  if not (new.status = any (v_allowed)) then
    raise exception 'Vehicle % cannot move from % to %.', old.chassis_no, old.status, new.status
      using errcode = 'check_violation',
            hint = 'Spec §13 defines the vehicle status lifecycle.';
  end if;

  return new;
end;
$$;

-- The stock ledger has to label the two new movements. Everything else is
-- exactly as 0036 left it: the trigger stays the sole writer of the log, and the
-- causing document still arrives in app.vehicle_movement_ref.
create or replace function app.vehicles_log_movement()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ref  text;
  v_type text;
  v_id   uuid;
begin
  if tg_op = 'INSERT' then
    insert into public.vehicle_stock_transactions
      (dealer_id, branch_id, vehicle_id, transaction_type, to_status, to_branch_id, value, created_by)
    values (new.dealer_id, new.branch_id, new.id, 'PURCHASE', new.status, new.branch_id,
            new.purchase_cost, new.created_by);
    return null;
  end if;

  if new.status is distinct from old.status or new.branch_id is distinct from old.branch_id then
    v_ref := nullif(current_setting('app.vehicle_movement_ref', true), '');
    if v_ref is not null then
      v_type := split_part(v_ref, ':', 1);
      v_id   := nullif(split_part(v_ref, ':', 2), '')::uuid;
    end if;

    insert into public.vehicle_stock_transactions
      (dealer_id, branch_id, vehicle_id, transaction_type,
       from_status, to_status, from_branch_id, to_branch_id, value,
       reference_type, reference_id, created_by)
    values (new.dealer_id, new.branch_id, new.id,
            case
              -- The branch moved, so the unit has arrived somewhere.
              when new.branch_id is distinct from old.branch_id then 'TRANSFER_IN'
              -- On its way: out of the source branch's stock, not yet anywhere.
              when new.status = 'TRANSFERRED'                    then 'TRANSFER_OUT'
              -- Back to the supplier, and back again if the note is reversed.
              when new.status = 'RETURNED'                       then 'RETURN'
              when old.status = 'RETURNED'                       then 'REVERSAL'
              when old.status in ('SOLD_PENDING_DELIVERY', 'DELIVERED')
                   and new.status = 'IN_STOCK'                   then 'RETURN'
              else 'STATUS_CHANGE'
            end,
            old.status, new.status, old.branch_id, new.branch_id, new.purchase_cost,
            v_type, v_id, new.updated_by);
  end if;

  return null;
end;
$$;

comment on function app.vehicles_log_movement() is
  'Sole writer of the vehicle stock ledger (spec §34). Labels transfers, sale '
  'returns and purchase returns from the status pair, and takes the causing '
  'document from the transaction-local setting app.vehicle_movement_ref.';

-- -----------------------------------------------------------------------------
-- purchase_returns — the debit note
-- -----------------------------------------------------------------------------
create table public.purchase_returns (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null references public.dealers (id) on delete restrict,
  branch_id        uuid not null,

  return_number    text not null,
  -- The bill the goods came in on. A return always has one: what is being sent
  -- back was bought at a price, on a date, at a tax rate, and those are the
  -- figures the credit has to use.
  purchase_bill_id uuid not null,
  -- Denormalised from the bill so the supplier's own list is one index lookup.
  -- The posting function is the only writer and copies it from the bill.
  supplier_id      uuid not null,

  return_date      date not null default current_date,
  -- Their credit note number, when they have issued one. Not unique: a supplier
  -- may not have raised it yet, and two may reuse a number.
  supplier_ref     text,

  status           text not null default 'DRAFT',

  -- Why. Required, because a debit note without one is unexplainable a year
  -- later, and it is written onto the accounting narration (spec §23).
  reason           text not null,

  taxable_value    numeric(18, 4) not null default 0,
  cgst_amount      numeric(18, 4) not null default 0,
  sgst_amount      numeric(18, 4) not null default 0,
  igst_amount      numeric(18, 4) not null default 0,
  total_amount     numeric(18, 4) not null default 0,

  notes            text,
  journal_entry_id uuid,
  -- A duplicate submission returns the first note rather than sending the goods
  -- back twice (spec §50). Supplied by the browser, one per dialog.
  idempotency_key  text,

  posted_at        timestamptz,
  posted_by        uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       uuid,
  updated_by       uuid,

  constraint purchase_returns_number_key    unique (dealer_id, return_number),
  constraint purchase_returns_id_dealer_key unique (id, dealer_id),
  constraint purchase_returns_idempotency_key unique (dealer_id, idempotency_key),

  constraint purchase_returns_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint purchase_returns_bill_tenant_fkey
    foreign key (purchase_bill_id, dealer_id) references public.purchase_bills (id, dealer_id),
  constraint purchase_returns_supplier_tenant_fkey
    foreign key (supplier_id, dealer_id) references public.suppliers (id, dealer_id),
  constraint purchase_returns_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),

  constraint purchase_returns_status_check check (status in ('DRAFT', 'POSTED', 'CANCELLED')),
  constraint purchase_returns_reason_check check (length(btrim(reason)) between 1 and 500),
  constraint purchase_returns_amounts_check check (
    taxable_value >= 0 and cgst_amount >= 0 and sgst_amount >= 0
    and igst_amount >= 0 and total_amount >= 0
  ),
  constraint purchase_returns_posted_stamp_check check (
    status <> 'POSTED' or (posted_at is not null and journal_entry_id is not null)
  )
);

comment on table public.purchase_returns is
  'Debit note against a purchase bill (spec §24, §34, §41). Takes part of a '
  'consignment back off the books at the cost it came in at, reverses its input '
  'GST and reduces what is owed to the supplier.';
comment on column public.purchase_returns.status is
  'DRAFT exists only inside post_purchase_return(), which creates the note and '
  'posts it in one transaction. Nothing in the product leaves one in DRAFT.';

create index purchase_returns_bill_idx     on public.purchase_returns (purchase_bill_id);
create index purchase_returns_supplier_idx on public.purchase_returns (supplier_id, return_date desc);
create index purchase_returns_dealer_idx   on public.purchase_returns (dealer_id, return_date desc);
create index purchase_returns_branch_idx   on public.purchase_returns (branch_id, return_date desc);
create index purchase_returns_status_idx   on public.purchase_returns (dealer_id, status);

-- -----------------------------------------------------------------------------
-- purchase_return_lines — what is going back, and off which bill line
-- -----------------------------------------------------------------------------
-- Every line points at the bill line it reverses. That is what makes "how much
-- of this line is still returnable" answerable, and it carries the rate and the
-- tax split forward so the credit is at the price actually paid rather than at
-- whatever the item costs today.
-- -----------------------------------------------------------------------------
create table public.purchase_return_lines (
  id                   uuid primary key default gen_random_uuid(),
  purchase_return_id   uuid not null,
  dealer_id            uuid not null,
  purchase_bill_line_id uuid not null,

  line_number    smallint not null,
  line_type      text not null,

  vehicle_id     uuid,
  item_id        uuid,
  source         text,

  description    text not null,
  quantity       numeric(18, 3) not null,
  unit_rate      numeric(18, 4) not null,

  taxable_value  numeric(18, 4) not null,
  cgst_amount    numeric(18, 4) not null default 0,
  sgst_amount    numeric(18, 4) not null default 0,
  igst_amount    numeric(18, 4) not null default 0,
  total_amount   numeric(18, 4) not null,

  created_at     timestamptz not null default now(),

  constraint prl_return_line_key unique (purchase_return_id, line_number),
  constraint prl_return_tenant_fkey
    foreign key (purchase_return_id, dealer_id)
    references public.purchase_returns (id, dealer_id) on delete cascade,
  constraint prl_bill_line_tenant_fkey
    foreign key (purchase_bill_line_id, dealer_id)
    references public.purchase_bill_lines (id, dealer_id),
  constraint prl_vehicle_tenant_fkey
    foreign key (vehicle_id, dealer_id) references public.vehicles (id, dealer_id),
  constraint prl_item_tenant_fkey
    foreign key (item_id, dealer_id) references public.inventory_items (id, dealer_id),

  constraint prl_type_check check (line_type in ('VEHICLE', 'ACCESSORY', 'SPARE')),
  constraint prl_source_check check (source is null or source in ('LOCAL', 'COMPANY')),
  -- The same shapes the bill line has: a chassis goes back whole, a counted item
  -- goes back from the lot it joined (spec §28).
  constraint prl_shape_check check (
    (line_type = 'VEHICLE'
       and vehicle_id is not null and item_id is null and source is null and quantity = 1)
    or (line_type <> 'VEHICLE'
       and item_id is not null and vehicle_id is null and source is not null and quantity > 0)
  ),
  constraint prl_amounts_check check (
    unit_rate >= 0 and taxable_value >= 0 and total_amount >= 0
    and cgst_amount >= 0 and sgst_amount >= 0 and igst_amount >= 0
  ),
  constraint prl_tax_split_check check (
    (igst_amount = 0) or (cgst_amount = 0 and sgst_amount = 0)
  ),
  constraint prl_line_number_check check (line_number > 0)
);

comment on table public.purchase_return_lines is
  'What is going back to the supplier, against the bill line it came in on '
  '(spec §34). Priced at the bill''s rate, never at today''s cost.';

-- One chassis goes back once. A second note for the same vehicle is a duplicate,
-- and the returnable-quantity check would already have refused it — this makes
-- it impossible rather than merely checked (spec §49, §50).
create unique index purchase_return_lines_vehicle_key
  on public.purchase_return_lines (vehicle_id) where vehicle_id is not null;

create index purchase_return_lines_return_idx on public.purchase_return_lines (purchase_return_id);
create index purchase_return_lines_bill_line_idx on public.purchase_return_lines (purchase_bill_line_id);
create index purchase_return_lines_item_idx on public.purchase_return_lines (item_id) where item_id is not null;

-- -----------------------------------------------------------------------------
-- The note's number, issued by the database
-- -----------------------------------------------------------------------------
create or replace function app.purchase_returns_assign_number()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_year text;
begin
  if new.return_number is not null and btrim(new.return_number) <> '' then
    return new;
  end if;

  v_year := app.financial_year_token(new.dealer_id, coalesce(new.return_date, current_date));

  insert into public.document_sequences (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
  values (new.dealer_id, null, 'PURCHASE_RETURN', v_year, 'PR', 6)
  on conflict on constraint document_sequences_scope_key do nothing;

  new.return_number := app.next_document_number(new.dealer_id, null, 'PURCHASE_RETURN', v_year);
  return new;
end;
$$;

create trigger purchase_returns_assign_number
  before insert on public.purchase_returns
  for each row execute function app.purchase_returns_assign_number();

-- -----------------------------------------------------------------------------
-- A posted note is immutable, and no note is ever deleted
-- -----------------------------------------------------------------------------
create or replace function app.purchase_returns_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Purchase return % cannot be deleted.', old.return_number
      using errcode = 'insufficient_privilege',
            hint = 'Spec §23: corrections use reversal, not deletion.';
  end if;

  -- A note is born as a draft, the same way a journal is (0007). Declaring one
  -- POSTED on the way in would put a document on the supplier's ledger that
  -- moved no stock and wrote no journal.
  if tg_op = 'INSERT' then
    if new.status <> 'DRAFT' then
      raise exception 'A purchase return is created as DRAFT and posted by post_purchase_return(); got %.',
        new.status using errcode = 'check_violation';
    end if;
    return new;
  end if;

  -- DRAFT exists only for the moment inside post_purchase_return() between
  -- writing the note and posting its journal. A note reaching POSTED by any
  -- other route would carry no stock movements and no accounting: the journal
  -- named has to be one that points back at this very note.
  if old.status = 'DRAFT' and new.status = 'POSTED' then
    if not exists (
      select 1 from public.journal_entries je
       where je.id = new.journal_entry_id
         and je.source_document_type = 'PURCHASE_RETURN'
         and je.source_document_id = new.id
    ) then
      raise exception 'A purchase return is posted by post_purchase_return(), not by hand.'
        using errcode = 'insufficient_privilege';
    end if;
  end if;

  if old.status = 'POSTED' then
    -- Only the cancellation the reverse path writes may change.
    if not (new.status = 'CANCELLED'
            and (to_jsonb(new) - 'status' - 'notes' - 'updated_at' - 'updated_by')
                = (to_jsonb(old) - 'status' - 'notes' - 'updated_at' - 'updated_by')) then
      raise exception 'Purchase return % is POSTED and immutable.', old.return_number
        using errcode = 'insufficient_privilege',
              hint = 'Spec §23: reverse it instead of editing.';
    end if;
  end if;

  if old.status = 'CANCELLED' and new.status <> 'CANCELLED' then
    raise exception 'Purchase return % is reversed and cannot be reopened.', old.return_number
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end;
$$;

-- INSERT is guarded too: the status a note is born with is as load-bearing as
-- the ones it may move to.
create trigger purchase_returns_guard
  before insert or update or delete on public.purchase_returns
  for each row execute function app.purchase_returns_guard();

-- Lines are written once, by the posting function, inside the transaction that
-- creates the note. Nothing edits them afterwards.
create trigger purchase_return_lines_append_only
  before update or delete on public.purchase_return_lines
  for each row execute function app.forbid_mutation();

create trigger purchase_returns_set_updated_at
  before update on public.purchase_returns
  for each row execute function app.set_updated_at();

create trigger purchase_returns_audit
  after insert or update or delete on public.purchase_returns
  for each row execute function app.audit_trigger();

-- -----------------------------------------------------------------------------
-- Row Level Security
-- -----------------------------------------------------------------------------
alter table public.purchase_returns      enable row level security;
alter table public.purchase_return_lines enable row level security;

create policy purchase_returns_select on public.purchase_returns
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and app.has_permission('purchases.view'))
  );

create policy purchase_returns_insert on public.purchase_returns
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and app.has_permission('purchases.return'))
  );

-- The DRAFT → POSTED flip inside the posting function, and the cancellation.
-- The guard above decides what an update may actually contain.
create policy purchase_returns_update on public.purchase_returns
  for update to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and (app.has_permission('purchases.return') or app.has_permission('purchases.cancel')))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and (app.has_permission('purchases.return') or app.has_permission('purchases.cancel')))
  );

-- Deliberately no delete policy: a debit note is a document, not a draft.

create policy purchase_return_lines_select on public.purchase_return_lines
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and exists (
          select 1 from public.purchase_returns r
           where r.id = purchase_return_lines.purchase_return_id
             and app.can_access_branch(r.branch_id)
        )
        and app.has_permission('purchases.view'))
  );

create policy purchase_return_lines_insert on public.purchase_return_lines
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('purchases.return'))
  );

-- -----------------------------------------------------------------------------
-- public.returnable_purchase_lines() — what is left to send back
-- -----------------------------------------------------------------------------
-- Billed, less everything already returned on posted notes. Invoker-rights, so
-- it shows only what the caller's branches and permissions already allow.
-- -----------------------------------------------------------------------------
create or replace function public.returnable_purchase_lines(p_bill_id uuid)
returns table (
  bill_line_id        uuid,
  line_number         smallint,
  line_type           text,
  description         text,
  source              text,
  chassis_no          text,
  item_code           text,
  vehicle_status      text,
  billed_quantity     numeric(18, 3),
  returned_quantity   numeric(18, 3),
  returnable_quantity numeric(18, 3),
  unit_rate           numeric(18, 4),
  cgst_rate           numeric(6, 3),
  sgst_rate           numeric(6, 3),
  igst_rate           numeric(6, 3)
)
language sql
stable
as $$
  select l.id, l.line_number, l.line_type, l.description, l.source,
         v.chassis_no, i.item_code, v.status,
         l.quantity,
         coalesce(r.returned, 0)::numeric(18, 3),
         (l.quantity - coalesce(r.returned, 0))::numeric(18, 3),
         l.unit_rate, l.cgst_rate, l.sgst_rate, l.igst_rate
    from public.purchase_bill_lines l
    left join public.vehicles v on v.id = l.vehicle_id
    left join public.inventory_items i on i.id = l.item_id
    left join lateral (
      select sum(rl.quantity) as returned
        from public.purchase_return_lines rl
        join public.purchase_returns pr on pr.id = rl.purchase_return_id
       where rl.purchase_bill_line_id = l.id
         and pr.status = 'POSTED'
    ) r on true
   where l.purchase_bill_id = p_bill_id
   order by l.line_number;
$$;

comment on function public.returnable_purchase_lines(uuid) is
  'Bill lines with how much of each has already gone back (spec §34), so a '
  'debit note cannot return more than arrived.';

-- -----------------------------------------------------------------------------
-- public.post_purchase_return() — the debit note, in one transaction
-- -----------------------------------------------------------------------------
-- Spec §48: the note, its lines, the stock movements and the journal all commit
-- together or not at all. p_lines is [{ "bill_line_id": uuid, "quantity": n }].
-- -----------------------------------------------------------------------------
create or replace function public.post_purchase_return(
  p_bill_id         uuid,
  p_lines           jsonb,
  p_reason          text,
  p_return_date     date default current_date,
  p_supplier_ref    text default null,
  p_idempotency_key text default null
)
returns table (
  return_id     uuid,
  return_number text,
  entry_id      uuid,
  total         numeric(18, 4)
)
language plpgsql
as $$
declare
  v_bill        public.purchase_bills;
  v_return      public.purchase_returns;
  v_line        public.purchase_bill_lines;
  v_req         jsonb;
  v_veh         record;
  v_account     uuid;
  v_entry       uuid;
  v_index       smallint := 0;
  v_qty         numeric(18, 3);
  v_returned    numeric(18, 3);
  v_ret_taxable numeric(18, 4);
  v_ret_cgst    numeric(18, 4);
  v_ret_sgst    numeric(18, 4);
  v_ret_igst    numeric(18, 4);
  v_taxable     numeric(18, 4);
  v_cgst        numeric(18, 4);
  v_sgst        numeric(18, 4);
  v_igst        numeric(18, 4);
  v_share       numeric;
  v_sum_taxable numeric(18, 4) := 0;
  v_sum_cgst    numeric(18, 4) := 0;
  v_sum_sgst    numeric(18, 4) := 0;
  v_sum_igst    numeric(18, 4) := 0;
  v_sum_total   numeric(18, 4) := 0;
  v_entries     jsonb := '[]'::jsonb;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A purchase return requires a reason.'
      using errcode = 'check_violation',
            hint = 'Spec §23: the reason is part of the record, not optional.';
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Choose at least one line to send back.'
      using errcode = 'check_violation';
  end if;

  -- Locked for the rest of the transaction, so two notes against the same bill
  -- cannot each believe the same quantity is still returnable (spec §49).
  select * into v_bill from public.purchase_bills where id = p_bill_id for update;

  if v_bill.id is null then
    raise exception 'Purchase bill not found.' using errcode = 'no_data_found';
  end if;
  if v_bill.status <> 'POSTED' then
    raise exception
      'Purchase bill % is % — only a posted bill has stock on the books to send back.',
      v_bill.bill_number, v_bill.status using errcode = 'check_violation';
  end if;

  -- A repeated submission returns the note the first one wrote rather than
  -- sending the goods back twice (spec §50).
  if p_idempotency_key is not null then
    select * into v_return from public.purchase_returns
     where dealer_id = v_bill.dealer_id and idempotency_key = p_idempotency_key;
    if v_return.id is not null then
      return query select v_return.id, v_return.return_number,
                          v_return.journal_entry_id, v_return.total_amount;
      return;
    end if;
  end if;

  insert into public.purchase_returns
    (dealer_id, branch_id, purchase_bill_id, supplier_id, return_date,
     supplier_ref, reason, idempotency_key, created_by)
  values
    (v_bill.dealer_id, v_bill.branch_id, p_bill_id, v_bill.supplier_id,
     coalesce(p_return_date, current_date), nullif(btrim(p_supplier_ref), ''),
     btrim(p_reason), p_idempotency_key, auth.uid())
  returning * into v_return;

  -- ── Every line: what goes back, off the books, and out of stock ───────────
  for v_req in select value from jsonb_array_elements(p_lines) loop
    v_index := v_index + 1;

    select * into v_line from public.purchase_bill_lines
     where id = (v_req->>'bill_line_id')::uuid
       and purchase_bill_id = p_bill_id;

    if v_line.id is null then
      raise exception 'A line being returned is not on bill %.', v_bill.bill_number
        using errcode = 'no_data_found';
    end if;

    v_qty := round(coalesce((v_req->>'quantity')::numeric, 0), 3);
    if v_qty <= 0 then
      raise exception 'Line % has nothing to return. Enter a quantity above zero.',
        v_line.line_number using errcode = 'check_violation';
    end if;

    -- What has already gone back on this bill line, and at what value. Both are
    -- needed: the quantity to cap this note, the value so the last return of a
    -- line takes the exact remainder rather than a rounded share of it.
    select coalesce(sum(rl.quantity), 0), coalesce(sum(rl.taxable_value), 0),
           coalesce(sum(rl.cgst_amount), 0), coalesce(sum(rl.sgst_amount), 0),
           coalesce(sum(rl.igst_amount), 0)
      into v_returned, v_ret_taxable, v_ret_cgst, v_ret_sgst, v_ret_igst
      from public.purchase_return_lines rl
      join public.purchase_returns pr on pr.id = rl.purchase_return_id
     where rl.purchase_bill_line_id = v_line.id
       and pr.status = 'POSTED';

    if v_qty > v_line.quantity - v_returned then
      raise exception
        'Line % has % of % left to return; % is more than arrived.',
        v_line.line_number, v_line.quantity - v_returned, v_line.quantity, v_qty
        using errcode = 'check_violation';
    end if;

    if v_qty = v_line.quantity - v_returned then
      -- The remainder, exactly. Rounding cannot accumulate across part returns
      -- and leave a few paise of stock on the books for ever.
      v_taxable := v_line.taxable_value - v_ret_taxable;
      v_cgst    := v_line.cgst_amount   - v_ret_cgst;
      v_sgst    := v_line.sgst_amount   - v_ret_sgst;
      v_igst    := v_line.igst_amount   - v_ret_igst;
    else
      v_share   := v_qty / v_line.quantity;
      v_taxable := round(v_line.taxable_value * v_share, 4);
      v_cgst    := round(v_line.cgst_amount   * v_share, 4);
      v_sgst    := round(v_line.sgst_amount   * v_share, 4);
      v_igst    := round(v_line.igst_amount   * v_share, 4);
    end if;

    if v_line.line_type = 'VEHICLE' then
      if v_qty <> 1 then
        raise exception 'A vehicle goes back whole; % of one cannot be returned.', v_qty
          using errcode = 'check_violation';
      end if;

      select id, status, chassis_no into v_veh
        from public.vehicles where id = v_line.vehicle_id for update;

      if v_veh.id is null then
        raise exception 'The vehicle on line % no longer exists.', v_line.line_number
          using errcode = 'no_data_found';
      end if;
      -- Booked, sold or in transit, it is not the dealer's to send back.
      if v_veh.status <> 'IN_STOCK' then
        raise exception
          'Chassis % is % — only a vehicle still in stock can go back to the supplier.',
          v_veh.chassis_no, v_veh.status using errcode = 'check_violation';
      end if;

      -- The RETURN ledger row is written by app.vehicles_log_movement(), which
      -- reads this setting to record what the movement was for.
      perform set_config('app.vehicle_movement_ref', 'PURCHASE_RETURN:' || v_return.id, true);
      update public.vehicles
         set status = 'RETURNED', updated_by = auth.uid()
       where id = v_line.vehicle_id;
      perform set_config('app.vehicle_movement_ref', '', true);

      v_account := app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE',
                                       'VEHICLE_INVENTORY', v_bill.branch_id);
    else
      -- Out of the lot it joined, never merged with the other one (spec §28,
      -- §60.16). The movement is what reduces the quantity (spec §34), and the
      -- trigger on inventory_transactions refuses to drive the lot negative.
      insert into public.inventory_transactions
        (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
         reference_type, reference_id, reference_number, narration, reason, created_by)
      values
        (v_bill.dealer_id, v_bill.branch_id, v_line.item_id, v_line.source, 'RETURN',
         -v_qty, round(v_taxable / v_qty, 4),
         'PURCHASE_RETURN', v_return.id, v_return.return_number,
         'Returned to supplier on ' || v_return.return_number, btrim(p_reason), auth.uid());

      v_account := app.require_account(
        v_bill.dealer_id, 'INVENTORY', 'PURCHASE',
        case when v_line.line_type = 'ACCESSORY' then 'ACCESSORY_INVENTORY'
             else 'SPARE_INVENTORY' end,
        v_bill.branch_id);
    end if;

    insert into public.purchase_return_lines
      (purchase_return_id, dealer_id, purchase_bill_line_id, line_number, line_type,
       vehicle_id, item_id, source, description, quantity, unit_rate,
       taxable_value, cgst_amount, sgst_amount, igst_amount, total_amount)
    values
      (v_return.id, v_bill.dealer_id, v_line.id, v_index, v_line.line_type,
       v_line.vehicle_id, v_line.item_id, v_line.source, v_line.description,
       v_qty, v_line.unit_rate,
       v_taxable, v_cgst, v_sgst, v_igst, v_taxable + v_cgst + v_sgst + v_igst);

    -- The credit that takes it off the balance sheet, at the cost it came in at.
    v_entries := v_entries || jsonb_build_object(
      'account_id', v_account, 'debit', 0, 'credit', v_taxable,
      'narration', 'Returned: ' || v_line.description);

    v_sum_taxable := v_sum_taxable + v_taxable;
    v_sum_cgst    := v_sum_cgst + v_cgst;
    v_sum_sgst    := v_sum_sgst + v_sgst;
    v_sum_igst    := v_sum_igst + v_igst;
  end loop;

  v_sum_total := v_sum_taxable + v_sum_cgst + v_sum_sgst + v_sum_igst;

  if v_sum_total <= 0 then
    raise exception 'This return comes to nothing. Check the quantities.'
      using errcode = 'check_violation';
  end if;

  -- ── Input GST goes back too: credit that is no longer claimable ───────────
  if v_sum_cgst > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_CGST', v_bill.branch_id),
      'debit', 0, 'credit', v_sum_cgst, 'narration', 'Input CGST reversed ' || v_return.return_number);
  end if;
  if v_sum_sgst > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_SGST', v_bill.branch_id),
      'debit', 0, 'credit', v_sum_sgst, 'narration', 'Input SGST reversed ' || v_return.return_number);
  end if;
  if v_sum_igst > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_IGST', v_bill.branch_id),
      'debit', 0, 'credit', v_sum_igst, 'narration', 'Input IGST reversed ' || v_return.return_number);
  end if;

  -- ── And the one debit: what the dealer no longer owes ─────────────────────
  -- Party-tagged, so it lands on the supplier's own ledger as an open debit that
  -- bill-wise settlement (0050) can knock off the bill it came from.
  v_entries := v_entries || jsonb_build_object(
    'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'PAYABLE', v_bill.branch_id),
    'debit', v_sum_total, 'credit', 0,
    'narration', 'Debit note ' || v_return.return_number || ' on ' || v_bill.supplier_bill_number,
    'party_type', 'SUPPLIER', 'party_id', v_bill.supplier_id);

  update public.purchase_returns
     set taxable_value = v_sum_taxable,
         cgst_amount   = v_sum_cgst,
         sgst_amount   = v_sum_sgst,
         igst_amount   = v_sum_igst,
         total_amount  = v_sum_total
   where id = v_return.id;

  v_entry := app.post_journal(
    v_bill.dealer_id, v_bill.branch_id, coalesce(p_return_date, current_date), 'INVENTORY',
    'Purchase return ' || v_return.return_number || ' — ' || v_bill.bill_number,
    v_entries,
    'PURCHASE_RETURN', v_return.id,
    'purchase-return:' || v_return.id::text
  );

  update public.purchase_returns
     set status = 'POSTED', journal_entry_id = v_entry,
         posted_at = now(), posted_by = auth.uid(), updated_by = auth.uid()
   where id = v_return.id;

  return query select v_return.id, v_return.return_number, v_entry, v_sum_total;
end;
$$;

comment on function public.post_purchase_return(uuid, jsonb, text, date, text, text) is
  'Sends part of a purchase bill back to the supplier (spec §21, §34, §48): '
  'stock out at the cost it came in at, input GST reversed, and the payable '
  'reduced on the supplier''s ledger. Idempotent (spec §50).';

-- -----------------------------------------------------------------------------
-- public.cancel_purchase_return() — the note itself was wrong
-- -----------------------------------------------------------------------------
-- The goods never went, or went on the wrong note. The journal is reversed by a
-- second entry, the stock comes back into the lot it left, and a returned
-- chassis returns to stock. The note stays on the record (spec §23).
-- -----------------------------------------------------------------------------
create or replace function public.cancel_purchase_return(
  p_return_id uuid,
  p_reason    text
)
returns uuid
language plpgsql
as $$
declare
  v_return public.purchase_returns;
  v_line   record;
  v_entry  uuid;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'Reversing a purchase return requires a reason.'
      using errcode = 'check_violation',
            hint = 'Spec §23: the reason is part of the record, not optional.';
  end if;

  select * into v_return from public.purchase_returns where id = p_return_id for update;

  if v_return.id is null then
    raise exception 'Purchase return not found.' using errcode = 'no_data_found';
  end if;
  if v_return.status <> 'POSTED' then
    raise exception 'Purchase return % is % and cannot be reversed.',
      v_return.return_number, v_return.status using errcode = 'check_violation';
  end if;

  v_entry := app.reverse_journal(v_return.journal_entry_id, btrim(p_reason), current_date);

  for v_line in
    select * from public.purchase_return_lines
     where purchase_return_id = p_return_id
     order by line_number
  loop
    if v_line.line_type = 'VEHICLE' then
      perform set_config('app.vehicle_movement_ref', 'PURCHASE_RETURN:' || p_return_id, true);
      update public.vehicles
         set status = 'IN_STOCK', updated_by = auth.uid()
       where id = v_line.vehicle_id;
      perform set_config('app.vehicle_movement_ref', '', true);
    else
      insert into public.inventory_transactions
        (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
         reference_type, reference_id, reference_number, narration, reason, created_by)
      values
        (v_return.dealer_id, v_return.branch_id, v_line.item_id, v_line.source, 'REVERSAL',
         v_line.quantity, round(v_line.taxable_value / v_line.quantity, 4),
         'PURCHASE_RETURN', p_return_id, v_return.return_number,
         'Reversed ' || v_return.return_number, btrim(p_reason), auth.uid());
    end if;
  end loop;

  update public.purchase_returns
     set status = 'CANCELLED', updated_by = auth.uid(),
         notes = coalesce(notes || E'\n', '') || 'Reversed: ' || btrim(p_reason)
   where id = p_return_id;

  return v_entry;
end;
$$;

comment on function public.cancel_purchase_return(uuid, text) is
  'Reverses a posted debit note (spec §23): a second journal undoes the first '
  'and the stock comes back into the lot it left.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.purchase_returns to authenticated';
    execute 'grant select, insert on public.purchase_return_lines to authenticated';
    execute 'grant all on public.purchase_returns to service_role';
    execute 'grant all on public.purchase_return_lines to service_role';
    execute 'grant execute on function public.returnable_purchase_lines(uuid) to authenticated';
    execute 'grant execute on function public.post_purchase_return(uuid, jsonb, text, date, text, text) to authenticated';
    execute 'grant execute on function public.cancel_purchase_return(uuid, text) to authenticated';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Permissions
-- -----------------------------------------------------------------------------
-- Separate from purchases.create: entering what arrived and deciding that some
-- of it goes back are different authorities, and the second one moves stock off
-- the books (spec §6).
-- -----------------------------------------------------------------------------
insert into public.permissions (code, module, description, is_sensitive) values
  ('purchases.return', 'purchases', 'Return purchased stock to a supplier (debit note)', false)
on conflict (code) do update
  set module      = excluded.module,
      description = excluded.description;

insert into public.role_permissions (role_id, permission_code)
select r.id, 'purchases.return'
  from public.roles r
 where r.is_system and r.code in ('DEALER_OWNER', 'ACCOUNTS')
on conflict do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0058_gst_input_tax.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0058 — Input tax credit: the half of GST the product could not report
-- =============================================================================
-- Spec §16, §21, §24, §40, §41, §59.
--
-- What is missing. public.gst_summary() from 0026 reads sale_lines and
-- service_lines — outward supplies only. That was complete when it was written,
-- because nothing in the product recorded a purchase. 0052 then introduced
-- purchase bills and accounts 1900/1910/1920 for input CGST/SGST/IGST, and 0057
-- taught purchase returns to reverse them, and neither migration taught the GST
-- screens that any of it existed.
--
-- So a dealer's input tax credit sits correctly on the balance sheet and appears
-- nowhere in GST → Summary or GST → Reports. The figure a dealer actually needs
-- at filing time is not output tax, it is
--
--     output tax  −  input tax credit  =  what is paid to the government
--
-- and the product could state only the first term. A dealer reading these
-- screens would overstate their liability by exactly the ITC they are entitled
-- to claim, which for a live dealership after one month of stock purchases is
-- a large number in the wrong direction.
--
-- ── Where the HSN comes from ────────────────────────────────────────────────
--
-- Purchase lines do not carry an hsn_code column the way sale lines do: a sale
-- line freezes the HSN onto the invoice because that invoice is a legal document
-- the dealer issues, whereas a purchase line is evidence of someone else's
-- invoice, and its HSN belongs to the item. So this resolves HSN through the
-- item for counted goods and through the model for a vehicle, rather than
-- inventing a column that would only ever be copied from those.
--
-- ── Returns net off, they do not subtract separately ────────────────────────
--
-- A debit note reverses the ITC on the goods sent back (0057). It belongs in the
-- same HSN bucket as a negative, not in a separate "returns" report: the number
-- a dealer claims is the net for the period, and a report that shows purchases
-- and returns in two places invites claiming the gross.
--
-- ── Why the HSN description is not looked up by code ────────────────────────
--
-- hsn_codes is dealer-scoped: two tenants legitimately hold the same code, and
-- 87141090 exists for both dealers on the live system today. So a description
-- join written `on h.code = lines.hsn` matches once per tenant holding that
-- code, and because it is a join rather than a lookup, every matching line is
-- emitted twice and the aggregate doubles.
--
-- Under RLS that stays hidden — a signed-in user sees only their own tenant's
-- hsn_codes row, so the join matches once — which is exactly what makes it
-- dangerous: correct in the application, wrong for anything that reads with RLS
-- bypassed, and silently a factor of two rather than an error. gst_summary()
-- from 0026 carries the same join and is corrected below.
--
-- Rollback: drop function public.gst_input_summary(date, date, uuid);
--           restore public.gst_summary(date, date, uuid) from 0026.
-- =============================================================================

create or replace function public.gst_input_summary(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  hsn_code       text,
  description    text,
  taxable_value  numeric(18, 4),
  cgst_amount    numeric(18, 4),
  sgst_amount    numeric(18, 4),
  igst_amount    numeric(18, 4),
  total_tax      numeric(18, 4),
  document_count bigint
)
language sql
stable
as $$
  with lines as (
    -- What was bought.
    select coalesce(h.code, 'UNSPECIFIED') as hsn,
           coalesce(h.description, '') as descr,
           l.taxable_value, l.cgst_amount, l.sgst_amount, l.igst_amount,
           b.id as doc
      from public.purchase_bill_lines l
      join public.purchase_bills b on b.id = l.purchase_bill_id
      left join public.inventory_items i on i.id = l.item_id
      left join public.vehicles v on v.id = l.vehicle_id
      left join public.vehicle_models m on m.id = v.model_id
      left join public.hsn_codes h on h.id = coalesce(i.hsn_code_id, m.hsn_code_id)
     where b.status = 'POSTED'
       and b.bill_date between p_from and p_to
       and (p_branch_id is null or b.branch_id = p_branch_id)

    union all

    -- What went back, as negatives in the same bucket: the claim is the net.
    select coalesce(h.code, 'UNSPECIFIED'),
           coalesce(h.description, ''),
           -rl.taxable_value, -rl.cgst_amount, -rl.sgst_amount, -rl.igst_amount,
           r.id
      from public.purchase_return_lines rl
      join public.purchase_returns r on r.id = rl.purchase_return_id
      left join public.inventory_items i on i.id = rl.item_id
      left join public.vehicles v on v.id = rl.vehicle_id
      left join public.vehicle_models m on m.id = v.model_id
      left join public.hsn_codes h on h.id = coalesce(i.hsn_code_id, m.hsn_code_id)
     where r.status = 'POSTED'
       and r.return_date between p_from and p_to
       and (p_branch_id is null or r.branch_id = p_branch_id)
  )
  -- No join back to hsn_codes here: the description already travelled with the
  -- line, from the row identified by id. Matching on code would match once per
  -- tenant holding it (see the note above).
  select lines.hsn,
         max(lines.descr),
         sum(lines.taxable_value), sum(lines.cgst_amount), sum(lines.sgst_amount),
         sum(lines.igst_amount),
         sum(lines.cgst_amount + lines.sgst_amount + lines.igst_amount),
         count(distinct lines.doc)
    from lines
   group by lines.hsn
   order by lines.hsn;
$$;

comment on function public.gst_input_summary(date, date, uuid) is
  'HSN-wise input tax credit for a period (spec §40, §41): purchase bills less '
  'the debit notes that reversed them. The counterpart to gst_summary(), which '
  'reports only outward supplies.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.gst_input_summary(date, date, uuid) to authenticated';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.gst_summary() — the same description join, corrected
-- -----------------------------------------------------------------------------
-- Identical body to 0026 apart from the description lookup, which is now scoped
-- by dealer. A sale line freezes its HSN as text, so there is no id to travel
-- with the line as there is above; the join therefore has to carry the tenant.
-- -----------------------------------------------------------------------------
create or replace function public.gst_summary(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  hsn_code      text,
  description   text,
  taxable_value numeric(18, 4),
  cgst_amount   numeric(18, 4),
  sgst_amount   numeric(18, 4),
  igst_amount   numeric(18, 4),
  total_tax     numeric(18, 4),
  document_count bigint
)
language sql
stable
as $$
  with lines as (
    select coalesce(l.hsn_code, 'UNSPECIFIED') hsn, s.dealer_id, l.taxable_value,
           l.cgst_amount, l.sgst_amount, l.igst_amount, s.id doc
      from public.sale_lines l
      join public.sales s on s.id = l.sale_id
     where s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select coalesce(l.hsn_code, 'UNSPECIFIED'), si.dealer_id, l.taxable_value,
           l.cgst_amount, l.sgst_amount, l.igst_amount, si.id
      from public.service_lines l
      join public.service_invoices si on si.id = l.invoice_id
     where si.status = 'POSTED'
       and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
  )
  select lines.hsn,
         coalesce(max(h.description), ''),
         sum(lines.taxable_value), sum(lines.cgst_amount), sum(lines.sgst_amount),
         sum(lines.igst_amount),
         sum(lines.cgst_amount + lines.sgst_amount + lines.igst_amount),
         count(distinct lines.doc)
    from lines
    -- Scoped by dealer: the same code in another tenant is a different row and
    -- must not multiply this one.
    left join public.hsn_codes h
      on h.code = lines.hsn and h.dealer_id = lines.dealer_id
   group by lines.hsn
   order by lines.hsn;
$$;

comment on function public.gst_summary(date, date, uuid) is
  'HSN-wise output tax for a period (spec §41). Reads the tax stored on each line, '
  'not the current tax master, so historical figures never move (spec §16).';


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0059_schema_version_stamp.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0059 — A database that can say which migration it is on
-- =============================================================================
-- Spec §59, §60.20.
--
-- The problem this closes. The application deploys to Railway on push, while
-- migrations are applied to Supabase by hand. Those two facts guarantee a window
-- in which the running code expects a schema the database does not have, and
-- nothing anywhere reports it. The symptom reaches a user as a PostgREST error
-- about a function signature, which tells the person who pressed the button
-- nothing they can act on, and tells the person who could fix it nothing at all
-- because they are not the one who saw it.
--
-- Two services already work around this by hand — settlement-service.ts guesses
-- from an error string that 0050 is missing, sale-service.ts does the same for
-- 0051. Both are honest patches over a missing fact: the database does not know
-- what it is. So record it.
--
-- ── Why a table and not a setting ───────────────────────────────────────────
--
-- system_settings is dealer-scoped configuration that an administrator changes.
-- The schema version is neither: it is one fact about the whole database, it is
-- written by migrations rather than by people, and it is a list rather than a
-- value — knowing 0058 was applied on Tuesday and 0059 has not been applied at
-- all is the useful form. A table keeps the history; a setting would keep only
-- the last answer.
--
-- ── On the backfilled timestamps ────────────────────────────────────────────
--
-- Every migration before this one is inserted here as applied, because a
-- database running this file necessarily ran them: migrations are applied in
-- order, and both bundles are wrapped in a single transaction. Their applied_at
-- is therefore the moment this migration ran, not the moment they did. That is a
-- true statement about *what* is applied and a false one about *when*, so the
-- column is named and commented accordingly rather than pretending to a history
-- that was never recorded.
--
-- From here on each migration stamps itself as its last statement, and
-- `npm run check:schema-version` fails the build if one forgets.
--
-- Rollback: drop table public.schema_migrations.
-- =============================================================================

create table public.schema_migrations (
  version     text primary key,
  name        text not null,
  -- When this row was written, which for rows backfilled by 0059 is when
  -- 0059 ran rather than when the migration itself was applied.
  applied_at  timestamptz not null default now()
);

comment on table public.schema_migrations is
  'Which migrations this database has. Written by migrations, never by users. '
  'Compared against the version the running application was built against, so a '
  'deploy that has outrun its schema is visible instead of being guessed at from '
  'PostgREST error strings.';

-- Not tenant data: one row per migration, identical for every dealer on this
-- database. Every public table carries RLS regardless (verify-migrations.sh
-- checks), so the policy is an explicit "any session may read this" rather than
-- an absence of one.
alter table public.schema_migrations enable row level security;

create policy schema_migrations_read on public.schema_migrations
  for select to authenticated using (true);

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  -- Release-managed, like public.permissions: readable by any session, writable
  -- only by migrations running as the owner or the service role.
  execute 'revoke insert, update, delete on public.schema_migrations from authenticated';
end $$;

-- -----------------------------------------------------------------------------
-- Backfill: everything up to and including this migration
-- -----------------------------------------------------------------------------
insert into public.schema_migrations (version, name) values
    ('0001', 'extensions_and_app_schema'),
    ('0002', 'organization'),
    ('0003', 'identity'),
    ('0004', 'rls_helpers'),
    ('0005', 'audit'),
    ('0006', 'document_sequences'),
    ('0007', 'accounting_core'),
    ('0008', 'system_settings'),
    ('0009', 'rls_policies'),
    ('0010', 'indexes'),
    ('0011', 'grants'),
    ('0012', 'reporting_functions'),
    ('0013', 'customers'),
    ('0014', 'tax_and_hsn'),
    ('0015', 'vehicle_catalogue'),
    ('0016', 'inventory_items'),
    ('0017', 'vehicle_stock'),
    ('0018', 'vehicle_pricing'),
    ('0019', 'inventory_stock'),
    ('0020', 'bookings_and_sales'),
    ('0021', 'finance'),
    ('0022', 'cash_and_bank'),
    ('0023', 'service'),
    ('0024', 'gst_and_accounting_rules'),
    ('0025', 'posting_engine'),
    ('0026', 'reports'),
    ('0027', 'default_accounting_rules'),
    ('0028', 'booking_and_sale_operations'),
    ('0029', 'create_sale_draft'),
    ('0030', 'cash_operations'),
    ('0031', 'bank_operations'),
    ('0032', 'bank_entry_permission'),
    ('0033', 'service_operations'),
    ('0034', 'gst_reports'),
    ('0035', 'mis_reports'),
    ('0036', 'transfers_returns_adjustments'),
    ('0037', 'customer_ledger_opening'),
    ('0038', 'delivery_document_sequence'),
    ('0039', 'dealer_wide_document_numbering'),
    ('0040', 'suppliers'),
    ('0041', 'party_ledger_and_supplier_payments'),
    ('0042', 'finance_accounting_rules'),
    ('0043', 'finance_operations'),
    ('0044', 'price_approval_workflow'),
    ('0045', 'customer_vehicle_writer'),
    ('0046', 'booking_advances'),
    ('0047', 'counter_sales'),
    ('0048', 'einvoice_payload'),
    ('0049', 'cash_book_and_cogs_classification'),
    ('0050', 'party_payment_allocation'),
    ('0051', 'sale_return_refund'),
    ('0052', 'purchases'),
    ('0053', 'hr_foundations'),
    ('0054', 'attendance_integration'),
    ('0055', 'dealer_status_gate'),
    ('0056', 'dealer_provisioning'),
    ('0057', 'purchase_returns'),
    ('0058', 'gst_input_tax'),
    ('0059', 'schema_version_stamp')
on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0060_list_totals.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0060 — Totals that do not depend on how many rows the screen drew
-- =============================================================================
-- Spec §41, §43, §51, §59.
--
-- The bug. A screen loads a capped list and then reduces over it to render the
-- figures at the top:
--
--     const rows   = await getFinanceApplications({ status, q });  -- limit 200
--     const totals = summarise(rows);                              -- "the period"
--
-- Under demo data every one of these is right, because there are never 200 rows.
-- A dealer passes 200 finance applications or 200 service invoices inside a
-- month, and from then on the tiles quietly report the most recent 200 while
-- presenting themselves as the period. The table underneath looks correct, which
-- is what makes it hard to notice: nothing is visibly broken, the numbers are
-- just smaller than the truth and drifting further every week.
--
-- A wrong total that announces itself is a bug. A wrong total that looks
-- plausible is a decision made on bad information.
--
-- ── Why SQL and not a bigger limit ──────────────────────────────────────────
--
-- Raising the cap moves the cliff, it does not remove it, and it makes the page
-- slower for everyone to postpone a wrong answer for whoever grows fastest. An
-- aggregate computed in Postgres has no cliff: it reads what matches and returns
-- one row.
--
-- ── Why the finance list moves here too ─────────────────────────────────────
--
-- getFinanceApplications() applied its search *in TypeScript, after* the limit,
-- so searching for a customer whose application was the 250th most recent
-- returned nothing — the row was never fetched. Fixing the totals alone would
-- have left the list and the totals disagreeing about what "matching" means, so
-- both now come from the same WHERE clause in this file. Two functions that must
-- agree should read one definition, not two copies of one.
--
-- Both are `stable` and `security invoker`, so RLS decides what a session may
-- count — a total that includes rows the reader may not see would be a leak.
--
-- Rollback: drop the three functions below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- app.finance_application_match() — the shared predicate
-- -----------------------------------------------------------------------------
-- One definition of "matching", used by both the list and the totals. Inlined by
-- the planner; it exists so the two can never drift apart.
-- -----------------------------------------------------------------------------
create or replace function app.finance_application_match(
  p_status     text,
  p_row_status text,
  p_branch     uuid,
  p_row_branch uuid,
  p_q          text,
  p_haystack   text
)
returns boolean
language sql
immutable
as $$
  select (p_status is null or p_status = 'ALL' or p_row_status = p_status)
     and (p_branch is null or p_row_branch = p_branch)
     and (
       p_q is null
       or btrim(p_q) = ''
       or p_haystack ilike '%' || btrim(p_q) || '%'
     );
$$;

comment on function app.finance_application_match(text, text, uuid, uuid, text, text) is
  'Whether one finance application matches the screen filters. Shared by '
  'finance_applications_list and finance_application_totals so a searched list '
  'and its summary can never disagree about what was counted.';

-- -----------------------------------------------------------------------------
-- public.finance_applications_list() — the rows a screen draws
-- -----------------------------------------------------------------------------
create or replace function public.finance_applications_list(
  p_status    text default 'ALL',
  p_branch_id uuid default null,
  p_q         text default null,
  p_limit     integer default 200
)
returns table (
  id                  uuid,
  application_number  text,
  application_date    date,
  customer_id         uuid,
  customer_name       text,
  finance_company_id  uuid,
  company_name        text,
  chassis_no          text,
  branch_name         text,
  loan_amount         numeric(18, 4),
  down_payment        numeric(18, 4),
  approved_amount     numeric(18, 4),
  disbursed_amount    numeric(18, 4),
  pending_amount      numeric(18, 4),
  approval_status     text,
  disbursement_status text,
  dd_number           text,
  bank_reference      text,
  commission_amount   numeric(18, 4)
)
language sql
stable
as $$
  select f.id, f.application_number, f.application_date,
         f.customer_id, c.name, f.finance_company_id, fc.name,
         v.chassis_no, b.name,
         f.loan_amount, f.down_payment, f.approved_amount, f.disbursed_amount,
         f.pending_amount, f.approval_status, f.disbursement_status,
         f.dd_number, f.bank_reference, f.commission_amount
    from public.finance_applications f
    join public.customers        c  on c.id  = f.customer_id
    join public.finance_companies fc on fc.id = f.finance_company_id
    join public.branches         b  on b.id  = f.branch_id
    left join public.vehicles    v  on v.id  = f.vehicle_id
   where app.finance_application_match(
           p_status, f.approval_status,
           p_branch_id, f.branch_id,
           p_q,
           f.application_number || ' ' || c.name || ' ' || fc.name ||
             ' ' || coalesce(v.chassis_no, '')
         )
   order by f.application_date desc, f.application_number desc
   limit greatest(p_limit, 1);
$$;

comment on function public.finance_applications_list(text, uuid, text, integer) is
  'Finance applications matching the screen filters (spec §27). The search runs '
  'here rather than in the application, which used to filter the already-capped '
  'page and so could not find the 250th row.';

-- -----------------------------------------------------------------------------
-- public.finance_application_totals() — the figures above the list
-- -----------------------------------------------------------------------------
-- No limit. This is the whole point: the tiles describe the period, not the page.
-- -----------------------------------------------------------------------------
create or replace function public.finance_application_totals(
  p_status    text default 'ALL',
  p_branch_id uuid default null,
  p_q         text default null
)
returns table (
  applications      bigint,
  approved          bigint,
  pending           bigint,
  rejected          bigint,
  loan_amount       numeric(18, 4),
  disbursed_amount  numeric(18, 4),
  pending_amount    numeric(18, 4),
  commission_amount numeric(18, 4)
)
language sql
stable
as $$
  select count(*),
         count(*) filter (where f.approval_status = 'APPROVED'),
         count(*) filter (where f.approval_status = 'PENDING'),
         count(*) filter (where f.approval_status = 'REJECTED'),
         coalesce(sum(f.loan_amount), 0),
         coalesce(sum(f.disbursed_amount), 0),
         coalesce(sum(f.pending_amount), 0),
         coalesce(sum(f.commission_amount), 0)
    from public.finance_applications f
    join public.customers         c  on c.id  = f.customer_id
    join public.finance_companies fc on fc.id = f.finance_company_id
    left join public.vehicles     v  on v.id  = f.vehicle_id
   where app.finance_application_match(
           p_status, f.approval_status,
           p_branch_id, f.branch_id,
           p_q,
           f.application_number || ' ' || c.name || ' ' || fc.name ||
             ' ' || coalesce(v.chassis_no, '')
         );
$$;

comment on function public.finance_application_totals(text, uuid, text) is
  'Finance figures over every matching application, not the page (spec §27, §51). '
  'commission_amount is summed here and dropped in the service layer for sessions '
  'without finance.commission.view — the redaction stays where it always was.';

-- -----------------------------------------------------------------------------
-- public.service_invoice_totals() — the figures above the service billing list
-- -----------------------------------------------------------------------------
create or replace function public.service_invoice_totals(
  p_status    text default 'ALL',
  p_branch_id uuid default null
)
returns table (
  invoices     bigint,
  total_amount numeric(18, 4),
  paid_amount  numeric(18, 4),
  balance      numeric(18, 4)
)
language sql
stable
as $$
  select count(*),
         coalesce(sum(si.total_amount), 0),
         coalesce(sum(si.paid_amount), 0),
         coalesce(sum(si.total_amount - si.paid_amount), 0)
    from public.service_invoices si
   -- Counter sales share this table but are their own screen (spec §33), and the
   -- list this summarises excludes them. A total counting both would not match
   -- the rows underneath it.
   where si.invoice_type = 'SERVICE'
     and (p_status is null or p_status = 'ALL' or si.status = p_status)
     and (p_branch_id is null or si.branch_id = p_branch_id);
$$;

comment on function public.service_invoice_totals(text, uuid) is
  'Billed and outstanding over every matching service invoice, not the page '
  '(spec §51). Excludes counter sales, matching the list it sits above.';

-- -----------------------------------------------------------------------------
-- public.bank_unreconciled_counts() — how many items each account still has
-- -----------------------------------------------------------------------------
-- The bank screen used to fetch every unreconciled transaction and count them in
-- JavaScript. That is the same defect in a quieter form: it works, it is slow in
-- proportion to how long the dealer has been trading, and it is wrong the moment
-- PostgREST is configured with a row ceiling — at which point the badge simply
-- stops going up and nobody can tell.
--
-- Counting is the database's job.
-- -----------------------------------------------------------------------------
create or replace function public.bank_unreconciled_counts()
returns table (
  bank_account_id uuid,
  unreconciled    bigint
)
language sql
stable
as $$
  select t.bank_account_id, count(*)
    from public.bank_transactions t
   where t.reconciled = false
     and t.status = 'ACTIVE'
   group by t.bank_account_id;
$$;

comment on function public.bank_unreconciled_counts() is
  'Unreconciled item count per bank account (spec §39). One grouped count rather '
  'than fetching every transaction to length-check it in the application.';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  execute 'grant execute on function public.finance_applications_list(text, uuid, text, integer) to authenticated';
  execute 'grant execute on function public.finance_application_totals(text, uuid, text) to authenticated';
  execute 'grant execute on function public.service_invoice_totals(text, uuid) to authenticated';
  execute 'grant execute on function public.bank_unreconciled_counts() to authenticated';
  execute 'grant execute on function app.finance_application_match(text, text, uuid, uuid, text, text) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0060', 'list_totals') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0061_idempotent_receipts.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0061 — A retried receipt is the same receipt (spec §50)
-- =============================================================================
-- Spec §50, §36, §37, §38, §48.
--
-- What is broken. record_sale_payment, record_cash_transaction and
-- record_bank_transaction have no duplicate protection of any kind. Submit one
-- twice — a double-click that outran the disabled button, a phone that retried
-- on a flaky shop connection, a browser that resent the POST — and the dealer
-- has two receipts, two journals, and a cash book that is over by the amount.
--
-- Nothing downstream catches it. These are not corrections that a later screen
-- reconciles; they are the primary record. The cash book balances perfectly
-- against a day that never happened.
--
-- ── The slot that was there and did nothing ─────────────────────────────────
--
-- record_sale_payment already passed an idempotency key to app.post_journal:
--
--     'receipt:' || v_rnumber
--
-- where v_rnumber is minted from the document sequence two lines earlier. A
-- fresh number every call, so the key is unique every call, so it can never
-- match — the parameter was filled in and inert. Journal-level protection would
-- not have been enough anyway: a second call getting the first journal id back
-- would still insert a second sale_payments row against it, putting the receipt
-- twice in the receipts list and once in the trial balance, hidden from the one
-- report that would have caught it.
--
-- So the guard belongs at the top of each function, on its own document table,
-- before any sequence is consumed.
--
-- ── Why not a generic idempotency table ─────────────────────────────────────
--
-- A shared app-level table would be a second source of truth that any direct
-- RPC call bypasses, and a check-then-insert against it has a race that a unique
-- constraint does not. The constraint *is* the mechanism. 0057 already works
-- this way for purchase returns; this follows it.
--
-- ── What is deliberately NOT changed ────────────────────────────────────────
--
-- post_vehicle_sale, post_purchase_bill and post_service_invoice accept a key
-- and default it to one derived from the document id — 'sale:' || id, and so on.
-- That is strictly better than a client-minted key for posting an existing
-- document: it dedupes across sessions, devices and page refreshes, because the
-- key is a property of the document rather than of a browser tab. They are left
-- alone on purpose.
--
-- The distinction worth keeping: *posting* an existing document derives its key
-- from the document; *creating* one has no id yet, so the caller must supply it.
-- This migration covers the second kind.
--
-- Rollback: restore the three functions from 0041 and 0049, then
--   alter table public.cash_transactions drop column idempotency_key;  (&c.)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The columns, and the constraints that do the actual work
-- -----------------------------------------------------------------------------
-- Partial unique indexes: null keys are exempt, so every existing row and every
-- caller that does not supply one is unaffected. Scoped by dealer, because one
-- tenant must not be able to poison another's key namespace.
alter table public.cash_transactions add column if not exists idempotency_key text;
alter table public.bank_transactions add column if not exists idempotency_key text;
alter table public.sale_payments     add column if not exists idempotency_key text;

create unique index if not exists cash_txn_idempotency_key
  on public.cash_transactions (dealer_id, idempotency_key) where idempotency_key is not null;
create unique index if not exists bank_txn_idempotency_key
  on public.bank_transactions (dealer_id, idempotency_key) where idempotency_key is not null;
create unique index if not exists sale_payment_idempotency_key
  on public.sale_payments (dealer_id, idempotency_key) where idempotency_key is not null;

comment on column public.cash_transactions.idempotency_key is
  'Caller-supplied key making a retry replay rather than repeat (spec §50). Null '
  'for entries made before 0061 and for callers that do not supply one.';

-- -----------------------------------------------------------------------------
-- public.record_cash_transaction() — spec §37, now idempotent
-- -----------------------------------------------------------------------------
-- Adding a parameter needs a drop: `create or replace` with a different argument
-- list makes an *overload*, and supabase-js sends named arguments, so a call
-- omitting the new one becomes ambiguous and fails with PGRST203. Precedent for
-- the drop-and-recreate is 0041 itself.
-- -----------------------------------------------------------------------------
drop function if exists public.record_cash_transaction(uuid, text, numeric, text, uuid, uuid, text, date, uuid);

create function public.record_cash_transaction(
  p_branch_id   uuid,
  p_direction   text,
  p_amount      numeric,
  p_particular  text,
  p_account_id  uuid,
  p_customer_id uuid default null,
  p_reference   text default null,
  p_date        date default current_date,
  p_supplier_id uuid default null,
  p_idempotency_key text default null
)
returns table (transaction_id bigint, journal_entry_id uuid, balance_after numeric)
language plpgsql
as $$
declare
  v_dealer   uuid;
  v_account  public.cash_accounts;
  v_entry    uuid;
  v_cash_acc uuid;
  v_txn      bigint;
  v_balance  numeric(18, 4);
  v_party    text;
  v_party_id uuid;
begin
  if p_amount <= 0 then
    raise exception 'The amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_direction not in ('RECEIPT', 'PAYMENT') then
    raise exception 'Direction must be RECEIPT or PAYMENT.' using errcode = 'check_violation';
  end if;
  -- A journal line carries one party. Two would make the entry belong to both
  -- subsidiary ledgers and reconcile against neither.
  if p_customer_id is not null and p_supplier_id is not null then
    raise exception 'An entry belongs to a customer or a supplier, not both.'
      using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer from public.branches where id = p_branch_id;

  -- ── The guard (spec §50) ────────────────────────────────────────────────
  -- Before ensure_cash_day, deliberately. A retry arriving after the day was
  -- closed must replay the receipt it already wrote, not raise "the day is
  -- closed" at someone who is looking at a spinner.
  if p_idempotency_key is not null then
    select t.id, t.journal_entry_id, t.balance_after
      into v_txn, v_entry, v_balance
      from public.cash_transactions t
     where t.dealer_id = v_dealer
       and t.idempotency_key = p_idempotency_key;

    if v_txn is not null then
      transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
      return next;
      return;
    end if;
  end if;

  select * into v_account from public.cash_accounts where branch_id = p_branch_id;

  if v_account.id is null then
    raise exception 'This branch has no cash account.' using errcode = 'no_data_found';
  end if;

  -- Opens the day if needed, and fails if it is already closed (spec §36).
  perform public.ensure_cash_day(p_branch_id, p_date);

  v_cash_acc := v_account.ledger_account_id;

  v_party := case
               when p_customer_id is not null then 'CUSTOMER'
               when p_supplier_id is not null then 'SUPPLIER'
             end;
  v_party_id := coalesce(p_customer_id, p_supplier_id);

  -- A receipt debits cash and credits whatever the money was for; a payment is
  -- the mirror. The contra account is chosen by the operator, because "what was
  -- this for" is a judgement the software cannot make.
  v_entry := app.post_journal(
    v_dealer, p_branch_id, p_date,
    'CASH',
    p_particular,
    case when p_direction = 'RECEIPT' then
      jsonb_build_array(
        jsonb_build_object('account_id', v_cash_acc, 'debit', p_amount, 'credit', 0,
                           'narration', p_particular),
        jsonb_build_object('account_id', p_account_id, 'debit', 0, 'credit', p_amount,
                           'narration', p_particular,
                           'party_type', v_party, 'party_id', v_party_id)
      )
    else
      jsonb_build_array(
        jsonb_build_object('account_id', p_account_id, 'debit', p_amount, 'credit', 0,
                           'narration', p_particular,
                           'party_type', v_party, 'party_id', v_party_id),
        jsonb_build_object('account_id', v_cash_acc, 'debit', 0, 'credit', p_amount,
                           'narration', p_particular)
      )
    end,
    'CASH_BOOK', null,
    case when p_idempotency_key is null then null else 'cash:' || p_idempotency_key end
  );

  insert into public.cash_transactions
    (dealer_id, branch_id, cash_account_id, business_date, direction, amount,
     particular, reference_number, customer_id, supplier_id, journal_entry_id,
     idempotency_key, created_by)
  values
    (v_dealer, p_branch_id, v_account.id, p_date, p_direction, p_amount,
     p_particular, p_reference, p_customer_id, p_supplier_id, v_entry,
     p_idempotency_key, auth.uid())
  returning id, cash_transactions.balance_after into v_txn, v_balance;

  transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_bank_transaction() — spec §38, now idempotent
-- -----------------------------------------------------------------------------
drop function if exists public.record_bank_transaction(uuid, text, numeric, text, uuid, date, text, text, text, uuid, uuid);

create function public.record_bank_transaction(
  p_bank_account_id uuid,
  p_direction       text,
  p_amount          numeric,
  p_particular      text,
  p_account_id      uuid,
  p_date            date default current_date,
  p_reference       text default null,
  p_utr             text default null,
  p_instrument      text default null,
  p_customer_id     uuid default null,
  p_supplier_id     uuid default null,
  p_idempotency_key text default null
)
returns table (transaction_id bigint, journal_entry_id uuid, balance_after numeric)
language plpgsql
as $$
declare
  v_bank     public.bank_accounts;
  v_entry    uuid;
  v_txn      bigint;
  v_balance  numeric(18, 4);
  v_party    text;
  v_party_id uuid;
begin
  if p_amount <= 0 then
    raise exception 'The amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_direction not in ('RECEIPT', 'PAYMENT') then
    raise exception 'Direction must be RECEIPT or PAYMENT.' using errcode = 'check_violation';
  end if;
  if p_customer_id is not null and p_supplier_id is not null then
    raise exception 'An entry belongs to a customer or a supplier, not both.'
      using errcode = 'check_violation';
  end if;

  select * into v_bank from public.bank_accounts where id = p_bank_account_id;
  if v_bank.id is null then
    raise exception 'Bank account not found.' using errcode = 'no_data_found';
  end if;

  -- ── The guard (spec §50) ────────────────────────────────────────────────
  -- Before the ACTIVE check, for the same reason the cash guard precedes the
  -- day-close check: a retry must replay what it wrote, not report a state that
  -- changed after it wrote it.
  if p_idempotency_key is not null then
    select t.id, t.journal_entry_id, t.balance_after
      into v_txn, v_entry, v_balance
      from public.bank_transactions t
     where t.dealer_id = v_bank.dealer_id
       and t.idempotency_key = p_idempotency_key;

    if v_txn is not null then
      transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
      return next;
      return;
    end if;
  end if;

  if v_bank.status <> 'ACTIVE' then
    raise exception 'Bank account % is %.', v_bank.name, v_bank.status
      using errcode = 'check_violation';
  end if;

  v_party := case
               when p_customer_id is not null then 'CUSTOMER'
               when p_supplier_id is not null then 'SUPPLIER'
             end;
  v_party_id := coalesce(p_customer_id, p_supplier_id);

  v_entry := app.post_journal(
    v_bank.dealer_id, v_bank.branch_id, p_date,
    'BANK',
    p_particular,
    case when p_direction = 'RECEIPT' then
      jsonb_build_array(
        jsonb_build_object('account_id', v_bank.ledger_account_id, 'debit', p_amount, 'credit', 0,
                           'narration', p_particular),
        jsonb_build_object('account_id', p_account_id, 'debit', 0, 'credit', p_amount,
                           'narration', p_particular,
                           'party_type', v_party, 'party_id', v_party_id)
      )
    else
      jsonb_build_array(
        jsonb_build_object('account_id', p_account_id, 'debit', p_amount, 'credit', 0,
                           'narration', p_particular,
                           'party_type', v_party, 'party_id', v_party_id),
        jsonb_build_object('account_id', v_bank.ledger_account_id, 'debit', 0, 'credit', p_amount,
                           'narration', p_particular)
      )
    end,
    'BANK_BOOK', null,
    case when p_idempotency_key is null then null else 'bank:' || p_idempotency_key end
  );

  insert into public.bank_transactions
    (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
     reference_number, utr, instrument_number, customer_id, supplier_id,
     journal_entry_id, idempotency_key, created_by)
  values
    (v_bank.dealer_id, p_bank_account_id, p_date, p_direction, p_amount, p_particular,
     p_reference, nullif(btrim(p_utr), ''), nullif(btrim(p_instrument), ''),
     p_customer_id, p_supplier_id, v_entry, p_idempotency_key, auth.uid())
  returning id, bank_transactions.balance_after into v_txn, v_balance;

  transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
  return next;
end;
$$;


-- -----------------------------------------------------------------------------
-- public.record_sale_payment() — spec §19, §27, now idempotent
-- -----------------------------------------------------------------------------
-- The one with no defence whatever: a POSTED sale accepts payments repeatedly by
-- design, which is correct — a customer may pay in instalments — and is exactly
-- why a repeated submission is indistinguishable from a second instalment
-- without a key to tell them apart.
-- -----------------------------------------------------------------------------
drop function if exists public.record_sale_payment(uuid, numeric, text, text, uuid);

create function public.record_sale_payment(
  p_sale_id      uuid,
  p_amount       numeric,
  p_payment_mode text,
  p_reference    text default null,
  p_finance_company_id uuid default null,
  p_idempotency_key text default null
)
returns table (receipt_number text, journal_entry_id uuid)
language plpgsql
as $$
declare
  v_sale     public.sales;
  v_year     text;
  v_rnumber  text;
  v_entry    uuid;
  v_debit    uuid;
  v_credit   uuid;
  v_component text;
  v_party    text;
  v_party_id uuid;
begin
  if p_amount <= 0 then
    raise exception 'The payment amount must be greater than zero.' using errcode = 'check_violation';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;
  if v_sale.id is null then
    raise exception 'Sale not found.' using errcode = 'no_data_found';
  end if;
  -- ── The guard (spec §50) ────────────────────────────────────────────────
  -- After the row lock, so a concurrent retry waits rather than racing; before
  -- the status check, so a retry arriving after delivery replays its receipt
  -- instead of raising; and before next_document_number, so a replay does not
  -- burn a RECEIPT number. A gap in a financial series is not cosmetic.
  if p_idempotency_key is not null then
    select p.receipt_number, p.journal_entry_id
      into receipt_number, journal_entry_id
      from public.sale_payments p
     where p.dealer_id = v_sale.dealer_id
       and p.idempotency_key = p_idempotency_key;

    if receipt_number is not null then
      return next;
      return;
    end if;
  end if;

  if v_sale.status not in ('POSTED', 'DELIVERED') then
    raise exception 'Payments can only be recorded against a posted invoice; this one is %.', v_sale.status
      using errcode = 'check_violation';
  end if;

  v_year := app.financial_year_token(v_sale.dealer_id, current_date);
  v_rnumber := app.next_document_number(v_sale.dealer_id, v_sale.branch_id, 'RECEIPT', v_year);

  -- Finance disbursement moves the debt to the finance company rather than
  -- settling it in cash (spec §27).
  if p_payment_mode = 'FINANCE' then
    if p_finance_company_id is null then
      raise exception 'A finance payment must name the finance company carrying the debt.'
        using errcode = 'check_violation';
    end if;
    v_component := 'FINANCE_RECEIVABLE';
    v_debit  := app.require_account(v_sale.dealer_id, 'FINANCE', 'INVOICE', 'FINANCE_RECEIVABLE', v_sale.branch_id);
    v_party := 'FINANCE_COMPANY';
    v_party_id := p_finance_company_id;
  else
    v_component := case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end;
    v_debit := app.require_account(
      v_sale.dealer_id,
      case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
      'RECEIPT', v_component, v_sale.branch_id);
  end if;

  v_credit := app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'RECEIVABLE', v_sale.branch_id);

  v_entry := app.post_journal(
    v_sale.dealer_id, v_sale.branch_id, current_date,
    case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
    'Receipt ' || v_rnumber || ' against ' || v_sale.invoice_number,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', p_payment_mode || ' received',
                         'party_type', v_party, 'party_id', v_party_id),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', 'Against ' || v_sale.invoice_number,
                         'party_type', 'CUSTOMER', 'party_id', v_sale.customer_id)
    ),
    'SALE_PAYMENT', p_sale_id,
    -- Was 'receipt:' || v_rnumber, which is minted from the sequence a few lines
    -- above: a different key on every call, so it could never match and the
    -- parameter did nothing. The caller's key is the one that can.
    coalesce('receipt:' || p_idempotency_key, 'receipt:' || v_rnumber)
  );

  insert into public.sale_payments
    (dealer_id, sale_id, receipt_number, amount, payment_mode, reference,
     finance_company_id, journal_entry_id, idempotency_key, created_by)
  values
    (v_sale.dealer_id, p_sale_id, v_rnumber, p_amount, p_payment_mode, p_reference,
     p_finance_company_id, v_entry, p_idempotency_key, auth.uid());

  -- The company now owes the dealer for this vehicle, so its position rises.
  if p_payment_mode = 'FINANCE' then
    insert into public.finance_transactions
      (dealer_id, branch_id, finance_company_id, transaction_date, transaction_type,
       debit, credit, reference_type, reference_id, reference_number, narration,
       sale_id, journal_entry_id, created_by)
    values
      (v_sale.dealer_id, v_sale.branch_id, p_finance_company_id, current_date, 'VEHICLE_ADJUSTMENT',
       0, p_amount, 'SALE', p_sale_id, v_sale.invoice_number,
       'Financed ' || v_sale.invoice_number, p_sale_id, v_entry, auth.uid());
  end if;

  -- 0049: FINANCE returns immediately inside the helper — no money has moved.
  perform app.record_money_movement(
    v_sale.dealer_id, v_sale.branch_id, current_date, p_payment_mode, 'RECEIPT',
    p_amount, 'Receipt ' || v_rnumber || ' — ' || v_sale.invoice_number,
    coalesce(p_reference, v_rnumber), v_entry, v_sale.customer_id);

  receipt_number := v_rnumber; journal_entry_id := v_entry;
  return next;
end;
$$;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  -- Grants are per-signature and were dropped with the old functions.
  execute 'grant execute on function public.record_cash_transaction(uuid, text, numeric, text, uuid, uuid, text, date, uuid, text) to authenticated';
  execute 'grant execute on function public.record_bank_transaction(uuid, text, numeric, text, uuid, date, text, text, text, uuid, uuid, text) to authenticated';
  execute 'grant execute on function public.record_sale_payment(uuid, numeric, text, text, uuid, text) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0061', 'idempotent_receipts') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0062_idempotent_sale_draft.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0062 — The dead column on public.sales, finally written to
-- =============================================================================
-- Spec §50, §45, §19.
--
-- sales.idempotency_key and its unique index have existed since 0020. Nothing
-- has ever written them: create_vehicle_sale_draft took no key, so the column
-- was null on every row and the index guarded nothing. A guarantee that is
-- declared and not wired is worse than an absent one, because it reads as
-- handled.
--
-- What happens today without it. A double-submitted sale is caught — but by
-- sales_vehicle_active_key, the unique index on the chassis, and only *after*
-- app.next_document_number has issued an invoice number and the transaction has
-- rolled it away. The dealer is protected from a duplicate sale and left with a
-- hole in the invoice series, which under GST is not a cosmetic problem: the
-- series is expected to be continuous, and every gap is a question to answer at
-- filing time.
--
-- The guard therefore goes before the number is drawn, and before the
-- availability check — a retry arriving after the first call moved the chassis
-- to SOLD_PENDING_DELIVERY must replay its draft, not report the vehicle as
-- unavailable to someone who is looking at a spinner.
--
-- Rollback: restore create_vehicle_sale_draft from 0029.
-- =============================================================================

drop function if exists public.create_vehicle_sale_draft(uuid, uuid, date, uuid, uuid, numeric, text);

create function public.create_vehicle_sale_draft(
  p_customer_id  uuid,
  p_vehicle_id   uuid,
  p_invoice_date date default current_date,
  p_booking_id   uuid default null,
  p_sales_executive_id uuid default null,
  p_discount     numeric default 0,
  p_notes        text default null,
  p_idempotency_key text default null
)
returns table (sale_id uuid, invoice_number text, total_amount numeric)
language plpgsql
as $$
declare
  v_vehicle  public.vehicles;
  v_price    record;
  v_tax      record;
  v_dealer   uuid;
  v_year     text;
  v_number   text;
  v_sale     uuid;
  v_line     smallint := 0;
  v_hsn      text;
  v_model_tax text;
begin
  select * into v_vehicle from public.vehicles where id = p_vehicle_id for update;

  if v_vehicle.id is null then
    raise exception 'Vehicle not found.' using errcode = 'no_data_found';
  end if;
  v_dealer := v_vehicle.dealer_id;

  -- ── The guard (spec §50) ────────────────────────────────────────────────
  -- Before the availability check, deliberately. A retry arriving after the
  -- vehicle has moved to SOLD_PENDING_DELIVERY — which the first call did —
  -- must replay the draft it created, not report the chassis as unavailable.
  --
  -- And long before next_document_number. sales_vehicle_active_key already
  -- rejected a second draft for the same chassis, but only *after* an invoice
  -- number had been issued and thrown away, leaving a hole in the GST series
  -- that has to be explained at filing time.
  if p_idempotency_key is not null then
    select s.id, s.invoice_number into v_sale, v_number
      from public.sales s
     where s.dealer_id = v_dealer
       and s.idempotency_key = p_idempotency_key;

    if v_sale is not null then
      sale_id := v_sale;
      invoice_number := v_number;
      select s.total_amount into total_amount from public.sales s where s.id = v_sale;
      return next;
      return;
    end if;
  end if;

  if v_vehicle.status not in ('IN_STOCK', 'BOOKED') then
    raise exception 'Vehicle % is % and is not available for sale.', v_vehicle.chassis_no, v_vehicle.status
      using errcode = 'check_violation';
  end if;

  -- The price in force on the invoice date, not today's price (spec §42).
  select * into v_price
    from public.resolve_vehicle_price(v_dealer, v_vehicle.model_id, v_vehicle.variant_id,
                                      v_vehicle.branch_id, p_invoice_date);

  if v_price.price_version_id is null then
    raise exception 'No price is configured for this model on %.', p_invoice_date
      using errcode = 'no_data_found',
            hint = 'Add a price version before selling this model.';
  end if;

  select m.tax_code, h.code into v_model_tax, v_hsn
    from public.vehicle_models m
    left join public.hsn_codes h on h.id = m.hsn_code_id
   where m.id = v_vehicle.model_id;

  select * into v_tax
    from public.resolve_tax_code(v_dealer, coalesce(v_price.tax_code, v_model_tax), p_invoice_date);

  v_year := app.financial_year_token(v_dealer, p_invoice_date);
  v_number := app.next_document_number(v_dealer, v_vehicle.branch_id, 'VEHICLE_INVOICE', v_year);

  insert into public.sales
    (dealer_id, branch_id, invoice_number, invoice_date, customer_id, vehicle_id,
     booking_id, price_version_id, sales_executive_id, notes, idempotency_key, created_by)
  values
    (v_dealer, v_vehicle.branch_id, v_number, p_invoice_date, p_customer_id, p_vehicle_id,
     p_booking_id, v_price.price_version_id, p_sales_executive_id, p_notes,
     p_idempotency_key, auth.uid())
  returning id into v_sale;

  -- ── One line per price component (spec §20) ───────────────────────────────
  -- Only the vehicle itself carries GST here; insurance and registration are
  -- pass-through in most dealer setups, and forwarding is taxed separately by
  -- configuration. A dealer whose treatment differs edits the lines before
  -- submitting, which is why the invoice is a draft first.
  if v_price.ex_showroom > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, hsn_code, quantity, unit_rate,
       taxable_value, tax_code, cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount,
       unit_cost, cost_amount)
    values
      (v_sale, v_dealer, v_line, 'VEHICLE',
       coalesce((select m.brand || ' ' || m.name from public.vehicle_models m where m.id = v_vehicle.model_id), 'Vehicle'),
       v_hsn, 1, v_price.ex_showroom, v_price.ex_showroom,
       v_tax.code, coalesce(v_tax.cgst_rate, 0), coalesce(v_tax.sgst_rate, 0),
       round(v_price.ex_showroom * coalesce(v_tax.cgst_rate, 0) / 100, 2),
       round(v_price.ex_showroom * coalesce(v_tax.sgst_rate, 0) / 100, 2),
       v_price.ex_showroom
         + round(v_price.ex_showroom * coalesce(v_tax.cgst_rate, 0) / 100, 2)
         + round(v_price.ex_showroom * coalesce(v_tax.sgst_rate, 0) / 100, 2),
       -- COGS uses what this specific unit cost, not the price master's figure.
       v_vehicle.purchase_cost, v_vehicle.purchase_cost);
  end if;

  if v_price.insurance > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'INSURANCE', 'Insurance', 1,
            v_price.insurance, v_price.insurance, v_price.insurance);
  end if;

  if v_price.registration > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'REGISTRATION', 'Registration (LTRT)', 1,
            v_price.registration, v_price.registration, v_price.registration);
  end if;

  if v_price.mandatory_accessories > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'ACCESSORY', 'Mandatory accessories', 1,
            v_price.mandatory_accessories, v_price.mandatory_accessories, v_price.mandatory_accessories);
  end if;

  if v_price.forwarding_charge > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'FORWARDING', 'Forwarding charges', 1,
            v_price.forwarding_charge, v_price.forwarding_charge, v_price.forwarding_charge);
  end if;

  if v_price.other_charges > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'OTHER_CHARGE', 'Other charges', 1,
            v_price.other_charges, v_price.other_charges, v_price.other_charges);
  end if;

  -- A discount beyond what the price version permits is a policy breach, not a
  -- rounding difference (spec §15).
  if p_discount > 0 then
    if p_discount > v_price.max_discount then
      raise exception 'A discount of % exceeds the maximum of % allowed on this price version.',
        p_discount, v_price.max_discount
        using errcode = 'check_violation';
    end if;
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       discount, taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'DISCOUNT', 'Discount', 1, 0, p_discount, 0, 0);
  end if;

  -- Reserve the chassis so no other draft can claim it (spec §49).
  if v_vehicle.status = 'IN_STOCK' then
    update public.vehicles set status = 'BOOKED', updated_by = auth.uid() where id = p_vehicle_id;
  end if;

  -- Converting a booking closes it.
  if p_booking_id is not null then
    update public.bookings
       set status = 'CONVERTED', converted_sale_id = v_sale, updated_by = auth.uid()
     where id = p_booking_id and status = 'OPEN';
  end if;

  sale_id := v_sale;
  invoice_number := v_number;
  select s.total_amount into total_amount from public.sales s where s.id = v_sale;
  return next;
end;
$$;

comment on function public.create_vehicle_sale_draft(uuid, uuid, date, uuid, uuid, numeric, text, text) is
  'Creates a DRAFT vehicle sale priced at the invoice date (spec §19, §42). '
  'A repeated call carrying the same idempotency key replays the draft it made '
  'rather than drawing a second invoice number (spec §50).';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  -- Per-signature, and the old one went with the drop.
  execute 'grant execute on function public.create_vehicle_sale_draft(uuid, uuid, date, uuid, uuid, numeric, text, text) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0062', 'idempotent_sale_draft') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0063_idempotent_second_wave.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0063 — Idempotency for the remaining money endpoints (spec §50)
-- =============================================================================
-- Spec §50, §18, §26, §32, §33.
--
-- 0061 and 0062 covered the endpoints a cashier touches most: sale payments,
-- cash, bank, and the sale draft. These five are the rest of the money surface —
-- service receipts, counter invoices, booking advances, advance refunds and
-- finance-company trade advances. Every one of them writes a document and a
-- journal, and every one of them could be submitted twice.
--
-- Three different shapes turned up, which is worth recording because the third
-- is the one that looks safe:
--
--   1. No protection at all — record_service_payment and record_trade_advance
--      passed a null idempotency key to app.post_journal.
--
--   2. A key that could never match — create_booking_with_advance passed
--      'booking:' || v_booking, minted from the row it had just inserted. The
--      same defect 0061 found in record_sale_payment: the parameter was filled
--      in and inert.
--
--   3. A deterministic key that made things *worse* — refund_booking_advance
--      passes 'booking-refund:<booking>:<amount>', which is stable across calls,
--      so app.post_journal correctly replays the first journal on a second call.
--      The function then carried on and inserted a second cash or bank row
--      against that replayed journal. The refund appeared twice in the cash book
--      and once in the ledger: over-reported on the day sheet, and invisible to
--      the trial balance that would otherwise have caught it. Half a guard was
--      worse than none, because it moved the damage somewhere nobody reconciles.
--
-- The fix in all three cases is the same and is the rule 0061 established: guard
-- at the top of the function, on its own document table, before any sequence is
-- consumed and before any row is written.
--
-- Rollback: restore these five from 0043, 0046, 0047 and 0049, then drop the
-- three columns added below.
-- =============================================================================

-- service_invoices has carried idempotency_key since 0023 and bookings did not;
-- the partial unique indexes exempt nulls, so nothing that predates this or
-- declines to opt in is affected.
alter table public.service_payments     add column if not exists idempotency_key text;
alter table public.bookings             add column if not exists idempotency_key text;
alter table public.finance_transactions add column if not exists idempotency_key text;

create unique index if not exists service_payment_idempotency_key
  on public.service_payments (dealer_id, idempotency_key) where idempotency_key is not null;
create unique index if not exists booking_idempotency_key
  on public.bookings (dealer_id, idempotency_key) where idempotency_key is not null;
create unique index if not exists finance_txn_idempotency_key
  on public.finance_transactions (dealer_id, idempotency_key) where idempotency_key is not null;

-- -----------------------------------------------------------------------------
-- public.record_service_payment() — spec §32, §33
-- -----------------------------------------------------------------------------
drop function if exists public.record_service_payment(uuid, numeric, text, text, date);

create function public.record_service_payment(
  p_invoice_id   uuid,
  p_amount       numeric,
  p_payment_mode text default 'CASH',
  p_reference    text default null,
  p_date         date default current_date,
  p_idempotency_key text default null
)
returns table (payment_id uuid, receipt_number text, balance_due numeric)
language plpgsql
as $$
declare
  v_invoice public.service_invoices;
  v_number  text;
  v_entry   uuid;
  v_debit   uuid;
  v_credit  uuid;
  v_id      uuid;
  v_balance numeric(18, 4);
begin
  select * into v_invoice from public.service_invoices where id = p_invoice_id for update;

  if v_invoice.id is null then
    raise exception 'Invoice not found.' using errcode = 'no_data_found';
  end if;
  -- The guard (spec §50): after the invoice lock, before the status and
  -- outstanding checks, and well before next_document_number. A retry arriving
  -- once the invoice is fully paid must replay its receipt, not be told the
  -- amount exceeds what is outstanding.
  if p_idempotency_key is not null then
    select p.id, p.receipt_number into v_id, v_number
      from public.service_payments p
     where p.dealer_id = v_invoice.dealer_id
       and p.idempotency_key = p_idempotency_key;

    if v_id is not null then
      select si.total_amount - si.paid_amount into v_balance
        from public.service_invoices si where si.id = p_invoice_id;
      payment_id := v_id; receipt_number := v_number; balance_due := v_balance;
      return next;
      return;
    end if;
  end if;

  if v_invoice.status <> 'POSTED' then
    raise exception 'Invoice % is % — only a posted invoice can take a payment.',
      v_invoice.invoice_number, v_invoice.status using errcode = 'check_violation';
  end if;
  if p_amount <= 0 then
    raise exception 'The payment amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_amount > v_invoice.total_amount - v_invoice.paid_amount then
    raise exception 'That is more than the % outstanding on this invoice.',
      v_invoice.total_amount - v_invoice.paid_amount using errcode = 'check_violation';
  end if;

  v_number := app.next_document_number(
    v_invoice.dealer_id, v_invoice.branch_id, 'RECEIPT',
    app.financial_year_token(v_invoice.dealer_id, p_date));

  v_debit := app.require_account(
    v_invoice.dealer_id,
    case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
    'RECEIPT',
    case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
    v_invoice.branch_id);

  v_credit := app.require_account(v_invoice.dealer_id, 'SERVICE', 'INVOICE', 'RECEIVABLE', v_invoice.branch_id);

  v_entry := app.post_journal(
    v_invoice.dealer_id, v_invoice.branch_id, p_date,
    case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
    'Receipt ' || v_number || ' against ' || v_invoice.invoice_number,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', v_number),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', v_invoice.invoice_number,
                         'party_type', case when v_invoice.customer_id is not null then 'CUSTOMER' end,
                         'party_id', v_invoice.customer_id)
    ),
    'SERVICE_RECEIPT', p_invoice_id, null);

  insert into public.service_payments
    (dealer_id, invoice_id, receipt_number, payment_date, amount, payment_mode,
     reference, journal_entry_id, idempotency_key, created_by)
  values
    (v_invoice.dealer_id, p_invoice_id, v_number, p_date, p_amount, p_payment_mode,
     p_reference, v_entry, p_idempotency_key, auth.uid())
  returning id into v_id;

  -- 0049: counter and workshop takings reach the cash book.
  perform app.record_money_movement(
    v_invoice.dealer_id, v_invoice.branch_id, p_date, p_payment_mode, 'RECEIPT',
    p_amount, 'Receipt ' || v_number || ' — ' || v_invoice.invoice_number,
    coalesce(p_reference, v_number), v_entry, v_invoice.customer_id);

  select si.total_amount - si.paid_amount into v_balance
    from public.service_invoices si where si.id = p_invoice_id;

  payment_id := v_id; receipt_number := v_number; balance_due := v_balance;
  return next;
end;
$$;
-- -----------------------------------------------------------------------------
-- public.create_counter_invoice() — spec §33
-- -----------------------------------------------------------------------------
drop function if exists public.create_counter_invoice(uuid, uuid, date);

create function public.create_counter_invoice(
  p_branch_id    uuid,
  p_customer_id  uuid default null,
  p_invoice_date date default current_date,
  p_idempotency_key text default null
)
returns table (invoice_id uuid, invoice_number text)
language plpgsql
as $$
declare
  v_dealer   uuid;
  v_number   text;
  v_id       uuid;
  v_required boolean;
begin
  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  -- The guard (spec §50). service_invoices has carried idempotency_key since
  -- 0023 for the workshop side; the counter never used it.
  if p_idempotency_key is not null then
    select si.id, si.invoice_number into v_id, v_number
      from public.service_invoices si
     where si.dealer_id = v_dealer
       and si.idempotency_key = p_idempotency_key;

    if v_id is not null then
      invoice_id := v_id; invoice_number := v_number;
      return next;
      return;
    end if;
  end if;

  select coalesce((value)::text = 'true', false) into v_required
    from public.system_settings
   where key = 'counter_sale.require_customer'
     and (dealer_id = v_dealer or dealer_id is null)
   order by dealer_id nulls last
   limit 1;

  if coalesce(v_required, false) and p_customer_id is null then
    raise exception 'This dealer requires a customer on every counter sale.'
      using errcode = 'check_violation',
            hint = 'Spec §33: the customer is optional or required by configuration.';
  end if;

  v_number := app.next_document_number(
    v_dealer, p_branch_id, 'COUNTER_INVOICE',
    app.financial_year_token(v_dealer, p_invoice_date));

  insert into public.service_invoices
    (dealer_id, branch_id, invoice_number, invoice_date, invoice_type,
     job_card_id, customer_id, idempotency_key, created_by)
  values
    (v_dealer, p_branch_id, v_number, p_invoice_date, 'COUNTER',
     null, p_customer_id, p_idempotency_key, auth.uid())
  returning id into v_id;

  invoice_id := v_id; invoice_number := v_number;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.create_booking_with_advance() — spec §18
-- -----------------------------------------------------------------------------
drop function if exists public.create_booking_with_advance(uuid, uuid, uuid, numeric, numeric, text, uuid, uuid, date, uuid, text, text);

create function public.create_booking_with_advance(
  p_customer_id       uuid,
  p_model_id          uuid,
  p_branch_id         uuid,
  p_booking_amount    numeric,
  p_advance_amount    numeric,
  p_payment_mode      text,
  p_variant_id        uuid default null,
  p_vehicle_id        uuid default null,
  p_expected_delivery date default null,
  p_sales_executive_id uuid default null,
  p_reference         text default null,
  p_notes             text default null,
  p_idempotency_key   text default null
)
returns table (booking_id uuid, booking_number text, receipt_number text, journal_entry_id uuid)
language plpgsql
as $$
declare
  v_dealer_id uuid;
  v_year      text;
  v_booking   uuid;
  v_bnumber   text;
  v_rnumber   text;
  v_entry     uuid;
  v_debit_acc uuid;
  v_credit_acc uuid;
  v_cash_component text;
begin
  if p_advance_amount <= 0 then
    raise exception 'The advance amount must be greater than zero.'
      using errcode = 'check_violation';
  end if;
  if p_booking_amount > 0 and p_advance_amount > p_booking_amount then
    raise exception 'The advance cannot exceed the booking amount.'
      using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer_id from public.branches where id = p_branch_id;
  if v_dealer_id is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  -- The guard (spec §50): before two document numbers are drawn. The journal
  -- key this function already passed was 'booking:' || v_booking, minted from
  -- the row it had just created — unique every call, so it could never match.
  if p_idempotency_key is not null then
    select b.id, b.booking_number into v_booking, v_bnumber
      from public.bookings b
     where b.dealer_id = v_dealer_id
       and b.idempotency_key = p_idempotency_key;

    if v_booking is not null then
      select bp.receipt_number, bp.journal_entry_id into v_rnumber, v_entry
        from public.booking_payments bp
       where bp.booking_id = v_booking and bp.status = 'RECEIVED'
       order by bp.created_at limit 1;

      booking_id := v_booking; booking_number := v_bnumber;
      receipt_number := v_rnumber; journal_entry_id := v_entry;
      return next;
      return;
    end if;
  end if;

  v_year := app.financial_year_token(v_dealer_id, current_date);

  -- Resolve accounts before writing anything: an unconfigured mapping should
  -- fail before a booking number is consumed.
  v_cash_component := case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end;
  v_debit_acc  := app.require_account(v_dealer_id, 'BOOKING', 'ADVANCE', v_cash_component, p_branch_id);
  v_credit_acc := app.require_account(v_dealer_id, 'BOOKING', 'ADVANCE', 'CUSTOMER_ADVANCE', p_branch_id);

  v_bnumber := app.next_document_number(v_dealer_id, p_branch_id, 'BOOKING', v_year);
  v_rnumber := app.next_document_number(v_dealer_id, p_branch_id, 'RECEIPT', v_year);

  insert into public.bookings
    (dealer_id, branch_id, booking_number, customer_id, model_id, variant_id, vehicle_id,
     booking_amount, expected_delivery, sales_executive_id, notes, idempotency_key, created_by)
  values
    (v_dealer_id, p_branch_id, v_bnumber, p_customer_id, p_model_id, p_variant_id, p_vehicle_id,
     p_booking_amount, p_expected_delivery, p_sales_executive_id, p_notes,
     p_idempotency_key, auth.uid())
  returning id into v_booking;

  -- Spec §18: the advance is a liability until the sale is raised.
  v_entry := app.post_journal(
    v_dealer_id, p_branch_id, current_date, 'BOOKING',
    'Booking advance ' || v_bnumber,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit_acc, 'debit', p_advance_amount, 'credit', 0,
                         'narration', p_payment_mode || ' received'),
      jsonb_build_object('account_id', v_credit_acc, 'debit', 0, 'credit', p_advance_amount,
                         'narration', 'Customer advance',
                         'party_type', 'CUSTOMER', 'party_id', p_customer_id)
    ),
    'BOOKING', v_booking, 'booking:' || v_booking::text
  );

  insert into public.booking_payments
    (dealer_id, booking_id, receipt_number, amount, payment_mode, reference,
     journal_entry_id, created_by)
  values
    (v_dealer_id, v_booking, v_rnumber, p_advance_amount, p_payment_mode, p_reference,
     v_entry, auth.uid());

  -- Reserving a specific chassis takes it out of available stock (spec §13).
  if p_vehicle_id is not null then
    update public.vehicles set status = 'BOOKED', updated_by = auth.uid()
     where id = p_vehicle_id and status = 'IN_STOCK';
  end if;

  -- 0049: and into the cash or bank book, which is where the cashier looks.
  perform app.record_money_movement(
    v_dealer_id, p_branch_id, current_date, p_payment_mode, 'RECEIPT',
    p_advance_amount, 'Booking advance ' || v_bnumber, coalesce(p_reference, v_rnumber),
    v_entry, p_customer_id);

  booking_id := v_booking; booking_number := v_bnumber;
  receipt_number := v_rnumber; journal_entry_id := v_entry;
  return next;
end;
$$;
-- -----------------------------------------------------------------------------
-- public.refund_booking_advance() — spec §18, §23
-- -----------------------------------------------------------------------------
drop function if exists public.refund_booking_advance(uuid, numeric, text, text, uuid, uuid, date);

create function public.refund_booking_advance(
  p_booking_id      uuid,
  p_amount          numeric,
  p_mode            text,
  p_reason          text,
  p_cash_branch_id  uuid default null,
  p_bank_account_id uuid default null,
  p_date            date default current_date
)
returns table (journal_entry_id uuid)
language plpgsql
as $$
declare
  v_b        public.bookings;
  v_received numeric(18, 4);
  v_debit    uuid;
  v_credit   uuid;
  v_entry    uuid;
  v_bank     public.bank_accounts;
  v_cash     public.cash_accounts;
  v_branch   uuid;
begin
  if p_amount <= 0 then
    raise exception 'The refund must be greater than zero.' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'A refund must say why.'
      using errcode = 'check_violation',
            hint = 'Spec §23: the reason is part of the record, not optional.';
  end if;

  select * into v_b from public.bookings where id = p_booking_id for update;
  if v_b.id is null then
    raise exception 'Booking not found.' using errcode = 'no_data_found';
  end if;

  -- The guard (spec §50).
  --
  -- This one already had half a defence and it made things worse. The journal
  -- key below is deterministic — 'booking-refund:<booking>:<amount>' — so
  -- app.post_journal replays the first entry on a second call. The function then
  -- carried on and inserted a *second* cash or bank row against that same
  -- journal, so the refund appeared twice in the cash book and once in the
  -- ledger: over-reported in the day sheet, and invisible to the trial balance
  -- that would otherwise have caught it.
  --
  -- Returning here is what makes the replay complete rather than partial.
  --
  -- And it sits above the status and received-amount checks deliberately. The
  -- first call reverses the booking_payments rows, so a replay that reached
  -- those checks would be told "only 0.0000 was received" — refusing to repeat
  -- itself with an error that describes the state it created. A guard placed
  -- after the checks it is meant to skip is not a guard.
  select je.id into v_entry
    from public.journal_entries je
   where je.dealer_id = v_b.dealer_id
     and je.idempotency_key =
         'booking-refund:' || p_booking_id::text || ':' || p_amount::text;

  if v_entry is not null then
    journal_entry_id := v_entry;
    return next;
    return;
  end if;


  -- Only a cancelled booking. A refund against a live booking would leave the
  -- customer with a reservation they have not paid for.
  if v_b.status <> 'CANCELLED' then
    raise exception 'Booking % is % — cancel it before refunding the advance.',
      v_b.booking_number, v_b.status using errcode = 'check_violation';
  end if;

  select coalesce(sum(amount), 0) into v_received
    from public.booking_payments
   where booking_id = p_booking_id and status = 'RECEIVED';

  if p_amount > v_received then
    raise exception 'Only % was received against %.', v_received, v_b.booking_number
      using errcode = 'check_violation';
  end if;

  v_debit := app.require_account(v_b.dealer_id, 'BOOKING', 'APPLY', 'CUSTOMER_ADVANCE', v_b.branch_id);

  if p_mode = 'CASH' then
    v_branch := coalesce(p_cash_branch_id, v_b.branch_id);
    select * into v_cash from public.cash_accounts where branch_id = v_branch;
    if v_cash.id is null then
      raise exception 'That branch has no cash account.' using errcode = 'no_data_found';
    end if;
    v_credit := v_cash.ledger_account_id;
    -- The day guard applies: a closed day cannot take a payment (spec §36).
    perform public.ensure_cash_day(v_branch, p_date);
  else
    select * into v_bank from public.bank_accounts where id = p_bank_account_id;
    if v_bank.id is null then
      raise exception 'Choose the bank account the refund was paid from.'
        using errcode = 'no_data_found';
    end if;
    v_branch := coalesce(v_bank.branch_id, v_b.branch_id);
    v_credit := v_bank.ledger_account_id;
  end if;

  v_entry := app.post_journal(
    v_b.dealer_id, v_branch, p_date, 'BOOKING',
    'Advance refunded on ' || v_b.booking_number,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', btrim(p_reason),
                         'party_type', 'CUSTOMER', 'party_id', v_b.customer_id),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', 'Refund of booking advance')
    ),
    'BOOKING_REFUND', p_booking_id, 'booking-refund:' || p_booking_id::text || ':' || p_amount::text
  );

  if p_mode = 'CASH' then
    insert into public.cash_transactions
      (dealer_id, branch_id, cash_account_id, business_date, direction, amount,
       particular, customer_id, journal_entry_id, created_by)
    values
      (v_b.dealer_id, v_branch, v_cash.id, p_date, 'PAYMENT', p_amount,
       'Advance refund ' || v_b.booking_number, v_b.customer_id, v_entry, auth.uid());
  else
    insert into public.bank_transactions
      (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
       customer_id, journal_entry_id, created_by)
    values
      (v_b.dealer_id, p_bank_account_id, p_date, 'PAYMENT', p_amount,
       'Advance refund ' || v_b.booking_number, v_b.customer_id, v_entry, auth.uid());
  end if;

  -- Reversing the receipts is what makes bookings.received_amount fall: the
  -- trigger in 0020 recomputes it from the RECEIVED rows.
  update public.booking_payments
     set status = 'REVERSED'
   where booking_id = p_booking_id and status = 'RECEIVED';

  journal_entry_id := v_entry;
  return next;
end;
$$;
-- -----------------------------------------------------------------------------
-- public.record_trade_advance() — spec §26
-- -----------------------------------------------------------------------------
drop function if exists public.record_trade_advance(uuid, uuid, text, numeric, uuid, date, text, text);

create function public.record_trade_advance(
  p_finance_company_id uuid,
  p_branch_id          uuid,
  p_type               text,
  p_amount             numeric,
  p_bank_account_id    uuid default null,
  p_date               date default current_date,
  p_narration          text default null,
  p_reference          text default null,
  p_idempotency_key    text default null
)
returns table (transaction_id bigint, journal_entry_id uuid)
language plpgsql
as $$
declare
  v_dealer  uuid;
  v_company public.finance_companies;
  v_bank    public.bank_accounts;
  v_bank_acc uuid;
  v_debit   uuid;
  v_credit  uuid;
  v_entry   uuid;
  v_txn     bigint;
  v_debit_amt  numeric(18, 4) := 0;
  v_credit_amt numeric(18, 4) := 0;
  v_narration text;
begin
  -- ft_one_sided_check forbids a zero row, so this is not merely tidiness.
  if p_amount <= 0 then
    raise exception 'The amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_type not in ('ADVANCE_RECEIVED', 'VEHICLE_ADJUSTMENT', 'SETTLEMENT',
                    'REFUND', 'COMMISSION', 'MANUAL_ADJUSTMENT') then
    raise exception 'Unknown trade advance type %.', p_type using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  -- The guard (spec §50). A finance company's ledger is reconciled against the
  -- financier's own statement; a duplicated advance is an argument with someone
  -- who has the money.
  if p_idempotency_key is not null then
    select ft.id, ft.journal_entry_id into v_txn, v_entry
      from public.finance_transactions ft
     where ft.dealer_id = v_dealer
       and ft.idempotency_key = p_idempotency_key;

    if v_txn is not null then
      transaction_id := v_txn; journal_entry_id := v_entry;
      return next;
      return;
    end if;
  end if;

  select * into v_company from public.finance_companies where id = p_finance_company_id;
  if v_company.id is null then
    raise exception 'Finance company not found.' using errcode = 'no_data_found';
  end if;

  if p_bank_account_id is not null then
    select * into v_bank from public.bank_accounts where id = p_bank_account_id;
  end if;

  v_narration := coalesce(p_narration, replace(initcap(replace(p_type, '_', ' ')), ' ', ' ')
                          || ' — ' || v_company.name);

  -- Money in or out needs a bank account; the internal moves do not.
  if p_type in ('ADVANCE_RECEIVED', 'SETTLEMENT', 'REFUND') and v_bank.id is null then
    raise exception 'A % needs the bank account the money moved through.', lower(replace(p_type, '_', ' '))
      using errcode = 'check_violation';
  end if;

  v_bank_acc := v_bank.ledger_account_id;

  if p_type = 'ADVANCE_RECEIVED' then
    -- The company funds the dealer ahead of sales: cash in, liability up.
    v_debit  := coalesce(v_bank_acc, app.require_account(v_dealer, 'TRADE_ADVANCE', 'RECEIVED', 'BANK', p_branch_id));
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'RECEIVED', 'FINANCE_PAYABLE', p_branch_id);
    v_debit_amt := p_amount;          -- the dealer holds their money, so the position falls
  elsif p_type = 'VEHICLE_ADJUSTMENT' then
    -- An advance is consumed by a vehicle the company financed.
    v_debit  := app.require_account(v_dealer, 'TRADE_ADVANCE', 'ADJUSTMENT', 'FINANCE_PAYABLE', p_branch_id);
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'ADJUSTMENT', 'FINANCE_RECEIVABLE', p_branch_id);
    v_credit_amt := p_amount;
  elsif p_type = 'SETTLEMENT' then
    v_debit  := coalesce(v_bank_acc, app.require_account(v_dealer, 'TRADE_ADVANCE', 'SETTLEMENT', 'BANK', p_branch_id));
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'SETTLEMENT', 'FINANCE_RECEIVABLE', p_branch_id);
    v_debit_amt := p_amount;
  elsif p_type = 'REFUND' then
    v_debit  := app.require_account(v_dealer, 'TRADE_ADVANCE', 'REFUND', 'FINANCE_PAYABLE', p_branch_id);
    v_credit := coalesce(v_bank_acc, app.require_account(v_dealer, 'TRADE_ADVANCE', 'REFUND', 'BANK', p_branch_id));
    v_credit_amt := p_amount;
  elsif p_type = 'COMMISSION' then
    v_debit  := app.require_account(v_dealer, 'TRADE_ADVANCE', 'COMMISSION', 'FINANCE_RECEIVABLE', p_branch_id);
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'COMMISSION', 'COMMISSION_INCOME', p_branch_id);
    v_credit_amt := p_amount;         -- earned but unpaid: the company owes more
  else -- MANUAL_ADJUSTMENT
    v_debit  := app.require_account(v_dealer, 'TRADE_ADVANCE', 'MANUAL_ADJUSTMENT', 'FINANCE_RECEIVABLE', p_branch_id);
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'MANUAL_ADJUSTMENT', 'FINANCE_PAYABLE', p_branch_id);
    v_credit_amt := p_amount;
  end if;

  v_entry := app.post_journal(
    v_dealer, p_branch_id, p_date, 'TRADE_ADVANCE', v_narration,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', v_narration,
                         'party_type', 'FINANCE_COMPANY', 'party_id', p_finance_company_id),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', v_narration,
                         'party_type', 'FINANCE_COMPANY', 'party_id', p_finance_company_id)
    ),
    'TRADE_ADVANCE', null, null
  );

  insert into public.finance_transactions
    (dealer_id, branch_id, finance_company_id, transaction_date, transaction_type,
     debit, credit, reference_type, reference_number, narration, journal_entry_id,
     idempotency_key, created_by)
  values
    (v_dealer, p_branch_id, p_finance_company_id, p_date, p_type,
     v_debit_amt, v_credit_amt, 'TRADE_ADVANCE', p_reference, v_narration, v_entry,
     p_idempotency_key, auth.uid())
  returning id into v_txn;

  -- Money that moved through a bank account belongs in the bank book too.
  if v_bank.id is not null and p_type in ('ADVANCE_RECEIVED', 'SETTLEMENT', 'REFUND') then
    insert into public.bank_transactions
      (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
       reference_number, journal_entry_id, created_by)
    values
      (v_dealer, p_bank_account_id, p_date,
       case when p_type = 'REFUND' then 'PAYMENT' else 'RECEIPT' end,
       p_amount, v_narration, p_reference, v_entry, auth.uid());
  end if;

  transaction_id := v_txn; journal_entry_id := v_entry;
  return next;
end;
$$;
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  -- Per-signature, and every one of them went with its drop.
  execute 'grant execute on function public.record_service_payment(uuid, numeric, text, text, date, text) to authenticated';
  execute 'grant execute on function public.create_counter_invoice(uuid, uuid, date, text) to authenticated';
  execute 'grant execute on function public.create_booking_with_advance(uuid, uuid, uuid, numeric, numeric, text, uuid, uuid, date, uuid, text, text, text) to authenticated';
  execute 'grant execute on function public.refund_booking_advance(uuid, numeric, text, text, uuid, uuid, date) to authenticated';
  execute 'grant execute on function public.record_trade_advance(uuid, uuid, text, numeric, uuid, date, text, text, text) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0063', 'idempotent_second_wave') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0064_dashboard_unit_counts.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0064 — The unit counts the dashboard has been apologising for
-- =============================================================================
-- Spec §10, §43, §59.
--
-- Seven of the dashboard's KPI tiles have been rendering dimmed, with a badge
-- naming the phase that would deliver them:
--
--   Vehicle Sales · Bookings · Deliveries · Vehicle Stock (Qty)
--   Accessories Stock (Qty) · Spare Stock (Qty) · Finance Units
--
-- Every one of those phases has shipped. The tiles were honest when written —
-- dashboard-service.ts sets out the rule that a card must not invent a number —
-- and they have been wrong for months, telling a dealer that modules they use
-- daily have not arrived. That is the same failure as a fake number, pointed the
-- other way.
--
-- ── Why the ledger could not answer ─────────────────────────────────────────
--
-- The file's own comment explains it: a journal records value, not units. Every
-- `ready` tile comes from account_balances(), which cannot say how many vehicles
-- were sold, only what they were worth. So these seven need their own aggregate,
-- and this is it — one round trip for all of them rather than seven.
--
-- Stock counts are "as at now", not "within the period". A stock figure is a
-- position, and a position has no date range: asking how much stock existed
-- between two dates is not a question with an answer. The period filter applies
-- to the four flow counts and is deliberately ignored by the three stock ones.
--
-- Rollback: drop function public.dashboard_unit_counts(date, date, uuid);
-- =============================================================================

create or replace function public.dashboard_unit_counts(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  vehicle_sales_units bigint,
  bookings            bigint,
  deliveries          bigint,
  vehicle_stock_qty   bigint,
  accessory_stock_qty numeric,
  spare_stock_qty     numeric,
  finance_units       bigint
)
language sql
stable
as $$
  select
    -- Sold, by invoice date. POSTED and DELIVERED both count: the sale is made
    -- when it is posted, and delivery is a later event with its own tile.
    (select count(*) from public.sales s
      where s.status in ('POSTED', 'DELIVERED')
        and s.invoice_date between p_from and p_to
        and (p_branch_id is null or s.branch_id = p_branch_id)),

    -- Taken, by booking date. Cancelled bookings are excluded: a dealer asking
    -- "how many bookings this month" means live ones.
    (select count(*) from public.bookings b
      where b.status <> 'CANCELLED'
        and b.booking_date between p_from and p_to
        and (p_branch_id is null or b.branch_id = p_branch_id)),

    -- Handed over, by the date of delivery rather than of the invoice — a
    -- vehicle invoiced in March and delivered in April is an April delivery.
    (select count(*) from public.sales s
      where s.status = 'DELIVERED'
        and s.delivered_at::date between p_from and p_to
        and (p_branch_id is null or s.branch_id = p_branch_id)),

    -- A position, not a flow: what is on the floor now (spec §13).
    (select count(*) from public.vehicles v
      where v.status = 'IN_STOCK'
        and (p_branch_id is null or v.branch_id = p_branch_id)),

    -- Local and company lots summed for the headline; the split stays visible
    -- on the inventory screens, which is where spec §28 requires it.
    (select coalesce(sum(st.quantity), 0) from public.inventory_stock st
      join public.inventory_items i on i.id = st.item_id
     where i.item_type = 'ACCESSORY'
       and (p_branch_id is null or st.branch_id = p_branch_id)),

    (select coalesce(sum(st.quantity), 0) from public.inventory_stock st
      join public.inventory_items i on i.id = st.item_id
     where i.item_type = 'SPARE'
       and (p_branch_id is null or st.branch_id = p_branch_id)),

    -- Financed units for the period: applications raised, excluding those the
    -- financier or the dealer withdrew.
    (select count(*) from public.finance_applications f
      where f.approval_status <> 'CANCELLED'
        and f.application_date between p_from and p_to
        and (p_branch_id is null or f.branch_id = p_branch_id));
$$;

comment on function public.dashboard_unit_counts(date, date, uuid) is
  'The seven unit counts spec §10 requires on the dashboard, which the ledger '
  'cannot answer because a journal records value and not units. Flow counts obey '
  'the period; the three stock counts are positions as at now and ignore it.';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  execute 'grant execute on function public.dashboard_unit_counts(date, date, uuid) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0064', 'dashboard_unit_counts') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0065_customer_360.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0065 — Customer 360, as a query rather than a promise
-- =============================================================================
-- Spec §11, §41, §59.
--
-- The customer page has been rendering six dashed boxes badged "P4", "P5" and
-- "P6" under the subtitle "Fills in as each module is built", driven by a
-- hardcoded array of six literals in the page file. It was the only place in the
-- product where invented data reached the screen, and every one of those phases
-- shipped months ago.
--
-- Spec §11 makes Customer 360 mandatory, and the data has existed the whole
-- time — scattered across /customers/ledger, /customers/vehicles,
-- /customers/service and the sales, booking and finance lists filtered by
-- customer. What was missing was one query that answers "what is this customer
-- to us" in a single round trip.
--
-- ── On the outstanding figure ───────────────────────────────────────────────
--
-- Taken from the journal lines carrying this customer as the party, not from
-- summing invoices and subtracting receipts. Those two can disagree — a credit
-- note, an opening balance, a manual journal — and when they do the ledger is
-- right. A customer page that quotes a different balance from the customer
-- ledger screen is worse than one that quotes none.
--
-- Rollback: drop function public.customer_360(uuid);
-- =============================================================================

create or replace function public.customer_360(p_customer_id uuid)
returns table (
  booking_count      bigint,
  booking_advance    numeric(18, 4),
  sale_count         bigint,
  sale_value         numeric(18, 4),
  paid_amount        numeric(18, 4),
  outstanding        numeric(18, 4),
  finance_count      bigint,
  finance_amount     numeric(18, 4),
  service_count      bigint,
  service_value      numeric(18, 4),
  vehicle_count      bigint,
  last_activity      date
)
language sql
stable
as $$
  with c as (
    select id, dealer_id from public.customers where id = p_customer_id
  )
  select
    (select count(*) from public.bookings b
      where b.customer_id = p_customer_id and b.status <> 'CANCELLED'),
    (select coalesce(sum(b.received_amount), 0) from public.bookings b
      where b.customer_id = p_customer_id and b.status <> 'CANCELLED'),

    (select count(*) from public.sales s
      where s.customer_id = p_customer_id and s.status not in ('CANCELLED', 'RETURNED')),
    (select coalesce(sum(s.total_amount), 0) from public.sales s
      where s.customer_id = p_customer_id and s.status not in ('CANCELLED', 'RETURNED')),

    (select coalesce(sum(p.amount), 0) from public.sale_payments p
      join public.sales s on s.id = p.sale_id
     where s.customer_id = p_customer_id),

    -- The ledger's answer, not arithmetic over documents. See the header.
    (select public.party_ledger_opening('CUSTOMER', p_customer_id, 'infinity'::date)),

    (select count(*) from public.finance_applications f
      where f.customer_id = p_customer_id and f.approval_status <> 'CANCELLED'),
    (select coalesce(sum(coalesce(f.approved_amount, f.loan_amount)), 0)
       from public.finance_applications f
      where f.customer_id = p_customer_id and f.approval_status <> 'CANCELLED'),

    (select count(*) from public.service_invoices si
      where si.customer_id = p_customer_id and si.status = 'POSTED'),
    (select coalesce(sum(si.total_amount), 0) from public.service_invoices si
      where si.customer_id = p_customer_id and si.status = 'POSTED'),

    (select count(*) from public.customer_vehicles cv where cv.customer_id = p_customer_id),

    -- The most recent thing that happened, whichever kind it was: the one date
    -- that answers "are they still a customer".
    (select max(d) from (
        select max(s.invoice_date)  as d from public.sales s where s.customer_id = p_customer_id
        union all
        select max(b.booking_date)      from public.bookings b where b.customer_id = p_customer_id
        union all
        select max(si.invoice_date)     from public.service_invoices si where si.customer_id = p_customer_id
     ) latest)
  from c;
$$;

comment on function public.customer_360(uuid) is
  'One round trip behind the Customer 360 panel (spec §11): bookings, sales, '
  'payments, outstanding, finance, service and vehicles. Outstanding comes from '
  'the party ledger rather than from summing documents, so it cannot disagree '
  'with the customer ledger screen.';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  execute 'grant execute on function public.customer_360(uuid) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0065', 'customer_360') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0066_opening_balances.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0066 — Opening balances: what the dealer was owed before they had this
-- =============================================================================
-- Spec §24, §41, §44, §59.
--
-- A dealer switching systems does not start at zero. They arrive owed money by
-- customers and owing it to suppliers, and until those balances are on the books
-- the customer ledger, the supplier ledger, the trial balance and every ageing
-- report describe a business that began the day they signed up.
--
-- `customer_ledger_opening` (0037) *computes* an opening from journals. There
-- has never been a way to *enter* one, so the only path was typing a journal
-- line per party by hand — which for a few hundred parties is a week's work and
-- a guaranteed transposition error.
--
-- ── One journal, not one per party ──────────────────────────────────────────
--
-- Every party is a line in a single entry balanced against 3300 Opening Balance
-- Equity. That is the standard treatment and it has a practical virtue: the
-- whole cut-over is one reversible document. If the figures turn out wrong — and
-- on a first attempt they usually do — the fix is one reversal, not several
-- hundred, and the trial balance is never half-migrated in between.
--
-- ── Why a suspense account and not Retained Earnings ────────────────────────
--
-- 3300 exists so the migration is visible as its own number. Posting straight to
-- retained earnings would mix "what we were owed on day one" into the same line
-- as trading profit, and nobody could later tell which was which. The dealer's
-- accountant clears 3300 into 3200 once they are satisfied the balances match
-- the old system — and a non-zero 3300 is itself a useful signal that the
-- reconciliation has not been finished.
--
-- Rollback: drop function public.post_opening_balances(...); the 3300 account
-- can stay, being harmless when unused.
-- =============================================================================

-- ── The account, for dealers who already exist ──────────────────────────────
-- New dealers get it from app.seed_chart_of_accounts below; this is the backfill
-- for the ones provisioned before today.
insert into public.chart_of_accounts
  (dealer_id, code, name, account_type, normal_balance, is_group, parent_id,
   is_system, is_branch_scoped)
select d.id, '3300', 'Opening Balance Equity', 'EQUITY', 'CREDIT', false,
       (select c.id from public.chart_of_accounts c
         where c.dealer_id = d.id and c.code = '3000'),
       true, false
  from public.dealers d
on conflict on constraint coa_dealer_code_key do nothing;

-- ── And for every dealer provisioned from now on ────────────────────────────
-- The original is renamed rather than copied. Reproducing its sixty-account
-- table here would leave two lists to keep in step — the exact failure this
-- migration exists to prevent elsewhere. app.provision_dealer still calls
-- app.seed_chart_of_accounts by name, so it picks up the wrapper unchanged.
alter function app.seed_chart_of_accounts(uuid) rename to seed_chart_of_accounts_base;

create or replace function app.seed_chart_of_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
declare
  v_added integer := 0;
begin
  v_added := app.seed_chart_of_accounts_base(p_dealer_id);

  insert into public.chart_of_accounts
    (dealer_id, code, name, account_type, normal_balance, is_group, parent_id,
     is_system, is_branch_scoped)
  values
    (p_dealer_id, '3300', 'Opening Balance Equity', 'EQUITY', 'CREDIT', false,
     (select c.id from public.chart_of_accounts c
       where c.dealer_id = p_dealer_id and c.code = '3000'),
     true, false)
  on conflict on constraint coa_dealer_code_key do nothing;

  if found then v_added := v_added + 1; end if;
  return v_added;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.post_opening_balances() — one balanced entry for a whole party ledger
-- -----------------------------------------------------------------------------
-- p_rows is [{ "party_code": "CUST-000001", "amount": 12500.00 }, …].
--
-- A positive amount means the party owes the dealer; negative means the dealer
-- owes the party. One sign convention for both directions, because a file with
-- a separate debit and credit column invites rows carrying both.
-- -----------------------------------------------------------------------------
create or replace function public.post_opening_balances(
  p_party_type      text,
  p_rows            jsonb,
  p_as_on           date default current_date,
  p_narration       text default null,
  p_idempotency_key text default null
)
returns table (journal_entry_id uuid, parties integer, total numeric)
language plpgsql
as $$
declare
  v_dealer   uuid;
  v_branch   uuid;
  v_control  uuid;
  v_equity   uuid;
  v_row      jsonb;
  v_party    uuid;
  v_code     text;
  v_amount   numeric(18, 4);
  v_lines    jsonb := '[]'::jsonb;
  v_net      numeric(18, 4) := 0;
  v_count    integer := 0;
  v_entry    uuid;
begin
  if p_party_type not in ('CUSTOMER', 'SUPPLIER') then
    raise exception 'Opening balances are for CUSTOMER or SUPPLIER, not %.', p_party_type
      using errcode = 'check_violation';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'No opening balances to post.' using errcode = 'check_violation';
  end if;

  select id into v_dealer from public.dealers limit 1;      -- RLS scopes this to one
  if v_dealer is null then
    raise exception 'No dealer in scope.' using errcode = 'no_data_found';
  end if;

  select id into v_branch from public.branches
   where dealer_id = v_dealer order by code limit 1;

  -- The guard (spec §50). A cut-over run twice would double every balance, and
  -- of all the things to post twice this is the worst: nobody notices until a
  -- customer disputes a statement.
  if p_idempotency_key is not null then
    select je.id into v_entry from public.journal_entries je
     where je.dealer_id = v_dealer and je.idempotency_key = 'opening:' || p_idempotency_key;
    if v_entry is not null then
      select count(*), coalesce(sum(abs(l.debit - l.credit)), 0)
        into v_count, v_net
        from public.journal_entry_lines l
       where l.journal_entry_id = v_entry and l.party_id is not null;
      journal_entry_id := v_entry; parties := v_count; total := v_net;
      return next;
      return;
    end if;
  end if;

  -- The two control accounts a party ledger reconciles against. The triples are
  -- the ones the posting engine already uses, so an opening balance lands in the
  -- same account a later invoice will (0027:34, 0027:96).
  v_control := case
    when p_party_type = 'CUSTOMER'
      then app.require_account(v_dealer, 'SALES', 'INVOICE', 'RECEIVABLE', v_branch)
    else app.require_account(v_dealer, 'INVENTORY', 'PURCHASE', 'PAYABLE', v_branch)
  end;

  select id into v_equity from public.chart_of_accounts
   where dealer_id = v_dealer and code = '3300';
  if v_equity is null then
    raise exception 'The Opening Balance Equity account (3300) is missing.'
      using errcode = 'no_data_found';
  end if;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_code   := btrim(v_row ->> 'party_code');
    v_amount := round((v_row ->> 'amount')::numeric, 4);

    if v_amount = 0 then
      continue;  -- nothing owed either way is not a line, it is an absence
    end if;

    if p_party_type = 'CUSTOMER' then
      select id into v_party from public.customers
       where dealer_id = v_dealer and customer_code = v_code;
    else
      select id into v_party from public.suppliers
       where dealer_id = v_dealer and supplier_code = v_code;
    end if;

    if v_party is null then
      raise exception 'No % with code %.', lower(p_party_type), v_code
        using errcode = 'no_data_found';
    end if;

    -- The sign decides the direction, and it does so the same way for both party
    -- types. "The party owes the dealer" is a debit to the control account
    -- whichever account that is; "the dealer owes the party" is a credit. The
    -- control account differs — 1300 for a customer, 2200 for a supplier — but
    -- the direction does not, and making it depend on the party type as well was
    -- a bug that inverted every supplier balance.
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', v_control,
      'debit',  case when v_amount > 0 then v_amount else 0 end,
      'credit', case when v_amount < 0 then abs(v_amount) else 0 end,
      'narration', 'Opening balance ' || v_code,
      'party_type', p_party_type,
      'party_id', v_party
    ));

    v_net := v_net + v_amount;   -- net debit across the party lines
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception 'Every row was zero — there is nothing to post.'
      using errcode = 'check_violation';
  end if;

  -- The balancing line. v_net is the net debit across the party lines, so the
  -- equity side is its mirror and the entry sums to zero by construction rather
  -- than by hoping the file added up.
  v_lines := v_lines || jsonb_build_array(jsonb_build_object(
    'account_id', v_equity,
    'debit',  case when v_net < 0 then abs(v_net) else 0 end,
    'credit', case when v_net > 0 then v_net else 0 end,
    'narration', 'Opening balances brought forward'
  ));

  v_entry := app.post_journal(
    v_dealer, v_branch, p_as_on, 'OPENING',
    coalesce(p_narration,
             'Opening ' || lower(p_party_type) || ' balances as at ' || p_as_on::text),
    v_lines,
    'OPENING_BALANCE', null,
    case when p_idempotency_key is null then null else 'opening:' || p_idempotency_key end
  );

  journal_entry_id := v_entry; parties := v_count; total := abs(v_net);
  return next;
end;
$$;

comment on function public.post_opening_balances(text, jsonb, date, text, text) is
  'Posts a whole party ledger as one balanced journal against 3300 Opening '
  'Balance Equity (spec §24). One document, so a wrong cut-over is one reversal '
  'rather than several hundred.';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  execute 'grant execute on function public.post_opening_balances(text, jsonb, date, text, text) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0066', 'opening_balances') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0067_opening_balances_tenant.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0067 — Opening balances must name their tenant, not guess it
-- =============================================================================
-- Spec §4, §24, §47.
--
-- 0066 resolved the dealer with
--
--     select id into v_dealer from public.dealers limit 1;   -- RLS scopes this
--
-- which is true for an ordinary session and false for the one that matters. RLS
-- narrows `dealers` to one row for a dealer user, so `limit 1` happens to be
-- right — but a platform administrator bypasses RLS entirely and sees every
-- tenant, so the same statement picks an arbitrary one. A platform admin running
-- a cut-over would post one dealer's opening balances into another dealer's
-- ledger, and nothing in the entry would look wrong afterwards.
--
-- A rehearsal found it: the dry run signs in as a platform admin to provision the
-- tenant — which is the only way to provision one — and then the balances went
-- looking for a customer in the wrong dealer.
--
-- The fix is to stop inferring. app.current_dealer_id() is the tenant of the
-- authenticated user and returns NULL for a platform admin precisely so that
-- "deny by default" holds (0004). So the session's own dealer is used when there
-- is one, and a platform admin must say which tenant they mean.
--
-- Rollback: restore public.post_opening_balances from 0066.
-- =============================================================================

drop function if exists public.post_opening_balances(text, jsonb, date, text, text);

create function public.post_opening_balances(
  p_party_type      text,
  p_rows            jsonb,
  p_as_on           date default current_date,
  p_narration       text default null,
  p_idempotency_key text default null,
  -- Only a platform admin may set this, and only a platform admin needs to:
  -- every other session has exactly one tenant and it is not theirs to choose.
  p_dealer_id       uuid default null
)
returns table (journal_entry_id uuid, parties integer, total numeric)
language plpgsql
as $$
declare
  v_dealer   uuid;
  v_branch   uuid;
  v_control  uuid;
  v_equity   uuid;
  v_row      jsonb;
  v_party    uuid;
  v_code     text;
  v_amount   numeric(18, 4);
  v_lines    jsonb := '[]'::jsonb;
  v_net      numeric(18, 4) := 0;
  v_count    integer := 0;
  v_entry    uuid;
begin
  if p_party_type not in ('CUSTOMER', 'SUPPLIER') then
    raise exception 'Opening balances are for CUSTOMER or SUPPLIER, not %.', p_party_type
      using errcode = 'check_violation';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'No opening balances to post.' using errcode = 'check_violation';
  end if;

  -- ── Whose books are these? ──────────────────────────────────────────────
  v_dealer := app.current_dealer_id();

  if v_dealer is null then
    -- A platform admin, or nobody. Either way the tenant has to be stated.
    if p_dealer_id is null then
      raise exception 'Name the dealer these balances belong to.'
        using errcode = 'check_violation',
              hint = 'A platform administrator has no tenant of their own, so '
                     'p_dealer_id is required.';
    end if;
    if not app.is_platform_admin() then
      raise exception 'You may not post opening balances for another dealer.'
        using errcode = 'insufficient_privilege';
    end if;
    v_dealer := p_dealer_id;
  elsif p_dealer_id is not null and p_dealer_id <> v_dealer then
    -- A dealer session naming someone else's tenant is either a mistake or an
    -- attempt; both deserve the same answer.
    raise exception 'You may not post opening balances for another dealer.'
      using errcode = 'insufficient_privilege';
  end if;

  if not exists (select 1 from public.dealers d where d.id = v_dealer) then
    raise exception 'Dealer not found.' using errcode = 'no_data_found';
  end if;

  select id into v_branch from public.branches
   where dealer_id = v_dealer order by code limit 1;

  -- ── The JOURNAL sequence for the year being posted into ─────────────────
  --
  -- provision_dealer seeds financial-document sequences for the *current*
  -- financial year only, and that is the right default: 0056 says plainly that
  -- an identifier may self-provision but a financial document should fail rather
  -- than invent a series nobody configured.
  --
  -- An opening balance is the one financial document that is always back-dated —
  -- it is dated the day before trading starts, which for an April cut-over is the
  -- previous financial year. So the very first thing a newly provisioned tenant
  -- does would fail with "No document sequence configured", and there is no
  -- screen on which to create one.
  --
  -- Hence this narrow exception, for this document type and only for the year
  -- this entry lands in. A rehearsal found it; a real cut-over would have found
  -- it too, in front of the dealer.
  insert into public.document_sequences
    (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
  values
    (v_dealer, null, 'JOURNAL', app.financial_year_token(v_dealer, p_as_on), 'JE', 6)
  on conflict on constraint document_sequences_scope_key do nothing;

  -- The guard (spec §50). A cut-over run twice would double every balance, and
  -- of all the things to post twice this is the worst: nobody notices until a
  -- customer disputes a statement.
  if p_idempotency_key is not null then
    select je.id into v_entry from public.journal_entries je
     where je.dealer_id = v_dealer and je.idempotency_key = 'opening:' || p_idempotency_key;
    if v_entry is not null then
      select count(*), coalesce(sum(abs(l.debit - l.credit)), 0)
        into v_count, v_net
        from public.journal_entry_lines l
       where l.journal_entry_id = v_entry and l.party_id is not null;
      journal_entry_id := v_entry; parties := v_count; total := v_net;
      return next;
      return;
    end if;
  end if;

  -- The two control accounts a party ledger reconciles against. The triples are
  -- the ones the posting engine already uses, so an opening balance lands in the
  -- same account a later invoice will (0027:34, 0027:96).
  v_control := case
    when p_party_type = 'CUSTOMER'
      then app.require_account(v_dealer, 'SALES', 'INVOICE', 'RECEIVABLE', v_branch)
    else app.require_account(v_dealer, 'INVENTORY', 'PURCHASE', 'PAYABLE', v_branch)
  end;

  select id into v_equity from public.chart_of_accounts
   where dealer_id = v_dealer and code = '3300';
  if v_equity is null then
    raise exception 'The Opening Balance Equity account (3300) is missing.'
      using errcode = 'no_data_found';
  end if;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_code   := btrim(v_row ->> 'party_code');
    v_amount := round((v_row ->> 'amount')::numeric, 4);

    if v_amount = 0 then
      continue;  -- nothing owed either way is not a line, it is an absence
    end if;

    if p_party_type = 'CUSTOMER' then
      select id into v_party from public.customers
       where dealer_id = v_dealer and customer_code = v_code;
    else
      select id into v_party from public.suppliers
       where dealer_id = v_dealer and supplier_code = v_code;
    end if;

    if v_party is null then
      raise exception 'No % with code %.', lower(p_party_type), v_code
        using errcode = 'no_data_found';
    end if;

    -- The sign decides the direction, and it does so the same way for both party
    -- types. "The party owes the dealer" is a debit to the control account
    -- whichever account that is; "the dealer owes the party" is a credit.
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', v_control,
      'debit',  case when v_amount > 0 then v_amount else 0 end,
      'credit', case when v_amount < 0 then abs(v_amount) else 0 end,
      'narration', 'Opening balance ' || v_code,
      'party_type', p_party_type,
      'party_id', v_party
    ));

    v_net := v_net + v_amount;   -- net debit across the party lines
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception 'Every row was zero — there is nothing to post.'
      using errcode = 'check_violation';
  end if;

  -- The balancing line. v_net is the net debit across the party lines, so the
  -- equity side is its mirror and the entry sums to zero by construction rather
  -- than by hoping the file added up.
  v_lines := v_lines || jsonb_build_array(jsonb_build_object(
    'account_id', v_equity,
    'debit',  case when v_net < 0 then abs(v_net) else 0 end,
    'credit', case when v_net > 0 then v_net else 0 end,
    'narration', 'Opening balances brought forward'
  ));

  v_entry := app.post_journal(
    v_dealer, v_branch, p_as_on, 'OPENING',
    coalesce(p_narration,
             'Opening ' || lower(p_party_type) || ' balances as at ' || p_as_on::text),
    v_lines,
    'OPENING_BALANCE', null,
    case when p_idempotency_key is null then null else 'opening:' || p_idempotency_key end
  );

  journal_entry_id := v_entry; parties := v_count; total := abs(v_net);
  return next;
end;
$$;

comment on function public.post_opening_balances(text, jsonb, date, text, text, uuid) is
  'Posts a whole party ledger as one balanced journal against 3300 Opening '
  'Balance Equity (spec §24). The tenant comes from the session, never from '
  '"whichever dealer is first" — a platform admin bypasses RLS and must name it.';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  execute 'grant execute on function public.post_opening_balances(text, jsonb, date, text, text, uuid) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0067', 'opening_balances_tenant') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0068_eway_bill.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0068 — E-way bills: the document that has to travel with the vehicle
-- =============================================================================
-- Spec §40, §41, §55.
--
-- What existed. 0024 created public.eway_bills, 0034 added queue_eway_bill(),
-- and the GST screen listed the rows. Nothing has ever called the queue
-- function: `queueEwayBillAction` had no callers anywhere in the product, so a
-- row could only ever be created by typing SQL. The screen's own empty state
-- said bills "are queued from a sale or a stock transfer", describing a path
-- that did not exist.
--
-- Why it matters more than a missing screen. An e-way bill is not paperwork the
-- dealer chooses to raise. Goods above the notified value may not move without
-- one, and a vehicle stopped without it is detained along with its consignment
-- (s.68 CGST Act, Rule 138). E-invoicing was built end to end in 0048; this is
-- the half of the same obligation that was left as a table.
--
-- ── What this adds ──────────────────────────────────────────────────────────
--
--   eway_bill_payload()     the EWB-1 document, built from what was sold
--   record_eway_request()   stores it before transmission, counts the attempt
--   record_eway_result()    records how the attempt ended
--   eway_bill_required()    whether the threshold is met, per configuration
--   eway_expected_validity() one day per 200km, which is the rule in Rule 138
--
-- The shape deliberately mirrors 0048. One integration pattern for both halves
-- of GST filing is easier to reason about than two, and the provider adapter on
-- the TypeScript side is shared.
--
-- ── The threshold is configuration, not a constant ──────────────────────────
--
-- ₹50,000 is the common figure and it is not universal: states set their own
-- limit for movement within the state, and several use ₹1,00,000. Hard-coding
-- 50000 would be wrong for those dealers in the direction that matters — it
-- would demand a bill that is not required, and the dealer would stop trusting
-- the warning. Two settings, defaulting to the common case.
--
-- Rollback: drop the four functions; delete the two settings. The table and
-- queue_eway_bill() predate this migration.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Thresholds
-- -----------------------------------------------------------------------------
-- Platform defaults, with dealer_id null. A dealer-scoped row of the same key
-- overrides them, which is how system_settings is meant to work and is the only
-- shape that survives provisioning: a per-dealer insert here would cover the
-- dealers that existed when this migration ran and no one onboarded afterwards.
-- Migrations run before any dealer exists at all, so that insert would have
-- created nothing whatsoever.
insert into public.system_settings (dealer_id, key, value, value_type, description, is_public)
values
  (null, 'eway.threshold_interstate', '50000'::jsonb, 'number',
   'Consignment value above which an e-way bill is required for movement to another state (Rule 138).', true),
  (null, 'eway.threshold_intrastate', '50000'::jsonb, 'number',
   'The same, for movement within the state. States differ — several use 1,00,000. Add a dealer-scoped row to override.', true)
on conflict on constraint system_settings_scope_key do nothing;

-- -----------------------------------------------------------------------------
-- public.eway_bill_required() — is one needed for this document?
-- -----------------------------------------------------------------------------
-- Returns the answer and the reasoning, because "no" is a claim the dealer is
-- relying on and they should be able to see why.
-- -----------------------------------------------------------------------------
create or replace function public.eway_bill_required(
  p_document_type text,
  p_document_id   uuid
)
returns table (required boolean, consignment_value numeric, threshold numeric, interstate boolean)
language plpgsql
stable
as $$
declare
  v_dealer   uuid;
  v_value    numeric(18, 4);
  v_from     text;
  v_to       text;
  v_key      text;
begin
  if p_document_type = 'SALE' then
    select s.dealer_id, s.total_amount,
           coalesce(b.state_code, d.state_code), coalesce(c.state_code, coalesce(b.state_code, d.state_code))
      into v_dealer, v_value, v_from, v_to
      from public.sales s
      join public.branches b on b.id = s.branch_id
      join public.dealers  d on d.id = s.dealer_id
      join public.customers c on c.id = s.customer_id
     where s.id = p_document_id;

  elsif p_document_type = 'SERVICE_INVOICE' then
    select si.dealer_id, si.total_amount,
           coalesce(b.state_code, d.state_code), coalesce(c.state_code, coalesce(b.state_code, d.state_code))
      into v_dealer, v_value, v_from, v_to
      from public.service_invoices si
      join public.branches b on b.id = si.branch_id
      join public.dealers  d on d.id = si.dealer_id
      left join public.customers c on c.id = si.customer_id
     where si.id = p_document_id;

  elsif p_document_type = 'TRANSFER' then
    -- A branch transfer moves stock the dealer still owns. It needs a bill on
    -- the same value test: the goods are on a public road either way.
    select t.dealer_id,
           coalesce(v.purchase_cost, 0),
           coalesce(bf.state_code, d.state_code),
           coalesce(bt.state_code, d.state_code)
      into v_dealer, v_value, v_from, v_to
      from public.vehicle_transfers t
      join public.dealers  d  on d.id = t.dealer_id
      join public.branches bf on bf.id = t.from_branch_id
      join public.branches bt on bt.id = t.to_branch_id
      left join public.vehicles v on v.id = t.vehicle_id
     where t.id = p_document_id;
  else
    raise exception 'Unsupported document type %.', p_document_type using errcode = 'check_violation';
  end if;

  if v_dealer is null then
    raise exception 'Document not found.' using errcode = 'no_data_found';
  end if;

  interstate := coalesce(v_from, '') <> coalesce(v_to, '');
  v_key := case when interstate then 'eway.threshold_interstate' else 'eway.threshold_intrastate' end;

  select coalesce((value #>> '{}')::numeric, 50000) into threshold
    from public.system_settings
   where key = v_key and (dealer_id = v_dealer or dealer_id is null)
   order by dealer_id nulls last
   limit 1;

  threshold := coalesce(threshold, 50000);
  consignment_value := coalesce(v_value, 0);
  required := consignment_value > threshold;
  return next;
end;
$$;

comment on function public.eway_bill_required(text, uuid) is
  'Whether Rule 138 requires an e-way bill for this document, with the value and '
  'threshold it was judged against. The threshold is configuration: states differ '
  'on movement within the state, and several use 1,00,000.';

-- -----------------------------------------------------------------------------
-- public.eway_expected_validity() — how long the bill will be good for
-- -----------------------------------------------------------------------------
-- Rule 138(10): one day per 200km or part thereof, counted from generation. The
-- portal is the authority and its answer is stored when it replies; this is what
-- to expect, so a dispatcher can see whether the journey fits before sending.
-- -----------------------------------------------------------------------------
create or replace function public.eway_expected_validity(
  p_distance_km integer,
  p_from        timestamptz default now()
)
returns timestamptz
language sql
immutable
as $$
  select p_from + (greatest(ceil(coalesce(p_distance_km, 0)::numeric / 200), 1) || ' days')::interval;
$$;

comment on function public.eway_expected_validity(integer, timestamptz) is
  'One day per 200km or part thereof (Rule 138(10)). Indicative: the portal '
  'assigns the real validity and record_eway_result stores what it said.';

-- -----------------------------------------------------------------------------
-- public.eway_bill_payload() — the EWB-1 document
-- -----------------------------------------------------------------------------
create or replace function public.eway_bill_payload(p_eway_id uuid)
returns jsonb
language plpgsql
stable
as $$
declare
  v_e      public.eway_bills;
  v_seller record;
  v_buyer  record;
  v_items  jsonb;
  v_total  numeric(18, 4) := 0;
begin
  select * into v_e from public.eway_bills where id = p_eway_id;
  if v_e.id is null then
    raise exception 'E-way bill not found.' using errcode = 'no_data_found';
  end if;

  if v_e.document_type <> 'SALE' then
    -- Service invoices and branch transfers can be queued and tracked, but the
    -- payload for each is a different document under Rule 138 (delivery challan
    -- rather than tax invoice). Refusing is better than sending a sale-shaped
    -- body and having the portal reject it for reasons nobody can read.
    raise exception 'Only a sale can be filed automatically yet; % must be raised on the portal.',
      v_e.document_type using errcode = 'feature_not_supported';
  end if;

  select coalesce(b.gstin, d.gstin) as gstin,
         d.legal_name as name,
         b.address_line1, b.city, b.pincode,
         coalesce(b.state_code, d.state_code) as state_code
    into v_seller
    from public.sales s
    join public.branches b on b.id = s.branch_id
    join public.dealers  d on d.id = s.dealer_id
   where s.id = v_e.document_id;

  select c.gstin, c.name, c.address_line1, c.city, c.pincode,
         coalesce(c.state_code, v_seller.state_code) as state_code
    into v_buyer
    from public.sales s
    join public.customers c on c.id = s.customer_id
   where s.id = v_e.document_id;

  select jsonb_agg(jsonb_build_object(
           'productName', l.description,
           'hsnCode',     coalesce(l.hsn_code, ''),
           'quantity',    l.quantity,
           'taxableAmount', l.taxable_value,
           'cgstRate',    coalesce(l.cgst_rate, 0),
           'sgstRate',    coalesce(l.sgst_rate, 0),
           'igstRate',    coalesce(l.igst_rate, 0)
         ) order by l.line_number),
         sum(l.total_amount)
    into v_items, v_total
    from public.sale_lines l
   where l.sale_id = v_e.document_id;

  return jsonb_build_object(
    'supplyType',   'O',                      -- outward
    'subSupplyType','1',                      -- supply
    'docType',      'INV',
    'docNo',        v_e.document_number,
    'docDate',      to_char((select invoice_date from public.sales where id = v_e.document_id), 'DD/MM/YYYY'),
    'fromGstin',    coalesce(v_seller.gstin, 'URP'),
    'fromTrdName',  v_seller.name,
    'fromAddr1',    coalesce(v_seller.address_line1, ''),
    'fromPlace',    coalesce(v_seller.city, ''),
    'fromPincode',  coalesce(v_seller.pincode, ''),
    'fromStateCode', v_seller.state_code,
    -- An unregistered buyer is URP, exactly as on the invoice itself.
    'toGstin',      coalesce(v_buyer.gstin, 'URP'),
    'toTrdName',    v_buyer.name,
    'toAddr1',      coalesce(v_buyer.address_line1, ''),
    'toPlace',      coalesce(v_buyer.city, ''),
    'toPincode',    coalesce(v_buyer.pincode, ''),
    'toStateCode',  v_buyer.state_code,
    'totalValue',   v_total,
    'transMode',    case v_e.transport_mode
                      when 'ROAD' then '1' when 'RAIL' then '2'
                      when 'AIR'  then '3' when 'SHIP' then '4' else '1' end,
    'transDistance', coalesce(v_e.distance_km, 0)::text,
    'vehicleNo',    coalesce(v_e.vehicle_number, ''),
    'transporterId', coalesce(v_e.transporter_id, ''),
    'transporterName', coalesce(v_e.transporter_name, ''),
    'itemList',     coalesce(v_items, '[]'::jsonb)
  );
end;
$$;

comment on function public.eway_bill_payload(uuid) is
  'The EWB-1 body for a sale (spec §40). Refuses a service invoice or a transfer: '
  'each moves under a different document and a sale-shaped body would be rejected '
  'by the portal for reasons nobody could read.';

-- -----------------------------------------------------------------------------
-- Request and result, as 0048 does for e-invoices
-- -----------------------------------------------------------------------------
create or replace function public.record_eway_request(p_eway_id uuid, p_payload jsonb)
returns void
language plpgsql
as $$
begin
  update public.eway_bills
     set request_payload = p_payload,
         status          = 'PENDING',
         error_message   = null,
         -- Counted as the request leaves, so a lost reply still leaves evidence
         -- that an attempt was made.
         attempt_count   = attempt_count + 1,
         updated_at      = now()
   where id = p_eway_id
     and status <> 'GENERATED';

  if not found then
    raise exception 'That e-way bill is already generated, or does not exist.'
      using errcode = 'check_violation';
  end if;
end;
$$;

create or replace function public.record_eway_result(
  p_eway_id     uuid,
  p_status      text,
  p_number      text default null,
  p_valid_until timestamptz default null,
  p_error       text default null,
  p_response    jsonb default null
)
returns void
language plpgsql
as $$
begin
  if p_status not in ('GENERATED', 'FAILED', 'CANCELLED') then
    raise exception 'Status must be GENERATED, FAILED or CANCELLED.' using errcode = 'check_violation';
  end if;
  if p_status = 'GENERATED' and p_number is null then
    raise exception 'A generated e-way bill must carry its number.' using errcode = 'check_violation';
  end if;
  if p_status = 'FAILED' and p_error is null then
    raise exception 'A failed e-way bill must record why.' using errcode = 'check_violation';
  end if;

  update public.eway_bills
     set status           = p_status,
         eway_bill_number = coalesce(p_number, eway_bill_number),
         generated_at     = case when p_status = 'GENERATED' then coalesce(generated_at, now()) else generated_at end,
         valid_until      = coalesce(p_valid_until, valid_until),
         error_message    = p_error,
         response_payload = coalesce(p_response, response_payload),
         updated_at       = now()
   where id = p_eway_id;

  if not found then
    raise exception 'E-way bill record not found.' using errcode = 'no_data_found';
  end if;
end;
$$;

comment on function public.record_eway_result(uuid, text, text, timestamptz, text, jsonb) is
  'The outcome of one attempt (spec §40, §55). A portal failure never disturbs '
  'the invoice: the sale stays posted and the bill is retried.';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  execute 'grant execute on function public.eway_bill_required(text, uuid) to authenticated';
  execute 'grant execute on function public.eway_expected_validity(integer, timestamptz) to authenticated';
  execute 'grant execute on function public.eway_bill_payload(uuid) to authenticated';
  execute 'grant execute on function public.record_eway_request(uuid, jsonb) to authenticated';
  execute 'grant execute on function public.record_eway_result(uuid, text, text, timestamptz, text, jsonb) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0068', 'eway_bill') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0069_manual_journal.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0069 — Manual journal entries, and reversal from the screen
-- =============================================================================
-- Spec §9, §21, §23, §60.12, §60.13.
--
-- What was missing. `accounting.journals.create` and `accounting.journals.post`
-- have existed as permissions since 0003, spec §9 lists Journal Entries under
-- Accounting, and the screen has only ever *listed* journals. There has been no
-- way to write one: every entry in the ledger arrived through a sale, a receipt
-- or a purchase. A dealer with a bank charge, a depreciation entry, a director's
-- expense or a correction from their accountant had nowhere to put it.
--
-- ── What this is NOT ────────────────────────────────────────────────────────
--
-- It is not an edit. A posted journal cannot be changed — the trigger in 0007
-- refuses it, and its own hint says why: "post a reversal and a corrected entry
-- instead of editing" (spec §23, §60.12). That is not a limitation of the
-- implementation; an immutable ledger is the difference between a book of
-- account and a spreadsheet, and the audit trail depends on it.
--
-- So correcting an entry is two documents and both are visible: the reversal
-- that undoes it, carrying a reason and its author, and the replacement that
-- says what should have happened. Anyone reading the ledger afterwards can see
-- that a correction occurred, which is the entire point.
--
-- app.reverse_journal has done the first half since 0025 and nothing in the UI
-- could reach it. public.reverse_journal_entry is that door.
--
-- Rollback: drop both functions.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.post_manual_journal() — an entry a person writes
-- -----------------------------------------------------------------------------
-- p_lines is [{ "account_id": uuid, "debit": n, "credit": n,
--               "narration": text, "party_type": text, "party_id": uuid }, …]
--
-- Balance, line count and account validity are all enforced by app.post_journal
-- and the constraints beneath it. Nothing is re-checked here: a second copy of
-- those rules is a second place for them to drift.
-- -----------------------------------------------------------------------------
create or replace function public.post_manual_journal(
  p_entry_date      date,
  p_narration       text,
  p_lines           jsonb,
  p_branch_id       uuid default null,
  p_idempotency_key text default null
)
returns table (journal_entry_id uuid, entry_number text)
language plpgsql
as $$
declare
  v_dealer uuid;
  v_branch uuid;
  v_entry  uuid;
begin
  v_dealer := app.current_dealer_id();
  if v_dealer is null then
    -- A platform admin has no tenant and no business writing into one's books.
    raise exception 'Only a dealer user can post a journal entry.'
      using errcode = 'insufficient_privilege';
  end if;

  if coalesce(btrim(p_narration), '') = '' then
    raise exception 'A journal entry must say what it is for.'
      using errcode = 'check_violation',
            hint = 'The narration is what makes the entry readable a year later.';
  end if;

  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    raise exception 'A journal entry needs at least two lines.'
      using errcode = 'check_violation';
  end if;

  v_branch := coalesce(p_branch_id, (select id from public.branches
                                      where dealer_id = v_dealer order by code limit 1));

  -- Every line must belong to this dealer's chart. Without this a caller could
  -- name another tenant's account id and post into their books — RLS governs
  -- what is *read*, and this is a write through a SECURITY-scoped path.
  if exists (
    select 1
      from jsonb_array_elements(p_lines) l
     where not exists (
       select 1 from public.chart_of_accounts c
        where c.id = (l ->> 'account_id')::uuid
          and c.dealer_id = v_dealer
     )
  ) then
    raise exception 'A line names an account that does not belong to this dealer.'
      using errcode = 'insufficient_privilege';
  end if;

  v_entry := app.post_journal(
    v_dealer, v_branch, p_entry_date, 'MANUAL', btrim(p_narration), p_lines,
    'MANUAL_JOURNAL', null,
    case when p_idempotency_key is null then null else 'manual:' || p_idempotency_key end
  );

  journal_entry_id := v_entry;
  select je.entry_number into entry_number from public.journal_entries je where je.id = v_entry;
  return next;
end;
$$;

comment on function public.post_manual_journal(date, text, jsonb, uuid, text) is
  'A journal entry written by a person (spec §9, §21) — a bank charge, a '
  'depreciation entry, an accountant''s correction. Balance and line rules come '
  'from app.post_journal; this adds the tenant checks a caller-supplied account '
  'id needs.';

-- -----------------------------------------------------------------------------
-- public.reverse_journal_entry() — the sanctioned correction (spec §23)
-- -----------------------------------------------------------------------------
create or replace function public.reverse_journal_entry(
  p_journal_entry_id uuid,
  p_reason           text,
  p_reversal_date    date default current_date
)
returns table (journal_entry_id uuid, entry_number text)
language plpgsql
as $$
declare
  v_dealer uuid;
  v_owner  uuid;
  v_entry  uuid;
begin
  v_dealer := app.current_dealer_id();

  select dealer_id into v_owner from public.journal_entries where id = p_journal_entry_id;
  if v_owner is null then
    raise exception 'Journal entry not found.' using errcode = 'no_data_found';
  end if;
  if v_dealer is null or v_owner <> v_dealer then
    raise exception 'That journal belongs to another dealer.'
      using errcode = 'insufficient_privilege';
  end if;

  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'A reversal must say why.'
      using errcode = 'check_violation',
            hint = 'Spec §23: the reason is part of the record, not optional.';
  end if;

  v_entry := app.reverse_journal(p_journal_entry_id, btrim(p_reason), p_reversal_date);

  journal_entry_id := v_entry;
  select je.entry_number into entry_number from public.journal_entries je where je.id = v_entry;
  return next;
end;
$$;

comment on function public.reverse_journal_entry(uuid, text, date) is
  'Reverses a posted journal and links the two (spec §23). The only way to undo '
  'a posting: the original stays, the reversal states why, and both are visible '
  'to whoever reads the ledger afterwards.';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  execute 'grant execute on function public.post_manual_journal(date, text, jsonb, uuid, text) to authenticated';
  execute 'grant execute on function public.reverse_journal_entry(uuid, text, date) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0069', 'manual_journal') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/seed.sql (required sections only)
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- seed.sql — permission catalogue, system roles, and a demo dealer
-- =============================================================================
-- Two distinct kinds of data live here:
--
--   REQUIRED   The permission catalogue and the seven system roles from spec §6.
--              The application cannot authorize anything without these.
--
--   DEMO       One dealer ("Sri Balaji Motors"), three branches, seven users,
--              employees and a chart of accounts. Every demo row is created
--              inside the `demo` block at the bottom and is removable with the
--              single DELETE at the end of this file.
--
-- Idempotent: safe to run repeatedly. Re-running refreshes the catalogue without
-- disturbing dealer data.
--
-- Demo logins all use the password below; change or remove them before going live.
--   PASSWORD: TwErp@2026
-- =============================================================================

-- =============================================================================
-- REQUIRED — permission catalogue (mirrors src/lib/permissions/registry.ts)
-- =============================================================================
insert into public.permissions (code, module, description, is_sensitive) values
  ('dashboard.view',                  'dashboard',  'View the dashboard', false),
  ('dashboard.view_consolidated',     'dashboard',  'View all branches consolidated', false),
  ('dashboard.view_margin',           'dashboard',  'View margin and profit KPIs', true),

  ('sales.view',                      'sales',      'View vehicle sales', false),
  ('sales.create',                    'sales',      'Create a vehicle sale draft', false),
  ('sales.submit',                    'sales',      'Submit a sale for verification', false),
  ('sales.verify',                    'sales',      'Perform accounts verification of a sale', false),
  ('sales.approve',                   'sales',      'Approve a verified sale', false),
  ('sales.post',                      'sales',      'Post a sale to the accounting engine', false),
  ('sales.deliver',                   'sales',      'Record vehicle delivery', false),
  ('sales.cancel',                    'sales',      'Cancel a sale', false),
  ('sales.return',                    'sales',      'Record a sales return', false),
  ('sales.view_cost',                 'sales',      'View purchase cost and COGS on a sale', true),

  ('bookings.view',                   'bookings',   'View bookings', false),
  ('bookings.create',                 'bookings',   'Create a booking and advance receipt', false),
  ('bookings.cancel',                 'bookings',   'Cancel a booking', false),
  ('bookings.convert',                'bookings',   'Convert a booking into a vehicle sale', false),
  ('bookings.refund',                 'bookings',   'Refund a cancelled booking advance', false),

  ('customers.view',                  'customers',  'View and search customers', false),
  ('customers.create',                'customers',  'Create a customer', false),
  ('customers.edit',                  'customers',  'Edit customer details', false),
  ('customers.view_ledger',           'customers',  'View customer ledger and outstanding', false),
  ('customers.import',                'customers',  'Bulk-import customers from CSV', false),

  ('vehicles.stock.view',             'vehicles',   'View chassis-level vehicle stock', false),
  ('vehicles.stock.upload',           'vehicles',   'Upload vehicle stock from CSV/Excel', false),
  ('vehicles.stock.adjust',           'vehicles',   'Adjust vehicle stock', false),
  ('vehicles.models.view',            'vehicles',   'View models and variants', false),
  ('vehicles.models.manage',          'vehicles',   'Manage models and variants', false),
  ('vehicles.pricing.view',           'vehicles',   'View vehicle pricing and price history', false),
  ('vehicles.pricing.manage',         'vehicles',   'Configure vehicle price versions', false),
  ('vehicles.pricing.approve',        'vehicles',   'Approve a price version', false),
  ('vehicles.transfers.view',         'vehicles',   'View vehicle transfers', false),
  ('vehicles.transfers.manage',       'vehicles',   'Raise and receive vehicle transfers', false),
  ('vehicles.view_cost',              'vehicles',   'View vehicle purchase cost', true),

  ('inventory.view',                  'inventory',  'View accessory and spare stock', false),
  ('inventory.items.manage',          'inventory',  'Manage accessory and spare items', false),
  ('inventory.stock.upload',          'inventory',  'Upload accessory/spare stock', false),
  ('inventory.stock.transfer',        'inventory',  'Transfer stock between branches', false),
  ('inventory.stock.adjust',          'inventory',  'Adjust stock quantities', false),
  ('inventory.ledger.view',           'inventory',  'View the stock ledger', false),
  ('inventory.counter_sale.create',   'inventory',  'Create counter sales invoices', false),
  ('inventory.view_cost',             'inventory',  'View item purchase cost', true),

  ('service.jobcards.view',           'service',    'View job cards', false),
  ('service.jobcards.create',         'service',    'Create job cards', false),
  ('service.billing.create',          'service',    'Create service bills', false),
  ('service.payments.collect',        'service',    'Collect service payments', false),
  ('service.history.view',            'service',    'View vehicle and customer service history', false),

  ('finance.companies.view',          'finance',    'View finance companies', false),
  ('finance.companies.manage',        'finance',    'Manage finance companies', false),
  ('finance.applications.view',       'finance',    'View HP/finance applications', false),
  ('finance.applications.manage',     'finance',    'Manage HP/finance applications', false),
  ('finance.trade_advance.view',      'finance',    'View finance-company trade advances', false),
  ('finance.trade_advance.manage',    'finance',    'Record trade advance transactions', false),
  ('finance.settlements.manage',      'finance',    'Record finance settlements', false),
  ('finance.commission.view',         'finance',    'View finance commission income', true),

  ('accounting.coa.view',             'accounting', 'View the chart of accounts', false),
  ('accounting.coa.manage',           'accounting', 'Manage the chart of accounts', false),
  ('accounting.journals.view',        'accounting', 'View journal entries', false),
  ('accounting.journals.create',      'accounting', 'Create draft journal entries', false),
  ('accounting.journals.post',        'accounting', 'Post journal entries', false),
  ('accounting.journals.reverse',     'accounting', 'Reverse a posted journal entry', false),
  ('accounting.periods.manage',       'accounting', 'Open, close and lock accounting periods', false),
  ('accounting.ledgers.view',         'accounting', 'View customer, supplier and finance ledgers', false),
  ('accounting.allocations.manage',   'accounting', 'Split payments against bills and settle party ledgers', false),
  ('purchases.view',                  'purchases',  'View purchase bills', false),
  ('purchases.create',                'purchases',  'Create and edit draft purchase bills', false),
  ('purchases.post',                  'purchases',  'Post a purchase bill to the accounts', false),
  ('purchases.cancel',                'purchases',  'Cancel or reverse a purchase bill', false),
  ('purchases.return',                'purchases',  'Return purchased stock to a supplier (debit note)', false),
  ('hr.settings.manage',              'hr',         'Manage shifts and leave types', false),
  ('hr.salary.view',                  'hr',         'View employee salary structures', true),
  ('hr.salary.manage',                'hr',         'Set and revise employee salary structures', true),
  ('hr.leave.view',                   'hr',         'View employee leave balances', false),
  ('hr.leave.manage',                 'hr',         'Set and adjust leave balances', false),
  ('hr.documents.view',               'hr',         'View employee documents', false),
  ('hr.documents.manage',             'hr',         'Upload and manage employee documents', false),
  ('hr.attendance.view',              'hr',         'View the attendance register', false),
  ('hr.attendance.sync',              'hr',         'Pull attendance from the external system', false),
  ('hr.attendance.edit',              'hr',         'Correct an attendance day by hand', false),
  ('hr.mapping.manage',               'hr',         'Map employees to the external attendance system', false),
  ('accounting.reports.view',         'accounting', 'View trial balance, P&L and balance sheet', false),

  ('cashbook.view',                   'cashbook',   'View the daily cash book', false),
  ('cashbook.receipts.create',        'cashbook',   'Record cash receipts', false),
  ('cashbook.payments.create',        'cashbook',   'Record cash payments', false),
  ('cashbook.day_close',              'cashbook',   'Count cash and close the day', false),
  ('cashbook.day_reopen',             'cashbook',   'Reopen a closed day for adjustment', false),

  ('bank.accounts.view',              'bank',       'View bank accounts', false),
  ('bank.accounts.manage',            'bank',       'Manage bank accounts', false),
  ('bank.book.view',                  'bank',       'View the bank book', false),
  ('bank.book.record',                'bank',       'Record bank receipts and payments', false),
  ('bank.statement.import',           'bank',       'Import bank statements', false),
  ('bank.reconcile',                  'bank',       'Reconcile bank transactions', false),

  ('gst.summary.view',                'gst',        'View GST summary', false),
  ('gst.einvoice.generate',           'gst',        'Generate e-invoices', false),
  ('gst.einvoice.retry',              'gst',        'Retry failed e-invoice requests', false),
  ('gst.ewaybill.generate',           'gst',        'Generate e-way bills', false),
  ('gst.reports.view',                'gst',        'View GST reports', false),

  ('reports.sales.view',              'reports',    'View sales reports', false),
  ('reports.inventory.view',          'reports',    'View inventory reports', false),
  ('reports.finance.view',            'reports',    'View finance reports', false),
  ('reports.accounting.view',         'reports',    'View accounting reports', false),
  ('reports.branch_performance.view', 'reports',    'View branch performance', false),
  ('reports.consolidated.view',       'reports',    'View consolidated MIS across branches', false),
  ('reports.margin.view',             'reports',    'View margin reports', true),
  ('reports.profitability.view',      'reports',    'View profitability reports', true),

  ('masters.tax.view',                'masters',    'View tax codes', false),
  ('masters.tax.manage',              'masters',    'Manage tax codes and GST rates', false),
  ('masters.hsn.view',                'masters',    'View HSN/SAC codes', false),
  ('masters.hsn.manage',              'masters',    'Manage HSN/SAC codes', false),
  ('masters.employees.view',          'masters',    'View employees', false),
  ('masters.employees.manage',        'masters',    'Manage employees', false),
  ('masters.pricing.manage',          'masters',    'Manage pricing templates', false),
  ('masters.suppliers.view',          'masters',    'View suppliers', false),
  ('masters.suppliers.manage',        'masters',    'Manage suppliers', false),

  ('admin.dealers.view',              'admin',      'View dealer configuration', false),
  ('admin.dealers.manage',            'admin',      'Manage dealer configuration', false),
  ('admin.branches.view',             'admin',      'View branches', false),
  ('admin.branches.manage',           'admin',      'Create and manage branches', false),
  ('admin.users.view',                'admin',      'View users', false),
  ('admin.users.manage',              'admin',      'Create and manage users and their access', false),
  ('admin.roles.view',                'admin',      'View roles and permissions', false),
  ('admin.roles.manage',              'admin',      'Manage roles and permission assignments', false),
  ('admin.audit.view',                'admin',      'View the audit trail', false),
  ('admin.settings.view',             'admin',      'View system settings', false),
  ('admin.settings.manage',           'admin',      'Manage system settings and document sequences', false)
on conflict (code) do update
  set module       = excluded.module,
      description  = excluded.description,
      is_sensitive = excluded.is_sensitive;

-- =============================================================================
-- REQUIRED — system roles (spec §6)
-- =============================================================================
insert into public.roles (code, name, description, is_system, dealer_id) values
  ('PLATFORM_ADMIN',  'Platform Admin',   'Manages dealers and platform configuration', true, null),
  ('DEALER_OWNER',    'Dealer Owner',     'Full access to the dealer, all branches, all financials', true, null),
  ('ACCOUNTS',        'Accounts',         'Accounting, pricing, GST, verification and margin visibility', true, null),
  ('CASHIER',         'Cashier',          'Bookings, receipts and sales drafts; no cost or margin access', true, null),
  ('SALES_EXECUTIVE', 'Sales Executive',  'Customers, bookings and sale preparation', true, null),
  ('SERVICE_ADVISOR', 'Service Advisor',  'Job cards, service billing and service payments', true, null),
  ('COUNTER_SALES',   'Counter Sales',    'Accessory and spare counter sales', true, null)
-- Matches the partial index roles_system_code_key (unique on code where dealer_id is null).
on conflict (code) where dealer_id is null do update
  set name        = excluded.name,
      description = excluded.description;

-- -----------------------------------------------------------------------------
-- Role → permission grants
-- -----------------------------------------------------------------------------
-- Rebuilt from scratch on every run so the matrix here is authoritative.
delete from public.role_permissions rp
 using public.roles r
 where r.id = rp.role_id and r.is_system;

-- PLATFORM_ADMIN: platform-level administration. Tenant data access comes from
-- app.is_platform_admin(), not from these grants.
insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join public.permissions p
 where r.code = 'PLATFORM_ADMIN'
   and p.module = 'admin';

-- DEALER_OWNER: everything except platform administration (spec §6).
insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join public.permissions p
 where r.code = 'DEALER_OWNER'
   and p.code <> 'admin.dealers.manage';

-- ACCOUNTS: stock upload, pricing, GST, verification, all ledgers and reports,
-- and full cost/margin visibility (spec §6).
insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join public.permissions p
 where r.code = 'ACCOUNTS'
   and (
        p.module in ('accounting', 'cashbook', 'bank', 'gst', 'reports', 'masters', 'inventory', 'vehicles', 'finance', 'purchases')
     or p.code in (
          'dashboard.view', 'dashboard.view_consolidated', 'dashboard.view_margin',
          'sales.view', 'sales.verify', 'sales.approve', 'sales.post', 'sales.cancel',
          'sales.return', 'sales.view_cost',
          'bookings.view', 'bookings.cancel', 'bookings.refund',
          'customers.view', 'customers.view_ledger', 'customers.import',
          'service.jobcards.view', 'service.history.view',
          'admin.audit.view', 'admin.settings.view', 'admin.settings.manage',
          'admin.branches.view', 'admin.users.view',
          -- HR paperwork and the roster, but deliberately not the pay scale:
          -- the accountant is usually an employee too (see migration 0053).
          'hr.settings.manage', 'hr.leave.view', 'hr.leave.manage',
          'hr.documents.view', 'hr.documents.manage',
          'hr.attendance.view', 'hr.attendance.sync', 'hr.attendance.edit', 'hr.mapping.manage'
        )
   );

-- CASHIER: bookings, receipts, sale drafts, selling price and customer balance.
-- Explicitly excludes every sensitive permission (spec §6, §52).
insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join public.permissions p
 where r.code = 'CASHIER'
   and not p.is_sensitive
   and p.code in (
     'dashboard.view',
     'customers.view', 'customers.create', 'customers.edit', 'customers.view_ledger',
     'bookings.view', 'bookings.create',
     'sales.view', 'sales.create', 'sales.submit',
     'vehicles.stock.view', 'vehicles.pricing.view',
     'inventory.view',
     'cashbook.view', 'cashbook.receipts.create'
   );

-- SALES_EXECUTIVE: customers, bookings, sale preparation, vehicle availability.
insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join public.permissions p
 where r.code = 'SALES_EXECUTIVE'
   and not p.is_sensitive
   and p.code in (
     'dashboard.view',
     'customers.view', 'customers.create', 'customers.edit',
     'bookings.view', 'bookings.create',
     'sales.view', 'sales.create', 'sales.submit',
     'vehicles.stock.view', 'vehicles.models.view', 'vehicles.pricing.view'
   );

-- SERVICE_ADVISOR: job cards, service billing, service payments.
insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join public.permissions p
 where r.code = 'SERVICE_ADVISOR'
   and not p.is_sensitive
   and p.code in (
     'dashboard.view',
     'customers.view', 'customers.create', 'customers.edit',
     'service.jobcards.view', 'service.jobcards.create',
     'service.billing.create', 'service.payments.collect', 'service.history.view',
     'inventory.view',
     'vehicles.stock.view'
   );

-- COUNTER_SALES: accessory and spare sales over the counter.
insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join public.permissions p
 where r.code = 'COUNTER_SALES'
   and not p.is_sensitive
   and p.code in (
     'dashboard.view',
     'customers.view', 'customers.create',
     'inventory.view', 'inventory.counter_sale.create',
     'cashbook.view', 'cashbook.receipts.create'
   );



commit;
