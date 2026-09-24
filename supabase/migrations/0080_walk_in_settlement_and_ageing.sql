-- =============================================================================
-- 0080 — Walk-in sales are settled when they are made, and ageing
-- =============================================================================
-- Spec §33, §41, §43, §50. Audit checklist §04 (allocations, advance and
-- credits, ageing, control tie-out).
--
-- ── A walk-in sale that nobody owes ─────────────────────────────────────────
--
-- The control tie-out (0077), run against production after the 0076–0079
-- deploy, found ₹1,115.10 on 1300 Customer Receivable carrying no customer:
-- counter invoice CSI-2026-000001, a walk-in sale posted on 16 Sep and never
-- paid. A counter sale with no customer posts its receivable untagged, because
-- there is nobody to tag; if the payment is then never recorded, the ledger
-- holds money owed by no one — uncollectable, unchaseable, and invisible on
-- every customer statement.
--
-- The rule a counter works by is that a walk-in pays before leaving; credit is
-- for a named customer. Posting and collecting were two separate steps, so the
-- rule was the cashier's memory. Now:
--
--   * public.settle_counter_invoice() posts a walk-in invoice and takes its
--     payment in full, in one transaction — the screen's single step;
--   * a DEFERRED constraint trigger refuses, at commit, any transaction that
--     leaves a posted walk-in invoice with a balance. Deferred, so the older
--     two-call path (post, then pay, in one transaction) still commits; only
--     "post and walk away" is refused.
--
-- The invoice already on file is not touched. Collecting its payment (in full)
-- clears it, which is what should happen if the money was in fact received.
--
-- ── Ageing ─────────────────────────────────────────────────────────────────
--
-- party_open_items() (0050) gives the open bills of one party with their age.
-- Nothing gave the book: who owes what, and for how long. party_ageing() does,
-- in the usual 0–30 / 31–60 / 61–90 / 90+ buckets:
--
--   * explicit bill-wise allocations (0050) are applied first;
--   * a receipt or payment not allocated to any bill then settles the oldest
--     bills first (FIFO), which is how a customer's lump payment is read in
--     the absence of instructions;
--   * advances sit on a different account (2100 for customers) and are shown in
--     their own column, never netted into the ageing — checklist §04 "not
--     silently netted".
--
-- Ages run from the document date: vehicle and counter invoices carry no due
-- date. An as-on date in the past counts an allocation only if its receipt was
-- dated by then.
--
-- Rollback: drop trigger service_invoices_walk_in_settled on service_invoices;
--           drop functions app.walk_in_settled(), public.settle_counter_invoice,
--           public.party_ageing.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The rule, checked at commit
-- -----------------------------------------------------------------------------
create or replace function app.walk_in_settled()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v public.service_invoices;
begin
  -- The row as it stands at commit, not as this particular event saw it: a
  -- payment later in the same transaction settles it.
  select * into v from public.service_invoices where id = new.id;

  if v.invoice_type = 'COUNTER'
     and v.customer_id is null
     and v.status = 'POSTED'
     and v.paid_amount < v.total_amount then
    raise exception 'Walk-in sale % must be paid in full when it is posted (% outstanding). Take the payment now, or add the customer to sell on credit.',
      v.invoice_number, v.total_amount - v.paid_amount
      using errcode = 'check_violation',
            hint = 'A counter sale with no customer leaves a receivable nobody owes.';
  end if;

  return null;
end;
$$;

create constraint trigger service_invoices_walk_in_settled
  after insert or update of status, paid_amount on public.service_invoices
  deferrable initially deferred
  for each row execute function app.walk_in_settled();

-- -----------------------------------------------------------------------------
-- public.settle_counter_invoice() — post and collect, one step
-- -----------------------------------------------------------------------------
create or replace function public.settle_counter_invoice(
  p_invoice_id      uuid,
  p_payment_mode    text default 'CASH',
  p_reference       text default null,
  p_idempotency_key text default null
)
returns table (journal_entry_id uuid, receipt_number text, amount_received numeric)
language plpgsql
as $$
declare
  v_invoice public.service_invoices;
  v_entry   uuid;
  v_balance numeric(18, 4);
  v_pay     record;
begin
  select * into v_invoice from public.service_invoices where id = p_invoice_id for update;
  if v_invoice.id is null then
    raise exception 'Invoice not found.' using errcode = 'no_data_found';
  end if;
  if v_invoice.invoice_type <> 'COUNTER' then
    raise exception 'Only a counter sale is settled this way; a job-card invoice is collected from the invoice.'
      using errcode = 'check_violation';
  end if;
  if v_invoice.status not in ('DRAFT', 'POSTED') then
    raise exception 'Invoice % is %.', v_invoice.invoice_number, v_invoice.status
      using errcode = 'check_violation';
  end if;

  -- Posting is idempotent: an invoice already posted returns its journal.
  v_entry := public.post_service_invoice(p_invoice_id);

  select si.total_amount - si.paid_amount into v_balance
    from public.service_invoices si where si.id = p_invoice_id;

  if v_balance > 0 then
    select * into v_pay from public.record_service_payment(
      p_invoice_id, v_balance, coalesce(p_payment_mode, 'CASH'), p_reference,
      current_date, p_idempotency_key);
    receipt_number := v_pay.receipt_number;
  else
    -- A retry after everything committed: nothing left to take.
    select sp.receipt_number into receipt_number
      from public.service_payments sp
     where sp.invoice_id = p_invoice_id and sp.status = 'RECEIVED'
     order by sp.created_at desc limit 1;
  end if;

  journal_entry_id := v_entry;
  amount_received := greatest(v_balance, 0);
  return next;
end;
$$;

comment on function public.settle_counter_invoice(uuid, text, text, text) is
  'Posts a counter invoice and collects its whole balance in one transaction '
  '(spec §33). The walk-in rule — paid in full when posted — is enforced by '
  'the deferred trigger service_invoices_walk_in_settled.';

-- -----------------------------------------------------------------------------
-- public.party_ageing() — who owes what, for how long
-- -----------------------------------------------------------------------------
create or replace function public.party_ageing(
  p_party_type text,
  p_as_on      date default current_date
)
returns table (
  party_id          uuid,
  party_name        text,
  balance           numeric(18, 4),
  bucket_0_30       numeric(18, 4),
  bucket_31_60      numeric(18, 4),
  bucket_61_90      numeric(18, 4),
  bucket_90_plus    numeric(18, 4),
  unallocated_credit numeric(18, 4),
  advance_held      numeric(18, 4),
  oldest_open_date  date
)
language sql
stable
as $$
  with params as (
    -- A customer or finance company owes on an asset account; the dealer owes a
    -- supplier on a liability account. The other side is an advance.
    select case when p_party_type = 'SUPPLIER' then 'LIABILITY' else 'ASSET' end as control_type,
           case when p_party_type = 'SUPPLIER' then 'ASSET' else 'LIABILITY' end as advance_type
  ),
  lines as (
    select l.id, l.party_id, je.entry_date,
           -- Positive = the bill side (what is owed), negative = what settles it.
           case when p_party_type = 'SUPPLIER' then l.credit - l.debit else l.debit - l.credit end as amt
      from public.journal_entry_lines l
      join public.journal_entries je on je.id = l.journal_entry_id
      join public.chart_of_accounts c on c.id = l.account_id
      cross join params p
     where l.party_type = p_party_type
       and je.status in ('POSTED', 'REVERSED')
       and je.entry_date <= p_as_on
       and c.account_type = p.control_type
  ),
  alloc as (
    select pa.debit_line_id, pa.credit_line_id, pa.amount
      from public.party_allocations pa
      join lines ld on ld.id = pa.debit_line_id
      join lines lc on lc.id = pa.credit_line_id
  ),
  allocated as (
    select x.id, sum(x.amount) as amt
      from (select debit_line_id as id, amount from alloc
            union all
            select credit_line_id, amount from alloc) x
     group by x.id
  ),
  items as (
    select l.party_id, l.entry_date, l.id, l.amt > 0 as is_bill,
           abs(l.amt) - coalesce(a.amt, 0) as open
      from lines l
      left join allocated a on a.id = l.id
  ),
  credits as (
    select party_id, sum(open) as u from items
     where not is_bill and open > 0 group by party_id
  ),
  bills as (
    select b.party_id, b.entry_date, b.open, coalesce(c.u, 0) as u,
           coalesce(sum(b.open) over (partition by b.party_id order by b.entry_date, b.id
                                      rows between unbounded preceding and 1 preceding), 0) as before
      from items b
      left join credits c on c.party_id = b.party_id
     where b.is_bill and b.open > 0
  ),
  remaining as (
    -- Unallocated credit settles the oldest bills first.
    select party_id, entry_date,
           greatest(0, open - greatest(0, u - before)) as rem
      from bills
  ),
  per_party as (
    select party_id,
           sum(rem) as owed,
           sum(rem) filter (where p_as_on - entry_date <= 30) as b0,
           sum(rem) filter (where p_as_on - entry_date between 31 and 60) as b1,
           sum(rem) filter (where p_as_on - entry_date between 61 and 90) as b2,
           sum(rem) filter (where p_as_on - entry_date > 90) as b3,
           min(entry_date) filter (where rem > 0) as oldest
      from remaining
     group by party_id
  ),
  bill_totals as (
    select party_id, sum(open) as total_open from items where is_bill and open > 0 group by party_id
  ),
  advances as (
    select l.party_id,
           sum(case when p_party_type = 'SUPPLIER' then l.debit - l.credit else l.credit - l.debit end) as held
      from public.journal_entry_lines l
      join public.journal_entries je on je.id = l.journal_entry_id
      join public.chart_of_accounts c on c.id = l.account_id
      cross join params p
     where l.party_type = p_party_type
       and je.status in ('POSTED', 'REVERSED')
       and je.entry_date <= p_as_on
       and c.account_type = p.advance_type
     group by l.party_id
  ),
  parties as (
    select party_id from per_party
    union select party_id from credits
    union select party_id from advances
  ),
  result as (
    select pt.party_id,
           coalesce(pp.owed, 0) as owed,
           coalesce(pp.b0, 0) as b0, coalesce(pp.b1, 0) as b1,
           coalesce(pp.b2, 0) as b2, coalesce(pp.b3, 0) as b3,
           greatest(0, coalesce(c.u, 0) - coalesce(bt.total_open, 0)) as spare,
           coalesce(a.held, 0) as held,
           pp.oldest
      from parties pt
      left join per_party pp on pp.party_id = pt.party_id
      left join credits c on c.party_id = pt.party_id
      left join bill_totals bt on bt.party_id = pt.party_id
      left join advances a on a.party_id = pt.party_id
  )
  select r.party_id,
         coalesce(cu.name, su.name, fc.name, '(unknown party)'),
         r.owed - r.spare,
         r.b0, r.b1, r.b2, r.b3,
         r.spare,
         r.held,
         r.oldest
    from result r
    left join public.customers cu on p_party_type = 'CUSTOMER' and cu.id = r.party_id
    left join public.suppliers su on p_party_type = 'SUPPLIER' and su.id = r.party_id
    left join public.finance_companies fc on p_party_type = 'FINANCE_COMPANY' and fc.id = r.party_id
   where r.owed <> 0 or r.spare <> 0 or r.held <> 0
   order by r.b3 desc, r.b2 desc, r.owed desc;
$$;

comment on function public.party_ageing(text, date) is
  'Receivables or payables ageing (spec §41): open bills after bill-wise '
  'allocation, then oldest-first against unallocated receipts, in 0–30/31–60/'
  '61–90/90+ buckets from the document date. Advances are a separate column, '
  'never netted. SECURITY INVOKER: RLS scopes it to the caller''s dealer.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.settle_counter_invoice(uuid, text, text, text) to authenticated';
    execute 'grant execute on function public.party_ageing(text, date) to authenticated';
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- What is already on file
-- -----------------------------------------------------------------------------
do $$
declare
  v_count integer;
  v_sum   numeric;
begin
  select count(*), coalesce(sum(total_amount - paid_amount), 0) into v_count, v_sum
    from public.service_invoices
   where invoice_type = 'COUNTER' and customer_id is null
     and status = 'POSTED' and paid_amount < total_amount;

  if v_count > 0 then
    raise notice '0080: % posted walk-in sale(s) still unpaid, % outstanding. Collect the payment in full on each (Inventory → Counter Sales) if it was received.', v_count, v_sum;
  end if;
end $$;

insert into public.schema_migrations (version, name)
values ('0080', 'walk_in_settlement_and_ageing') on conflict (version) do nothing;
