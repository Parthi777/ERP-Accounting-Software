-- =============================================================================
-- 0030 — Cash book operations
-- =============================================================================
-- Spec §36, §37, §60.14, §60.15. The cash book is mandatory and so is the daily
-- close, so these are the operations that make both usable.
--
-- Each is a function for the same reason as the sale: a receipt written without
-- its journal is money the books never saw.
--
-- Rollback: drop the functions below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Fix: the cash difference was always NULL (bug in 0022)
-- -----------------------------------------------------------------------------
-- app.cash_day_guard() computed `new.difference := new.physical_cash -
-- new.expected_closing`, but expected_closing is a *generated* column and
-- PostgreSQL does not populate generated columns in NEW during a BEFORE trigger —
-- they are computed after it returns. So new.expected_closing was NULL, the
-- subtraction was NULL, and difference was silently NULL on every close.
--
-- That is the one number the daily close exists to produce: cash short or over.
-- Recomputing it from the base columns, which *are* populated.
-- -----------------------------------------------------------------------------
create or replace function app.cash_day_guard()
returns trigger
language plpgsql
as $$
declare
  v_expected numeric(18, 4);
begin
  if new.physical_cash is not null then
    v_expected := new.opening_balance + new.total_receipts - new.total_payments;
    new.difference := new.physical_cash - v_expected;
  end if;

  if tg_op = 'UPDATE' and old.status = 'CLOSED' and new.status <> 'CLOSED' then
    if new.reopen_reason is null then
      raise exception 'Reopening a closed day requires a reason.'
        using errcode = 'check_violation';
    end if;
    new.reopened_at := now();
  end if;

  return new;
end;
$$;

-- Any day already closed with a NULL difference gets it computed now.
update public.cash_day_closings
   set difference = physical_cash - (opening_balance + total_receipts - total_payments)
 where physical_cash is not null and difference is null;

-- -----------------------------------------------------------------------------
-- public.ensure_cash_day() — every branch has an open day
-- -----------------------------------------------------------------------------
-- Opening the day is bookkeeping, not a decision. Rather than making a cashier
-- press "open day" before the first receipt, the day is created on demand with
-- its opening balance carried from the previous close.
-- -----------------------------------------------------------------------------
create or replace function public.ensure_cash_day(
  p_branch_id uuid,
  p_date      date default current_date
)
returns uuid
language plpgsql
as $$
declare
  v_dealer  uuid;
  v_account public.cash_accounts;
  v_day     uuid;
  v_opening numeric(18, 4);
begin
  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  select * into v_account from public.cash_accounts where branch_id = p_branch_id;

  -- A branch without a cash account cannot take cash (spec §36).
  if v_account.id is null then
    raise exception 'This branch has no cash account.'
      using errcode = 'no_data_found',
            hint = 'Create one under Administration → Settings before taking cash.';
  end if;

  select id into v_day
    from public.cash_day_closings
   where branch_id = p_branch_id and business_date = p_date;

  if v_day is not null then
    return v_day;
  end if;

  -- Carry forward from the most recent closed day, so the opening balance is
  -- never typed in and never disagrees with yesterday.
  select coalesce(physical_cash, expected_closing) into v_opening
    from public.cash_day_closings
   where branch_id = p_branch_id and business_date < p_date and status = 'CLOSED'
   order by business_date desc
   limit 1;

  if v_opening is null then
    v_opening := v_account.opening_balance;
  end if;

  insert into public.cash_day_closings
    (dealer_id, branch_id, cash_account_id, business_date, opening_balance, status)
  values (v_dealer, p_branch_id, v_account.id, p_date, v_opening, 'OPEN')
  returning id into v_day;

  return v_day;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_cash_transaction() — a receipt or a payment (spec §37)
-- -----------------------------------------------------------------------------
create or replace function public.record_cash_transaction(
  p_branch_id   uuid,
  p_direction   text,
  p_amount      numeric,
  p_particular  text,
  p_account_id  uuid,
  p_customer_id uuid default null,
  p_reference   text default null,
  p_date        date default current_date
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
begin
  if p_amount <= 0 then
    raise exception 'The amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_direction not in ('RECEIPT', 'PAYMENT') then
    raise exception 'Direction must be RECEIPT or PAYMENT.' using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  select * into v_account from public.cash_accounts where branch_id = p_branch_id;

  if v_account.id is null then
    raise exception 'This branch has no cash account.' using errcode = 'no_data_found';
  end if;

  -- Opens the day if needed, and fails if it is already closed (spec §36).
  perform public.ensure_cash_day(p_branch_id, p_date);

  v_cash_acc := v_account.ledger_account_id;

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
                           'party_type', case when p_customer_id is not null then 'CUSTOMER' end,
                           'party_id', p_customer_id)
      )
    else
      jsonb_build_array(
        jsonb_build_object('account_id', p_account_id, 'debit', p_amount, 'credit', 0,
                           'narration', p_particular,
                           'party_type', case when p_customer_id is not null then 'CUSTOMER' end,
                           'party_id', p_customer_id),
        jsonb_build_object('account_id', v_cash_acc, 'debit', 0, 'credit', p_amount,
                           'narration', p_particular)
      )
    end,
    'CASH_BOOK', null, null
  );

  insert into public.cash_transactions
    (dealer_id, branch_id, cash_account_id, business_date, direction, amount,
     particular, reference_number, customer_id, journal_entry_id, created_by)
  values
    (v_dealer, p_branch_id, v_account.id, p_date, p_direction, p_amount,
     p_particular, p_reference, p_customer_id, v_entry, auth.uid())
  returning id, cash_transactions.balance_after into v_txn, v_balance;

  transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.close_cash_day() — count, compare, close (spec §36)
-- -----------------------------------------------------------------------------
-- The difference between counted and expected is computed, never typed. A
-- cashier who could type the difference could type zero.
-- -----------------------------------------------------------------------------
create or replace function public.close_cash_day(
  p_branch_id     uuid,
  p_date          date,
  p_physical_cash numeric,
  p_denominations jsonb default null,
  p_remarks       text default null
)
returns table (expected numeric, counted numeric, difference numeric)
language plpgsql
as $$
declare
  v_day public.cash_day_closings;
begin
  if p_physical_cash is null or p_physical_cash < 0 then
    raise exception 'Enter the physical cash counted.' using errcode = 'check_violation';
  end if;

  select * into v_day
    from public.cash_day_closings
   where branch_id = p_branch_id and business_date = p_date
     for update;

  if v_day.id is null then
    raise exception 'No cash book exists for % at this branch.', p_date
      using errcode = 'no_data_found';
  end if;
  if v_day.status = 'CLOSED' then
    raise exception 'The cash book for % is already closed.', p_date
      using errcode = 'check_violation';
  end if;

  update public.cash_day_closings
     set physical_cash = p_physical_cash,
         denominations = p_denominations,
         remarks       = p_remarks,
         counted_at    = now(),
         counted_by    = auth.uid(),
         closed_at     = now(),
         closed_by     = auth.uid(),
         status        = 'CLOSED'
   where id = v_day.id;

  select cdc.expected_closing, cdc.physical_cash, cdc.difference
    into expected, counted, difference
    from public.cash_day_closings cdc where cdc.id = v_day.id;

  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.reopen_cash_day() — spec §36, with permission and a reason
-- -----------------------------------------------------------------------------
create or replace function public.reopen_cash_day(
  p_branch_id uuid,
  p_date      date,
  p_reason    text
)
returns void
language plpgsql
as $$
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'Reopening a closed day requires a reason.'
      using errcode = 'check_violation',
            hint = 'Spec §36: no silent edits after close.';
  end if;

  update public.cash_day_closings
     set status = 'COUNTED', reopened_at = now(), reopened_by = auth.uid(), reopen_reason = p_reason
   where branch_id = p_branch_id and business_date = p_date and status = 'CLOSED';

  if not found then
    raise exception 'No closed cash book found for % at this branch.', p_date
      using errcode = 'no_data_found';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.cash_book() — the day sheet (spec §37)
-- -----------------------------------------------------------------------------
create or replace function public.cash_book(
  p_branch_id uuid,
  p_date      date default current_date
)
returns table (
  transaction_time timestamptz,
  reference_number text,
  particular       text,
  receipt          numeric(18, 4),
  payment          numeric(18, 4),
  running_balance  numeric(18, 4),
  journal_entry_id uuid
)
language sql
stable
as $$
  select t.transaction_time, t.reference_number, t.particular,
         case when t.direction = 'RECEIPT' then t.amount else 0 end,
         case when t.direction = 'PAYMENT' then t.amount else 0 end,
         t.balance_after, t.journal_entry_id
    from public.cash_transactions t
   where t.branch_id = p_branch_id
     and t.business_date = p_date
     and t.status = 'ACTIVE'
   order by t.transaction_time, t.id;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.ensure_cash_day(uuid, date) to authenticated';
    execute 'grant execute on function public.record_cash_transaction(uuid, text, numeric, text, uuid, uuid, text, date) to authenticated';
    execute 'grant execute on function public.close_cash_day(uuid, date, numeric, jsonb, text) to authenticated';
    execute 'grant execute on function public.reopen_cash_day(uuid, date, text) to authenticated';
    execute 'grant execute on function public.cash_book(uuid, date) to authenticated';
  end if;
end;
$$;
