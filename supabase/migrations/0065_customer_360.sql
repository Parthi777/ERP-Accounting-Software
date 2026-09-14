-- =============================================================================
-- 0065 — Customer 360, as a query rather than a promise
-- =============================================================================
-- Spec §11, §41, §59.
--
-- The customer page has been rendering six dashed boxes badged "P4", "P5" and
-- "P6" under the subtitle "Fills in as each module is built", driven by a
-- hardcoded array of six literals in the page file. It was the only place in the
-- product where invented data reached the screen, and every one of those phases
-- shipped months ago.
--
-- Spec §11 makes Customer 360 mandatory, and the data has existed the whole
-- time — scattered across /customers/ledger, /customers/vehicles,
-- /customers/service and the sales, booking and finance lists filtered by
-- customer. What was missing was one query that answers "what is this customer
-- to us" in a single round trip.
--
-- ── On the outstanding figure ───────────────────────────────────────────────
--
-- Taken from the journal lines carrying this customer as the party, not from
-- summing invoices and subtracting receipts. Those two can disagree — a credit
-- note, an opening balance, a manual journal — and when they do the ledger is
-- right. A customer page that quotes a different balance from the customer
-- ledger screen is worse than one that quotes none.
--
-- Rollback: drop function public.customer_360(uuid);
-- =============================================================================

create or replace function public.customer_360(p_customer_id uuid)
returns table (
  booking_count      bigint,
  booking_advance    numeric(18, 4),
  sale_count         bigint,
  sale_value         numeric(18, 4),
  paid_amount        numeric(18, 4),
  outstanding        numeric(18, 4),
  finance_count      bigint,
  finance_amount     numeric(18, 4),
  service_count      bigint,
  service_value      numeric(18, 4),
  vehicle_count      bigint,
  last_activity      date
)
language sql
stable
as $$
  with c as (
    select id, dealer_id from public.customers where id = p_customer_id
  )
  select
    (select count(*) from public.bookings b
      where b.customer_id = p_customer_id and b.status <> 'CANCELLED'),
    (select coalesce(sum(b.received_amount), 0) from public.bookings b
      where b.customer_id = p_customer_id and b.status <> 'CANCELLED'),

    (select count(*) from public.sales s
      where s.customer_id = p_customer_id and s.status not in ('CANCELLED', 'RETURNED')),
    (select coalesce(sum(s.total_amount), 0) from public.sales s
      where s.customer_id = p_customer_id and s.status not in ('CANCELLED', 'RETURNED')),

    (select coalesce(sum(p.amount), 0) from public.sale_payments p
      join public.sales s on s.id = p.sale_id
     where s.customer_id = p_customer_id),

    -- The ledger's answer, not arithmetic over documents. See the header.
    (select public.party_ledger_opening('CUSTOMER', p_customer_id, 'infinity'::date)),

    (select count(*) from public.finance_applications f
      where f.customer_id = p_customer_id and f.approval_status <> 'CANCELLED'),
    (select coalesce(sum(coalesce(f.approved_amount, f.loan_amount)), 0)
       from public.finance_applications f
      where f.customer_id = p_customer_id and f.approval_status <> 'CANCELLED'),

    (select count(*) from public.service_invoices si
      where si.customer_id = p_customer_id and si.status = 'POSTED'),
    (select coalesce(sum(si.total_amount), 0) from public.service_invoices si
      where si.customer_id = p_customer_id and si.status = 'POSTED'),

    (select count(*) from public.customer_vehicles cv where cv.customer_id = p_customer_id),

    -- The most recent thing that happened, whichever kind it was: the one date
    -- that answers "are they still a customer".
    (select max(d) from (
        select max(s.invoice_date)  as d from public.sales s where s.customer_id = p_customer_id
        union all
        select max(b.booking_date)      from public.bookings b where b.customer_id = p_customer_id
        union all
        select max(si.invoice_date)     from public.service_invoices si where si.customer_id = p_customer_id
     ) latest)
  from c;
$$;

comment on function public.customer_360(uuid) is
  'One round trip behind the Customer 360 panel (spec §11): bookings, sales, '
  'payments, outstanding, finance, service and vehicles. Outstanding comes from '
  'the party ledger rather than from summing documents, so it cannot disagree '
  'with the customer ledger screen.';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  execute 'grant execute on function public.customer_360(uuid) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0065', 'customer_360') on conflict (version) do nothing;
