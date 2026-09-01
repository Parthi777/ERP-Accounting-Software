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
