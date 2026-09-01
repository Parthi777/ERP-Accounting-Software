-- =============================================================================
-- 0049 — Money received reaches the cash and bank books; accessory cost reaches
--        the accessory accounts
-- =============================================================================
-- Spec §21, §24, §28, §36, §37, §38, §41, §59.
--
-- Two defects, both found by seeding a full set of trading data through the real
-- posting functions and then reconciling the reports against the ledger.
--
-- ── 1. The cash and bank books do not see money taken by other modules ───────
--
-- public.cash_book() reads public.cash_transactions, and public.bank_book() reads
-- public.bank_transactions. Only three functions have ever written to those
-- tables: record_cash_transaction, record_bank_transaction and (since 0046)
-- refund_booking_advance.
--
-- Meanwhile a booking advance, a vehicle sale receipt and a service receipt all
-- debit the cash or bank ledger account directly and write no subsidiary row at
-- all. So the money is in the general ledger and absent from the book that is
-- supposed to itemise it. On a representative day's trading that was ₹50,647.60
-- of receipts missing from the cash book — every cash receipt the business took
-- other than through the cash-book screen itself.
--
-- Spec §36 makes the daily cash book mandatory and §37 defines it as every
-- receipt and payment with a running balance; §59 requires reports to reconcile
-- with transaction data. A cash book that omits the takings is not a cash book,
-- and the day-close difference it computes is meaningless — expected closing was
-- being derived from a fraction of the day's movements.
--
-- Fixed by giving the three functions a shared helper that writes the subsidiary
-- row alongside the journal they already post.
--
-- ── 2. Accessory cost is charged to vehicle and spare accounts ──────────────
--
-- Accounts 1600 (Accessories Inventory) and 5200 (Accessories COGS) exist in
-- every dealer's chart of accounts and had never received a single entry.
--
-- post_vehicle_sale summed cost_amount across all invoice lines into one figure
-- and posted it to SALES/INVOICE/COGS → 5100, so accessories fitted to a vehicle
-- were charged to Vehicle COGS. post_service_invoice did the same into
-- SERVICE/INVOICE/COGS → 5300, so accessories sold over the counter were charged
-- to Spare COGS.
--
-- Spec §24 lists the accessory accounts separately and §41 requires an
-- accessories margin report for owners and accounts. Neither can be derived from
-- a ledger that never posts to them, and both the vehicle and the spare margin
-- were overstated in cost by the accessory content.
--
-- Fixed by classifying the cost by what was actually sold before posting it.
--
-- Rollback: restore public.create_booking_with_advance and public.record_sale_payment
--           from 0028, public.record_sale_payment from 0043, public.record_service_payment
--           and public.post_service_invoice from 0033, public.post_vehicle_sale
--           from 0025; drop app.record_money_movement and
--           app.seed_cogs_accounting_rules; delete the accounting_rules rows
--           whose description is 'Cost classification (0049)'.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Accounting rules for the accessory cost accounts
-- -----------------------------------------------------------------------------
-- Added as new components rather than by repointing COGS/INVENTORY, so a dealer
-- who has already mapped those to their own accounts keeps that mapping. The
-- existing COGS/INVENTORY components keep their meaning: the module's primary
-- stock — vehicles for a sale, spares for a service invoice.
create or replace function app.seed_cogs_accounting_rules(p_dealer_id uuid)
returns integer
language plpgsql
as $$
declare
  v_added integer := 0;
  v_rule  record;
  v_account uuid;
begin
  for v_rule in
    select * from (values
      ('SALES',   'INVOICE', 'ACCESSORY_COGS',      'DEBIT',  '5200'),
      ('SALES',   'INVOICE', 'ACCESSORY_INVENTORY', 'CREDIT', '1600'),
      ('SERVICE', 'INVOICE', 'ACCESSORY_COGS',      'DEBIT',  '5200'),
      ('SERVICE', 'INVOICE', 'ACCESSORY_INVENTORY', 'CREDIT', '1600')
    ) as t(module, event, component, side, account_code)
  loop
    select id into v_account
      from public.chart_of_accounts
     where dealer_id = p_dealer_id and code = v_rule.account_code;

    -- A dealer running a chart of accounts of their own may not have this code.
    -- Skipping is right: the posting paths below fall back to the module's
    -- existing COGS mapping when no accessory rule is configured, so nothing
    -- breaks — the split simply does not happen for them.
    continue when v_account is null;

    insert into public.accounting_rules
      (dealer_id, module, event, component, side, account_id, description)
    values
      (p_dealer_id, v_rule.module, v_rule.event, v_rule.component, v_rule.side,
       v_account, 'Cost classification (0049)')
    on conflict do nothing;

    if found then v_added := v_added + 1; end if;
  end loop;

  return v_added;
end;
$$;

comment on function app.seed_cogs_accounting_rules(uuid) is
  'Maps accessory cost and accessory stock relief to accounts 5200 and 1600 '
  '(spec §24). Skips any code the dealer does not have; the posting paths fall '
  'back to the module COGS mapping when a rule is absent.';

do $$
declare d record;
begin
  for d in select id from public.dealers loop
    perform app.seed_cogs_accounting_rules(d.id);
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- Every branch has a cash account — spec §36, now actually guaranteed
-- -----------------------------------------------------------------------------
-- cash_accounts has carried `unique (branch_id)` since 0022, but nothing ever
-- created the row: seed.sql does not, and neither does branch creation. Every
-- branch in existence has been without one, which is why nothing noticed that
-- receipts were not reaching the cash book — there was nowhere to put them.
--
-- SECURITY DEFINER because cash_accounts_write requires admin.settings.manage,
-- and the point is that this happens automatically rather than being remembered.
-- It only ever inserts a row for the branch being created, so there is nothing a
-- caller can steer.
create or replace function app.branches_ensure_cash_account()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account uuid;
begin
  v_account := public.resolve_account(new.dealer_id, 'CASH', 'RECEIPT', 'CASH', new.id);

  if v_account is null then
    select id into v_account from public.chart_of_accounts
     where dealer_id = new.dealer_id and code = '1100';
  end if;

  -- A branch can be created before the chart of accounts exists. Skipping leaves
  -- the backfill below to catch it once the accounts are in place.
  if v_account is null then
    return new;
  end if;

  insert into public.cash_accounts (dealer_id, branch_id, name, ledger_account_id)
  values (new.dealer_id, new.id, new.name || ' — Cash', v_account)
  on conflict (branch_id) do nothing;

  return new;
end;
$$;

drop trigger if exists branches_ensure_cash_account on public.branches;
create trigger branches_ensure_cash_account
  after insert on public.branches
  for each row execute function app.branches_ensure_cash_account();

-- The same logic, callable: a branch is often created before the chart of
-- accounts exists (seed.sql does exactly that), so the trigger above cannot
-- always succeed at insert time. seed.sql calls this once the accounts are in.
create or replace function app.ensure_branch_cash_accounts(p_dealer_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  b record;
  v_account uuid;
  v_made int := 0;
begin
  for b in
    select br.id, br.dealer_id, br.name
      from public.branches br
      left join public.cash_accounts ca on ca.branch_id = br.id
     where ca.id is null
       and (p_dealer_id is null or br.dealer_id = p_dealer_id)
  loop
    v_account := public.resolve_account(b.dealer_id, 'CASH', 'RECEIPT', 'CASH', b.id);
    if v_account is null then
      select id into v_account from public.chart_of_accounts
       where dealer_id = b.dealer_id and code = '1100';
    end if;
    continue when v_account is null;

    insert into public.cash_accounts (dealer_id, branch_id, name, ledger_account_id)
    values (b.dealer_id, b.id, b.name || ' — Cash', v_account)
    on conflict (branch_id) do nothing;
    v_made := v_made + 1;
  end loop;

  return v_made;
end;
$$;

comment on function app.ensure_branch_cash_accounts(uuid) is
  'Creates the missing per-branch cash account required by spec §36. Safe to '
  'call repeatedly; skips branches whose dealer has no cash ledger account yet.';

-- Backfill every branch that already exists.
do $$
declare v_made int;
begin
  v_made := app.ensure_branch_cash_accounts();
  if v_made > 0 then
    raise notice '0049: created % missing branch cash account(s).', v_made;
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- The roles that take the money must be allowed to write the book
-- -----------------------------------------------------------------------------
-- ct_insert admitted only cashbook.receipts.create / cashbook.payments.create,
-- which CASHIER and COUNTER_SALES hold but SALES_EXECUTIVE and SERVICE_ADVISOR
-- do not. Without this, the helper below would turn a sales executive's booking
-- advance and a service advisor's receipt — both already authorized, both
-- already posting a journal — into an RLS failure.
--
-- Same reasoning as 0043 adding finance.applications.manage to ft_insert and
-- 0045 adding sales.deliver to cv_write: the subsidiary row is part of the act
-- the user is already permitted to perform, not a separate privilege.
drop policy if exists ct_insert on public.cash_transactions;

create policy ct_insert on public.cash_transactions for insert to authenticated
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('cashbook.receipts.create')
                  or app.has_permission('cashbook.payments.create')
                  or app.has_permission('bookings.create')
                  or app.has_permission('bookings.refund')
                  or app.has_permission('sales.create')
                  or app.has_permission('service.payments.collect')
                  or app.has_permission('inventory.counter_sale.create'))));

drop policy if exists bt_write on public.bank_transactions;

create policy bt_write on public.bank_transactions for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('bank.reconcile')
                  or app.has_permission('cashbook.payments.create'))))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('bank.reconcile')
                  or app.has_permission('cashbook.payments.create')
                  or app.has_permission('bookings.create')
                  or app.has_permission('bookings.refund')
                  or app.has_permission('sales.create')
                  or app.has_permission('service.payments.collect')
                  or app.has_permission('inventory.counter_sale.create'))));

-- The USING clause stays narrow on purpose: taking a payment writes a row, it
-- does not amend or reconcile one. Only bank.reconcile and cashbook.payments.create
-- can touch a bank row after the fact.

-- -----------------------------------------------------------------------------
-- app.record_money_movement() — the subsidiary row behind a posted receipt
-- -----------------------------------------------------------------------------
-- Called after the journal is posted, by every function that takes or returns
-- money outside the cash-book and bank-book screens. It writes the cash or bank
-- row that makes the movement visible in the book, and nothing else — the
-- journal is already written and is not touched here.
--
-- Three modes, and the third is the interesting one:
--
--   CASH     — opens the day if needed and writes a cash_transactions row.
--   BANK etc — writes a bank_transactions row against the branch's account.
--   FINANCE  — writes nothing, deliberately. A sale settled by finance has moved
--              the debt to the finance company; no money has arrived yet, and it
--              must not appear in a book that says it has. The disbursement is
--              what hits the bank, and disburse_finance_application already
--              writes that row.
create or replace function app.record_money_movement(
  p_dealer_id   uuid,
  p_branch_id   uuid,
  p_date        date,
  p_mode        text,
  p_direction   text,      -- RECEIPT | PAYMENT
  p_amount      numeric,
  p_particular  text,
  p_reference   text,
  p_journal_entry_id uuid,
  p_customer_id uuid default null
)
returns void
language plpgsql
as $$
declare
  v_cash public.cash_accounts;
  v_bank uuid;
begin
  if p_mode = 'FINANCE' then
    return;
  end if;

  if p_mode = 'CASH' then
    select * into v_cash from public.cash_accounts
     where branch_id = p_branch_id and status = 'ACTIVE';

    -- A branch with no cash account cannot have a cash book. Silence here would
    -- reintroduce exactly the defect this migration exists to close.
    if v_cash.id is null then
      raise exception 'Branch has no active cash account, so this receipt cannot reach the cash book.'
        using errcode = 'no_data_found',
              hint = 'Create a cash account for the branch (spec §36: each branch has one).';
    end if;

    -- Opens the day, and refuses if it is already closed (spec §36).
    perform public.ensure_cash_day(p_branch_id, p_date);

    insert into public.cash_transactions
      (dealer_id, branch_id, cash_account_id, business_date, direction, amount,
       particular, reference_number, customer_id, journal_entry_id, created_by)
    values
      (p_dealer_id, p_branch_id, v_cash.id, p_date, p_direction, p_amount,
       p_particular, p_reference, p_customer_id, p_journal_entry_id, auth.uid());

    return;
  end if;

  -- Anything else settles through a bank account: the branch's own, else the
  -- dealer-wide one.
  select id into v_bank from public.bank_accounts
   where dealer_id = p_dealer_id and status = 'ACTIVE' and branch_id = p_branch_id
   order by created_at limit 1;

  if v_bank is null then
    select id into v_bank from public.bank_accounts
     where dealer_id = p_dealer_id and status = 'ACTIVE' and branch_id is null
     order by created_at limit 1;
  end if;

  -- Unlike cash, this one does not raise. A dealer may genuinely have no bank
  -- account configured yet and still take a UPI payment on day one; refusing the
  -- receipt would be a worse failure than a bank book that has nothing to show.
  -- The journal is posted either way, so no money is lost — only the subsidiary
  -- row is skipped, and it reappears as soon as an account exists.
  if v_bank is null then
    return;
  end if;

  insert into public.bank_transactions
    (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
     reference_number, customer_id, journal_entry_id, created_by)
  values
    (p_dealer_id, v_bank, p_date, p_direction, p_amount, p_particular,
     p_reference, p_customer_id, p_journal_entry_id, auth.uid());
end;
$$;

comment on function app.record_money_movement(uuid, uuid, date, text, text, numeric, text, text, uuid, uuid) is
  'Writes the cash_transactions or bank_transactions row behind a receipt that '
  'another module has already journalled, so the cash book (spec §37) and bank '
  'book (spec §38) show it. FINANCE writes nothing: the money has not arrived.';

-- -----------------------------------------------------------------------------
-- public.create_booking_with_advance() — spec §18
-- -----------------------------------------------------------------------------
-- Unchanged from 0028 apart from the closing call: the advance now reaches the
-- cash or bank book.
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
    (dealer_id, booking_id, receipt_number, amount, payment_mode, reference,
     journal_entry_id, created_by)
  values
    (v_dealer_id, v_booking, v_rnumber, p_advance_amount, p_payment_mode, p_reference,
     v_entry, auth.uid());

  -- Reserving a specific chassis takes it out of available stock (spec §13).
  if p_vehicle_id is not null then
    update public.vehicles set status = 'BOOKED', updated_by = auth.uid()
     where id = p_vehicle_id and status = 'IN_STOCK';
  end if;

  -- 0049: and into the cash or bank book, which is where the cashier looks.
  perform app.record_money_movement(
    v_dealer_id, p_branch_id, current_date, p_payment_mode, 'RECEIPT',
    p_advance_amount, 'Booking advance ' || v_bnumber, coalesce(p_reference, v_rnumber),
    v_entry, p_customer_id);

  booking_id := v_booking; booking_number := v_bnumber;
  receipt_number := v_rnumber; journal_entry_id := v_entry;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_sale_payment() — spec §19, §27
-- -----------------------------------------------------------------------------
-- Carries forward from 0043: the FINANCE_RECEIVABLE line stays party-tagged to
-- the finance company and a FINANCE payment still writes its finance_transactions
-- row. New in 0049: a cash or bank receipt reaches its book.
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

  -- 0049: FINANCE returns immediately inside the helper — no money has moved.
  perform app.record_money_movement(
    v_sale.dealer_id, v_sale.branch_id, current_date, p_payment_mode, 'RECEIPT',
    p_amount, 'Receipt ' || v_rnumber || ' — ' || v_sale.invoice_number,
    coalesce(p_reference, v_rnumber), v_entry, v_sale.customer_id);

  receipt_number := v_rnumber; journal_entry_id := v_entry;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_service_payment() — spec §32, §33
-- -----------------------------------------------------------------------------
-- Unchanged from 0033 apart from the closing call. Counter sales come through
-- here too, so this is what puts counter takings into the cash book.
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

  -- 0049: counter and workshop takings reach the cash book.
  perform app.record_money_movement(
    v_invoice.dealer_id, v_invoice.branch_id, p_date, p_payment_mode, 'RECEIPT',
    p_amount, 'Receipt ' || v_number || ' — ' || v_invoice.invoice_number,
    coalesce(p_reference, v_number), v_entry, v_invoice.customer_id);

  select si.total_amount - si.paid_amount into v_balance
    from public.service_invoices si where si.id = p_invoice_id;

  payment_id := v_id; receipt_number := v_number; balance_due := v_balance;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.post_vehicle_sale() — spec §19, §22, §24
-- -----------------------------------------------------------------------------
-- Carries forward from 0025 unchanged, except that the cost accumulator is split
-- in two: what came out of vehicle stock, and what came out of accessory stock.
-- FITTING and ACCESSORY lines are accessories; everything else with a cost is
-- the vehicle. Charges that carry no stock — insurance, registration, forwarding
-- — have no cost_amount and contribute to neither.
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
  v_line    record;
  v_cogs    numeric(18, 4) := 0;   -- vehicle stock
  v_acc_cogs numeric(18, 4) := 0;  -- accessory stock
  v_acc_debit  uuid;
  v_acc_credit uuid;
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

    -- 0049: accessory cost is accessory cost, whichever invoice it rides on.
    if v_line.line_type in ('FITTING', 'ACCESSORY') then
      v_acc_cogs := v_acc_cogs + coalesce(v_line.cost, 0);
    else
      v_cogs := v_cogs + coalesce(v_line.cost, 0);
    end if;
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
                         'debit', v_cogs, 'credit', 0, 'narration', 'Vehicle cost of goods sold'),
      jsonb_build_object('account_id', app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'INVENTORY', v_sale.branch_id),
                         'debit', 0, 'credit', v_cogs, 'narration', 'Vehicle stock relieved'));
  end if;

  if v_acc_cogs > 0 then
    -- resolve_account rather than require_account: a dealer whose chart has no
    -- 1600/5200 keeps the pre-0049 behaviour instead of being unable to post.
    v_acc_debit  := public.resolve_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'ACCESSORY_COGS', v_sale.branch_id);
    v_acc_credit := public.resolve_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'ACCESSORY_INVENTORY', v_sale.branch_id);

    if v_acc_debit is null or v_acc_credit is null then
      v_acc_debit  := app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'COGS', v_sale.branch_id);
      v_acc_credit := app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'INVENTORY', v_sale.branch_id);
    end if;

    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('account_id', v_acc_debit, 'debit', v_acc_cogs, 'credit', 0,
                         'narration', 'Accessories cost of goods sold'),
      jsonb_build_object('account_id', v_acc_credit, 'debit', 0, 'credit', v_acc_cogs,
                         'narration', 'Accessory stock relieved'));
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

-- -----------------------------------------------------------------------------
-- public.post_service_invoice() — spec §32, §33, §24
-- -----------------------------------------------------------------------------
-- Carries forward from 0033 unchanged, except that stock relief is accumulated
-- per item type as it is allocated, so a counter sale of helmets no longer
-- charges Spare COGS.
create or replace function public.post_service_invoice(
  p_invoice_id      uuid,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_invoice public.service_invoices;
  v_dealer  uuid;
  v_branch  uuid;
  v_lines   jsonb := '[]'::jsonb;
  v_entry   uuid;
  v_line    record;
  v_alloc   record;
  v_cogs    numeric(18, 4) := 0;   -- spares
  v_acc_cogs numeric(18, 4) := 0;  -- accessories
  v_remaining numeric(14, 3);
  v_acc_debit  uuid;
  v_acc_credit uuid;
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
  -- item_type comes along for the ride so the cost can be classified (0049).
  for v_line in
    select sl.id, sl.item_id, sl.quantity, sl.unit_rate, sl.line_number, i.item_type
      from public.service_lines sl
      join public.inventory_items i on i.id = sl.item_id
     where sl.invoice_id = p_invoice_id and sl.item_id is not null
     order by sl.line_number
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

      if v_line.item_type = 'ACCESSORY' then
        v_acc_cogs := v_acc_cogs + round(v_alloc.quantity * v_alloc.unit_cost, 2);
      else
        v_cogs := v_cogs + round(v_alloc.quantity * v_alloc.unit_cost, 2);
      end if;
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

  if v_acc_cogs > 0 then
    v_acc_debit  := public.resolve_account(v_dealer, 'SERVICE', 'INVOICE', 'ACCESSORY_COGS', v_branch);
    v_acc_credit := public.resolve_account(v_dealer, 'SERVICE', 'INVOICE', 'ACCESSORY_INVENTORY', v_branch);

    if v_acc_debit is null or v_acc_credit is null then
      v_acc_debit  := app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'COGS', v_branch);
      v_acc_credit := app.require_account(v_dealer, 'SERVICE', 'INVOICE', 'INVENTORY', v_branch);
    end if;

    v_lines := v_lines
      || jsonb_build_object('account_id', v_acc_debit, 'debit', v_acc_cogs, 'credit', 0,
                            'narration', 'Cost of accessories sold')
      || jsonb_build_object('account_id', v_acc_credit, 'debit', 0, 'credit', v_acc_cogs,
                            'narration', 'Accessories issued from stock');
  end if;

  v_entry := app.post_journal(
    v_dealer, v_branch, v_invoice.invoice_date, 'SERVICE',
    'Service invoice ' || v_invoice.invoice_number,
    v_lines, 'SERVICE_INVOICE', p_invoice_id,
    coalesce(p_idempotency_key, 'service:' || p_invoice_id::text));

  update public.service_invoices
     set status = 'POSTED', posted_at = now(), journal_entry_id = v_entry,
         total_cost = v_cogs + v_acc_cogs,
         idempotency_key = coalesce(p_idempotency_key, 'service:' || p_invoice_id::text),
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
-- Grants
-- -----------------------------------------------------------------------------
-- create or replace preserves the grants on the public functions above; the new
-- app helper needs its own.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function app.record_money_movement(uuid, uuid, date, text, text, numeric, text, text, uuid, uuid) to authenticated';
  end if;
end;
$$;
