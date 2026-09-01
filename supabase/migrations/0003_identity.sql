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
