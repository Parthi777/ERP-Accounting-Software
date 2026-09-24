-- =============================================================================
-- INCREMENTAL 0076 → 0079
-- =============================================================================
-- GENERATED FILE. Regenerate with:
--   FROM=0076 bash scripts/build-incremental.sh
--
-- For a database that ALREADY has migrations up to 0075.
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
-- SOURCE: supabase/migrations/0076_ledger_integrity.sql
-- ═══════════════════════════════════════════════════════════════════════════

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


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0077_contra_and_reconciliation.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0077 — Contra vouchers, a real bank reconciliation statement, and a tie-out
-- =============================================================================
-- Spec §36, §37, §38, §39, §41, §43, §50, §60.14.
--
-- ── Contra ──────────────────────────────────────────────────────────────────
--
-- 0076 stopped cash and bank from being written by hand, because a journal line
-- on 1100/1200 moves the ledger and not the book. That leaves one ordinary
-- transaction with nowhere to go: money moving between two of the dealer's own
-- accounts — the day's takings deposited, cash drawn for petty expenses, a sweep
-- from one bank to another. It is neither a receipt nor a payment; it is both at
-- once, and it must move both books. public.record_contra() writes the one
-- journal and the two book rows in one transaction.
--
-- ── The BRS, with its reconciling items ────────────────────────────────────
--
-- complete_bank_reconciliation() stored statement − book and nothing else. A
-- non-zero figure there is normal — cheques issued and not yet presented,
-- deposits in transit, charges the bank took that the books have not heard of —
-- and the product gave no way to see which. A reconciliation that cannot say
-- why the two balances differ is a subtraction, not a reconciliation.
--
-- bank_reconciliation_statement() is the textbook layout:
--
--     balance as per books
--   + credits in the bank not yet in the books      (direct deposits, interest)
--   − debits in the bank not yet in the books       (charges)
--   = adjusted book balance
--   + cheques issued, not yet presented
--   − deposits made, not yet credited
--   = balance expected on the statement
--     against the statement's actual closing → unexplained difference
--
-- "As on" is honoured: a book entry is cleared at the date only if the
-- statement line it was matched to is dated on or before it, and a statement
-- line counts as bank-only if it is unmatched or matched to a book entry dated
-- after it. The same reconciliation re-run for an earlier date tells the truth
-- about that date.
--
-- ── The tie-out ────────────────────────────────────────────────────────────
--
-- Every sub-ledger here is derived or maintained beside the general ledger:
-- party ledgers from party-tagged lines, the cash and bank books from their own
-- tables, stock from movements. Nothing compared them. control_account_tieout()
-- does, so a difference is found by a report rather than by an auditor.
--
-- Rollback: drop functions public.record_contra, public.bank_reconciliation_statement,
--           public.bank_reconciliation_items, public.control_account_tieout;
--           restore public.complete_bank_reconciliation from 0031;
--           alter table public.bank_reconciliations drop the columns added here.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.record_contra()
-- -----------------------------------------------------------------------------
-- p_from_kind / p_to_kind are 'CASH' (the id is a branch — each branch has one
-- cash account) or 'BANK' (the id is a bank account).
create or replace function public.record_contra(
  p_from_kind       text,
  p_from_id         uuid,
  p_to_kind         text,
  p_to_id           uuid,
  p_amount          numeric,
  p_date            date default current_date,
  p_reference       text default null,
  p_narration       text default null,
  p_idempotency_key text default null
)
returns table (journal_entry_id uuid, entry_number text)
language plpgsql
as $$
declare
  v_dealer     uuid := app.current_dealer_id();
  v_from_cash  public.cash_accounts;
  v_to_cash    public.cash_accounts;
  v_from_bank  public.bank_accounts;
  v_to_bank    public.bank_accounts;
  v_from_led   uuid;
  v_to_led     uuid;
  v_from_name  text;
  v_to_name    text;
  v_branch     uuid;
  v_entry      uuid;
  v_text       text;
  v_key        text;
begin
  if v_dealer is null then
    raise exception 'Only a dealer user can record a contra.' using errcode = 'insufficient_privilege';
  end if;
  if not app.has_permission('bank.book.record') then
    raise exception 'You may not record bank entries.' using errcode = 'insufficient_privilege';
  end if;
  if p_from_kind not in ('CASH', 'BANK') or p_to_kind not in ('CASH', 'BANK') then
    raise exception 'Each side of a contra is CASH or BANK.' using errcode = 'check_violation';
  end if;
  if p_from_kind = 'CASH' and p_to_kind = 'CASH' then
    raise exception 'Cash moving between branches is a branch transfer, not a contra.'
      using errcode = 'check_violation';
  end if;
  if p_from_id = p_to_id then
    raise exception 'The money has to go somewhere else.' using errcode = 'check_violation';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'The amount must be greater than zero.' using errcode = 'check_violation';
  end if;

  -- ── Replay (spec §50) ────────────────────────────────────────────────────
  v_key := case when p_idempotency_key is null then null else 'contra:' || p_idempotency_key end;
  if v_key is not null then
    select je.id, je.entry_number into v_entry, v_text
      from public.journal_entries je
     where je.dealer_id = v_dealer and je.idempotency_key = v_key;
    if v_entry is not null then
      journal_entry_id := v_entry; entry_number := v_text;
      return next;
      return;
    end if;
  end if;

  -- ── Resolve both sides, inside this dealer ──────────────────────────────
  if p_from_kind = 'CASH' then
    select * into v_from_cash from public.cash_accounts
     where branch_id = p_from_id and dealer_id = v_dealer and status = 'ACTIVE';
    if v_from_cash.id is null then
      raise exception 'That branch has no active cash account.' using errcode = 'no_data_found';
    end if;
    v_from_led := v_from_cash.ledger_account_id; v_from_name := v_from_cash.name;
    v_branch := v_from_cash.branch_id;
  else
    select * into v_from_bank from public.bank_accounts
     where id = p_from_id and dealer_id = v_dealer and status = 'ACTIVE' for update;
    if v_from_bank.id is null then
      raise exception 'The bank account money is leaving is not an active account of yours.'
        using errcode = 'no_data_found';
    end if;
    v_from_led := v_from_bank.ledger_account_id; v_from_name := v_from_bank.name;
  end if;

  if p_to_kind = 'CASH' then
    select * into v_to_cash from public.cash_accounts
     where branch_id = p_to_id and dealer_id = v_dealer and status = 'ACTIVE';
    if v_to_cash.id is null then
      raise exception 'That branch has no active cash account.' using errcode = 'no_data_found';
    end if;
    v_to_led := v_to_cash.ledger_account_id; v_to_name := v_to_cash.name;
    v_branch := v_to_cash.branch_id;
  else
    select * into v_to_bank from public.bank_accounts
     where id = p_to_id and dealer_id = v_dealer and status = 'ACTIVE' for update;
    if v_to_bank.id is null then
      raise exception 'The bank account money is going to is not an active account of yours.'
        using errcode = 'no_data_found';
    end if;
    v_to_led := v_to_bank.ledger_account_id; v_to_name := v_to_bank.name;
  end if;

  -- The journal belongs to the branch whose cash moved; bank to bank sits with
  -- the paying account's branch, else the dealer's first branch.
  v_branch := coalesce(v_branch, v_from_bank.branch_id, v_to_bank.branch_id,
                       (select id from public.branches where dealer_id = v_dealer order by code limit 1));

  -- Cash side needs an open day (spec §36) — refuse before posting anything.
  if v_from_cash.id is not null then
    perform public.ensure_cash_day(v_from_cash.branch_id, p_date);
  end if;
  if v_to_cash.id is not null then
    perform public.ensure_cash_day(v_to_cash.branch_id, p_date);
  end if;

  v_text := coalesce(nullif(btrim(p_narration), ''), 'Contra: ' || v_from_name || ' to ' || v_to_name);

  -- 1100 and 1200 are shared control accounts, so bank-to-bank posts the same
  -- account on both sides. That is still two lines — the journal records that
  -- money moved even though the control total did not — and both books move.
  v_entry := app.post_journal(
    v_dealer, v_branch, p_date, 'BANK', v_text,
    jsonb_build_array(
      jsonb_build_object('account_id', v_to_led,   'debit', p_amount, 'credit', 0, 'narration', 'To ' || v_to_name),
      jsonb_build_object('account_id', v_from_led, 'debit', 0, 'credit', p_amount, 'narration', 'From ' || v_from_name)
    ),
    'CONTRA', null, v_key);

  -- ── Both books ──────────────────────────────────────────────────────────
  if v_from_cash.id is not null then
    insert into public.cash_transactions
      (dealer_id, branch_id, cash_account_id, business_date, direction, amount,
       particular, reference_type, reference_number, journal_entry_id, created_by)
    values
      (v_dealer, v_from_cash.branch_id, v_from_cash.id, p_date, 'PAYMENT', p_amount,
       v_text, 'CONTRA', p_reference, v_entry, auth.uid());
  else
    insert into public.bank_transactions
      (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
       reference_type, reference_number, journal_entry_id, created_by)
    values
      (v_dealer, v_from_bank.id, p_date, 'PAYMENT', p_amount, v_text,
       'CONTRA', p_reference, v_entry, auth.uid());
  end if;

  if v_to_cash.id is not null then
    insert into public.cash_transactions
      (dealer_id, branch_id, cash_account_id, business_date, direction, amount,
       particular, reference_type, reference_number, journal_entry_id, created_by)
    values
      (v_dealer, v_to_cash.branch_id, v_to_cash.id, p_date, 'RECEIPT', p_amount,
       v_text, 'CONTRA', p_reference, v_entry, auth.uid());
  else
    insert into public.bank_transactions
      (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
       reference_type, reference_number, journal_entry_id, created_by)
    values
      (v_dealer, v_to_bank.id, p_date, 'RECEIPT', p_amount, v_text,
       'CONTRA', p_reference, v_entry, auth.uid());
  end if;

  journal_entry_id := v_entry;
  select je.entry_number into entry_number from public.journal_entries je where je.id = v_entry;
  return next;
end;
$$;

comment on function public.record_contra(text, uuid, text, uuid, numeric, date, text, text, text) is
  'Cash to bank, bank to cash, or bank to bank: one journal and a row in each '
  'book, in one transaction (spec §36, §38). Idempotent on the key (spec §50).';

-- -----------------------------------------------------------------------------
-- Reconciling items as on a date
-- -----------------------------------------------------------------------------
create or replace function public.bank_reconciliation_items(
  p_bank_account_id uuid,
  p_as_on           date
)
returns table (
  kind        text,     -- BANK_CREDIT | BANK_DEBIT | UNPRESENTED | IN_TRANSIT
  item_date   date,
  particular  text,
  reference   text,
  amount      numeric(18, 4),
  source      text,     -- STATEMENT | BOOK
  source_id   bigint,
  match_status text
)
language sql
stable
as $$
  -- In the bank, not (yet) in the books as at the date. IGNORED lines are left
  -- out: ignoring is the operator's explicit statement that the line is not a
  -- movement the books need (a bank's own opening-balance row, a duplicate),
  -- and ignore_bank_line() records who said so.
  select case when l.credit > 0 then 'BANK_CREDIT' else 'BANK_DEBIT' end,
         l.statement_date, l.narration,
         coalesce(l.utr, l.reference, l.cheque_number),
         greatest(l.credit, l.debit), 'STATEMENT', l.id, l.match_status
    from public.bank_statement_lines l
    left join public.bank_transactions t on t.id = l.matched_transaction_id
   where l.bank_account_id = p_bank_account_id
     and l.statement_date <= p_as_on
     and (l.match_status in ('UNMATCHED', 'PARTIAL')
          or (l.match_status = 'MATCHED' and t.transaction_date > p_as_on))

  union all

  -- In the books, not (yet) through the bank as at the date.
  select case when t.direction = 'PAYMENT' then 'UNPRESENTED' else 'IN_TRANSIT' end,
         t.transaction_date, t.particular,
         coalesce(t.instrument_number, t.utr, t.reference_number),
         t.amount, 'BOOK', t.id, null
    from public.bank_transactions t
   where t.bank_account_id = p_bank_account_id
     and t.status = 'ACTIVE'
     and t.transaction_date <= p_as_on
     and not exists (
       select 1 from public.bank_statement_lines l
        where l.matched_transaction_id = t.id
          and l.match_status = 'MATCHED'
          and l.statement_date <= p_as_on)
  order by 1, 2;
$$;

comment on function public.bank_reconciliation_items(uuid, date) is
  'Every item explaining why book and statement differ on a date (spec §39): '
  'bank-only credits and debits, unpresented payments, deposits in transit.';

create or replace function public.bank_reconciliation_statement(
  p_bank_account_id   uuid,
  p_as_on             date,
  p_statement_closing numeric default null
)
returns table (
  book_balance               numeric(18, 4),
  bank_only_credits          numeric(18, 4),
  bank_only_debits           numeric(18, 4),
  adjusted_book_balance      numeric(18, 4),
  unpresented_payments       numeric(18, 4),
  deposits_in_transit        numeric(18, 4),
  expected_statement_balance numeric(18, 4),
  statement_closing_balance  numeric(18, 4),
  unexplained_difference     numeric(18, 4)
)
language sql
stable
as $$
  with book as (
    select a.opening_balance + coalesce(sum(
             case when t.direction = 'RECEIPT' then t.amount else -t.amount end), 0) as bal
      from public.bank_accounts a
      left join public.bank_transactions t
        on t.bank_account_id = a.id and t.status = 'ACTIVE' and t.transaction_date <= p_as_on
     where a.id = p_bank_account_id
     group by a.opening_balance
  ),
  items as (
    select coalesce(sum(amount) filter (where kind = 'BANK_CREDIT'), 0) as bc,
           coalesce(sum(amount) filter (where kind = 'BANK_DEBIT'), 0)  as bd,
           coalesce(sum(amount) filter (where kind = 'UNPRESENTED'), 0) as up,
           coalesce(sum(amount) filter (where kind = 'IN_TRANSIT'), 0)  as it
      from public.bank_reconciliation_items(p_bank_account_id, p_as_on)
  )
  select book.bal, items.bc, items.bd,
         book.bal + items.bc - items.bd,
         items.up, items.it,
         book.bal + items.bc - items.bd + items.up - items.it,
         p_statement_closing,
         case when p_statement_closing is null then null
              else p_statement_closing - (book.bal + items.bc - items.bd + items.up - items.it) end
    from book, items;
$$;

comment on function public.bank_reconciliation_statement(uuid, date, numeric) is
  'Bank reconciliation statement (spec §39): book balance, adjusted for bank-only '
  'items, then for timing differences, against the statement. A non-zero '
  'unexplained difference is the only figure that needs investigating.';

-- -----------------------------------------------------------------------------
-- Completed reconciliations keep the statement they were completed on
-- -----------------------------------------------------------------------------
alter table public.bank_reconciliations
  add column if not exists bank_only_credits          numeric(18, 4),
  add column if not exists bank_only_debits           numeric(18, 4),
  add column if not exists adjusted_book_balance      numeric(18, 4),
  add column if not exists unpresented_payments       numeric(18, 4),
  add column if not exists deposits_in_transit        numeric(18, 4),
  add column if not exists expected_statement_balance numeric(18, 4),
  add column if not exists unexplained_difference     numeric(18, 4);

comment on column public.bank_reconciliations.difference is
  'Statement minus book, before reconciling items. See unexplained_difference.';

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
  v_matched   integer;
  v_unmatched integer;
  v_brs       record;
begin
  select * into v_bank from public.bank_accounts where id = p_bank_account_id;
  if v_bank.id is null then
    raise exception 'Bank account not found.' using errcode = 'no_data_found';
  end if;

  select count(*) filter (where l.match_status = 'MATCHED'),
         count(*) filter (where l.match_status = 'UNMATCHED')
    into v_matched, v_unmatched
    from public.bank_statement_lines l
   where l.bank_account_id = p_bank_account_id
     and l.statement_date between p_from_date and p_to_date
     and l.reconciliation_id is null;

  select * into v_brs
    from public.bank_reconciliation_statement(p_bank_account_id, p_to_date, p_statement_closing);

  v_number := app.next_document_number(
    v_bank.dealer_id, null, 'BANK_RECONCILIATION',
    app.financial_year_token(v_bank.dealer_id, p_to_date));

  insert into public.bank_reconciliations
    (dealer_id, bank_account_id, reconciliation_number, from_date, to_date,
     statement_closing_balance, book_closing_balance, matched_count, unmatched_count,
     bank_only_credits, bank_only_debits, adjusted_book_balance,
     unpresented_payments, deposits_in_transit, expected_statement_balance,
     unexplained_difference,
     status, completed_at, completed_by, notes, created_by)
  values
    (v_bank.dealer_id, p_bank_account_id, v_number, p_from_date, p_to_date,
     p_statement_closing, v_brs.book_balance, v_matched, v_unmatched,
     v_brs.bank_only_credits, v_brs.bank_only_debits, v_brs.adjusted_book_balance,
     v_brs.unpresented_payments, v_brs.deposits_in_transit, v_brs.expected_statement_balance,
     v_brs.unexplained_difference,
     'COMPLETED', now(), auth.uid(), p_notes, auth.uid())
  returning id into v_recon;

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
  -- The difference reported back is the one that needs explaining: what is
  -- left once every timing and bank-only item has been accounted for.
  difference        := v_brs.unexplained_difference;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.control_account_tieout() — every control account against its detail
-- -----------------------------------------------------------------------------
create or replace function public.control_account_tieout(p_as_on date default current_date)
returns table (
  control          text,     -- PARTY | CASH | BANK | VEHICLE_STOCK | ACCESSORY_STOCK | SPARE_STOCK
  account_code     text,
  account_name     text,
  ledger_balance   numeric(18, 4),
  subledger_balance numeric(18, 4),
  difference       numeric(18, 4),
  explanation      text
)
language sql
stable
as $$
  with gl as (
    select l.account_id,
           sum(l.debit - l.credit) as bal,
           sum(l.debit - l.credit) filter (where l.party_id is not null) as tagged,
           count(*) filter (where l.party_id is null) as untagged_lines
      from public.journal_entry_lines l
      join public.journal_entries je on je.id = l.journal_entry_id
     where je.status in ('POSTED', 'REVERSED')
       and je.entry_date <= p_as_on
     group by l.account_id
  ),
  coa as (
    select c.id, c.code, c.name, c.normal_balance, c.account_type, c.dealer_id
      from public.chart_of_accounts c
  ),
  -- Party control accounts: receivables, payables, advances and finance-company
  -- balances — balance-sheet accounts a party line has touched, plus the two
  -- that should only ever be touched that way. A bank line or a commission
  -- income line may carry a party for reference; those are not controls, and
  -- listing them would report a "difference" that is nothing of the kind.
  party as (
    select 'PARTY'::text, coa.code, coa.name,
           coalesce(gl.bal, 0), coalesce(gl.tagged, 0),
           coalesce(gl.bal, 0) - coalesce(gl.tagged, 0),
           case when coalesce(gl.bal, 0) = coalesce(gl.tagged, 0) then null
                else gl.untagged_lines || ' line(s) on this account carry no customer, supplier or finance company' end
      from coa
      left join gl on gl.account_id = coa.id
     where coa.code in ('1300', '2200')
        or (coalesce(gl.tagged, 0) <> 0
            and coa.account_type in ('ASSET', 'LIABILITY')
            and not app.is_money_ledger(coa.dealer_id, coa.id))
  ),
  cash_book as (
    select ca.ledger_account_id,
           sum(ca.opening_balance + coalesce((
             select sum(case when t.direction = 'RECEIPT' then t.amount else -t.amount end)
               from public.cash_transactions t
              where t.cash_account_id = ca.id and t.status = 'ACTIVE'
                and t.business_date <= p_as_on), 0)) as bal
      from public.cash_accounts ca
     group by ca.ledger_account_id
  ),
  bank_book as (
    select ba.ledger_account_id,
           sum(ba.opening_balance + coalesce((
             select sum(case when t.direction = 'RECEIPT' then t.amount else -t.amount end)
               from public.bank_transactions t
              where t.bank_account_id = ba.id and t.status = 'ACTIVE'
                and t.transaction_date <= p_as_on), 0)) as bal
      from public.bank_accounts ba
     group by ba.ledger_account_id
  ),
  money as (
    select 'CASH'::text, coa.code, coa.name, coalesce(gl.bal, 0), cb.bal,
           coalesce(gl.bal, 0) - cb.bal,
           case when coalesce(gl.bal, 0) = cb.bal then null
                else 'Cash-ledger lines with no cash-book row, or a cash book opening balance never journalled' end
      from cash_book cb join coa on coa.id = cb.ledger_account_id
      left join gl on gl.account_id = cb.ledger_account_id
    union all
    select 'BANK'::text, coa.code, coa.name, coalesce(gl.bal, 0), bb.bal,
           coalesce(gl.bal, 0) - bb.bal,
           case when coalesce(gl.bal, 0) = bb.bal then null
                else 'Bank-ledger lines with no bank-book row (e.g. a receipt taken before any bank account existed)' end
      from bank_book bb join coa on coa.id = bb.ledger_account_id
      left join gl on gl.account_id = bb.ledger_account_id
  ),
  -- Stock is valued as it stands now; a stock tie-out for a past date would
  -- need the movement history replayed, and is only offered for today.
  stock as (
    select 'VEHICLE_STOCK'::text as control, '1500'::text as code,
           coalesce(sum(v.purchase_cost), 0) as val
      from public.vehicles v
     where v.status in ('IN_STOCK', 'BOOKED', 'TRANSFERRED')
    union all
    select case i.item_type when 'ACCESSORY' then 'ACCESSORY_STOCK' else 'SPARE_STOCK' end,
           case i.item_type when 'ACCESSORY' then '1600' else '1700' end,
           coalesce(sum(s.stock_value), 0)
      from public.inventory_stock s
      join public.inventory_items i on i.id = s.item_id
     group by i.item_type
  ),
  stock_rows as (
    select st.control, coa.code, coa.name, coalesce(gl.bal, 0), sum(st.val),
           coalesce(gl.bal, 0) - sum(st.val),
           case when coalesce(gl.bal, 0) = sum(st.val) then null
                else 'Stock at cost that never reached the ledger (uploaded without a purchase bill or opening entry), or the reverse' end
      from stock st
      join coa on coa.code = st.code
      left join gl on gl.account_id = coa.id
     where p_as_on >= current_date
     group by st.control, coa.code, coa.name, gl.bal
  )
  select * from party
  union all select * from money
  union all select * from stock_rows
  order by 1, 2;
$$;

comment on function public.control_account_tieout(date) is
  'Each control account against its sub-ledger (spec §41, §43): party-tagged '
  'lines, cash book, bank book, and stock at cost. Debit-positive amounts. '
  'SECURITY INVOKER: RLS scopes it to the caller''s dealer.';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  execute 'grant execute on function public.record_contra(text, uuid, text, uuid, numeric, date, text, text, text) to authenticated';
  execute 'grant execute on function public.bank_reconciliation_items(uuid, date) to authenticated';
  execute 'grant execute on function public.bank_reconciliation_statement(uuid, date, numeric) to authenticated';
  execute 'grant execute on function public.complete_bank_reconciliation(uuid, date, date, numeric, text) to authenticated';
  execute 'grant execute on function public.control_account_tieout(date) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0077', 'contra_and_reconciliation') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0078_expense_purchase_lines.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0078 — Expenses and fixed assets on a purchase bill
-- =============================================================================
-- Spec §16, §21, §22, §24, §40, §41, §48.
--
-- A purchase bill could only carry stock: a VEHICLE, an ACCESSORY or a SPARE.
-- Everything else a dealer buys on a GST invoice — the showroom rent, the
-- electricity, a computer, a signboard, the auditor's fee — had no document.
-- It could be typed in as a manual journal, which put the cost somewhere but
-- lost the supplier bill, and its input GST never reached gst_input_summary():
-- that reads purchase bills, so the ITC on every overhead was invisible at
-- filing time and the liability overstated by exactly that much.
--
-- An EXPENSE line names the account it is charged to — an expense, or a fixed
-- asset when the thing bought is capital — and otherwise behaves like any other
-- line: taxable value, GST computed server-side, payable to the supplier.
--
-- ITC eligibility. Not every input tax can be claimed (blocked credits under
-- s.17(5) — food, personal use, motor vehicles for own use, and so on). A line
-- marked itc_eligible = false charges its GST into its own account instead of
-- to Input CGST/SGST/IGST, and is left out of the input-tax summary. This is the
-- line-level switch the return needs; which purchases are blocked remains the
-- accountant's judgement, as it has to be.
--
-- Stock never arrives this way: an EXPENSE line may not name an inventory, input
-- tax or payable account — those have their own lines and rules — nor a cash or
-- bank ledger.
--
-- Rollback: delete EXPENSE lines (none posted), restore the constraints and
--           public.post_purchase_bill from 0052, public.gst_input_summary from
--           0058 and public.returnable_purchase_lines from 0057; drop the columns
--           and trigger added here.
-- =============================================================================

alter table public.purchase_bill_lines
  add column if not exists account_id   uuid,
  add column if not exists hsn_sac      text,
  add column if not exists itc_eligible boolean not null default true;

alter table public.purchase_bill_lines
  add constraint pbl_account_tenant_fkey
    foreign key (account_id, dealer_id) references public.chart_of_accounts (id, dealer_id);

alter table public.purchase_bill_lines drop constraint pbl_type_check;
alter table public.purchase_bill_lines
  add constraint pbl_type_check check (line_type in ('VEHICLE', 'ACCESSORY', 'SPARE', 'EXPENSE'));

alter table public.purchase_bill_lines drop constraint pbl_shape_check;
alter table public.purchase_bill_lines
  add constraint pbl_shape_check check (
    (line_type = 'VEHICLE'
       and vehicle_id is not null and item_id is null and source is null
       and account_id is null and quantity = 1)
    or (line_type in ('ACCESSORY', 'SPARE')
       and item_id is not null and vehicle_id is null and source is not null
       and account_id is null and quantity > 0)
    or (line_type = 'EXPENSE'
       and account_id is not null and item_id is null and vehicle_id is null
       and source is null and quantity > 0)
  );

-- Blocked credit is an expense-line concept: stock carries its input tax, and
-- folding blocked GST into a stock lot's cost is a costing change of its own.
alter table public.purchase_bill_lines
  add constraint pbl_itc_scope_check check (itc_eligible or line_type = 'EXPENSE');

alter table public.purchase_bill_lines
  add constraint pbl_hsn_sac_shape_check check (hsn_sac is null or hsn_sac ~ '^[0-9]{4,8}$');

create index if not exists purchase_bill_lines_account_idx
  on public.purchase_bill_lines (account_id) where account_id is not null;

-- -----------------------------------------------------------------------------
-- Which accounts an EXPENSE line may be charged to
-- -----------------------------------------------------------------------------
create or replace function app.purchase_bill_lines_account_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_acc public.chart_of_accounts;
begin
  if new.line_type <> 'EXPENSE' then
    return new;
  end if;

  select * into v_acc from public.chart_of_accounts
   where id = new.account_id and dealer_id = new.dealer_id;

  if v_acc.id is null then
    raise exception 'The account on this line is not in your chart of accounts.'
      using errcode = 'foreign_key_violation';
  end if;
  if v_acc.is_group or v_acc.status <> 'ACTIVE' then
    raise exception 'Account % % cannot be charged: it is a heading or inactive.', v_acc.code, v_acc.name
      using errcode = 'check_violation';
  end if;
  if v_acc.account_type not in ('EXPENSE', 'ASSET') then
    raise exception 'A purchase is charged to an expense or an asset; % % is %.',
      v_acc.code, v_acc.name, lower(v_acc.account_type)
      using errcode = 'check_violation';
  end if;
  if app.is_money_ledger(new.dealer_id, new.account_id) then
    raise exception 'Account % % is cash or bank, not something bought.', v_acc.code, v_acc.name
      using errcode = 'check_violation';
  end if;
  -- Inventory, input tax and the payable each have their own path onto a bill.
  if exists (select 1 from public.accounting_rules r
              where r.dealer_id = new.dealer_id and r.account_id = new.account_id
                and r.module = 'INVENTORY' and r.event = 'PURCHASE'
                and r.status = 'ACTIVE') then
    raise exception 'Account % % is posted by stock lines and tax, not charged directly. Use a vehicle, accessory or spare line.',
      v_acc.code, v_acc.name using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

create trigger purchase_bill_lines_account_guard
  before insert or update on public.purchase_bill_lines
  for each row execute function app.purchase_bill_lines_account_guard();

-- -----------------------------------------------------------------------------
-- public.post_purchase_bill() — EXPENSE lines, and blocked ITC
-- -----------------------------------------------------------------------------
-- As 0052, with two changes: an EXPENSE line debits its own account (plus its
-- GST when the credit is blocked) and moves no stock; and the input-tax debits
-- are summed from the eligible lines rather than read off the header.
create or replace function public.post_purchase_bill(
  p_bill_id         uuid,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_bill    public.purchase_bills;
  v_line    record;
  v_lines   jsonb := '[]'::jsonb;
  v_entry   uuid;
  v_count   integer;
  v_account uuid;
  v_veh     record;
  v_total   numeric(18, 4);
  v_debit   numeric(18, 4);
  v_cgst    numeric(18, 4);
  v_sgst    numeric(18, 4);
  v_igst    numeric(18, 4);
begin
  select * into v_bill from public.purchase_bills where id = p_bill_id for update;

  if v_bill.id is null then
    raise exception 'Purchase bill not found.' using errcode = 'no_data_found';
  end if;
  if v_bill.status = 'POSTED' then
    return v_bill.journal_entry_id;
  end if;
  if v_bill.status <> 'DRAFT' then
    raise exception 'Purchase bill % is % and cannot be posted.',
      v_bill.bill_number, v_bill.status using errcode = 'check_violation';
  end if;

  select count(*)::integer into v_count
    from public.purchase_bill_lines where purchase_bill_id = p_bill_id;
  if v_count = 0 then
    raise exception 'Purchase bill % has no lines.', v_bill.bill_number
      using errcode = 'check_violation';
  end if;
  if v_bill.total_amount <= 0 then
    raise exception 'Purchase bill % comes to nothing.', v_bill.bill_number
      using errcode = 'check_violation';
  end if;

  for v_line in
    select * from public.purchase_bill_lines
     where purchase_bill_id = p_bill_id
     order by line_number
  loop
    v_debit := v_line.taxable_value;

    if v_line.line_type = 'VEHICLE' then
      select id, status, chassis_no into v_veh
        from public.vehicles where id = v_line.vehicle_id for update;

      if v_veh.id is null then
        raise exception 'The vehicle on line % no longer exists.', v_line.line_number
          using errcode = 'no_data_found';
      end if;
      if v_veh.status <> 'IN_STOCK' then
        raise exception 'Chassis % is % and cannot be put on a purchase bill.',
          v_veh.chassis_no, v_veh.status using errcode = 'check_violation';
      end if;

      update public.vehicles
         set purchase_cost    = v_line.taxable_value,
             purchase_invoice = coalesce(purchase_invoice, v_bill.supplier_bill_number),
             purchase_date    = coalesce(purchase_date, v_bill.bill_date),
             updated_by       = auth.uid()
       where id = v_line.vehicle_id;

      v_account := app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE',
                                       'VEHICLE_INVENTORY', v_bill.branch_id);

    elsif v_line.line_type = 'EXPENSE' then
      -- No stock moves. Blocked input tax is part of what the thing cost.
      v_account := v_line.account_id;
      if not v_line.itc_eligible then
        v_debit := v_debit + v_line.cgst_amount + v_line.sgst_amount + v_line.igst_amount;
      end if;

    else
      insert into public.inventory_transactions
        (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
         reference_type, reference_id, reference_number, narration, created_by)
      values
        (v_bill.dealer_id, v_bill.branch_id, v_line.item_id, v_line.source, 'PURCHASE',
         v_line.quantity, round(v_line.taxable_value / v_line.quantity, 4),
         'PURCHASE_BILL', p_bill_id, v_bill.bill_number,
         'Purchased on ' || v_bill.bill_number, auth.uid());

      v_account := app.require_account(
        v_bill.dealer_id, 'INVENTORY', 'PURCHASE',
        case when v_line.line_type = 'ACCESSORY' then 'ACCESSORY_INVENTORY'
             else 'SPARE_INVENTORY' end,
        v_bill.branch_id);
    end if;

    if v_debit > 0 then
      v_lines := v_lines || jsonb_build_object(
        'account_id', v_account, 'debit', v_debit, 'credit', 0,
        'narration', v_line.description);
    end if;
  end loop;

  -- ── Input GST, from the lines whose credit can be claimed ────────────────
  select coalesce(sum(cgst_amount), 0), coalesce(sum(sgst_amount), 0), coalesce(sum(igst_amount), 0)
    into v_cgst, v_sgst, v_igst
    from public.purchase_bill_lines
   where purchase_bill_id = p_bill_id and itc_eligible;

  if v_cgst > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_CGST', v_bill.branch_id),
      'debit', v_cgst, 'credit', 0, 'narration', 'Input CGST ' || v_bill.bill_number);
  end if;
  if v_sgst > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_SGST', v_bill.branch_id),
      'debit', v_sgst, 'credit', 0, 'narration', 'Input SGST ' || v_bill.bill_number);
  end if;
  if v_igst > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_IGST', v_bill.branch_id),
      'debit', v_igst, 'credit', 0, 'narration', 'Input IGST ' || v_bill.bill_number);
  end if;

  select total_amount into v_total from public.purchase_bills where id = p_bill_id;

  v_lines := v_lines || jsonb_build_object(
    'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'PAYABLE', v_bill.branch_id),
    'debit', 0, 'credit', v_total,
    'narration', 'Bill ' || v_bill.supplier_bill_number,
    'party_type', 'SUPPLIER', 'party_id', v_bill.supplier_id);

  v_entry := app.post_journal(
    v_bill.dealer_id, v_bill.branch_id, v_bill.bill_date,
    case when exists (select 1 from public.purchase_bill_lines
                       where purchase_bill_id = p_bill_id and line_type <> 'EXPENSE')
         then 'INVENTORY' else 'EXPENSE' end,
    'Purchase ' || v_bill.bill_number || ' — ' || v_bill.supplier_bill_number,
    v_lines,
    'PURCHASE_BILL', p_bill_id,
    coalesce(p_idempotency_key, 'purchase-bill:' || p_bill_id::text)
  );

  update public.purchase_bills
     set status = 'POSTED', journal_entry_id = v_entry,
         posted_at = now(), posted_by = auth.uid(), updated_by = auth.uid()
   where id = p_bill_id;

  return v_entry;
end;
$$;

comment on function public.post_purchase_bill(uuid, text) is
  'Posts a purchase bill (spec §21, §48): stock onto the balance sheet, expenses '
  'and fixed assets to their accounts, eligible input GST to ITC, and the payable '
  'onto the supplier''s ledger. Idempotent (spec §50).';

-- -----------------------------------------------------------------------------
-- Returns are for goods that go back; an expense is corrected by cancelling
-- -----------------------------------------------------------------------------
create or replace function public.returnable_purchase_lines(p_bill_id uuid)
returns table (
  bill_line_id        uuid,
  line_number         smallint,
  line_type           text,
  description         text,
  source              text,
  chassis_no          text,
  item_code           text,
  vehicle_status      text,
  billed_quantity     numeric(18, 3),
  returned_quantity   numeric(18, 3),
  returnable_quantity numeric(18, 3),
  unit_rate           numeric(18, 4),
  cgst_rate           numeric(6, 3),
  sgst_rate           numeric(6, 3),
  igst_rate           numeric(6, 3)
)
language sql
stable
as $$
  select l.id, l.line_number, l.line_type, l.description, l.source,
         v.chassis_no, i.item_code, v.status,
         l.quantity,
         coalesce(r.returned, 0)::numeric(18, 3),
         (l.quantity - coalesce(r.returned, 0))::numeric(18, 3),
         l.unit_rate, l.cgst_rate, l.sgst_rate, l.igst_rate
    from public.purchase_bill_lines l
    left join public.vehicles v on v.id = l.vehicle_id
    left join public.inventory_items i on i.id = l.item_id
    left join lateral (
      select sum(rl.quantity) as returned
        from public.purchase_return_lines rl
        join public.purchase_returns pr on pr.id = rl.purchase_return_id
       where rl.purchase_bill_line_id = l.id
         and pr.status = 'POSTED'
    ) r on true
   where l.purchase_bill_id = p_bill_id
     and l.line_type <> 'EXPENSE'
   order by l.line_number;
$$;

-- post_purchase_return() walks the lines it is given; an EXPENSE line has no
-- stock to take back. Refused with a reason rather than a constraint name.
create or replace function app.purchase_return_lines_type_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if exists (select 1 from public.purchase_bill_lines
              where id = new.purchase_bill_line_id and line_type = 'EXPENSE') then
    raise exception 'An expense line cannot be returned. Cancel the bill, or post the supplier''s credit note as a journal.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger purchase_return_lines_type_guard
  before insert on public.purchase_return_lines
  for each row execute function app.purchase_return_lines_type_guard();

-- -----------------------------------------------------------------------------
-- gst_input_summary() — expense lines by their HSN/SAC, blocked credit left out
-- -----------------------------------------------------------------------------
create or replace function public.gst_input_summary(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  hsn_code       text,
  description    text,
  taxable_value  numeric(18, 4),
  cgst_amount    numeric(18, 4),
  sgst_amount    numeric(18, 4),
  igst_amount    numeric(18, 4),
  total_tax      numeric(18, 4),
  document_count bigint
)
language sql
stable
as $$
  with lines as (
    select coalesce(h.code, l.hsn_sac, 'UNSPECIFIED') as hsn,
           coalesce(h.description, case when l.line_type = 'EXPENSE' then c.name end, '') as descr,
           l.taxable_value, l.cgst_amount, l.sgst_amount, l.igst_amount,
           b.id as doc
      from public.purchase_bill_lines l
      join public.purchase_bills b on b.id = l.purchase_bill_id
      left join public.inventory_items i on i.id = l.item_id
      left join public.vehicles v on v.id = l.vehicle_id
      left join public.vehicle_models m on m.id = v.model_id
      left join public.hsn_codes h on h.id = coalesce(i.hsn_code_id, m.hsn_code_id)
      left join public.chart_of_accounts c on c.id = l.account_id
     where b.status = 'POSTED'
       and l.itc_eligible
       and b.bill_date between p_from and p_to
       and (p_branch_id is null or b.branch_id = p_branch_id)

    union all

    select coalesce(h.code, 'UNSPECIFIED'),
           coalesce(h.description, ''),
           -rl.taxable_value, -rl.cgst_amount, -rl.sgst_amount, -rl.igst_amount,
           r.id
      from public.purchase_return_lines rl
      join public.purchase_returns r on r.id = rl.purchase_return_id
      left join public.inventory_items i on i.id = rl.item_id
      left join public.vehicles v on v.id = rl.vehicle_id
      left join public.vehicle_models m on m.id = v.model_id
      left join public.hsn_codes h on h.id = coalesce(i.hsn_code_id, m.hsn_code_id)
     where r.status = 'POSTED'
       and r.return_date between p_from and p_to
       and (p_branch_id is null or r.branch_id = p_branch_id)
  )
  select lines.hsn,
         max(lines.descr),
         sum(lines.taxable_value), sum(lines.cgst_amount), sum(lines.sgst_amount),
         sum(lines.igst_amount),
         sum(lines.cgst_amount + lines.sgst_amount + lines.igst_amount),
         count(distinct lines.doc)
    from lines
   group by lines.hsn
   order by lines.hsn;
$$;

comment on function public.gst_input_summary(date, date, uuid) is
  'HSN/SAC-wise claimable input tax for a period (spec §40, §41): stock and '
  'expense lines on purchase bills, less debit notes. Lines marked ITC-ineligible '
  'are excluded — their tax is a cost, not a credit.';

insert into public.schema_migrations (version, name)
values ('0078', 'expense_purchase_lines') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0079_stock_adjustment_posting.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0079 — Stock adjustments reach the ledger
-- =============================================================================
-- Spec §21, §34, §35, §60.22 ("No silent stock adjustments").
--
-- 0036's header says of transfers, returns and adjustments: "each moves value,
-- so each writes a journal alongside whatever it moves … an adjustment that
-- changes quantity without touching the ledger leaves stock value disagreeing
-- with the balance sheet." adjust_inventory_stock() then wrote the stock
-- movement and no journal.
--
-- Found by the control-account tie-out (0077) on the demo dealer after an
-- upgrade rehearsal: accessory stock ₹900 above account 1600 and spare stock
-- ₹480 below 1700 — exactly the two adjustments on file, and nothing else.
--
-- Now an adjustment posts, in the same transaction as the movement:
--
--     count up    Inventory (1600/1700)  Dr   /  Stock Adjustments (5970)  Cr
--     count down  Stock Adjustments      Dr   /  Inventory                 Cr
--
-- at the cost the movement carries, so the stock value and the ledger move by
-- the same amount. Accounts are resolved from accounting rules (spec §22), seeded
-- here as INVENTORY / ADJUSTMENT and remappable per dealer.
--
-- ── And they could not be made at all, from the application ────────────────
--
-- Writing the test for the above as the dealer owner under `authenticated`
-- (as the app runs) rather than as the database owner found a second defect:
-- adjust_inventory_stock() and transfer_inventory_stock() read the stock lot
-- with SELECT … FOR UPDATE, and inventory_stock has a SELECT policy and no
-- UPDATE policy — it is maintained by a SECURITY DEFINER trigger, by design.
-- Under RLS, FOR UPDATE only returns rows the caller could update, so the read
-- found nothing: every stock decrease was refused with "Only 0 in stock", every
-- branch transfer with "Only 0 in … stock at the source branch", and increases
-- were costed at standard cost instead of the lot's average. The seed data runs
-- as the owner, which is why the demo dealer has adjustments on file at all.
--
-- app.lock_stock_lot() takes the lock with definer rights, for the caller's own
-- dealer only, and both functions now use it.
--
-- Adjustments made BEFORE this migration are not journalled retrospectively:
-- a silent catch-up posting would be exactly the kind of unexplained ledger
-- movement this migration exists to stop. The tie-out shows the difference and
-- the notice below counts them; Accounts clears them with a manual journal
-- whose narration says what it is.
--
-- Rollback: restore public.adjust_inventory_stock and
--           public.transfer_inventory_stock from 0036; drop app.lock_stock_lot; restore
--           app.seed_purchase_accounting_rules by renaming the _0052 function;
--           drop app.seed_adjustment_accounting_rules. Posted journals stay.
-- =============================================================================

create or replace function app.seed_adjustment_accounting_rules(p_dealer_id uuid)
returns integer
language plpgsql
as $$
declare
  v_added   integer := 0;
  v_rule    record;
  v_account uuid;
begin
  for v_rule in
    select * from (values
      ('INVENTORY', 'ADJUSTMENT', 'ACCESSORY_INVENTORY', 'DEBIT',  '1600'),
      ('INVENTORY', 'ADJUSTMENT', 'SPARE_INVENTORY',     'DEBIT',  '1700'),
      ('INVENTORY', 'ADJUSTMENT', 'VARIANCE',            'CREDIT', '5970')
    ) as t(module, event, component, side, account_code)
  loop
    select id into v_account from public.chart_of_accounts
     where dealer_id = p_dealer_id and code = v_rule.account_code;
    continue when v_account is null;

    insert into public.accounting_rules
      (dealer_id, module, event, component, side, account_id, description)
    values
      (p_dealer_id, v_rule.module, v_rule.event, v_rule.component, v_rule.side,
       v_account, 'Stock adjustments (0079)')
    on conflict do nothing;

    if found then v_added := v_added + 1; end if;
  end loop;

  return v_added;
end;
$$;

do $$
declare d record;
begin
  for d in select id from public.dealers loop
    perform app.seed_adjustment_accounting_rules(d.id);
  end loop;
end $$;

-- Provisioning and the seed both call seed_purchase_accounting_rules; chaining
-- onto it means a new dealer gets these rules without either being edited.
alter function app.seed_purchase_accounting_rules(uuid) rename to seed_purchase_accounting_rules_0052;

create or replace function app.seed_purchase_accounting_rules(p_dealer_id uuid)
returns integer
language plpgsql
as $$
begin
  return app.seed_purchase_accounting_rules_0052(p_dealer_id)
       + app.seed_adjustment_accounting_rules(p_dealer_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- app.lock_stock_lot() — lock a lot and read it, whatever the caller's policies
-- -----------------------------------------------------------------------------
create or replace function app.lock_stock_lot(
  p_item_id   uuid,
  p_branch_id uuid,
  p_source    text
)
returns table (quantity numeric(14, 3), average_cost numeric(18, 4))
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_dealer uuid;
begin
  select i.dealer_id into v_dealer from public.inventory_items i where i.id = p_item_id;

  -- Definer rights, so the tenant check is explicit: a dealer user reaches only
  -- their own lots. auth.uid() is null for the service role and migrations.
  if v_dealer is null
     or (auth.uid() is not null
         and not app.is_platform_admin()
         and v_dealer is distinct from app.current_dealer_id()) then
    raise exception 'Item not found.' using errcode = 'no_data_found';
  end if;
  if not exists (select 1 from public.branches b where b.id = p_branch_id and b.dealer_id = v_dealer) then
    raise exception 'That branch does not belong to this dealer.' using errcode = 'insufficient_privilege';
  end if;

  return query
    select s.quantity, s.average_cost
      from public.inventory_stock s
     where s.item_id = p_item_id and s.branch_id = p_branch_id and s.source = p_source
       for update;
end;
$$;

revoke execute on function app.lock_stock_lot(uuid, uuid, text) from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function app.lock_stock_lot(uuid, uuid, text) to authenticated';
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- public.transfer_inventory_stock() — as 0036, reading the lot through the lock
-- -----------------------------------------------------------------------------
create or replace function public.transfer_inventory_stock(
  p_item_id        uuid,
  p_from_branch_id uuid,
  p_to_branch_id   uuid,
  p_quantity       numeric,
  p_source         text default 'COMPANY',
  p_remarks        text default null
)
returns void
language plpgsql
as $$
declare
  v_dealer    uuid;
  v_available numeric(14, 3);
  v_cost      numeric(18, 4);
begin
  if p_quantity <= 0 then
    raise exception 'Quantity must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_from_branch_id = p_to_branch_id then
    raise exception 'The source and destination branches are the same.' using errcode = 'check_violation';
  end if;
  if p_source not in ('LOCAL', 'COMPANY') then
    raise exception 'Source must be LOCAL or COMPANY.' using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer from public.inventory_items where id = p_item_id;
  if v_dealer is null then
    raise exception 'Item not found.' using errcode = 'no_data_found';
  end if;
  if not exists (select 1 from public.branches where id = p_to_branch_id and dealer_id = v_dealer) then
    raise exception 'The destination branch does not belong to this dealer.'
      using errcode = 'insufficient_privilege';
  end if;

  select l.quantity, l.average_cost into v_available, v_cost
    from app.lock_stock_lot(p_item_id, p_from_branch_id, p_source) l;

  if coalesce(v_available, 0) < p_quantity then
    raise exception 'Only % in % stock at the source branch.', coalesce(v_available, 0), p_source
      using errcode = 'check_violation';
  end if;

  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
     reference_type, narration, created_by)
  values
    (v_dealer, p_from_branch_id, p_item_id, p_source, 'TRANSFER_OUT', -p_quantity, v_cost,
     'STOCK_TRANSFER', coalesce(p_remarks, 'Transferred out'), auth.uid()),
    (v_dealer, p_to_branch_id, p_item_id, p_source, 'TRANSFER_IN', p_quantity, v_cost,
     'STOCK_TRANSFER', coalesce(p_remarks, 'Transferred in'), auth.uid());
end;
$$;

-- -----------------------------------------------------------------------------
-- public.adjust_inventory_stock() — the movement and its journal, together
-- -----------------------------------------------------------------------------
create or replace function public.adjust_inventory_stock(
  p_item_id   uuid,
  p_branch_id uuid,
  p_source    text,
  p_quantity  numeric,
  p_reason    text
)
returns void
language plpgsql
as $$
declare
  v_dealer    uuid;
  v_type      text;
  v_code      text;
  v_available numeric(14, 3);
  v_cost      numeric(18, 4);
  v_value     numeric(18, 4);
  v_stock_acc uuid;
  v_var_acc   uuid;
  v_entry     uuid;
begin
  if p_quantity = 0 then
    raise exception 'An adjustment of zero changes nothing.' using errcode = 'check_violation';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A stock adjustment requires a reason.'
      using errcode = 'check_violation',
            hint = 'Spec §35: adjustments are auditable, so they must be explained.';
  end if;
  if p_source not in ('LOCAL', 'COMPANY') then
    raise exception 'Source must be LOCAL or COMPANY.' using errcode = 'check_violation';
  end if;

  select dealer_id, standard_cost, item_type, item_code into v_dealer, v_cost, v_type, v_code
    from public.inventory_items where id = p_item_id;

  if v_dealer is null then
    raise exception 'Item not found.' using errcode = 'no_data_found';
  end if;

  select l.quantity, l.average_cost into v_available, v_cost
    from app.lock_stock_lot(p_item_id, p_branch_id, p_source) l;

  if p_quantity < 0 and coalesce(v_available, 0) < abs(p_quantity) then
    raise exception 'Only % in stock — an adjustment of % would drive it negative.',
      coalesce(v_available, 0), p_quantity using errcode = 'check_violation';
  end if;

  if v_cost is null or v_cost = 0 then
    select standard_cost into v_cost from public.inventory_items where id = p_item_id;
  end if;
  v_cost  := coalesce(v_cost, 0);
  -- The same figure the movement's generated `value` column will hold, so the
  -- stock ledger and the general ledger move by exactly the same amount.
  v_value := round(abs(p_quantity) * v_cost, 4);

  -- ── The journal first: if the rules are missing, nothing moves ──────────
  if v_value > 0 then
    v_stock_acc := app.require_account(v_dealer, 'INVENTORY', 'ADJUSTMENT',
      case when v_type = 'ACCESSORY' then 'ACCESSORY_INVENTORY' else 'SPARE_INVENTORY' end,
      p_branch_id);
    v_var_acc := app.require_account(v_dealer, 'INVENTORY', 'ADJUSTMENT', 'VARIANCE', p_branch_id);

    v_entry := app.post_journal(
      v_dealer, p_branch_id, current_date, 'INVENTORY',
      'Stock adjustment ' || v_code || ' ' || p_source || ' '
        || case when p_quantity > 0 then '+' else '' end || p_quantity::text
        || ' — ' || btrim(p_reason),
      case when p_quantity > 0 then
        jsonb_build_array(
          jsonb_build_object('account_id', v_stock_acc, 'debit', v_value, 'credit', 0,
                             'narration', 'Counted more ' || v_code),
          jsonb_build_object('account_id', v_var_acc, 'debit', 0, 'credit', v_value,
                             'narration', btrim(p_reason)))
      else
        jsonb_build_array(
          jsonb_build_object('account_id', v_var_acc, 'debit', v_value, 'credit', 0,
                             'narration', btrim(p_reason)),
          jsonb_build_object('account_id', v_stock_acc, 'debit', 0, 'credit', v_value,
                             'narration', 'Counted less ' || v_code))
      end,
      'STOCK_ADJUSTMENT', p_item_id, null);
  end if;

  -- reference_id carries the journal, so the stock ledger row drills to it.
  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
     reference_type, reference_id, narration, reason, created_by)
  values
    (v_dealer, p_branch_id, p_item_id, p_source, 'ADJUSTMENT', p_quantity, v_cost,
     'ADJUSTMENT', v_entry, 'Stock adjustment', btrim(p_reason), auth.uid());
end;
$$;

comment on function public.adjust_inventory_stock(uuid, uuid, text, numeric, text) is
  'A counted-stock correction (spec §35): the movement and its journal against '
  'Stock Adjustments, at the movement''s cost, in one transaction. A reason is '
  'required and kept on both.';

-- -----------------------------------------------------------------------------
-- What was adjusted before this, without a journal
-- -----------------------------------------------------------------------------
do $$
declare
  v_count integer;
  v_net   numeric;
begin
  select count(*), coalesce(sum(value), 0) into v_count, v_net
    from public.inventory_transactions
   where transaction_type = 'ADJUSTMENT' and reference_id is null;

  if v_count > 0 then
    raise notice '0079: % earlier stock adjustment(s), net value %, were never journalled. Accounting → Control Tie-out shows the difference; clear it with a manual journal to 5970.', v_count, v_net;
  end if;
end $$;

insert into public.schema_migrations (version, name)
values ('0079', 'stock_adjustment_posting') on conflict (version) do nothing;


commit;
