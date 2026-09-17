-- =============================================================================
-- 0075 — The work nobody could see was waiting
-- =============================================================================
-- Spec §19, §36, §40, §54.
--
-- The live dealer has three vehicle-sale drafts, created on three consecutive
-- days, all identical, none submitted. Between the second and the third the same
-- user created and posted a service invoice without trouble. Nothing is broken:
-- the role holds sales.submit, the RLS update policy allows the transition, the
-- status guard permits DRAFT → SUBMITTED, every line type resolves to an
-- accounting rule, and the sale screen renders "Submit for verification" for a
-- draft. The workflow works. Nothing tells anyone it is waiting.
--
-- A draft is not a sale. It is in no ledger, no GST return and no stock
-- movement, and the vehicle behind it is neither sold nor available. Three days
-- of vehicle sales sat in that state while the dashboard showed nothing at all —
-- it has no mention of drafts, and the sales list offers a status badge and no
-- reason to act on it.
--
-- Spec §54 asks for an "attention required" panel in row three of the
-- dashboard. This is the query behind it.
--
-- DELIBERATELY NOT PERIOD-SCOPED.
--
-- Every other dashboard figure is bounded by the selected financial year, and
-- this one must not be: a draft raised last March is more urgent than one raised
-- this morning, not less, and it would vanish from the panel exactly when the
-- year turned over. Work in progress is a state, not a period.
--
-- Rollback: drop function public.work_in_progress(uuid).
-- =============================================================================

create or replace function public.work_in_progress(p_branch_id uuid default null)
returns table (
  key         text,
  count       bigint,
  oldest_date date,
  href        text
)
language sql
stable
as $$
  -- Each row is a stage something can be stuck at, with the oldest example so
  -- the screen can say "the oldest is 3 days old" rather than only how many.
  with stages as (
    select 'sales_draft'      as key, 1 as ord,
           '/sales?status=DRAFT' as href,
           count(*) as count, min(s.invoice_date) as oldest_date
      from public.sales s
     where s.status = 'DRAFT'
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select 'sales_awaiting_approval', 2,
           '/sales?status=SUBMITTED',
           count(*), min(s.invoice_date)
      from public.sales s
     where s.status in ('SUBMITTED', 'ACCOUNTS_VERIFICATION')
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select 'sales_approved_unposted', 3,
           '/sales?status=APPROVED',
           count(*), min(s.invoice_date)
      from public.sales s
     where s.status = 'APPROVED'
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    -- POSTED is its own status until the vehicle leaves; DELIVERED replaces it.
    select 'sales_undelivered', 4,
           '/sales?status=POSTED',
           count(*), min(s.invoice_date)
      from public.sales s
     where s.status = 'POSTED'
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select 'bookings_open', 5,
           '/bookings',
           count(*), min(b.booking_date)
      from public.bookings b
     where b.status = 'OPEN'
       and (p_branch_id is null or b.branch_id = p_branch_id)
    union all
    -- A failed filing is a document the dealer may not legally deliver against,
    -- so it belongs here rather than only on the GST screen (spec §40).
    select 'einvoice_failed', 6,
           '/gst/e-invoice',
           count(*), min(e.document_date)
      from public.einvoices e
     where e.status = 'FAILED'
    union all
    -- Spec §36: the cash day is mandatory and closing it is not optional. A day
    -- with movement on it and no closing, before today, is a day nobody counted.
    select 'cash_days_open', 7,
           '/cash-book/day-close',
           count(*), min(t.day)
      from (
        select distinct ct.business_date as day, ct.branch_id
          from public.cash_transactions ct
         where ct.business_date < current_date
           and ct.status = 'ACTIVE'
      ) t
     where (p_branch_id is null or t.branch_id = p_branch_id)
       and not exists (
         select 1 from public.cash_day_closings c
          where c.branch_id = t.branch_id
            and c.business_date = t.day
            and c.status = 'CLOSED')
  )
  select key, count, oldest_date, href
    from stages
   where count > 0
   order by ord;
$$;

comment on function public.work_in_progress(uuid) is
  'One row per stage something is stuck at — drafts, unapproved sales, unposted '
  'approvals, undelivered invoices, open bookings, failed filings, uncounted '
  'cash days (spec §54). Never period-scoped: a draft from last year is more '
  'urgent than one from this morning, not less.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.work_in_progress(uuid) to authenticated';
  end if;
end $$;

insert into public.schema_migrations (version, name)
values ('0075', 'work_in_progress') on conflict (version) do nothing;
