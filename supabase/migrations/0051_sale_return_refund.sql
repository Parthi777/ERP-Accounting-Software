-- =============================================================================
-- 0051 — A sales return can refund the money it takes back
-- =============================================================================
-- Spec §19, §21, §23, §34, §36, §37, §38, §48, §59.
--
-- public.return_vehicle_sale() from 0036 refuses outright when anything has been
-- received against the invoice:
--
--     Invoice INV-… has 50000.0000 received against it. Refund it before
--     returning the sale.
--
-- Sound advice, except that there has never been anywhere in the product to do
-- it. A cash refund against a sale is not a cash-book payment (that would credit
-- cash and debit nothing meaningful), it is not a booking refund (0046 handles
-- only bookings), and the sale screens offer no such action. So every sale a
-- customer had paid for was unreturnable — which is most of them, and exactly
-- the ones a dealer actually needs to return.
--
-- The stock half already worked and is unchanged below: the vehicle goes back to
-- IN_STOCK through app.vehicles_log_movement(), and fitted accessories return to
-- the lot — LOCAL or COMPANY — that they were consumed from (spec §28, §31, §34).
--
-- ── The accounting ──────────────────────────────────────────────────────────
--
-- Three postings, one transaction (spec §48). Taking a ₹65,000 invoice with
-- ₹50,000 received:
--
--   1. the sale journal is reversed          Dr Revenue/Tax  Cr Receivable  65,000
--      leaving the customer ₹50,000 in credit — the dealer is holding money for
--      a sale that no longer exists;
--   2. the refund pays it back               Dr Receivable   Cr Cash/Bank   50,000
--      clearing the customer to nil and taking the notes out of the drawer;
--   3. the receipts are marked REVERSED, so sales.paid_amount falls to zero
--      through the trigger in 0020 rather than being written directly.
--
-- Refunding less than was received is allowed and does something specific: the
-- difference stays as a credit on the customer's ledger, visible as an
-- unallocated receipt in the bill-wise settlement view (0050). It is NOT quietly
-- turned into income — a retained cancellation charge is a decision someone has
-- to make and post, not a rounding of a refund.
--
-- The refund reaches the cash book or the bank book by writing the subsidiary
-- row alongside the journal, which is the rule 0049 established: money that
-- moves and is absent from the book that itemises it makes the day-close
-- meaningless (spec §36, §37, §38).
--
-- DROPped and recreated rather than replaced: the function gains parameters and
-- returns a row instead of a uuid, and `create or replace` can do neither.
-- Leaving both signatures in place would make supabase.rpc() ambiguous at
-- runtime and emit a duplicate key from scripts/generate-types.mjs.
--
-- Rollback: restore public.return_vehicle_sale(uuid, text) from 0036 and its grant.
-- =============================================================================

drop function if exists public.return_vehicle_sale(uuid, text);

create function public.return_vehicle_sale(
  p_sale_id         uuid,
  p_reason          text,
  -- 'CASH', 'BANK', or null when nothing was received and nothing is going back.
  p_refund_mode     text    default null,
  -- Defaults to everything received. Less is allowed; more is not.
  p_refund_amount   numeric default null,
  p_bank_account_id uuid    default null,
  -- The cheque number, UTR or voucher the money went out on.
  p_reference       text    default null,
  p_date            date    default current_date
)
returns table (
  reversal_entry_id uuid,
  refund_entry_id   uuid,
  refunded          numeric(18, 4),
  credit_left       numeric(18, 4)
)
language plpgsql
as $$
declare
  v_sale     public.sales;
  v_entry    uuid;
  v_refund   uuid;
  v_alloc    record;
  v_received numeric(18, 4);
  v_amount   numeric(18, 4);
  v_debit    uuid;
  v_credit   uuid;
  v_cash     public.cash_accounts;
  v_bank     public.bank_accounts;
  v_branch   uuid;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A sales return requires a reason.'
      using errcode = 'check_violation',
            hint = 'Spec §21: the reason is part of the record, not optional.';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;

  if v_sale.id is null then
    raise exception 'Sale not found.' using errcode = 'no_data_found';
  end if;
  if v_sale.status <> 'POSTED' then
    raise exception 'Invoice % is % — only a posted, undelivered sale can be returned.',
      v_sale.invoice_number, v_sale.status using errcode = 'check_violation';
  end if;

  -- What the customer actually paid. sales.paid_amount excludes FINANCE by
  -- construction (the trigger in 0020 splits the two), so money disbursed by a
  -- finance company is not refunded in cash here — that is a settlement with the
  -- financier, not a refund to the customer.
  v_received := coalesce(v_sale.paid_amount, 0);
  v_amount   := round(coalesce(p_refund_amount, v_received), 4);

  if v_received > 0 and coalesce(p_refund_mode, '') = '' then
    raise exception
      'Invoice % has % received against it. Say how it is being refunded — cash or bank.',
      v_sale.invoice_number, v_received
      using errcode = 'check_violation';
  end if;
  if v_amount > v_received then
    raise exception 'Only % was received against %; % cannot be refunded.',
      v_received, v_sale.invoice_number, v_amount
      using errcode = 'check_violation';
  end if;
  if v_amount < 0 then
    raise exception 'A refund cannot be negative.' using errcode = 'check_violation';
  end if;
  if p_refund_mode is not null and p_refund_mode not in ('CASH', 'BANK') then
    raise exception 'A refund is paid in cash or from a bank account; got %.', p_refund_mode
      using errcode = 'check_violation';
  end if;

  -- ── 1. Reverse the invoice ─────────────────────────────────────────────────
  -- The original is never edited or deleted; a second entry undoes it and
  -- carries the reason (spec §23, §60.12, §60.13).
  v_entry := app.reverse_journal(v_sale.journal_entry_id, btrim(p_reason), p_date);

  -- ── 2. Pay the money back ──────────────────────────────────────────────────
  if v_amount > 0 then
    -- The same receivable the invoice and its receipts used, so the customer's
    -- subsidiary ledger closes to nil rather than to two offsetting balances in
    -- different accounts.
    v_debit := app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'RECEIVABLE', v_sale.branch_id);

    if p_refund_mode = 'CASH' then
      select * into v_cash from public.cash_accounts where branch_id = v_sale.branch_id;
      if v_cash.id is null then
        raise exception 'This branch has no cash account, so a cash refund cannot be paid.'
          using errcode = 'no_data_found';
      end if;
      v_branch := v_sale.branch_id;
      v_credit := v_cash.ledger_account_id;
      -- A closed day cannot take a movement, in or out (spec §36).
      perform public.ensure_cash_day(v_branch, p_date);
    else
      select * into v_bank from public.bank_accounts where id = p_bank_account_id;
      if v_bank.id is null then
        raise exception 'Choose the bank account the refund is being paid from.'
          using errcode = 'no_data_found';
      end if;
      if v_bank.dealer_id <> v_sale.dealer_id then
        raise exception 'That bank account belongs to another dealer.'
          using errcode = 'insufficient_privilege';
      end if;
      v_branch := coalesce(v_bank.branch_id, v_sale.branch_id);
      v_credit := v_bank.ledger_account_id;
    end if;

    v_refund := app.post_journal(
      v_sale.dealer_id, v_branch, p_date, 'SALES',
      'Refund on return of ' || v_sale.invoice_number,
      jsonb_build_array(
        jsonb_build_object('account_id', v_debit, 'debit', v_amount, 'credit', 0,
                           'narration', btrim(p_reason),
                           'party_type', 'CUSTOMER', 'party_id', v_sale.customer_id),
        jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', v_amount,
                           'narration', 'Refund ' || v_sale.invoice_number)
      ),
      'SALE_RETURN', p_sale_id,
      -- One refund per return, however many times the button is pressed (spec §50).
      'sale-return-refund:' || p_sale_id::text
    );

    -- The book that itemises the movement, not just the ledger that totals it.
    if p_refund_mode = 'CASH' then
      insert into public.cash_transactions
        (dealer_id, branch_id, cash_account_id, business_date, direction, amount,
         particular, reference_number, customer_id, journal_entry_id, created_by)
      values
        (v_sale.dealer_id, v_branch, v_cash.id, p_date, 'PAYMENT', v_amount,
         'Sales return refund ' || v_sale.invoice_number, nullif(btrim(p_reference), ''),
         v_sale.customer_id, v_refund, auth.uid());
    else
      insert into public.bank_transactions
        (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
         reference_number, customer_id, journal_entry_id, created_by)
      values
        (v_sale.dealer_id, p_bank_account_id, p_date, 'PAYMENT', v_amount,
         'Sales return refund ' || v_sale.invoice_number, nullif(btrim(p_reference), ''),
         v_sale.customer_id, v_refund, auth.uid());
    end if;
  end if;

  -- ── 3. The receipts are no longer live ─────────────────────────────────────
  -- Marked, not deleted. sales.paid_amount falls out of the trigger in 0020
  -- rather than being written here, so the figure and its evidence cannot
  -- disagree. FINANCE rows are left alone: that money came from the financier.
  update public.sale_payments
     set status = 'REVERSED'
   where sale_id = p_sale_id and status = 'RECEIVED' and payment_mode <> 'FINANCE';

  -- ── 4. The stock comes back ────────────────────────────────────────────────
  -- Each accessory returns to the lot it was consumed from, so the LOCAL and
  -- COMPANY split stays true (spec §28, §31, §60.16).
  for v_alloc in
    select t.item_id, t.source, -t.quantity as qty, t.unit_cost
      from public.inventory_transactions t
     where t.reference_type = 'SALE' and t.reference_id = p_sale_id and t.quantity < 0
  loop
    insert into public.inventory_transactions
      (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
       reference_type, reference_id, narration, reason, created_by)
    values
      (v_sale.dealer_id, v_sale.branch_id, v_alloc.item_id, v_alloc.source, 'RETURN',
       v_alloc.qty, v_alloc.unit_cost, 'SALE_RETURN', p_sale_id,
       'Returned from ' || v_sale.invoice_number, btrim(p_reason), auth.uid());
  end loop;

  update public.sales
     set status = 'RETURNED', updated_by = auth.uid(), notes =
           coalesce(notes || E'\n', '') || 'Returned: ' || btrim(p_reason)
   where id = p_sale_id;

  -- The RETURN ledger row is written by app.vehicles_log_movement(), which reads
  -- this setting to record what the movement was for.
  perform set_config('app.vehicle_movement_ref', 'SALE_RETURN:' || p_sale_id, true);

  update public.vehicles
     set status = 'IN_STOCK', updated_by = auth.uid()
   where id = v_sale.vehicle_id;

  perform set_config('app.vehicle_movement_ref', '', true);

  reversal_entry_id := v_entry;
  refund_entry_id   := v_refund;
  refunded          := v_amount;
  -- What the dealer still holds for this customer: received, less refunded. Not
  -- income until someone posts it as income.
  credit_left       := round(v_received - v_amount, 4);
  return next;
end;
$$;

comment on function public.return_vehicle_sale(uuid, text, text, numeric, uuid, text, date) is
  'Returns a posted sale (spec §21): reverses the invoice, refunds what was '
  'received through the cash or bank book, reverses the receipts and puts the '
  'vehicle and its fitted accessories back into stock. One transaction (spec §48).';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.return_vehicle_sale(uuid, text, text, numeric, uuid, text, date) to authenticated';
  end if;
end;
$$;
