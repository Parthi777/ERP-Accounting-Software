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
