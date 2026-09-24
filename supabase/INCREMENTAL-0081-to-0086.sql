-- =============================================================================
-- INCREMENTAL 0081 → 0086
-- =============================================================================
-- GENERATED FILE. Regenerate with:
--   FROM=0081 bash scripts/build-incremental.sh
--
-- For a database that ALREADY has migrations up to 0080.
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
-- SOURCE: supabase/migrations/0081_approvals_attachments_place_of_supply.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0081 — Maker-checker approval, attachments, and place of supply
-- =============================================================================
-- Spec §6, §16, §19, §23, §35, §40, §46. Audit checklist §02 (general journal:
-- approvals), §03 (source and attachments), §06 (counts and exceptions:
-- approved), §07 (GSTIN and place of supply), §11 test E.
--
-- ── 1. Approval before posting ─────────────────────────────────────────────
--
-- A manual journal posted the moment it was written, and a stock adjustment
-- moved stock the moment it was entered. Both are the two places where one
-- person can change the books without any business document behind them, and
-- the checklist asks for an approval step on each.
--
-- approval_requests holds the request — who asked, for what, why — and nothing
-- posts until a DIFFERENT person with the approve permission accepts it. The
-- request is validated in full when it is made (balance, accounts, lock date,
-- stock on hand) by posting it inside a savepoint and rolling back, so a
-- request that could never be approved is refused at the door rather than in
-- the approver's queue. Numbering happens at approval, so a rejected request
-- leaves no gap in the journal series.
--
-- Whether approval is required is a dealer setting, one per kind:
--   approvals.manual_journal   approvals.stock_adjustment
-- Off by default, so turning this on is a decision and not a surprise. With it
-- on, the direct functions refuse and say to submit for approval.
--
-- ── 2. Attachments ─────────────────────────────────────────────────────────
--
-- A journal, a purchase bill or a filing had no way to carry the paper behind
-- it. document_attachments records a file in Supabase Storage (private bucket
-- `attachments`, one folder per dealer, readable only by that dealer) against
-- any document. Rows are append-only: evidence that can be quietly removed is
-- not evidence.
--
-- ── 3. Place of supply, and the tax it implies ─────────────────────────────
--
-- Every sale and service invoice was taxed CGST + SGST, whoever the customer
-- was. A customer registered in another state must be charged IGST; charging
-- intra-state tax to them is a wrong invoice, not a presentation detail. The
-- place of supply was never stored — the e-invoice payload derived it on the
-- fly — so nothing checked it either.
--
--   * sales and service_invoices gain place_of_supply (a state code), set from
--     the customer's state, else the branch's (a walk-in buys at the counter);
--   * a trigger on sale_lines and service_lines turns CGST + SGST into IGST at
--     the same total rate when the place of supply is another state;
--   * posting refuses an invoice whose tax does not match its place of supply,
--     a B2B customer whose GSTIN is malformed or names a different state, or
--     a B2B customer with no state. (Checklist test E.)
--
-- Rollback: drop the tables, triggers and functions created here; move
--           app.post_manual_journal_core and app.adjust_inventory_stock_core
--           back to public under their old names; drop the place_of_supply
--           columns.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Settings and permissions
-- -----------------------------------------------------------------------------
insert into public.system_settings (dealer_id, key, value, value_type, description, is_public)
select d.id, k.key, 'false'::jsonb, 'boolean', k.description, true
  from public.dealers d
  cross join (values
    ('approvals.manual_journal',   'Manual journals need a second person to approve them before they post.'),
    ('approvals.stock_adjustment', 'Stock count adjustments need a second person to approve them before they post.')
  ) as k(key, description)
on conflict on constraint system_settings_scope_key do nothing;

create or replace function app.setting_enabled(p_dealer_id uuid, p_key text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((
    select s.value = 'true'::jsonb
      from public.system_settings s
     where s.key = p_key and (s.dealer_id = p_dealer_id or s.dealer_id is null)
     order by s.dealer_id nulls last
     limit 1), false);
$$;

insert into public.permissions (code, module, description, is_sensitive) values
  ('accounting.journals.approve', 'accounting', 'Approve or reject manual journals submitted by someone else', false),
  ('inventory.stock.approve',     'inventory',  'Approve or reject stock adjustments submitted by someone else', false),
  ('attachments.upload',          'accounting', 'Attach supporting files to documents', false)
on conflict (code) do update set module = excluded.module, description = excluded.description;

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join (values ('accounting.journals.approve'), ('inventory.stock.approve'), ('attachments.upload')) as p(code)
 where r.is_system and r.code in ('DEALER_OWNER', 'ACCOUNTS')
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- The direct functions move behind approval-aware wrappers
-- -----------------------------------------------------------------------------
-- The app schema is not exposed through the API, so the core functions can be
-- reached only through the wrappers below and the approval function.
alter function public.post_manual_journal(date, text, jsonb, uuid, text) set schema app;
alter function app.post_manual_journal(date, text, jsonb, uuid, text) rename to post_manual_journal_core;

alter function public.adjust_inventory_stock(uuid, uuid, text, numeric, text) set schema app;
alter function app.adjust_inventory_stock(uuid, uuid, text, numeric, text) rename to adjust_inventory_stock_core;

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
begin
  if app.setting_enabled(app.current_dealer_id(), 'approvals.manual_journal') then
    raise exception 'Manual journals need approval at this dealer. Submit it for approval instead.'
      using errcode = 'insufficient_privilege',
            hint = 'A second person with accounting.journals.approve posts it.';
  end if;
  return query select * from app.post_manual_journal_core(
    p_entry_date, p_narration, p_lines, p_branch_id, p_idempotency_key);
end;
$$;

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
begin
  if app.setting_enabled(app.current_dealer_id(), 'approvals.stock_adjustment') then
    raise exception 'Stock adjustments need approval at this dealer. Submit it for approval instead.'
      using errcode = 'insufficient_privilege',
            hint = 'A second person with inventory.stock.approve posts it.';
  end if;
  perform app.adjust_inventory_stock_core(p_item_id, p_branch_id, p_source, p_quantity, p_reason);
end;
$$;

-- -----------------------------------------------------------------------------
-- approval_requests
-- -----------------------------------------------------------------------------
create table public.approval_requests (
  id              uuid primary key default gen_random_uuid(),
  dealer_id       uuid not null references public.dealers (id) on delete restrict,
  branch_id       uuid,
  kind            text not null,
  payload         jsonb not null,
  summary         text not null,
  amount          numeric(18, 4),
  status          text not null default 'PENDING',

  requested_by    uuid not null,
  requested_at    timestamptz not null default now(),
  decided_by      uuid,
  decided_at      timestamptz,
  decision_note   text,
  -- What approval produced: the journal entry.
  result_id       uuid,

  idempotency_key text,

  constraint approval_requests_kind_check check (kind in ('MANUAL_JOURNAL', 'STOCK_ADJUSTMENT')),
  constraint approval_requests_status_check check (status in ('PENDING', 'APPROVED', 'REJECTED', 'WITHDRAWN')),
  constraint approval_requests_decided_check check (
    status = 'PENDING' or (decided_by is not null and decided_at is not null)
  ),
  constraint approval_requests_rejection_reason_check check (
    status <> 'REJECTED' or length(btrim(coalesce(decision_note, ''))) >= 3
  ),
  constraint approval_requests_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id)
);

create unique index approval_requests_idempotency_key
  on public.approval_requests (dealer_id, idempotency_key) where idempotency_key is not null;
create index approval_requests_pending_idx
  on public.approval_requests (dealer_id, kind, requested_at) where status = 'PENDING';

comment on table public.approval_requests is
  'Maker-checker queue (spec §6, §23, §35): a manual journal or stock adjustment '
  'that posts only when a second person approves it.';

-- A decided request is a record; only the decision itself may be written.
create or replace function app.approval_requests_guard()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'An approval request is a record and cannot be deleted. Withdraw it instead.'
      using errcode = 'insufficient_privilege';
  end if;
  if old.status <> 'PENDING' then
    raise exception 'This request was already %.', lower(old.status)
      using errcode = 'check_violation';
  end if;
  if (to_jsonb(new) - 'status' - 'decided_by' - 'decided_at' - 'decision_note' - 'result_id')
     <> (to_jsonb(old) - 'status' - 'decided_by' - 'decided_at' - 'decision_note' - 'result_id') then
    raise exception 'A request cannot be edited; withdraw it and submit a new one.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger approval_requests_guard
  before update or delete on public.approval_requests
  for each row execute function app.approval_requests_guard();

create trigger approval_requests_audit
  after insert or update on public.approval_requests
  for each row execute function app.audit_trigger();

alter table public.approval_requests enable row level security;

create policy approval_requests_select on public.approval_requests
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and (requested_by = auth.uid()
             or app.has_permission('accounting.journals.approve')
             or app.has_permission('inventory.stock.approve')
             or app.has_permission('accounting.journals.view')))
  );

create policy approval_requests_insert on public.approval_requests
  for insert to authenticated
  with check (dealer_id = app.current_dealer_id() and requested_by = auth.uid());

create policy approval_requests_update on public.approval_requests
  for update to authenticated
  using (dealer_id = app.current_dealer_id())
  with check (dealer_id = app.current_dealer_id());

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.approval_requests to authenticated';
  end if;
end $$;

-- Posts the payload inside a savepoint and rolls it back: every rule the real
-- posting applies — balance, accounts, lock date, stock on hand — is checked
-- now, and nothing is written or numbered.
create or replace function app.dry_run_approval(p_kind text, p_payload jsonb)
returns void
language plpgsql
as $$
begin
  begin
    if p_kind = 'MANUAL_JOURNAL' then
      perform app.post_manual_journal_core(
        (p_payload ->> 'entry_date')::date, p_payload ->> 'narration', p_payload -> 'lines',
        (p_payload ->> 'branch_id')::uuid, null);
    else
      perform app.adjust_inventory_stock_core(
        (p_payload ->> 'item_id')::uuid, (p_payload ->> 'branch_id')::uuid,
        p_payload ->> 'source', (p_payload ->> 'quantity')::numeric, p_payload ->> 'reason');
    end if;
    raise exception using errcode = 'P0001', message = '__approval_dry_run_ok__';
  exception when others then
    if sqlerrm <> '__approval_dry_run_ok__' then
      raise;
    end if;
  end;
end;
$$;

-- -----------------------------------------------------------------------------
-- Submitting
-- -----------------------------------------------------------------------------
create or replace function public.request_manual_journal(
  p_entry_date      date,
  p_narration       text,
  p_lines           jsonb,
  p_branch_id       uuid default null,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_dealer  uuid := app.current_dealer_id();
  v_id      uuid;
  v_payload jsonb;
  v_total   numeric;
begin
  if v_dealer is null then
    raise exception 'Only a dealer user can submit a journal.' using errcode = 'insufficient_privilege';
  end if;
  if not (app.has_permission('accounting.journals.create') or app.has_permission('accounting.journals.post')) then
    raise exception 'You may not write journal entries.' using errcode = 'insufficient_privilege';
  end if;

  if p_idempotency_key is not null then
    select id into v_id from public.approval_requests
     where dealer_id = v_dealer and idempotency_key = p_idempotency_key;
    if v_id is not null then
      return v_id;
    end if;
  end if;

  v_payload := jsonb_build_object('entry_date', p_entry_date, 'narration', btrim(coalesce(p_narration, '')),
                                  'lines', p_lines, 'branch_id', p_branch_id);
  perform app.dry_run_approval('MANUAL_JOURNAL', v_payload);

  select sum(coalesce((l ->> 'debit')::numeric, 0)) into v_total from jsonb_array_elements(p_lines) l;

  insert into public.approval_requests
    (dealer_id, branch_id, kind, payload, summary, amount, requested_by, idempotency_key)
  values
    (v_dealer, p_branch_id, 'MANUAL_JOURNAL', v_payload, btrim(p_narration), v_total, auth.uid(), p_idempotency_key)
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.request_stock_adjustment(
  p_item_id         uuid,
  p_branch_id       uuid,
  p_source          text,
  p_quantity        numeric,
  p_reason          text,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_dealer  uuid := app.current_dealer_id();
  v_id      uuid;
  v_payload jsonb;
  v_item    text;
begin
  if v_dealer is null or not app.has_permission('inventory.stock.adjust') then
    raise exception 'You may not adjust stock.' using errcode = 'insufficient_privilege';
  end if;

  if p_idempotency_key is not null then
    select id into v_id from public.approval_requests
     where dealer_id = v_dealer and idempotency_key = p_idempotency_key;
    if v_id is not null then
      return v_id;
    end if;
  end if;

  v_payload := jsonb_build_object('item_id', p_item_id, 'branch_id', p_branch_id, 'source', p_source,
                                  'quantity', p_quantity, 'reason', btrim(coalesce(p_reason, '')));
  perform app.dry_run_approval('STOCK_ADJUSTMENT', v_payload);

  select item_code || ' ' || name into v_item from public.inventory_items where id = p_item_id;

  insert into public.approval_requests
    (dealer_id, branch_id, kind, payload, summary, amount, requested_by, idempotency_key)
  values
    (v_dealer, p_branch_id, 'STOCK_ADJUSTMENT', v_payload,
     v_item || ' ' || p_source || ' ' || case when p_quantity > 0 then '+' else '' end || p_quantity::text
       || ' — ' || btrim(p_reason),
     p_quantity, auth.uid(), p_idempotency_key)
  returning id into v_id;

  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Deciding
-- -----------------------------------------------------------------------------
create or replace function public.decide_approval(
  p_request_id uuid,
  p_approve    boolean,
  p_note       text default null
)
returns uuid
language plpgsql
as $$
declare
  v_req    public.approval_requests;
  v_result uuid;
  v_perm   text;
begin
  select * into v_req from public.approval_requests
   where id = p_request_id and dealer_id = app.current_dealer_id()
     for update;
  if v_req.id is null then
    raise exception 'Approval request not found.' using errcode = 'no_data_found';
  end if;
  if v_req.status <> 'PENDING' then
    raise exception 'This request was already %.', lower(v_req.status) using errcode = 'check_violation';
  end if;

  v_perm := case v_req.kind when 'MANUAL_JOURNAL' then 'accounting.journals.approve'
                            else 'inventory.stock.approve' end;
  if not app.has_permission(v_perm) then
    raise exception 'You may not approve this kind of request.' using errcode = 'insufficient_privilege';
  end if;
  -- Maker-checker: the point is a second pair of eyes.
  if v_req.requested_by = auth.uid() then
    raise exception 'You submitted this request, so someone else has to decide it.'
      using errcode = 'insufficient_privilege';
  end if;

  if not p_approve then
    if length(btrim(coalesce(p_note, ''))) < 3 then
      raise exception 'Say why it is rejected; the person who submitted it needs to know.'
        using errcode = 'check_violation';
    end if;
    update public.approval_requests
       set status = 'REJECTED', decided_by = auth.uid(), decided_at = now(), decision_note = btrim(p_note)
     where id = p_request_id;
    return null;
  end if;

  if v_req.kind = 'MANUAL_JOURNAL' then
    select r.journal_entry_id into v_result
      from app.post_manual_journal_core(
        (v_req.payload ->> 'entry_date')::date, v_req.payload ->> 'narration', v_req.payload -> 'lines',
        (v_req.payload ->> 'branch_id')::uuid, 'approval:' || v_req.id::text) r;
  else
    perform app.adjust_inventory_stock_core(
      (v_req.payload ->> 'item_id')::uuid, (v_req.payload ->> 'branch_id')::uuid,
      v_req.payload ->> 'source', (v_req.payload ->> 'quantity')::numeric, v_req.payload ->> 'reason');
    select t.reference_id into v_result
      from public.inventory_transactions t
     where t.item_id = (v_req.payload ->> 'item_id')::uuid and t.transaction_type = 'ADJUSTMENT'
     order by t.id desc limit 1;
  end if;

  update public.approval_requests
     set status = 'APPROVED', decided_by = auth.uid(), decided_at = now(),
         decision_note = nullif(btrim(coalesce(p_note, '')), ''), result_id = v_result
   where id = p_request_id;

  return v_result;
end;
$$;

comment on function public.decide_approval(uuid, boolean, text) is
  'Approves (posting the journal or adjustment) or rejects (with a reason) a '
  'request submitted by someone else (spec §6, §23).';

create or replace function public.withdraw_approval(p_request_id uuid)
returns void
language plpgsql
as $$
begin
  update public.approval_requests
     set status = 'WITHDRAWN', decided_by = auth.uid(), decided_at = now()
   where id = p_request_id and status = 'PENDING' and requested_by = auth.uid()
     and dealer_id = app.current_dealer_id();
  if not found then
    raise exception 'Only a pending request you submitted can be withdrawn.' using errcode = 'check_violation';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- document_attachments
-- -----------------------------------------------------------------------------
create table public.document_attachments (
  id            uuid primary key default gen_random_uuid(),
  dealer_id     uuid not null references public.dealers (id) on delete restrict,
  entity_type   text not null,
  entity_id     uuid not null,
  storage_path  text not null,
  file_name     text not null,
  content_type  text not null,
  size_bytes    bigint not null,
  note          text,
  uploaded_by   uuid not null,
  created_at    timestamptz not null default now(),

  constraint document_attachments_path_key unique (storage_path),
  constraint document_attachments_entity_type_check check (entity_type in (
    'JOURNAL_ENTRY', 'PURCHASE_BILL', 'SALE', 'SERVICE_INVOICE', 'BANK_TRANSACTION',
    'CASH_TRANSACTION', 'APPROVAL_REQUEST', 'FIXED_ASSET', 'PARTY_NOTE', 'GST_FILING', 'PAYROLL_RUN', 'LOAN'
  )),
  constraint document_attachments_size_check check (size_bytes > 0 and size_bytes <= 10485760),
  -- The folder is the dealer: the storage policy below reads the same prefix.
  constraint document_attachments_path_shape_check check (
    storage_path like dealer_id::text || '/%'
  )
);

create index document_attachments_entity_idx on public.document_attachments (dealer_id, entity_type, entity_id);

comment on table public.document_attachments is
  'Supporting files (spec §46; checklist §03). Append-only: evidence is not removable.';

create or replace function app.document_attachments_append_only()
returns trigger
language plpgsql
as $$
begin
  raise exception 'An attachment is evidence and cannot be changed or removed.'
    using errcode = 'insufficient_privilege';
end;
$$;

create trigger document_attachments_append_only
  before update or delete on public.document_attachments
  for each row execute function app.document_attachments_append_only();

create trigger document_attachments_audit
  after insert on public.document_attachments
  for each row execute function app.audit_trigger();

alter table public.document_attachments enable row level security;

create policy document_attachments_select on public.document_attachments
  for select to authenticated
  using (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy document_attachments_insert on public.document_attachments
  for insert to authenticated
  with check (dealer_id = app.current_dealer_id() and uploaded_by = auth.uid()
              and app.has_permission('attachments.upload'));

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert on public.document_attachments to authenticated';
  end if;
end $$;

-- The private bucket and its per-dealer folder policy. Supabase only: the local
-- verification database has no storage schema, and skips this.
do $$
begin
  if not exists (select 1 from pg_namespace where nspname = 'storage') then
    raise notice '0081: no storage schema here; the attachments bucket is created on Supabase only.';
    return;
  end if;

  execute $sql$
    insert into storage.buckets (id, name, public, file_size_limit)
    values ('attachments', 'attachments', false, 10485760)
    on conflict (id) do nothing
  $sql$;

  execute $sql$
    drop policy if exists attachments_read on storage.objects;
    create policy attachments_read on storage.objects for select to authenticated
      using (bucket_id = 'attachments'
             and (storage.foldername(name))[1] = app.current_dealer_id()::text)
  $sql$;

  execute $sql$
    drop policy if exists attachments_write on storage.objects;
    create policy attachments_write on storage.objects for insert to authenticated
      with check (bucket_id = 'attachments'
                  and (storage.foldername(name))[1] = app.current_dealer_id()::text
                  and app.has_permission('attachments.upload'))
  $sql$;
end $$;

-- -----------------------------------------------------------------------------
-- Place of supply
-- -----------------------------------------------------------------------------
alter table public.sales            add column if not exists place_of_supply text;
alter table public.service_invoices add column if not exists place_of_supply text;

alter table public.sales
  add constraint sales_pos_shape_check check (place_of_supply is null or place_of_supply ~ '^[0-9]{2}$');
alter table public.service_invoices
  add constraint service_invoices_pos_shape_check check (place_of_supply is null or place_of_supply ~ '^[0-9]{2}$');

-- The supplier's state: the branch's, else the dealer's.
create or replace function app.supplier_state(p_branch_id uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(nullif(btrim(b.state_code), ''), nullif(btrim(d.state_code), ''))
    from public.branches b
    join public.dealers d on d.id = b.dealer_id
   where b.id = p_branch_id;
$$;

create or replace function app.recipient_state(p_customer_id uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select nullif(btrim(c.state_code), '') from public.customers c where c.id = p_customer_id;
$$;

-- The place of supply: where the customer is; a walk-in buys at the counter.
create or replace function app.set_place_of_supply()
returns trigger
language plpgsql
as $$
begin
  if new.place_of_supply is null
     or (tg_op = 'UPDATE' and new.customer_id is distinct from old.customer_id) then
    new.place_of_supply := coalesce(app.recipient_state(new.customer_id), app.supplier_state(new.branch_id));
  end if;
  return new;
end;
$$;

create trigger sales_set_place_of_supply
  before insert or update of customer_id on public.sales
  for each row execute function app.set_place_of_supply();

create trigger service_invoices_set_place_of_supply
  before insert or update of customer_id on public.service_invoices
  for each row execute function app.set_place_of_supply();

-- Documents already on file get theirs.
update public.sales s
   set place_of_supply = coalesce(app.recipient_state(s.customer_id), app.supplier_state(s.branch_id))
 where s.place_of_supply is null;
update public.service_invoices si
   set place_of_supply = coalesce(app.recipient_state(si.customer_id), app.supplier_state(si.branch_id))
 where si.place_of_supply is null and si.status = 'DRAFT';

-- A line on an inter-state document carries IGST at the combined rate.
create or replace function app.apply_place_of_supply_tax()
returns trigger
language plpgsql
as $$
declare
  v_pos      text;
  v_supplier text;
  v_rate     numeric;
  v_old_tax  numeric;
begin
  if tg_table_name = 'sale_lines' then
    select s.place_of_supply, app.supplier_state(s.branch_id) into v_pos, v_supplier
      from public.sales s where s.id = new.sale_id;
  else
    select si.place_of_supply, app.supplier_state(si.branch_id) into v_pos, v_supplier
      from public.service_invoices si where si.id = new.invoice_id;
  end if;

  if v_pos is not null and v_supplier is not null and v_pos <> v_supplier
     and (new.cgst_rate > 0 or new.sgst_rate > 0) then
    v_rate    := new.cgst_rate + new.sgst_rate;
    v_old_tax := new.cgst_amount + new.sgst_amount;
    new.igst_rate   := v_rate;
    new.igst_amount := round(new.taxable_value * v_rate / 100, 2);
    new.cgst_rate := 0; new.sgst_rate := 0;
    new.cgst_amount := 0; new.sgst_amount := 0;
    new.total_amount := new.total_amount - v_old_tax + new.igst_amount;
  end if;
  return new;
end;
$$;

create trigger sale_lines_place_of_supply_tax
  before insert or update of taxable_value, cgst_rate, sgst_rate on public.sale_lines
  for each row execute function app.apply_place_of_supply_tax();

create trigger service_lines_place_of_supply_tax
  before insert or update of taxable_value, cgst_rate, sgst_rate on public.service_lines
  for each row execute function app.apply_place_of_supply_tax();

-- -----------------------------------------------------------------------------
-- Posting refuses a document whose GST facts do not hold together (test E)
-- -----------------------------------------------------------------------------
create or replace function app.validate_gst_document()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_gstin    text;
  v_state    text;
  v_supplier text;
  v_label    text := coalesce(new.invoice_number, 'this invoice');
begin
  if not (new.status = 'POSTED' and old.status is distinct from 'POSTED') then
    return new;
  end if;

  v_supplier := app.supplier_state(new.branch_id);

  if new.customer_id is not null then
    select nullif(btrim(c.gstin), ''), nullif(btrim(c.state_code), '') into v_gstin, v_state
      from public.customers c where c.id = new.customer_id;

    if v_gstin is not null then
      if v_gstin !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z]Z[0-9A-Z]$' then
        raise exception 'Invoice %: the customer''s GSTIN % is not a valid GSTIN.', v_label, v_gstin
          using errcode = 'check_violation', hint = 'Correct it on the customer before posting.';
      end if;
      if v_state is null then
        raise exception 'Invoice %: a registered customer needs a state for the place of supply.', v_label
          using errcode = 'check_violation';
      end if;
      if left(v_gstin, 2) <> v_state then
        raise exception 'Invoice %: GSTIN % is registered in state %, but the customer''s state is %.',
          v_label, v_gstin, left(v_gstin, 2), v_state
          using errcode = 'check_violation';
      end if;
    end if;
  end if;

  if (new.cgst_amount + new.sgst_amount + new.igst_amount) > 0 then
    if new.place_of_supply is null or v_supplier is null then
      raise exception 'Invoice %: the place of supply and the branch''s state are both needed to charge GST.', v_label
        using errcode = 'check_violation',
              hint = 'Set the state code on the branch (Administration → Branches) and the customer.';
    end if;
    if new.place_of_supply <> v_supplier and (new.cgst_amount + new.sgst_amount) > 0 then
      raise exception 'Invoice %: the place of supply (%) is outside the branch''s state (%), so the tax must be IGST, not CGST + SGST.',
        v_label, new.place_of_supply, v_supplier using errcode = 'check_violation';
    end if;
    if new.place_of_supply = v_supplier and new.igst_amount > 0 then
      raise exception 'Invoice %: the place of supply is the branch''s own state (%), so the tax must be CGST + SGST, not IGST.',
        v_label, v_supplier using errcode = 'check_violation';
    end if;
  end if;

  return new;
end;
$$;

create trigger sales_validate_gst
  before update of status on public.sales
  for each row execute function app.validate_gst_document();

create trigger service_invoices_validate_gst
  before update of status on public.service_invoices
  for each row execute function app.validate_gst_document();

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------
revoke execute on function app.setting_enabled(uuid, text) from public;
revoke execute on function app.supplier_state(uuid) from public;
revoke execute on function app.recipient_state(uuid) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function app.setting_enabled(uuid, text) to authenticated';
    execute 'grant execute on function app.supplier_state(uuid) to authenticated';
    execute 'grant execute on function app.recipient_state(uuid) to authenticated';
    execute 'grant execute on function public.post_manual_journal(date, text, jsonb, uuid, text) to authenticated';
    execute 'grant execute on function public.adjust_inventory_stock(uuid, uuid, text, numeric, text) to authenticated';
    execute 'grant execute on function public.request_manual_journal(date, text, jsonb, uuid, text) to authenticated';
    execute 'grant execute on function public.request_stock_adjustment(uuid, uuid, text, numeric, text, text) to authenticated';
    execute 'grant execute on function public.decide_approval(uuid, boolean, text) to authenticated';
    execute 'grant execute on function public.withdraw_approval(uuid) to authenticated';
  end if;
end $$;

insert into public.schema_migrations (version, name)
values ('0081', 'approvals_attachments_place_of_supply') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0082_fixed_assets_payroll_loans.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0082 — Fixed assets and depreciation, payroll, and loans
-- =============================================================================
-- Spec §12, §21, §24, §41. Audit checklist §02 (depreciation / accruals, loans
-- and interest, payroll), §09 (fixed asset and depreciation register).
--
-- ── Fixed assets ───────────────────────────────────────────────────────────
--
-- A computer could be bought on a purchase bill (0078) and depreciated by a
-- hand journal (0076), but nothing remembered the asset: its cost, its life,
-- what had been charged against it, what it was worth now. fixed_assets is the
-- register; run_depreciation() posts a month's depreciation for every asset in
-- one journal per branch, at most once per asset per month (a unique key, not
-- a convention); dispose_fixed_asset() takes it off the books with the gain or
-- loss. Registering an asset posts nothing — its cost is already in the ledger
-- from the bill that bought it.
--
-- ── Payroll ────────────────────────────────────────────────────────────────
--
-- Salary structures existed (0053); nothing turned them into a journal, so
-- salary was a bank payment to 5500 and PF, ESI, TDS and professional tax —
-- money the dealer owes the government from the day the salary is earned —
-- appeared nowhere. A payroll run takes the month's structures, is reviewed as
-- a draft (TDS and other deductions are entered then), posts
--
--     Salaries (gross) + Employer PF & ESI      Dr
--       Salaries Payable (net, per employee)      Cr
--       PF / ESI / TDS / PT Payable               Cr
--       Other Receivables (advance recovered)     Cr
--
-- and is paid from a bank account in one journal that also writes the bank
-- book. The statutory payables are then paid like any other liability.
--
-- ── Loans ──────────────────────────────────────────────────────────────────
--
-- A loan is a liability account and two kinds of money movement: the amount
-- received, and repayments that split into principal (reducing the liability)
-- and interest (an expense). Recording a repayment as one figure against the
-- loan understates the liability's fall and hides the interest cost; the
-- checklist asks for exactly this split. loan_schedule() gives the reducing-
-- balance EMI plan to compare against.
--
-- Rollback: drop the tables and functions created here; restore
--           public.control_account_tieout from 0077 and app.seed_chart_of_accounts
--           by renaming the _0076 function back.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Accounts
-- -----------------------------------------------------------------------------
create or replace function app.seed_payroll_asset_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
declare
  v_added integer := 0;
  a       record;
begin
  for a in
    select * from (values
      ('2710', 'Salaries Payable',          'LIABILITY', '2000'),
      ('2720', 'PF Payable',                'LIABILITY', '2000'),
      ('2730', 'ESI Payable',               'LIABILITY', '2000'),
      ('2740', 'TDS Payable',               'LIABILITY', '2000'),
      ('2750', 'Professional Tax Payable',  'LIABILITY', '2000'),
      ('4810', 'Gain on Sale of Assets',    'INCOME',    '4000'),
      ('5510', 'Employer PF & ESI',         'EXPENSE',   '5000'),
      ('5980', 'Loss on Sale of Assets',    'EXPENSE',   '5000')
    ) as t(code, name, account_type, parent_code)
  loop
    insert into public.chart_of_accounts
      (dealer_id, code, name, account_type, normal_balance, is_group, parent_id, is_system, is_branch_scoped)
    select p_dealer_id, a.code, a.name, a.account_type,
           case when a.account_type in ('ASSET', 'EXPENSE') then 'DEBIT' else 'CREDIT' end,
           false, p.id, true, false
      from public.chart_of_accounts p
     where p.dealer_id = p_dealer_id and p.code = a.parent_code and p.is_group
    on conflict on constraint coa_dealer_code_key do nothing;
    if found then v_added := v_added + 1; end if;
  end loop;
  return v_added;
end;
$$;

do $$
declare d record;
begin
  for d in select id from public.dealers loop
    perform app.seed_payroll_asset_accounts(d.id);
  end loop;
end $$;

alter function app.seed_chart_of_accounts(uuid) rename to seed_chart_of_accounts_0076;

create or replace function app.seed_chart_of_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
begin
  return app.seed_chart_of_accounts_0076(p_dealer_id) + app.seed_payroll_asset_accounts(p_dealer_id);
end;
$$;

insert into public.permissions (code, module, description, is_sensitive) values
  ('assets.view',     'accounting', 'View the fixed asset register', false),
  ('assets.manage',   'accounting', 'Register, depreciate and dispose of fixed assets', false),
  ('loans.view',      'accounting', 'View loans and their statements', false),
  ('loans.manage',    'accounting', 'Record loans, disbursements and repayments', false),
  ('hr.payroll.run',  'hr',         'Prepare, post and pay monthly payroll', true)
on conflict (code) do update set module = excluded.module, description = excluded.description,
                                 is_sensitive = excluded.is_sensitive;

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join (values ('assets.view'), ('assets.manage'), ('loans.view'), ('loans.manage')) as p(code)
 where r.is_system and r.code in ('DEALER_OWNER', 'ACCOUNTS')
on conflict do nothing;

insert into public.role_permissions (role_id, permission_code)
select r.id, 'hr.payroll.run' from public.roles r
 where r.is_system and r.code = 'DEALER_OWNER'
on conflict do nothing;

-- A cash or bank ledger line is always accompanied by its book row. These
-- helpers write the bank-book row for a journal this migration's functions post.
create or replace function app.bank_book_row(
  p_bank_account_id uuid, p_date date, p_direction text, p_amount numeric,
  p_particular text, p_reference_type text, p_reference_id uuid, p_journal_entry_id uuid,
  p_idempotency_key text default null
)
returns void
language sql
as $$
  insert into public.bank_transactions
    (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
     reference_type, reference_id, journal_entry_id, idempotency_key, created_by)
  select b.dealer_id, b.id, p_date, p_direction, p_amount, p_particular,
         p_reference_type, p_reference_id, p_journal_entry_id, p_idempotency_key, auth.uid()
    from public.bank_accounts b where b.id = p_bank_account_id;
$$;

-- =============================================================================
-- Fixed assets
-- =============================================================================
create table public.fixed_assets (
  id                     uuid primary key default gen_random_uuid(),
  dealer_id              uuid not null references public.dealers (id) on delete restrict,
  branch_id              uuid not null,
  asset_code             text not null,
  name                   text not null,
  category               text,
  asset_account_id       uuid not null,
  accumulated_account_id uuid not null,
  expense_account_id     uuid not null,
  purchase_bill_line_id  uuid,
  acquired_on            date not null,
  depreciation_start     date not null,
  cost                   numeric(18, 4) not null,
  salvage_value          numeric(18, 4) not null default 0,
  method                 text not null,
  useful_life_months     integer,
  wdv_rate               numeric(6, 3),
  status                 text not null default 'ACTIVE',
  disposed_on            date,
  disposal_value         numeric(18, 4),
  disposal_journal_id    uuid,
  created_at             timestamptz not null default now(),
  created_by             uuid,

  constraint fixed_assets_code_key unique (dealer_id, asset_code),
  constraint fixed_assets_id_dealer_key unique (id, dealer_id),
  constraint fixed_assets_branch_tenant_fkey foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint fixed_assets_asset_acc_fkey foreign key (asset_account_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint fixed_assets_accum_acc_fkey foreign key (accumulated_account_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint fixed_assets_expense_acc_fkey foreign key (expense_account_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint fixed_assets_bill_line_key unique (purchase_bill_line_id),
  constraint fixed_assets_amounts_check check (cost > 0 and salvage_value >= 0 and salvage_value < cost),
  constraint fixed_assets_method_check check (
    (method = 'SLM' and useful_life_months between 1 and 1200 and wdv_rate is null)
    or (method = 'WDV' and wdv_rate > 0 and wdv_rate <= 100 and useful_life_months is null)
  ),
  constraint fixed_assets_status_check check (status in ('ACTIVE', 'DISPOSED')),
  constraint fixed_assets_disposal_check check (
    status = 'ACTIVE' or (disposed_on is not null and disposal_journal_id is not null)
  )
);

create table public.fixed_asset_depreciation (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null,
  asset_id         uuid not null,
  period           date not null,
  amount           numeric(18, 4) not null,
  journal_entry_id uuid not null,
  created_at       timestamptz not null default now(),

  -- The rule that makes a re-run harmless: one charge per asset per month.
  constraint fad_asset_period_key unique (asset_id, period),
  constraint fad_asset_fkey foreign key (asset_id, dealer_id) references public.fixed_assets (id, dealer_id),
  constraint fad_period_check check (extract(day from period) = 1),
  constraint fad_amount_check check (amount > 0)
);

create index fixed_assets_dealer_idx on public.fixed_assets (dealer_id, status);

create trigger fixed_assets_audit after insert or update on public.fixed_assets
  for each row execute function app.audit_trigger();

alter table public.fixed_assets enable row level security;
alter table public.fixed_asset_depreciation enable row level security;

create policy fixed_assets_select on public.fixed_assets for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('assets.view')));
create policy fixed_assets_write on public.fixed_assets for all to authenticated
  using (dealer_id = app.current_dealer_id() and app.has_permission('assets.manage'))
  with check (dealer_id = app.current_dealer_id() and app.has_permission('assets.manage'));
create policy fad_select on public.fixed_asset_depreciation for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('assets.view')));
create policy fad_insert on public.fixed_asset_depreciation for insert to authenticated
  with check (dealer_id = app.current_dealer_id() and app.has_permission('assets.manage'));

-- Accumulated depreciation of one asset, to a date.
create or replace function app.asset_accumulated(p_asset_id uuid, p_as_on date default null)
returns numeric
language sql
stable
as $$
  select coalesce(sum(d.amount), 0) from public.fixed_asset_depreciation d
   where d.asset_id = p_asset_id
     and (p_as_on is null or d.period <= p_as_on);
$$;

create or replace function public.register_fixed_asset(
  p_name               text,
  p_asset_account_id   uuid,
  p_acquired_on        date,
  p_cost               numeric,
  p_method             text default 'SLM',
  p_useful_life_months integer default null,
  p_wdv_rate           numeric default null,
  p_salvage_value      numeric default 0,
  p_category           text default null,
  p_branch_id          uuid default null,
  p_purchase_bill_line_id uuid default null
)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_acc    public.chart_of_accounts;
  v_line   record;
  v_code   text;
  v_id     uuid;
  v_branch uuid;
begin
  if v_dealer is null or not app.has_permission('assets.manage') then
    raise exception 'You may not register fixed assets.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(length(btrim(p_name)), 0) < 2 then
    raise exception 'Name the asset.' using errcode = 'check_violation';
  end if;

  select * into v_acc from public.chart_of_accounts where id = p_asset_account_id and dealer_id = v_dealer;
  if v_acc.id is null or v_acc.account_type <> 'ASSET' or v_acc.is_group then
    raise exception 'A fixed asset sits on a postable asset account (e.g. 1951).' using errcode = 'check_violation';
  end if;
  if app.is_money_ledger(v_dealer, p_asset_account_id) or v_acc.code in ('1959') then
    raise exception 'Account % % cannot hold a fixed asset.', v_acc.code, v_acc.name using errcode = 'check_violation';
  end if;

  if p_purchase_bill_line_id is not null then
    select l.id, l.account_id, l.taxable_value, l.itc_eligible, l.cgst_amount + l.sgst_amount + l.igst_amount as tax,
           b.status, b.branch_id, b.bill_date
      into v_line
      from public.purchase_bill_lines l join public.purchase_bills b on b.id = l.purchase_bill_id
     where l.id = p_purchase_bill_line_id and l.dealer_id = v_dealer;
    if v_line.id is null or v_line.status <> 'POSTED' or v_line.account_id <> p_asset_account_id then
      raise exception 'That bill line is not a posted purchase charged to this asset account.' using errcode = 'check_violation';
    end if;
  end if;

  v_branch := coalesce(p_branch_id, v_line.branch_id,
                       (select id from public.branches where dealer_id = v_dealer order by code limit 1));
  v_code := 'FA-' || lpad((select count(*) + 1 from public.fixed_assets where dealer_id = v_dealer)::text, 5, '0');

  insert into public.fixed_assets
    (dealer_id, branch_id, asset_code, name, category, asset_account_id, accumulated_account_id,
     expense_account_id, purchase_bill_line_id, acquired_on, depreciation_start, cost, salvage_value,
     method, useful_life_months, wdv_rate, created_by)
  values
    (v_dealer, v_branch, v_code, btrim(p_name), nullif(btrim(p_category), ''), p_asset_account_id,
     (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '1959'),
     (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '5950'),
     p_purchase_bill_line_id, p_acquired_on,
     -- Depreciation starts the month the asset is acquired.
     date_trunc('month', p_acquired_on)::date,
     coalesce(p_cost, v_line.taxable_value + case when v_line.itc_eligible then 0 else v_line.tax end),
     coalesce(p_salvage_value, 0), upper(p_method),
     case when upper(p_method) = 'SLM' then p_useful_life_months end,
     case when upper(p_method) = 'WDV' then p_wdv_rate end,
     auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.register_fixed_asset(text, uuid, date, numeric, text, integer, numeric, numeric, text, uuid, uuid) is
  'Adds an asset to the register (checklist §09). Posts nothing: its cost is '
  'already in the ledger from the bill that bought it.';

create or replace function public.run_depreciation(p_month date)
returns table (assets integer, total numeric, journals integer)
language plpgsql
as $$
declare
  v_dealer  uuid := app.current_dealer_id();
  v_period  date := date_trunc('month', p_month)::date;
  v_end     date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  v_branch  record;
  v_asset   record;
  v_amount  numeric;
  v_nbv     numeric;
  v_lines   jsonb;
  v_charges jsonb;
  v_entry   uuid;
  v_c       jsonb;
begin
  if v_dealer is null or not app.has_permission('assets.manage') then
    raise exception 'You may not run depreciation.' using errcode = 'insufficient_privilege';
  end if;
  if v_period > current_date then
    raise exception 'Depreciation for % cannot be run before the month begins.', to_char(v_period, 'Mon YYYY')
      using errcode = 'check_violation';
  end if;

  assets := 0; total := 0; journals := 0;

  for v_branch in select distinct branch_id from public.fixed_assets
                   where dealer_id = v_dealer and status = 'ACTIVE' loop
    v_lines := '[]'::jsonb;
    v_charges := '[]'::jsonb;

    for v_asset in
      select a.* from public.fixed_assets a
       where a.dealer_id = v_dealer and a.branch_id = v_branch.branch_id and a.status = 'ACTIVE'
         and a.depreciation_start <= v_period
         -- Never twice, and never behind a month already charged.
         and not exists (select 1 from public.fixed_asset_depreciation d
                          where d.asset_id = a.id and d.period >= v_period)
       order by a.asset_code
    loop
      v_nbv := v_asset.cost - app.asset_accumulated(v_asset.id);
      v_amount := case v_asset.method
                    when 'SLM' then round((v_asset.cost - v_asset.salvage_value) / v_asset.useful_life_months, 2)
                    else round(v_nbv * v_asset.wdv_rate / 100 / 12, 2)
                  end;
      v_amount := least(v_amount, v_nbv - v_asset.salvage_value);
      continue when v_amount <= 0;

      v_lines := v_lines
        || jsonb_build_object('account_id', v_asset.expense_account_id, 'debit', v_amount, 'credit', 0,
                              'narration', v_asset.asset_code || ' ' || v_asset.name)
        || jsonb_build_object('account_id', v_asset.accumulated_account_id, 'debit', 0, 'credit', v_amount,
                              'narration', v_asset.asset_code || ' ' || v_asset.name);
      v_charges := v_charges || jsonb_build_object('asset_id', v_asset.id, 'amount', v_amount);
      assets := assets + 1;
      total := total + v_amount;
    end loop;

    continue when jsonb_array_length(v_lines) = 0;

    v_entry := app.post_journal(
      v_dealer, v_branch.branch_id, least(v_end, current_date), 'EXPENSE',
      'Depreciation for ' || to_char(v_period, 'Mon YYYY'), v_lines,
      'DEPRECIATION', null, null);
    journals := journals + 1;

    for v_c in select * from jsonb_array_elements(v_charges) loop
      insert into public.fixed_asset_depreciation (dealer_id, asset_id, period, amount, journal_entry_id)
      values (v_dealer, (v_c ->> 'asset_id')::uuid, v_period, (v_c ->> 'amount')::numeric, v_entry);
    end loop;
  end loop;

  return next;
end;
$$;

comment on function public.run_depreciation(date) is
  'Posts one month''s depreciation for every active asset, one journal per branch '
  '(checklist §02). At most once per asset per month; a re-run charges only what '
  'was not charged.';

create or replace function public.dispose_fixed_asset(
  p_asset_id uuid,
  p_date     date,
  p_proceeds numeric,
  p_reason   text
)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_asset  public.fixed_assets;
  v_acc    numeric;
  v_nbv    numeric;
  v_gain   numeric;
  v_lines  jsonb := '[]'::jsonb;
  v_entry  uuid;
begin
  if v_dealer is null or not app.has_permission('assets.manage') then
    raise exception 'You may not dispose of fixed assets.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(length(btrim(p_reason)), 0) < 3 then
    raise exception 'Say why the asset is leaving the books.' using errcode = 'check_violation';
  end if;
  if coalesce(p_proceeds, 0) < 0 then
    raise exception 'Proceeds cannot be negative.' using errcode = 'check_violation';
  end if;

  select * into v_asset from public.fixed_assets where id = p_asset_id and dealer_id = v_dealer for update;
  if v_asset.id is null then
    raise exception 'Asset not found.' using errcode = 'no_data_found';
  end if;
  if v_asset.status <> 'ACTIVE' then
    raise exception 'Asset % is already disposed of.', v_asset.asset_code using errcode = 'check_violation';
  end if;

  v_acc  := app.asset_accumulated(p_asset_id);
  v_nbv  := v_asset.cost - v_acc;
  v_gain := coalesce(p_proceeds, 0) - v_nbv;

  if v_acc > 0 then
    v_lines := v_lines || jsonb_build_object('account_id', v_asset.accumulated_account_id, 'debit', v_acc, 'credit', 0,
                                             'narration', 'Depreciation written back');
  end if;
  if coalesce(p_proceeds, 0) > 0 then
    v_lines := v_lines || jsonb_build_object('account_id',
      (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '1800'),
      'debit', p_proceeds, 'credit', 0, 'narration', 'Sale proceeds receivable');
  end if;
  if v_gain < 0 then
    v_lines := v_lines || jsonb_build_object('account_id',
      (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '5980'),
      'debit', -v_gain, 'credit', 0, 'narration', 'Loss on disposal');
  end if;
  v_lines := v_lines || jsonb_build_object('account_id', v_asset.asset_account_id, 'debit', 0, 'credit', v_asset.cost,
                                           'narration', v_asset.asset_code || ' at cost');
  if v_gain > 0 then
    v_lines := v_lines || jsonb_build_object('account_id',
      (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '4810'),
      'debit', 0, 'credit', v_gain, 'narration', 'Gain on disposal');
  end if;

  v_entry := app.post_journal(v_dealer, v_asset.branch_id, p_date, 'EXPENSE',
    'Disposal of ' || v_asset.asset_code || ' ' || v_asset.name || ' — ' || btrim(p_reason),
    v_lines, 'ASSET_DISPOSAL', p_asset_id, 'asset-disposal:' || p_asset_id::text);

  update public.fixed_assets
     set status = 'DISPOSED', disposed_on = p_date, disposal_value = coalesce(p_proceeds, 0),
         disposal_journal_id = v_entry
   where id = p_asset_id;

  return v_entry;
end;
$$;

create or replace function public.fixed_asset_register(p_as_on date default current_date)
returns table (
  asset_id uuid, asset_code text, name text, category text, branch_name text,
  account_code text, acquired_on date, method text, cost numeric(18, 4),
  accumulated numeric(18, 4), net_book_value numeric(18, 4), status text,
  last_period date, disposed_on date
)
language sql
stable
as $$
  select a.id, a.asset_code, a.name, a.category, b.name, c.code, a.acquired_on, a.method,
         a.cost, app.asset_accumulated(a.id, p_as_on),
         case when a.status = 'DISPOSED' and a.disposed_on <= p_as_on then 0
              else a.cost - app.asset_accumulated(a.id, p_as_on) end,
         case when a.status = 'DISPOSED' and a.disposed_on <= p_as_on then 'DISPOSED' else 'ACTIVE' end,
         (select max(d.period) from public.fixed_asset_depreciation d where d.asset_id = a.id and d.period <= p_as_on),
         a.disposed_on
    from public.fixed_assets a
    join public.branches b on b.id = a.branch_id
    join public.chart_of_accounts c on c.id = a.asset_account_id
   where a.acquired_on <= p_as_on
   order by a.asset_code;
$$;

-- =============================================================================
-- Payroll
-- =============================================================================
create table public.payroll_runs (
  id                 uuid primary key default gen_random_uuid(),
  dealer_id          uuid not null references public.dealers (id) on delete restrict,
  branch_id          uuid not null,
  period             date not null,
  status             text not null default 'DRAFT',
  journal_entry_id   uuid,
  payment_journal_id uuid,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  posted_at          timestamptz,
  posted_by          uuid,
  paid_at            timestamptz,

  constraint payroll_runs_id_dealer_key unique (id, dealer_id),
  constraint payroll_runs_period_key unique (dealer_id, branch_id, period),
  constraint payroll_runs_branch_tenant_fkey foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint payroll_runs_status_check check (status in ('DRAFT', 'POSTED', 'PAID')),
  constraint payroll_runs_period_check check (extract(day from period) = 1)
);

create table public.payroll_lines (
  id               uuid primary key default gen_random_uuid(),
  run_id           uuid not null,
  dealer_id        uuid not null,
  employee_id      uuid not null,
  gross            numeric(14, 2) not null,
  pf_employee      numeric(14, 2) not null default 0,
  esi_employee     numeric(14, 2) not null default 0,
  professional_tax numeric(14, 2) not null default 0,
  tds              numeric(14, 2) not null default 0,
  other_deduction  numeric(14, 2) not null default 0,
  pf_employer      numeric(14, 2) not null default 0,
  esi_employer     numeric(14, 2) not null default 0,
  net_pay          numeric(14, 2) generated always as (
    gross - pf_employee - esi_employee - professional_tax - tds - other_deduction
  ) stored,

  constraint payroll_lines_run_employee_key unique (run_id, employee_id),
  constraint payroll_lines_run_fkey foreign key (run_id, dealer_id) references public.payroll_runs (id, dealer_id) on delete cascade,
  constraint payroll_lines_employee_fkey foreign key (employee_id, dealer_id) references public.employees (id, dealer_id),
  constraint payroll_lines_amounts_check check (
    gross >= 0 and pf_employee >= 0 and esi_employee >= 0 and professional_tax >= 0
    and tds >= 0 and other_deduction >= 0 and pf_employer >= 0 and esi_employer >= 0
  ),
  constraint payroll_lines_net_check check (
    gross - pf_employee - esi_employee - professional_tax - tds - other_deduction >= 0
  )
);

-- A run's lines move only while it is a draft.
create or replace function app.payroll_lines_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_status text;
begin
  select status into v_status from public.payroll_runs where id = coalesce(new.run_id, old.run_id);
  if v_status is not null and v_status <> 'DRAFT' then
    raise exception 'This payroll is % and cannot be changed.', lower(v_status) using errcode = 'insufficient_privilege';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger payroll_lines_guard before insert or update or delete on public.payroll_lines
  for each row execute function app.payroll_lines_guard();
create trigger payroll_runs_audit after insert or update on public.payroll_runs
  for each row execute function app.audit_trigger();

alter table public.payroll_runs enable row level security;
alter table public.payroll_lines enable row level security;
create policy payroll_runs_all on public.payroll_runs for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('hr.payroll.run')))
  with check (dealer_id = app.current_dealer_id() and app.has_permission('hr.payroll.run'));
create policy payroll_lines_all on public.payroll_lines for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('hr.payroll.run')))
  with check (dealer_id = app.current_dealer_id() and app.has_permission('hr.payroll.run'));

create or replace function public.create_payroll_run(p_period date, p_branch_id uuid)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_period date := date_trunc('month', p_period)::date;
  v_end    date := (date_trunc('month', p_period) + interval '1 month - 1 day')::date;
  v_run    uuid;
begin
  if v_dealer is null or not app.has_permission('hr.payroll.run') then
    raise exception 'You may not run payroll.' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.branches where id = p_branch_id and dealer_id = v_dealer) then
    raise exception 'That branch does not belong to this dealer.' using errcode = 'insufficient_privilege';
  end if;

  insert into public.payroll_runs (dealer_id, branch_id, period, created_by)
  values (v_dealer, p_branch_id, v_period, auth.uid())
  returning id into v_run;

  -- Everyone at the branch with a salary structure in force during the month.
  insert into public.payroll_lines
    (run_id, dealer_id, employee_id, gross, pf_employee, esi_employee, professional_tax,
     other_deduction, pf_employer, esi_employer)
  select v_run, v_dealer, e.id, s.gross_earnings, s.pf_employee, s.esi_employee, s.professional_tax,
         s.other_deduction, s.pf_employer, s.esi_employer
    from public.employees e
    join lateral (
      select * from public.employee_salary_structures ss
       where ss.employee_id = e.id and ss.effective_from <= v_end
         and (ss.effective_to is null or ss.effective_to >= v_period)
       order by ss.effective_from desc limit 1
    ) s on true
   where e.dealer_id = v_dealer and e.branch_id = p_branch_id and e.status in ('ACTIVE', 'ON_LEAVE');

  return v_run;
end;
$$;

create or replace function public.post_payroll_run(p_run_id uuid)
returns uuid
language plpgsql
as $$
declare
  v_run   public.payroll_runs;
  v_d     uuid;
  v_lines jsonb := '[]'::jsonb;
  t       record;
  e       record;
  v_entry uuid;
  acc     record;
begin
  select * into v_run from public.payroll_runs where id = p_run_id and dealer_id = app.current_dealer_id() for update;
  if v_run.id is null then
    raise exception 'Payroll run not found.' using errcode = 'no_data_found';
  end if;
  if not app.has_permission('hr.payroll.run') then
    raise exception 'You may not post payroll.' using errcode = 'insufficient_privilege';
  end if;
  if v_run.status <> 'DRAFT' then
    return v_run.journal_entry_id;
  end if;
  v_d := v_run.dealer_id;

  select (select id from public.chart_of_accounts where dealer_id = v_d and code = '5500') as salaries,
         (select id from public.chart_of_accounts where dealer_id = v_d and code = '5510') as employer,
         (select id from public.chart_of_accounts where dealer_id = v_d and code = '2710') as payable,
         (select id from public.chart_of_accounts where dealer_id = v_d and code = '2720') as pf,
         (select id from public.chart_of_accounts where dealer_id = v_d and code = '2730') as esi,
         (select id from public.chart_of_accounts where dealer_id = v_d and code = '2740') as tds,
         (select id from public.chart_of_accounts where dealer_id = v_d and code = '2750') as pt,
         (select id from public.chart_of_accounts where dealer_id = v_d and code = '1800') as advances
    into acc;

  select coalesce(sum(gross), 0) as gross, coalesce(sum(pf_employer + esi_employer), 0) as employer,
         coalesce(sum(pf_employee + pf_employer), 0) as pf, coalesce(sum(esi_employee + esi_employer), 0) as esi,
         coalesce(sum(tds), 0) as tds, coalesce(sum(professional_tax), 0) as pt, count(*) as n
    into t from public.payroll_lines where run_id = p_run_id;
  if t.n = 0 or t.gross = 0 then
    raise exception 'This payroll has no salary to post.' using errcode = 'check_violation';
  end if;

  v_lines := v_lines || jsonb_build_object('account_id', acc.salaries, 'debit', t.gross, 'credit', 0,
                                           'narration', 'Gross salaries');
  if t.employer > 0 then
    v_lines := v_lines || jsonb_build_object('account_id', acc.employer, 'debit', t.employer, 'credit', 0,
                                             'narration', 'Employer PF and ESI');
  end if;
  -- Net pay owed, per employee, so each one's balance is on their own ledger.
  for e in select l.employee_id, l.net_pay, l.other_deduction, em.name from public.payroll_lines l
            join public.employees em on em.id = l.employee_id
           where l.run_id = p_run_id order by em.name loop
    if e.net_pay > 0 then
      v_lines := v_lines || jsonb_build_object('account_id', acc.payable, 'debit', 0, 'credit', e.net_pay,
        'narration', 'Net pay ' || e.name, 'party_type', 'EMPLOYEE', 'party_id', e.employee_id);
    end if;
    if e.other_deduction > 0 then
      v_lines := v_lines || jsonb_build_object('account_id', acc.advances, 'debit', 0, 'credit', e.other_deduction,
        'narration', 'Recovered from ' || e.name, 'party_type', 'EMPLOYEE', 'party_id', e.employee_id);
    end if;
  end loop;
  if t.pf > 0 then v_lines := v_lines || jsonb_build_object('account_id', acc.pf, 'debit', 0, 'credit', t.pf, 'narration', 'PF'); end if;
  if t.esi > 0 then v_lines := v_lines || jsonb_build_object('account_id', acc.esi, 'debit', 0, 'credit', t.esi, 'narration', 'ESI'); end if;
  if t.tds > 0 then v_lines := v_lines || jsonb_build_object('account_id', acc.tds, 'debit', 0, 'credit', t.tds, 'narration', 'TDS on salary'); end if;
  if t.pt > 0 then v_lines := v_lines || jsonb_build_object('account_id', acc.pt, 'debit', 0, 'credit', t.pt, 'narration', 'Professional tax'); end if;

  v_entry := app.post_journal(v_d, v_run.branch_id,
    least((v_run.period + interval '1 month - 1 day')::date, current_date), 'EXPENSE',
    'Payroll for ' || to_char(v_run.period, 'Mon YYYY'), v_lines, 'PAYROLL', p_run_id, 'payroll:' || p_run_id::text);

  update public.payroll_runs set status = 'POSTED', journal_entry_id = v_entry, posted_at = now(), posted_by = auth.uid()
   where id = p_run_id;
  return v_entry;
end;
$$;

create or replace function public.pay_payroll_run(p_run_id uuid, p_bank_account_id uuid, p_date date default current_date)
returns uuid
language plpgsql
as $$
declare
  v_run   public.payroll_runs;
  v_bank  public.bank_accounts;
  v_lines jsonb := '[]'::jsonb;
  v_total numeric := 0;
  e       record;
  v_entry uuid;
  v_payable uuid;
begin
  select * into v_run from public.payroll_runs where id = p_run_id and dealer_id = app.current_dealer_id() for update;
  if v_run.id is null then
    raise exception 'Payroll run not found.' using errcode = 'no_data_found';
  end if;
  if not app.has_permission('hr.payroll.run') then
    raise exception 'You may not pay payroll.' using errcode = 'insufficient_privilege';
  end if;
  if v_run.status = 'PAID' then
    return v_run.payment_journal_id;
  end if;
  if v_run.status <> 'POSTED' then
    raise exception 'Post the payroll before paying it.' using errcode = 'check_violation';
  end if;
  select * into v_bank from public.bank_accounts where id = p_bank_account_id and dealer_id = v_run.dealer_id and status = 'ACTIVE';
  if v_bank.id is null then
    raise exception 'Choose an active bank account.' using errcode = 'no_data_found';
  end if;

  select id into v_payable from public.chart_of_accounts where dealer_id = v_run.dealer_id and code = '2710';
  for e in select l.employee_id, l.net_pay, em.name from public.payroll_lines l
            join public.employees em on em.id = l.employee_id
           where l.run_id = p_run_id and l.net_pay > 0 order by em.name loop
    v_lines := v_lines || jsonb_build_object('account_id', v_payable, 'debit', e.net_pay, 'credit', 0,
      'narration', 'Salary paid ' || e.name, 'party_type', 'EMPLOYEE', 'party_id', e.employee_id);
    v_total := v_total + e.net_pay;
  end loop;
  v_lines := v_lines || jsonb_build_object('account_id', v_bank.ledger_account_id, 'debit', 0, 'credit', v_total,
                                           'narration', 'Salaries ' || to_char(v_run.period, 'Mon YYYY'));

  v_entry := app.post_journal(v_run.dealer_id, v_run.branch_id, p_date, 'BANK',
    'Salary payment for ' || to_char(v_run.period, 'Mon YYYY'), v_lines,
    'PAYROLL_PAYMENT', p_run_id, 'payroll-pay:' || p_run_id::text);

  perform app.bank_book_row(p_bank_account_id, p_date, 'PAYMENT', v_total,
    'Salaries ' || to_char(v_run.period, 'Mon YYYY'), 'PAYROLL', p_run_id, v_entry);

  update public.payroll_runs set status = 'PAID', payment_journal_id = v_entry, paid_at = now() where id = p_run_id;
  return v_entry;
end;
$$;

-- =============================================================================
-- Loans
-- =============================================================================
create table public.loans (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null references public.dealers (id) on delete restrict,
  branch_id      uuid not null,
  loan_number    text not null,
  lender         text not null,
  account_id     uuid not null,
  principal      numeric(18, 4) not null,
  interest_rate  numeric(6, 3) not null,
  start_date     date not null,
  tenure_months  integer not null,
  status         text not null default 'ACTIVE',
  notes          text,
  created_at     timestamptz not null default now(),
  created_by     uuid,

  constraint loans_number_key unique (dealer_id, loan_number),
  constraint loans_id_dealer_key unique (id, dealer_id),
  constraint loans_branch_tenant_fkey foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint loans_account_fkey foreign key (account_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint loans_amounts_check check (principal > 0 and interest_rate >= 0 and tenure_months between 1 and 600),
  constraint loans_status_check check (status in ('ACTIVE', 'CLOSED'))
);

create table public.loan_transactions (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null,
  loan_id          uuid not null,
  txn_date         date not null,
  kind             text not null,
  principal        numeric(18, 4) not null default 0,
  interest         numeric(18, 4) not null default 0,
  bank_account_id  uuid not null,
  journal_entry_id uuid not null,
  idempotency_key  text,
  created_at       timestamptz not null default now(),
  created_by       uuid,

  constraint loan_txn_loan_fkey foreign key (loan_id, dealer_id) references public.loans (id, dealer_id),
  constraint loan_txn_kind_check check (kind in ('DISBURSEMENT', 'REPAYMENT')),
  constraint loan_txn_amounts_check check (principal >= 0 and interest >= 0 and principal + interest > 0),
  constraint loan_txn_disbursement_check check (kind <> 'DISBURSEMENT' or interest = 0)
);

create unique index loan_txn_idempotency_key on public.loan_transactions (dealer_id, idempotency_key)
  where idempotency_key is not null;

create trigger loans_audit after insert or update on public.loans for each row execute function app.audit_trigger();

alter table public.loans enable row level security;
alter table public.loan_transactions enable row level security;
create policy loans_select on public.loans for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('loans.view')));
create policy loans_write on public.loans for all to authenticated
  using (dealer_id = app.current_dealer_id() and app.has_permission('loans.manage'))
  with check (dealer_id = app.current_dealer_id() and app.has_permission('loans.manage'));
create policy loan_txn_select on public.loan_transactions for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('loans.view')));
create policy loan_txn_insert on public.loan_transactions for insert to authenticated
  with check (dealer_id = app.current_dealer_id() and app.has_permission('loans.manage'));

create or replace function public.create_loan(
  p_lender text, p_principal numeric, p_interest_rate numeric, p_start_date date,
  p_tenure_months integer, p_account_id uuid default null, p_branch_id uuid default null, p_notes text default null
)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_acc    public.chart_of_accounts;
  v_id     uuid;
begin
  if v_dealer is null or not app.has_permission('loans.manage') then
    raise exception 'You may not record loans.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(length(btrim(p_lender)), 0) < 2 then
    raise exception 'Name the lender.' using errcode = 'check_violation';
  end if;
  select * into v_acc from public.chart_of_accounts
   where dealer_id = v_dealer and id = coalesce(p_account_id,
     (select id from public.chart_of_accounts where dealer_id = v_dealer and code = '2800'));
  if v_acc.id is null or v_acc.account_type <> 'LIABILITY' or v_acc.is_group then
    raise exception 'A loan sits on a postable liability account (e.g. 2800 Loans).' using errcode = 'check_violation';
  end if;

  insert into public.loans (dealer_id, branch_id, loan_number, lender, account_id, principal, interest_rate,
                            start_date, tenure_months, notes, created_by)
  values (v_dealer,
          coalesce(p_branch_id, (select id from public.branches where dealer_id = v_dealer order by code limit 1)),
          'LN-' || lpad((select count(*) + 1 from public.loans where dealer_id = v_dealer)::text, 4, '0'),
          btrim(p_lender), v_acc.id, p_principal, p_interest_rate, p_start_date, p_tenure_months,
          nullif(btrim(p_notes), ''), auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.record_loan_transaction(
  p_loan_id         uuid,
  p_kind            text,
  p_bank_account_id uuid,
  p_date            date,
  p_principal       numeric,
  p_interest        numeric default 0,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_loan  public.loans;
  v_bank  public.bank_accounts;
  v_out   numeric;
  v_lines jsonb;
  v_entry uuid;
  v_existing uuid;
  v_total numeric := coalesce(p_principal, 0) + coalesce(p_interest, 0);
begin
  select * into v_loan from public.loans where id = p_loan_id and dealer_id = app.current_dealer_id() for update;
  if v_loan.id is null then
    raise exception 'Loan not found.' using errcode = 'no_data_found';
  end if;
  if not app.has_permission('loans.manage') then
    raise exception 'You may not record loan transactions.' using errcode = 'insufficient_privilege';
  end if;
  if p_idempotency_key is not null then
    select journal_entry_id into v_existing from public.loan_transactions
     where dealer_id = v_loan.dealer_id and idempotency_key = p_idempotency_key;
    if v_existing is not null then return v_existing; end if;
  end if;
  if p_kind not in ('DISBURSEMENT', 'REPAYMENT') then
    raise exception 'A loan transaction is a DISBURSEMENT or a REPAYMENT.' using errcode = 'check_violation';
  end if;
  if coalesce(p_principal, 0) < 0 or coalesce(p_interest, 0) < 0 or v_total <= 0 then
    raise exception 'Enter an amount greater than zero.' using errcode = 'check_violation';
  end if;
  select * into v_bank from public.bank_accounts where id = p_bank_account_id and dealer_id = v_loan.dealer_id and status = 'ACTIVE';
  if v_bank.id is null then
    raise exception 'Choose an active bank account.' using errcode = 'no_data_found';
  end if;

  select coalesce(sum(case when kind = 'DISBURSEMENT' then principal else -principal end), 0) into v_out
    from public.loan_transactions where loan_id = p_loan_id;

  if p_kind = 'DISBURSEMENT' then
    if coalesce(p_interest, 0) <> 0 then
      raise exception 'A disbursement carries no interest.' using errcode = 'check_violation';
    end if;
    -- The sanction caps what is ever drawn, not what is outstanding: repaying an
    -- instalment does not free that amount to be drawn again.
    if (select coalesce(sum(principal), 0) from public.loan_transactions
         where loan_id = p_loan_id and kind = 'DISBURSEMENT') + p_principal > v_loan.principal then
      raise exception 'That would take % beyond its sanctioned %.', v_loan.loan_number, v_loan.principal
        using errcode = 'check_violation';
    end if;
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_bank.ledger_account_id, 'debit', p_principal, 'credit', 0, 'narration', 'Loan received'),
      jsonb_build_object('account_id', v_loan.account_id, 'debit', 0, 'credit', p_principal, 'narration', v_loan.loan_number || ' ' || v_loan.lender));
  else
    if coalesce(p_principal, 0) > v_out then
      raise exception 'Only % of principal is outstanding on %.', v_out, v_loan.loan_number using errcode = 'check_violation';
    end if;
    -- Principal reduces the liability; interest is a cost, never a repayment of principal.
    v_lines := '[]'::jsonb;
    if coalesce(p_principal, 0) > 0 then
      v_lines := v_lines || jsonb_build_object('account_id', v_loan.account_id, 'debit', p_principal, 'credit', 0,
                                               'narration', v_loan.loan_number || ' principal');
    end if;
    if coalesce(p_interest, 0) > 0 then
      v_lines := v_lines || jsonb_build_object('account_id',
        (select id from public.chart_of_accounts where dealer_id = v_loan.dealer_id and code = '5960'),
        'debit', p_interest, 'credit', 0, 'narration', v_loan.loan_number || ' interest');
    end if;
    v_lines := v_lines || jsonb_build_object('account_id', v_bank.ledger_account_id, 'debit', 0, 'credit', v_total,
                                             'narration', 'Loan instalment');
  end if;

  v_entry := app.post_journal(v_loan.dealer_id, v_loan.branch_id, p_date, 'BANK',
    initcap(lower(p_kind)) || ' — ' || v_loan.loan_number || ' ' || v_loan.lender, v_lines,
    'LOAN', p_loan_id, case when p_idempotency_key is null then null else 'loan:' || p_idempotency_key end);

  perform app.bank_book_row(p_bank_account_id, p_date,
    case when p_kind = 'DISBURSEMENT' then 'RECEIPT' else 'PAYMENT' end, v_total,
    v_loan.loan_number || ' ' || lower(p_kind), 'LOAN', p_loan_id, v_entry);

  insert into public.loan_transactions (dealer_id, loan_id, txn_date, kind, principal, interest,
                                        bank_account_id, journal_entry_id, idempotency_key, created_by)
  values (v_loan.dealer_id, p_loan_id, p_date, p_kind, coalesce(p_principal, 0), coalesce(p_interest, 0),
          p_bank_account_id, v_entry, p_idempotency_key, auth.uid());

  if p_kind = 'REPAYMENT' and v_out - coalesce(p_principal, 0) = 0 then
    update public.loans set status = 'CLOSED' where id = p_loan_id;
  end if;

  return v_entry;
end;
$$;

create or replace function public.loan_schedule(p_loan_id uuid)
returns table (instalment integer, due_date date, emi numeric(18, 2), principal numeric(18, 2),
               interest numeric(18, 2), balance numeric(18, 2))
language plpgsql
stable
as $$
declare
  v_loan public.loans;
  v_r    numeric;
  v_emi  numeric;
  v_bal  numeric;
  v_int  numeric;
  v_pr   numeric;
  i      integer;
begin
  select * into v_loan from public.loans where id = p_loan_id;
  if v_loan.id is null then return; end if;
  v_r := v_loan.interest_rate / 100 / 12;
  v_emi := case when v_r = 0 then v_loan.principal / v_loan.tenure_months
                else v_loan.principal * v_r * power(1 + v_r, v_loan.tenure_months)
                     / (power(1 + v_r, v_loan.tenure_months) - 1) end;
  v_bal := v_loan.principal;
  for i in 1 .. v_loan.tenure_months loop
    v_int := round(v_bal * v_r, 2);
    v_pr := case when i = v_loan.tenure_months then v_bal else round(v_emi - v_int, 2) end;
    v_bal := v_bal - v_pr;
    instalment := i; due_date := (v_loan.start_date + (i || ' month')::interval)::date;
    emi := round(v_pr + v_int, 2); principal := v_pr; interest := v_int; balance := round(v_bal, 2);
    return next;
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- The tie-out learns the new registers: fixed assets at cost, accumulated
-- depreciation, and loans outstanding — each only where the register is in use.
-- -----------------------------------------------------------------------------
create or replace function app.gl_balance(p_account_id uuid, p_as_on date)
returns numeric
language sql
stable
as $$
  select coalesce(sum(l.debit - l.credit), 0)
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.account_id = p_account_id and je.status in ('POSTED', 'REVERSED') and je.entry_date <= p_as_on;
$$;

create or replace function public.register_tieout(p_as_on date default current_date)
returns table (control text, account_code text, account_name text, ledger_balance numeric(18, 4),
               subledger_balance numeric(18, 4), difference numeric(18, 4), explanation text)
language sql
stable
as $$
  with fa as (
    select a.asset_account_id as account_id, sum(a.cost) as reg
      from public.fixed_assets a
     where a.acquired_on <= p_as_on and not (a.status = 'DISPOSED' and a.disposed_on <= p_as_on)
     group by a.asset_account_id
  ),
  acc as (
    select a.accumulated_account_id as account_id,
           -sum(app.asset_accumulated(a.id, p_as_on)) as reg
      from public.fixed_assets a
     where not (a.status = 'DISPOSED' and a.disposed_on <= p_as_on)
     group by a.accumulated_account_id
  ),
  ln as (
    select l.account_id,
           -coalesce(sum(case when t.kind = 'DISBURSEMENT' then t.principal else -t.principal end), 0) as reg
      from public.loans l
      left join public.loan_transactions t on t.loan_id = l.id and t.txn_date <= p_as_on
     group by l.account_id
  ),
  rows as (
    select 'FIXED_ASSETS'::text as control, account_id, reg from fa
    union all select 'ACCUMULATED_DEPRECIATION', account_id, reg from acc
    union all select 'LOANS', account_id, reg from ln
  )
  select r.control, c.code, c.name, app.gl_balance(r.account_id, p_as_on), r.reg,
         app.gl_balance(r.account_id, p_as_on) - r.reg,
         case when app.gl_balance(r.account_id, p_as_on) = r.reg then null
              else 'The register and the ledger disagree: an asset bought or depreciated outside the register, or a loan moved by hand' end
    from rows r join public.chart_of_accounts c on c.id = r.account_id
   order by 1, 2;
$$;

comment on function public.register_tieout(date) is
  'Fixed asset register, accumulated depreciation and loans against their '
  'ledger accounts. Shown beside control_account_tieout() on the tie-out page.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.fixed_assets, public.payroll_runs, public.payroll_lines, public.loans to authenticated';
    execute 'grant select, insert on public.fixed_asset_depreciation, public.loan_transactions to authenticated';
    execute 'grant delete on public.payroll_lines to authenticated';
  end if;
end $$;

insert into public.schema_migrations (version, name)
values ('0082', 'fixed_assets_payroll_loans') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0083_branch_transfers_damaged_consignment.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0083 — Branch transfers that move value, damaged stock, consignment stock
-- =============================================================================
-- Spec §28, §34, §35, §40. Audit checklist §06 (transfers; damaged /
-- consignment), §07 (document lifecycle: delivery challan).
--
-- ── Transfers moved quantity and not value ─────────────────────────────────
--
-- A stock or vehicle transfer moved the item between branches and wrote no
-- journal. 1500/1600/1700 are branch-scoped, so a branch's trial balance kept
-- the value of stock it had sent away and never showed stock it had received;
-- only the dealer total was right. And when the two branches hold different
-- GSTINs, a transfer is a supply under GST — a tax invoice with output tax at
-- one end and input tax at the other — which nothing recorded at all.
--
-- Every transfer now issues a transfer note (a delivery challan between
-- branches of one GSTIN, a tax invoice between two) and posts through a new
-- account, 1850 Inter-Branch Stock in Transit, so each branch balances on its
-- own:
--
--   sending branch    Stock in Transit  Dr  /  Inventory Cr  [/ Output GST Cr]
--   receiving branch  Inventory Dr  [/ Input GST Dr]  /  Stock in Transit Cr
--
-- Counted stock arrives at once, so both halves post together. A vehicle is on
-- the road between dispatch and receipt: the first half posts at dispatch, the
-- second at receipt, and 1850 holds the vehicle meanwhile — goods in transit,
-- where an auditor expects them. A cancelled dispatch is reversed. To do this in
-- one journal, post_journal now accepts a branch per line; account_balances()
-- and account_ledger() filter on the line's branch, which for every existing
-- line is the same as its header's.
--
-- ── Damaged and consignment stock ──────────────────────────────────────────
--
-- Two new lots beside LOCAL and COMPANY, neither of which the sale allocator
-- reads, so neither can be sold by accident:
--
--   DAMAGED      moved out of saleable stock at its cost, and written down to
--                what it will fetch; the write-down posts to 5970. It can then
--                be written off like any other adjustment.
--   CONSIGNMENT  held for a supplier and not owned: received and returned at nil
--                value, so it never enters the stock ledger's value or the GL.
--                To sell it, buy it in on a purchase bill.
--
-- Rollback: restore post_journal (0076), account_balances (0076),
--           account_ledger (0070), control_account_tieout (0077),
--           app.adjust_inventory_stock_core and transfer_inventory_stock (0079);
--           drop the note table, triggers and functions added here.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1850 Inter-Branch Stock in Transit
-- -----------------------------------------------------------------------------
create or replace function app.seed_transfer_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
begin
  insert into public.chart_of_accounts
    (dealer_id, code, name, account_type, normal_balance, is_group, parent_id, is_system, is_branch_scoped)
  select p_dealer_id, '1850', 'Inter-Branch Stock in Transit', 'ASSET', 'DEBIT', false, p.id, true, true
    from public.chart_of_accounts p
   where p.dealer_id = p_dealer_id and p.code = '1000' and p.is_group
  on conflict on constraint coa_dealer_code_key do nothing;
  return case when found then 1 else 0 end;
end;
$$;

do $$
declare d record;
begin
  for d in select id from public.dealers loop
    perform app.seed_transfer_accounts(d.id);
  end loop;
end $$;

alter function app.seed_chart_of_accounts(uuid) rename to seed_chart_of_accounts_0082;

create or replace function app.seed_chart_of_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
begin
  return app.seed_chart_of_accounts_0082(p_dealer_id) + app.seed_transfer_accounts(p_dealer_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- New lots
-- -----------------------------------------------------------------------------
alter table public.inventory_stock drop constraint inventory_stock_source_check;
alter table public.inventory_stock add constraint inventory_stock_source_check
  check (source in ('LOCAL', 'COMPANY', 'DAMAGED', 'CONSIGNMENT'));
alter table public.inventory_transactions drop constraint inventory_transactions_source_check;
alter table public.inventory_transactions add constraint inventory_transactions_source_check
  check (source in ('LOCAL', 'COMPANY', 'DAMAGED', 'CONSIGNMENT'));

-- -----------------------------------------------------------------------------
-- branch_transfer_notes — the challan or tax invoice behind every transfer
-- -----------------------------------------------------------------------------
create table public.branch_transfer_notes (
  id                 uuid primary key default gen_random_uuid(),
  dealer_id          uuid not null references public.dealers (id) on delete restrict,
  note_number        text not null,
  note_date          date not null default current_date,
  note_kind          text not null,
  from_branch_id     uuid not null,
  to_branch_id       uuid not null,
  from_gstin         text,
  to_gstin           text,
  item_id            uuid,
  vehicle_id         uuid,
  quantity           numeric(14, 3) not null,
  description        text not null,
  taxable_value      numeric(18, 4) not null,
  cgst_amount        numeric(18, 4) not null default 0,
  sgst_amount        numeric(18, 4) not null default 0,
  igst_amount        numeric(18, 4) not null default 0,
  journal_entry_id   uuid,
  receipt_journal_id uuid,
  created_at         timestamptz not null default now(),
  created_by         uuid,

  constraint btn_number_key unique (dealer_id, note_number),
  constraint btn_kind_check check (note_kind in ('DELIVERY_CHALLAN', 'TAX_INVOICE')),
  constraint btn_from_fkey foreign key (from_branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint btn_to_fkey foreign key (to_branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint btn_amounts_check check (taxable_value >= 0 and cgst_amount >= 0 and sgst_amount >= 0 and igst_amount >= 0),
  constraint btn_challan_untaxed_check check (
    note_kind = 'TAX_INVOICE' or (cgst_amount = 0 and sgst_amount = 0 and igst_amount = 0)
  )
);

create index btn_dealer_date_idx on public.branch_transfer_notes (dealer_id, note_date desc);

alter table public.branch_transfer_notes enable row level security;
create policy btn_select on public.branch_transfer_notes for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('inventory.view') or app.has_permission('gst.summary.view'))));
create policy btn_insert on public.branch_transfer_notes for insert to authenticated
  with check (dealer_id = app.current_dealer_id());
create policy btn_update on public.branch_transfer_notes for update to authenticated
  using (dealer_id = app.current_dealer_id()) with check (dealer_id = app.current_dealer_id());

create or replace function app.btn_append_only()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'A transfer note is a document and cannot be deleted.' using errcode = 'insufficient_privilege';
  end if;
  -- Only the receipt journal may be added later, once.
  if (to_jsonb(new) - 'receipt_journal_id') <> (to_jsonb(old) - 'receipt_journal_id')
     or old.receipt_journal_id is not null then
    raise exception 'A transfer note cannot be changed.' using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;

create trigger btn_append_only before update or delete on public.branch_transfer_notes
  for each row execute function app.btn_append_only();
create trigger btn_audit after insert on public.branch_transfer_notes
  for each row execute function app.audit_trigger();

-- -----------------------------------------------------------------------------
-- app.post_branch_transfer() — the note, and one or both halves of the journal
-- -----------------------------------------------------------------------------
-- p_mode: BOTH (counted stock, arrives at once), DISPATCH (vehicle leaves),
-- RECEIVE (vehicle arrives; p_note_id names the dispatch note).
create or replace function app.post_branch_transfer(
  p_dealer_id    uuid,
  p_from_branch  uuid,
  p_to_branch    uuid,
  p_inventory    uuid,
  p_value        numeric,
  p_tax_code     text,
  p_mode         text,
  p_item_id      uuid,
  p_vehicle_id   uuid,
  p_quantity     numeric,
  p_description  text,
  p_note_id      uuid
)
returns uuid
language plpgsql
as $$
declare
  v_note     public.branch_transfer_notes;
  v_from     public.branches;
  v_to       public.branches;
  v_taxable  boolean;
  v_inter    boolean;
  v_rate     record;
  v_cgst     numeric := 0;
  v_sgst     numeric := 0;
  v_igst     numeric := 0;
  v_transit  uuid;
  v_send     jsonb := '[]'::jsonb;
  v_recv     jsonb := '[]'::jsonb;
  v_year     text;
  v_gross    numeric;
  v_entry    uuid;
begin
  select id into v_transit from public.chart_of_accounts where dealer_id = p_dealer_id and code = '1850';
  if v_transit is null then
    raise exception 'The Inter-Branch Stock in Transit account (1850) is missing.' using errcode = 'no_data_found';
  end if;

  if p_mode = 'RECEIVE' then
    select * into v_note from public.branch_transfer_notes where id = p_note_id;
  else
    select * into v_from from public.branches where id = p_from_branch;
    select * into v_to from public.branches where id = p_to_branch;
    v_taxable := nullif(btrim(v_from.gstin), '') is not null and nullif(btrim(v_to.gstin), '') is not null
                 and v_from.gstin <> v_to.gstin;

    if v_taxable and p_tax_code is not null and p_value > 0 then
      select * into v_rate from public.resolve_tax_code(p_dealer_id, p_tax_code, current_date);
      v_inter := left(v_from.gstin, 2) <> left(v_to.gstin, 2);
      if v_inter then
        v_igst := round(p_value * coalesce(v_rate.igst_rate, v_rate.cgst_rate + v_rate.sgst_rate, 0) / 100, 2);
      else
        v_cgst := round(p_value * coalesce(v_rate.cgst_rate, 0) / 100, 2);
        v_sgst := round(p_value * coalesce(v_rate.sgst_rate, 0) / 100, 2);
      end if;
    end if;

    -- The series provisions itself: a dealer never finds transfers blocked for
    -- want of a sequence row.
    v_year := app.financial_year_token(p_dealer_id, current_date);
    insert into public.document_sequences (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
    values (p_dealer_id, null, 'TRANSFER_NOTE', v_year, 'TN', 6)
    on conflict on constraint document_sequences_scope_key do nothing;

    insert into public.branch_transfer_notes
      (dealer_id, note_number, note_kind, from_branch_id, to_branch_id, from_gstin, to_gstin,
       item_id, vehicle_id, quantity, description, taxable_value, cgst_amount, sgst_amount, igst_amount, created_by)
    values
      (p_dealer_id, app.next_document_number(p_dealer_id, null, 'TRANSFER_NOTE', v_year),
       case when v_taxable then 'TAX_INVOICE' else 'DELIVERY_CHALLAN' end,
       p_from_branch, p_to_branch, nullif(btrim(v_from.gstin), ''), nullif(btrim(v_to.gstin), ''),
       p_item_id, p_vehicle_id, p_quantity, p_description, p_value, v_cgst, v_sgst, v_igst, auth.uid())
    returning * into v_note;
  end if;

  if v_note.taxable_value <= 0 then
    return v_note.id;   -- nothing of value moved; the note alone records it
  end if;

  v_gross := v_note.taxable_value + v_note.cgst_amount + v_note.sgst_amount + v_note.igst_amount;

  -- The sending branch.
  v_send := jsonb_build_array(
    jsonb_build_object('account_id', v_transit, 'debit', v_gross, 'credit', 0,
                       'branch_id', v_note.from_branch_id, 'narration', v_note.note_number || ' to branch'),
    jsonb_build_object('account_id', p_inventory, 'debit', 0, 'credit', v_note.taxable_value,
                       'branch_id', v_note.from_branch_id, 'narration', v_note.description));
  if v_note.cgst_amount > 0 then
    v_send := v_send
      || jsonb_build_object('account_id', app.require_account(p_dealer_id, 'SERVICE', 'INVOICE', 'CGST', v_note.from_branch_id),
                            'debit', 0, 'credit', v_note.cgst_amount, 'branch_id', v_note.from_branch_id, 'narration', 'Output CGST')
      || jsonb_build_object('account_id', app.require_account(p_dealer_id, 'SERVICE', 'INVOICE', 'SGST', v_note.from_branch_id),
                            'debit', 0, 'credit', v_note.sgst_amount, 'branch_id', v_note.from_branch_id, 'narration', 'Output SGST');
  end if;
  if v_note.igst_amount > 0 then
    v_send := v_send
      || jsonb_build_object('account_id', app.require_account(p_dealer_id, 'SERVICE', 'INVOICE', 'IGST', v_note.from_branch_id),
                            'debit', 0, 'credit', v_note.igst_amount, 'branch_id', v_note.from_branch_id, 'narration', 'Output IGST');
  end if;

  -- The receiving branch.
  v_recv := jsonb_build_array(
    jsonb_build_object('account_id', p_inventory, 'debit', v_note.taxable_value, 'credit', 0,
                       'branch_id', v_note.to_branch_id, 'narration', v_note.description));
  if v_note.cgst_amount > 0 then
    v_recv := v_recv
      || jsonb_build_object('account_id', app.require_account(p_dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_CGST', v_note.to_branch_id),
                            'debit', v_note.cgst_amount, 'credit', 0, 'branch_id', v_note.to_branch_id, 'narration', 'Input CGST')
      || jsonb_build_object('account_id', app.require_account(p_dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_SGST', v_note.to_branch_id),
                            'debit', v_note.sgst_amount, 'credit', 0, 'branch_id', v_note.to_branch_id, 'narration', 'Input SGST');
  end if;
  if v_note.igst_amount > 0 then
    v_recv := v_recv
      || jsonb_build_object('account_id', app.require_account(p_dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_IGST', v_note.to_branch_id),
                            'debit', v_note.igst_amount, 'credit', 0, 'branch_id', v_note.to_branch_id, 'narration', 'Input IGST');
  end if;
  v_recv := v_recv || jsonb_build_object('account_id', v_transit, 'debit', 0, 'credit', v_gross,
                                         'branch_id', v_note.to_branch_id, 'narration', v_note.note_number || ' from branch');

  if p_mode = 'BOTH' then
    v_entry := app.post_journal(p_dealer_id, v_note.from_branch_id, v_note.note_date, 'INVENTORY',
      'Transfer ' || v_note.note_number || ' — ' || v_note.description, v_send || v_recv,
      'BRANCH_TRANSFER', v_note.id, 'transfer:' || v_note.id::text);
    update public.branch_transfer_notes set receipt_journal_id = v_entry where id = v_note.id;
    -- journal_entry_id is written at insert time for the other modes; here the
    -- single journal is both, recorded as the receipt.
  elsif p_mode = 'DISPATCH' then
    v_entry := app.post_journal(p_dealer_id, v_note.from_branch_id, v_note.note_date, 'INVENTORY',
      'Dispatch ' || v_note.note_number || ' — ' || v_note.description, v_send,
      'BRANCH_TRANSFER', v_note.id, 'transfer-out:' || v_note.id::text);
  else
    v_entry := app.post_journal(p_dealer_id, v_note.to_branch_id, current_date, 'INVENTORY',
      'Receipt ' || v_note.note_number || ' — ' || v_note.description, v_recv,
      'BRANCH_TRANSFER', v_note.id, 'transfer-in:' || v_note.id::text);
    update public.branch_transfer_notes set receipt_journal_id = v_entry where id = v_note.id;
  end if;

  return case when p_mode = 'DISPATCH' then v_entry else v_note.id end;
end;
$$;

comment on function app.post_branch_transfer(uuid, uuid, uuid, uuid, numeric, text, text, uuid, uuid, numeric, text, uuid) is
  'Issues a transfer note (challan or tax invoice) and posts the value through '
  '1850 so each branch balances (0083). DISPATCH returns the journal id; the '
  'other modes return the note id.';

-- -----------------------------------------------------------------------------
-- Vehicle transfers: dispatch and receipt carry their halves
-- -----------------------------------------------------------------------------
alter table public.vehicle_transfers
  add column if not exists transfer_note_id    uuid,
  add column if not exists dispatch_journal_id uuid,
  add column if not exists receipt_journal_id  uuid;

create or replace function app.vehicle_transfer_journals()
returns trigger
language plpgsql
as $$
declare
  v_vehicle record;
  v_entry   uuid;
begin
  if tg_op = 'INSERT' then
    select v.purchase_cost, v.chassis_no, m.tax_code, m.brand || ' ' || m.name as label
      into v_vehicle
      from public.vehicles v join public.vehicle_models m on m.id = v.model_id
     where v.id = new.vehicle_id;

    if coalesce(v_vehicle.purchase_cost, 0) > 0 then
      v_entry := app.post_branch_transfer(
        new.dealer_id, new.from_branch_id, new.to_branch_id,
        app.require_account(new.dealer_id, 'INVENTORY', 'PURCHASE', 'VEHICLE_INVENTORY', new.from_branch_id),
        v_vehicle.purchase_cost, v_vehicle.tax_code, 'DISPATCH', null, new.vehicle_id, 1,
        v_vehicle.label || ' — ' || v_vehicle.chassis_no, null);
      new.dispatch_journal_id := v_entry;
      select je.source_document_id into new.transfer_note_id from public.journal_entries je where je.id = v_entry;
    end if;
    return new;
  end if;

  if old.status = 'IN_TRANSIT' and new.status = 'RECEIVED' and new.transfer_note_id is not null then
    perform app.post_branch_transfer(
      new.dealer_id, new.from_branch_id, new.to_branch_id,
      app.require_account(new.dealer_id, 'INVENTORY', 'PURCHASE', 'VEHICLE_INVENTORY', new.to_branch_id),
      0, null, 'RECEIVE', null, new.vehicle_id, 1, null, new.transfer_note_id);
    select receipt_journal_id into new.receipt_journal_id
      from public.branch_transfer_notes where id = new.transfer_note_id;
  elsif old.status = 'IN_TRANSIT' and new.status = 'CANCELLED' and new.dispatch_journal_id is not null then
    perform app.reverse_journal(new.dispatch_journal_id, 'Transfer ' || new.transfer_number || ' cancelled', current_date);
  end if;
  return new;
end;
$$;

create trigger vehicle_transfers_journals
  before insert or update of status on public.vehicle_transfers
  for each row execute function app.vehicle_transfer_journals();

-- -----------------------------------------------------------------------------
-- Damaged stock
-- -----------------------------------------------------------------------------
create or replace function public.mark_stock_damaged(
  p_item_id        uuid,
  p_branch_id      uuid,
  p_source         text,
  p_quantity       numeric,
  p_realisable_unit numeric,
  p_reason         text
)
returns uuid
language plpgsql
as $$
declare
  v_dealer   uuid := app.current_dealer_id();
  v_item     public.inventory_items;
  v_avail    numeric;
  v_cost     numeric;
  v_nrv      numeric;
  v_writedown numeric;
  v_entry    uuid;
  v_inv      uuid;
begin
  if v_dealer is null or not app.has_permission('inventory.stock.adjust') then
    raise exception 'You may not adjust stock.' using errcode = 'insufficient_privilege';
  end if;
  if p_source not in ('LOCAL', 'COMPANY') then
    raise exception 'Damaged stock comes out of the LOCAL or COMPANY lot.' using errcode = 'check_violation';
  end if;
  if coalesce(p_quantity, 0) <= 0 then
    raise exception 'Enter how many are damaged.' using errcode = 'check_violation';
  end if;
  if coalesce(length(btrim(p_reason)), 0) < 3 then
    raise exception 'Say what happened to it.' using errcode = 'check_violation';
  end if;

  select * into v_item from public.inventory_items where id = p_item_id and dealer_id = v_dealer;
  if v_item.id is null then
    raise exception 'Item not found.' using errcode = 'no_data_found';
  end if;

  select l.quantity, l.average_cost into v_avail, v_cost from app.lock_stock_lot(p_item_id, p_branch_id, p_source) l;
  if coalesce(v_avail, 0) < p_quantity then
    raise exception 'Only % in % stock.', coalesce(v_avail, 0), p_source using errcode = 'check_violation';
  end if;
  v_cost := coalesce(v_cost, 0);
  v_nrv := least(greatest(coalesce(p_realisable_unit, 0), 0), v_cost);
  v_writedown := round(p_quantity * (v_cost - v_nrv), 4);

  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
     reference_type, narration, reason, created_by)
  values
    (v_dealer, p_branch_id, p_item_id, p_source, 'TRANSFER_OUT', -p_quantity, v_cost,
     'DAMAGE', 'Moved to damaged stock', btrim(p_reason), auth.uid()),
    (v_dealer, p_branch_id, p_item_id, 'DAMAGED', 'TRANSFER_IN', p_quantity, v_nrv,
     'DAMAGE', 'Damaged, held at realisable value', btrim(p_reason), auth.uid());

  if v_writedown > 0 then
    v_inv := app.require_account(v_dealer, 'INVENTORY', 'ADJUSTMENT',
      case when v_item.item_type = 'ACCESSORY' then 'ACCESSORY_INVENTORY' else 'SPARE_INVENTORY' end, p_branch_id);
    v_entry := app.post_journal(v_dealer, p_branch_id, current_date, 'INVENTORY',
      'Write-down of damaged ' || v_item.item_code || ' ×' || p_quantity || ' — ' || btrim(p_reason),
      jsonb_build_array(
        jsonb_build_object('account_id', app.require_account(v_dealer, 'INVENTORY', 'ADJUSTMENT', 'VARIANCE', p_branch_id),
                           'debit', v_writedown, 'credit', 0, 'narration', 'Damaged stock written down'),
        jsonb_build_object('account_id', v_inv, 'debit', 0, 'credit', v_writedown, 'narration', v_item.item_code)),
      'STOCK_DAMAGE', p_item_id, null);
  end if;

  return v_entry;
end;
$$;

comment on function public.mark_stock_damaged(uuid, uuid, text, numeric, numeric, text) is
  'Moves counted stock into the DAMAGED lot (never sold by the allocator) at its '
  'realisable value, posting the write-down to 5970 (checklist §06).';

-- -----------------------------------------------------------------------------
-- Consignment stock: held, not owned, valued at nil
-- -----------------------------------------------------------------------------
create or replace function public.move_consignment_stock(
  p_item_id   uuid,
  p_branch_id uuid,
  p_quantity  numeric,
  p_direction text,
  p_reference text
)
returns void
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
begin
  if v_dealer is null or not app.has_permission('inventory.stock.adjust') then
    raise exception 'You may not move stock.' using errcode = 'insufficient_privilege';
  end if;
  if p_direction not in ('RECEIVE', 'RETURN') or coalesce(p_quantity, 0) <= 0 then
    raise exception 'Receive or return a positive quantity.' using errcode = 'check_violation';
  end if;
  if coalesce(length(btrim(p_reference)), 0) < 2 then
    raise exception 'Give the consignor''s delivery note or reference.' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.inventory_items where id = p_item_id and dealer_id = v_dealer) then
    raise exception 'Item not found.' using errcode = 'no_data_found';
  end if;

  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
     reference_type, reference_number, narration, created_by)
  values
    (v_dealer, p_branch_id, p_item_id, 'CONSIGNMENT',
     case when p_direction = 'RECEIVE' then 'TRANSFER_IN' else 'TRANSFER_OUT' end,
     case when p_direction = 'RECEIVE' then p_quantity else -p_quantity end,
     0, 'CONSIGNMENT', btrim(p_reference),
     case when p_direction = 'RECEIVE' then 'Received on consignment — not owned' else 'Returned to consignor' end,
     auth.uid());
end;
$$;

create or replace function public.inventory_condition_report(p_branch_id uuid default null)
returns table (item_id uuid, item_code text, item_name text, branch_name text,
               damaged_qty numeric, damaged_value numeric, consignment_qty numeric)
language sql
stable
as $$
  select i.id, i.item_code, i.name, b.name,
         coalesce(sum(s.quantity) filter (where s.source = 'DAMAGED'), 0),
         coalesce(sum(s.stock_value) filter (where s.source = 'DAMAGED'), 0),
         coalesce(sum(s.quantity) filter (where s.source = 'CONSIGNMENT'), 0)
    from public.inventory_stock s
    join public.inventory_items i on i.id = s.item_id
    join public.branches b on b.id = s.branch_id
   where s.source in ('DAMAGED', 'CONSIGNMENT')
     and (p_branch_id is null or s.branch_id = p_branch_id)
   group by i.id, i.item_code, i.name, b.name
  having coalesce(sum(s.quantity), 0) <> 0
   order by i.item_code;
$$;
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
  v_acc       record;
  v_dr        numeric;
  v_cr        numeric;
  v_money     integer := 0;
  v_lock      date;
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
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

  -- ── Every line, before anything is written ───────────────────────────────
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_index := v_index + 1;

    if (v_line ->> 'account_id') is null then
      raise exception 'Journal line % has no account. Check the accounting rules for this event.', v_index
        using errcode = 'check_violation',
              hint = 'Spec §22: accounts are resolved from accounting_rules, never hard-coded.';
    end if;

    begin
      v_dr := coalesce((v_line ->> 'debit')::numeric, 0);
      v_cr := coalesce((v_line ->> 'credit')::numeric, 0);
    exception when others then
      raise exception 'Journal line % has an amount that is not a number.', v_index
        using errcode = 'check_violation';
    end;

    if v_dr < 0 or v_cr < 0 then
      raise exception 'Journal line % has a negative amount. Use the other side instead.', v_index
        using errcode = 'check_violation';
    end if;
    if (v_dr > 0) = (v_cr > 0) then
      raise exception 'Journal line % must be a debit or a credit — not both, and not zero.', v_index
        using errcode = 'check_violation';
    end if;

    -- A line may sit in another branch of the same dealer (an inter-branch
    -- transfer posts both branches in one entry, each side balanced).
    if (v_line ->> 'branch_id') is not null and not exists (
         select 1 from public.branches b
          where b.id = (v_line ->> 'branch_id')::uuid and b.dealer_id = p_dealer_id) then
      raise exception 'Journal line % names a branch that does not belong to this dealer.', v_index
        using errcode = 'insufficient_privilege';
    end if;

    select * into v_acc from app.journal_account(p_dealer_id, (v_line ->> 'account_id')::uuid);
    if v_acc.code is null then
      raise exception 'Journal line % names an account that does not belong to this dealer.', v_index
        using errcode = 'insufficient_privilege';
    end if;
    if v_acc.is_group then
      raise exception 'Journal line %: % % is a group heading and cannot be posted to.',
        v_index, v_acc.code, v_acc.name
        using errcode = 'check_violation',
              hint = 'Post to one of the accounts beneath it.';
    end if;
    if v_acc.status <> 'ACTIVE' then
      raise exception 'Journal line %: % % is inactive and cannot be posted to.',
        v_index, v_acc.code, v_acc.name
        using errcode = 'check_violation';
    end if;

    if app.is_money_ledger(p_dealer_id, (v_line ->> 'account_id')::uuid) then
      v_money := v_money + 1;
      -- A hand-written line on cash or bank moves the ledger and not the book.
      if p_source_document_type = 'MANUAL_JOURNAL' then
        raise exception 'Journal line %: % % is a cash or bank account. Use Bank or Cash entry, or a Contra voucher, so the book moves with the ledger.',
          v_index, v_acc.code, v_acc.name
          using errcode = 'check_violation';
      end if;
    end if;

    v_debit  := v_debit  + v_dr;
    v_credit := v_credit + v_cr;
  end loop;

  -- A cash or bank entry writes ONE book row. A counter account that is itself
  -- cash or bank would move a second book that nothing writes.
  if p_source_document_type in ('CASH_BOOK', 'BANK_BOOK') and v_money > 1 then
    raise exception 'Money moving between cash and bank, or between two banks, is a Contra voucher.'
      using errcode = 'check_violation',
            hint = 'Bank → Contra writes both books; a receipt or payment writes only one.';
  end if;

  if round(v_debit, 4) <> round(v_credit, 4) then
    raise exception 'Journal does not balance: debit % <> credit %.', v_debit, v_credit
      using errcode = 'check_violation',
            hint = 'Spec §22: total debit must equal total credit.';
  end if;

  -- ── The lock date ────────────────────────────────────────────────────────
  v_lock := app.books_locked_through(p_dealer_id);
  if v_lock is not null and p_entry_date <= v_lock then
    raise exception 'The books are locked through %. Nothing dated % can be posted.',
      to_char(v_lock, 'DD-MM-YYYY'), to_char(p_entry_date, 'DD-MM-YYYY')
      using errcode = 'insufficient_privilege',
            hint = 'Date the entry after the lock, or ask Accounts to reopen the period with a reason.';
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

  v_index := 0;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_index := v_index + 1;
    insert into public.journal_entry_lines
      (journal_entry_id, dealer_id, line_number, account_id, branch_id,
       debit, credit, narration, party_type, party_id)
    values
      (v_entry_id, p_dealer_id, v_index, (v_line ->> 'account_id')::uuid,
       coalesce((v_line ->> 'branch_id')::uuid, p_branch_id),
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
   -- The line's branch, not the header's: an inter-branch transfer puts each
   -- side in its own branch within one entry (0083).
   and (p_branch_id is null or l.branch_id = p_branch_id)
  left join public.journal_entries je
    on je.id = l.journal_entry_id
   and je.status in ('POSTED', 'REVERSED')
  group by coa.id, coa.code, coa.name, coa.account_type, coa.normal_balance,
           coa.is_group, coa.status
  having (not coa.is_group and coa.status = 'ACTIVE') or count(je.id) > 0
  order by coa.code;
$$;

create or replace function public.account_ledger(
  p_account_id uuid,
  p_from       date,
  p_to         date,
  p_branch_id  uuid default null
)
returns table (
  journal_entry_id uuid,
  entry_date       date,
  entry_number     text,
  source_module    text,
  status           text,
  narration        text,
  -- What sat on the other side of this line, which is the question anyone
  -- reading a ledger row actually has: "4,150 to Bank Charges — from where?"
  contra           text,
  debit            numeric(18, 4),
  credit           numeric(18, 4),
  running_balance  numeric(18, 4)
)
language sql
stable
as $$
  select je.id,
         je.entry_date,
         je.entry_number,
         je.source_module,
         je.status,
         coalesce(l.narration, je.narration),
         (
           -- The opposite side of the same entry, named. Several accounts on the
           -- other side are listed rather than reduced to "Split", because on a
           -- two-line entry — which most are — the one name is the whole answer.
           select string_agg(distinct c2.name, ', ' order by c2.name)
             from public.journal_entry_lines l2
             join public.chart_of_accounts c2 on c2.id = l2.account_id
            where l2.journal_entry_id = je.id
              and l2.account_id <> p_account_id
         ),
         l.debit,
         l.credit,
         public.account_ledger_opening(p_account_id, p_from)
           + sum(l.debit - l.credit) over (order by je.entry_date, je.entry_number, l.line_number
                                           rows between unbounded preceding and current row)
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.account_id = p_account_id
     and je.status in ('POSTED', 'REVERSED')
     and je.entry_date between p_from and p_to
     and (p_branch_id is null or l.branch_id = p_branch_id)
   order by je.entry_date, je.entry_number, l.line_number;
$$;

create or replace function public.control_account_tieout(p_as_on date default current_date)
returns table (
  control          text,     -- PARTY | CASH | BANK | VEHICLE_STOCK | ACCESSORY_STOCK | SPARE_STOCK
  account_code     text,
  account_name     text,
  ledger_balance   numeric(18, 4),
  subledger_balance numeric(18, 4),
  difference       numeric(18, 4),
  explanation      text
)
language sql
stable
as $$
  with gl as (
    select l.account_id,
           sum(l.debit - l.credit) as bal,
           sum(l.debit - l.credit) filter (where l.party_id is not null) as tagged,
           count(*) filter (where l.party_id is null) as untagged_lines
      from public.journal_entry_lines l
      join public.journal_entries je on je.id = l.journal_entry_id
     where je.status in ('POSTED', 'REVERSED')
       and je.entry_date <= p_as_on
     group by l.account_id
  ),
  coa as (
    select c.id, c.code, c.name, c.normal_balance, c.account_type, c.dealer_id
      from public.chart_of_accounts c
  ),
  -- Party control accounts: receivables, payables, advances and finance-company
  -- balances — balance-sheet accounts a party line has touched, plus the two
  -- that should only ever be touched that way. A bank line or a commission
  -- income line may carry a party for reference; those are not controls, and
  -- listing them would report a "difference" that is nothing of the kind.
  party as (
    select 'PARTY'::text, coa.code, coa.name,
           coalesce(gl.bal, 0), coalesce(gl.tagged, 0),
           coalesce(gl.bal, 0) - coalesce(gl.tagged, 0),
           case when coalesce(gl.bal, 0) = coalesce(gl.tagged, 0) then null
                else gl.untagged_lines || ' line(s) on this account carry no customer, supplier or finance company' end
      from coa
      left join gl on gl.account_id = coa.id
     where coa.code in ('1300', '2200')
        or (coalesce(gl.tagged, 0) <> 0
            and coa.account_type in ('ASSET', 'LIABILITY')
            and not app.is_money_ledger(coa.dealer_id, coa.id))
  ),
  cash_book as (
    select ca.ledger_account_id,
           sum(ca.opening_balance + coalesce((
             select sum(case when t.direction = 'RECEIPT' then t.amount else -t.amount end)
               from public.cash_transactions t
              where t.cash_account_id = ca.id and t.status = 'ACTIVE'
                and t.business_date <= p_as_on), 0)) as bal
      from public.cash_accounts ca
     group by ca.ledger_account_id
  ),
  bank_book as (
    select ba.ledger_account_id,
           sum(ba.opening_balance + coalesce((
             select sum(case when t.direction = 'RECEIPT' then t.amount else -t.amount end)
               from public.bank_transactions t
              where t.bank_account_id = ba.id and t.status = 'ACTIVE'
                and t.transaction_date <= p_as_on), 0)) as bal
      from public.bank_accounts ba
     group by ba.ledger_account_id
  ),
  money as (
    select 'CASH'::text, coa.code, coa.name, coalesce(gl.bal, 0), cb.bal,
           coalesce(gl.bal, 0) - cb.bal,
           case when coalesce(gl.bal, 0) = cb.bal then null
                else 'Cash-ledger lines with no cash-book row, or a cash book opening balance never journalled' end
      from cash_book cb join coa on coa.id = cb.ledger_account_id
      left join gl on gl.account_id = cb.ledger_account_id
    union all
    select 'BANK'::text, coa.code, coa.name, coalesce(gl.bal, 0), bb.bal,
           coalesce(gl.bal, 0) - bb.bal,
           case when coalesce(gl.bal, 0) = bb.bal then null
                else 'Bank-ledger lines with no bank-book row (e.g. a receipt taken before any bank account existed)' end
      from bank_book bb join coa on coa.id = bb.ledger_account_id
      left join gl on gl.account_id = bb.ledger_account_id
  ),
  -- Stock is valued as it stands now; a stock tie-out for a past date would
  -- need the movement history replayed, and is only offered for today.
  stock as (
    -- A vehicle on the road left 1500 when its dispatch was journalled (0083);
    -- one dispatched before that never did.
    select 'VEHICLE_STOCK'::text as control, '1500'::text as code,
           coalesce(sum(v.purchase_cost), 0) as val
      from public.vehicles v
     where v.status in ('IN_STOCK', 'BOOKED')
        or (v.status = 'TRANSFERRED' and not exists (
              select 1 from public.vehicle_transfers vt
               where vt.vehicle_id = v.id and vt.status = 'IN_TRANSIT' and vt.dispatch_journal_id is not null))
    union all
    select 'STOCK_IN_TRANSIT', '1850',
           coalesce(sum(n.taxable_value + n.cgst_amount + n.sgst_amount + n.igst_amount), 0)
      from public.branch_transfer_notes n
      join public.vehicle_transfers vt on vt.transfer_note_id = n.id
     where vt.status = 'IN_TRANSIT'
    union all
    select case i.item_type when 'ACCESSORY' then 'ACCESSORY_STOCK' else 'SPARE_STOCK' end,
           case i.item_type when 'ACCESSORY' then '1600' else '1700' end,
           coalesce(sum(s.stock_value), 0)
      from public.inventory_stock s
      join public.inventory_items i on i.id = s.item_id
     group by i.item_type
  ),
  stock_rows as (
    select st.control, coa.code, coa.name, coalesce(gl.bal, 0), sum(st.val),
           coalesce(gl.bal, 0) - sum(st.val),
           case when coalesce(gl.bal, 0) = sum(st.val) then null
                else 'Stock at cost that never reached the ledger (uploaded without a purchase bill or opening entry), or the reverse' end
      from stock st
      join coa on coa.code = st.code
      left join gl on gl.account_id = coa.id
     where p_as_on >= current_date
     group by st.control, coa.code, coa.name, gl.bal
  )
  select * from party
  union all select * from money
  union all select * from stock_rows
  order by 1, 2;
$$;

create or replace function app.adjust_inventory_stock_core(
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
  v_type      text;
  v_code      text;
  v_available numeric(14, 3);
  v_cost      numeric(18, 4);
  v_value     numeric(18, 4);
  v_stock_acc uuid;
  v_var_acc   uuid;
  v_entry     uuid;
begin
  if p_quantity = 0 then
    raise exception 'An adjustment of zero changes nothing.' using errcode = 'check_violation';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A stock adjustment requires a reason.'
      using errcode = 'check_violation',
            hint = 'Spec §35: adjustments are auditable, so they must be explained.';
  end if;
  -- DAMAGED stock can be written off; CONSIGNMENT is not the dealer's to adjust.
  if p_source not in ('LOCAL', 'COMPANY', 'DAMAGED') then
    raise exception 'Source must be LOCAL, COMPANY or DAMAGED.' using errcode = 'check_violation';
  end if;

  select dealer_id, standard_cost, item_type, item_code into v_dealer, v_cost, v_type, v_code
    from public.inventory_items where id = p_item_id;

  if v_dealer is null then
    raise exception 'Item not found.' using errcode = 'no_data_found';
  end if;

  select l.quantity, l.average_cost into v_available, v_cost
    from app.lock_stock_lot(p_item_id, p_branch_id, p_source) l;

  if p_quantity < 0 and coalesce(v_available, 0) < abs(p_quantity) then
    raise exception 'Only % in stock — an adjustment of % would drive it negative.',
      coalesce(v_available, 0), p_quantity using errcode = 'check_violation';
  end if;

  if v_cost is null or v_cost = 0 then
    select standard_cost into v_cost from public.inventory_items where id = p_item_id;
  end if;
  v_cost  := coalesce(v_cost, 0);
  -- The same figure the movement's generated `value` column will hold, so the
  -- stock ledger and the general ledger move by exactly the same amount.
  v_value := round(abs(p_quantity) * v_cost, 4);

  -- ── The journal first: if the rules are missing, nothing moves ──────────
  if v_value > 0 then
    v_stock_acc := app.require_account(v_dealer, 'INVENTORY', 'ADJUSTMENT',
      case when v_type = 'ACCESSORY' then 'ACCESSORY_INVENTORY' else 'SPARE_INVENTORY' end,
      p_branch_id);
    v_var_acc := app.require_account(v_dealer, 'INVENTORY', 'ADJUSTMENT', 'VARIANCE', p_branch_id);

    v_entry := app.post_journal(
      v_dealer, p_branch_id, current_date, 'INVENTORY',
      'Stock adjustment ' || v_code || ' ' || p_source || ' '
        || case when p_quantity > 0 then '+' else '' end || p_quantity::text
        || ' — ' || btrim(p_reason),
      case when p_quantity > 0 then
        jsonb_build_array(
          jsonb_build_object('account_id', v_stock_acc, 'debit', v_value, 'credit', 0,
                             'narration', 'Counted more ' || v_code),
          jsonb_build_object('account_id', v_var_acc, 'debit', 0, 'credit', v_value,
                             'narration', btrim(p_reason)))
      else
        jsonb_build_array(
          jsonb_build_object('account_id', v_var_acc, 'debit', v_value, 'credit', 0,
                             'narration', btrim(p_reason)),
          jsonb_build_object('account_id', v_stock_acc, 'debit', 0, 'credit', v_value,
                             'narration', 'Counted less ' || v_code))
      end,
      'STOCK_ADJUSTMENT', p_item_id, null);
  end if;

  -- reference_id carries the journal, so the stock ledger row drills to it.
  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
     reference_type, reference_id, narration, reason, created_by)
  values
    (v_dealer, p_branch_id, p_item_id, p_source, 'ADJUSTMENT', p_quantity, v_cost,
     'ADJUSTMENT', v_entry, 'Stock adjustment', btrim(p_reason), auth.uid());
end;
$$;

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
  if not exists (select 1 from public.branches where id = p_to_branch_id and dealer_id = v_dealer) then
    raise exception 'The destination branch does not belong to this dealer.'
      using errcode = 'insufficient_privilege';
  end if;

  select l.quantity, l.average_cost into v_available, v_cost
    from app.lock_stock_lot(p_item_id, p_from_branch_id, p_source) l;

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

  -- The value moves with the quantity (0083): out of the sending branch's stock,
  -- into the receiving branch's, through Inter-Branch Stock in Transit — with
  -- GST when the two branches hold different GSTINs, because then it is a supply.
  perform app.post_branch_transfer(
    v_dealer, p_from_branch_id, p_to_branch_id,
    app.require_account(v_dealer, 'INVENTORY', 'ADJUSTMENT',
      case when (select item_type from public.inventory_items where id = p_item_id) = 'ACCESSORY'
           then 'ACCESSORY_INVENTORY' else 'SPARE_INVENTORY' end, p_from_branch_id),
    round(p_quantity * coalesce(v_cost, 0), 4),
    (select tax_code from public.inventory_items where id = p_item_id),
    'BOTH', p_item_id, null, p_quantity,
    (select item_code || ' ' || name from public.inventory_items where id = p_item_id), null);
end;
$$;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.branch_transfer_notes to authenticated';
    execute 'grant execute on function public.mark_stock_damaged(uuid, uuid, text, numeric, numeric, text) to authenticated';
    execute 'grant execute on function public.move_consignment_stock(uuid, uuid, numeric, text, text) to authenticated';
    execute 'grant execute on function public.inventory_condition_report(uuid) to authenticated';
  end if;
end $$;

-- What was dispatched before this and never journalled stays in 1500 until it
-- is received; the tie-out counts it there.
do $$
declare v_count integer;
begin
  select count(*) into v_count from public.vehicle_transfers where status = 'IN_TRANSIT' and dispatch_journal_id is null;
  if v_count > 0 then
    raise notice '0083: % vehicle(s) in transit were dispatched before transfers carried value; they post nothing on receipt.', v_count;
  end if;
end $$;

insert into public.schema_migrations (version, name)
values ('0083', 'branch_transfer_value_damaged_consignment') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0084_gst_categories_notes_rcm_itc.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0084 — Tax categories, credit and debit notes, reverse charge, ITC categories
-- =============================================================================
-- Spec §16, §20, §21, §40, §41. Audit checklist §04 (tax setup), §05 (GST
-- documents), §08 (input tax).
--
-- ── Tax categories ─────────────────────────────────────────────────────────
--
-- A tax code carried a rate and nothing else, so a zero-rate line could be nil
-- rated, exempt, outside GST or simply unconfigured, and GSTR-3B table 3.1(c)/
-- (e) and table 5 need to know which. tax_codes.tax_category says; the three
-- non-taxable categories may not carry a rate. Sale and service lines keep the
-- code they were billed under (spec §16), so their category is read from the
-- code version in force on the invoice date; purchase lines record the
-- supplier's category directly, as they record the supplier's rate.
--
-- An invoice whose every line is non-taxable is a bill of supply (rule 49), not
-- a tax invoice; the printed document says so.
--
-- ── Credit and debit notes (s.34) ──────────────────────────────────────────
--
-- A price revision, a post-sale discount, a short supply: nothing recorded any
-- of these against the invoice they amend. gst_notes does, for both sides:
--
--   issued to a customer   CREDIT  income + output GST Dr / receivable Cr
--                          DEBIT   receivable Dr / income + output GST Cr
--   from a supplier        CREDIT  payable Dr / expense + input GST Cr
--                          DEBIT   expense + input GST Dr / payable Cr
--
-- Every note names the invoice or bill it amends, takes that document's tax
-- mode (IGST or CGST+SGST), and credit notes may not exceed what they amend.
-- A note is corrected by cancelling it, which reverses its journal.
--
-- ── Reverse charge ─────────────────────────────────────────────────────────
--
-- On a reverse-charge purchase (GTA freight, legal fees, an unregistered
-- landlord) the supplier's bill carries no tax and the dealer pays it instead:
--
--   Expense Dr  /  Input GST Dr (if claimable)  /  Supplier Cr (value only)
--                                              /  GST Payable (RCM) Cr
--
-- purchase_bill_lines.reverse_charge marks the line; the bill's header tax is
-- what the supplier charged, and reverse_charge_tax is what the dealer owes.
--
-- ── ITC categories ─────────────────────────────────────────────────────────
--
-- itc_eligible (0078) was a yes/no. itc_category records why: ELIGIBLE,
-- CAPITAL_GOODS, COMMON (claimed, then apportioned under rule 42), BLOCKED
-- (s.17(5)) or PERSONAL; itc_eligible follows from it. itc_adjustments records
-- reversals and re-claims — rule 37 (supplier unpaid after 180 days), rule 42/43
-- (common credit), s.17(5) — each posting ITC ⇄ 5990 Input Tax Credit Reversed,
-- and a re-claim can never exceed what was reversed. itc_rule37_candidates()
-- finds the bills a rule 37 reversal is due on.
--
-- Rollback: drop gst_notes, itc_adjustments and their functions; restore
--           post_purchase_bill (0078), purchase_bill_lines_sync_totals (0052),
--           gstr1_summary and gst_document_register (0034), gst_summary and
--           gst_input_summary (0078), app.seed_chart_of_accounts (rename
--           _0083 back); drop the columns added here.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Accounts, rules and category codes
-- -----------------------------------------------------------------------------
create or replace function app.seed_gst_compliance(p_dealer_id uuid)
returns integer
language plpgsql
as $$
declare
  v_added integer := 0;
  a       record;
begin
  for a in
    select * from (values
      ('2590', 'GST Payable — Reverse Charge',   'LIABILITY', '2000'),
      ('5990', 'Input Tax Credit Reversed',      'EXPENSE',   '5000')
    ) as t(code, name, account_type, parent_code)
  loop
    insert into public.chart_of_accounts
      (dealer_id, code, name, account_type, normal_balance, is_group, parent_id, is_system, is_branch_scoped)
    select p_dealer_id, a.code, a.name, a.account_type,
           case when a.account_type in ('ASSET', 'EXPENSE') then 'DEBIT' else 'CREDIT' end,
           false, p.id, true, false
      from public.chart_of_accounts p
     where p.dealer_id = p_dealer_id and p.code = a.parent_code and p.is_group
    on conflict on constraint coa_dealer_code_key do nothing;
    if found then v_added := v_added + 1; end if;
  end loop;

  insert into public.accounting_rules (dealer_id, module, event, component, side, account_id, description)
  select p_dealer_id, r.module, r.event, r.component, r.side, c.id, 'Default mapping'
    from (values
      ('INVENTORY', 'PURCHASE', 'RCM_PAYABLE', 'CREDIT', '2590'),
      ('EXPENSE',   'ITC',      'REVERSED',    'DEBIT',  '5990')
    ) as r(module, event, component, side, code)
    -- A dealer who already used the code for something else keeps it, and the
    -- rule is left unmapped: posting then says so instead of hitting the wrong account.
    join public.chart_of_accounts c on c.dealer_id = p_dealer_id and c.code = r.code
                                   and not c.is_group
                                   and c.account_type = case r.code when '2590' then 'LIABILITY' else 'EXPENSE' end
   where not exists (select 1 from public.accounting_rules x
                      where x.dealer_id = p_dealer_id and x.module = r.module
                        and x.event = r.event and x.component = r.component
                        and x.branch_id is null and x.status = 'ACTIVE');

  -- The three non-taxable categories, ready to put on an item or a line.
  insert into public.tax_codes
    (dealer_id, code, name, cgst_rate, sgst_rate, igst_rate, effective_from, tax_category)
  select p_dealer_id, t.code, t.name, 0, 0, 0, date '2017-07-01', t.category
    from (values
      ('NIL_RATED', 'Nil rated (0%)',          'NIL_RATED'),
      ('EXEMPT',    'Exempt supply',           'EXEMPT'),
      ('NON_GST',   'Non-GST supply',          'NON_GST')
    ) as t(code, name, category)
   where not exists (select 1 from public.tax_codes x
                      where x.dealer_id = p_dealer_id and x.code = t.code);

  return v_added;
end;
$$;

alter table public.tax_codes
  add column if not exists tax_category text not null default 'TAXABLE';
alter table public.tax_codes
  add constraint tax_codes_category_check
    check (tax_category in ('TAXABLE', 'ZERO_RATED', 'NIL_RATED', 'EXEMPT', 'NON_GST'));
-- Nil rated, exempt and non-GST supplies carry no tax, by definition.
alter table public.tax_codes
  add constraint tax_codes_category_rate_check
    check (tax_category in ('TAXABLE', 'ZERO_RATED')
           or (cgst_rate = 0 and sgst_rate = 0 and igst_rate = 0 and cess_rate = 0));

comment on column public.tax_codes.tax_category is
  'What GSTR-3B calls the supply: TAXABLE, ZERO_RATED (export/SEZ), NIL_RATED, '
  'EXEMPT or NON_GST. The last three carry no rate.';

do $$
declare d record;
begin
  for d in select id from public.dealers loop
    perform app.seed_gst_compliance(d.id);
  end loop;
end $$;

alter function app.seed_chart_of_accounts(uuid) rename to seed_chart_of_accounts_0083;

create or replace function app.seed_chart_of_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
begin
  return app.seed_chart_of_accounts_0083(p_dealer_id) + app.seed_gst_compliance(p_dealer_id);
end;
$$;

-- The category of a billed line: the code version in force on the invoice date.
-- A line with no code is TAXABLE if it was taxed and unclassified if not — an
-- untagged zero-rate line is a question for the accountant, not a guess.
create or replace function app.supply_category(
  p_dealer_id uuid, p_tax_code text, p_on date, p_tax numeric
)
returns text
language sql
stable
as $$
  select coalesce(
    (select t.tax_category from public.tax_codes t
      where t.dealer_id = p_dealer_id and t.code = p_tax_code
        and t.effective_from <= p_on and (t.effective_to is null or t.effective_to >= p_on)
      order by t.effective_from desc limit 1),
    case when coalesce(p_tax, 0) > 0 then 'TAXABLE' else 'UNCLASSIFIED' end);
$$;

-- -----------------------------------------------------------------------------
-- Purchase lines: category, reverse charge, ITC category
-- -----------------------------------------------------------------------------
alter table public.purchase_bill_lines
  add column if not exists tax_category   text not null default 'TAXABLE',
  add column if not exists reverse_charge boolean not null default false,
  add column if not exists itc_category   text not null default 'ELIGIBLE';

alter table public.purchase_bills
  add column if not exists reverse_charge_tax numeric(18, 4) not null default 0;

alter table public.purchase_bill_lines
  add constraint pbl_tax_category_check
    check (tax_category in ('TAXABLE', 'ZERO_RATED', 'NIL_RATED', 'EXEMPT', 'NON_GST')),
  add constraint pbl_tax_category_rate_check
    check (tax_category in ('TAXABLE', 'ZERO_RATED') or (cgst_amount = 0 and sgst_amount = 0 and igst_amount = 0)),
  add constraint pbl_itc_category_check
    check (itc_category in ('ELIGIBLE', 'CAPITAL_GOODS', 'COMMON', 'BLOCKED', 'PERSONAL')),
  -- Stock is always bought for business; the finer categories are for overheads.
  add constraint pbl_itc_category_scope_check
    check (itc_category = 'ELIGIBLE' or line_type = 'EXPENSE'),
  add constraint pbl_rcm_scope_check
    check (not reverse_charge or (line_type = 'EXPENSE' and tax_category = 'TAXABLE')),
  -- The supplier is owed the value alone; the tax is the dealer's to pay.
  add constraint pbl_rcm_total_check
    check (not reverse_charge or total_amount = taxable_value);

comment on column public.purchase_bill_lines.reverse_charge is
  'Tax payable by the dealer under s.9(3)/(4): the line''s tax is self-assessed, '
  'credited to GST Payable (RCM) and not owed to the supplier.';
comment on column public.purchase_bill_lines.itc_category is
  'Why the input tax is or is not claimed. ELIGIBLE, CAPITAL_GOODS and COMMON are '
  'claimed (COMMON is then apportioned); BLOCKED (s.17(5)) and PERSONAL are cost.';

-- A personal purchase paid by the business is the owner's drawing: it may be
-- charged to an equity account. Otherwise as 0078.
create or replace function app.purchase_bill_lines_account_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_acc public.chart_of_accounts;
begin
  if new.line_type <> 'EXPENSE' then
    return new;
  end if;

  select * into v_acc from public.chart_of_accounts
   where id = new.account_id and dealer_id = new.dealer_id;

  if v_acc.id is null then
    raise exception 'The account on this line is not in your chart of accounts.'
      using errcode = 'foreign_key_violation';
  end if;
  if v_acc.is_group or v_acc.status <> 'ACTIVE' then
    raise exception 'Account % % cannot be charged: it is a heading or inactive.', v_acc.code, v_acc.name
      using errcode = 'check_violation';
  end if;
  if not (v_acc.account_type in ('EXPENSE', 'ASSET')
          or (v_acc.account_type = 'EQUITY' and new.itc_category = 'PERSONAL')) then
    raise exception 'A purchase is charged to an expense or an asset (or, if personal, to drawings); % % is %.',
      v_acc.code, v_acc.name, lower(v_acc.account_type)
      using errcode = 'check_violation';
  end if;
  if app.is_money_ledger(new.dealer_id, new.account_id) then
    raise exception 'Account % % is cash or bank, not something bought.', v_acc.code, v_acc.name
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.accounting_rules r
              where r.dealer_id = new.dealer_id and r.account_id = new.account_id
                and r.module = 'INVENTORY' and r.event = 'PURCHASE'
                and r.status = 'ACTIVE') then
    raise exception 'Account % % is posted by stock lines and tax, not charged directly. Use a vehicle, accessory or spare line.',
      v_acc.code, v_acc.name using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

-- itc_eligible follows the category. A caller that still sends only the 0078
-- flag (false) gets BLOCKED, which is what false meant there.
create or replace function app.purchase_line_itc_category()
returns trigger
language plpgsql
as $$
begin
  if new.itc_category = 'ELIGIBLE' and not new.itc_eligible then
    new.itc_category := 'BLOCKED';
  end if;
  new.itc_eligible := new.itc_category in ('ELIGIBLE', 'CAPITAL_GOODS', 'COMMON');
  -- A reverse-charge line's total is its value alone; pbl_rcm_total_check
  -- refuses anything else rather than this trigger quietly rewriting it.
  return new;
end;
$$;

create trigger purchase_bill_lines_itc_category
  before insert or update on public.purchase_bill_lines
  for each row execute function app.purchase_line_itc_category();

-- The header's tax is what the supplier charged; reverse-charge tax is shown
-- beside it, so taxable + tax = total still holds on every bill.
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

  if v_status is null then
    return coalesce(new, old);
  end if;

  if v_status <> 'DRAFT' then
    raise exception 'Cannot % lines of purchase bill %: it is %.',
      lower(tg_op), v_number, v_status
      using errcode = 'insufficient_privilege';
  end if;

  update public.purchase_bills b
     set taxable_value      = coalesce(t.taxable, 0),
         cgst_amount        = coalesce(t.cgst, 0),
         sgst_amount        = coalesce(t.sgst, 0),
         igst_amount        = coalesce(t.igst, 0),
         reverse_charge_tax = coalesce(t.rcm, 0),
         total_amount       = coalesce(t.total, 0)
    from (
      select sum(l.taxable_value) as taxable,
             sum(l.cgst_amount) filter (where not l.reverse_charge) as cgst,
             sum(l.sgst_amount) filter (where not l.reverse_charge) as sgst,
             sum(l.igst_amount) filter (where not l.reverse_charge) as igst,
             sum(l.cgst_amount + l.sgst_amount + l.igst_amount) filter (where l.reverse_charge) as rcm,
             sum(l.total_amount) as total
        from public.purchase_bill_lines l
       where l.purchase_bill_id = v_bill
    ) t
   where b.id = v_bill;

  return coalesce(new, old);
end;
$$;

-- -----------------------------------------------------------------------------
-- public.post_purchase_bill() — reverse charge
-- -----------------------------------------------------------------------------
-- As 0078, plus: the tax on reverse-charge lines is credited to GST Payable
-- (RCM) rather than owed to the supplier, and claimed as input tax when the
-- line's credit is claimable.
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
  v_debit   numeric(18, 4);
  v_cgst    numeric(18, 4);
  v_sgst    numeric(18, 4);
  v_igst    numeric(18, 4);
  v_rcm     numeric(18, 4);
begin
  select * into v_bill from public.purchase_bills where id = p_bill_id for update;

  if v_bill.id is null then
    raise exception 'Purchase bill not found.' using errcode = 'no_data_found';
  end if;
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

  for v_line in
    select * from public.purchase_bill_lines
     where purchase_bill_id = p_bill_id
     order by line_number
  loop
    v_debit := v_line.taxable_value;

    if v_line.line_type = 'VEHICLE' then
      select id, status, chassis_no into v_veh
        from public.vehicles where id = v_line.vehicle_id for update;

      if v_veh.id is null then
        raise exception 'The vehicle on line % no longer exists.', v_line.line_number
          using errcode = 'no_data_found';
      end if;
      if v_veh.status <> 'IN_STOCK' then
        raise exception 'Chassis % is % and cannot be put on a purchase bill.',
          v_veh.chassis_no, v_veh.status using errcode = 'check_violation';
      end if;

      update public.vehicles
         set purchase_cost    = v_line.taxable_value,
             purchase_invoice = coalesce(purchase_invoice, v_bill.supplier_bill_number),
             purchase_date    = coalesce(purchase_date, v_bill.bill_date),
             updated_by       = auth.uid()
       where id = v_line.vehicle_id;

      v_account := app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE',
                                       'VEHICLE_INVENTORY', v_bill.branch_id);

    elsif v_line.line_type = 'EXPENSE' then
      v_account := v_line.account_id;
      if not v_line.itc_eligible then
        v_debit := v_debit + v_line.cgst_amount + v_line.sgst_amount + v_line.igst_amount;
      end if;

    else
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

    if v_debit > 0 then
      v_lines := v_lines || jsonb_build_object(
        'account_id', v_account, 'debit', v_debit, 'credit', 0,
        'narration', v_line.description);
    end if;
  end loop;

  select coalesce(sum(cgst_amount), 0), coalesce(sum(sgst_amount), 0), coalesce(sum(igst_amount), 0)
    into v_cgst, v_sgst, v_igst
    from public.purchase_bill_lines
   where purchase_bill_id = p_bill_id and itc_eligible;

  if v_cgst > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_CGST', v_bill.branch_id),
      'debit', v_cgst, 'credit', 0, 'narration', 'Input CGST ' || v_bill.bill_number);
  end if;
  if v_sgst > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_SGST', v_bill.branch_id),
      'debit', v_sgst, 'credit', 0, 'narration', 'Input SGST ' || v_bill.bill_number);
  end if;
  if v_igst > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_IGST', v_bill.branch_id),
      'debit', v_igst, 'credit', 0, 'narration', 'Input IGST ' || v_bill.bill_number);
  end if;

  -- ── Reverse charge: the dealer owes this tax to the government ───────────
  select coalesce(sum(cgst_amount + sgst_amount + igst_amount), 0) into v_rcm
    from public.purchase_bill_lines
   where purchase_bill_id = p_bill_id and reverse_charge;

  if v_rcm > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'RCM_PAYABLE', v_bill.branch_id),
      'debit', 0, 'credit', v_rcm, 'narration', 'GST on reverse charge ' || v_bill.bill_number);
  end if;

  select total_amount into v_total from public.purchase_bills where id = p_bill_id;

  v_lines := v_lines || jsonb_build_object(
    'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'PAYABLE', v_bill.branch_id),
    'debit', 0, 'credit', v_total,
    'narration', 'Bill ' || v_bill.supplier_bill_number,
    'party_type', 'SUPPLIER', 'party_id', v_bill.supplier_id);

  v_entry := app.post_journal(
    v_bill.dealer_id, v_bill.branch_id, v_bill.bill_date,
    case when exists (select 1 from public.purchase_bill_lines
                       where purchase_bill_id = p_bill_id and line_type <> 'EXPENSE')
         then 'INVENTORY' else 'EXPENSE' end,
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

-- -----------------------------------------------------------------------------
-- Permissions
-- -----------------------------------------------------------------------------
insert into public.permissions (code, module, description, is_sensitive) values
  ('gst.notes.manage', 'gst', 'Issue and cancel credit and debit notes', false),
  ('gst.itc.manage',   'gst', 'Reverse and re-claim input tax credit', false)
on conflict (code) do update set module = excluded.module, description = excluded.description,
                                 is_sensitive = excluded.is_sensitive;

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join (values ('gst.notes.manage'), ('gst.itc.manage')) as p(code)
 where r.is_system and r.code in ('DEALER_OWNER', 'ACCOUNTS')
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- gst_notes — credit and debit notes against an invoice or a bill (s.34)
-- -----------------------------------------------------------------------------
create table public.gst_notes (
  id                       uuid primary key default gen_random_uuid(),
  dealer_id                uuid not null references public.dealers (id) on delete restrict,
  branch_id                uuid not null,
  note_number              text not null,
  note_type                text not null,
  party_type               text not null,
  customer_id              uuid,
  supplier_id              uuid,
  -- For a supplier's note: the number on their document.
  party_note_number        text,
  original_document_type   text not null,
  original_document_id     uuid not null,
  original_document_number text not null,
  original_document_date   date not null,
  note_date                date not null,
  reason                   text not null,
  description              text not null,
  account_id               uuid not null,
  hsn_sac                  text,
  gst_rate                 numeric(6, 3) not null default 0,
  taxable_value            numeric(18, 4) not null,
  cgst_amount              numeric(18, 4) not null default 0,
  sgst_amount              numeric(18, 4) not null default 0,
  igst_amount              numeric(18, 4) not null default 0,
  total_amount             numeric(18, 4) not null,
  itc_eligible             boolean not null default true,
  status                   text not null default 'POSTED',
  journal_entry_id         uuid,
  cancel_journal_id        uuid,
  cancel_reason            text,
  idempotency_key          text,
  created_by               uuid,
  created_at               timestamptz not null default now(),

  constraint gst_notes_number_key unique (dealer_id, note_number),
  constraint gst_notes_idempotency_key unique (dealer_id, idempotency_key),
  constraint gst_notes_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint gst_notes_customer_tenant_fkey
    foreign key (customer_id, dealer_id) references public.customers (id, dealer_id),
  constraint gst_notes_supplier_tenant_fkey
    foreign key (supplier_id, dealer_id) references public.suppliers (id, dealer_id),
  constraint gst_notes_account_tenant_fkey
    foreign key (account_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint gst_notes_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint gst_notes_type_check   check (note_type in ('CREDIT', 'DEBIT')),
  constraint gst_notes_party_check  check (
    (party_type = 'CUSTOMER' and customer_id is not null and supplier_id is null
       and original_document_type in ('SALE', 'SERVICE_INVOICE'))
    or (party_type = 'SUPPLIER' and supplier_id is not null and customer_id is null
       and original_document_type = 'PURCHASE_BILL')
  ),
  constraint gst_notes_reason_check check (reason in (
    'PRICE_REVISION', 'DISCOUNT', 'SHORT_SUPPLY', 'DEFICIENCY', 'RATE_CORRECTION', 'OTHER')),
  constraint gst_notes_status_check check (status in ('POSTED', 'CANCELLED')),
  constraint gst_notes_amounts_check check (
    taxable_value > 0 and cgst_amount >= 0 and sgst_amount >= 0 and igst_amount >= 0
    and total_amount = taxable_value + cgst_amount + sgst_amount + igst_amount),
  constraint gst_notes_tax_split_check check (igst_amount = 0 or (cgst_amount = 0 and sgst_amount = 0)),
  constraint gst_notes_hsn_check check (hsn_sac is null or hsn_sac ~ '^[0-9]{4,8}$'),
  constraint gst_notes_cancel_check check (
    status <> 'CANCELLED' or (cancel_journal_id is not null and cancel_reason is not null))
);

comment on table public.gst_notes is
  'Credit and debit notes (s.34, spec §40): issued to customers against a sale or '
  'service invoice, or received from suppliers against a purchase bill. Posted '
  'on issue; corrected only by cancellation, which reverses the journal.';

create index gst_notes_original_idx on public.gst_notes (original_document_id);
create index gst_notes_dealer_date_idx on public.gst_notes (dealer_id, note_date desc);

-- A note is a posted document: after issue only its journal link (once) and its
-- cancellation (once) may be written.
create or replace function app.gst_notes_guard()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'A credit or debit note cannot be deleted; cancel it.'
      using errcode = 'insufficient_privilege';
  end if;
  if (new.id, new.dealer_id, new.branch_id, new.note_number, new.note_type, new.party_type,
      new.original_document_id, new.note_date, new.taxable_value, new.cgst_amount,
      new.sgst_amount, new.igst_amount, new.account_id)
     is distinct from
     (old.id, old.dealer_id, old.branch_id, old.note_number, old.note_type, old.party_type,
      old.original_document_id, old.note_date, old.taxable_value, old.cgst_amount,
      old.sgst_amount, old.igst_amount, old.account_id) then
    raise exception 'Note % is posted and cannot be edited; cancel it and issue another.', old.note_number
      using errcode = 'insufficient_privilege';
  end if;
  if old.journal_entry_id is not null and new.journal_entry_id is distinct from old.journal_entry_id then
    raise exception 'The journal of note % cannot be changed.', old.note_number
      using errcode = 'insufficient_privilege';
  end if;
  if old.status = 'CANCELLED' then
    raise exception 'Note % is already cancelled.', old.note_number
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger gst_notes_guard
  before update or delete on public.gst_notes
  for each row execute function app.gst_notes_guard();

create trigger gst_notes_audit after insert or update on public.gst_notes
  for each row execute function app.audit_trigger();

alter table public.gst_notes enable row level security;

create policy gst_notes_select on public.gst_notes for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('gst.reports.view') or app.has_permission('gst.notes.manage'))));
create policy gst_notes_insert on public.gst_notes for insert to authenticated
  with check (dealer_id = app.current_dealer_id() and app.has_permission('gst.notes.manage'));
create policy gst_notes_update on public.gst_notes for update to authenticated
  using (dealer_id = app.current_dealer_id() and app.has_permission('gst.notes.manage'))
  with check (dealer_id = app.current_dealer_id() and app.has_permission('gst.notes.manage'));

-- -----------------------------------------------------------------------------
-- public.issue_gst_note()
-- -----------------------------------------------------------------------------
create or replace function public.issue_gst_note(
  p_note_type          text,
  p_original_type      text,
  p_original_id        uuid,
  p_taxable_value      numeric,
  p_gst_rate           numeric,
  p_account_id         uuid,
  p_reason             text,
  p_description        text,
  p_note_date          date default current_date,
  p_party_note_number  text default null,
  p_itc_eligible       boolean default true,
  p_hsn_sac            text default null,
  p_idempotency_key    text default null
)
returns uuid
language plpgsql
as $$
declare
  v_dealer   uuid := app.current_dealer_id();
  v_existing uuid;
  v_branch   uuid;
  v_customer uuid;
  v_supplier uuid;
  v_number   text;
  v_date     date;
  v_taxable  numeric;
  v_inter    boolean;
  v_credited numeric;
  v_acc      public.chart_of_accounts;
  v_party    text;
  v_module   text;
  v_value    numeric := round(p_taxable_value, 2);
  v_cgst     numeric := 0;
  v_sgst     numeric := 0;
  v_igst     numeric := 0;
  v_tax      numeric;
  v_doc_type text;
  v_prefix   text;
  v_year     text;
  v_note     public.gst_notes;
  v_lines    jsonb := '[]'::jsonb;
  v_entry    uuid;
  v_hsn      text := nullif(btrim(coalesce(p_hsn_sac, '')), '');
  v_tax_acc  text;
begin
  if v_dealer is null or not app.has_permission('gst.notes.manage') then
    raise exception 'You do not have permission to issue credit or debit notes.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_idempotency_key is not null then
    select id into v_existing from public.gst_notes
     where dealer_id = v_dealer and idempotency_key = p_idempotency_key;
    if v_existing is not null then
      return v_existing;
    end if;
  end if;
  if p_note_type not in ('CREDIT', 'DEBIT') then
    raise exception 'A note is a credit note or a debit note.' using errcode = 'check_violation';
  end if;
  if not (v_value > 0) then
    raise exception 'Enter the value of the note.' using errcode = 'check_violation';
  end if;
  if p_gst_rate is null or p_gst_rate < 0 or p_gst_rate > 40 then
    raise exception 'Enter the GST rate of the original supply.' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_description), '') = '' then
    raise exception 'Say what the note is for.' using errcode = 'check_violation';
  end if;

  -- ── The document it amends ───────────────────────────────────────────────
  if p_original_type = 'SALE' then
    select s.branch_id, s.customer_id, s.invoice_number, s.invoice_date, s.taxable_value,
           s.igst_amount > 0 or (s.cgst_amount = 0 and s.place_of_supply is not null
                                 and s.place_of_supply <> b.state_code)
      into v_branch, v_customer, v_number, v_date, v_taxable, v_inter
      from public.sales s join public.branches b on b.id = s.branch_id
     where s.id = p_original_id and s.dealer_id = v_dealer and s.status in ('POSTED', 'DELIVERED');
    v_party := 'CUSTOMER'; v_module := 'SALES';
  elsif p_original_type = 'SERVICE_INVOICE' then
    select si.branch_id, si.customer_id, si.invoice_number, si.invoice_date, si.taxable_value,
           si.igst_amount > 0 or (si.cgst_amount = 0 and si.place_of_supply is not null
                                  and si.place_of_supply <> b.state_code)
      into v_branch, v_customer, v_number, v_date, v_taxable, v_inter
      from public.service_invoices si join public.branches b on b.id = si.branch_id
     where si.id = p_original_id and si.dealer_id = v_dealer and si.status = 'POSTED';
    v_party := 'CUSTOMER'; v_module := 'SERVICE';
  elsif p_original_type = 'PURCHASE_BILL' then
    select pb.branch_id, pb.supplier_id, pb.bill_number, pb.bill_date, pb.taxable_value,
           exists (select 1 from public.purchase_bill_lines l
                    where l.purchase_bill_id = pb.id and l.igst_amount > 0)
      into v_branch, v_supplier, v_number, v_date, v_taxable, v_inter
      from public.purchase_bills pb
     where pb.id = p_original_id and pb.dealer_id = v_dealer and pb.status = 'POSTED';
    v_party := 'SUPPLIER'; v_module := 'INVENTORY';
  else
    raise exception 'A note amends a sale, a service invoice or a purchase bill.'
      using errcode = 'check_violation';
  end if;

  if v_number is null then
    raise exception 'The document this note amends was not found, or is not posted.'
      using errcode = 'no_data_found';
  end if;
  if v_party = 'CUSTOMER' and v_customer is null then
    raise exception 'Invoice % has no customer; a note needs someone to issue it to.', v_number
      using errcode = 'check_violation';
  end if;
  if p_note_date < v_date then
    raise exception 'A note cannot be dated before the document it amends (%).', to_char(v_date, 'DD-MM-YYYY')
      using errcode = 'check_violation';
  end if;
  if p_note_date > current_date then
    raise exception 'A note cannot be dated in the future.' using errcode = 'check_violation';
  end if;
  if not app.can_access_branch(v_branch) then
    raise exception 'You do not have access to the branch that issued %.', v_number
      using errcode = 'insufficient_privilege';
  end if;

  -- Credit notes cannot take back more than was supplied.
  if p_note_type = 'CREDIT' then
    select coalesce(sum(taxable_value), 0) into v_credited
      from public.gst_notes
     where original_document_id = p_original_id and note_type = 'CREDIT' and status = 'POSTED';
    if v_credited + v_value > v_taxable then
      raise exception 'Credit notes on % would come to % against a taxable value of %.',
        v_number, v_credited + v_value, v_taxable using errcode = 'check_violation';
    end if;
  end if;

  -- ── The account the value goes to ────────────────────────────────────────
  select * into v_acc from public.chart_of_accounts where id = p_account_id and dealer_id = v_dealer;
  if v_acc.id is null or v_acc.is_group or v_acc.status <> 'ACTIVE' then
    raise exception 'Choose an active account from your chart of accounts.' using errcode = 'check_violation';
  end if;
  if (v_party = 'CUSTOMER' and v_acc.account_type not in ('INCOME', 'EXPENSE'))
     or (v_party = 'SUPPLIER' and v_acc.account_type not in ('EXPENSE', 'ASSET', 'INCOME'))
     or app.is_money_ledger(v_dealer, v_acc.id) then
    raise exception 'Account % % cannot carry the value of this note.', v_acc.code, v_acc.name
      using errcode = 'check_violation';
  end if;

  -- ── Tax, in the original's mode ──────────────────────────────────────────
  if v_inter then
    v_igst := round(v_value * p_gst_rate / 100, 2);
  else
    v_cgst := round(v_value * p_gst_rate / 200, 2);
    v_sgst := round(v_value * p_gst_rate / 200, 2);
  end if;
  v_tax := v_cgst + v_sgst + v_igst;

  if v_hsn is null and v_party = 'CUSTOMER' then
    select l.hsn_code into v_hsn from (
      select hsn_code, line_number from public.sale_lines where sale_id = p_original_id and hsn_code is not null
      union all
      select hsn_code, line_number from public.service_lines where invoice_id = p_original_id and hsn_code is not null
    ) l order by l.line_number limit 1;
  end if;

  -- ── Number ───────────────────────────────────────────────────────────────
  v_doc_type := case when v_party = 'CUSTOMER' then p_note_type || '_NOTE'
                     else 'SUPPLIER_' || p_note_type || '_NOTE' end;
  v_prefix := case v_doc_type when 'CREDIT_NOTE' then 'CN' when 'DEBIT_NOTE' then 'DBN'
                              when 'SUPPLIER_CREDIT_NOTE' then 'SCN' else 'SDN' end;
  v_year := app.financial_year_token(v_dealer, p_note_date);
  insert into public.document_sequences (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
  values (v_dealer, null, v_doc_type, v_year, v_prefix, 6)
  on conflict on constraint document_sequences_scope_key do nothing;

  insert into public.gst_notes
    (dealer_id, branch_id, note_number, note_type, party_type, customer_id, supplier_id,
     party_note_number, original_document_type, original_document_id, original_document_number,
     original_document_date, note_date, reason, description, account_id, hsn_sac, gst_rate,
     taxable_value, cgst_amount, sgst_amount, igst_amount, total_amount, itc_eligible,
     idempotency_key, created_by)
  values
    (v_dealer, v_branch, app.next_document_number(v_dealer, null, v_doc_type, v_year),
     p_note_type, v_party, v_customer, v_supplier,
     nullif(btrim(coalesce(p_party_note_number, '')), ''), p_original_type, p_original_id, v_number,
     v_date, p_note_date, coalesce(p_reason, 'OTHER'), btrim(p_description), p_account_id, v_hsn,
     p_gst_rate, v_value, v_cgst, v_sgst, v_igst, v_value + v_tax,
     case when v_party = 'SUPPLIER' then coalesce(p_itc_eligible, true) else true end,
     p_idempotency_key, auth.uid())
  returning * into v_note;

  -- ── Journal ──────────────────────────────────────────────────────────────
  -- Built as the entry that increases the party's balance (a debit note); a
  -- credit note is the same lines with the sides swapped.
  if v_party = 'CUSTOMER' then
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', app.require_account(v_dealer, v_module, 'INVOICE', 'RECEIVABLE', v_branch),
        'debit', v_note.total_amount, 'credit', 0, 'narration', v_note.note_number || ' on ' || v_number,
        'party_type', 'CUSTOMER', 'party_id', v_customer),
      jsonb_build_object('account_id', p_account_id, 'debit', 0, 'credit', v_value,
        'narration', v_note.description));
    foreach v_tax_acc in array array['CGST', 'SGST', 'IGST'] loop
      if (case v_tax_acc when 'CGST' then v_cgst when 'SGST' then v_sgst else v_igst end) > 0 then
        v_lines := v_lines || jsonb_build_object(
          'account_id', app.require_account(v_dealer, v_module, 'INVOICE', v_tax_acc, v_branch),
          'debit', 0, 'credit', case v_tax_acc when 'CGST' then v_cgst when 'SGST' then v_sgst else v_igst end,
          'narration', 'Output ' || v_tax_acc || ' ' || v_note.note_number);
      end if;
    end loop;
  else
    -- A supplier's debit note: more cost, more input tax, more owed.
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', p_account_id, 'debit',
        v_value + case when v_note.itc_eligible then 0 else v_tax end, 'credit', 0,
        'narration', v_note.description),
      jsonb_build_object('account_id', app.require_account(v_dealer, 'INVENTORY', 'PURCHASE', 'PAYABLE', v_branch),
        'debit', 0, 'credit', v_note.total_amount,
        'narration', v_note.note_number || ' on ' || v_number,
        'party_type', 'SUPPLIER', 'party_id', v_supplier));
    if v_note.itc_eligible then
      foreach v_tax_acc in array array['CGST', 'SGST', 'IGST'] loop
        if (case v_tax_acc when 'CGST' then v_cgst when 'SGST' then v_sgst else v_igst end) > 0 then
          v_lines := v_lines || jsonb_build_object(
            'account_id', app.require_account(v_dealer, 'INVENTORY', 'PURCHASE', 'INPUT_' || v_tax_acc, v_branch),
            'debit', case v_tax_acc when 'CGST' then v_cgst when 'SGST' then v_sgst else v_igst end, 'credit', 0,
            'narration', 'Input ' || v_tax_acc || ' ' || v_note.note_number);
        end if;
      end loop;
    end if;
  end if;

  if p_note_type = 'CREDIT' then
    select jsonb_agg(l || jsonb_build_object('debit', l->'credit', 'credit', l->'debit'))
      into v_lines from jsonb_array_elements(v_lines) l;
  end if;

  v_entry := app.post_journal(
    v_dealer, v_branch, p_note_date, v_module,
    initcap(lower(p_note_type)) || ' note ' || v_note.note_number || ' on ' || v_number,
    v_lines, 'GST_NOTE', v_note.id, 'gst-note:' || v_note.id::text);

  update public.gst_notes set journal_entry_id = v_entry where id = v_note.id;
  return v_note.id;
end;
$$;

comment on function public.issue_gst_note(text, text, uuid, numeric, numeric, uuid, text, text, date, text, boolean, text, text) is
  'Issues (to a customer) or records (from a supplier) a credit or debit note '
  'against a posted document, in that document''s tax mode, and posts it. '
  'Credit notes cannot exceed the original taxable value. Idempotent.';

create or replace function public.cancel_gst_note(p_note_id uuid, p_reason text)
returns uuid
language plpgsql
as $$
declare
  v_note  public.gst_notes;
  v_entry uuid;
begin
  if not app.has_permission('gst.notes.manage') then
    raise exception 'You do not have permission to cancel notes.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_note from public.gst_notes
   where id = p_note_id and dealer_id = app.current_dealer_id() for update;
  if v_note.id is null then
    raise exception 'Note not found.' using errcode = 'no_data_found';
  end if;
  if v_note.status = 'CANCELLED' then
    return v_note.cancel_journal_id;
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why the note is being cancelled.' using errcode = 'check_violation';
  end if;

  v_entry := app.reverse_journal(v_note.journal_entry_id, 'Cancelled ' || v_note.note_number || ': ' || btrim(p_reason), current_date);
  update public.gst_notes
     set status = 'CANCELLED', cancel_journal_id = v_entry, cancel_reason = btrim(p_reason)
   where id = p_note_id;
  return v_entry;
end;
$$;

-- -----------------------------------------------------------------------------
-- itc_adjustments — reversals and re-claims of input tax credit
-- -----------------------------------------------------------------------------
create table public.itc_adjustments (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null references public.dealers (id) on delete restrict,
  branch_id        uuid not null,
  adjustment_date  date not null,
  direction        text not null,
  rule             text not null,
  purchase_bill_id uuid,
  cgst_amount      numeric(18, 4) not null default 0,
  sgst_amount      numeric(18, 4) not null default 0,
  igst_amount      numeric(18, 4) not null default 0,
  total_amount     numeric(18, 4) generated always as (cgst_amount + sgst_amount + igst_amount) stored,
  note             text not null,
  journal_entry_id uuid,
  idempotency_key  text,
  created_by       uuid,
  created_at       timestamptz not null default now(),

  constraint itc_adj_idempotency_key unique (dealer_id, idempotency_key),
  constraint itc_adj_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint itc_adj_bill_tenant_fkey
    foreign key (purchase_bill_id, dealer_id) references public.purchase_bills (id, dealer_id),
  constraint itc_adj_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint itc_adj_direction_check check (direction in ('REVERSAL', 'RECLAIM')),
  constraint itc_adj_rule_check check (rule in ('RULE_37', 'RULE_42', 'RULE_43', 'SECTION_17_5', 'OTHER')),
  constraint itc_adj_amounts_check check (
    cgst_amount >= 0 and sgst_amount >= 0 and igst_amount >= 0
    and cgst_amount + sgst_amount + igst_amount > 0)
);

comment on table public.itc_adjustments is
  'Input tax credit reversed (rule 37, 42, 43, s.17(5)) and re-claimed, each '
  'posted ITC ⇄ 5990. GSTR-3B table 4(B) reads the reversals, 4(A)(5) the re-claims.';

create index itc_adj_dealer_date_idx on public.itc_adjustments (dealer_id, adjustment_date);
create index itc_adj_bill_idx on public.itc_adjustments (purchase_bill_id) where purchase_bill_id is not null;

-- Append-only: the one write after insert is the journal link, once.
create or replace function app.itc_adjustments_append_only()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' or old.journal_entry_id is not null
     -- total_amount is generated, and not yet computed in a BEFORE trigger.
     or (to_jsonb(new) - 'journal_entry_id' - 'total_amount')
        is distinct from (to_jsonb(old) - 'journal_entry_id' - 'total_amount') then
    raise exception 'An ITC adjustment is permanent; record the opposite adjustment instead.'
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;

create trigger itc_adjustments_append_only
  before update or delete on public.itc_adjustments
  for each row execute function app.itc_adjustments_append_only();

alter table public.itc_adjustments enable row level security;
create policy itc_adj_select on public.itc_adjustments for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('gst.reports.view') or app.has_permission('gst.itc.manage'))));
create policy itc_adj_insert on public.itc_adjustments for insert to authenticated
  with check (dealer_id = app.current_dealer_id() and app.has_permission('gst.itc.manage'));
create policy itc_adj_update on public.itc_adjustments for update to authenticated
  using (dealer_id = app.current_dealer_id() and app.has_permission('gst.itc.manage'))
  with check (dealer_id = app.current_dealer_id() and app.has_permission('gst.itc.manage'));

create or replace function public.record_itc_adjustment(
  p_direction        text,
  p_rule             text,
  p_branch_id        uuid,
  p_cgst             numeric,
  p_sgst             numeric,
  p_igst             numeric,
  p_note             text,
  p_date             date default current_date,
  p_purchase_bill_id uuid default null,
  p_idempotency_key  text default null
)
returns uuid
language plpgsql
as $$
declare
  v_dealer   uuid := app.current_dealer_id();
  v_existing uuid;
  v_adj      public.itc_adjustments;
  v_reversed numeric;
  v_claimed  numeric;
  v_lines    jsonb := '[]'::jsonb;
  v_head     text;
  v_amount   numeric;
  v_entry    uuid;
  v_input    numeric := 0;
begin
  if v_dealer is null or not app.has_permission('gst.itc.manage') then
    raise exception 'You do not have permission to adjust input tax credit.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_idempotency_key is not null then
    select id into v_existing from public.itc_adjustments
     where dealer_id = v_dealer and idempotency_key = p_idempotency_key;
    if v_existing is not null then return v_existing; end if;
  end if;
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'Say why the credit is being adjusted.' using errcode = 'check_violation';
  end if;
  if not app.can_access_branch(p_branch_id) then
    raise exception 'You do not have access to that branch.' using errcode = 'insufficient_privilege';
  end if;
  if p_purchase_bill_id is not null and not exists (
       select 1 from public.purchase_bills where id = p_purchase_bill_id and dealer_id = v_dealer and status = 'POSTED') then
    raise exception 'That purchase bill is not posted.' using errcode = 'no_data_found';
  end if;

  -- A re-claim gives back credit that was taken away, never more.
  if p_direction = 'RECLAIM' then
    select coalesce(sum(total_amount) filter (where direction = 'REVERSAL'), 0),
           coalesce(sum(total_amount) filter (where direction = 'RECLAIM'), 0)
      into v_reversed, v_claimed
      from public.itc_adjustments
     where dealer_id = v_dealer and rule = p_rule
       and purchase_bill_id is not distinct from p_purchase_bill_id;
    if v_claimed + coalesce(p_cgst, 0) + coalesce(p_sgst, 0) + coalesce(p_igst, 0) > v_reversed then
      raise exception 'Only % of credit reversed under % is left to re-claim.',
        v_reversed - v_claimed, replace(p_rule, '_', ' ') using errcode = 'check_violation';
    end if;
  end if;

  insert into public.itc_adjustments
    (dealer_id, branch_id, adjustment_date, direction, rule, purchase_bill_id,
     cgst_amount, sgst_amount, igst_amount, note, idempotency_key, created_by)
  values
    (v_dealer, p_branch_id, p_date, p_direction, p_rule, p_purchase_bill_id,
     round(coalesce(p_cgst, 0), 2), round(coalesce(p_sgst, 0), 2), round(coalesce(p_igst, 0), 2),
     btrim(p_note), p_idempotency_key, auth.uid())
  returning * into v_adj;

  foreach v_head in array array['CGST', 'SGST', 'IGST'] loop
    v_amount := case v_head when 'CGST' then v_adj.cgst_amount when 'SGST' then v_adj.sgst_amount
                            else v_adj.igst_amount end;
    if v_amount > 0 then
      v_lines := v_lines || jsonb_build_object(
        'account_id', app.require_account(v_dealer, 'INVENTORY', 'PURCHASE', 'INPUT_' || v_head, p_branch_id),
        'debit',  case when p_direction = 'RECLAIM' then v_amount else 0 end,
        'credit', case when p_direction = 'REVERSAL' then v_amount else 0 end,
        'narration', initcap(lower(p_direction)) || ' of input ' || v_head);
      v_input := v_input + v_amount;
    end if;
  end loop;
  v_lines := v_lines || jsonb_build_object(
    'account_id', app.require_account(v_dealer, 'EXPENSE', 'ITC', 'REVERSED', p_branch_id),
    'debit',  case when p_direction = 'REVERSAL' then v_input else 0 end,
    'credit', case when p_direction = 'RECLAIM' then v_input else 0 end,
    'narration', btrim(p_note));

  v_entry := app.post_journal(
    v_dealer, p_branch_id, p_date, 'EXPENSE',
    'ITC ' || lower(p_direction) || ' — ' || replace(p_rule, '_', ' ') || ': ' || btrim(p_note),
    v_lines, 'ITC_ADJUSTMENT', v_adj.id, 'itc-adjustment:' || v_adj.id::text);

  update public.itc_adjustments set journal_entry_id = v_entry where id = v_adj.id;
  return v_adj.id;
end;
$$;

comment on function public.record_itc_adjustment(text, text, uuid, numeric, numeric, numeric, text, date, uuid, text) is
  'Reverses or re-claims input tax credit and posts it (ITC ⇄ 5990). A re-claim '
  'may not exceed what was reversed under the same rule and bill. Idempotent.';

-- Rule 37: credit on a bill not paid within 180 days is reversed until it is.
-- Payments are applied oldest bill first, so what a supplier is still owed sits
-- on the newest bills; a bill older than 180 days that still carries any of it
-- has that share of its credit due for reversal, less what is already reversed.
create or replace function public.itc_rule37_candidates(p_as_on date default current_date)
returns table (
  purchase_bill_id uuid,
  bill_number      text,
  supplier_bill_number text,
  supplier_name    text,
  branch_id        uuid,
  bill_date        date,
  days_outstanding integer,
  bill_total       numeric(18, 4),
  unpaid           numeric(18, 4),
  cgst_due         numeric(18, 4),
  sgst_due         numeric(18, 4),
  igst_due         numeric(18, 4)
)
language sql
stable
as $$
  with owed as (
    select l.party_id as supplier_id, sum(l.credit - l.debit) as outstanding
      from public.journal_entry_lines l
      join public.journal_entries je on je.id = l.journal_entry_id
     where l.party_type = 'SUPPLIER' and je.status in ('POSTED', 'REVERSED')
       and je.entry_date <= p_as_on and je.dealer_id = app.current_dealer_id()
     group by l.party_id
  ),
  bills as (
    select b.*, s.name as supplier_name,
           sum(b.total_amount) over (partition by b.supplier_id
                                      order by b.bill_date desc, b.bill_number desc
                                      rows unbounded preceding) - b.total_amount as newer
      from public.purchase_bills b
      join public.suppliers s on s.id = b.supplier_id
     where b.status = 'POSTED' and b.bill_date <= p_as_on and b.dealer_id = app.current_dealer_id()
  ),
  unpaid as (
    select b.*, greatest(0, least(b.total_amount, coalesce(o.outstanding, 0) - b.newer)) as unpaid_amt
      from bills b left join owed o on o.supplier_id = b.supplier_id
  ),
  credit as (
    select l.purchase_bill_id,
           sum(l.cgst_amount) as cgst, sum(l.sgst_amount) as sgst, sum(l.igst_amount) as igst
      from public.purchase_bill_lines l
     where l.itc_eligible and not l.reverse_charge
     group by l.purchase_bill_id
  ),
  done as (
    select a.purchase_bill_id,
           sum(case when a.direction = 'REVERSAL' then a.cgst_amount else -a.cgst_amount end) as cgst,
           sum(case when a.direction = 'REVERSAL' then a.sgst_amount else -a.sgst_amount end) as sgst,
           sum(case when a.direction = 'REVERSAL' then a.igst_amount else -a.igst_amount end) as igst
      from public.itc_adjustments a
     where a.rule = 'RULE_37' and a.purchase_bill_id is not null
     group by a.purchase_bill_id
  )
  select u.id, u.bill_number, u.supplier_bill_number, u.supplier_name, u.branch_id, u.bill_date,
         (p_as_on - u.bill_date)::integer, u.total_amount, u.unpaid_amt,
         greatest(0, round(c.cgst * u.unpaid_amt / u.total_amount, 2) - coalesce(d.cgst, 0)),
         greatest(0, round(c.sgst * u.unpaid_amt / u.total_amount, 2) - coalesce(d.sgst, 0)),
         greatest(0, round(c.igst * u.unpaid_amt / u.total_amount, 2) - coalesce(d.igst, 0))
    from unpaid u
    join credit c on c.purchase_bill_id = u.id
    left join done d on d.purchase_bill_id = u.id
   where u.bill_date <= p_as_on - 180
     and u.unpaid_amt > 0
     and greatest(0, round(c.cgst * u.unpaid_amt / u.total_amount, 2) - coalesce(d.cgst, 0))
       + greatest(0, round(c.sgst * u.unpaid_amt / u.total_amount, 2) - coalesce(d.sgst, 0))
       + greatest(0, round(c.igst * u.unpaid_amt / u.total_amount, 2) - coalesce(d.igst, 0)) > 0
   order by u.bill_date;
$$;

-- -----------------------------------------------------------------------------
-- Reports
-- -----------------------------------------------------------------------------
-- Outward and inward supplies by category — GSTR-3B 3.1(a)(b)(c)(e) and 5.
create or replace function public.gst_supply_categories(
  p_from date, p_to date, p_branch_id uuid default null
)
returns table (
  direction      text,
  tax_category   text,
  document_count bigint,
  taxable_value  numeric(18, 4),
  total_tax      numeric(18, 4)
)
language sql
stable
as $$
  with lines as (
    select 'OUTWARD'::text as dir,
           app.supply_category(s.dealer_id, l.tax_code, s.invoice_date,
                               l.cgst_amount + l.sgst_amount + l.igst_amount) as cat,
           s.id as doc, l.taxable_value, l.cgst_amount + l.sgst_amount + l.igst_amount as tax
      from public.sale_lines l join public.sales s on s.id = l.sale_id
     where s.status in ('POSTED', 'DELIVERED') and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select 'OUTWARD',
           app.supply_category(si.dealer_id, l.tax_code, si.invoice_date,
                               l.cgst_amount + l.sgst_amount + l.igst_amount),
           si.id, l.taxable_value, l.cgst_amount + l.sgst_amount + l.igst_amount
      from public.service_lines l join public.service_invoices si on si.id = l.invoice_id
     where si.status = 'POSTED' and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
    union all
    select 'INWARD', l.tax_category, b.id, l.taxable_value,
           l.cgst_amount + l.sgst_amount + l.igst_amount
      from public.purchase_bill_lines l join public.purchase_bills b on b.id = l.purchase_bill_id
     where b.status = 'POSTED' and b.bill_date between p_from and p_to
       and (p_branch_id is null or b.branch_id = p_branch_id)
  )
  select dir, cat, count(distinct doc), sum(taxable_value), sum(tax)
    from lines
   group by dir, cat
   order by dir desc, cat;
$$;

-- GSTR-1: notes to registered customers are CDNR, to others CDNUR; a credit
-- note is shown negative so each section nets to what is owed.
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
    select case when nullif(btrim(coalesce(c.gstin, '')), '') is not null then 'B2B' else 'B2C' end as section,
           s.id, s.taxable_value, s.cgst_amount, s.sgst_amount, s.igst_amount, s.total_amount
      from public.sales s
      left join public.customers c on c.id = s.customer_id
     where s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select case when nullif(btrim(coalesce(c.gstin, '')), '') is not null then 'B2B' else 'B2C' end,
           si.id, si.taxable_value, si.cgst_amount, si.sgst_amount, si.igst_amount, si.total_amount
      from public.service_invoices si
      left join public.customers c on c.id = si.customer_id
     where si.status = 'POSTED'
       and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
    union all
    select case when nullif(btrim(coalesce(c.gstin, '')), '') is not null then 'CDNR' else 'CDNUR' end,
           n.id,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.taxable_value,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.cgst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.sgst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.igst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.total_amount
      from public.gst_notes n
      join public.customers c on c.id = n.customer_id
     where n.party_type = 'CUSTOMER' and n.status = 'POSTED'
       and n.note_date between p_from and p_to
       and (p_branch_id is null or n.branch_id = p_branch_id)
  )
  select docs.section, count(*), sum(docs.taxable_value), sum(docs.cgst_amount), sum(docs.sgst_amount),
         sum(docs.igst_amount), sum(docs.cgst_amount + docs.sgst_amount + docs.igst_amount),
         sum(docs.total_amount)
    from docs
   group by 1
   order by 1;
$$;

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
           s.taxable_value, s.cgst_amount, s.sgst_amount, s.igst_amount, s.total_amount,
           case when nullif(btrim(coalesce(c.gstin, '')), '') is not null then 'B2B' else 'B2C' end as sect
      from public.sales s
      left join public.customers c on c.id = s.customer_id
     where s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select 'SERVICE_INVOICE', si.id, si.invoice_number, si.invoice_date,
           coalesce(c.name, 'Counter sale'), c.gstin, c.state,
           si.taxable_value, si.cgst_amount, si.sgst_amount, si.igst_amount, si.total_amount,
           case when nullif(btrim(coalesce(c.gstin, '')), '') is not null then 'B2B' else 'B2C' end
      from public.service_invoices si
      left join public.customers c on c.id = si.customer_id
     where si.status = 'POSTED'
       and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
    union all
    select n.note_type || '_NOTE', n.id, n.note_number, n.note_date,
           c.name, c.gstin, c.state,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.taxable_value,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.cgst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.sgst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.igst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.total_amount,
           case when nullif(btrim(coalesce(c.gstin, '')), '') is not null then 'CDNR' else 'CDNUR' end
      from public.gst_notes n
      join public.customers c on c.id = n.customer_id
     where n.party_type = 'CUSTOMER' and n.status = 'POSTED'
       and n.note_date between p_from and p_to
       and (p_branch_id is null or n.branch_id = p_branch_id)
  )
  select d.dtype, d.id, d.invoice_number, d.invoice_date, d.cname, d.gstin, d.pos, d.sect,
         d.taxable_value, d.cgst_amount, d.sgst_amount, d.igst_amount, d.total_amount,
         coalesce(e.status, 'NOT_REQUESTED'), e.irn
    from docs d
    left join public.einvoices e on e.document_type = d.dtype and e.document_id = d.id
   where p_section is null or p_section = d.sect
   order by d.invoice_date, d.invoice_number;
$$;

-- HSN summary: customer notes net against the HSN they amend.
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
    union all
    select coalesce(n.hsn_sac, 'UNSPECIFIED'), n.dealer_id,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.taxable_value,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.cgst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.sgst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.igst_amount,
           n.id
      from public.gst_notes n
     where n.party_type = 'CUSTOMER' and n.status = 'POSTED'
       and n.note_date between p_from and p_to
       and (p_branch_id is null or n.branch_id = p_branch_id)
  )
  select lines.hsn,
         coalesce(max(h.description), ''),
         sum(lines.taxable_value), sum(lines.cgst_amount), sum(lines.sgst_amount),
         sum(lines.igst_amount),
         sum(lines.cgst_amount + lines.sgst_amount + lines.igst_amount),
         count(distinct lines.doc)
    from lines
    left join public.hsn_codes h
      on h.code = lines.hsn and h.dealer_id = lines.dealer_id
   group by lines.hsn
   order by lines.hsn;
$$;

-- Input tax: supplier notes adjust the credit they amend (when it was claimable).
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
    select coalesce(h.code, l.hsn_sac, 'UNSPECIFIED') as hsn,
           coalesce(h.description, case when l.line_type = 'EXPENSE' then c.name end, '') as descr,
           l.taxable_value, l.cgst_amount, l.sgst_amount, l.igst_amount,
           b.id as doc
      from public.purchase_bill_lines l
      join public.purchase_bills b on b.id = l.purchase_bill_id
      left join public.inventory_items i on i.id = l.item_id
      left join public.vehicles v on v.id = l.vehicle_id
      left join public.vehicle_models m on m.id = v.model_id
      left join public.hsn_codes h on h.id = coalesce(i.hsn_code_id, m.hsn_code_id)
      left join public.chart_of_accounts c on c.id = l.account_id
     where b.status = 'POSTED'
       and l.itc_eligible
       and b.bill_date between p_from and p_to
       and (p_branch_id is null or b.branch_id = p_branch_id)

    union all

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

    union all

    select coalesce(n.hsn_sac, 'UNSPECIFIED'), coalesce(c.name, ''),
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.taxable_value,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.cgst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.sgst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.igst_amount,
           n.id
      from public.gst_notes n
      left join public.chart_of_accounts c on c.id = n.account_id
     where n.party_type = 'SUPPLIER' and n.status = 'POSTED' and n.itc_eligible
       and n.note_date between p_from and p_to
       and (p_branch_id is null or n.branch_id = p_branch_id)
  )
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

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;
  execute 'grant select, insert, update on public.gst_notes to authenticated';
  execute 'grant select, insert, update on public.itc_adjustments to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0084', 'gst_categories_notes_rcm_itc') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0085_gst_returns_2b_3b.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0085 — GST returns: GSTR-2B matching, ITC claims, GSTR-3B, cross-checks,
--        filing evidence
-- =============================================================================
-- Spec §40, §41, §46. Audit checklist §08 (input tax, 2B), §09 (returns:
-- GSTR-1, GSTR-3B, reconciliation, filing evidence; Tests C and D).
--
-- The product computed GSTR-1 style figures and stopped there. Nothing said
-- what had actually been filed, whether the ITC in the books had reached the
-- supplier-side statement (GSTR-2B), how much of it could be claimed, what the
-- 3B came to after set-off, or whether GSTR-1, GSTR-3B and the ledger agreed.
--
-- ── Outward documents ──────────────────────────────────────────────────────
--
-- app.gst_outward_documents() is the one list the returns read: sales,
-- service and counter invoices, credit/debit notes to customers (signed), and
-- branch-transfer tax invoices between two GSTINs (a supply from the sending
-- GSTIN). gstr1_summary() and gst_document_register() now read it too, so
-- transfer invoices reach GSTR-1. Every return is per GSTIN: a branch files
-- under its own GSTIN, or the dealer's when it has none.
--
-- ── GSTR-2B ────────────────────────────────────────────────────────────────
--
-- A month's 2B is imported as lines (supplier GSTIN, document number, date,
-- values) and matched to posted purchase bills and supplier notes by supplier
-- GSTIN and normalised document number. Each 2B line is MATCHED,
-- VALUE_MISMATCH, NOT_IN_BOOKS or NOT_CLAIMABLE (the books say the credit is
-- blocked or personal, so it is never claimed automatically, 2B or not); each
-- bill of the month the 2B does not carry is NOT_IN_2B. A re-import supersedes
-- the earlier one.
--
-- ── ITC claim controls (rule 36(4)) ────────────────────────────────────────
--
-- Credit on a bill is claimable in 3B only once the bill is in a 2B, and then
-- at the lower of the books and the 2B, head by head. Reverse-charge credit
-- needs no 2B (the dealer paid it). Supplier credit notes reduce the claim
-- whether or not they are in 2B. When a 3B is filed, what it claimed is written
-- to itc_claim_lines, so nothing is claimed twice.
--
-- ── GSTR-3B ────────────────────────────────────────────────────────────────
--
-- gstr3b_working() lays out 3.1, 4 and 5; gstr3b_setoff() applies the credit
-- in the order rule 88A requires (IGST first — against IGST, then CGST, then
-- SGST; then CGST against CGST then IGST; SGST against SGST then IGST; CGST and
-- SGST never cross) and gives the cash payable per head. Reverse-charge tax is
-- always paid in cash. post_gst_setoff() posts the result once filed.
--
-- ── Filing and evidence ────────────────────────────────────────────────────
--
-- gst_returns records each return: PREPARED (a snapshot of the system's
-- figures), SIGNED_OFF (by someone other than the preparer), FILED (ARN, date,
-- the figures actually filed, challan). A filed return is permanent; GSTR-1's
-- documents are frozen with it, and gstr1_amendments() later lists any that
-- changed, were cancelled or were missed — the next GSTR-1's amendments.
-- gst_cross_checks() compares GSTR-1, GSTR-3B, 2B and the ledger and flags any
-- difference; the filed return and its challan attach as 'GST_FILING'.
--
-- Rollback: drop the tables and functions created here; restore gstr1_summary
--           and gst_document_register from 0084.
-- =============================================================================

insert into public.permissions (code, module, description, is_sensitive) values
  ('gst.returns.prepare', 'gst', 'Import GSTR-2B and prepare GST returns', false),
  ('gst.returns.file',    'gst', 'Sign off and record the filing of GST returns', false)
on conflict (code) do update set module = excluded.module, description = excluded.description,
                                 is_sensitive = excluded.is_sensitive;

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join (values ('gst.returns.prepare'), ('gst.returns.file')) as p(code)
 where r.is_system and r.code in ('DEALER_OWNER', 'ACCOUNTS')
on conflict do nothing;

-- The GSTIN a branch files under.
create or replace function app.branch_gstin(p_branch_id uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(nullif(btrim(b.gstin), ''), nullif(btrim(d.gstin), ''))
    from public.branches b join public.dealers d on d.id = b.dealer_id
   where b.id = p_branch_id;
$$;

create or replace function app.norm_doc_no(p text)
returns text
language sql
immutable
as $$
  select nullif(ltrim(upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')), '0'), '');
$$;

create or replace function app.month_end(p_period date)
returns date
language sql
immutable
as $$
  select (date_trunc('month', p_period) + interval '1 month - 1 day')::date;
$$;

-- -----------------------------------------------------------------------------
-- app.gst_outward_documents()
-- -----------------------------------------------------------------------------
create or replace function app.gst_outward_documents(p_from date, p_to date, p_gstin text default null)
returns table (
  document_type   text,
  document_id     uuid,
  document_number text,
  document_date   date,
  branch_id       uuid,
  party_name      text,
  party_gstin     text,
  place_of_supply text,
  section         text,
  taxable_value   numeric(18, 4),
  cgst_amount     numeric(18, 4),
  sgst_amount     numeric(18, 4),
  igst_amount     numeric(18, 4),
  total_amount    numeric(18, 4)
)
language sql
stable
as $$
  with docs as (
    select 'SALE'::text as dtype, s.id, s.invoice_number as num, s.invoice_date as ddate, s.branch_id as br,
           coalesce(c.name, 'Cash customer') as pname, nullif(btrim(coalesce(c.gstin, '')), '') as pgstin,
           coalesce(s.place_of_supply, c.state_code) as pos,
           s.taxable_value as tv, s.cgst_amount as cg, s.sgst_amount as sg, s.igst_amount as ig, s.total_amount as tot,
           false as is_note
      from public.sales s
      left join public.customers c on c.id = s.customer_id
     where s.dealer_id = app.current_dealer_id()
       and s.status in ('POSTED', 'DELIVERED') and s.invoice_date between p_from and p_to
    union all
    select 'SERVICE_INVOICE', si.id, si.invoice_number, si.invoice_date, si.branch_id,
           coalesce(c.name, 'Counter sale'), nullif(btrim(coalesce(c.gstin, '')), ''),
           coalesce(si.place_of_supply, c.state_code),
           si.taxable_value, si.cgst_amount, si.sgst_amount, si.igst_amount, si.total_amount, false
      from public.service_invoices si
      left join public.customers c on c.id = si.customer_id
     where si.dealer_id = app.current_dealer_id()
       and si.status = 'POSTED' and si.invoice_date between p_from and p_to
    union all
    select n.note_type || '_NOTE', n.id, n.note_number, n.note_date, n.branch_id,
           c.name, nullif(btrim(coalesce(c.gstin, '')), ''), c.state_code,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.taxable_value,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.cgst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.sgst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.igst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.total_amount, true
      from public.gst_notes n
      join public.customers c on c.id = n.customer_id
     where n.dealer_id = app.current_dealer_id()
       and n.party_type = 'CUSTOMER' and n.status = 'POSTED' and n.note_date between p_from and p_to
    union all
    -- A transfer between two GSTINs is a supply by the sending one.
    select 'TRANSFER_INVOICE', t.id, t.note_number, t.note_date, t.from_branch_id,
           b.name, t.to_gstin, left(t.to_gstin, 2),
           t.taxable_value, t.cgst_amount, t.sgst_amount, t.igst_amount,
           t.taxable_value + t.cgst_amount + t.sgst_amount + t.igst_amount, false
      from public.branch_transfer_notes t
      join public.branches b on b.id = t.to_branch_id
     where t.dealer_id = app.current_dealer_id()
       and t.note_kind = 'TAX_INVOICE' and t.note_date between p_from and p_to
  )
  select d.dtype, d.id, d.num, d.ddate, d.br, d.pname, d.pgstin, d.pos,
         case when d.is_note then (case when d.pgstin is not null then 'CDNR' else 'CDNUR' end)
              when d.pgstin is not null then 'B2B' else 'B2C' end,
         d.tv, d.cg, d.sg, d.ig, d.tot
    from docs d
   where p_gstin is null or app.branch_gstin(d.br) = p_gstin;
$$;

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
  select d.section, count(*), sum(d.taxable_value), sum(d.cgst_amount), sum(d.sgst_amount),
         sum(d.igst_amount), sum(d.cgst_amount + d.sgst_amount + d.igst_amount), sum(d.total_amount)
    from app.gst_outward_documents(p_from, p_to) d
   where p_branch_id is null or d.branch_id = p_branch_id
   group by d.section
   order by d.section;
$$;

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
  select d.document_type, d.document_id, d.document_number, d.document_date, d.party_name,
         d.party_gstin, d.place_of_supply, d.section,
         d.taxable_value, d.cgst_amount, d.sgst_amount, d.igst_amount, d.total_amount,
         coalesce(e.status, 'NOT_REQUESTED'), e.irn
    from app.gst_outward_documents(p_from, p_to) d
    left join public.einvoices e on e.document_type = d.document_type and e.document_id = d.document_id
   where (p_branch_id is null or d.branch_id = p_branch_id)
     and (p_section is null or p_section = d.section)
   order by d.document_date, d.document_number;
$$;

-- -----------------------------------------------------------------------------
-- gst_returns — what was prepared, signed off and filed
-- -----------------------------------------------------------------------------
create table public.gst_returns (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null references public.dealers (id) on delete restrict,
  gstin            text not null,
  return_type      text not null,
  period           date not null,
  status           text not null default 'PREPARED',
  computed         jsonb not null,
  prepared_by      uuid,
  prepared_at      timestamptz not null default now(),
  signed_off_by    uuid,
  signed_off_at    timestamptz,
  -- As filed on the portal. For GSTR-1 the output figures; for GSTR-3B also
  -- the credit claimed.
  filed_taxable    numeric(18, 4),
  filed_igst       numeric(18, 4),
  filed_cgst       numeric(18, 4),
  filed_sgst       numeric(18, 4),
  filed_itc_igst   numeric(18, 4),
  filed_itc_cgst   numeric(18, 4),
  filed_itc_sgst   numeric(18, 4),
  arn              text,
  filed_on         date,
  filed_by         uuid,
  filed_at         timestamptz,
  challan_cpin     text,
  challan_cin      text,
  challan_amount   numeric(18, 4),
  setoff_journal_id uuid,
  notes            text,

  constraint gst_returns_scope_key unique (dealer_id, gstin, return_type, period),
  constraint gst_returns_journal_tenant_fkey
    foreign key (setoff_journal_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint gst_returns_type_check   check (return_type in ('GSTR1', 'GSTR3B')),
  constraint gst_returns_status_check check (status in ('PREPARED', 'SIGNED_OFF', 'FILED')),
  constraint gst_returns_period_check check (period = date_trunc('month', period)::date),
  constraint gst_returns_gstin_check  check (gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z]Z[0-9A-Z]$'),
  constraint gst_returns_filed_check  check (
    status <> 'FILED' or (arn is not null and filed_on is not null and signed_off_by is not null)),
  constraint gst_returns_arn_check    check (arn is null or length(btrim(arn)) between 5 and 30),
  -- Maker and checker are different people.
  constraint gst_returns_four_eyes_check check (signed_off_by is null or signed_off_by <> prepared_by)
);

comment on table public.gst_returns is
  'GST returns per GSTIN and month: the system''s figures when prepared, who '
  'signed off, and what was filed (ARN, figures, challan). A filed return is '
  'permanent; its evidence attaches as GST_FILING.';

create or replace function app.gst_returns_guard()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    if old.status = 'FILED' then
      raise exception 'A filed return cannot be deleted.' using errcode = 'insufficient_privilege';
    end if;
    return old;
  end if;
  if old.status = 'FILED'
     and (to_jsonb(new) - 'setoff_journal_id') is distinct from (to_jsonb(old) - 'setoff_journal_id') then
    raise exception 'The % for % is filed and cannot be changed.', old.return_type, to_char(old.period, 'Mon YYYY')
      using errcode = 'insufficient_privilege';
  end if;
  if old.setoff_journal_id is not null and new.setoff_journal_id is distinct from old.setoff_journal_id then
    raise exception 'The set-off of this return is already posted.' using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;

create trigger gst_returns_guard
  before update or delete on public.gst_returns
  for each row execute function app.gst_returns_guard();
create trigger gst_returns_audit after insert or update or delete on public.gst_returns
  for each row execute function app.audit_trigger();

-- The documents a filed GSTR-1 reported, as they stood.
create table public.gst_filed_documents (
  id              uuid primary key default gen_random_uuid(),
  return_id       uuid not null references public.gst_returns (id) on delete restrict,
  dealer_id       uuid not null,
  document_type   text not null,
  document_id     uuid not null,
  document_number text not null,
  document_date   date not null,
  party_gstin     text,
  place_of_supply text,
  section         text not null,
  taxable_value   numeric(18, 4) not null,
  cgst_amount     numeric(18, 4) not null,
  sgst_amount     numeric(18, 4) not null,
  igst_amount     numeric(18, 4) not null,
  total_amount    numeric(18, 4) not null,
  constraint gfd_return_document_key unique (return_id, document_type, document_id)
);
create index gfd_document_idx on public.gst_filed_documents (document_id);

-- -----------------------------------------------------------------------------
-- GSTR-2B
-- -----------------------------------------------------------------------------
create table public.gstr2b_imports (
  id          uuid primary key default gen_random_uuid(),
  dealer_id   uuid not null references public.dealers (id) on delete restrict,
  gstin       text not null,
  period      date not null,
  file_name   text,
  line_count  integer not null default 0,
  status      text not null default 'ACTIVE',
  imported_by uuid,
  imported_at timestamptz not null default now(),
  constraint gstr2b_imports_status_check check (status in ('ACTIVE', 'SUPERSEDED')),
  constraint gstr2b_imports_period_check check (period = date_trunc('month', period)::date),
  constraint gstr2b_imports_id_dealer_key unique (id, dealer_id)
);
create unique index gstr2b_imports_active_key
  on public.gstr2b_imports (dealer_id, gstin, period) where status = 'ACTIVE';

create table public.gstr2b_lines (
  id               uuid primary key default gen_random_uuid(),
  import_id        uuid not null,
  dealer_id        uuid not null,
  supplier_gstin   text not null,
  supplier_name    text,
  document_type    text not null default 'INVOICE',
  document_number  text not null,
  document_date    date,
  taxable_value    numeric(18, 4) not null default 0,
  igst_amount      numeric(18, 4) not null default 0,
  cgst_amount      numeric(18, 4) not null default 0,
  sgst_amount      numeric(18, 4) not null default 0,
  cess_amount      numeric(18, 4) not null default 0,
  itc_available    boolean not null default true,
  reverse_charge   boolean not null default false,
  match_status     text not null default 'NOT_IN_BOOKS',
  matched_bill_id  uuid,
  matched_note_id  uuid,
  books_taxable    numeric(18, 4),
  books_tax        numeric(18, 4),
  constraint gstr2b_lines_import_fkey
    foreign key (import_id, dealer_id) references public.gstr2b_imports (id, dealer_id) on delete restrict,
  constraint gstr2b_lines_type_check   check (document_type in ('INVOICE', 'CREDIT_NOTE', 'DEBIT_NOTE')),
  constraint gstr2b_lines_status_check check (match_status in ('MATCHED', 'VALUE_MISMATCH', 'NOT_IN_BOOKS', 'NOT_CLAIMABLE')),
  constraint gstr2b_lines_gstin_check  check (supplier_gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z]Z[0-9A-Z]$'),
  constraint gstr2b_lines_amounts_check check (
    taxable_value >= 0 and igst_amount >= 0 and cgst_amount >= 0 and sgst_amount >= 0 and cess_amount >= 0)
);
create index gstr2b_lines_import_idx on public.gstr2b_lines (import_id);
create index gstr2b_lines_bill_idx on public.gstr2b_lines (matched_bill_id) where matched_bill_id is not null;

-- What a filed 3B claimed, document by document, so no credit is taken twice.
create table public.itc_claim_lines (
  id               uuid primary key default gen_random_uuid(),
  return_id        uuid not null references public.gst_returns (id) on delete restrict,
  dealer_id        uuid not null,
  claim_kind       text not null,
  purchase_bill_id uuid,
  gst_note_id      uuid,
  igst_amount      numeric(18, 4) not null default 0,
  cgst_amount      numeric(18, 4) not null default 0,
  sgst_amount      numeric(18, 4) not null default 0,
  constraint itc_claim_kind_check check (claim_kind in ('INVOICE', 'RCM', 'CREDIT_NOTE', 'DEBIT_NOTE')),
  constraint itc_claim_doc_check check ((purchase_bill_id is null) <> (gst_note_id is null))
);
create unique index itc_claim_bill_key on public.itc_claim_lines (purchase_bill_id, claim_kind) where purchase_bill_id is not null;
create unique index itc_claim_note_key on public.itc_claim_lines (gst_note_id) where gst_note_id is not null;

-- Evidence tables are append-only.
create or replace function app.gst_evidence_append_only()
returns trigger
language plpgsql
as $$
begin
  raise exception 'Filed return evidence is permanent.' using errcode = 'insufficient_privilege';
end;
$$;
create trigger gst_filed_documents_append_only before update or delete on public.gst_filed_documents
  for each row execute function app.gst_evidence_append_only();
create trigger itc_claim_lines_append_only before update or delete on public.itc_claim_lines
  for each row execute function app.gst_evidence_append_only();

alter table public.gst_returns enable row level security;
alter table public.gst_filed_documents enable row level security;
alter table public.gstr2b_imports enable row level security;
alter table public.gstr2b_lines enable row level security;
alter table public.itc_claim_lines enable row level security;

create policy gst_returns_select on public.gst_returns for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('gst.reports.view')));
create policy gst_returns_write on public.gst_returns for all to authenticated
  using (dealer_id = app.current_dealer_id()
         and (app.has_permission('gst.returns.prepare') or app.has_permission('gst.returns.file')))
  with check (dealer_id = app.current_dealer_id()
              and (app.has_permission('gst.returns.prepare') or app.has_permission('gst.returns.file')));
create policy gfd_select on public.gst_filed_documents for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('gst.reports.view')));
create policy gfd_insert on public.gst_filed_documents for insert to authenticated
  with check (dealer_id = app.current_dealer_id() and app.has_permission('gst.returns.file'));
create policy gstr2b_imports_select on public.gstr2b_imports for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('gst.reports.view')));
create policy gstr2b_imports_write on public.gstr2b_imports for all to authenticated
  using (dealer_id = app.current_dealer_id() and app.has_permission('gst.returns.prepare'))
  with check (dealer_id = app.current_dealer_id() and app.has_permission('gst.returns.prepare'));
create policy gstr2b_lines_select on public.gstr2b_lines for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('gst.reports.view')));
create policy gstr2b_lines_write on public.gstr2b_lines for all to authenticated
  using (dealer_id = app.current_dealer_id() and app.has_permission('gst.returns.prepare'))
  with check (dealer_id = app.current_dealer_id() and app.has_permission('gst.returns.prepare'));
create policy itc_claim_select on public.itc_claim_lines for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('gst.reports.view')));
create policy itc_claim_insert on public.itc_claim_lines for insert to authenticated
  with check (dealer_id = app.current_dealer_id() and app.has_permission('gst.returns.file'));

-- -----------------------------------------------------------------------------
-- 2B import and matching
-- -----------------------------------------------------------------------------
create or replace function public.match_gstr2b(p_import_id uuid)
returns table (match_status text, line_count bigint)
language plpgsql
as $$
declare
  v_imp  public.gstr2b_imports;
  l      record;
  v_bill record;
  v_note record;
begin
  select * into v_imp from public.gstr2b_imports
   where id = p_import_id and dealer_id = app.current_dealer_id();
  if v_imp.id is null then
    raise exception 'GSTR-2B import not found.' using errcode = 'no_data_found';
  end if;

  update public.gstr2b_lines
     set match_status = 'NOT_IN_BOOKS', matched_bill_id = null, matched_note_id = null,
         books_taxable = null, books_tax = null
   where import_id = p_import_id;

  for l in select * from public.gstr2b_lines where import_id = p_import_id order by document_date, document_number loop
    if l.document_type in ('INVOICE') then
      select b.id, b.taxable_value, b.cgst_amount + b.sgst_amount + b.igst_amount as tax,
             exists (select 1 from public.purchase_bill_lines pl
                      where pl.purchase_bill_id = b.id and pl.itc_eligible
                        and pl.cgst_amount + pl.sgst_amount + pl.igst_amount > 0) as claimable
        into v_bill
        from public.purchase_bills b
        join public.suppliers s on s.id = b.supplier_id
       where b.dealer_id = v_imp.dealer_id and b.status = 'POSTED'
         and upper(btrim(s.gstin)) = l.supplier_gstin
         and app.norm_doc_no(b.supplier_bill_number) = app.norm_doc_no(l.document_number)
         -- One bill, one 2B line: a bill already matched in this or another live import is taken.
         and not exists (select 1 from public.gstr2b_lines x
                           join public.gstr2b_imports xi on xi.id = x.import_id and xi.status = 'ACTIVE'
                          where x.matched_bill_id = b.id and x.id <> l.id)
       order by b.bill_date desc
       limit 1;

      if v_bill.id is not null then
        update public.gstr2b_lines
           set matched_bill_id = v_bill.id, books_taxable = v_bill.taxable_value, books_tax = v_bill.tax,
               match_status = case
                 when not v_bill.claimable then 'NOT_CLAIMABLE'
                 when abs(v_bill.taxable_value - l.taxable_value) <= 1
                  and abs(v_bill.tax - (l.igst_amount + l.cgst_amount + l.sgst_amount)) <= 1 then 'MATCHED'
                 else 'VALUE_MISMATCH' end
         where id = l.id;
      end if;
    else
      select n.id, n.taxable_value, n.cgst_amount + n.sgst_amount + n.igst_amount as tax, n.itc_eligible
        into v_note
        from public.gst_notes n
        join public.suppliers s on s.id = n.supplier_id
       where n.dealer_id = v_imp.dealer_id and n.party_type = 'SUPPLIER' and n.status = 'POSTED'
         and n.note_type = case when l.document_type = 'CREDIT_NOTE' then 'CREDIT' else 'DEBIT' end
         and upper(btrim(s.gstin)) = l.supplier_gstin
         and app.norm_doc_no(n.party_note_number) = app.norm_doc_no(l.document_number)
       limit 1;
      if v_note.id is not null then
        update public.gstr2b_lines
           set matched_note_id = v_note.id, books_taxable = v_note.taxable_value, books_tax = v_note.tax,
               match_status = case
                 when not v_note.itc_eligible then 'NOT_CLAIMABLE'
                 when abs(v_note.taxable_value - l.taxable_value) <= 1
                  and abs(v_note.tax - (l.igst_amount + l.cgst_amount + l.sgst_amount)) <= 1 then 'MATCHED'
                 else 'VALUE_MISMATCH' end
         where id = l.id;
      end if;
    end if;
  end loop;

  return query
    select g.match_status, count(*) from public.gstr2b_lines g
     where g.import_id = p_import_id group by g.match_status order by 1;
end;
$$;

create or replace function public.import_gstr2b(
  p_gstin     text,
  p_period    date,
  p_lines     jsonb,
  p_file_name text default null
)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_id     uuid;
  v_count  integer;
  v_period date := date_trunc('month', p_period)::date;
  v_bad    record;
begin
  if v_dealer is null or not app.has_permission('gst.returns.prepare') then
    raise exception 'You do not have permission to import GSTR-2B.' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.branches b where b.dealer_id = v_dealer and app.branch_gstin(b.id) = p_gstin) then
    raise exception 'GSTIN % is not one of yours.', p_gstin using errcode = 'check_violation';
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'The GSTR-2B file has no lines.' using errcode = 'check_violation';
  end if;

  -- Validate before writing anything: no partial import (spec §14).
  select e.ordinality as n, e.value->>'supplier_gstin' as g, e.value->>'document_number' as d
    into v_bad
    from jsonb_array_elements(p_lines) with ordinality e
   where upper(btrim(coalesce(e.value->>'supplier_gstin', ''))) !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z]Z[0-9A-Z]$'
      or coalesce(btrim(e.value->>'document_number'), '') = ''
   limit 1;
  if v_bad.n is not null then
    raise exception 'Line % of the 2B file is not usable: supplier GSTIN "%" / document "%".', v_bad.n, v_bad.g, v_bad.d
      using errcode = 'check_violation';
  end if;

  update public.gstr2b_imports set status = 'SUPERSEDED'
   where dealer_id = v_dealer and gstin = p_gstin and period = v_period and status = 'ACTIVE';

  insert into public.gstr2b_imports (dealer_id, gstin, period, file_name, imported_by)
  values (v_dealer, p_gstin, v_period, p_file_name, auth.uid())
  returning id into v_id;

  insert into public.gstr2b_lines
    (import_id, dealer_id, supplier_gstin, supplier_name, document_type, document_number, document_date,
     taxable_value, igst_amount, cgst_amount, sgst_amount, cess_amount, itc_available, reverse_charge)
  select v_id, v_dealer, upper(btrim(e->>'supplier_gstin')), nullif(btrim(e->>'supplier_name'), ''),
         coalesce(nullif(upper(btrim(e->>'document_type')), ''), 'INVOICE'), btrim(e->>'document_number'),
         nullif(e->>'document_date', '')::date,
         coalesce(nullif(e->>'taxable_value', '')::numeric, 0), coalesce(nullif(e->>'igst', '')::numeric, 0),
         coalesce(nullif(e->>'cgst', '')::numeric, 0), coalesce(nullif(e->>'sgst', '')::numeric, 0),
         coalesce(nullif(e->>'cess', '')::numeric, 0),
         coalesce(nullif(e->>'itc_available', '')::boolean, true),
         coalesce(nullif(e->>'reverse_charge', '')::boolean, false)
    from jsonb_array_elements(p_lines) e;
  get diagnostics v_count = row_count;
  update public.gstr2b_imports set line_count = v_count where id = v_id;

  perform public.match_gstr2b(v_id);
  return v_id;
end;
$$;

-- Both sides of the 2B: every 2B line with its status, and every bill of the
-- month in the books that the 2B does not carry.
create or replace function public.gstr2b_reconciliation(p_import_id uuid)
returns table (
  side             text,
  match_status     text,
  supplier_gstin   text,
  supplier_name    text,
  document_number  text,
  document_date    date,
  taxable_2b       numeric(18, 4),
  tax_2b           numeric(18, 4),
  taxable_books    numeric(18, 4),
  tax_books        numeric(18, 4),
  difference       numeric(18, 4),
  purchase_bill_id uuid,
  line_id          uuid
)
language sql
stable
as $$
  with imp as (
    select * from public.gstr2b_imports where id = p_import_id and dealer_id = app.current_dealer_id()
  )
  select '2B', g.match_status, g.supplier_gstin, g.supplier_name, g.document_number, g.document_date,
         g.taxable_value, g.igst_amount + g.cgst_amount + g.sgst_amount, g.books_taxable, g.books_tax,
         coalesce(g.books_tax, 0) - (g.igst_amount + g.cgst_amount + g.sgst_amount),
         g.matched_bill_id, g.id
    from public.gstr2b_lines g join imp on imp.id = g.import_id
  union all
  select 'BOOKS', 'NOT_IN_2B', upper(btrim(s.gstin)), s.name, b.supplier_bill_number, b.bill_date,
         null, null, b.taxable_value, b.cgst_amount + b.sgst_amount + b.igst_amount,
         b.cgst_amount + b.sgst_amount + b.igst_amount, b.id, null
    from public.purchase_bills b
    join public.suppliers s on s.id = b.supplier_id
    join imp on true
   where b.dealer_id = imp.dealer_id and b.status = 'POSTED'
     and b.bill_date between imp.period and app.month_end(imp.period)
     and app.branch_gstin(b.branch_id) = imp.gstin
     and nullif(btrim(coalesce(s.gstin, '')), '') is not null
     and b.cgst_amount + b.sgst_amount + b.igst_amount > 0
     and not exists (select 1 from public.gstr2b_lines x
                       join public.gstr2b_imports xi on xi.id = x.import_id and xi.status = 'ACTIVE'
                      where x.matched_bill_id = b.id)
   order by 1, 6, 5;
$$;

-- -----------------------------------------------------------------------------
-- ITC claim controls
-- -----------------------------------------------------------------------------
-- Every document whose credit is open for this GSTIN up to a month's end:
-- claimable now, or held back and why.
create or replace function public.itc_claimable(p_gstin text, p_period date)
returns table (
  claim_kind       text,
  purchase_bill_id uuid,
  gst_note_id      uuid,
  document_number  text,
  document_date    date,
  supplier_name    text,
  igst_amount      numeric(18, 4),
  cgst_amount      numeric(18, 4),
  sgst_amount      numeric(18, 4),
  claimable        boolean,
  reason           text
)
language sql
stable
as $$
  with bills as (
    select b.id, b.bill_number, b.bill_date, s.name as supplier,
           sum(l.igst_amount) filter (where l.itc_eligible and not l.reverse_charge) as ig,
           sum(l.cgst_amount) filter (where l.itc_eligible and not l.reverse_charge) as cg,
           sum(l.sgst_amount) filter (where l.itc_eligible and not l.reverse_charge) as sg,
           sum(l.igst_amount) filter (where l.itc_eligible and l.reverse_charge) as rig,
           sum(l.cgst_amount) filter (where l.itc_eligible and l.reverse_charge) as rcg,
           sum(l.sgst_amount) filter (where l.itc_eligible and l.reverse_charge) as rsg
      from public.purchase_bills b
      join public.suppliers s on s.id = b.supplier_id
      join public.purchase_bill_lines l on l.purchase_bill_id = b.id
     where b.dealer_id = app.current_dealer_id() and b.status = 'POSTED'
       and b.bill_date <= app.month_end(p_period)
       and app.branch_gstin(b.branch_id) = p_gstin
     group by b.id, b.bill_number, b.bill_date, s.name
  ),
  in2b as (
    select distinct on (g.matched_bill_id) g.matched_bill_id, g.match_status,
           g.igst_amount, g.cgst_amount, g.sgst_amount
      from public.gstr2b_lines g
      join public.gstr2b_imports i on i.id = g.import_id and i.status = 'ACTIVE'
     where i.dealer_id = app.current_dealer_id() and i.gstin = p_gstin
       and i.period <= date_trunc('month', p_period)::date and g.matched_bill_id is not null
       and g.itc_available
     order by g.matched_bill_id, i.period desc
  )
  -- Invoices: in 2B, at the lower of books and 2B head by head.
  select 'INVOICE', b.id, null::uuid, b.bill_number, b.bill_date, b.supplier,
         case when m.matched_bill_id is null then coalesce(b.ig, 0) else least(coalesce(b.ig, 0), m.igst_amount) end,
         case when m.matched_bill_id is null then coalesce(b.cg, 0) else least(coalesce(b.cg, 0), m.cgst_amount) end,
         case when m.matched_bill_id is null then coalesce(b.sg, 0) else least(coalesce(b.sg, 0), m.sgst_amount) end,
         m.matched_bill_id is not null and m.match_status in ('MATCHED', 'VALUE_MISMATCH'),
         case when m.matched_bill_id is null then 'Not yet in GSTR-2B'
              when m.match_status = 'VALUE_MISMATCH' then 'In 2B with a different value: the lower is claimed'
              else 'In GSTR-2B' end
    from bills b
    left join in2b m on m.matched_bill_id = b.id
   where coalesce(b.ig, 0) + coalesce(b.cg, 0) + coalesce(b.sg, 0) > 0
     and not exists (select 1 from public.itc_claim_lines c where c.purchase_bill_id = b.id and c.claim_kind = 'INVOICE')
  union all
  -- Reverse charge: the dealer paid the tax; no 2B is needed.
  select 'RCM', b.id, null, b.bill_number, b.bill_date, b.supplier,
         coalesce(b.rig, 0), coalesce(b.rcg, 0), coalesce(b.rsg, 0), true, 'Reverse charge paid by you'
    from bills b
   where coalesce(b.rig, 0) + coalesce(b.rcg, 0) + coalesce(b.rsg, 0) > 0
     and b.bill_date >= date_trunc('month', p_period)::date
     and not exists (select 1 from public.itc_claim_lines c where c.purchase_bill_id = b.id and c.claim_kind = 'RCM')
  union all
  -- Supplier notes. A credit note reduces the claim regardless of 2B; a debit
  -- note, like an invoice, waits for it.
  select n.note_type || '_NOTE', null, n.id, coalesce(n.party_note_number, n.note_number), n.note_date, s.name,
         case when n.note_type = 'CREDIT' then -1 else 1 end * n.igst_amount,
         case when n.note_type = 'CREDIT' then -1 else 1 end * n.cgst_amount,
         case when n.note_type = 'CREDIT' then -1 else 1 end * n.sgst_amount,
         n.note_type = 'CREDIT' or exists (
           select 1 from public.gstr2b_lines g join public.gstr2b_imports i on i.id = g.import_id and i.status = 'ACTIVE'
            where g.matched_note_id = n.id and i.period <= date_trunc('month', p_period)::date),
         case when n.note_type = 'CREDIT' then 'Supplier credit note reduces credit'
              else 'Supplier debit note' end
    from public.gst_notes n
    join public.suppliers s on s.id = n.supplier_id
   where n.dealer_id = app.current_dealer_id() and n.party_type = 'SUPPLIER' and n.status = 'POSTED'
     and n.itc_eligible and n.note_date <= app.month_end(p_period)
     and app.branch_gstin(n.branch_id) = p_gstin
     and not exists (select 1 from public.itc_claim_lines c where c.gst_note_id = n.id)
   order by 1, 5;
$$;

-- -----------------------------------------------------------------------------
-- GSTR-3B working
-- -----------------------------------------------------------------------------
create or replace function public.gstr3b_working(p_gstin text, p_period date)
returns table (
  section       text,
  description   text,
  taxable_value numeric(18, 4),
  igst_amount   numeric(18, 4),
  cgst_amount   numeric(18, 4),
  sgst_amount   numeric(18, 4)
)
language sql
stable
as $$
  with bounds as (
    select date_trunc('month', p_period)::date as f, app.month_end(p_period) as t
  ),
  outward_lines as (
    select app.supply_category(s.dealer_id, l.tax_code, s.invoice_date, l.cgst_amount + l.sgst_amount + l.igst_amount) as cat,
           l.taxable_value as tv, l.igst_amount as ig, l.cgst_amount as cg, l.sgst_amount as sg
      from public.sale_lines l join public.sales s on s.id = l.sale_id, bounds
     where s.dealer_id = app.current_dealer_id() and s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between bounds.f and bounds.t and app.branch_gstin(s.branch_id) = p_gstin
    union all
    select app.supply_category(si.dealer_id, l.tax_code, si.invoice_date, l.cgst_amount + l.sgst_amount + l.igst_amount),
           l.taxable_value, l.igst_amount, l.cgst_amount, l.sgst_amount
      from public.service_lines l join public.service_invoices si on si.id = l.invoice_id, bounds
     where si.dealer_id = app.current_dealer_id() and si.status = 'POSTED'
       and si.invoice_date between bounds.f and bounds.t and app.branch_gstin(si.branch_id) = p_gstin
    union all
    -- Notes and transfer invoices are taxable supplies (or their correction).
    select 'TAXABLE', d.taxable_value, d.igst_amount, d.cgst_amount, d.sgst_amount
      from bounds, app.gst_outward_documents(bounds.f, bounds.t, p_gstin) d
     where d.document_type in ('CREDIT_NOTE', 'DEBIT_NOTE', 'TRANSFER_INVOICE')
  ),
  inward_lines as (
    select l.tax_category as cat, l.reverse_charge as rcm, l.itc_eligible as elig,
           l.taxable_value as tv, l.igst_amount as ig, l.cgst_amount as cg, l.sgst_amount as sg
      from public.purchase_bill_lines l join public.purchase_bills b on b.id = l.purchase_bill_id, bounds
     where b.dealer_id = app.current_dealer_id() and b.status = 'POSTED'
       and b.bill_date between bounds.f and bounds.t and app.branch_gstin(b.branch_id) = p_gstin
  ),
  claims as (
    select * from public.itc_claimable(p_gstin, p_period) where claimable
  ),
  adj as (
    select a.direction, a.rule, a.igst_amount as ig, a.cgst_amount as cg, a.sgst_amount as sg
      from public.itc_adjustments a, bounds
     where a.dealer_id = app.current_dealer_id() and a.adjustment_date between bounds.f and bounds.t
       and app.branch_gstin(a.branch_id) = p_gstin
  ),
  rows as (
    select 1 as ord, '3.1(a)' as sec, 'Outward taxable supplies (other than zero, nil rated and exempted)' as descr,
           sum(tv) as tv, sum(ig) as ig, sum(cg) as cg, sum(sg) as sg
      from outward_lines where cat = 'TAXABLE'
    union all
    select 2, '3.1(b)', 'Outward taxable supplies (zero rated)', sum(tv), sum(ig), sum(cg), sum(sg)
      from outward_lines where cat = 'ZERO_RATED'
    union all
    select 3, '3.1(c)', 'Other outward supplies (nil rated, exempted)', sum(tv), 0, 0, 0
      from outward_lines where cat in ('NIL_RATED', 'EXEMPT')
    union all
    select 4, '3.1(d)', 'Inward supplies liable to reverse charge', sum(tv), sum(ig), sum(cg), sum(sg)
      from inward_lines where rcm
    union all
    select 5, '3.1(e)', 'Non-GST outward supplies', sum(tv), 0, 0, 0
      from outward_lines where cat = 'NON_GST'
    union all
    select 6, '3.1(!)', 'Unclassified zero-tax lines: give them a tax code before filing', sum(tv), 0, 0, 0
      from outward_lines where cat = 'UNCLASSIFIED' having count(*) > 0
    union all
    select 7, '4(A)(3)', 'ITC: inward supplies liable to reverse charge', null,
           sum(igst_amount), sum(cgst_amount), sum(sgst_amount)
      from claims where claim_kind = 'RCM'
    union all
    select 8, '4(A)(5)', 'ITC: all other (in GSTR-2B), net of supplier credit notes and re-claims', null,
           coalesce((select sum(igst_amount) from claims where claim_kind <> 'RCM'), 0)
             + coalesce((select sum(ig) from adj where direction = 'RECLAIM'), 0),
           coalesce((select sum(cgst_amount) from claims where claim_kind <> 'RCM'), 0)
             + coalesce((select sum(cg) from adj where direction = 'RECLAIM'), 0),
           coalesce((select sum(sgst_amount) from claims where claim_kind <> 'RCM'), 0)
             + coalesce((select sum(sg) from adj where direction = 'RECLAIM'), 0)
    union all
    select 9, '4(B)(1)', 'ITC reversed: rules 42, 43 and s.17(5)', null, sum(ig), sum(cg), sum(sg)
      from adj where direction = 'REVERSAL' and rule in ('RULE_42', 'RULE_43', 'SECTION_17_5')
    union all
    select 10, '4(B)(2)', 'ITC reversed: others (rule 37 etc.)', null, sum(ig), sum(cg), sum(sg)
      from adj where direction = 'REVERSAL' and rule not in ('RULE_42', 'RULE_43', 'SECTION_17_5')
    union all
    select 12, '4(D)', 'ITC in the books not yet claimable (not in GSTR-2B)', null,
           sum(igst_amount), sum(cgst_amount), sum(sgst_amount)
      from public.itc_claimable(p_gstin, p_period) where not claimable
    union all
    select 13, '5', 'Inward exempt, nil rated and non-GST supplies', sum(tv), 0, 0, 0
      from inward_lines where cat in ('NIL_RATED', 'EXEMPT', 'NON_GST')
  ),
  with_net as (
    select * from rows
    union all
    select 11, '4(C)', 'Net ITC available (A − B)', null,
           sum(case when sec like '4(A)%' then coalesce(ig, 0) when sec like '4(B)%' then -coalesce(ig, 0) else 0 end),
           sum(case when sec like '4(A)%' then coalesce(cg, 0) when sec like '4(B)%' then -coalesce(cg, 0) else 0 end),
           sum(case when sec like '4(A)%' then coalesce(sg, 0) when sec like '4(B)%' then -coalesce(sg, 0) else 0 end)
      from rows
  )
  select sec, descr, tv, coalesce(ig, 0), coalesce(cg, 0), coalesce(sg, 0)
    from with_net order by ord;
$$;

-- Credit left at the end of the last filed 3B for this GSTIN.
create or replace function app.gst_opening_credit(p_gstin text, p_period date)
returns table (igst numeric, cgst numeric, sgst numeric)
language sql
stable
as $$
  select coalesce((r.computed->'closing_credit'->>'igst')::numeric, 0),
         coalesce((r.computed->'closing_credit'->>'cgst')::numeric, 0),
         coalesce((r.computed->'closing_credit'->>'sgst')::numeric, 0)
    from (select 1) one
    left join lateral (
      select g.computed from public.gst_returns g
       where g.dealer_id = app.current_dealer_id() and g.gstin = p_gstin and g.return_type = 'GSTR3B'
         and g.status = 'FILED' and g.period < date_trunc('month', p_period)::date
       order by g.period desc limit 1) r on true;
$$;

-- Set-off in the order of rule 88A; reverse-charge tax is paid in cash.
create or replace function public.gstr3b_setoff(p_gstin text, p_period date)
returns table (
  tax_head         text,
  liability        numeric(18, 4),
  rcm_liability    numeric(18, 4),
  opening_credit   numeric(18, 4),
  period_credit    numeric(18, 4),
  paid_by_igst     numeric(18, 4),
  paid_by_cgst     numeric(18, 4),
  paid_by_sgst     numeric(18, 4),
  cash_payable     numeric(18, 4),
  closing_credit   numeric(18, 4)
)
language plpgsql
stable
as $$
declare
  li numeric; lc numeric; ls numeric;           -- liability left, per head
  ri numeric; rc numeric; rs numeric;           -- reverse charge
  oi numeric; oc numeric; os numeric;           -- opening credit
  ni numeric; nc numeric; ns numeric;           -- this period's net credit
  ci numeric; cc numeric; cs numeric;           -- credit left
  i_i numeric; i_c numeric; i_s numeric;        -- IGST credit used against IGST / CGST / SGST
  c_c numeric; c_i numeric;                     -- CGST credit used against CGST / IGST
  s_s numeric; s_i numeric;                     -- SGST credit used against SGST / IGST
  w record;
begin
  li := 0; lc := 0; ls := 0; ri := 0; rc := 0; rs := 0; ni := 0; nc := 0; ns := 0;
  for w in select * from public.gstr3b_working(p_gstin, p_period) loop
    if w.section in ('3.1(a)', '3.1(b)') then
      li := li + w.igst_amount; lc := lc + w.cgst_amount; ls := ls + w.sgst_amount;
    elsif w.section = '3.1(d)' then
      ri := ri + w.igst_amount; rc := rc + w.cgst_amount; rs := rs + w.sgst_amount;
    elsif w.section = '4(C)' then
      ni := w.igst_amount; nc := w.cgst_amount; ns := w.sgst_amount;
    end if;
  end loop;
  select o.igst, o.cgst, o.sgst into oi, oc, os from app.gst_opening_credit(p_gstin, p_period) o;

  -- Liability cannot be negative for set-off; a net credit note month simply
  -- has nothing to pay.
  li := greatest(li, 0); lc := greatest(lc, 0); ls := greatest(ls, 0);
  ci := greatest(oi + ni, 0); cc := greatest(oc + nc, 0); cs := greatest(os + ns, 0);

  tax_head := null;
  i_i := least(ci, li); li := li - i_i; ci := ci - i_i;
  i_c := least(ci, lc); lc := lc - i_c; ci := ci - i_c;
  i_s := least(ci, ls); ls := ls - i_s; ci := ci - i_s;
  c_c := least(cc, lc); lc := lc - c_c; cc := cc - c_c;
  c_i := least(cc, li); li := li - c_i; cc := cc - c_i;
  s_s := least(cs, ls); ls := ls - s_s; cs := cs - s_s;
  s_i := least(cs, li); li := li - s_i; cs := cs - s_i;

  return query values
    ('IGST', li + i_i + c_i + s_i, ri, oi, ni, i_i, c_i, s_i, li + ri, ci),
    ('CGST', lc + i_c + c_c, rc, oc, nc, i_c, c_c, 0::numeric, lc + rc, cc),
    ('SGST', ls + i_s + s_s, rs, os, ns, i_s, 0::numeric, s_s, ls + rs, cs);
end;
$$;

-- -----------------------------------------------------------------------------
-- Preparing, signing off and filing
-- -----------------------------------------------------------------------------
create or replace function app.gst_return_snapshot(p_type text, p_gstin text, p_period date)
returns jsonb
language plpgsql
stable
as $$
declare
  v_f date := date_trunc('month', p_period)::date;
  v_t date := app.month_end(p_period);
begin
  if p_type = 'GSTR1' then
    return jsonb_build_object(
      'sections', (select coalesce(jsonb_agg(to_jsonb(s) order by s.section), '[]'::jsonb) from (
         select d.section, count(*) as documents, sum(d.taxable_value) as taxable,
                sum(d.igst_amount) as igst, sum(d.cgst_amount) as cgst, sum(d.sgst_amount) as sgst
           from app.gst_outward_documents(v_f, v_t, p_gstin) d group by d.section) s),
      'totals', (select jsonb_build_object('taxable', coalesce(sum(taxable_value), 0),
                  'igst', coalesce(sum(igst_amount), 0), 'cgst', coalesce(sum(cgst_amount), 0),
                  'sgst', coalesce(sum(sgst_amount), 0))
                   from app.gst_outward_documents(v_f, v_t, p_gstin)));
  end if;
  return jsonb_build_object(
    'working', (select jsonb_agg(to_jsonb(w)) from public.gstr3b_working(p_gstin, p_period) w),
    'setoff',  (select jsonb_agg(to_jsonb(s)) from public.gstr3b_setoff(p_gstin, p_period) s),
    'closing_credit', (select jsonb_object_agg(lower(s.tax_head), s.closing_credit)
                         from public.gstr3b_setoff(p_gstin, p_period) s),
    'cash_payable', (select sum(s.cash_payable) from public.gstr3b_setoff(p_gstin, p_period) s));
end;
$$;

create or replace function public.prepare_gst_return(p_type text, p_gstin text, p_period date, p_notes text default null)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_period date := date_trunc('month', p_period)::date;
  v_ret    public.gst_returns;
begin
  if v_dealer is null or not app.has_permission('gst.returns.prepare') then
    raise exception 'You do not have permission to prepare GST returns.' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.branches b where b.dealer_id = v_dealer and app.branch_gstin(b.id) = p_gstin) then
    raise exception 'GSTIN % is not one of yours.', p_gstin using errcode = 'check_violation';
  end if;
  if v_period > date_trunc('month', current_date)::date then
    raise exception 'A return cannot be prepared for a month that has not begun.' using errcode = 'check_violation';
  end if;

  select * into v_ret from public.gst_returns
   where dealer_id = v_dealer and gstin = p_gstin and return_type = p_type and period = v_period for update;
  if v_ret.status = 'FILED' then
    raise exception 'The % for % is already filed. Corrections go in a later return as amendments.',
      p_type, to_char(v_period, 'Mon YYYY') using errcode = 'check_violation';
  end if;

  if v_ret.id is null then
    insert into public.gst_returns (dealer_id, gstin, return_type, period, computed, prepared_by, notes)
    values (v_dealer, p_gstin, p_type, v_period, app.gst_return_snapshot(p_type, p_gstin, v_period), auth.uid(), p_notes)
    returning * into v_ret;
  else
    -- Re-preparing replaces the figures, so any sign-off on the old ones lapses.
    update public.gst_returns
       set computed = app.gst_return_snapshot(p_type, p_gstin, v_period), prepared_by = auth.uid(),
           prepared_at = now(), status = 'PREPARED', signed_off_by = null, signed_off_at = null,
           notes = coalesce(p_notes, notes)
     where id = v_ret.id;
  end if;
  return v_ret.id;
end;
$$;

create or replace function public.sign_off_gst_return(p_return_id uuid)
returns void
language plpgsql
as $$
declare
  v_ret public.gst_returns;
begin
  if not app.has_permission('gst.returns.file') then
    raise exception 'You do not have permission to sign off GST returns.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_ret from public.gst_returns where id = p_return_id and dealer_id = app.current_dealer_id() for update;
  if v_ret.id is null then
    raise exception 'Return not found.' using errcode = 'no_data_found';
  end if;
  if v_ret.status <> 'PREPARED' then
    raise exception 'Only a prepared return can be signed off; this one is %.', lower(v_ret.status)
      using errcode = 'check_violation';
  end if;
  if v_ret.prepared_by = auth.uid() then
    raise exception 'The person who prepared a return cannot also sign it off.' using errcode = 'check_violation';
  end if;
  update public.gst_returns set status = 'SIGNED_OFF', signed_off_by = auth.uid(), signed_off_at = now()
   where id = p_return_id;
end;
$$;

create or replace function public.record_gst_filing(
  p_return_id      uuid,
  p_arn            text,
  p_filed_on       date,
  p_taxable        numeric,
  p_igst           numeric,
  p_cgst           numeric,
  p_sgst           numeric,
  p_itc_igst       numeric default null,
  p_itc_cgst       numeric default null,
  p_itc_sgst       numeric default null,
  p_challan_cpin   text default null,
  p_challan_cin    text default null,
  p_challan_amount numeric default null,
  p_notes          text default null
)
returns void
language plpgsql
as $$
declare
  v_ret public.gst_returns;
  v_f   date;
  v_t   date;
begin
  if not app.has_permission('gst.returns.file') then
    raise exception 'You do not have permission to record GST filings.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_ret from public.gst_returns where id = p_return_id and dealer_id = app.current_dealer_id() for update;
  if v_ret.id is null then
    raise exception 'Return not found.' using errcode = 'no_data_found';
  end if;
  if v_ret.status = 'FILED' then
    return;
  end if;
  if v_ret.status <> 'SIGNED_OFF' then
    raise exception 'Sign the return off before recording its filing.' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_arn), '') = '' or p_filed_on is null then
    raise exception 'Enter the ARN and the date of filing from the portal.' using errcode = 'check_violation';
  end if;
  if p_filed_on > current_date then
    raise exception 'A filing date cannot be in the future.' using errcode = 'check_violation';
  end if;

  v_f := v_ret.period; v_t := app.month_end(v_ret.period);

  update public.gst_returns
     set status = 'FILED', arn = upper(btrim(p_arn)), filed_on = p_filed_on, filed_by = auth.uid(), filed_at = now(),
         filed_taxable = p_taxable, filed_igst = p_igst, filed_cgst = p_cgst, filed_sgst = p_sgst,
         filed_itc_igst = p_itc_igst, filed_itc_cgst = p_itc_cgst, filed_itc_sgst = p_itc_sgst,
         challan_cpin = nullif(btrim(coalesce(p_challan_cpin, '')), ''),
         challan_cin = nullif(btrim(coalesce(p_challan_cin, '')), ''),
         challan_amount = p_challan_amount, notes = coalesce(p_notes, notes)
   where id = p_return_id;

  if v_ret.return_type = 'GSTR1' then
    insert into public.gst_filed_documents
      (return_id, dealer_id, document_type, document_id, document_number, document_date, party_gstin,
       place_of_supply, section, taxable_value, cgst_amount, sgst_amount, igst_amount, total_amount)
    select p_return_id, v_ret.dealer_id, d.document_type, d.document_id, d.document_number, d.document_date,
           d.party_gstin, d.place_of_supply, d.section, d.taxable_value, d.cgst_amount, d.sgst_amount,
           d.igst_amount, d.total_amount
      from app.gst_outward_documents(v_f, v_t, v_ret.gstin) d;
  else
    insert into public.itc_claim_lines
      (return_id, dealer_id, claim_kind, purchase_bill_id, gst_note_id, igst_amount, cgst_amount, sgst_amount)
    select p_return_id, v_ret.dealer_id, c.claim_kind, c.purchase_bill_id, c.gst_note_id,
           c.igst_amount, c.cgst_amount, c.sgst_amount
      from public.itc_claimable(v_ret.gstin, v_ret.period) c
     where c.claimable;
  end if;
end;
$$;

-- The 3B's set-off, posted once filed: output tax cleared by input credit, the
-- rest (and reverse-charge tax) paid from the bank.
create or replace function public.post_gst_setoff(p_return_id uuid, p_bank_account_id uuid, p_date date default null)
returns uuid
language plpgsql
as $$
declare
  v_ret    public.gst_returns;
  v_bank   public.bank_accounts;
  v_branch uuid;
  v_lines  jsonb := '[]'::jsonb;
  v_cash   numeric := 0;
  v_entry  uuid;
  v_date   date;
  s        record;
  v_head   text;
begin
  if not app.has_permission('gst.returns.file') then
    raise exception 'You do not have permission to post the GST set-off.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_ret from public.gst_returns where id = p_return_id and dealer_id = app.current_dealer_id() for update;
  if v_ret.id is null or v_ret.return_type <> 'GSTR3B' then
    raise exception 'GSTR-3B not found.' using errcode = 'no_data_found';
  end if;
  if v_ret.setoff_journal_id is not null then
    return v_ret.setoff_journal_id;
  end if;
  if v_ret.status <> 'FILED' then
    raise exception 'Record the filing before posting its set-off.' using errcode = 'check_violation';
  end if;
  select * into v_bank from public.bank_accounts where id = p_bank_account_id and dealer_id = v_ret.dealer_id and status = 'ACTIVE';
  if v_bank.id is null then
    raise exception 'Choose an active bank account.' using errcode = 'no_data_found';
  end if;
  select b.id into v_branch from public.branches b
   where b.dealer_id = v_ret.dealer_id and app.branch_gstin(b.id) = v_ret.gstin
   order by (b.id = v_bank.branch_id) desc, b.created_at limit 1;
  v_date := coalesce(p_date, v_ret.filed_on);

  for s in select * from jsonb_to_recordset(v_ret.computed->'setoff') as x(
             tax_head text, liability numeric, rcm_liability numeric, paid_by_igst numeric,
             paid_by_cgst numeric, paid_by_sgst numeric, cash_payable numeric) loop
    v_head := s.tax_head;
    -- The liability cleared: output tax, and reverse-charge tax, debited.
    if s.liability > 0 then
      v_lines := v_lines || jsonb_build_object(
        'account_id', app.require_account(v_ret.dealer_id, 'SERVICE', 'INVOICE', v_head, v_branch),
        'debit', s.liability, 'credit', 0, 'narration', 'Output ' || v_head || ' set off ' || to_char(v_ret.period, 'Mon YYYY'));
    end if;
    if s.rcm_liability > 0 then
      v_lines := v_lines || jsonb_build_object(
        'account_id', app.require_account(v_ret.dealer_id, 'INVENTORY', 'PURCHASE', 'RCM_PAYABLE', v_branch),
        'debit', s.rcm_liability, 'credit', 0, 'narration', 'Reverse-charge ' || v_head || ' paid');
    end if;
    v_cash := v_cash + s.cash_payable;
  end loop;

  -- The credit used, by the head it came from.
  for v_head in select unnest(array['IGST', 'CGST', 'SGST']) loop
    select sum(case v_head when 'IGST' then x.paid_by_igst when 'CGST' then x.paid_by_cgst else x.paid_by_sgst end)
      into s from jsonb_to_recordset(v_ret.computed->'setoff') as x(paid_by_igst numeric, paid_by_cgst numeric, paid_by_sgst numeric);
    if coalesce(s.sum, 0) > 0 then
      v_lines := v_lines || jsonb_build_object(
        'account_id', app.require_account(v_ret.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_' || v_head, v_branch),
        'debit', 0, 'credit', s.sum, 'narration', 'Input ' || v_head || ' utilised');
    end if;
  end loop;

  if v_cash > 0 then
    v_lines := v_lines || jsonb_build_object('account_id', v_bank.ledger_account_id, 'debit', 0, 'credit', v_cash,
      'narration', 'GST paid ' || coalesce('CIN ' || v_ret.challan_cin, 'for ' || to_char(v_ret.period, 'Mon YYYY')));
  end if;
  if jsonb_array_length(v_lines) = 0 then
    raise exception 'Nothing to set off for this return.' using errcode = 'check_violation';
  end if;

  v_entry := app.post_journal(v_ret.dealer_id, v_branch, v_date, 'BANK',
    'GST set-off and payment — GSTR-3B ' || to_char(v_ret.period, 'Mon YYYY') || ' ' || v_ret.gstin,
    v_lines, 'GST_SETOFF', p_return_id, 'gst-setoff:' || p_return_id::text);
  if v_cash > 0 then
    perform app.bank_book_row(p_bank_account_id, v_date, 'PAYMENT', v_cash,
      'GST ' || to_char(v_ret.period, 'Mon YYYY'), 'GST_RETURN', p_return_id, v_entry);
  end if;
  update public.gst_returns set setoff_journal_id = v_entry where id = p_return_id;
  return v_entry;
end;
$$;

-- -----------------------------------------------------------------------------
-- Amendments and cross-checks
-- -----------------------------------------------------------------------------
-- Against every GSTR-1 already filed for this GSTIN before the period: a
-- document that changed or was cancelled after filing, or one dated in a filed
-- month that the filing never carried.
create or replace function public.gstr1_amendments(p_gstin text, p_period date)
returns table (
  kind            text,
  filed_period    date,
  document_type   text,
  document_id     uuid,
  document_number text,
  document_date   date,
  filed_taxable   numeric(18, 4),
  filed_tax       numeric(18, 4),
  current_taxable numeric(18, 4),
  current_tax     numeric(18, 4),
  detail          text
)
language sql
stable
as $$
  with filed as (
    select r.id, r.period from public.gst_returns r
     where r.dealer_id = app.current_dealer_id() and r.gstin = p_gstin and r.return_type = 'GSTR1'
       and r.status = 'FILED' and r.period < date_trunc('month', p_period)::date
  ),
  snap as (
    select f.period, d.* from filed f join public.gst_filed_documents d on d.return_id = f.id
  ),
  cur as (
    select f.period, d.* from filed f
    cross join lateral app.gst_outward_documents(f.period, app.month_end(f.period), p_gstin) d
  )
  select case when c.document_id is null then 'CANCELLED_AFTER_FILING' else 'CHANGED_AFTER_FILING' end,
         s.period, s.document_type, s.document_id, s.document_number, s.document_date,
         s.taxable_value, s.cgst_amount + s.sgst_amount + s.igst_amount,
         c.taxable_value, c.cgst_amount + c.sgst_amount + c.igst_amount,
         case when c.document_id is null then 'Reported, since cancelled: report the reversal as an amendment.'
              else concat_ws('; ',
                case when s.party_gstin is distinct from c.party_gstin then 'GSTIN ' || coalesce(s.party_gstin, 'none') || ' → ' || coalesce(c.party_gstin, 'none') end,
                case when s.place_of_supply is distinct from c.place_of_supply then 'place of supply ' || coalesce(s.place_of_supply, '—') || ' → ' || coalesce(c.place_of_supply, '—') end,
                case when s.taxable_value <> c.taxable_value then 'value changed' end) end
    from snap s
    left join cur c on c.document_type = s.document_type and c.document_id = s.document_id
   where c.document_id is null
      or s.party_gstin is distinct from c.party_gstin
      or s.place_of_supply is distinct from c.place_of_supply
      or s.taxable_value <> c.taxable_value
      or s.cgst_amount + s.sgst_amount + s.igst_amount <> c.cgst_amount + c.sgst_amount + c.igst_amount
  union all
  select 'MISSED_IN_FILING', c.period, c.document_type, c.document_id, c.document_number, c.document_date,
         null, null, c.taxable_value, c.cgst_amount + c.sgst_amount + c.igst_amount,
         'Dated in a filed month but not in that filing: report it in this return.'
    from cur c
   where not exists (select 1 from snap s where s.document_type = c.document_type and s.document_id = c.document_id)
   order by 2, 6;
$$;

create or replace function public.gst_cross_checks(p_gstin text, p_period date)
returns table (
  check_code  text,
  description text,
  left_label  text,
  left_value  numeric(18, 4),
  right_label text,
  right_value numeric(18, 4),
  difference  numeric(18, 4),
  status      text
)
language sql
stable
as $$
  with b as (select date_trunc('month', p_period)::date as f, app.month_end(p_period) as t),
  g1 as (
    select coalesce(sum(d.cgst_amount + d.sgst_amount + d.igst_amount), 0) as tax,
           coalesce(sum(d.taxable_value), 0) as taxable
      from b, app.gst_outward_documents(b.f, b.t, p_gstin) d
  ),
  w as (select * from public.gstr3b_working(p_gstin, p_period)),
  g3 as (
    select coalesce(sum(igst_amount + cgst_amount + sgst_amount) filter (where section in ('3.1(a)', '3.1(b)')), 0) as tax,
           coalesce(sum(igst_amount + cgst_amount + sgst_amount) filter (where section = '4(A)(5)'), 0) as itc
      from w
  ),
  -- Output tax in the ledger: the tax accounts the invoice rules post to,
  -- for this GSTIN's branches, apart from the set-off that clears them.
  books as (
    select coalesce(sum(l.credit - l.debit), 0) as tax
      from public.journal_entry_lines l
      join public.journal_entries je on je.id = l.journal_entry_id, b
     where je.dealer_id = app.current_dealer_id() and je.status in ('POSTED', 'REVERSED')
       and je.entry_date between b.f and b.t
       and coalesce(je.source_document_type, '') <> 'GST_SETOFF'
       and app.branch_gstin(coalesce(l.branch_id, je.branch_id)) = p_gstin
       and l.account_id in (select r.account_id from public.accounting_rules r
                             where r.dealer_id = app.current_dealer_id() and r.status = 'ACTIVE'
                               and r.event = 'INVOICE' and r.component in ('CGST', 'SGST', 'IGST'))
  ),
  twob as (
    select coalesce(sum(g.igst_amount + g.cgst_amount + g.sgst_amount) filter (where g.itc_available and not g.reverse_charge), 0) as itc
      from public.gstr2b_lines g
      join public.gstr2b_imports i on i.id = g.import_id and i.status = 'ACTIVE'
     where i.dealer_id = app.current_dealer_id() and i.gstin = p_gstin and i.period = date_trunc('month', p_period)::date
  ),
  bookitc as (
    select coalesce(sum(l.igst_amount + l.cgst_amount + l.sgst_amount), 0) as itc
      from public.purchase_bill_lines l join public.purchase_bills pb on pb.id = l.purchase_bill_id, b
     where pb.dealer_id = app.current_dealer_id() and pb.status = 'POSTED' and l.itc_eligible and not l.reverse_charge
       and pb.bill_date between b.f and b.t and app.branch_gstin(pb.branch_id) = p_gstin
  ),
  r1 as (select * from public.gst_returns where dealer_id = app.current_dealer_id() and gstin = p_gstin
           and return_type = 'GSTR1' and period = date_trunc('month', p_period)::date),
  r3 as (select * from public.gst_returns where dealer_id = app.current_dealer_id() and gstin = p_gstin
           and return_type = 'GSTR3B' and period = date_trunc('month', p_period)::date),
  checks as (
    select 1 as ord, 'BOOKS_VS_GSTR1' as code, 'Output tax in the ledger against GSTR-1' as descr,
           'Ledger' as ll, books.tax as lv, 'GSTR-1' as rl, g1.tax as rv from books, g1
    union all
    select 2, 'GSTR1_VS_GSTR3B', 'Output tax in GSTR-1 against GSTR-3B 3.1', 'GSTR-1', g1.tax, 'GSTR-3B', g3.tax from g1, g3
    union all
    select 3, 'FILED_GSTR1_VS_FILED_GSTR3B', 'Tax as filed: GSTR-1 against GSTR-3B',
           'GSTR-1 filed', (select filed_igst + filed_cgst + filed_sgst from r1 where status = 'FILED'),
           'GSTR-3B filed', (select filed_igst + filed_cgst + filed_sgst from r3 where status = 'FILED')
    union all
    select 4, 'FILED_VS_COMPUTED_GSTR1', 'GSTR-1: filed against the books today',
           'Filed', (select filed_igst + filed_cgst + filed_sgst from r1 where status = 'FILED'), 'Computed', g1.tax from g1
    union all
    select 5, 'FILED_VS_COMPUTED_GSTR3B', 'GSTR-3B output tax: filed against the books today',
           'Filed', (select filed_igst + filed_cgst + filed_sgst from r3 where status = 'FILED'), 'Computed', g3.tax from g3
    union all
    select 6, 'ITC_3B_VS_2B', 'Credit claimed in GSTR-3B 4(A)(5) against GSTR-2B',
           'GSTR-3B', coalesce((select filed_itc_igst + filed_itc_cgst + filed_itc_sgst from r3 where status = 'FILED'), g3.itc),
           'GSTR-2B', twob.itc from g3, twob
    union all
    select 7, 'ITC_BOOKS_VS_2B', 'Eligible credit on this month''s bills against GSTR-2B',
           'Books', bookitc.itc, 'GSTR-2B', twob.itc from bookitc, twob
  )
  select code, descr, ll, lv, rl, rv, lv - rv,
         case when lv is null or rv is null then 'PENDING'
              when abs(lv - rv) < 1 then 'OK'
              -- Claiming less credit than 2B offers is allowed; claiming more is not.
              when code = 'ITC_3B_VS_2B' and lv < rv then 'OK'
              else 'DIFFERENCE' end
    from checks order by ord;
$$;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;
  execute 'grant select, insert, update, delete on public.gst_returns to authenticated';
  execute 'grant select, insert on public.gst_filed_documents, public.itc_claim_lines to authenticated';
  execute 'grant select, insert, update on public.gstr2b_imports, public.gstr2b_lines to authenticated';
  execute 'grant execute on function app.branch_gstin(uuid) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0085', 'gst_returns_2b_3b') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0086_orphan_branch_reference.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0086 — Repair: a profile pointing at a branch that no longer exists
-- =============================================================================
-- Found by the restore drill (scripts/restore-drill.sh, docs/backup-restore-
-- runbook.md): a logical backup of production could not be restored, because
-- one user_profiles row had a default_branch_id for a branch that had been
-- deleted. The foreign key is ON DELETE SET NULL, but the branch was removed by
-- scripts/remove-demo-dealer.sql under session_replication_role = replica, which
-- suspends foreign-key actions along with the checks, so the SET NULL never ran.
-- The live database worked (the reference is only a UI default), but a restore —
-- which re-creates the constraint — refused it. A backup that cannot be restored
-- is not a backup.
--
-- A scan of every foreign key in public and app found this one orphan and no
-- other. The script now clears such references before its sweep.
--
-- Rollback: none needed; the cleared value referred to nothing.
-- =============================================================================

update public.user_profiles p
   set default_branch_id = null
 where p.default_branch_id is not null
   and not exists (select 1 from public.branches b where b.id = p.default_branch_id);

insert into public.schema_migrations (version, name)
values ('0086', 'orphan_branch_reference') on conflict (version) do nothing;


commit;
