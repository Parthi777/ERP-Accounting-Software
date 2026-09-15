-- =============================================================================
-- 0070 — The ledger of an account, which nothing could show
-- =============================================================================
-- Spec §8, §41, §43.
--
-- The product has a customer ledger, a supplier ledger, a cash book and a bank
-- book. It has never had the plainest one of all: pick an account from the chart
-- and see what moved through it.
--
-- So "why is Bank Charges 4,150 this month" had no answer on any screen. The
-- trial balance gives the total and stops; the chart of accounts is a list of
-- names. Spec §43 asks that every number be drillable down to the transaction,
-- and for the accounts that are not a party or a bank, nothing was.
--
-- Mirrors party_ledger exactly — opening carried in, running balance computed
-- from it — so a row read on its own is the account's real position on that
-- date rather than a total of whatever window is on screen.
--
-- Rollback: drop both functions.
-- =============================================================================

create or replace function public.account_ledger_opening(
  p_account_id uuid,
  p_as_on      date
)
returns numeric
language sql
stable
as $$
  select coalesce(sum(l.debit - l.credit), 0)::numeric(18, 4)
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.account_id = p_account_id
     and je.status in ('POSTED', 'REVERSED')
     and je.entry_date < p_as_on;
$$;

comment on function public.account_ledger_opening(uuid, date) is
  'Balance carried into a date for one account (spec §41). Debit positive, '
  'whatever the account''s normal side — the screen reads the sign.';

create or replace function public.account_ledger(
  p_account_id uuid,
  p_from       date,
  p_to         date,
  p_branch_id  uuid default null
)
returns table (
  journal_entry_id uuid,
  entry_date       date,
  entry_number     text,
  source_module    text,
  status           text,
  narration        text,
  -- What sat on the other side of this line, which is the question anyone
  -- reading a ledger row actually has: "4,150 to Bank Charges — from where?"
  contra           text,
  debit            numeric(18, 4),
  credit           numeric(18, 4),
  running_balance  numeric(18, 4)
)
language sql
stable
as $$
  select je.id,
         je.entry_date,
         je.entry_number,
         je.source_module,
         je.status,
         coalesce(l.narration, je.narration),
         (
           -- The opposite side of the same entry, named. Several accounts on the
           -- other side are listed rather than reduced to "Split", because on a
           -- two-line entry — which most are — the one name is the whole answer.
           select string_agg(distinct c2.name, ', ' order by c2.name)
             from public.journal_entry_lines l2
             join public.chart_of_accounts c2 on c2.id = l2.account_id
            where l2.journal_entry_id = je.id
              and l2.account_id <> p_account_id
         ),
         l.debit,
         l.credit,
         public.account_ledger_opening(p_account_id, p_from)
           + sum(l.debit - l.credit) over (order by je.entry_date, je.entry_number, l.line_number
                                           rows between unbounded preceding and current row)
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.account_id = p_account_id
     and je.status in ('POSTED', 'REVERSED')
     and je.entry_date between p_from and p_to
     and (p_branch_id is null or je.branch_id = p_branch_id)
   order by je.entry_date, je.entry_number, l.line_number;
$$;

comment on function public.account_ledger(uuid, date, date, uuid) is
  'What moved through one account, with the contra account named (spec §41, §43). '
  'The running balance starts from the carried-forward opening, so any row read '
  'alone is the real position on that date.';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  execute 'grant execute on function public.account_ledger_opening(uuid, date) to authenticated';
  execute 'grant execute on function public.account_ledger(uuid, date, date, uuid) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0070', 'account_ledger') on conflict (version) do nothing;
