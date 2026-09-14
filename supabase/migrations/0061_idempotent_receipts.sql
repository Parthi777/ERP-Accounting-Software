-- =============================================================================
-- 0061 — A retried receipt is the same receipt (spec §50)
-- =============================================================================
-- Spec §50, §36, §37, §38, §48.
--
-- What is broken. record_sale_payment, record_cash_transaction and
-- record_bank_transaction have no duplicate protection of any kind. Submit one
-- twice — a double-click that outran the disabled button, a phone that retried
-- on a flaky shop connection, a browser that resent the POST — and the dealer
-- has two receipts, two journals, and a cash book that is over by the amount.
--
-- Nothing downstream catches it. These are not corrections that a later screen
-- reconciles; they are the primary record. The cash book balances perfectly
-- against a day that never happened.
--
-- ── The slot that was there and did nothing ─────────────────────────────────
--
-- record_sale_payment already passed an idempotency key to app.post_journal:
--
--     'receipt:' || v_rnumber
--
-- where v_rnumber is minted from the document sequence two lines earlier. A
-- fresh number every call, so the key is unique every call, so it can never
-- match — the parameter was filled in and inert. Journal-level protection would
-- not have been enough anyway: a second call getting the first journal id back
-- would still insert a second sale_payments row against it, putting the receipt
-- twice in the receipts list and once in the trial balance, hidden from the one
-- report that would have caught it.
--
-- So the guard belongs at the top of each function, on its own document table,
-- before any sequence is consumed.
--
-- ── Why not a generic idempotency table ─────────────────────────────────────
--
-- A shared app-level table would be a second source of truth that any direct
-- RPC call bypasses, and a check-then-insert against it has a race that a unique
-- constraint does not. The constraint *is* the mechanism. 0057 already works
-- this way for purchase returns; this follows it.
--
-- ── What is deliberately NOT changed ────────────────────────────────────────
--
-- post_vehicle_sale, post_purchase_bill and post_service_invoice accept a key
-- and default it to one derived from the document id — 'sale:' || id, and so on.
-- That is strictly better than a client-minted key for posting an existing
-- document: it dedupes across sessions, devices and page refreshes, because the
-- key is a property of the document rather than of a browser tab. They are left
-- alone on purpose.
--
-- The distinction worth keeping: *posting* an existing document derives its key
-- from the document; *creating* one has no id yet, so the caller must supply it.
-- This migration covers the second kind.
--
-- Rollback: restore the three functions from 0041 and 0049, then
--   alter table public.cash_transactions drop column idempotency_key;  (&c.)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The columns, and the constraints that do the actual work
-- -----------------------------------------------------------------------------
-- Partial unique indexes: null keys are exempt, so every existing row and every
-- caller that does not supply one is unaffected. Scoped by dealer, because one
-- tenant must not be able to poison another's key namespace.
alter table public.cash_transactions add column if not exists idempotency_key text;
alter table public.bank_transactions add column if not exists idempotency_key text;
alter table public.sale_payments     add column if not exists idempotency_key text;

create unique index if not exists cash_txn_idempotency_key
  on public.cash_transactions (dealer_id, idempotency_key) where idempotency_key is not null;
create unique index if not exists bank_txn_idempotency_key
  on public.bank_transactions (dealer_id, idempotency_key) where idempotency_key is not null;
create unique index if not exists sale_payment_idempotency_key
  on public.sale_payments (dealer_id, idempotency_key) where idempotency_key is not null;

comment on column public.cash_transactions.idempotency_key is
  'Caller-supplied key making a retry replay rather than repeat (spec §50). Null '
  'for entries made before 0061 and for callers that do not supply one.';

-- -----------------------------------------------------------------------------
-- public.record_cash_transaction() — spec §37, now idempotent
-- -----------------------------------------------------------------------------
-- Adding a parameter needs a drop: `create or replace` with a different argument
-- list makes an *overload*, and supabase-js sends named arguments, so a call
-- omitting the new one becomes ambiguous and fails with PGRST203. Precedent for
-- the drop-and-recreate is 0041 itself.
-- -----------------------------------------------------------------------------
drop function if exists public.record_cash_transaction(uuid, text, numeric, text, uuid, uuid, text, date, uuid);

create function public.record_cash_transaction(
  p_branch_id   uuid,
  p_direction   text,
  p_amount      numeric,
  p_particular  text,
  p_account_id  uuid,
  p_customer_id uuid default null,
  p_reference   text default null,
  p_date        date default current_date,
  p_supplier_id uuid default null,
  p_idempotency_key text default null
)
returns table (transaction_id bigint, journal_entry_id uuid, balance_after numeric)
language plpgsql
as $$
declare
  v_dealer   uuid;
  v_account  public.cash_accounts;
  v_entry    uuid;
  v_cash_acc uuid;
  v_txn      bigint;
  v_balance  numeric(18, 4);
  v_party    text;
  v_party_id uuid;
begin
  if p_amount <= 0 then
    raise exception 'The amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_direction not in ('RECEIPT', 'PAYMENT') then
    raise exception 'Direction must be RECEIPT or PAYMENT.' using errcode = 'check_violation';
  end if;
  -- A journal line carries one party. Two would make the entry belong to both
  -- subsidiary ledgers and reconcile against neither.
  if p_customer_id is not null and p_supplier_id is not null then
    raise exception 'An entry belongs to a customer or a supplier, not both.'
      using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer from public.branches where id = p_branch_id;

  -- ── The guard (spec §50) ────────────────────────────────────────────────
  -- Before ensure_cash_day, deliberately. A retry arriving after the day was
  -- closed must replay the receipt it already wrote, not raise "the day is
  -- closed" at someone who is looking at a spinner.
  if p_idempotency_key is not null then
    select t.id, t.journal_entry_id, t.balance_after
      into v_txn, v_entry, v_balance
      from public.cash_transactions t
     where t.dealer_id = v_dealer
       and t.idempotency_key = p_idempotency_key;

    if v_txn is not null then
      transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
      return next;
      return;
    end if;
  end if;

  select * into v_account from public.cash_accounts where branch_id = p_branch_id;

  if v_account.id is null then
    raise exception 'This branch has no cash account.' using errcode = 'no_data_found';
  end if;

  -- Opens the day if needed, and fails if it is already closed (spec §36).
  perform public.ensure_cash_day(p_branch_id, p_date);

  v_cash_acc := v_account.ledger_account_id;

  v_party := case
               when p_customer_id is not null then 'CUSTOMER'
               when p_supplier_id is not null then 'SUPPLIER'
             end;
  v_party_id := coalesce(p_customer_id, p_supplier_id);

  -- A receipt debits cash and credits whatever the money was for; a payment is
  -- the mirror. The contra account is chosen by the operator, because "what was
  -- this for" is a judgement the software cannot make.
  v_entry := app.post_journal(
    v_dealer, p_branch_id, p_date,
    'CASH',
    p_particular,
    case when p_direction = 'RECEIPT' then
      jsonb_build_array(
        jsonb_build_object('account_id', v_cash_acc, 'debit', p_amount, 'credit', 0,
                           'narration', p_particular),
        jsonb_build_object('account_id', p_account_id, 'debit', 0, 'credit', p_amount,
                           'narration', p_particular,
                           'party_type', v_party, 'party_id', v_party_id)
      )
    else
      jsonb_build_array(
        jsonb_build_object('account_id', p_account_id, 'debit', p_amount, 'credit', 0,
                           'narration', p_particular,
                           'party_type', v_party, 'party_id', v_party_id),
        jsonb_build_object('account_id', v_cash_acc, 'debit', 0, 'credit', p_amount,
                           'narration', p_particular)
      )
    end,
    'CASH_BOOK', null,
    case when p_idempotency_key is null then null else 'cash:' || p_idempotency_key end
  );

  insert into public.cash_transactions
    (dealer_id, branch_id, cash_account_id, business_date, direction, amount,
     particular, reference_number, customer_id, supplier_id, journal_entry_id,
     idempotency_key, created_by)
  values
    (v_dealer, p_branch_id, v_account.id, p_date, p_direction, p_amount,
     p_particular, p_reference, p_customer_id, p_supplier_id, v_entry,
     p_idempotency_key, auth.uid())
  returning id, cash_transactions.balance_after into v_txn, v_balance;

  transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_bank_transaction() — spec §38, now idempotent
-- -----------------------------------------------------------------------------
drop function if exists public.record_bank_transaction(uuid, text, numeric, text, uuid, date, text, text, text, uuid, uuid);

create function public.record_bank_transaction(
  p_bank_account_id uuid,
  p_direction       text,
  p_amount          numeric,
  p_particular      text,
  p_account_id      uuid,
  p_date            date default current_date,
  p_reference       text default null,
  p_utr             text default null,
  p_instrument      text default null,
  p_customer_id     uuid default null,
  p_supplier_id     uuid default null,
  p_idempotency_key text default null
)
returns table (transaction_id bigint, journal_entry_id uuid, balance_after numeric)
language plpgsql
as $$
declare
  v_bank     public.bank_accounts;
  v_entry    uuid;
  v_txn      bigint;
  v_balance  numeric(18, 4);
  v_party    text;
  v_party_id uuid;
begin
  if p_amount <= 0 then
    raise exception 'The amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_direction not in ('RECEIPT', 'PAYMENT') then
    raise exception 'Direction must be RECEIPT or PAYMENT.' using errcode = 'check_violation';
  end if;
  if p_customer_id is not null and p_supplier_id is not null then
    raise exception 'An entry belongs to a customer or a supplier, not both.'
      using errcode = 'check_violation';
  end if;

  select * into v_bank from public.bank_accounts where id = p_bank_account_id;
  if v_bank.id is null then
    raise exception 'Bank account not found.' using errcode = 'no_data_found';
  end if;

  -- ── The guard (spec §50) ────────────────────────────────────────────────
  -- Before the ACTIVE check, for the same reason the cash guard precedes the
  -- day-close check: a retry must replay what it wrote, not report a state that
  -- changed after it wrote it.
  if p_idempotency_key is not null then
    select t.id, t.journal_entry_id, t.balance_after
      into v_txn, v_entry, v_balance
      from public.bank_transactions t
     where t.dealer_id = v_bank.dealer_id
       and t.idempotency_key = p_idempotency_key;

    if v_txn is not null then
      transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
      return next;
      return;
    end if;
  end if;

  if v_bank.status <> 'ACTIVE' then
    raise exception 'Bank account % is %.', v_bank.name, v_bank.status
      using errcode = 'check_violation';
  end if;

  v_party := case
               when p_customer_id is not null then 'CUSTOMER'
               when p_supplier_id is not null then 'SUPPLIER'
             end;
  v_party_id := coalesce(p_customer_id, p_supplier_id);

  v_entry := app.post_journal(
    v_bank.dealer_id, v_bank.branch_id, p_date,
    'BANK',
    p_particular,
    case when p_direction = 'RECEIPT' then
      jsonb_build_array(
        jsonb_build_object('account_id', v_bank.ledger_account_id, 'debit', p_amount, 'credit', 0,
                           'narration', p_particular),
        jsonb_build_object('account_id', p_account_id, 'debit', 0, 'credit', p_amount,
                           'narration', p_particular,
                           'party_type', v_party, 'party_id', v_party_id)
      )
    else
      jsonb_build_array(
        jsonb_build_object('account_id', p_account_id, 'debit', p_amount, 'credit', 0,
                           'narration', p_particular,
                           'party_type', v_party, 'party_id', v_party_id),
        jsonb_build_object('account_id', v_bank.ledger_account_id, 'debit', 0, 'credit', p_amount,
                           'narration', p_particular)
      )
    end,
    'BANK_BOOK', null,
    case when p_idempotency_key is null then null else 'bank:' || p_idempotency_key end
  );

  insert into public.bank_transactions
    (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
     reference_number, utr, instrument_number, customer_id, supplier_id,
     journal_entry_id, idempotency_key, created_by)
  values
    (v_bank.dealer_id, p_bank_account_id, p_date, p_direction, p_amount, p_particular,
     p_reference, nullif(btrim(p_utr), ''), nullif(btrim(p_instrument), ''),
     p_customer_id, p_supplier_id, v_entry, p_idempotency_key, auth.uid())
  returning id, bank_transactions.balance_after into v_txn, v_balance;

  transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
  return next;
end;
$$;


-- -----------------------------------------------------------------------------
-- public.record_sale_payment() — spec §19, §27, now idempotent
-- -----------------------------------------------------------------------------
-- The one with no defence whatever: a POSTED sale accepts payments repeatedly by
-- design, which is correct — a customer may pay in instalments — and is exactly
-- why a repeated submission is indistinguishable from a second instalment
-- without a key to tell them apart.
-- -----------------------------------------------------------------------------
drop function if exists public.record_sale_payment(uuid, numeric, text, text, uuid);

create function public.record_sale_payment(
  p_sale_id      uuid,
  p_amount       numeric,
  p_payment_mode text,
  p_reference    text default null,
  p_finance_company_id uuid default null,
  p_idempotency_key text default null
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
  -- ── The guard (spec §50) ────────────────────────────────────────────────
  -- After the row lock, so a concurrent retry waits rather than racing; before
  -- the status check, so a retry arriving after delivery replays its receipt
  -- instead of raising; and before next_document_number, so a replay does not
  -- burn a RECEIPT number. A gap in a financial series is not cosmetic.
  if p_idempotency_key is not null then
    select p.receipt_number, p.journal_entry_id
      into receipt_number, journal_entry_id
      from public.sale_payments p
     where p.dealer_id = v_sale.dealer_id
       and p.idempotency_key = p_idempotency_key;

    if receipt_number is not null then
      return next;
      return;
    end if;
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
    'SALE_PAYMENT', p_sale_id,
    -- Was 'receipt:' || v_rnumber, which is minted from the sequence a few lines
    -- above: a different key on every call, so it could never match and the
    -- parameter did nothing. The caller's key is the one that can.
    coalesce('receipt:' || p_idempotency_key, 'receipt:' || v_rnumber)
  );

  insert into public.sale_payments
    (dealer_id, sale_id, receipt_number, amount, payment_mode, reference,
     finance_company_id, journal_entry_id, idempotency_key, created_by)
  values
    (v_sale.dealer_id, p_sale_id, v_rnumber, p_amount, p_payment_mode, p_reference,
     p_finance_company_id, v_entry, p_idempotency_key, auth.uid());

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

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  -- Grants are per-signature and were dropped with the old functions.
  execute 'grant execute on function public.record_cash_transaction(uuid, text, numeric, text, uuid, uuid, text, date, uuid, text) to authenticated';
  execute 'grant execute on function public.record_bank_transaction(uuid, text, numeric, text, uuid, date, text, text, text, uuid, uuid, text) to authenticated';
  execute 'grant execute on function public.record_sale_payment(uuid, numeric, text, text, uuid, text) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0061', 'idempotent_receipts') on conflict (version) do nothing;
