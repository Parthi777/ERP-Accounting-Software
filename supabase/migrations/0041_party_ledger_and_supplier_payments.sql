-- =============================================================================
-- 0041 — Party ledger, and supplier tagging on money movements
-- =============================================================================
-- Spec §11, §41.
--
-- Two halves of one problem: a supplier ledger needs a query that can read a
-- party account, and it needs journal lines actually tagged with the supplier.
-- Neither existed. Every writer in the codebase hardcoded party_type='CUSTOMER',
-- so account 2200 (Supplier Payables) has only ever held an undifferentiated
-- total, and no subsidiary ledger could be derived from it.
--
-- 1. The ledger from 0037 is generalised over party type. customer_ledger and
--    customer_ledger_opening become thin wrappers, so everything already calling
--    them — src/server/services/accounting/ledger-service.ts and
--    supabase/test/90_customer_ledger.sql — keeps working untouched, and the two
--    party ledgers can never drift apart because there is only one of them.
--
-- 2. record_cash_transaction and record_bank_transaction learn about suppliers.
--    These are DROPPED and recreated rather than replaced: they gain a
--    parameter, and `create or replace` cannot change a signature. Leaving both
--    signatures in place would create an overload, which makes supabase.rpc()
--    ambiguous at runtime and makes scripts/generate-types.mjs emit the same key
--    twice — a TypeScript error. The old grants die with the old functions and
--    are reissued below.
--
-- Rollback: restore record_cash_transaction from 0030 and record_bank_transaction
--           from 0031 with their grants; drop public.party_ledger,
--           public.party_ledger_opening; restore customer_ledger and
--           customer_ledger_opening from 0037; drop the columns added below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.party_ledger_opening() — what a party's balance was before a date
-- -----------------------------------------------------------------------------
-- Debit positive throughout, for every party type. For a customer that reads as
-- "they owe us"; for a supplier the natural sign is the mirror, so a supplier
-- balance is normally negative here and the view labels it Cr. Keeping one
-- convention in the data and inverting only for display is what lets both
-- ledgers reconcile to their control accounts with the same arithmetic.
-- -----------------------------------------------------------------------------
create or replace function public.party_ledger_opening(
  p_party_type text,
  p_party_id   uuid,
  p_as_on      date
)
returns numeric
language sql
stable
as $$
  select coalesce(sum(l.debit - l.credit), 0)::numeric(18, 4)
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.party_type = p_party_type
     and l.party_id = p_party_id
     and je.status in ('POSTED', 'REVERSED')
     and je.entry_date < p_as_on;
$$;

comment on function public.party_ledger_opening(text, uuid, date) is
  'Balance carried into a date for any party (spec §41). Debit positive.';

-- -----------------------------------------------------------------------------
-- public.party_ledger() — the running account for any party
-- -----------------------------------------------------------------------------
create or replace function public.party_ledger(
  p_party_type text,
  p_party_id   uuid,
  p_from       date,
  p_to         date
)
returns table (
  entry_date      date,
  entry_number    text,
  narration       text,
  debit           numeric(18, 4),
  credit          numeric(18, 4),
  running_balance numeric(18, 4)
)
language sql
stable
as $$
  -- Derived from party-tagged journal lines, so a subsidiary ledger reconciles
  -- to its control account by construction. The running balance starts from the
  -- carried-forward balance, so any row read on its own is the party's actual
  -- position on that date rather than a total of the window on screen.
  select je.entry_date, je.entry_number, coalesce(l.narration, je.narration),
         l.debit, l.credit,
         public.party_ledger_opening(p_party_type, p_party_id, p_from)
           + sum(l.debit - l.credit) over (order by je.entry_date, je.entry_number, l.line_number
                                           rows between unbounded preceding and current row)
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.party_type = p_party_type
     and l.party_id = p_party_id
     and je.status in ('POSTED', 'REVERSED')
     and je.entry_date between p_from and p_to
   order by je.entry_date, je.entry_number, l.line_number;
$$;

comment on function public.party_ledger(text, uuid, date, date) is
  'Running account for any party from the general ledger (spec §41), opening '
  'balance included, so the subsidiary ledger and the control account agree.';

-- -----------------------------------------------------------------------------
-- The customer ledger becomes a wrapper — one implementation, two entry points
-- -----------------------------------------------------------------------------
create or replace function public.customer_ledger_opening(
  p_customer_id uuid,
  p_as_on       date
)
returns numeric
language sql
stable
as $$
  select public.party_ledger_opening('CUSTOMER', p_customer_id, p_as_on);
$$;

create or replace function public.customer_ledger(
  p_customer_id uuid,
  p_from        date,
  p_to          date
)
returns table (
  entry_date      date,
  entry_number    text,
  narration       text,
  debit           numeric(18, 4),
  credit          numeric(18, 4),
  running_balance numeric(18, 4)
)
language sql
stable
as $$
  select * from public.party_ledger('CUSTOMER', p_customer_id, p_from, p_to);
$$;

-- -----------------------------------------------------------------------------
-- Party columns on the money movements
-- -----------------------------------------------------------------------------
-- cash_transactions already carries customer_id; bank_transactions carried no
-- party at all, so a bank receipt from a customer could not be attributed.
alter table public.cash_transactions
  add column if not exists supplier_id uuid;

alter table public.bank_transactions
  add column if not exists supplier_id uuid,
  add column if not exists customer_id uuid;

alter table public.cash_transactions
  add constraint cash_transactions_supplier_tenant_fkey
  foreign key (supplier_id, dealer_id) references public.suppliers (id, dealer_id);

alter table public.bank_transactions
  add constraint bank_transactions_supplier_tenant_fkey
  foreign key (supplier_id, dealer_id) references public.suppliers (id, dealer_id);

alter table public.bank_transactions
  add constraint bank_transactions_customer_tenant_fkey
  foreign key (customer_id, dealer_id) references public.customers (id, dealer_id);

create index cash_transactions_supplier_idx on public.cash_transactions (supplier_id)
  where supplier_id is not null;
create index bank_transactions_supplier_idx on public.bank_transactions (supplier_id)
  where supplier_id is not null;
create index bank_transactions_customer_idx on public.bank_transactions (customer_id)
  where customer_id is not null;

-- -----------------------------------------------------------------------------
-- public.record_cash_transaction() — spec §37, now party-aware
-- -----------------------------------------------------------------------------
drop function if exists public.record_cash_transaction(uuid, text, numeric, text, uuid, uuid, text, date);

create function public.record_cash_transaction(
  p_branch_id   uuid,
  p_direction   text,
  p_amount      numeric,
  p_particular  text,
  p_account_id  uuid,
  p_customer_id uuid default null,
  p_reference   text default null,
  p_date        date default current_date,
  p_supplier_id uuid default null
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
    'CASH_BOOK', null, null
  );

  insert into public.cash_transactions
    (dealer_id, branch_id, cash_account_id, business_date, direction, amount,
     particular, reference_number, customer_id, supplier_id, journal_entry_id, created_by)
  values
    (v_dealer, p_branch_id, v_account.id, p_date, p_direction, p_amount,
     p_particular, p_reference, p_customer_id, p_supplier_id, v_entry, auth.uid())
  returning id, cash_transactions.balance_after into v_txn, v_balance;

  transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_bank_transaction() — spec §38, now party-aware
-- -----------------------------------------------------------------------------
drop function if exists public.record_bank_transaction(uuid, text, numeric, text, uuid, date, text, text, text);

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
  p_supplier_id     uuid default null
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
    'BANK_BOOK', null, null
  );

  insert into public.bank_transactions
    (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
     reference_number, utr, instrument_number, customer_id, supplier_id,
     journal_entry_id, created_by)
  values
    (v_bank.dealer_id, p_bank_account_id, p_date, p_direction, p_amount, p_particular,
     p_reference, nullif(btrim(p_utr), ''), nullif(btrim(p_instrument), ''),
     p_customer_id, p_supplier_id, v_entry, auth.uid())
  returning id, bank_transactions.balance_after into v_txn, v_balance;

  transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
  return next;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.party_ledger(text, uuid, date, date) to authenticated';
    execute 'grant execute on function public.party_ledger_opening(text, uuid, date) to authenticated';
    execute 'grant execute on function public.customer_ledger(uuid, date, date) to authenticated';
    execute 'grant execute on function public.customer_ledger_opening(uuid, date) to authenticated';
    execute 'grant execute on function public.record_cash_transaction(uuid, text, numeric, text, uuid, uuid, text, date, uuid) to authenticated';
    execute 'grant execute on function public.record_bank_transaction(uuid, text, numeric, text, uuid, date, text, text, text, uuid, uuid) to authenticated';
  end if;
end;
$$;
