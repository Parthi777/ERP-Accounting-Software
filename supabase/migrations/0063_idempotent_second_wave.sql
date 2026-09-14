-- =============================================================================
-- 0063 — Idempotency for the remaining money endpoints (spec §50)
-- =============================================================================
-- Spec §50, §18, §26, §32, §33.
--
-- 0061 and 0062 covered the endpoints a cashier touches most: sale payments,
-- cash, bank, and the sale draft. These five are the rest of the money surface —
-- service receipts, counter invoices, booking advances, advance refunds and
-- finance-company trade advances. Every one of them writes a document and a
-- journal, and every one of them could be submitted twice.
--
-- Three different shapes turned up, which is worth recording because the third
-- is the one that looks safe:
--
--   1. No protection at all — record_service_payment and record_trade_advance
--      passed a null idempotency key to app.post_journal.
--
--   2. A key that could never match — create_booking_with_advance passed
--      'booking:' || v_booking, minted from the row it had just inserted. The
--      same defect 0061 found in record_sale_payment: the parameter was filled
--      in and inert.
--
--   3. A deterministic key that made things *worse* — refund_booking_advance
--      passes 'booking-refund:<booking>:<amount>', which is stable across calls,
--      so app.post_journal correctly replays the first journal on a second call.
--      The function then carried on and inserted a second cash or bank row
--      against that replayed journal. The refund appeared twice in the cash book
--      and once in the ledger: over-reported on the day sheet, and invisible to
--      the trial balance that would otherwise have caught it. Half a guard was
--      worse than none, because it moved the damage somewhere nobody reconciles.
--
-- The fix in all three cases is the same and is the rule 0061 established: guard
-- at the top of the function, on its own document table, before any sequence is
-- consumed and before any row is written.
--
-- Rollback: restore these five from 0043, 0046, 0047 and 0049, then drop the
-- three columns added below.
-- =============================================================================

-- service_invoices has carried idempotency_key since 0023 and bookings did not;
-- the partial unique indexes exempt nulls, so nothing that predates this or
-- declines to opt in is affected.
alter table public.service_payments     add column if not exists idempotency_key text;
alter table public.bookings             add column if not exists idempotency_key text;
alter table public.finance_transactions add column if not exists idempotency_key text;

create unique index if not exists service_payment_idempotency_key
  on public.service_payments (dealer_id, idempotency_key) where idempotency_key is not null;
create unique index if not exists booking_idempotency_key
  on public.bookings (dealer_id, idempotency_key) where idempotency_key is not null;
create unique index if not exists finance_txn_idempotency_key
  on public.finance_transactions (dealer_id, idempotency_key) where idempotency_key is not null;

-- -----------------------------------------------------------------------------
-- public.record_service_payment() — spec §32, §33
-- -----------------------------------------------------------------------------
drop function if exists public.record_service_payment(uuid, numeric, text, text, date);

create function public.record_service_payment(
  p_invoice_id   uuid,
  p_amount       numeric,
  p_payment_mode text default 'CASH',
  p_reference    text default null,
  p_date         date default current_date,
  p_idempotency_key text default null
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
  -- The guard (spec §50): after the invoice lock, before the status and
  -- outstanding checks, and well before next_document_number. A retry arriving
  -- once the invoice is fully paid must replay its receipt, not be told the
  -- amount exceeds what is outstanding.
  if p_idempotency_key is not null then
    select p.id, p.receipt_number into v_id, v_number
      from public.service_payments p
     where p.dealer_id = v_invoice.dealer_id
       and p.idempotency_key = p_idempotency_key;

    if v_id is not null then
      select si.total_amount - si.paid_amount into v_balance
        from public.service_invoices si where si.id = p_invoice_id;
      payment_id := v_id; receipt_number := v_number; balance_due := v_balance;
      return next;
      return;
    end if;
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
     reference, journal_entry_id, idempotency_key, created_by)
  values
    (v_invoice.dealer_id, p_invoice_id, v_number, p_date, p_amount, p_payment_mode,
     p_reference, v_entry, p_idempotency_key, auth.uid())
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
-- public.create_counter_invoice() — spec §33
-- -----------------------------------------------------------------------------
drop function if exists public.create_counter_invoice(uuid, uuid, date);

create function public.create_counter_invoice(
  p_branch_id    uuid,
  p_customer_id  uuid default null,
  p_invoice_date date default current_date,
  p_idempotency_key text default null
)
returns table (invoice_id uuid, invoice_number text)
language plpgsql
as $$
declare
  v_dealer   uuid;
  v_number   text;
  v_id       uuid;
  v_required boolean;
begin
  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  -- The guard (spec §50). service_invoices has carried idempotency_key since
  -- 0023 for the workshop side; the counter never used it.
  if p_idempotency_key is not null then
    select si.id, si.invoice_number into v_id, v_number
      from public.service_invoices si
     where si.dealer_id = v_dealer
       and si.idempotency_key = p_idempotency_key;

    if v_id is not null then
      invoice_id := v_id; invoice_number := v_number;
      return next;
      return;
    end if;
  end if;

  select coalesce((value)::text = 'true', false) into v_required
    from public.system_settings
   where key = 'counter_sale.require_customer'
     and (dealer_id = v_dealer or dealer_id is null)
   order by dealer_id nulls last
   limit 1;

  if coalesce(v_required, false) and p_customer_id is null then
    raise exception 'This dealer requires a customer on every counter sale.'
      using errcode = 'check_violation',
            hint = 'Spec §33: the customer is optional or required by configuration.';
  end if;

  v_number := app.next_document_number(
    v_dealer, p_branch_id, 'COUNTER_INVOICE',
    app.financial_year_token(v_dealer, p_invoice_date));

  insert into public.service_invoices
    (dealer_id, branch_id, invoice_number, invoice_date, invoice_type,
     job_card_id, customer_id, idempotency_key, created_by)
  values
    (v_dealer, p_branch_id, v_number, p_invoice_date, 'COUNTER',
     null, p_customer_id, p_idempotency_key, auth.uid())
  returning id into v_id;

  invoice_id := v_id; invoice_number := v_number;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.create_booking_with_advance() — spec §18
-- -----------------------------------------------------------------------------
drop function if exists public.create_booking_with_advance(uuid, uuid, uuid, numeric, numeric, text, uuid, uuid, date, uuid, text, text);

create function public.create_booking_with_advance(
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
  p_notes             text default null,
  p_idempotency_key   text default null
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

  -- The guard (spec §50): before two document numbers are drawn. The journal
  -- key this function already passed was 'booking:' || v_booking, minted from
  -- the row it had just created — unique every call, so it could never match.
  if p_idempotency_key is not null then
    select b.id, b.booking_number into v_booking, v_bnumber
      from public.bookings b
     where b.dealer_id = v_dealer_id
       and b.idempotency_key = p_idempotency_key;

    if v_booking is not null then
      select bp.receipt_number, bp.journal_entry_id into v_rnumber, v_entry
        from public.booking_payments bp
       where bp.booking_id = v_booking and bp.status = 'RECEIVED'
       order by bp.created_at limit 1;

      booking_id := v_booking; booking_number := v_bnumber;
      receipt_number := v_rnumber; journal_entry_id := v_entry;
      return next;
      return;
    end if;
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
     booking_amount, expected_delivery, sales_executive_id, notes, idempotency_key, created_by)
  values
    (v_dealer_id, p_branch_id, v_bnumber, p_customer_id, p_model_id, p_variant_id, p_vehicle_id,
     p_booking_amount, p_expected_delivery, p_sales_executive_id, p_notes,
     p_idempotency_key, auth.uid())
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
-- public.refund_booking_advance() — spec §18, §23
-- -----------------------------------------------------------------------------
drop function if exists public.refund_booking_advance(uuid, numeric, text, text, uuid, uuid, date);

create function public.refund_booking_advance(
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

  -- The guard (spec §50).
  --
  -- This one already had half a defence and it made things worse. The journal
  -- key below is deterministic — 'booking-refund:<booking>:<amount>' — so
  -- app.post_journal replays the first entry on a second call. The function then
  -- carried on and inserted a *second* cash or bank row against that same
  -- journal, so the refund appeared twice in the cash book and once in the
  -- ledger: over-reported in the day sheet, and invisible to the trial balance
  -- that would otherwise have caught it.
  --
  -- Returning here is what makes the replay complete rather than partial.
  --
  -- And it sits above the status and received-amount checks deliberately. The
  -- first call reverses the booking_payments rows, so a replay that reached
  -- those checks would be told "only 0.0000 was received" — refusing to repeat
  -- itself with an error that describes the state it created. A guard placed
  -- after the checks it is meant to skip is not a guard.
  select je.id into v_entry
    from public.journal_entries je
   where je.dealer_id = v_b.dealer_id
     and je.idempotency_key =
         'booking-refund:' || p_booking_id::text || ':' || p_amount::text;

  if v_entry is not null then
    journal_entry_id := v_entry;
    return next;
    return;
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
-- -----------------------------------------------------------------------------
-- public.record_trade_advance() — spec §26
-- -----------------------------------------------------------------------------
drop function if exists public.record_trade_advance(uuid, uuid, text, numeric, uuid, date, text, text);

create function public.record_trade_advance(
  p_finance_company_id uuid,
  p_branch_id          uuid,
  p_type               text,
  p_amount             numeric,
  p_bank_account_id    uuid default null,
  p_date               date default current_date,
  p_narration          text default null,
  p_reference          text default null,
  p_idempotency_key    text default null
)
returns table (transaction_id bigint, journal_entry_id uuid)
language plpgsql
as $$
declare
  v_dealer  uuid;
  v_company public.finance_companies;
  v_bank    public.bank_accounts;
  v_bank_acc uuid;
  v_debit   uuid;
  v_credit  uuid;
  v_entry   uuid;
  v_txn     bigint;
  v_debit_amt  numeric(18, 4) := 0;
  v_credit_amt numeric(18, 4) := 0;
  v_narration text;
begin
  -- ft_one_sided_check forbids a zero row, so this is not merely tidiness.
  if p_amount <= 0 then
    raise exception 'The amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_type not in ('ADVANCE_RECEIVED', 'VEHICLE_ADJUSTMENT', 'SETTLEMENT',
                    'REFUND', 'COMMISSION', 'MANUAL_ADJUSTMENT') then
    raise exception 'Unknown trade advance type %.', p_type using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  -- The guard (spec §50). A finance company's ledger is reconciled against the
  -- financier's own statement; a duplicated advance is an argument with someone
  -- who has the money.
  if p_idempotency_key is not null then
    select ft.id, ft.journal_entry_id into v_txn, v_entry
      from public.finance_transactions ft
     where ft.dealer_id = v_dealer
       and ft.idempotency_key = p_idempotency_key;

    if v_txn is not null then
      transaction_id := v_txn; journal_entry_id := v_entry;
      return next;
      return;
    end if;
  end if;

  select * into v_company from public.finance_companies where id = p_finance_company_id;
  if v_company.id is null then
    raise exception 'Finance company not found.' using errcode = 'no_data_found';
  end if;

  if p_bank_account_id is not null then
    select * into v_bank from public.bank_accounts where id = p_bank_account_id;
  end if;

  v_narration := coalesce(p_narration, replace(initcap(replace(p_type, '_', ' ')), ' ', ' ')
                          || ' — ' || v_company.name);

  -- Money in or out needs a bank account; the internal moves do not.
  if p_type in ('ADVANCE_RECEIVED', 'SETTLEMENT', 'REFUND') and v_bank.id is null then
    raise exception 'A % needs the bank account the money moved through.', lower(replace(p_type, '_', ' '))
      using errcode = 'check_violation';
  end if;

  v_bank_acc := v_bank.ledger_account_id;

  if p_type = 'ADVANCE_RECEIVED' then
    -- The company funds the dealer ahead of sales: cash in, liability up.
    v_debit  := coalesce(v_bank_acc, app.require_account(v_dealer, 'TRADE_ADVANCE', 'RECEIVED', 'BANK', p_branch_id));
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'RECEIVED', 'FINANCE_PAYABLE', p_branch_id);
    v_debit_amt := p_amount;          -- the dealer holds their money, so the position falls
  elsif p_type = 'VEHICLE_ADJUSTMENT' then
    -- An advance is consumed by a vehicle the company financed.
    v_debit  := app.require_account(v_dealer, 'TRADE_ADVANCE', 'ADJUSTMENT', 'FINANCE_PAYABLE', p_branch_id);
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'ADJUSTMENT', 'FINANCE_RECEIVABLE', p_branch_id);
    v_credit_amt := p_amount;
  elsif p_type = 'SETTLEMENT' then
    v_debit  := coalesce(v_bank_acc, app.require_account(v_dealer, 'TRADE_ADVANCE', 'SETTLEMENT', 'BANK', p_branch_id));
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'SETTLEMENT', 'FINANCE_RECEIVABLE', p_branch_id);
    v_debit_amt := p_amount;
  elsif p_type = 'REFUND' then
    v_debit  := app.require_account(v_dealer, 'TRADE_ADVANCE', 'REFUND', 'FINANCE_PAYABLE', p_branch_id);
    v_credit := coalesce(v_bank_acc, app.require_account(v_dealer, 'TRADE_ADVANCE', 'REFUND', 'BANK', p_branch_id));
    v_credit_amt := p_amount;
  elsif p_type = 'COMMISSION' then
    v_debit  := app.require_account(v_dealer, 'TRADE_ADVANCE', 'COMMISSION', 'FINANCE_RECEIVABLE', p_branch_id);
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'COMMISSION', 'COMMISSION_INCOME', p_branch_id);
    v_credit_amt := p_amount;         -- earned but unpaid: the company owes more
  else -- MANUAL_ADJUSTMENT
    v_debit  := app.require_account(v_dealer, 'TRADE_ADVANCE', 'MANUAL_ADJUSTMENT', 'FINANCE_RECEIVABLE', p_branch_id);
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'MANUAL_ADJUSTMENT', 'FINANCE_PAYABLE', p_branch_id);
    v_credit_amt := p_amount;
  end if;

  v_entry := app.post_journal(
    v_dealer, p_branch_id, p_date, 'TRADE_ADVANCE', v_narration,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', v_narration,
                         'party_type', 'FINANCE_COMPANY', 'party_id', p_finance_company_id),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', v_narration,
                         'party_type', 'FINANCE_COMPANY', 'party_id', p_finance_company_id)
    ),
    'TRADE_ADVANCE', null, null
  );

  insert into public.finance_transactions
    (dealer_id, branch_id, finance_company_id, transaction_date, transaction_type,
     debit, credit, reference_type, reference_number, narration, journal_entry_id,
     idempotency_key, created_by)
  values
    (v_dealer, p_branch_id, p_finance_company_id, p_date, p_type,
     v_debit_amt, v_credit_amt, 'TRADE_ADVANCE', p_reference, v_narration, v_entry,
     p_idempotency_key, auth.uid())
  returning id into v_txn;

  -- Money that moved through a bank account belongs in the bank book too.
  if v_bank.id is not null and p_type in ('ADVANCE_RECEIVED', 'SETTLEMENT', 'REFUND') then
    insert into public.bank_transactions
      (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
       reference_number, journal_entry_id, created_by)
    values
      (v_dealer, p_bank_account_id, p_date,
       case when p_type = 'REFUND' then 'PAYMENT' else 'RECEIPT' end,
       p_amount, v_narration, p_reference, v_entry, auth.uid());
  end if;

  transaction_id := v_txn; journal_entry_id := v_entry;
  return next;
end;
$$;
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  -- Per-signature, and every one of them went with its drop.
  execute 'grant execute on function public.record_service_payment(uuid, numeric, text, text, date, text) to authenticated';
  execute 'grant execute on function public.create_counter_invoice(uuid, uuid, date, text) to authenticated';
  execute 'grant execute on function public.create_booking_with_advance(uuid, uuid, uuid, numeric, numeric, text, uuid, uuid, date, uuid, text, text, text) to authenticated';
  execute 'grant execute on function public.refund_booking_advance(uuid, numeric, text, text, uuid, uuid, date) to authenticated';
  execute 'grant execute on function public.record_trade_advance(uuid, uuid, text, numeric, uuid, date, text, text, text) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0063', 'idempotent_second_wave') on conflict (version) do nothing;
