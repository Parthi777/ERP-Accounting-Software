-- =============================================================================
-- 0046 — Booking advances: applied on sale, refundable on cancellation
-- =============================================================================
-- Spec §18, §23, §41.
--
-- 0027 seeded BOOKING/APPLY/CUSTOMER_ADVANCE and BOOKING/APPLY/RECEIVABLE, and
-- nothing has ever invoked them. Converting a booking marks it CONVERTED and
-- stops there, so account 2100 (Customer Advances) accumulates every advance the
-- dealer has ever taken and releases none of them. The liability grows forever
-- and the customer's receivable is overstated by the advance they already paid.
--
-- Two functions close that:
--   * app.apply_booking_advance() releases the advance when the sale posts;
--   * public.refund_booking_advance() returns it when a booking is cancelled.
--
-- REFUND IS NOT AUTOMATIC ON CANCELLATION, deliberately. A cancelled booking's
-- advance is often retained as a forfeit, and auto-refunding would post money
-- the dealer never paid. It is a separate act, separately permitted.
--
-- Existing data keeps its stale 2100 balance: this releases advances from here
-- on, and back-posting entries for historical bookings would put journals into
-- closed periods. /bookings/advances shows the control balance alongside the
-- derived figure so the difference is visible rather than papered over.
--
-- Rollback: drop trigger sales_apply_advance on public.sales, then drop
--           app.sales_apply_advance(), app.apply_booking_advance(uuid) and
--           public.refund_booking_advance(uuid, numeric, text, text, uuid, uuid, date).
--           post_vehicle_sale() is untouched by this migration.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- app.apply_booking_advance() — spec §18
-- -----------------------------------------------------------------------------
-- Dr Customer Advances / Cr Customer Receivable: the money the customer already
-- paid stops being a liability and settles part of what they now owe. Both lines
-- carry the customer, so their ledger shows the advance being used.
--
-- Idempotent on the sale, so posting twice applies once.
-- -----------------------------------------------------------------------------
create or replace function app.apply_booking_advance(p_sale_id uuid)
returns uuid
language plpgsql
as $$
declare
  v_sale    public.sales;
  v_advance numeric(18, 4);
  v_apply   numeric(18, 4);
  v_debit   uuid;
  v_credit  uuid;
begin
  select * into v_sale from public.sales where id = p_sale_id;

  if v_sale.id is null or v_sale.booking_id is null then
    return null;  -- a walk-in sale has no advance to release
  end if;

  select coalesce(sum(amount), 0) into v_advance
    from public.booking_payments
   where booking_id = v_sale.booking_id and status = 'RECEIVED';

  if v_advance <= 0 then
    return null;
  end if;

  -- Never release more than the invoice is worth: the remainder stays a
  -- liability until it is refunded or applied elsewhere.
  v_apply := least(v_advance, v_sale.total_amount);

  v_debit  := app.require_account(v_sale.dealer_id, 'BOOKING', 'APPLY', 'CUSTOMER_ADVANCE', v_sale.branch_id);
  v_credit := app.require_account(v_sale.dealer_id, 'BOOKING', 'APPLY', 'RECEIVABLE', v_sale.branch_id);

  return app.post_journal(
    v_sale.dealer_id, v_sale.branch_id, v_sale.invoice_date, 'BOOKING',
    'Advance applied to ' || v_sale.invoice_number,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', v_apply, 'credit', 0,
                         'narration', 'Advance applied',
                         'party_type', 'CUSTOMER', 'party_id', v_sale.customer_id),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', v_apply,
                         'narration', 'Against ' || v_sale.invoice_number,
                         'party_type', 'CUSTOMER', 'party_id', v_sale.customer_id)
    ),
    'BOOKING_APPLY', p_sale_id, 'booking-apply:' || p_sale_id::text
  );
end;
$$;

comment on function app.apply_booking_advance(uuid) is
  'Releases a booking advance from Customer Advances against the invoice it was '
  'taken for (spec §18). Idempotent on the sale.';

-- -----------------------------------------------------------------------------
-- The advance is released when the sale posts
-- -----------------------------------------------------------------------------
-- A trigger rather than a change to post_vehicle_sale(). Rewriting that function
-- here would mean copying its hundred-line body into this migration, where the
-- copy would have to be kept in step with the original by hand forever. It also
-- means the release happens however a sale reaches POSTED, not only down the one
-- code path — the same reasoning as app.vehicles_log_movement() in 0017.
--
-- AFTER UPDATE, so the sale journal already exists and both entries land in the
-- same transaction.
-- -----------------------------------------------------------------------------
create or replace function app.sales_apply_advance()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'POSTED' and old.status is distinct from 'POSTED' then
    perform app.apply_booking_advance(new.id);
  end if;
  return null;
end;
$$;

create trigger sales_apply_advance
  after update on public.sales
  for each row execute function app.sales_apply_advance();

-- -----------------------------------------------------------------------------
-- public.refund_booking_advance() — spec §18, §23
-- -----------------------------------------------------------------------------
create or replace function public.refund_booking_advance(
  p_booking_id      uuid,
  p_amount          numeric,
  p_mode            text,
  p_reason          text,
  p_cash_branch_id  uuid default null,
  p_bank_account_id uuid default null,
  p_date            date default current_date
)
returns table (journal_entry_id uuid)
language plpgsql
as $$
declare
  v_b        public.bookings;
  v_received numeric(18, 4);
  v_debit    uuid;
  v_credit   uuid;
  v_entry    uuid;
  v_bank     public.bank_accounts;
  v_cash     public.cash_accounts;
  v_branch   uuid;
begin
  if p_amount <= 0 then
    raise exception 'The refund must be greater than zero.' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'A refund must say why.'
      using errcode = 'check_violation',
            hint = 'Spec §23: the reason is part of the record, not optional.';
  end if;

  select * into v_b from public.bookings where id = p_booking_id for update;
  if v_b.id is null then
    raise exception 'Booking not found.' using errcode = 'no_data_found';
  end if;

  -- Only a cancelled booking. A refund against a live booking would leave the
  -- customer with a reservation they have not paid for.
  if v_b.status <> 'CANCELLED' then
    raise exception 'Booking % is % — cancel it before refunding the advance.',
      v_b.booking_number, v_b.status using errcode = 'check_violation';
  end if;

  select coalesce(sum(amount), 0) into v_received
    from public.booking_payments
   where booking_id = p_booking_id and status = 'RECEIVED';

  if p_amount > v_received then
    raise exception 'Only % was received against %.', v_received, v_b.booking_number
      using errcode = 'check_violation';
  end if;

  v_debit := app.require_account(v_b.dealer_id, 'BOOKING', 'APPLY', 'CUSTOMER_ADVANCE', v_b.branch_id);

  if p_mode = 'CASH' then
    v_branch := coalesce(p_cash_branch_id, v_b.branch_id);
    select * into v_cash from public.cash_accounts where branch_id = v_branch;
    if v_cash.id is null then
      raise exception 'That branch has no cash account.' using errcode = 'no_data_found';
    end if;
    v_credit := v_cash.ledger_account_id;
    -- The day guard applies: a closed day cannot take a payment (spec §36).
    perform public.ensure_cash_day(v_branch, p_date);
  else
    select * into v_bank from public.bank_accounts where id = p_bank_account_id;
    if v_bank.id is null then
      raise exception 'Choose the bank account the refund was paid from.'
        using errcode = 'no_data_found';
    end if;
    v_branch := coalesce(v_bank.branch_id, v_b.branch_id);
    v_credit := v_bank.ledger_account_id;
  end if;

  v_entry := app.post_journal(
    v_b.dealer_id, v_branch, p_date, 'BOOKING',
    'Advance refunded on ' || v_b.booking_number,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', btrim(p_reason),
                         'party_type', 'CUSTOMER', 'party_id', v_b.customer_id),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', 'Refund of booking advance')
    ),
    'BOOKING_REFUND', p_booking_id, 'booking-refund:' || p_booking_id::text || ':' || p_amount::text
  );

  if p_mode = 'CASH' then
    insert into public.cash_transactions
      (dealer_id, branch_id, cash_account_id, business_date, direction, amount,
       particular, customer_id, journal_entry_id, created_by)
    values
      (v_b.dealer_id, v_branch, v_cash.id, p_date, 'PAYMENT', p_amount,
       'Advance refund ' || v_b.booking_number, v_b.customer_id, v_entry, auth.uid());
  else
    insert into public.bank_transactions
      (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
       customer_id, journal_entry_id, created_by)
    values
      (v_b.dealer_id, p_bank_account_id, p_date, 'PAYMENT', p_amount,
       'Advance refund ' || v_b.booking_number, v_b.customer_id, v_entry, auth.uid());
  end if;

  -- Reversing the receipts is what makes bookings.received_amount fall: the
  -- trigger in 0020 recomputes it from the RECEIVED rows.
  update public.booking_payments
     set status = 'REVERSED'
   where booking_id = p_booking_id and status = 'RECEIVED';

  journal_entry_id := v_entry;
  return next;
end;
$$;

comment on function public.refund_booking_advance(uuid, numeric, text, text, uuid, uuid, date) is
  'Returns a cancelled booking''s advance, clearing the liability and writing the '
  'cash or bank payment (spec §18, §23). Never automatic: an advance is often forfeit.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.refund_booking_advance(uuid, numeric, text, text, uuid, uuid, date) to authenticated';
  end if;
end;
$$;
