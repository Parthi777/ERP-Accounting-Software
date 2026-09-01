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
