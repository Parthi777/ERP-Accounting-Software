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
