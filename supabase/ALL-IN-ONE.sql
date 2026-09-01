-- =============================================================================
-- ALL-IN-ONE.sql — every migration and seed, concatenated in order
-- =============================================================================
-- GENERATED FILE. Do not edit; edit the sources and regenerate with
--   bash scripts/build-all-in-one.sh
--
-- For pasting into the Supabase SQL Editor in a single run instead of applying
-- fourteen files by hand. Wrapped in one transaction: if any statement fails,
-- the whole thing rolls back and the database is left untouched — you will never
-- end up with a half-applied schema.
--
-- Run once, on an empty project. Re-running fails on the first CREATE TABLE,
-- which is the intended signal that there is nothing to do.
--
-- Includes the demo ledger. For a production database, delete the
-- seed-demo-ledger.sql section at the end before running.
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
-- SOURCE: supabase/seed.sql
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
        p.module in ('accounting', 'cashbook', 'bank', 'gst', 'reports', 'masters', 'inventory', 'vehicles', 'finance')
     or p.code in (
          'dashboard.view', 'dashboard.view_consolidated', 'dashboard.view_margin',
          'sales.view', 'sales.verify', 'sales.approve', 'sales.post', 'sales.cancel',
          'sales.return', 'sales.view_cost',
          'bookings.view', 'bookings.cancel', 'bookings.refund',
          'customers.view', 'customers.view_ledger',
          'service.jobcards.view', 'service.history.view',
          'admin.audit.view', 'admin.settings.view', 'admin.settings.manage',
          'admin.branches.view', 'admin.users.view'
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

-- =============================================================================
-- DEMO — one dealer, three branches, seven users, chart of accounts
-- =============================================================================
-- Remove everything below with:
--   delete from public.dealers where code = 'SBM';
-- =============================================================================
do $$
declare
  v_dealer_id   uuid;
  v_main        uuid;
  v_north       uuid;
  v_south       uuid;
  v_fy          text := '2026';
  v_user        record;
  v_role_id     uuid;
  v_account     record;
  v_parent_id   uuid;
  -- Real Supabase's auth.users carries encrypted_password; the local shim does not.
  v_is_shim     boolean := not exists (
    select 1 from information_schema.columns
     where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password'
  );
begin
  -- ── Dealer ────────────────────────────────────────────────────────────────
  insert into public.dealers (code, legal_name, trade_name, gstin, pan,
                              address_line1, city, state, state_code, pincode, phone, email)
  values ('SBM', 'Sri Balaji Motors Private Limited', 'Sri Balaji Motors',
          '33AABCS1429B1ZQ', 'AABCS1429B',
          '142 Anna Salai', 'Chennai', 'Tamil Nadu', '33', '600002',
          '+914428520000', 'accounts@sribalajimotors.example')
  on conflict (code) do update set legal_name = excluded.legal_name
  returning id into v_dealer_id;

  -- ── Branches ──────────────────────────────────────────────────────────────
  insert into public.branches (dealer_id, code, name, gstin, city, state, state_code, pincode, is_head_office)
  values (v_dealer_id, 'MAIN', 'Main Branch', '33AABCS1429B1ZQ', 'Chennai', 'Tamil Nadu', '33', '600002', true)
  on conflict (dealer_id, code) do update set name = excluded.name
  returning id into v_main;

  insert into public.branches (dealer_id, code, name, gstin, city, state, state_code, pincode)
  values (v_dealer_id, 'NORTH', 'Ambattur Branch', '33AABCS1429B1ZQ', 'Chennai', 'Tamil Nadu', '33', '600053')
  on conflict (dealer_id, code) do update set name = excluded.name
  returning id into v_north;

  insert into public.branches (dealer_id, code, name, gstin, city, state, state_code, pincode)
  values (v_dealer_id, 'SOUTH', 'Tambaram Branch', '33AABCS1429B1ZQ', 'Chennai', 'Tamil Nadu', '33', '600045')
  on conflict (dealer_id, code) do update set name = excluded.name
  returning id into v_south;

  -- ── Users, one per system role ────────────────────────────────────────────
  -- Only against the local test shim.
  --
  -- On a real Supabase project, a login must be created through Supabase Auth so
  -- GoTrue owns the password hash and the account metadata. Writing rows into
  -- auth.users by hand produces accounts that cannot sign in, and worse, squats
  -- on the email address so creating the account properly later fails on the
  -- unique index.
  --
  -- So: create the users in Authentication → Users, then run
  -- scripts/link-auth-users.sql, which matches them by email and wires up the
  -- profile, role and branch rows.
  if not v_is_shim then
    raise notice 'Real Supabase detected — skipping demo user creation.';
    raise notice 'Create the logins in Authentication → Users, then run scripts/link-auth-users.sql.';
  end if;

  for v_user in
    select * from (values
      ('11111111-1111-4111-8111-111111111111'::uuid, 'owner@sribalajimotors.example',   'Rajesh Kumar',   'DEALER_OWNER',    true),
      ('22222222-2222-4222-8222-222222222222'::uuid, 'accounts@sribalajimotors.example','Priya Venkatesh','ACCOUNTS',        true),
      ('33333333-3333-4333-8333-333333333333'::uuid, 'cashier@sribalajimotors.example', 'Anand Raj',      'CASHIER',         false),
      ('44444444-4444-4444-8444-444444444444'::uuid, 'sales@sribalajimotors.example',   'Divya Shankar',  'SALES_EXECUTIVE', false),
      ('55555555-5555-4555-8555-555555555555'::uuid, 'service@sribalajimotors.example', 'Karthik Murali', 'SERVICE_ADVISOR', false),
      ('66666666-6666-4666-8666-666666666666'::uuid, 'counter@sribalajimotors.example', 'Meena Lakshmi',  'COUNTER_SALES',   false)
    ) as t(id, email, full_name, role_code, all_branches)
  loop
    continue when not v_is_shim;

    insert into auth.users (id, email) values (v_user.id, v_user.email)
    on conflict (id) do nothing;

    insert into public.user_profiles (id, dealer_id, full_name, email, has_all_branch_access, default_branch_id)
    values (v_user.id, v_dealer_id, v_user.full_name, v_user.email, v_user.all_branches, v_main)
    on conflict (id) do update
      set full_name             = excluded.full_name,
          has_all_branch_access = excluded.has_all_branch_access,
          default_branch_id     = excluded.default_branch_id;

    select id into v_role_id from public.roles where code = v_user.role_code and dealer_id is null;
    insert into public.user_roles (user_id, role_id) values (v_user.id, v_role_id)
    on conflict do nothing;

    -- Branch-limited users get an explicit grant to the main branch only.
    if not v_user.all_branches then
      insert into public.user_branches (user_id, branch_id, dealer_id)
      values (v_user.id, v_main, v_dealer_id)
      on conflict do nothing;
    end if;
  end loop;

  -- A platform admin, outside the tenant model. Shim only, for the same reason.
  if v_is_shim then
    insert into auth.users (id, email)
    values ('00000000-0000-4000-8000-000000000000', 'platform@twerp.example')
    on conflict (id) do nothing;

    insert into public.user_profiles (id, dealer_id, full_name, email, is_platform_admin)
    values ('00000000-0000-4000-8000-000000000000', null, 'Platform Administrator', 'platform@twerp.example', true)
    on conflict (id) do update set is_platform_admin = true;

    insert into public.user_roles (user_id, role_id)
    select '00000000-0000-4000-8000-000000000000',
           id from public.roles where code = 'PLATFORM_ADMIN' and dealer_id is null
    on conflict do nothing;
  end if;

  -- ── Employees (spec §12) ──────────────────────────────────────────────────
  -- user_id is attached only under the shim; on Supabase, link-auth-users.sql
  -- fills it in once the real logins exist.
  insert into public.employees (dealer_id, branch_id, employee_code, name, department, designation, mobile, joining_date, user_id)
  select e.dealer_id, e.branch_id, e.employee_code, e.name, e.department, e.designation,
         e.mobile, e.joining_date, case when v_is_shim then e.user_id else null end
    from (values
    (v_dealer_id, v_main,  'EMP0001', 'Rajesh Kumar',    'Management', 'Managing Director', '9840012001', date '2015-04-01', '11111111-1111-4111-8111-111111111111'),
    (v_dealer_id, v_main,  'EMP0002', 'Priya Venkatesh', 'Accounts',   'Accounts Manager',  '9840012002', date '2018-06-15', '22222222-2222-4222-8222-222222222222'),
    (v_dealer_id, v_main,  'EMP0003', 'Anand Raj',       'Front Desk', 'Cashier',           '9840012003', date '2021-01-11', '33333333-3333-4333-8333-333333333333'),
    (v_dealer_id, v_main,  'EMP0004', 'Divya Shankar',   'Sales',      'Sales Executive',   '9840012004', date '2022-08-01', '44444444-4444-4444-8444-444444444444'),
    (v_dealer_id, v_main,  'EMP0005', 'Karthik Murali',  'Service',    'Service Advisor',   '9840012005', date '2020-03-02', '55555555-5555-4555-8555-555555555555'),
    (v_dealer_id, v_main,  'EMP0006', 'Meena Lakshmi',   'Counter',    'Counter Sales',     '9840012006', date '2023-05-20', '66666666-6666-4666-8666-666666666666'),
    (v_dealer_id, v_north, 'EMP0007', 'Suresh Babu',     'Sales',      'Branch Manager',    '9840012007', date '2019-09-09', null),
    (v_dealer_id, v_south, 'EMP0008', 'Vidya Ramesh',    'Sales',      'Branch Manager',    '9840012008', date '2019-11-01', null::uuid)
  ) as e(dealer_id, branch_id, employee_code, name, department, designation, mobile, joining_date, user_id)
  on conflict (dealer_id, employee_code) do update set name = excluded.name;

  -- ── Chart of accounts (spec §24) ──────────────────────────────────────────
  -- Group headers first, then the postable leaves beneath them.
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
    v_parent_id := null;
    if v_account.parent_code is not null then
      select id into v_parent_id
        from public.chart_of_accounts
       where dealer_id = v_dealer_id and code = v_account.parent_code;
    end if;

    insert into public.chart_of_accounts
      (dealer_id, code, name, account_type, normal_balance, is_group, parent_id, is_system, is_branch_scoped)
    values
      (v_dealer_id, v_account.code, v_account.name, v_account.account_type,
       v_account.normal_balance, v_account.is_group, v_parent_id, true, v_account.branch_scoped)
    on conflict (dealer_id, code) do update set name = excluded.name;
  end loop;

  -- ── Default accounting rules (spec §22) ───────────────────────────────────
  -- Called here rather than relying on migration 0027's loop: at migration time
  -- this dealer and its chart of accounts do not exist yet, so there is nothing
  -- for that loop to map. (The loop still serves a database that is being
  -- upgraded, where the dealer is already present.)
  perform app.seed_default_accounting_rules(v_dealer_id);
  perform app.seed_finance_accounting_rules(v_dealer_id);

  -- ── Accounting period: Indian FY 2026-27 ──────────────────────────────────
  insert into public.accounting_periods (dealer_id, name, start_date, end_date, status)
  values (v_dealer_id, 'FY 2026-27', date '2026-04-01', date '2027-03-31', 'OPEN')
  on conflict (dealer_id, start_date, end_date) do nothing;

  -- ── Document sequences (spec §45) ─────────────────────────────────────────
  -- All dealer-wide (branch_id null).
  --
  -- Every number below is stored in a column that is unique per *dealer* —
  -- sales_invoice_key, bookings_number_key, the three receipt keys, jc_number_key,
  -- si_number_key, vehicle_transfers_number_key, deliveries_number_key. A
  -- per-branch counter cannot feed a per-dealer unique column: every branch
  -- starts at 1 with the same prefix, so the second branch to issue its first
  -- document collides with the first (spec §45, §60.3).
  --
  -- The branch is still recorded on every document; it is simply not what
  -- allocates the number. app.next_document_number() prefers a dealer-wide row
  -- over a branch one, so a type that ever needs a per-branch series just omits
  -- its dealer-wide row here.
  insert into public.document_sequences (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
  values (v_dealer_id, null, 'VEHICLE_INVOICE',     v_fy, 'INV', 6),
         (v_dealer_id, null, 'BOOKING',             v_fy, 'BK',  6),
         (v_dealer_id, null, 'RECEIPT',             v_fy, 'REC', 6),
         (v_dealer_id, null, 'PAYMENT',             v_fy, 'PAY', 6),
         (v_dealer_id, null, 'JOB_CARD',            v_fy, 'JC',  6),
         (v_dealer_id, null, 'SERVICE_INVOICE',     v_fy, 'SVC', 6),
         (v_dealer_id, null, 'COUNTER_INVOICE',     v_fy, 'CSI', 6),
         (v_dealer_id, null, 'JOURNAL',             v_fy, 'JE',  6),
         (v_dealer_id, null, 'BANK_RECONCILIATION', v_fy, 'BRS', 6),
         (v_dealer_id, null, 'STOCK_TRANSFER',      v_fy, 'TRF', 6),
         (v_dealer_id, null, 'DELIVERY',            v_fy, 'DN',  6),
         (v_dealer_id, null, 'FINANCE_APPLICATION', v_fy, 'FA',  6),
         (v_dealer_id, null, 'FINANCE_SETTLEMENT',  v_fy, 'FS',  6)
  on conflict on constraint document_sequences_scope_key do nothing;

  -- ── Settings ──────────────────────────────────────────────────────────────
  insert into public.system_settings (dealer_id, key, value, value_type, description, is_public)
  values
    (v_dealer_id, 'accounting.booking_recognises_revenue', 'false'::jsonb, 'boolean',
     'Bookings post to Customer Advances rather than revenue (spec §18).', true),
    (v_dealer_id, 'inventory.allow_negative_stock', 'false'::jsonb, 'boolean',
     'Counter sales cannot drive stock below zero (spec §33).', true),
    (v_dealer_id, 'inventory.accessory_allocation_order', '["LOCAL","COMPANY"]'::jsonb, 'json',
     'Consume local accessory stock before company stock (spec §31).', true),
    (v_dealer_id, 'cashbook.require_daily_close', 'true'::jsonb, 'boolean',
     'Daily cash closing is mandatory (spec §60.15).', true),
    (v_dealer_id, 'counter_sale.require_customer', 'false'::jsonb, 'boolean',
     'Require a customer on every counter sale (spec §33).', true)
  on conflict on constraint system_settings_scope_key do update set value = excluded.value;

  raise notice 'Seeded dealer %: % branches, % users, % employees, % accounts.',
    v_dealer_id,
    (select count(*) from public.branches           where dealer_id = v_dealer_id),
    (select count(*) from public.user_profiles      where dealer_id = v_dealer_id),
    (select count(*) from public.employees          where dealer_id = v_dealer_id),
    (select count(*) from public.chart_of_accounts  where dealer_id = v_dealer_id);
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/seed-demo-ledger.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- seed-demo-ledger.sql — DEMO ONLY
-- =============================================================================
-- Posts a month of balanced journal entries for the demo dealer so the dashboard
-- has real numbers behind it before the sales, inventory and service modules
-- exist.
--
-- These are not mock values painted onto the UI. Every figure the dashboard shows
-- is computed by public.account_balances() from double-entry journals that
-- satisfy the same constraints and immutability rules as production data — the
-- entries are simply seeded rather than raised by a business module.
--
-- Remove with:
--   delete from public.journal_entry_lines l using public.journal_entries je
--    where je.id = l.journal_entry_id and je.narration like '[DEMO]%';
--   -- posted journals cannot be deleted, so drop the dealer to fully reset:
--   -- see the teardown note in seed.sql
--
-- Skip this file entirely for a production deployment.
-- =============================================================================

do $$
declare
  v_dealer   uuid;
  v_main     uuid;
  v_north    uuid;
  v_south    uuid;
  v_period   uuid;
  v_branches uuid[];
  v_branch   uuid;
  v_day      date;
  v_je       uuid;
  v_number   text;
  v_scale    numeric;
  v_i        int;

  -- Account ids, resolved once.
  a_cash uuid; a_bank uuid; a_recv uuid; a_finrecv uuid;
  a_veh_stock uuid; a_acc_stock uuid; a_spr_stock uuid;
  a_advance uuid; a_payable uuid; a_cgst uuid; a_sgst uuid; a_capital uuid;
  a_veh_sales uuid; a_acc_sales uuid; a_spr_sales uuid; a_service uuid;
  a_fin_comm uuid; a_ins_comm uuid; a_fwd uuid;
  a_veh_cogs uuid; a_acc_cogs uuid; a_spr_cogs uuid; a_svc_cost uuid;
  a_salaries uuid; a_rent uuid;

  function_missing boolean;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  if v_dealer is null then
    raise notice 'Demo dealer SBM not found; skipping demo ledger.';
    return;
  end if;

  -- Already seeded? Leave it alone so re-running is harmless.
  select exists (
    select 1 from public.journal_entries
     where dealer_id = v_dealer and narration like '[DEMO]%'
  ) into function_missing;
  if function_missing then
    raise notice 'Demo ledger already present; skipping.';
    return;
  end if;

  select id into v_main  from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_north from public.branches where dealer_id = v_dealer and code = 'NORTH';
  select id into v_south from public.branches where dealer_id = v_dealer and code = 'SOUTH';
  v_branches := array[v_main, v_north, v_south];

  select id into v_period from public.accounting_periods
   where dealer_id = v_dealer and start_date = date '2026-04-01';

  select id into a_cash      from public.chart_of_accounts where dealer_id = v_dealer and code = '1100';
  select id into a_bank      from public.chart_of_accounts where dealer_id = v_dealer and code = '1200';
  select id into a_recv      from public.chart_of_accounts where dealer_id = v_dealer and code = '1300';
  select id into a_finrecv   from public.chart_of_accounts where dealer_id = v_dealer and code = '1400';
  select id into a_veh_stock from public.chart_of_accounts where dealer_id = v_dealer and code = '1500';
  select id into a_acc_stock from public.chart_of_accounts where dealer_id = v_dealer and code = '1600';
  select id into a_spr_stock from public.chart_of_accounts where dealer_id = v_dealer and code = '1700';
  select id into a_advance   from public.chart_of_accounts where dealer_id = v_dealer and code = '2100';
  select id into a_payable   from public.chart_of_accounts where dealer_id = v_dealer and code = '2200';
  select id into a_cgst      from public.chart_of_accounts where dealer_id = v_dealer and code = '2300';
  select id into a_sgst      from public.chart_of_accounts where dealer_id = v_dealer and code = '2400';
  select id into a_capital   from public.chart_of_accounts where dealer_id = v_dealer and code = '3100';
  select id into a_veh_sales from public.chart_of_accounts where dealer_id = v_dealer and code = '4100';
  select id into a_acc_sales from public.chart_of_accounts where dealer_id = v_dealer and code = '4200';
  select id into a_spr_sales from public.chart_of_accounts where dealer_id = v_dealer and code = '4300';
  select id into a_service   from public.chart_of_accounts where dealer_id = v_dealer and code = '4400';
  select id into a_fin_comm  from public.chart_of_accounts where dealer_id = v_dealer and code = '4500';
  select id into a_ins_comm  from public.chart_of_accounts where dealer_id = v_dealer and code = '4600';
  select id into a_fwd       from public.chart_of_accounts where dealer_id = v_dealer and code = '4700';
  select id into a_veh_cogs  from public.chart_of_accounts where dealer_id = v_dealer and code = '5100';
  select id into a_acc_cogs  from public.chart_of_accounts where dealer_id = v_dealer and code = '5200';
  select id into a_spr_cogs  from public.chart_of_accounts where dealer_id = v_dealer and code = '5300';
  select id into a_svc_cost  from public.chart_of_accounts where dealer_id = v_dealer and code = '5400';
  select id into a_salaries  from public.chart_of_accounts where dealer_id = v_dealer and code = '5500';
  select id into a_rent      from public.chart_of_accounts where dealer_id = v_dealer and code = '5600';

  -- ── Opening balances: capital funds cash, bank and stock ──────────────────
  v_number := app.next_document_number(v_dealer, null, 'JOURNAL', '2026');
  insert into public.journal_entries
    (dealer_id, branch_id, entry_number, entry_date, period_id, source_module, narration)
  values (v_dealer, v_main, v_number, date '2026-04-01', v_period, 'OPENING',
          '[DEMO] Opening balances FY 2026-27')
  returning id into v_je;

  insert into public.journal_entry_lines
    (journal_entry_id, dealer_id, line_number, account_id, branch_id, debit, credit, narration)
  values
    (v_je, v_dealer, 1, a_cash,      v_main,   650000.00,        0, 'Opening cash'),
    (v_je, v_dealer, 2, a_bank,      v_main, 11200000.00,        0, 'Opening bank'),
    (v_je, v_dealer, 3, a_veh_stock, v_main, 30500000.00,        0, 'Opening vehicle stock'),
    (v_je, v_dealer, 4, a_acc_stock, v_main,  2400000.00,        0, 'Opening accessories stock'),
    (v_je, v_dealer, 5, a_spr_stock, v_main,  1650000.00,        0, 'Opening spare stock'),
    (v_je, v_dealer, 6, a_payable,   v_main,          0, 2350000.00, 'Opening supplier payables'),
    (v_je, v_dealer, 7, a_capital,   v_main,          0, 44050000.00, 'Share capital');

  update public.journal_entries set status = 'POSTED' where id = v_je;

  -- ── A month of trading, spread across the three branches ──────────────────
  -- Each day posts one composite sales entry and one service entry. Amounts vary
  -- deterministically so the sales-trend chart has a believable shape without
  -- being random from run to run.
  v_i := 0;
  for v_day in select generate_series(date '2026-08-01', date '2026-08-30', interval '1 day')::date loop
    v_i := v_i + 1;
    v_branch := v_branches[1 + (v_i % 3)];
    -- A repeating weekly rhythm plus a slow upward drift.
    v_scale := 0.72 + 0.34 * sin(v_i::numeric / 2.1) + 0.010 * v_i;

    -- Vehicle sale: part cash, part finance, with GST and COGS.
    v_number := app.next_document_number(v_dealer, null, 'JOURNAL', '2026');
    insert into public.journal_entries
      (dealer_id, branch_id, entry_number, entry_date, period_id, source_module, narration)
    values (v_dealer, v_branch, v_number, v_day, v_period, 'SALES',
            '[DEMO] Vehicle sales ' || to_char(v_day, 'DD Mon YYYY'))
    returning id into v_je;

    insert into public.journal_entry_lines
      (journal_entry_id, dealer_id, line_number, account_id, branch_id, debit, credit, narration)
    values
      (v_je, v_dealer, 1, a_cash,      v_branch, round(240000 * v_scale, 2), 0, 'Cash collected'),
      (v_je, v_dealer, 2, a_finrecv,   v_branch, round(560000 * v_scale, 2), 0, 'Finance receivable'),
      (v_je, v_dealer, 3, a_veh_sales, v_branch, 0, round(620000 * v_scale, 2), 'Ex-showroom value'),
      (v_je, v_dealer, 4, a_acc_sales, v_branch, 0, round( 46000 * v_scale, 2), 'Fitted accessories'),
      (v_je, v_dealer, 5, a_fwd,       v_branch, 0, round(  8000 * v_scale, 2), 'Forwarding charges'),
      (v_je, v_dealer, 6, a_ins_comm,  v_branch, 0, round(  7400 * v_scale, 2), 'Insurance commission'),
      (v_je, v_dealer, 7, a_cgst,      v_branch, 0, round( 59300 * v_scale, 2), 'Output CGST'),
      (v_je, v_dealer, 8, a_sgst,      v_branch, 0, round( 59300 * v_scale, 2), 'Output SGST'),
      -- COGS and the matching stock relief.
      (v_je, v_dealer, 9, a_veh_cogs,  v_branch, round(521000 * v_scale, 2), 0, 'Vehicle COGS'),
      (v_je, v_dealer, 10, a_acc_cogs, v_branch, round( 31000 * v_scale, 2), 0, 'Accessories COGS'),
      (v_je, v_dealer, 11, a_veh_stock, v_branch, 0, round(521000 * v_scale, 2), 'Vehicle stock relief'),
      (v_je, v_dealer, 12, a_acc_stock, v_branch, 0, round( 31000 * v_scale, 2), 'Accessories stock relief');

    -- Balance the rounding: the debit and credit legs above are independently
    -- rounded, so square them off against cash before posting.
    declare
      v_debit  numeric(18, 4);
      v_credit numeric(18, 4);
      v_diff   numeric(18, 4);
    begin
      select coalesce(sum(debit), 0), coalesce(sum(credit), 0)
        into v_debit, v_credit
        from public.journal_entry_lines where journal_entry_id = v_je;
      v_diff := v_debit - v_credit;

      if v_diff <> 0 then
        update public.journal_entry_lines
           set debit = debit - v_diff
         where journal_entry_id = v_je and line_number = 1;
      end if;
    end;

    update public.journal_entries set status = 'POSTED' where id = v_je;

    -- Service billing: labour and spares, collected in cash.
    v_number := app.next_document_number(v_dealer, null, 'JOURNAL', '2026');
    insert into public.journal_entries
      (dealer_id, branch_id, entry_number, entry_date, period_id, source_module, narration)
    values (v_dealer, v_branch, v_number, v_day, v_period, 'SERVICE',
            '[DEMO] Service billing ' || to_char(v_day, 'DD Mon YYYY'))
    returning id into v_je;

    insert into public.journal_entry_lines
      (journal_entry_id, dealer_id, line_number, account_id, branch_id, debit, credit, narration)
    values
      (v_je, v_dealer, 1, a_cash,      v_branch, round(42000 * v_scale, 2), 0, 'Service collections'),
      (v_je, v_dealer, 2, a_service,   v_branch, 0, round(21000 * v_scale, 2), 'Labour'),
      (v_je, v_dealer, 3, a_spr_sales, v_branch, 0, round(14600 * v_scale, 2), 'Spares billed'),
      (v_je, v_dealer, 4, a_cgst,      v_branch, 0, round( 3200 * v_scale, 2), 'Output CGST'),
      (v_je, v_dealer, 5, a_sgst,      v_branch, 0, round( 3200 * v_scale, 2), 'Output SGST'),
      (v_je, v_dealer, 6, a_spr_cogs,  v_branch, round( 9800 * v_scale, 2), 0, 'Spare COGS'),
      (v_je, v_dealer, 7, a_svc_cost,  v_branch, round( 2600 * v_scale, 2), 0, 'Service consumables'),
      (v_je, v_dealer, 8, a_spr_stock, v_branch, 0, round( 9800 * v_scale, 2), 'Spare stock relief'),
      (v_je, v_dealer, 9, a_acc_stock, v_branch, 0, round( 2600 * v_scale, 2), 'Consumables relief');

    declare
      v_debit  numeric(18, 4);
      v_credit numeric(18, 4);
      v_diff   numeric(18, 4);
    begin
      select coalesce(sum(debit), 0), coalesce(sum(credit), 0)
        into v_debit, v_credit
        from public.journal_entry_lines where journal_entry_id = v_je;
      v_diff := v_debit - v_credit;

      if v_diff <> 0 then
        update public.journal_entry_lines
           set debit = debit - v_diff
         where journal_entry_id = v_je and line_number = 1;
      end if;
    end;

    update public.journal_entries set status = 'POSTED' where id = v_je;
  end loop;

  -- ── Booking advances outstanding ──────────────────────────────────────────
  v_number := app.next_document_number(v_dealer, null, 'JOURNAL', '2026');
  insert into public.journal_entries
    (dealer_id, branch_id, entry_number, entry_date, period_id, source_module, narration)
  values (v_dealer, v_main, v_number, date '2026-08-28', v_period, 'BOOKING',
          '[DEMO] Booking advances received')
  returning id into v_je;

  insert into public.journal_entry_lines
    (journal_entry_id, dealer_id, line_number, account_id, branch_id, debit, credit, narration)
  values
    (v_je, v_dealer, 1, a_cash,    v_main, 1124500.00, 0, 'Advances collected'),
    (v_je, v_dealer, 2, a_advance, v_main, 0, 1124500.00, 'Customer advances (spec §18)');

  update public.journal_entries set status = 'POSTED' where id = v_je;

  -- ── Finance commission and a bank deposit ─────────────────────────────────
  v_number := app.next_document_number(v_dealer, null, 'JOURNAL', '2026');
  insert into public.journal_entries
    (dealer_id, branch_id, entry_number, entry_date, period_id, source_module, narration)
  values (v_dealer, v_main, v_number, date '2026-08-29', v_period, 'FINANCE',
          '[DEMO] Finance disbursement and commission')
  returning id into v_je;

  insert into public.journal_entry_lines
    (journal_entry_id, dealer_id, line_number, account_id, branch_id, debit, credit, narration)
  values
    (v_je, v_dealer, 1, a_bank,     v_main, 9850000.00, 0, 'Finance disbursements received'),
    (v_je, v_dealer, 2, a_finrecv,  v_main, 0, 9850000.00, 'Finance receivable settled'),
    (v_je, v_dealer, 3, a_bank,     v_main,  384000.00, 0, 'Commission credited'),
    (v_je, v_dealer, 4, a_fin_comm, v_main, 0,  384000.00, 'Finance commission income');

  update public.journal_entries set status = 'POSTED' where id = v_je;

  -- ── Operating expenses ────────────────────────────────────────────────────
  v_number := app.next_document_number(v_dealer, null, 'JOURNAL', '2026');
  insert into public.journal_entries
    (dealer_id, branch_id, entry_number, entry_date, period_id, source_module, narration)
  values (v_dealer, v_main, v_number, date '2026-08-30', v_period, 'EXPENSE',
          '[DEMO] Monthly operating expenses')
  returning id into v_je;

  insert into public.journal_entry_lines
    (journal_entry_id, dealer_id, line_number, account_id, branch_id, debit, credit, narration)
  values
    (v_je, v_dealer, 1, a_salaries, v_main, 1860000.00, 0, 'Salaries'),
    (v_je, v_dealer, 2, a_rent,     v_main,  420000.00, 0, 'Rent'),
    (v_je, v_dealer, 3, a_bank,     v_main, 0, 2280000.00, 'Paid by bank transfer');

  update public.journal_entries set status = 'POSTED' where id = v_je;

  -- ── Trade payables partly settled, some receivables outstanding ───────────
  v_number := app.next_document_number(v_dealer, null, 'JOURNAL', '2026');
  insert into public.journal_entries
    (dealer_id, branch_id, entry_number, entry_date, period_id, source_module, narration)
  values (v_dealer, v_main, v_number, date '2026-08-30', v_period, 'CASH',
          '[DEMO] Customer dues outstanding')
  returning id into v_je;

  insert into public.journal_entry_lines
    (journal_entry_id, dealer_id, line_number, account_id, branch_id, debit, credit, narration)
  values
    (v_je, v_dealer, 1, a_recv,  v_main, 4875430.00, 0, 'Customer receivables'),
    (v_je, v_dealer, 2, a_cash,  v_main, 0, 4875430.00, 'Credit extended against cash sales');

  update public.journal_entries set status = 'POSTED' where id = v_je;

  raise notice '[DEMO] Ledger seeded: % posted journals.',
    (select count(*) from public.journal_entries where dealer_id = v_dealer and status = 'POSTED');
end;
$$;


commit;
