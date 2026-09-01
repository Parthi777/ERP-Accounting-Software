-- =============================================================================
-- 0012 — Reporting: account balances
-- =============================================================================
-- The dashboard and every accounting report ask the same question: what are the
-- balances of each account, for this branch, over this date range. Doing that by
-- fetching journal lines into the application and summing them there would move
-- megabytes to add them up, so it is a database function.
--
-- SECURITY INVOKER (the default) is important here: the function runs with the
-- caller's privileges, so the RLS policies on journal_entries, journal_entry_lines
-- and chart_of_accounts all still apply. Tenant isolation is not bypassed to make
-- reporting convenient.
--
-- Balance-sheet accounts need a cumulative balance; profit-and-loss accounts need
-- the movement within the period. Both are returned so the caller picks the right
-- one per account type rather than issuing two queries.
--
-- Rollback: drop function public.account_balances(date, date, uuid);
-- =============================================================================

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
  -- Signed balance in the account's own normal direction: positive means the
  -- account is where you would expect it to be.
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
   -- Only posted entries count. Drafts are not yet part of the books (spec §19).
   and je.status in ('POSTED', 'REVERSED')
   and (p_branch_id is null or je.branch_id = p_branch_id)
  where not coa.is_group
    and coa.status = 'ACTIVE'
  group by coa.id, coa.code, coa.name, coa.account_type, coa.normal_balance
  order by coa.code;
$$;

comment on function public.account_balances(date, date, uuid) is
  'Per-account debit/credit totals for a period and cumulatively to the end date. '
  'SECURITY INVOKER, so RLS scopes it to the caller''s dealer and branches.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.account_balances(date, date, uuid) to authenticated';
  end if;
end;
$$;

revoke execute on function public.account_balances(date, date, uuid) from public;
