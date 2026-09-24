-- =============================================================================
-- 0076 — Ledger integrity: what the posting engine accepted and should not have
-- =============================================================================
-- Spec §21, §22, §23, §24, §36, §38, §44, §46, §60.12, §60.20, §60.23.
--
-- Found by walking the accounting audit checklist (P0 "Balanced posting",
-- "Invalid voucher rejection", "Ledger and trial balance", "Closed period")
-- against the code rather than against the screens.
--
-- ── 1. A journal could post to a heading, and vanish from the trial balance ──
--
-- app.post_journal() checked that debits equal credits and nothing about the
-- accounts themselves. account_balances() — and so the trial balance, P&L and
-- balance sheet — reads `where not coa.is_group and coa.status = 'ACTIVE'`.
-- So a line on "1000 Assets" posted, balanced, and then did not exist as far as
-- every report was concerned. Reproduced on a fresh database before this
-- migration: one manual journal of 999 to 1000 against 2700 left the trial
-- balance out by exactly 999. The only thing preventing it was the journal
-- screen's picker; the database, the cash and bank RPCs and any other caller
-- did not check. The same went for an account that was later deactivated: its
-- balance simply left the books.
--
-- Fixed in two places, because either alone is not enough:
--   * post_journal refuses a line on a group, an inactive account, another
--     dealer's account, or with a negative / two-sided / non-numeric amount —
--     with a message naming the line and the account, before anything is
--     written;
--   * account_balances no longer hides INACTIVE accounts, and shows a group
--     that somehow carries lines rather than dropping them. A report that
--     silently omits posted money is worse than one that shows an odd row.
--   * a trigger on chart_of_accounts refuses the changes that would strand
--     posted lines: turning a used account into a group, changing its type or
--     normal side, deactivating it while it carries a balance, or deleting it.
--
-- ── 2. Cash and bank moved in the ledger without moving in the books ────────
--
-- Every bank account posts to 1200 and every cash account to 1100; the bank
-- book and cash book are the bank_transactions / cash_transactions tables that
-- the receipt functions write beside the journal. A manual journal touching
-- 1100/1200 — or a bank entry whose "counter account" was 1100 — moved the
-- ledger with no book row, so the cash book, the bank book, the BRS and the
-- trial balance stopped agreeing, permanently and silently. The manual-journal
-- test itself posted bank charges that way.
--
-- post_journal now refuses a line on a cash or bank ledger when the journal is
-- a manual one, and refuses a cash/bank entry whose counter account is itself a
-- cash or bank ledger. Money moving between cash and bank, or bank and bank, is
-- a Contra voucher (0077), which writes both books.
--
-- ── 3. There was no way to lock the books ──────────────────────────────────
--
-- accounting_periods are whole financial years and nothing closes one. A
-- dealer could post into last month after the GST return was filed. This adds a
-- lock date — "books locked through" — the way accounting packages do it:
-- nothing dated on or before it posts, including reversals. Moving it forward
-- or back needs accounting.periods.manage and a reason, and every move is kept
-- (the table is append-only, so the history is the table).
--
-- ── 4. The chart of accounts could not be extended ─────────────────────────
--
-- accounting.coa.manage has existed since 0003 and nothing used it. A dealer
-- buying a computer, depreciating it, taking a loan or recording drawings had
-- no account to put it in. create_account() and set_account_status() are the
-- door, and the standard accounts every dealer needs are seeded.
--
-- ── 5. Gross profit ─────────────────────────────────────────────────────────
--
-- The P&L listed income and expenses with no gross-profit line. COGS accounts
-- are marked COST_OF_SALES and profit_and_loss() reports them as their own
-- section, so gross profit is read, not calculated by the reader.
--
-- Rollback: restore app.post_journal and public.account_balances from 0025/0012,
--           public.profit_and_loss from 0026, public.post_manual_journal from
--           0069, app.seed_chart_of_accounts from 0066; drop the functions and
--           trigger created here and table public.accounting_locks. Accounts
--           seeded here may be deactivated but not deleted once used.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Helpers the posting engine calls. SECURITY DEFINER because post_journal runs
-- as the caller, and a cashier taking a receipt holds no accounting.coa.view —
-- the lookup must not depend on who is posting. Each takes the dealer and
-- returns nothing for another tenant's rows, so the helper widens nothing.
-- -----------------------------------------------------------------------------
create or replace function app.journal_account(p_dealer_id uuid, p_account_id uuid)
returns table (code text, name text, is_group boolean, status text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select c.code, c.name, c.is_group, c.status
    from public.chart_of_accounts c
   where c.id = p_account_id
     and c.dealer_id = p_dealer_id;
$$;

comment on function app.journal_account(uuid, uuid) is
  'The account facts post_journal validates against, independent of the caller''s '
  'RLS. Returns no row for an account belonging to another dealer.';

-- A cash or bank "money ledger": the control account behind a cash book or a
-- bank book. Lines on it must come with a book row, or the book and the ledger
-- part company.
create or replace function app.is_money_ledger(p_dealer_id uuid, p_account_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.cash_accounts
                  where dealer_id = p_dealer_id and ledger_account_id = p_account_id)
      or exists (select 1 from public.bank_accounts
                  where dealer_id = p_dealer_id and ledger_account_id = p_account_id);
$$;

comment on function app.is_money_ledger(uuid, uuid) is
  'True when the account is the ledger behind a cash book or bank book (spec §36, '
  '§38). Such lines are only posted by functions that also write the book row.';

-- -----------------------------------------------------------------------------
-- accounting_locks — "books locked through", append-only
-- -----------------------------------------------------------------------------
create table public.accounting_locks (
  id              uuid primary key default gen_random_uuid(),
  -- Order of record. Not created_at: two moves in one transaction share now(),
  -- and "the latest lock" must never be decided by a random uuid.
  seq             bigint generated always as identity,
  dealer_id       uuid not null references public.dealers (id) on delete cascade,
  -- NULL means "unlocked": reopening everything is a recorded act too.
  locked_through  date,
  reason          text not null,
  created_at      timestamptz not null default now(),
  created_by      uuid,

  constraint accounting_locks_reason_check check (length(btrim(reason)) between 3 and 500)
);

comment on table public.accounting_locks is
  'Append-only history of the dealer''s lock date (spec §23, §46). The current '
  'lock is the latest row; nothing dated on or before it posts.';

create index accounting_locks_dealer_idx on public.accounting_locks (dealer_id, seq desc);

alter table public.accounting_locks enable row level security;

-- Every dealer user may read it: the posting engine consults it for them, and a
-- cashier told "the books are locked" is entitled to see through when.
create policy accounting_locks_select on public.accounting_locks
  for select to authenticated
  using (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy accounting_locks_insert on public.accounting_locks
  for insert to authenticated
  with check (
    dealer_id = app.current_dealer_id() and app.has_permission('accounting.periods.manage')
  );

-- No update or delete policy: the history is the audit trail. The trigger below
-- makes that hold for the service role too.
create or replace function app.accounting_locks_append_only()
returns trigger
language plpgsql
as $$
begin
  raise exception 'The lock history cannot be edited. Set a new lock date instead.'
    using errcode = 'insufficient_privilege';
end;
$$;

create trigger accounting_locks_append_only
  before update or delete on public.accounting_locks
  for each row execute function app.accounting_locks_append_only();

create trigger accounting_locks_audit
  after insert on public.accounting_locks
  for each row execute function app.audit_trigger();

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert on public.accounting_locks to authenticated';
  end if;
end $$;

create or replace function app.books_locked_through(p_dealer_id uuid)
returns date
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select l.locked_through
    from public.accounting_locks l
   where l.dealer_id = p_dealer_id
   order by l.seq desc
   limit 1;
$$;

-- -----------------------------------------------------------------------------
-- public.set_books_lock() — lock, move, or reopen
-- -----------------------------------------------------------------------------
create or replace function public.set_books_lock(
  p_locked_through date,
  p_reason         text
)
returns table (locked_through date, previous date)
language plpgsql
as $$
declare
  v_dealer   uuid := app.current_dealer_id();
  v_previous date;
begin
  if v_dealer is null then
    raise exception 'Only a dealer user can lock that dealer''s books.'
      using errcode = 'insufficient_privilege';
  end if;
  if not app.has_permission('accounting.periods.manage') then
    raise exception 'You may not lock or reopen the books.'
      using errcode = 'insufficient_privilege';
  end if;
  if coalesce(length(btrim(p_reason)), 0) < 3 then
    raise exception 'Say why the lock date is changing. The reason is kept with it.'
      using errcode = 'check_violation';
  end if;
  if p_locked_through is not null and p_locked_through >= current_date then
    raise exception 'The books can be locked through yesterday at the latest.'
      using errcode = 'check_violation',
            hint = 'Today is still being traded; lock it once the day is closed.';
  end if;

  v_previous := app.books_locked_through(v_dealer);

  insert into public.accounting_locks (dealer_id, locked_through, reason, created_by)
  values (v_dealer, p_locked_through, btrim(p_reason), auth.uid());

  locked_through := p_locked_through;
  previous := v_previous;
  return next;
end;
$$;

comment on function public.set_books_lock(date, text) is
  'Moves the dealer''s lock date (NULL reopens everything). Needs '
  'accounting.periods.manage and a reason; every move is kept.';

-- -----------------------------------------------------------------------------
-- app.post_journal() — the single entry point to the ledger, now checking what
-- it posts to as well as that it balances
-- -----------------------------------------------------------------------------
create or replace function app.post_journal(
  p_dealer_id       uuid,
  p_branch_id       uuid,
  p_entry_date      date,
  p_source_module   text,
  p_narration       text,
  p_lines           jsonb,
  p_source_document_type text default null,
  p_source_document_id   uuid default null,
  p_idempotency_key      text default null,
  p_reversal_of_id       uuid default null,
  p_reversal_reason      text default null
)
returns uuid
language plpgsql
as $$
declare
  v_entry_id  uuid;
  v_number    text;
  v_year      text;
  v_period_id uuid;
  v_debit     numeric(18, 4) := 0;
  v_credit    numeric(18, 4) := 0;
  v_line      jsonb;
  v_index     smallint := 0;
  v_existing  uuid;
  v_acc       record;
  v_dr        numeric;
  v_cr        numeric;
  v_money     integer := 0;
  v_lock      date;
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    raise exception 'A journal needs at least two lines.'
      using errcode = 'check_violation';
  end if;

  -- Idempotency (spec §50): a repeated submission returns the original entry
  -- rather than posting a second one.
  if p_idempotency_key is not null then
    select id into v_existing
      from public.journal_entries
     where dealer_id = p_dealer_id and idempotency_key = p_idempotency_key;
    if v_existing is not null then
      return v_existing;
    end if;
  end if;

  -- ── Every line, before anything is written ───────────────────────────────
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_index := v_index + 1;

    if (v_line ->> 'account_id') is null then
      raise exception 'Journal line % has no account. Check the accounting rules for this event.', v_index
        using errcode = 'check_violation',
              hint = 'Spec §22: accounts are resolved from accounting_rules, never hard-coded.';
    end if;

    begin
      v_dr := coalesce((v_line ->> 'debit')::numeric, 0);
      v_cr := coalesce((v_line ->> 'credit')::numeric, 0);
    exception when others then
      raise exception 'Journal line % has an amount that is not a number.', v_index
        using errcode = 'check_violation';
    end;

    if v_dr < 0 or v_cr < 0 then
      raise exception 'Journal line % has a negative amount. Use the other side instead.', v_index
        using errcode = 'check_violation';
    end if;
    if (v_dr > 0) = (v_cr > 0) then
      raise exception 'Journal line % must be a debit or a credit — not both, and not zero.', v_index
        using errcode = 'check_violation';
    end if;

    select * into v_acc from app.journal_account(p_dealer_id, (v_line ->> 'account_id')::uuid);
    if v_acc.code is null then
      raise exception 'Journal line % names an account that does not belong to this dealer.', v_index
        using errcode = 'insufficient_privilege';
    end if;
    if v_acc.is_group then
      raise exception 'Journal line %: % % is a group heading and cannot be posted to.',
        v_index, v_acc.code, v_acc.name
        using errcode = 'check_violation',
              hint = 'Post to one of the accounts beneath it.';
    end if;
    if v_acc.status <> 'ACTIVE' then
      raise exception 'Journal line %: % % is inactive and cannot be posted to.',
        v_index, v_acc.code, v_acc.name
        using errcode = 'check_violation';
    end if;

    if app.is_money_ledger(p_dealer_id, (v_line ->> 'account_id')::uuid) then
      v_money := v_money + 1;
      -- A hand-written line on cash or bank moves the ledger and not the book.
      if p_source_document_type = 'MANUAL_JOURNAL' then
        raise exception 'Journal line %: % % is a cash or bank account. Use Bank or Cash entry, or a Contra voucher, so the book moves with the ledger.',
          v_index, v_acc.code, v_acc.name
          using errcode = 'check_violation';
      end if;
    end if;

    v_debit  := v_debit  + v_dr;
    v_credit := v_credit + v_cr;
  end loop;

  -- A cash or bank entry writes ONE book row. A counter account that is itself
  -- cash or bank would move a second book that nothing writes.
  if p_source_document_type in ('CASH_BOOK', 'BANK_BOOK') and v_money > 1 then
    raise exception 'Money moving between cash and bank, or between two banks, is a Contra voucher.'
      using errcode = 'check_violation',
            hint = 'Bank → Contra writes both books; a receipt or payment writes only one.';
  end if;

  if round(v_debit, 4) <> round(v_credit, 4) then
    raise exception 'Journal does not balance: debit % <> credit %.', v_debit, v_credit
      using errcode = 'check_violation',
            hint = 'Spec §22: total debit must equal total credit.';
  end if;

  -- ── The lock date ────────────────────────────────────────────────────────
  v_lock := app.books_locked_through(p_dealer_id);
  if v_lock is not null and p_entry_date <= v_lock then
    raise exception 'The books are locked through %. Nothing dated % can be posted.',
      to_char(v_lock, 'DD-MM-YYYY'), to_char(p_entry_date, 'DD-MM-YYYY')
      using errcode = 'insufficient_privilege',
            hint = 'Date the entry after the lock, or ask Accounts to reopen the period with a reason.';
  end if;

  v_year   := app.financial_year_token(p_dealer_id, p_entry_date);
  v_number := app.next_document_number(p_dealer_id, null, 'JOURNAL', v_year);

  select id into v_period_id
    from public.accounting_periods
   where dealer_id = p_dealer_id
     and p_entry_date between start_date and end_date
   limit 1;

  -- An entry dated into a closed period must not post (spec §44).
  if v_period_id is not null then
    if (select status from public.accounting_periods where id = v_period_id) <> 'OPEN' then
      raise exception 'The accounting period covering % is closed.', p_entry_date
        using errcode = 'insufficient_privilege';
    end if;
  end if;

  insert into public.journal_entries
    (dealer_id, branch_id, entry_number, entry_date, period_id, source_module,
     source_document_type, source_document_id, narration, idempotency_key,
     reversal_of_id, reversal_reason, created_by)
  values
    (p_dealer_id, p_branch_id, v_number, p_entry_date, v_period_id, p_source_module,
     p_source_document_type, p_source_document_id, p_narration, p_idempotency_key,
     p_reversal_of_id, p_reversal_reason, auth.uid())
  returning id into v_entry_id;

  v_index := 0;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_index := v_index + 1;
    insert into public.journal_entry_lines
      (journal_entry_id, dealer_id, line_number, account_id, branch_id,
       debit, credit, narration, party_type, party_id)
    values
      (v_entry_id, p_dealer_id, v_index, (v_line ->> 'account_id')::uuid, p_branch_id,
       coalesce((v_line ->> 'debit')::numeric, 0),
       coalesce((v_line ->> 'credit')::numeric, 0),
       v_line ->> 'narration',
       v_line ->> 'party_type',
       (v_line ->> 'party_id')::uuid);
  end loop;

  -- The trigger in 0007 recomputes totals from the lines and refuses to post
  -- anything unbalanced, so this is the second, independent check.
  update public.journal_entries set status = 'POSTED', posted_by = auth.uid()
   where id = v_entry_id;

  return v_entry_id;
end;
$$;

comment on function app.post_journal(uuid, uuid, date, text, text, jsonb, text, uuid, text, uuid, text) is
  'The single entry point to the ledger (spec §21, §60.18). Validates every line '
  '(leaf, active, own-dealer account; one-sided non-negative amount), refuses '
  'manual lines on cash/bank ledgers and dates on or before the lock date, then '
  'balances, numbers and posts atomically. Idempotent when given a key (spec §50).';

-- -----------------------------------------------------------------------------
-- account_balances() — nothing posted is ever left out
-- -----------------------------------------------------------------------------
-- Identical to 0012 except the account filter: an INACTIVE account keeps its
-- history (a trial balance as on last year must still show it), and a group
-- that carries lines — only possible before this migration — is shown rather
-- than silently dropped. Rows with no movement are filtered by each report.
create or replace function public.account_balances(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  account_id        uuid,
  account_code      text,
  account_name      text,
  account_type      text,
  normal_balance    text,
  period_debit      numeric(18, 4),
  period_credit     numeric(18, 4),
  closing_debit     numeric(18, 4),
  closing_credit    numeric(18, 4),
  period_movement   numeric(18, 4),
  closing_balance   numeric(18, 4)
)
language sql
stable
as $$
  select
    coa.id,
    coa.code,
    coa.name,
    coa.account_type,
    coa.normal_balance,

    coalesce(sum(l.debit)  filter (where je.entry_date between p_from and p_to), 0),
    coalesce(sum(l.credit) filter (where je.entry_date between p_from and p_to), 0),
    coalesce(sum(l.debit)  filter (where je.entry_date <= p_to), 0),
    coalesce(sum(l.credit) filter (where je.entry_date <= p_to), 0),

    case when coa.normal_balance = 'DEBIT'
      then coalesce(sum(l.debit)  filter (where je.entry_date between p_from and p_to), 0)
         - coalesce(sum(l.credit) filter (where je.entry_date between p_from and p_to), 0)
      else coalesce(sum(l.credit) filter (where je.entry_date between p_from and p_to), 0)
         - coalesce(sum(l.debit)  filter (where je.entry_date between p_from and p_to), 0)
    end,

    case when coa.normal_balance = 'DEBIT'
      then coalesce(sum(l.debit)  filter (where je.entry_date <= p_to), 0)
         - coalesce(sum(l.credit) filter (where je.entry_date <= p_to), 0)
      else coalesce(sum(l.credit) filter (where je.entry_date <= p_to), 0)
         - coalesce(sum(l.debit)  filter (where je.entry_date <= p_to), 0)
    end

  from public.chart_of_accounts coa
  left join public.journal_entry_lines l
    on l.account_id = coa.id
  left join public.journal_entries je
    on je.id = l.journal_entry_id
   and je.status in ('POSTED', 'REVERSED')
   and (p_branch_id is null or je.branch_id = p_branch_id)
  group by coa.id, coa.code, coa.name, coa.account_type, coa.normal_balance,
           coa.is_group, coa.status
  having (not coa.is_group and coa.status = 'ACTIVE') or count(je.id) > 0
  order by coa.code;
$$;

comment on function public.account_balances(date, date, uuid) is
  'Per-account debit/credit totals for a period and cumulatively to the end date. '
  'Every account with posted lines is included, active or not, so no report can '
  'omit posted money. SECURITY INVOKER: RLS scopes it to the caller''s dealer.';

-- -----------------------------------------------------------------------------
-- Chart-of-accounts guard: no change that strands posted lines
-- -----------------------------------------------------------------------------
create or replace function app.chart_of_accounts_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_used    boolean;
  v_balance numeric;
  v_parent  public.chart_of_accounts;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    select exists (select 1 from public.journal_entry_lines where account_id = old.id)
      into v_used;
  end if;

  if tg_op = 'DELETE' then
    if v_used then
      raise exception 'Account % % has posted lines and cannot be deleted. Deactivate it instead.',
        old.code, old.name using errcode = 'insufficient_privilege';
    end if;
    -- A heading with children is protected by coa_parent_tenant_fkey, checked at
    -- the end of the statement — which is what lets purge_dealer() remove a
    -- whole unused chart in one delete.
    return old;
  end if;

  -- The parent is a heading of the same kind, in the same chart.
  if new.parent_id is not null
     and (tg_op = 'INSERT' or new.parent_id is distinct from old.parent_id
          or new.account_type is distinct from old.account_type) then
    select * into v_parent from public.chart_of_accounts where id = new.parent_id;
    if v_parent.id is null or v_parent.dealer_id <> new.dealer_id then
      raise exception 'The parent account does not exist in this chart.'
        using errcode = 'foreign_key_violation';
    end if;
    if not v_parent.is_group then
      raise exception 'Account % % is not a heading, so nothing can sit beneath it.',
        v_parent.code, v_parent.name using errcode = 'check_violation';
    end if;
    if v_parent.account_type <> new.account_type then
      raise exception 'An % account cannot sit under the % heading %.',
        lower(new.account_type), lower(v_parent.account_type), v_parent.code
        using errcode = 'check_violation';
    end if;
  end if;

  if tg_op = 'INSERT' then
    return new;
  end if;

  if v_used then
    if new.account_type <> old.account_type or new.normal_balance <> old.normal_balance then
      raise exception 'Account % % has posted lines; its type cannot change. Open a new account and journal the balance across.',
        old.code, old.name using errcode = 'check_violation';
    end if;
    if new.is_group and not old.is_group then
      raise exception 'Account % % has posted lines and cannot become a heading.',
        old.code, old.name using errcode = 'check_violation';
    end if;
    if new.dealer_id <> old.dealer_id then
      raise exception 'An account cannot move between dealers.' using errcode = 'insufficient_privilege';
    end if;
  end if;

  if not new.is_group and old.is_group
     and exists (select 1 from public.chart_of_accounts where parent_id = old.id) then
    raise exception 'Heading % % has accounts beneath it and cannot become postable.',
      old.code, old.name using errcode = 'check_violation';
  end if;

  if new.status = 'INACTIVE' and old.status = 'ACTIVE' and v_used then
    select coalesce(sum(l.debit - l.credit), 0) into v_balance
      from public.journal_entry_lines l
      join public.journal_entries je on je.id = l.journal_entry_id
     where l.account_id = old.id and je.status in ('POSTED', 'REVERSED');
    if v_balance <> 0 then
      raise exception 'Account % % still carries a balance of %. Journal it to another account before deactivating.',
        old.code, old.name, abs(v_balance) using errcode = 'check_violation';
    end if;
  end if;

  if new.status = 'INACTIVE' and old.status = 'ACTIVE'
     and (exists (select 1 from public.cash_accounts where ledger_account_id = old.id and status = 'ACTIVE')
          or exists (select 1 from public.bank_accounts where ledger_account_id = old.id and status = 'ACTIVE')) then
    raise exception 'Account % % is the ledger behind an active cash or bank account.', old.code, old.name
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

create trigger chart_of_accounts_guard
  before insert or update or delete on public.chart_of_accounts
  for each row execute function app.chart_of_accounts_guard();

-- -----------------------------------------------------------------------------
-- public.create_account() / public.set_account_status() — spec §24
-- -----------------------------------------------------------------------------
create or replace function public.create_account(
  p_code      text,
  p_name      text,
  p_type      text,
  p_parent_id uuid default null,
  p_is_group  boolean default false,
  p_subtype   text default null
)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_id     uuid;
  v_code   text := upper(btrim(coalesce(p_code, '')));
begin
  if v_dealer is null or not app.has_permission('accounting.coa.manage') then
    raise exception 'You may not change the chart of accounts.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_code !~ '^[0-9A-Z][0-9A-Z._-]{0,29}$' then
    raise exception 'An account code is letters and digits, up to 30 characters.'
      using errcode = 'check_violation';
  end if;
  if coalesce(length(btrim(p_name)), 0) < 2 then
    raise exception 'Give the account a name.' using errcode = 'check_violation';
  end if;
  if p_type not in ('ASSET', 'LIABILITY', 'EQUITY', 'INCOME', 'EXPENSE') then
    raise exception 'Account type must be asset, liability, equity, income or expense.'
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.chart_of_accounts where dealer_id = v_dealer and code = v_code) then
    raise exception 'Account code % is already in use.', v_code using errcode = 'unique_violation';
  end if;

  insert into public.chart_of_accounts
    (dealer_id, code, name, account_type, account_subtype, normal_balance, is_group,
     parent_id, is_system, is_branch_scoped, created_by)
  values
    (v_dealer, v_code, btrim(p_name), p_type, nullif(btrim(p_subtype), ''),
     case when p_type in ('ASSET', 'EXPENSE') then 'DEBIT' else 'CREDIT' end,
     coalesce(p_is_group, false), p_parent_id, false,
     p_type in ('INCOME', 'EXPENSE'), auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.create_account(text, text, text, uuid, boolean, text) is
  'Adds an account to the caller''s chart (spec §24). The normal side follows '
  'from the type; the parent must be a heading of the same type.';

create or replace function public.set_account_status(p_account_id uuid, p_status text)
returns void
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
begin
  if v_dealer is null or not app.has_permission('accounting.coa.manage') then
    raise exception 'You may not change the chart of accounts.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_status not in ('ACTIVE', 'INACTIVE') then
    raise exception 'Status must be ACTIVE or INACTIVE.' using errcode = 'check_violation';
  end if;

  update public.chart_of_accounts
     set status = p_status, updated_by = auth.uid()
   where id = p_account_id and dealer_id = v_dealer;

  if not found then
    raise exception 'Account not found.' using errcode = 'no_data_found';
  end if;
end;
$$;

comment on function public.set_account_status(uuid, text) is
  'Activates or deactivates an account. The guard refuses deactivating one that '
  'still carries a balance or backs a cash/bank account.';

-- -----------------------------------------------------------------------------
-- Standard accounts every dealer needs, and cost-of-sales marking
-- -----------------------------------------------------------------------------
create or replace function app.seed_standard_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
declare
  v_added integer := 0;
  a       record;
begin
  for a in
    select * from (values
      (1, '1950', 'Fixed Assets',                     'ASSET',     true,  '1000'),
      (2, '1951', 'Furniture, Fixtures & Computers',  'ASSET',     false, '1950'),
      (3, '1959', 'Accumulated Depreciation',         'ASSET',     false, '1950'),
      (4, '2800', 'Loans',                            'LIABILITY', false, '2000'),
      (5, '3400', 'Drawings',                         'EQUITY',    false, '3000'),
      (6, '5950', 'Depreciation',                     'EXPENSE',   false, '5000'),
      (7, '5960', 'Interest Expense',                 'EXPENSE',   false, '5000'),
      -- Count differences, both ways: a shortage debits it, an excess credits it
      -- (0079 posts stock adjustments here).
      (8, '5970', 'Stock Adjustments',                'EXPENSE',   false, '5000')
    ) as t(ord, code, name, account_type, is_group, parent_code)
    order by ord
  loop
    insert into public.chart_of_accounts
      (dealer_id, code, name, account_type, normal_balance, is_group, parent_id,
       is_system, is_branch_scoped)
    select p_dealer_id, a.code, a.name, a.account_type,
           case when a.account_type in ('ASSET', 'EXPENSE') then 'DEBIT' else 'CREDIT' end,
           a.is_group, p.id, true, false
      from public.chart_of_accounts p
     where p.dealer_id = p_dealer_id and p.code = a.parent_code and p.is_group
    on conflict on constraint coa_dealer_code_key do nothing;

    if found then v_added := v_added + 1; end if;
  end loop;

  update public.chart_of_accounts
     set account_subtype = 'COST_OF_SALES'
   where dealer_id = p_dealer_id
     and code in ('5100', '5200', '5300', '5400')
     and account_subtype is distinct from 'COST_OF_SALES';

  return v_added;
end;
$$;

comment on function app.seed_standard_accounts(uuid) is
  'Fixed assets, accumulated depreciation, loans, drawings, depreciation, '
  'interest and stock adjustments; marks COGS accounts COST_OF_SALES. Idempotent; never touches an '
  'account a dealer already has under the same code.';

do $$
declare d record;
begin
  for d in select id from public.dealers loop
    perform app.seed_standard_accounts(d.id);
  end loop;
end $$;

-- New dealers get them through provisioning, which calls seed_chart_of_accounts.
alter function app.seed_chart_of_accounts(uuid) rename to seed_chart_of_accounts_0066;

create or replace function app.seed_chart_of_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
begin
  return app.seed_chart_of_accounts_0066(p_dealer_id) + app.seed_standard_accounts(p_dealer_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- profit_and_loss() — cost of sales as its own section
-- -----------------------------------------------------------------------------
create or replace function public.profit_and_loss(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  section      text,
  account_code text,
  account_name text,
  amount       numeric(18, 4)
)
language sql
stable
as $$
  select case
           when b.account_type = 'INCOME' then 'INCOME'
           when c.account_subtype = 'COST_OF_SALES' then 'COST_OF_SALES'
           else 'EXPENSE'
         end,
         b.account_code, b.account_name, b.period_movement
    from public.account_balances(p_from, p_to, p_branch_id) b
    join public.chart_of_accounts c on c.id = b.account_id
   where b.account_type in ('INCOME', 'EXPENSE')
     and b.period_movement <> 0
   order by case when b.account_type = 'INCOME' then 1
                 when c.account_subtype = 'COST_OF_SALES' then 2 else 3 end,
            b.account_code;
$$;

comment on function public.profit_and_loss(date, date, uuid) is
  'Income, cost of sales and other expenses for a period (spec §41). Income less '
  'cost of sales is gross profit; less the rest is the net result.';

-- -----------------------------------------------------------------------------
-- post_manual_journal() — no future dates
-- -----------------------------------------------------------------------------
-- Unchanged from 0069 apart from the date check. The cash/bank rule and the
-- account checks now live in post_journal, where every caller meets them.
create or replace function public.post_manual_journal(
  p_entry_date      date,
  p_narration       text,
  p_lines           jsonb,
  p_branch_id       uuid default null,
  p_idempotency_key text default null
)
returns table (journal_entry_id uuid, entry_number text)
language plpgsql
as $$
declare
  v_dealer uuid;
  v_branch uuid;
  v_entry  uuid;
begin
  v_dealer := app.current_dealer_id();
  if v_dealer is null then
    raise exception 'Only a dealer user can post a journal entry.'
      using errcode = 'insufficient_privilege';
  end if;

  if coalesce(btrim(p_narration), '') = '' then
    raise exception 'A journal entry must say what it is for.'
      using errcode = 'check_violation',
            hint = 'The narration is what makes the entry readable a year later.';
  end if;

  if p_entry_date is null then
    raise exception 'A journal entry needs a date.' using errcode = 'check_violation';
  end if;
  if p_entry_date > current_date then
    raise exception 'A journal entry cannot be dated in the future (%).', to_char(p_entry_date, 'DD-MM-YYYY')
      using errcode = 'check_violation',
            hint = 'Post it on the day it happens.';
  end if;

  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    raise exception 'A journal entry needs at least two lines.'
      using errcode = 'check_violation';
  end if;

  v_branch := coalesce(p_branch_id, (select id from public.branches
                                      where dealer_id = v_dealer order by code limit 1));

  if not exists (select 1 from public.branches where id = v_branch and dealer_id = v_dealer) then
    raise exception 'That branch does not belong to this dealer.'
      using errcode = 'insufficient_privilege';
  end if;

  v_entry := app.post_journal(
    v_dealer, v_branch, p_entry_date, 'MANUAL', btrim(p_narration), p_lines,
    'MANUAL_JOURNAL', null,
    case when p_idempotency_key is null then null else 'manual:' || p_idempotency_key end
  );

  journal_entry_id := v_entry;
  select je.entry_number into entry_number from public.journal_entries je where je.id = v_entry;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------
revoke execute on function app.journal_account(uuid, uuid) from public;
revoke execute on function app.is_money_ledger(uuid, uuid) from public;
revoke execute on function app.books_locked_through(uuid) from public;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  execute 'grant execute on function app.journal_account(uuid, uuid) to authenticated';
  execute 'grant execute on function app.is_money_ledger(uuid, uuid) to authenticated';
  execute 'grant execute on function app.books_locked_through(uuid) to authenticated';
  execute 'grant execute on function public.set_books_lock(date, text) to authenticated';
  execute 'grant execute on function public.create_account(text, text, text, uuid, boolean, text) to authenticated';
  execute 'grant execute on function public.set_account_status(uuid, text) to authenticated';
  execute 'grant execute on function public.post_manual_journal(date, text, jsonb, uuid, text) to authenticated';
end $$;

-- -----------------------------------------------------------------------------
-- What this migration found already on file
-- -----------------------------------------------------------------------------
-- Lines posted before this migration to a group or an inactive account, or by
-- hand to cash/bank, are not undone (posted journals are immutable). They now
-- show in the reports; this names them so they can be corrected by reversal.
do $$
declare
  v_group  integer;
  v_manual integer;
begin
  select count(*) into v_group
    from public.journal_entry_lines l
    join public.chart_of_accounts c on c.id = l.account_id
   where c.is_group;

  select count(*) into v_manual
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where je.source_document_type = 'MANUAL_JOURNAL'
     and je.status = 'POSTED'
     and app.is_money_ledger(l.dealer_id, l.account_id);

  if v_group > 0 then
    raise notice '0076: % journal line(s) sit on group accounts. They now appear in the trial balance; reverse and repost them.', v_group;
  end if;
  if v_manual > 0 then
    raise notice '0076: % manual journal line(s) moved cash/bank without a book row. Check the tie-out report.', v_manual;
  end if;
end $$;

insert into public.schema_migrations (version, name)
values ('0076', 'ledger_integrity') on conflict (version) do nothing;
