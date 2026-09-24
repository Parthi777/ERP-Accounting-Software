-- =============================================================================
-- 0079 — Stock adjustments reach the ledger
-- =============================================================================
-- Spec §21, §34, §35, §60.22 ("No silent stock adjustments").
--
-- 0036's header says of transfers, returns and adjustments: "each moves value,
-- so each writes a journal alongside whatever it moves … an adjustment that
-- changes quantity without touching the ledger leaves stock value disagreeing
-- with the balance sheet." adjust_inventory_stock() then wrote the stock
-- movement and no journal.
--
-- Found by the control-account tie-out (0077) on the demo dealer after an
-- upgrade rehearsal: accessory stock ₹900 above account 1600 and spare stock
-- ₹480 below 1700 — exactly the two adjustments on file, and nothing else.
--
-- Now an adjustment posts, in the same transaction as the movement:
--
--     count up    Inventory (1600/1700)  Dr   /  Stock Adjustments (5970)  Cr
--     count down  Stock Adjustments      Dr   /  Inventory                 Cr
--
-- at the cost the movement carries, so the stock value and the ledger move by
-- the same amount. Accounts are resolved from accounting rules (spec §22), seeded
-- here as INVENTORY / ADJUSTMENT and remappable per dealer.
--
-- ── And they could not be made at all, from the application ────────────────
--
-- Writing the test for the above as the dealer owner under `authenticated`
-- (as the app runs) rather than as the database owner found a second defect:
-- adjust_inventory_stock() and transfer_inventory_stock() read the stock lot
-- with SELECT … FOR UPDATE, and inventory_stock has a SELECT policy and no
-- UPDATE policy — it is maintained by a SECURITY DEFINER trigger, by design.
-- Under RLS, FOR UPDATE only returns rows the caller could update, so the read
-- found nothing: every stock decrease was refused with "Only 0 in stock", every
-- branch transfer with "Only 0 in … stock at the source branch", and increases
-- were costed at standard cost instead of the lot's average. The seed data runs
-- as the owner, which is why the demo dealer has adjustments on file at all.
--
-- app.lock_stock_lot() takes the lock with definer rights, for the caller's own
-- dealer only, and both functions now use it.
--
-- Adjustments made BEFORE this migration are not journalled retrospectively:
-- a silent catch-up posting would be exactly the kind of unexplained ledger
-- movement this migration exists to stop. The tie-out shows the difference and
-- the notice below counts them; Accounts clears them with a manual journal
-- whose narration says what it is.
--
-- Rollback: restore public.adjust_inventory_stock and
--           public.transfer_inventory_stock from 0036; drop app.lock_stock_lot; restore
--           app.seed_purchase_accounting_rules by renaming the _0052 function;
--           drop app.seed_adjustment_accounting_rules. Posted journals stay.
-- =============================================================================

create or replace function app.seed_adjustment_accounting_rules(p_dealer_id uuid)
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
      ('INVENTORY', 'ADJUSTMENT', 'ACCESSORY_INVENTORY', 'DEBIT',  '1600'),
      ('INVENTORY', 'ADJUSTMENT', 'SPARE_INVENTORY',     'DEBIT',  '1700'),
      ('INVENTORY', 'ADJUSTMENT', 'VARIANCE',            'CREDIT', '5970')
    ) as t(module, event, component, side, account_code)
  loop
    select id into v_account from public.chart_of_accounts
     where dealer_id = p_dealer_id and code = v_rule.account_code;
    continue when v_account is null;

    insert into public.accounting_rules
      (dealer_id, module, event, component, side, account_id, description)
    values
      (p_dealer_id, v_rule.module, v_rule.event, v_rule.component, v_rule.side,
       v_account, 'Stock adjustments (0079)')
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
    perform app.seed_adjustment_accounting_rules(d.id);
  end loop;
end $$;

-- Provisioning and the seed both call seed_purchase_accounting_rules; chaining
-- onto it means a new dealer gets these rules without either being edited.
alter function app.seed_purchase_accounting_rules(uuid) rename to seed_purchase_accounting_rules_0052;

create or replace function app.seed_purchase_accounting_rules(p_dealer_id uuid)
returns integer
language plpgsql
as $$
begin
  return app.seed_purchase_accounting_rules_0052(p_dealer_id)
       + app.seed_adjustment_accounting_rules(p_dealer_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- app.lock_stock_lot() — lock a lot and read it, whatever the caller's policies
-- -----------------------------------------------------------------------------
create or replace function app.lock_stock_lot(
  p_item_id   uuid,
  p_branch_id uuid,
  p_source    text
)
returns table (quantity numeric(14, 3), average_cost numeric(18, 4))
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_dealer uuid;
begin
  select i.dealer_id into v_dealer from public.inventory_items i where i.id = p_item_id;

  -- Definer rights, so the tenant check is explicit: a dealer user reaches only
  -- their own lots. auth.uid() is null for the service role and migrations.
  if v_dealer is null
     or (auth.uid() is not null
         and not app.is_platform_admin()
         and v_dealer is distinct from app.current_dealer_id()) then
    raise exception 'Item not found.' using errcode = 'no_data_found';
  end if;
  if not exists (select 1 from public.branches b where b.id = p_branch_id and b.dealer_id = v_dealer) then
    raise exception 'That branch does not belong to this dealer.' using errcode = 'insufficient_privilege';
  end if;

  return query
    select s.quantity, s.average_cost
      from public.inventory_stock s
     where s.item_id = p_item_id and s.branch_id = p_branch_id and s.source = p_source
       for update;
end;
$$;

revoke execute on function app.lock_stock_lot(uuid, uuid, text) from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function app.lock_stock_lot(uuid, uuid, text) to authenticated';
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- public.transfer_inventory_stock() — as 0036, reading the lot through the lock
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
end;
$$;

-- -----------------------------------------------------------------------------
-- public.adjust_inventory_stock() — the movement and its journal, together
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
  if p_source not in ('LOCAL', 'COMPANY') then
    raise exception 'Source must be LOCAL or COMPANY.' using errcode = 'check_violation';
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

comment on function public.adjust_inventory_stock(uuid, uuid, text, numeric, text) is
  'A counted-stock correction (spec §35): the movement and its journal against '
  'Stock Adjustments, at the movement''s cost, in one transaction. A reason is '
  'required and kept on both.';

-- -----------------------------------------------------------------------------
-- What was adjusted before this, without a journal
-- -----------------------------------------------------------------------------
do $$
declare
  v_count integer;
  v_net   numeric;
begin
  select count(*), coalesce(sum(value), 0) into v_count, v_net
    from public.inventory_transactions
   where transaction_type = 'ADJUSTMENT' and reference_id is null;

  if v_count > 0 then
    raise notice '0079: % earlier stock adjustment(s), net value %, were never journalled. Accounting → Control Tie-out shows the difference; clear it with a manual journal to 5970.', v_count, v_net;
  end if;
end $$;

insert into public.schema_migrations (version, name)
values ('0079', 'stock_adjustment_posting') on conflict (version) do nothing;
