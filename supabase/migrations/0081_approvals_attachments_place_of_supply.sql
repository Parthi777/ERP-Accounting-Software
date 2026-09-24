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
