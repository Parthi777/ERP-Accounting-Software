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
