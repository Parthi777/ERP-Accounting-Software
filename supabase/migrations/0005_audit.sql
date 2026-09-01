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
