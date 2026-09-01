-- =============================================================================
-- 0037 — Customer ledger opening balance
-- =============================================================================
-- Spec §11, §41.
--
-- The customer ledger from 0026 computed its running balance across the
-- filtered window alone, so a ledger for August opened at zero however much the
-- customer owed on 31 July. Every balance on the page was then wrong by the
-- carried-forward amount, and the subsidiary ledger stopped agreeing with the
-- receivable control account — which is the one property §41 asks it to have.
--
-- Both functions here are invoker-rights, so RLS scopes them to the caller's
-- dealer exactly as it does a plain select.
--
-- Rollback: restore public.customer_ledger(uuid, date, date) from 0026 and
--           drop public.customer_ledger_opening(uuid, date).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.customer_ledger_opening() — what the customer owed before the window
-- -----------------------------------------------------------------------------
-- Returned separately rather than folded into the ledger because the opening
-- balance has to be shown even when the window contains no movements at all: a
-- customer who owes money and did nothing this month still has a balance, and a
-- statement that renders as empty would be read as "nothing outstanding".
-- -----------------------------------------------------------------------------
create or replace function public.customer_ledger_opening(
  p_customer_id uuid,
  p_as_on       date
)
returns numeric
language sql
stable
as $$
  select coalesce(sum(l.debit - l.credit), 0)::numeric(18, 4)
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.party_type = 'CUSTOMER'
     and l.party_id = p_customer_id
     and je.status in ('POSTED', 'REVERSED')
     and je.entry_date < p_as_on;
$$;

comment on function public.customer_ledger_opening(uuid, date) is
  'Customer balance carried into a date (spec §41). Debit positive: the customer owes.';

-- -----------------------------------------------------------------------------
-- public.customer_ledger() — the running account, seeded with the opening
-- -----------------------------------------------------------------------------
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
  -- The subsidiary ledger is derived from party-tagged journal lines, so it
  -- reconciles to the receivable control account by construction. The running
  -- balance starts from the carried-forward balance, so any row read on its own
  -- is the customer's actual position on that date rather than a total of the
  -- window that happens to be on screen.
  select je.entry_date, je.entry_number, coalesce(l.narration, je.narration),
         l.debit, l.credit,
         public.customer_ledger_opening(p_customer_id, p_from)
           + sum(l.debit - l.credit) over (order by je.entry_date, je.entry_number, l.line_number
                                           rows between unbounded preceding and current row)
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.party_type = 'CUSTOMER'
     and l.party_id = p_customer_id
     and je.status in ('POSTED', 'REVERSED')
     and je.entry_date between p_from and p_to
   order by je.entry_date, je.entry_number, l.line_number;
$$;

comment on function public.customer_ledger(uuid, date, date) is
  'Customer running account from the general ledger (spec §41), opening balance '
  'included, so the subsidiary ledger and the control account can never disagree.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.customer_ledger_opening(uuid, date) to authenticated';
    execute 'grant execute on function public.customer_ledger(uuid, date, date) to authenticated';
  end if;
end;
$$;
