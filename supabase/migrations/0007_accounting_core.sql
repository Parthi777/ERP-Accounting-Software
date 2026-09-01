-- =============================================================================
-- 0007 — Accounting core: chart of accounts, periods, journals
-- =============================================================================
-- Spec §21–§24. Every module in the product eventually posts through these three
-- tables; there is exactly one accounting engine (spec §60.18).
--
-- This migration creates the SCHEMA and its integrity rules — the balance check,
-- the immutability trigger, the reversal linkage. The posting service that writes
-- through it arrives with the business modules (Phase 4+).
--
-- Three rules are enforced by the database, not by application code:
--   1. A posted journal balances: total_debit = total_credit (spec §22).
--   2. A posted journal cannot be edited or deleted (spec §23, §60.12).
--   3. Correction happens through reversal, and a reversal records who and why.
--
-- Rollback: drop tables journal_entry_lines, journal_entries, accounting_periods,
--           chart_of_accounts; drop the app.journal_* functions.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- chart_of_accounts — spec §24
-- -----------------------------------------------------------------------------
create table public.chart_of_accounts (
  id              uuid primary key default gen_random_uuid(),
  dealer_id       uuid not null references public.dealers (id) on delete restrict,

  code            text not null,
  name            text not null,
  account_type    text not null,
  account_subtype text,

  parent_id       uuid,

  -- Which side increases this account. Used for ledger presentation and for
  -- deriving balances without hard-coding sign logic per report.
  normal_balance  text not null,

  -- Group accounts are headers; only leaf accounts may be posted to.
  is_group        boolean not null default false,
  -- System accounts are created by seed/migration and cannot be deleted by users.
  is_system       boolean not null default false,
  -- When true, ledger balances are meaningful per branch (cash, bank, stock).
  is_branch_scoped boolean not null default false,

  status          text not null default 'ACTIVE',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  created_by      uuid,
  updated_by      uuid,

  constraint coa_dealer_code_key unique (dealer_id, code),
  constraint coa_id_dealer_key   unique (id, dealer_id),
  constraint coa_parent_tenant_fkey
    foreign key (parent_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint coa_type_check check (
    account_type in ('ASSET', 'LIABILITY', 'EQUITY', 'INCOME', 'EXPENSE')
  ),
  constraint coa_normal_balance_check check (normal_balance in ('DEBIT', 'CREDIT')),
  constraint coa_status_check check (status in ('ACTIVE', 'INACTIVE')),
  constraint coa_code_format_check check (code ~ '^[0-9A-Z][0-9A-Z._-]{0,29}$'),
  -- Assets and expenses are debit-normal; liabilities, equity and income are credit-normal.
  constraint coa_normal_balance_matches_type_check check (
    (account_type in ('ASSET', 'EXPENSE') and normal_balance = 'DEBIT')
    or (account_type in ('LIABILITY', 'EQUITY', 'INCOME') and normal_balance = 'CREDIT')
  ),
  constraint coa_no_self_parent_check check (parent_id is null or parent_id <> id)
);

comment on table public.chart_of_accounts is
  'Dealer-scoped chart of accounts (spec §24). Account IDs are resolved through '
  'accounting rules at posting time and are never hard-coded in the frontend (spec §22).';

-- -----------------------------------------------------------------------------
-- accounting_periods — spec §44
-- -----------------------------------------------------------------------------
create table public.accounting_periods (
  id         uuid primary key default gen_random_uuid(),
  dealer_id  uuid not null references public.dealers (id) on delete cascade,

  name       text not null,
  start_date date not null,
  end_date   date not null,
  status     text not null default 'OPEN',

  closed_at  timestamptz,
  closed_by  uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint accounting_periods_range_key  unique (dealer_id, start_date, end_date),
  constraint accounting_periods_id_dealer_key unique (id, dealer_id),
  constraint accounting_periods_dates_check check (end_date >= start_date),
  constraint accounting_periods_status_check check (status in ('OPEN', 'CLOSED', 'LOCKED'))
);

create index accounting_periods_dealer_range_idx
  on public.accounting_periods (dealer_id, start_date, end_date);

-- A dealer's periods must not overlap. An exclusion constraint would be the
-- natural tool but needs btree_gist; a trigger keeps this migration extension-free.
create or replace function app.accounting_periods_no_overlap()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_conflict text;
begin
  select ap.name
    into v_conflict
    from public.accounting_periods ap
   where ap.dealer_id = new.dealer_id
     and ap.id <> new.id
     and ap.start_date <= new.end_date
     and ap.end_date   >= new.start_date
   limit 1;

  if found then
    raise exception 'Accounting period % overlaps existing period %.', new.name, v_conflict
      using errcode = 'exclusion_violation';
  end if;

  return new;
end;
$$;

create trigger accounting_periods_no_overlap
  before insert or update on public.accounting_periods
  for each row execute function app.accounting_periods_no_overlap();

-- -----------------------------------------------------------------------------
-- journal_entries — spec §21, §22, §23
-- -----------------------------------------------------------------------------
create table public.journal_entries (
  id                   uuid primary key default gen_random_uuid(),
  dealer_id            uuid not null references public.dealers (id) on delete restrict,
  branch_id            uuid not null,

  entry_number         text not null,
  entry_date           date not null,
  period_id            uuid,

  -- Which business module raised this accounting event (spec §21).
  source_module        text not null,
  source_document_type text,
  source_document_id   uuid,

  narration            text,
  status               text not null default 'DRAFT',

  -- Maintained by trigger from the lines; never written directly by the client.
  total_debit          numeric(18, 4) not null default 0,
  total_credit         numeric(18, 4) not null default 0,

  -- Reversal linkage (spec §23).
  reversal_of_id       uuid,
  reversed_by_id       uuid,
  reversal_reason      text,

  -- Duplicate-submission protection for financial endpoints (spec §50).
  idempotency_key      text,

  posted_at            timestamptz,
  posted_by            uuid,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  created_by           uuid,
  updated_by           uuid,

  constraint journal_entries_dealer_number_key unique (dealer_id, entry_number),
  constraint journal_entries_id_dealer_key     unique (id, dealer_id),
  constraint journal_entries_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint journal_entries_period_tenant_fkey
    foreign key (period_id, dealer_id) references public.accounting_periods (id, dealer_id),
  constraint journal_entries_reversal_of_fkey
    foreign key (reversal_of_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint journal_entries_reversed_by_fkey
    foreign key (reversed_by_id, dealer_id) references public.journal_entries (id, dealer_id),

  constraint journal_entries_status_check check (status in ('DRAFT', 'POSTED', 'REVERSED')),
  constraint journal_entries_module_check check (source_module in (
    'SALES', 'BOOKING', 'SERVICE', 'ACCESSORY', 'SPARE',
    'FINANCE', 'TRADE_ADVANCE', 'CASH', 'BANK',
    'EXPENSE', 'INVENTORY', 'MANUAL', 'OPENING'
  )),
  constraint journal_entries_totals_sign_check check (total_debit >= 0 and total_credit >= 0),

  -- Rule 1: a posted journal balances (spec §22).
  constraint journal_entries_balanced_check check (
    status = 'DRAFT' or total_debit = total_credit
  ),
  constraint journal_entries_posted_nonzero_check check (
    status = 'DRAFT' or total_debit > 0
  ),
  constraint journal_entries_posted_stamp_check check (
    status = 'DRAFT' or posted_at is not null
  ),
  -- A reversal must say why (spec §23).
  constraint journal_entries_reversal_reason_check check (
    reversal_of_id is null or reversal_reason is not null
  ),
  constraint journal_entries_no_self_reversal_check check (
    (reversal_of_id is null or reversal_of_id <> id)
    and (reversed_by_id is null or reversed_by_id <> id)
  )
);

comment on table public.journal_entries is
  'Journal header. Posted entries are immutable; corrections are made by posting a '
  'reversal and a corrected entry (spec §23, §60.12, §60.13).';

-- Idempotency keys are unique per dealer where present (spec §50).
create unique index journal_entries_idempotency_key
  on public.journal_entries (dealer_id, idempotency_key)
  where idempotency_key is not null;

-- -----------------------------------------------------------------------------
-- journal_entry_lines
-- -----------------------------------------------------------------------------
create table public.journal_entry_lines (
  id               uuid primary key default gen_random_uuid(),
  journal_entry_id uuid not null,
  dealer_id        uuid not null,

  line_number      smallint not null,
  account_id       uuid not null,
  -- Optional narrower scope than the header, for branch-scoped accounts.
  branch_id        uuid,

  debit            numeric(18, 4) not null default 0,
  credit           numeric(18, 4) not null default 0,

  narration        text,

  -- Subsidiary-ledger pointer: which customer / supplier / finance company this
  -- line belongs to, so party ledgers reconcile to the general ledger (spec §25).
  party_type       text,
  party_id         uuid,

  created_at       timestamptz not null default now(),

  constraint jel_entry_line_key unique (journal_entry_id, line_number),
  constraint jel_entry_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id) on delete cascade,
  constraint jel_account_tenant_fkey
    foreign key (account_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint jel_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint jel_amounts_sign_check check (debit >= 0 and credit >= 0),
  -- A line is a debit or a credit, never both and never neither.
  constraint jel_one_sided_check check (
    (debit > 0 and credit = 0) or (credit > 0 and debit = 0)
  ),
  constraint jel_line_number_check check (line_number > 0),
  constraint jel_party_shape_check check (
    (party_type is null and party_id is null) or (party_type is not null and party_id is not null)
  ),
  constraint jel_party_type_check check (
    party_type is null or party_type in ('CUSTOMER', 'SUPPLIER', 'FINANCE_COMPANY', 'EMPLOYEE')
  )
);

comment on table public.journal_entry_lines is
  'Journal detail. Every line is one-sided; the header''s balance check is enforced at posting.';

-- -----------------------------------------------------------------------------
-- Posting guard: recompute totals from lines, and refuse to post an unbalanced entry
-- -----------------------------------------------------------------------------
-- This is where the double-entry rule actually bites. The CHECK constraint above
-- can only compare the columns it is given; this trigger makes sure those columns
-- reflect the lines rather than whatever the caller supplied.
-- -----------------------------------------------------------------------------
create or replace function app.journal_entries_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_debit  numeric(18, 4);
  v_credit numeric(18, 4);
  v_lines  integer;
begin
  if tg_op = 'DELETE' then
    if old.status <> 'DRAFT' then
      raise exception
        'Journal % is % and cannot be deleted. Post a reversal instead.', old.entry_number, old.status
        using errcode = 'insufficient_privilege',
              hint = 'Spec §23: corrections use reversal, not deletion.';
    end if;
    return old;
  end if;

  -- Entries are born as drafts. Forcing everything through the DRAFT -> POSTED
  -- transition below means the line-level balance check can never be skipped by
  -- inserting a pre-posted row with hand-written totals.
  if tg_op = 'INSERT' then
    if new.status <> 'DRAFT' then
      raise exception 'Journal entries must be created as DRAFT, then posted; got %.', new.status
        using errcode = 'check_violation',
              hint = 'Insert the header and its lines, then update status to POSTED.';
    end if;
    return new;
  end if;

  -- DRAFT -> POSTED: derive the totals from the lines and verify the entry balances.
  if old.status = 'DRAFT' and new.status = 'POSTED' then
    select coalesce(sum(l.debit), 0), coalesce(sum(l.credit), 0), count(*)
      into v_debit, v_credit, v_lines
      from public.journal_entry_lines l
     where l.journal_entry_id = old.id;

    if v_lines < 2 then
      raise exception 'Journal % needs at least two lines to post; found %.', old.entry_number, v_lines
        using errcode = 'check_violation';
    end if;

    if v_debit <> v_credit then
      raise exception
        'Journal % does not balance: debit % <> credit %.', old.entry_number, v_debit, v_credit
        using errcode = 'check_violation',
              hint = 'Spec §22: total debit must equal total credit.';
    end if;

    new.total_debit  := v_debit;
    new.total_credit := v_credit;
    new.posted_at    := coalesce(new.posted_at, now());
    return new;
  end if;

  -- POSTED is immutable except for recording that it has since been reversed.
  if old.status = 'POSTED' then
    if new.status = 'REVERSED'
       and old.reversed_by_id is null
       and new.reversed_by_id is not null
       and new.reversal_reason is not null
       and (to_jsonb(new) - 'status' - 'reversed_by_id' - 'reversal_reason' - 'updated_at' - 'updated_by')
           = (to_jsonb(old) - 'status' - 'reversed_by_id' - 'reversal_reason' - 'updated_at' - 'updated_by')
    then
      return new;
    end if;

    raise exception 'Journal % is POSTED and immutable.', old.entry_number
      using errcode = 'insufficient_privilege',
            hint = 'Spec §23: post a reversal and a corrected entry instead of editing.';
  end if;

  if old.status = 'REVERSED' then
    raise exception 'Journal % is REVERSED and immutable.', old.entry_number
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end;
$$;

create trigger journal_entries_guard
  before insert or update or delete on public.journal_entries
  for each row execute function app.journal_entries_guard();

-- -----------------------------------------------------------------------------
-- Line guard: lines may only change while the header is DRAFT
-- -----------------------------------------------------------------------------
create or replace function app.journal_lines_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_entry_id uuid := coalesce(new.journal_entry_id, old.journal_entry_id);
  v_status   text;
  v_number   text;
begin
  select je.status, je.entry_number
    into v_status, v_number
    from public.journal_entries je
   where je.id = v_entry_id;

  -- Header already gone (ON DELETE CASCADE): let the cascade proceed.
  if v_status is null then
    return coalesce(new, old);
  end if;

  if v_status <> 'DRAFT' then
    raise exception 'Cannot % lines of journal %: it is %.', lower(tg_op), v_number, v_status
      using errcode = 'insufficient_privilege',
            hint = 'Spec §23: posted journals are immutable.';
  end if;

  return coalesce(new, old);
end;
$$;

create trigger journal_lines_guard
  before insert or update or delete on public.journal_entry_lines
  for each row execute function app.journal_lines_guard();

-- -----------------------------------------------------------------------------
-- Totals stay in sync with the lines while the entry is still a draft
-- -----------------------------------------------------------------------------
create or replace function app.journal_sync_totals()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_entry_id uuid := coalesce(new.journal_entry_id, old.journal_entry_id);
begin
  update public.journal_entries je
     set total_debit  = coalesce(t.debit, 0),
         total_credit = coalesce(t.credit, 0)
    from (
      select sum(l.debit) as debit, sum(l.credit) as credit
        from public.journal_entry_lines l
       where l.journal_entry_id = v_entry_id
    ) t
   where je.id = v_entry_id
     and je.status = 'DRAFT';

  return null;
end;
$$;

create trigger journal_lines_sync_totals
  after insert or update or delete on public.journal_entry_lines
  for each row execute function app.journal_sync_totals();

create trigger chart_of_accounts_set_updated_at
  before update on public.chart_of_accounts
  for each row execute function app.set_updated_at();

create trigger accounting_periods_set_updated_at
  before update on public.accounting_periods
  for each row execute function app.set_updated_at();

create trigger journal_entries_set_updated_at
  before update on public.journal_entries
  for each row execute function app.set_updated_at();

create trigger chart_of_accounts_audit
  after insert or update or delete on public.chart_of_accounts
  for each row execute function app.audit_trigger();

create trigger journal_entries_audit
  after insert or update or delete on public.journal_entries
  for each row execute function app.audit_trigger();
