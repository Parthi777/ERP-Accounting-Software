-- =============================================================================
-- INCREMENTAL 0030 → 0035
-- =============================================================================
-- GENERATED FILE. Regenerate with:
--   FROM=0030 bash scripts/build-incremental.sh
--
-- For a database that ALREADY has migrations up to 0029.
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
-- SOURCE: supabase/migrations/0030_cash_operations.sql
-- ═══════════════════════════════════════════════════════════════════════════

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


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0031_bank_operations.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0031 — Bank operations, statement import and reconciliation
-- =============================================================================
-- Spec §38, §39.
--
-- Reconciliation matches the bank's version of events against ours. The rule the
-- whole module turns on: a statement line is never marked reconciled without a
-- recorded link to the book entry it matched (enforced by bsl_matched_link_check
-- in 0022). Auto-matching proposes; nothing is silently accepted.
--
-- Rollback: drop the functions below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The reconciliation number needs a sequence (spec §45)
-- -----------------------------------------------------------------------------
-- Dealer-wide rather than branch-scoped, because a bank account need not belong
-- to a branch. Added for every accounting period already on file, so existing
-- dealers can reconcile without anyone editing a settings table first.
-- -----------------------------------------------------------------------------
insert into public.document_sequences (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
select distinct p.dealer_id, null::uuid, 'BANK_RECONCILIATION',
       app.financial_year_token(p.dealer_id, p.start_date), 'BRS', 6
  from public.accounting_periods p
on conflict on constraint document_sequences_scope_key do nothing;

-- -----------------------------------------------------------------------------
-- public.record_bank_transaction() — a bank receipt or payment (spec §38)
-- -----------------------------------------------------------------------------
create or replace function public.record_bank_transaction(
  p_bank_account_id uuid,
  p_direction       text,
  p_amount          numeric,
  p_particular      text,
  p_account_id      uuid,
  p_date            date default current_date,
  p_reference       text default null,
  p_utr             text default null,
  p_instrument      text default null
)
returns table (transaction_id bigint, journal_entry_id uuid, balance_after numeric)
language plpgsql
as $$
declare
  v_bank    public.bank_accounts;
  v_entry   uuid;
  v_txn     bigint;
  v_balance numeric(18, 4);
begin
  if p_amount <= 0 then
    raise exception 'The amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_direction not in ('RECEIPT', 'PAYMENT') then
    raise exception 'Direction must be RECEIPT or PAYMENT.' using errcode = 'check_violation';
  end if;

  select * into v_bank from public.bank_accounts where id = p_bank_account_id;
  if v_bank.id is null then
    raise exception 'Bank account not found.' using errcode = 'no_data_found';
  end if;
  if v_bank.status <> 'ACTIVE' then
    raise exception 'Bank account % is %.', v_bank.name, v_bank.status
      using errcode = 'check_violation';
  end if;

  v_entry := app.post_journal(
    v_bank.dealer_id, v_bank.branch_id, p_date,
    'BANK',
    p_particular,
    case when p_direction = 'RECEIPT' then
      jsonb_build_array(
        jsonb_build_object('account_id', v_bank.ledger_account_id, 'debit', p_amount, 'credit', 0,
                           'narration', p_particular),
        jsonb_build_object('account_id', p_account_id, 'debit', 0, 'credit', p_amount,
                           'narration', p_particular)
      )
    else
      jsonb_build_array(
        jsonb_build_object('account_id', p_account_id, 'debit', p_amount, 'credit', 0,
                           'narration', p_particular),
        jsonb_build_object('account_id', v_bank.ledger_account_id, 'debit', 0, 'credit', p_amount,
                           'narration', p_particular)
      )
    end,
    'BANK_BOOK', null, null
  );

  insert into public.bank_transactions
    (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
     reference_number, utr, instrument_number, journal_entry_id, created_by)
  values
    (v_bank.dealer_id, p_bank_account_id, p_date, p_direction, p_amount, p_particular,
     p_reference, nullif(btrim(p_utr), ''), nullif(btrim(p_instrument), ''), v_entry, auth.uid())
  returning id, bank_transactions.balance_after into v_txn, v_balance;

  transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.import_bank_statement() — stage rows for matching (spec §39)
-- -----------------------------------------------------------------------------
-- Takes the parsed rows as JSONB. Duplicate lines are skipped rather than
-- rejected, so re-importing an overlapping statement is safe: the unique index
-- bsl_dedupe_key is the authority on what counts as the same line.
-- -----------------------------------------------------------------------------
create or replace function public.import_bank_statement(
  p_bank_account_id uuid,
  p_rows            jsonb
)
returns table (import_batch uuid, imported integer, skipped integer)
language plpgsql
as $$
declare
  v_dealer   uuid;
  v_batch    uuid := gen_random_uuid();
  v_row      jsonb;
  v_imported integer := 0;
  v_skipped  integer := 0;
  v_debit    numeric(18, 4);
  v_credit   numeric(18, 4);
begin
  select dealer_id into v_dealer from public.bank_accounts where id = p_bank_account_id;
  if v_dealer is null then
    raise exception 'Bank account not found.' using errcode = 'no_data_found';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'No statement rows to import.' using errcode = 'check_violation';
  end if;

  for v_row in select * from jsonb_array_elements(p_rows)
  loop
    v_debit  := coalesce((v_row ->> 'debit')::numeric, 0);
    v_credit := coalesce((v_row ->> 'credit')::numeric, 0);

    -- A row that is neither a debit nor a credit carries no information, and one
    -- that is both is a parsing failure. Either way it is not silently kept.
    if (v_debit > 0) = (v_credit > 0) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    begin
      insert into public.bank_statement_lines
        (dealer_id, bank_account_id, import_batch, statement_date, value_date,
         narration, reference, utr, upi_id, cheque_number, debit, credit,
         running_balance, raw_row, created_by)
      values
        (v_dealer, p_bank_account_id, v_batch,
         (v_row ->> 'statement_date')::date,
         nullif(v_row ->> 'value_date', '')::date,
         coalesce(nullif(btrim(v_row ->> 'narration'), ''), '(no narration)'),
         nullif(btrim(v_row ->> 'reference'), ''),
         nullif(btrim(v_row ->> 'utr'), ''),
         nullif(btrim(v_row ->> 'upi_id'), ''),
         nullif(btrim(v_row ->> 'cheque_number'), ''),
         v_debit, v_credit,
         nullif(v_row ->> 'running_balance', '')::numeric,
         v_row, auth.uid());
      v_imported := v_imported + 1;
    exception
      when unique_violation then
        v_skipped := v_skipped + 1;
    end;
  end loop;

  import_batch := v_batch; imported := v_imported; skipped := v_skipped;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.suggest_bank_matches() — proposals, not decisions (spec §39)
-- -----------------------------------------------------------------------------
-- Confidence is ranked: an exact UTR match is near-certain; amount and date
-- together are likely; amount alone within a window is a hint. Nothing here
-- writes — a human accepts a match, which is what makes the audit trail mean
-- something.
-- -----------------------------------------------------------------------------
create or replace function public.suggest_bank_matches(
  p_bank_account_id uuid,
  p_date_window     integer default 5
)
returns table (
  statement_line_id bigint,
  statement_date    date,
  narration         text,
  debit             numeric(18, 4),
  credit            numeric(18, 4),
  transaction_id    bigint,
  transaction_date  date,
  particular        text,
  amount            numeric(18, 4),
  confidence        text,
  reason            text
)
language sql
stable
as $$
  with candidates as (
    select
      l.id as line_id, l.statement_date, l.narration, l.debit, l.credit, l.utr, l.cheque_number,
      t.id as txn_id, t.transaction_date, t.particular, t.amount,
      case
        when l.utr is not null and t.utr = l.utr                        then 'EXACT'
        when l.cheque_number is not null and t.instrument_number = l.cheque_number then 'EXACT'
        when t.transaction_date = l.statement_date                      then 'LIKELY'
        else 'POSSIBLE'
      end as confidence,
      case
        when l.utr is not null and t.utr = l.utr                        then 'UTR matches'
        when l.cheque_number is not null and t.instrument_number = l.cheque_number then 'Instrument number matches'
        when t.transaction_date = l.statement_date                      then 'Amount and date match'
        else 'Amount matches within ' || p_date_window || ' days'
      end as reason
    from public.bank_statement_lines l
    join public.bank_transactions t
      on  t.bank_account_id = l.bank_account_id
      and t.status = 'ACTIVE'
      and not t.reconciled
      -- Our receipt is the bank's credit; our payment is the bank's debit.
      and t.direction = case when l.credit > 0 then 'RECEIPT' else 'PAYMENT' end
      and t.amount = greatest(l.debit, l.credit)
      and t.transaction_date between l.statement_date - p_date_window
                                 and l.statement_date + p_date_window
    where l.bank_account_id = p_bank_account_id
      and l.match_status = 'UNMATCHED'
  ),
  ranked as (
    select *, row_number() over (
      partition by line_id
      order by case confidence when 'EXACT' then 1 when 'LIKELY' then 2 else 3 end,
               abs(transaction_date - statement_date), txn_id
    ) as rank_in_line
    from candidates
  )
  -- One proposal per line: the best one. A list of six equally plausible matches
  -- is not a suggestion, it is homework.
  select line_id, statement_date, narration, debit, credit,
         txn_id, transaction_date, particular, amount, confidence, reason
    from ranked
   where rank_in_line = 1
   order by statement_date, line_id;
$$;

-- -----------------------------------------------------------------------------
-- public.match_bank_line() — accept one match (spec §39)
-- -----------------------------------------------------------------------------
create or replace function public.match_bank_line(
  p_statement_line_id bigint,
  p_transaction_id    bigint
)
returns void
language plpgsql
as $$
declare
  v_line public.bank_statement_lines;
  v_txn  public.bank_transactions;
begin
  select * into v_line from public.bank_statement_lines where id = p_statement_line_id for update;
  select * into v_txn  from public.bank_transactions   where id = p_transaction_id    for update;

  if v_line.id is null then
    raise exception 'Statement line not found.' using errcode = 'no_data_found';
  end if;
  if v_txn.id is null then
    raise exception 'Bank entry not found.' using errcode = 'no_data_found';
  end if;
  if v_line.bank_account_id <> v_txn.bank_account_id then
    raise exception 'The statement line and the book entry belong to different bank accounts.'
      using errcode = 'check_violation';
  end if;
  if v_line.match_status = 'MATCHED' then
    raise exception 'That statement line is already matched.' using errcode = 'check_violation';
  end if;
  if v_txn.reconciled then
    raise exception 'That book entry is already reconciled.' using errcode = 'check_violation';
  end if;

  -- Matching two different amounts is how a reconciliation ends up balancing on
  -- paper and wrong in fact.
  if v_txn.amount <> greatest(v_line.debit, v_line.credit) then
    raise exception 'The amounts differ: statement % against book %.',
      greatest(v_line.debit, v_line.credit), v_txn.amount
      using errcode = 'check_violation';
  end if;

  update public.bank_statement_lines
     set match_status = 'MATCHED', matched_transaction_id = p_transaction_id
   where id = p_statement_line_id;

  update public.bank_transactions
     set reconciled = true
   where id = p_transaction_id;
end;
$$;

create or replace function public.unmatch_bank_line(p_statement_line_id bigint)
returns void
language plpgsql
as $$
declare v_txn bigint;
begin
  select matched_transaction_id into v_txn
    from public.bank_statement_lines where id = p_statement_line_id for update;

  update public.bank_statement_lines
     set match_status = 'UNMATCHED', matched_transaction_id = null
   where id = p_statement_line_id and reconciliation_id is null;

  if not found then
    raise exception 'That line is part of a completed reconciliation and cannot be unmatched.'
      using errcode = 'insufficient_privilege';
  end if;

  if v_txn is not null then
    update public.bank_transactions set reconciled = false where id = v_txn;
  end if;
end;
$$;

create or replace function public.ignore_bank_line(p_statement_line_id bigint)
returns void
language plpgsql
as $$
begin
  update public.bank_statement_lines
     set match_status = 'IGNORED'
   where id = p_statement_line_id and match_status = 'UNMATCHED';

  if not found then
    raise exception 'Only an unmatched line can be ignored.' using errcode = 'check_violation';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.complete_bank_reconciliation() — close the period (spec §39)
-- -----------------------------------------------------------------------------
create or replace function public.complete_bank_reconciliation(
  p_bank_account_id uuid,
  p_from_date       date,
  p_to_date         date,
  p_statement_closing numeric,
  p_notes           text default null
)
returns table (reconciliation_id uuid, number text, difference numeric,
               matched integer, unmatched integer)
language plpgsql
as $$
declare
  v_bank      public.bank_accounts;
  v_recon     uuid;
  v_number    text;
  v_book      numeric(18, 4);
  v_matched   integer;
  v_unmatched integer;
begin
  select * into v_bank from public.bank_accounts where id = p_bank_account_id;
  if v_bank.id is null then
    raise exception 'Bank account not found.' using errcode = 'no_data_found';
  end if;

  -- Every column is table-qualified below: this function has an OUT parameter
  -- called reconciliation_id, and an unqualified reference resolves to that
  -- rather than to the column.
  select count(*) filter (where l.match_status = 'MATCHED'),
         count(*) filter (where l.match_status = 'UNMATCHED')
    into v_matched, v_unmatched
    from public.bank_statement_lines l
   where l.bank_account_id = p_bank_account_id
     and l.statement_date between p_from_date and p_to_date
     and l.reconciliation_id is null;

  -- The book balance as at the closing date, from the entries themselves.
  select coalesce(v_bank.opening_balance + sum(
           case when direction = 'RECEIPT' then amount else -amount end), v_bank.opening_balance)
    into v_book
    from public.bank_transactions
   where bank_account_id = p_bank_account_id
     and status = 'ACTIVE'
     and transaction_date <= p_to_date;

  -- Dealer-wide, not branch-scoped: a bank account need not belong to a branch,
  -- so a branch-scoped sequence would have nothing to key on.
  v_number := app.next_document_number(
    v_bank.dealer_id, null, 'BANK_RECONCILIATION',
    app.financial_year_token(v_bank.dealer_id, p_to_date));

  insert into public.bank_reconciliations
    (dealer_id, bank_account_id, reconciliation_number, from_date, to_date,
     statement_closing_balance, book_closing_balance, matched_count, unmatched_count,
     status, completed_at, completed_by, notes, created_by)
  values
    (v_bank.dealer_id, p_bank_account_id, v_number, p_from_date, p_to_date,
     p_statement_closing, v_book, v_matched, v_unmatched,
     'COMPLETED', now(), auth.uid(), p_notes, auth.uid())
  returning id into v_recon;

  -- Stamp the lines and entries so a completed reconciliation cannot be
  -- retrospectively unpicked (unmatch_bank_line refuses once this is set).
  update public.bank_statement_lines l
     set reconciliation_id = v_recon
   where l.bank_account_id = p_bank_account_id
     and l.statement_date between p_from_date and p_to_date
     and l.reconciliation_id is null
     and l.match_status in ('MATCHED', 'IGNORED');

  update public.bank_transactions t
     set reconciliation_id = v_recon
   where t.bank_account_id = p_bank_account_id
     and t.reconciled and t.reconciliation_id is null
     and t.transaction_date <= p_to_date;

  reconciliation_id := v_recon;
  number            := v_number;
  matched           := v_matched;
  unmatched         := v_unmatched;
  select r.difference into difference from public.bank_reconciliations r where r.id = v_recon;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.bank_book() — the account's entries with running balance (spec §38)
-- -----------------------------------------------------------------------------
create or replace function public.bank_book(
  p_bank_account_id uuid,
  p_from_date       date default null,
  p_to_date         date default null
)
returns table (
  id               bigint,
  transaction_date date,
  particular       text,
  reference_number text,
  utr              text,
  receipt          numeric(18, 4),
  payment          numeric(18, 4),
  running_balance  numeric(18, 4),
  reconciled       boolean,
  journal_entry_id uuid
)
language sql
stable
as $$
  select t.id, t.transaction_date, t.particular, t.reference_number, t.utr,
         case when t.direction = 'RECEIPT' then t.amount else 0 end,
         case when t.direction = 'PAYMENT' then t.amount else 0 end,
         t.balance_after, t.reconciled, t.journal_entry_id
    from public.bank_transactions t
   where t.bank_account_id = p_bank_account_id
     and t.status = 'ACTIVE'
     and (p_from_date is null or t.transaction_date >= p_from_date)
     and (p_to_date   is null or t.transaction_date <= p_to_date)
   order by t.transaction_date, t.id;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.record_bank_transaction(uuid, text, numeric, text, uuid, date, text, text, text) to authenticated';
    execute 'grant execute on function public.import_bank_statement(uuid, jsonb) to authenticated';
    execute 'grant execute on function public.suggest_bank_matches(uuid, integer) to authenticated';
    execute 'grant execute on function public.match_bank_line(bigint, bigint) to authenticated';
    execute 'grant execute on function public.unmatch_bank_line(bigint) to authenticated';
    execute 'grant execute on function public.ignore_bank_line(bigint) to authenticated';
    execute 'grant execute on function public.complete_bank_reconciliation(uuid, date, date, numeric, text) to authenticated';
    execute 'grant execute on function public.bank_book(uuid, date, date) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0032_bank_entry_permission.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0032 — bank.book.record
-- =============================================================================
-- Writing a bank entry was, until now, reachable by anyone who could *view* the
-- bank book: there was no write permission for it in the catalogue. Spec §6 and
-- §47 want the check to name the thing being done, so this adds the code and
-- grants it exactly where the seed's own matrix would have put it — every role
-- that already holds the rest of the bank module.
--
-- Rollback: delete from public.role_permissions where permission_code = 'bank.book.record';
--           delete from public.permissions where code = 'bank.book.record';
-- =============================================================================

insert into public.permissions (code, module, description, is_sensitive)
values ('bank.book.record', 'bank', 'Record bank receipts and payments', false)
on conflict (code) do nothing;

-- ACCOUNTS holds the whole bank module; DEALER_OWNER holds everything bar
-- platform administration. Mirroring seed.sql rather than inventing a new rule.
insert into public.role_permissions (role_id, permission_code)
select r.id, 'bank.book.record'
  from public.roles r
 where r.is_system
   and r.code in ('DEALER_OWNER', 'ACCOUNTS')
on conflict do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0033_service_operations.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0033 — Service operations: job cards, billing, posting and payment
-- =============================================================================
-- Spec §32, §33.
--
-- The workshop flow: job card → work done → invoice → post → collect. Spares
-- consumed on a job leave stock LOCAL-before-COMPANY (spec §31), the same order
-- as a vehicle fitting, and the source is recorded on each line so the invoice
-- stays explainable.
--
-- Rollback: drop the functions below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.create_job_card() — spec §32
-- -----------------------------------------------------------------------------
create or replace function public.create_job_card(
  p_branch_id       uuid,
  p_customer_id     uuid,
  p_service_type    text default 'PAID',
  p_registration_no text default null,
  p_odometer        numeric default null,
  p_complaint       text default null,
  p_customer_vehicle_id uuid default null,
  p_service_advisor_id  uuid default null,
  p_technician_id       uuid default null,
  p_promised_at     timestamptz default null,
  p_job_date        date default current_date
)
returns table (job_card_id uuid, job_card_number text)
language plpgsql
as $$
declare
  v_dealer uuid;
  v_number text;
  v_id     uuid;
begin
  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  v_number := app.next_document_number(
    v_dealer, p_branch_id, 'JOB_CARD', app.financial_year_token(v_dealer, p_job_date));

  insert into public.job_cards
    (dealer_id, branch_id, job_card_number, job_date, customer_id, customer_vehicle_id,
     registration_no, odometer, service_type, complaint, service_advisor_id, technician_id,
     promised_at, created_by)
  values
    (v_dealer, p_branch_id, v_number, p_job_date, p_customer_id, p_customer_vehicle_id,
     nullif(btrim(p_registration_no), ''), p_odometer, p_service_type, p_complaint,
     p_service_advisor_id, p_technician_id, p_promised_at, auth.uid())
  returning id into v_id;

  job_card_id := v_id; job_card_number := v_number;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.create_service_invoice() — a draft bill for a job card (spec §32)
-- -----------------------------------------------------------------------------
create or replace function public.create_service_invoice(
  p_job_card_id  uuid,
  p_invoice_date date default current_date
)
returns table (invoice_id uuid, invoice_number text)
language plpgsql
as $$
declare
  v_job    public.job_cards;
  v_number text;
  v_id     uuid;
begin
  select * into v_job from public.job_cards where id = p_job_card_id for update;

  if v_job.id is null then
    raise exception 'Job card not found.' using errcode = 'no_data_found';
  end if;
  if v_job.status in ('INVOICED', 'CLOSED', 'CANCELLED') then
    raise exception 'Job card % is % and cannot be billed again.', v_job.job_card_number, v_job.status
      using errcode = 'check_violation';
  end if;

  -- One open bill per job card. A second draft would let two people bill the
  -- same work without either seeing the other.
  if exists (
    select 1 from public.service_invoices
     where job_card_id = p_job_card_id and status in ('DRAFT', 'POSTED')
  ) then
    raise exception 'This job card already has an invoice.' using errcode = 'unique_violation';
  end if;

  v_number := app.next_document_number(
    v_job.dealer_id, v_job.branch_id, 'SERVICE_INVOICE',
    app.financial_year_token(v_job.dealer_id, p_invoice_date));

  insert into public.service_invoices
    (dealer_id, branch_id, invoice_number, invoice_date, invoice_type,
     job_card_id, customer_id, created_by)
  values
    (v_job.dealer_id, v_job.branch_id, v_number, p_invoice_date, 'SERVICE',
     p_job_card_id, v_job.customer_id, auth.uid())
  returning id into v_id;

  invoice_id := v_id; invoice_number := v_number;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.add_service_line() — labour or a part (spec §32, §33)
-- -----------------------------------------------------------------------------
-- A spare line resolves its cost and its stock source here rather than at
-- posting, so the operator sees on the draft which stock the part will come out
-- of, and so an out-of-stock part is refused while the bill can still be changed.
-- -----------------------------------------------------------------------------
create or replace function public.add_service_line(
  p_invoice_id  uuid,
  p_line_type   text,
  p_description text,
  p_quantity    numeric,
  p_unit_rate   numeric,
  p_item_id     uuid default null,
  p_tax_code    text default null,
  p_discount    numeric default 0
)
returns uuid
language plpgsql
as $$
declare
  v_invoice   public.service_invoices;
  v_line      smallint;
  v_tax       record;
  v_taxable   numeric(18, 4);
  v_hsn       text;
  v_cost      numeric(18, 4) := 0;
  v_available numeric(14, 3);
  v_source    text;
  v_id        uuid;
  v_cgst      numeric(18, 4) := 0;
  v_sgst      numeric(18, 4) := 0;
  v_cgst_rate numeric(6, 3)  := 0;
  v_sgst_rate numeric(6, 3)  := 0;
begin
  select * into v_invoice from public.service_invoices where id = p_invoice_id for update;

  if v_invoice.id is null then
    raise exception 'Invoice not found.' using errcode = 'no_data_found';
  end if;
  if v_invoice.status <> 'DRAFT' then
    raise exception 'Invoice % is % and can no longer be edited.', v_invoice.invoice_number, v_invoice.status
      using errcode = 'check_violation';
  end if;
  if p_quantity <= 0 then
    raise exception 'Quantity must be greater than zero.' using errcode = 'check_violation';
  end if;

  v_taxable := round(p_quantity * p_unit_rate, 2) - coalesce(p_discount, 0);
  if v_taxable < 0 then
    raise exception 'The discount is more than the line value.' using errcode = 'check_violation';
  end if;

  -- ── A part comes out of stock, LOCAL before COMPANY (spec §31) ─────────────
  if p_item_id is not null and p_line_type in ('SPARE', 'ACCESSORY') then
    select h.code into v_hsn
      from public.inventory_items i
      left join public.hsn_codes h on h.id = i.hsn_code_id
     where i.id = p_item_id;

    -- allocate_stock reports a shortfall as a row of its own rather than by
    -- returning less, so the shortfall must be looked for explicitly — summing
    -- the quantities would count it as if it had been allocated. Blocking here,
    -- while the bill is still a draft, beats failing at posting with the
    -- customer waiting (spec §31).
    select a.quantity into v_available
      from public.allocate_stock(p_item_id, v_invoice.branch_id, p_quantity) a
     where a.source = 'SHORTFALL';

    if v_available is not null then
      raise exception 'Not enough stock: short by % of %.', v_available, p_quantity
        using errcode = 'check_violation',
              hint = 'Transfer stock in, or reduce the quantity.';
    end if;

    select coalesce(sum(a.quantity * a.unit_cost), 0),
           -- The source shown on the line is where the first unit comes from;
           -- a split allocation is recorded per movement at posting.
           min(a.source) filter (where a.source = 'LOCAL')
    into v_cost, v_source
      from public.allocate_stock(p_item_id, v_invoice.branch_id, p_quantity) a;

    v_source := coalesce(v_source, 'COMPANY');
  end if;

  -- The rates stay in scalars: a `record` that was never assigned raises on
  -- first access, so an untaxed line would fail at the INSERT below.
  if p_tax_code is not null then
    select * into v_tax from public.resolve_tax_code(v_invoice.dealer_id, p_tax_code, v_invoice.invoice_date);
    v_cgst_rate := coalesce(v_tax.cgst_rate, 0);
    v_sgst_rate := coalesce(v_tax.sgst_rate, 0);
    v_cgst := round(v_taxable * v_cgst_rate / 100, 2);
    v_sgst := round(v_taxable * v_sgst_rate / 100, 2);
  end if;

  select coalesce(max(line_number), 0) + 1 into v_line
    from public.service_lines where invoice_id = p_invoice_id;

  insert into public.service_lines
    (invoice_id, dealer_id, line_number, line_type, description, item_id, hsn_code,
     quantity, unit_rate, discount, taxable_value, tax_code,
     cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount,
     unit_cost, cost_amount, stock_source)
  values
    (p_invoice_id, v_invoice.dealer_id, v_line, p_line_type, p_description, p_item_id, v_hsn,
     p_quantity, p_unit_rate, coalesce(p_discount, 0), v_taxable, p_tax_code,
     v_cgst_rate, v_sgst_rate, v_cgst, v_sgst,
     v_taxable + v_cgst + v_sgst,
     case when p_quantity > 0 then round(v_cost / p_quantity, 4) else 0 end, v_cost, v_source)
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.remove_service_line(p_line_id uuid)
returns void
language plpgsql
as $$
declare v_status text;
begin
  select i.status into v_status
    from public.service_lines l
    join public.service_invoices i on i.id = l.invoice_id
   where l.id = p_line_id;

  if v_status is null then
    raise exception 'Line not found.' using errcode = 'no_data_found';
  end if;
  if v_status <> 'DRAFT' then
    raise exception 'This invoice is % and can no longer be edited.', v_status
      using errcode = 'check_violation';
  end if;

  delete from public.service_lines where id = p_line_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.post_service_invoice() — one transaction (spec §32, §48)
-- -----------------------------------------------------------------------------
-- Revenue, GST, COGS and stock relief happen together or not at all. A service
-- invoice whose journal posted but whose spares never left stock is a workshop
-- that has sold parts it still believes it holds.
-- -----------------------------------------------------------------------------
create or replace function public.post_service_invoice(
  p_invoice_id      uuid,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_invoice public.service_invoices;
  v_line    record;
  v_lines   jsonb := '[]'::jsonb;
  v_entry   uuid;
  v_dealer  uuid;
  v_branch  uuid;
  v_cogs    numeric(18, 4) := 0;
  v_remaining numeric(14, 3);
  v_alloc   record;
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
  for v_line in
    select id, item_id, quantity, unit_rate
      from public.service_lines
     where invoice_id = p_invoice_id and item_id is not null
     order by line_number
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

      v_cogs := v_cogs + round(v_alloc.quantity * v_alloc.unit_cost, 2);
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

  v_entry := app.post_journal(
    v_dealer, v_branch, v_invoice.invoice_date, 'SERVICE',
    'Service invoice ' || v_invoice.invoice_number,
    v_lines, 'SERVICE_INVOICE', p_invoice_id,
    coalesce(p_idempotency_key, 'service:' || p_invoice_id::text));

  update public.service_invoices
     set status = 'POSTED', posted_at = now(), journal_entry_id = v_entry,
         total_cost = v_cogs, idempotency_key = coalesce(p_idempotency_key, 'service:' || p_invoice_id::text),
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
-- public.record_service_payment() — spec §32
-- -----------------------------------------------------------------------------
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

  select si.total_amount - si.paid_amount into v_balance
    from public.service_invoices si where si.id = p_invoice_id;

  payment_id := v_id; receipt_number := v_number; balance_due := v_balance;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.service_history() — spec §33
-- -----------------------------------------------------------------------------
create or replace function public.service_history(
  p_customer_id     uuid default null,
  p_registration_no text default null
)
returns table (
  job_card_id     uuid,
  job_card_number text,
  job_date        date,
  customer_name   text,
  registration_no text,
  odometer        numeric(10, 1),
  service_type    text,
  complaint       text,
  status          text,
  invoice_number  text,
  invoice_total   numeric(18, 4),
  paid_amount     numeric(18, 4)
)
language sql
stable
as $$
  select j.id, j.job_card_number, j.job_date, c.name, j.registration_no, j.odometer,
         j.service_type, j.complaint, j.status,
         i.invoice_number, i.total_amount, i.paid_amount
    from public.job_cards j
    join public.customers c on c.id = j.customer_id
    left join public.service_invoices i
      on i.job_card_id = j.id and i.status <> 'CANCELLED'
   where (p_customer_id is null or j.customer_id = p_customer_id)
     and (p_registration_no is null or j.registration_no ilike p_registration_no)
   order by j.job_date desc, j.job_card_number desc;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.create_job_card(uuid, uuid, text, text, numeric, text, uuid, uuid, uuid, timestamptz, date) to authenticated';
    execute 'grant execute on function public.create_service_invoice(uuid, date) to authenticated';
    execute 'grant execute on function public.add_service_line(uuid, text, text, numeric, numeric, uuid, text, numeric) to authenticated';
    execute 'grant execute on function public.remove_service_line(uuid) to authenticated';
    execute 'grant execute on function public.post_service_invoice(uuid, text) to authenticated';
    execute 'grant execute on function public.record_service_payment(uuid, numeric, text, text, date) to authenticated';
    execute 'grant execute on function public.service_history(uuid, text) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0034_gst_reports.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0034 — GST returns and the e-invoice queue
-- =============================================================================
-- Spec §40.
--
-- Two things here, and it matters that they are separate:
--
--   Reporting   GSTR-1 style views over documents the dealer has already
--               issued. These are derived, never stored, so they cannot drift
--               from the invoices they summarise.
--
--   Queue       einvoices and eway_bills rows track what the GST portal has
--               been told. Enqueuing is a local act; whether the portal
--               responded is a separate fact. A failure there must never roll
--               back an accounting transaction that already happened.
--
-- Rollback: drop the functions below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.gstr1_summary() — outward supplies by section (spec §40)
-- -----------------------------------------------------------------------------
-- The B2B/B2C split turns on whether the customer has a GSTIN, which is what the
-- return itself turns on. A registered buyer whose GSTIN was never captured ends
-- up in B2C and cannot claim credit, so the count of missing GSTINs is worth
-- seeing next to the totals rather than buried.
-- -----------------------------------------------------------------------------
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
    select s.id, c.gstin, s.taxable_value, s.cgst_amount, s.sgst_amount, s.igst_amount,
           s.total_amount
      from public.sales s
      left join public.customers c on c.id = s.customer_id
     where s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select si.id, c.gstin, si.taxable_value, si.cgst_amount, si.sgst_amount, si.igst_amount,
           si.total_amount
      from public.service_invoices si
      left join public.customers c on c.id = si.customer_id
     where si.status = 'POSTED'
       and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
  )
  select case when nullif(btrim(coalesce(docs.gstin, '')), '') is not null then 'B2B' else 'B2C' end,
         count(*), sum(docs.taxable_value), sum(docs.cgst_amount), sum(docs.sgst_amount),
         sum(docs.igst_amount),
         sum(docs.cgst_amount + docs.sgst_amount + docs.igst_amount),
         sum(docs.total_amount)
    from docs
   group by 1
   order by 1;
$$;

-- -----------------------------------------------------------------------------
-- public.gst_document_register() — the invoice-level detail behind the return
-- -----------------------------------------------------------------------------
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
           s.taxable_value, s.cgst_amount, s.sgst_amount, s.igst_amount, s.total_amount
      from public.sales s
      left join public.customers c on c.id = s.customer_id
     where s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select 'SERVICE_INVOICE', si.id, si.invoice_number, si.invoice_date,
           coalesce(c.name, 'Counter sale'), c.gstin, c.state,
           si.taxable_value, si.cgst_amount, si.sgst_amount, si.igst_amount, si.total_amount
      from public.service_invoices si
      left join public.customers c on c.id = si.customer_id
     where si.status = 'POSTED'
       and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
  )
  select d.dtype, d.id, d.invoice_number, d.invoice_date, d.cname, d.gstin, d.pos,
         case when nullif(btrim(coalesce(d.gstin, '')), '') is not null then 'B2B' else 'B2C' end,
         d.taxable_value, d.cgst_amount, d.sgst_amount, d.igst_amount, d.total_amount,
         -- No e-invoice row at all is a different state from one that failed.
         coalesce(e.status, 'NOT_REQUESTED'), e.irn
    from docs d
    left join public.einvoices e on e.document_type = d.dtype and e.document_id = d.id
   where p_section is null
      or p_section = (case when nullif(btrim(coalesce(d.gstin, '')), '') is not null then 'B2B' else 'B2C' end)
   order by d.invoice_date, d.invoice_number;
$$;

-- -----------------------------------------------------------------------------
-- public.queue_einvoice() — record the intent to file (spec §40)
-- -----------------------------------------------------------------------------
-- Creating the row is all this does. Whether the portal accepts it is recorded
-- later by whatever process talks to the portal, so a portal outage leaves a
-- retryable row rather than blocking the sale.
-- -----------------------------------------------------------------------------
create or replace function public.queue_einvoice(
  p_document_type text,
  p_document_id   uuid
)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid;
  v_number text;
  v_date   date;
  v_id     uuid;
  v_status text;
begin
  if p_document_type = 'SALE' then
    select dealer_id, invoice_number, invoice_date, status
      into v_dealer, v_number, v_date, v_status
      from public.sales where id = p_document_id;
  elsif p_document_type = 'SERVICE_INVOICE' then
    select dealer_id, invoice_number, invoice_date, status
      into v_dealer, v_number, v_date, v_status
      from public.service_invoices where id = p_document_id;
  else
    raise exception 'Unsupported document type %.', p_document_type using errcode = 'check_violation';
  end if;

  if v_dealer is null then
    raise exception 'Document not found.' using errcode = 'no_data_found';
  end if;

  -- An unposted invoice is not yet a supply, and filing one would report a sale
  -- the books do not carry.
  if v_status not in ('POSTED', 'DELIVERED') then
    raise exception 'Document % is % — only a posted invoice can be filed.', v_number, v_status
      using errcode = 'check_violation';
  end if;

  insert into public.einvoices
    (dealer_id, document_type, document_id, document_number, document_date, status, created_by)
  values
    (v_dealer, p_document_type, p_document_id, v_number, v_date, 'PENDING', auth.uid())
  on conflict on constraint einvoices_document_key do update
     set status = case
                    -- A generated e-invoice is not re-queued: it has an IRN.
                    when public.einvoices.status = 'GENERATED' then 'GENERATED'
                    else 'PENDING'
                  end,
         error_code = null,
         error_message = null
  returning id into v_id;

  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_einvoice_result() — what the portal said
-- -----------------------------------------------------------------------------
create or replace function public.record_einvoice_result(
  p_einvoice_id uuid,
  p_status      text,
  p_irn         text default null,
  p_ack_number  text default null,
  p_ack_date    timestamptz default null,
  p_qr_code     text default null,
  p_error_code  text default null,
  p_error       text default null,
  p_response    jsonb default null
)
returns void
language plpgsql
as $$
begin
  if p_status not in ('GENERATED', 'FAILED', 'CANCELLED') then
    raise exception 'Status must be GENERATED, FAILED or CANCELLED.' using errcode = 'check_violation';
  end if;
  if p_status = 'GENERATED' and (p_irn is null or p_ack_number is null) then
    raise exception 'A generated e-invoice must carry an IRN and acknowledgement number.'
      using errcode = 'check_violation';
  end if;
  if p_status = 'FAILED' and p_error is null then
    raise exception 'A failed e-invoice must record why.' using errcode = 'check_violation';
  end if;

  update public.einvoices
     set status = p_status,
         irn = coalesce(p_irn, irn),
         ack_number = coalesce(p_ack_number, ack_number),
         ack_date = coalesce(p_ack_date, ack_date),
         signed_qr_code = coalesce(p_qr_code, signed_qr_code),
         error_code = p_error_code,
         error_message = p_error,
         response_payload = coalesce(p_response, response_payload),
         attempt_count = attempt_count + 1,
         last_attempt_at = now()
   where id = p_einvoice_id;

  if not found then
    raise exception 'E-invoice record not found.' using errcode = 'no_data_found';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.queue_eway_bill() — spec §40
-- -----------------------------------------------------------------------------
create or replace function public.queue_eway_bill(
  p_document_type   text,
  p_document_id     uuid,
  p_transport_mode  text default 'ROAD',
  p_vehicle_number  text default null,
  p_distance_km     integer default null,
  p_transporter_id  text default null,
  p_transporter_name text default null
)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid;
  v_number text;
  v_id     uuid;
begin
  if p_document_type = 'SALE' then
    select dealer_id, invoice_number into v_dealer, v_number
      from public.sales where id = p_document_id;
  elsif p_document_type = 'SERVICE_INVOICE' then
    select dealer_id, invoice_number into v_dealer, v_number
      from public.service_invoices where id = p_document_id;
  elsif p_document_type = 'TRANSFER' then
    select dealer_id, transfer_number into v_dealer, v_number
      from public.vehicle_transfers where id = p_document_id;
  else
    raise exception 'Unsupported document type %.', p_document_type using errcode = 'check_violation';
  end if;

  if v_dealer is null then
    raise exception 'Document not found.' using errcode = 'no_data_found';
  end if;

  insert into public.eway_bills
    (dealer_id, document_type, document_id, document_number, status,
     transport_mode, vehicle_number, distance_km, transporter_id, transporter_name, created_by)
  values
    (v_dealer, p_document_type, p_document_id, v_number, 'PENDING',
     p_transport_mode, nullif(btrim(p_vehicle_number), ''), p_distance_km,
     nullif(btrim(p_transporter_id), ''), nullif(btrim(p_transporter_name), ''), auth.uid())
  on conflict on constraint eway_document_key do update
     set status = case when public.eway_bills.status = 'GENERATED' then 'GENERATED' else 'PENDING' end,
         transport_mode = excluded.transport_mode,
         vehicle_number = excluded.vehicle_number,
         distance_km = excluded.distance_km,
         error_message = null
  returning id into v_id;

  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.einvoice_queue() — what is waiting, what failed, what is missing
-- -----------------------------------------------------------------------------
-- Posted invoices with no e-invoice row at all appear here too. They are the
-- ones nobody has noticed, and leaving them out of the queue is how a return
-- gets filed short.
-- -----------------------------------------------------------------------------
create or replace function public.einvoice_queue(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  einvoice_id     uuid,
  document_type   text,
  document_id     uuid,
  document_number text,
  document_date   date,
  customer_name   text,
  gstin           text,
  invoice_value   numeric(18, 4),
  status          text,
  irn             text,
  ack_number      text,
  error_message   text,
  attempt_count   integer
)
language sql
stable
as $$
  with docs as (
    select 'SALE'::text as dtype, s.id, s.invoice_number, s.invoice_date,
           coalesce(c.name, 'Cash customer') as cname, c.gstin, s.total_amount
      from public.sales s
      left join public.customers c on c.id = s.customer_id
     where s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select 'SERVICE_INVOICE', si.id, si.invoice_number, si.invoice_date,
           coalesce(c.name, 'Counter sale'), c.gstin, si.total_amount
      from public.service_invoices si
      left join public.customers c on c.id = si.customer_id
     where si.status = 'POSTED'
       and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
  )
  select e.id, d.dtype, d.id, d.invoice_number, d.invoice_date, d.cname, d.gstin,
         d.total_amount,
         coalesce(e.status, 'NOT_REQUESTED'), e.irn, e.ack_number, e.error_message,
         coalesce(e.attempt_count, 0)
    from docs d
    left join public.einvoices e on e.document_type = d.dtype and e.document_id = d.id
   order by
     -- Failures first, then never-requested, then pending; the generated ones
     -- need no attention.
     case coalesce(e.status, 'NOT_REQUESTED')
       when 'FAILED' then 1 when 'NOT_REQUESTED' then 2 when 'PENDING' then 3 else 4 end,
     d.invoice_date desc;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.gstr1_summary(date, date, uuid) to authenticated';
    execute 'grant execute on function public.gst_document_register(date, date, uuid, text) to authenticated';
    execute 'grant execute on function public.queue_einvoice(text, uuid) to authenticated';
    execute 'grant execute on function public.record_einvoice_result(uuid, text, text, text, timestamptz, text, text, text, jsonb) to authenticated';
    execute 'grant execute on function public.queue_eway_bill(text, uuid, text, text, integer, text, text) to authenticated';
    execute 'grant execute on function public.einvoice_queue(date, date, uuid) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0035_mis_reports.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0035 — MIS reports
-- =============================================================================
-- Spec §41, §43.
--
-- Every figure is derived from posted documents. Nothing here is stored, cached
-- or maintained by trigger, so a report can be wrong only if the transactions
-- behind it are wrong — which is the property that makes a report worth reading.
--
-- Cost and margin appear in these result sets. Spec §10 and §52 require them to
-- be withheld from responses for roles without permission, which the service
-- layer does with scrubRestrictedFields(); it is not this layer's job, but it is
-- this layer's reason for keeping them in named columns rather than blending
-- them into a total.
--
-- Rollback: drop the functions below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.finance_summary() — spec §41
-- -----------------------------------------------------------------------------
create or replace function public.finance_summary(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  finance_company_id   uuid,
  finance_company_name text,
  application_count    bigint,
  approved_count       bigint,
  rejected_count       bigint,
  pending_count        bigint,
  loan_amount          numeric(18, 4),
  disbursed_amount     numeric(18, 4),
  pending_disbursement numeric(18, 4),
  commission_amount    numeric(18, 4)
)
language sql
stable
as $$
  select f.id, f.name,
         count(*),
         count(*) filter (where a.approval_status = 'APPROVED'),
         count(*) filter (where a.approval_status = 'REJECTED'),
         count(*) filter (where a.approval_status = 'PENDING'),
         sum(a.loan_amount),
         sum(a.disbursed_amount),
         -- Only approved business can be pending disbursement; a rejected
         -- application is not money anyone is waiting for.
         sum(case when a.approval_status = 'APPROVED'
                  then coalesce(a.approved_amount, a.loan_amount) - a.disbursed_amount
                  else 0 end),
         sum(a.commission_amount)
    from public.finance_applications a
    join public.finance_companies f on f.id = a.finance_company_id
   where a.application_date between p_from and p_to
     and (p_branch_id is null or a.branch_id = p_branch_id)
   group by f.id, f.name
   order by sum(a.loan_amount) desc;
$$;

-- -----------------------------------------------------------------------------
-- public.branch_performance() — spec §43
-- -----------------------------------------------------------------------------
-- One row per branch, with the streams that make up its result. The subqueries
-- are deliberate: joining sales, service and bookings in one query multiplies
-- rows against each other and inflates every total.
-- -----------------------------------------------------------------------------
create or replace function public.branch_performance(
  p_from date,
  p_to   date
)
returns table (
  branch_id         uuid,
  branch_code       text,
  branch_name       text,
  vehicle_units     bigint,
  vehicle_revenue   numeric(18, 4),
  vehicle_cost      numeric(18, 4),
  vehicle_margin    numeric(18, 4),
  service_jobs      bigint,
  service_revenue   numeric(18, 4),
  service_cost      numeric(18, 4),
  bookings_open     bigint,
  booking_advances  numeric(18, 4),
  cash_in_hand      numeric(18, 4),
  receivables       numeric(18, 4)
)
language sql
stable
as $$
  select b.id, b.code, b.name,
         coalesce(s.units, 0), coalesce(s.revenue, 0), coalesce(s.cost, 0),
         coalesce(s.revenue, 0) - coalesce(s.cost, 0),
         coalesce(v.jobs, 0), coalesce(v.revenue, 0), coalesce(v.cost, 0),
         coalesce(k.open_count, 0), coalesce(k.advances, 0),
         coalesce(c.current_balance, 0),
         coalesce(s.receivable, 0) + coalesce(v.receivable, 0)
    from public.branches b
    left join lateral (
      select count(*) units,
             sum(sa.taxable_value) revenue,
             sum(sa.total_cost) cost,
             sum(sa.total_amount - sa.paid_amount) receivable
        from public.sales sa
       where sa.branch_id = b.id
         and sa.status in ('POSTED', 'DELIVERED')
         and sa.invoice_date between p_from and p_to
    ) s on true
    left join lateral (
      select count(*) jobs,
             sum(si.taxable_value) revenue,
             sum(si.total_cost) cost,
             sum(si.total_amount - si.paid_amount) receivable
        from public.service_invoices si
       where si.branch_id = b.id
         and si.status = 'POSTED'
         and si.invoice_date between p_from and p_to
    ) v on true
    left join lateral (
      select count(*) filter (where bk.status = 'OPEN') open_count,
             sum(bk.received_amount) filter (where bk.status = 'OPEN') advances
        from public.bookings bk
       where bk.branch_id = b.id
         and bk.booking_date between p_from and p_to
    ) k on true
    left join public.cash_accounts c on c.branch_id = b.id
   where b.status = 'ACTIVE'
   order by coalesce(s.revenue, 0) desc, b.name;
$$;

-- -----------------------------------------------------------------------------
-- public.margin_report() — spec §41, restricted
-- -----------------------------------------------------------------------------
-- Margin by stream, because "our margin" means something different for a vehicle
-- than for a spare part, and a blended figure hides which one is failing.
-- -----------------------------------------------------------------------------
create or replace function public.margin_report(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  stream        text,
  document_count bigint,
  revenue       numeric(18, 4),
  cost          numeric(18, 4),
  margin        numeric(18, 4),
  margin_percent numeric(8, 3)
)
language sql
stable
as $$
  with streams as (
    select 'Vehicle sales'::text as stream, count(*)::bigint as documents,
           coalesce(sum(s.taxable_value), 0) as revenue,
           coalesce(sum(s.total_cost), 0) as cost
      from public.sales s
     where s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select 'Service and parts', count(*)::bigint,
           coalesce(sum(si.taxable_value), 0), coalesce(sum(si.total_cost), 0)
      from public.service_invoices si
     where si.status = 'POSTED'
       and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
    union all
    -- Commission has no cost of its own: it is margin in full.
    select 'Finance commission', count(*)::bigint,
           coalesce(sum(a.commission_amount), 0), 0
      from public.finance_applications a
     where a.commission_amount > 0
       and a.application_date between p_from and p_to
       and (p_branch_id is null or a.branch_id = p_branch_id)
  )
  select streams.stream, streams.documents, streams.revenue, streams.cost,
         streams.revenue - streams.cost,
         case when streams.revenue > 0
              then round((streams.revenue - streams.cost) * 100 / streams.revenue, 3)
              else 0 end
    from streams
   where streams.documents > 0
   order by streams.revenue - streams.cost desc;
$$;

-- -----------------------------------------------------------------------------
-- public.consolidated_mis() — the whole dealership on one line per stream
-- -----------------------------------------------------------------------------
-- Spec §43. Sales, service, cash, bank and receivables together, so the owner
-- does not have to open five screens and add them up.
-- -----------------------------------------------------------------------------
create or replace function public.consolidated_mis(
  p_from date,
  p_to   date
)
returns table (
  metric  text,
  category text,
  value   numeric(18, 4),
  count_value bigint
)
language sql
stable
as $$
  select 'Vehicles sold', 'Sales',
         coalesce(sum(s.total_amount), 0), count(*)::bigint
    from public.sales s
   where s.status in ('POSTED', 'DELIVERED') and s.invoice_date between p_from and p_to
  union all
  select 'Service invoices', 'Service',
         coalesce(sum(si.total_amount), 0), count(*)::bigint
    from public.service_invoices si
   where si.status = 'POSTED' and si.invoice_date between p_from and p_to
  union all
  select 'Bookings taken', 'Sales',
         coalesce(sum(b.received_amount), 0), count(*)::bigint
    from public.bookings b
   where b.booking_date between p_from and p_to
  union all
  select 'Cash collected', 'Collections',
         coalesce(sum(t.amount), 0), count(*)::bigint
    from public.cash_transactions t
   where t.direction = 'RECEIPT' and t.status = 'ACTIVE'
     and t.business_date between p_from and p_to
  union all
  select 'Cash paid out', 'Collections',
         coalesce(sum(t.amount), 0), count(*)::bigint
    from public.cash_transactions t
   where t.direction = 'PAYMENT' and t.status = 'ACTIVE'
     and t.business_date between p_from and p_to
  union all
  select 'Bank receipts', 'Collections',
         coalesce(sum(t.amount), 0), count(*)::bigint
    from public.bank_transactions t
   where t.direction = 'RECEIPT' and t.status = 'ACTIVE'
     and t.transaction_date between p_from and p_to
  union all
  -- Outstanding is as at now, not for the period: a receivable does not belong
  -- to the month it was raised in once it is still owed.
  select 'Receivable outstanding', 'Position',
         coalesce(sum(s.total_amount - s.paid_amount), 0), count(*)::bigint
    from public.sales s
   where s.status in ('POSTED', 'DELIVERED') and s.total_amount > s.paid_amount
  union all
  select 'Cash in hand', 'Position',
         coalesce(sum(c.current_balance), 0), count(*)::bigint
    from public.cash_accounts c where c.status = 'ACTIVE'
  union all
  select 'Bank balance', 'Position',
         coalesce(sum(a.current_balance), 0), count(*)::bigint
    from public.bank_accounts a where a.status = 'ACTIVE'
  union all
  select 'Vehicles in stock', 'Position',
         coalesce(sum(v.purchase_cost), 0), count(*)::bigint
    from public.vehicles v where v.status = 'IN_STOCK';
$$;

-- -----------------------------------------------------------------------------
-- public.inventory_movement_report() — what moved, and why
-- -----------------------------------------------------------------------------
create or replace function public.inventory_movement_report(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  item_id        uuid,
  item_code      text,
  item_name      text,
  item_type      text,
  received_qty   numeric(14, 3),
  issued_qty     numeric(14, 3),
  received_value numeric(18, 4),
  issued_value   numeric(18, 4),
  closing_qty    numeric(14, 3),
  closing_value  numeric(18, 4)
)
language sql
stable
as $$
  select i.id, i.item_code, i.name, i.item_type,
         coalesce(sum(t.quantity) filter (where t.quantity > 0), 0),
         coalesce(-sum(t.quantity) filter (where t.quantity < 0), 0),
         coalesce(sum(t.value) filter (where t.quantity > 0), 0),
         coalesce(-sum(t.value) filter (where t.quantity < 0), 0),
         coalesce(max(s.total_qty), 0),
         coalesce(max(s.total_value), 0)
    from public.inventory_items i
    left join public.inventory_transactions t
      on t.item_id = i.id
     and t.created_at::date between p_from and p_to
     and (p_branch_id is null or t.branch_id = p_branch_id)
    left join lateral (
      select sum(st.quantity) total_qty, sum(st.stock_value) total_value
        from public.inventory_stock st
       where st.item_id = i.id
         and (p_branch_id is null or st.branch_id = p_branch_id)
    ) s on true
   group by i.id, i.item_code, i.name, i.item_type
  having coalesce(sum(abs(t.quantity)), 0) > 0 or coalesce(max(s.total_qty), 0) > 0
   order by i.name;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.finance_summary(date, date, uuid) to authenticated';
    execute 'grant execute on function public.branch_performance(date, date) to authenticated';
    execute 'grant execute on function public.margin_report(date, date, uuid) to authenticated';
    execute 'grant execute on function public.consolidated_mis(date, date) to authenticated';
    execute 'grant execute on function public.inventory_movement_report(date, date, uuid) to authenticated';
  end if;
end;
$$;


commit;
