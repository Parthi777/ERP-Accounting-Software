-- =============================================================================
-- 0050 — Bill-wise settlement: splitting a receipt across the bills it pays
-- =============================================================================
-- Spec §11, §21, §22, §23, §41, §49, §50, §60.24.
--
-- What is missing today. A cashier takes ₹50,000 from a customer and records it
-- through the cash book. That posts one credit to the customer's account, and
-- the customer ledger then shows a column of invoices on the debit side and a
-- column of receipts on the credit side with nothing connecting them. The
-- closing balance is right — it has always been right, it comes from the general
-- ledger — but the balance is the only thing the ledger can answer. It cannot say
-- WHICH invoices are still unpaid, which is the question a dealer actually asks
-- when they ring a customer.
--
-- That connection is the accountant's job, and it is a real step in the day's
-- procedure: the cashier records the money as it arrives, and Accounts then
-- allocates it against the bills it settles. This migration gives that step a
-- place to be recorded.
--
-- ── The design ──────────────────────────────────────────────────────────────
--
-- An allocation joins two JOURNAL LINES, not two business documents:
--
--     debit line (a bill)  ←── amount ──→  credit line (a receipt)
--
-- Everything that can ever reach a party ledger is already a party-tagged
-- journal line — a vehicle invoice, a service bill, a counter sale, a booking
-- advance, a cash receipt, a bank receipt, an opening balance, a hand-written
-- journal. Settling at line level therefore covers all of them without this
-- table ever learning what a sale or a job card is, and — the property that
-- matters — it settles against the exact rows the ledger is drawn from. So:
--
--     Σ unpaid bills  −  Σ unapplied receipts  =  the ledger closing balance
--
-- holds by construction rather than by reconciliation. That identity is what
-- "tallying the ledger" means here, and public.party_open_items() below returns
-- the two sides of it.
--
-- A credit may be knocked off against a debit in a different control account on
-- purpose: a booking advance sits in 2100 (Customer Advances) and the invoice it
-- pays for sits in 1200 (Customer Receivable). Refusing that would make the
-- commonest case in the business unrecordable.
--
-- ── What this does NOT do ───────────────────────────────────────────────────
--
-- It posts nothing. No journal is written, amended or reversed; posted entries
-- stay immutable (spec §23, §60.12, §60.23). An allocation is a statement about
-- entries that already exist, so getting one wrong costs nothing but re-doing
-- it, and no accounting figure anywhere moves when it changes.
--
-- Rollback: drop function public.allocate_party_payment(uuid, jsonb, text);
--           drop function public.party_open_items(text, uuid, boolean);
--           drop table public.party_allocations;
--           drop function app.party_allocations_guard();
--           alter table public.journal_entry_lines drop constraint jel_id_dealer_key;
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A journal line becomes addressable by a composite tenant key
-- -----------------------------------------------------------------------------
-- Every table in this schema that points at another carries (id, dealer_id)
-- rather than id alone, so a foreign key cannot cross a tenant boundary even if
-- the application asks it to. journal_entry_lines had never been the target of
-- one and so never needed the key; it is one now.
-- -----------------------------------------------------------------------------
alter table public.journal_entry_lines
  add constraint jel_id_dealer_key unique (id, dealer_id);

-- -----------------------------------------------------------------------------
-- party_allocations — which receipt paid which bill, and how much of it
-- -----------------------------------------------------------------------------
create table public.party_allocations (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null references public.dealers (id) on delete restrict,

  -- Denormalised from the two lines so the common query — "everything for this
  -- customer" — is one index lookup rather than a join through the journal. The
  -- guard below refuses any row where these disagree with the lines.
  party_type     text not null,
  party_id       uuid not null,

  -- The bill being settled, and the money settling it.
  debit_line_id  uuid not null,
  credit_line_id uuid not null,

  amount         numeric(18, 4) not null,

  note           text,

  created_at     timestamptz not null default now(),
  created_by     uuid,

  -- One link per pair. A second allocation between the same bill and the same
  -- receipt is not a second fact, it is the first one written twice (spec §50).
  constraint party_allocations_pair_key unique (debit_line_id, credit_line_id),

  constraint party_allocations_debit_tenant_fkey
    foreign key (debit_line_id, dealer_id)
    references public.journal_entry_lines (id, dealer_id) on delete cascade,
  constraint party_allocations_credit_tenant_fkey
    foreign key (credit_line_id, dealer_id)
    references public.journal_entry_lines (id, dealer_id) on delete cascade,

  constraint party_allocations_amount_check check (amount > 0),
  constraint party_allocations_distinct_lines_check check (debit_line_id <> credit_line_id),
  constraint party_allocations_party_type_check check (
    party_type in ('CUSTOMER', 'SUPPLIER', 'FINANCE_COMPANY', 'EMPLOYEE')
  )
);

comment on table public.party_allocations is
  'Bill-wise settlement (spec §41): links a credit journal line to the debit '
  'lines it pays. Posts nothing — journals stay immutable (spec §23) — so the '
  'subsidiary ledger keeps its balance and gains the detail behind it.';
comment on column public.party_allocations.party_type is
  'Copied from both lines and verified against them by app.party_allocations_guard().';

create index party_allocations_party_idx
  on public.party_allocations (dealer_id, party_type, party_id);
create index party_allocations_debit_idx  on public.party_allocations (debit_line_id);
create index party_allocations_credit_idx on public.party_allocations (credit_line_id);

-- The cash and bank books have always been reachable from a transaction to its
-- journal and never the other way round. party_open_items() below needs the
-- reverse, to put the cashier's own slip number on the row.
create index if not exists cash_transactions_journal_idx
  on public.cash_transactions (journal_entry_id) where journal_entry_id is not null;
create index if not exists bank_transactions_journal_idx
  on public.bank_transactions (journal_entry_id) where journal_entry_id is not null;

-- -----------------------------------------------------------------------------
-- app.party_allocations_guard() — the rules an allocation has to obey
-- -----------------------------------------------------------------------------
-- Five of them, and every one is a way an allocation could otherwise make the
-- ledger lie:
--
--   1. the bill side is a debit line and the payment side is a credit line;
--   2. both belong to the same party as the allocation claims;
--   3. both belong to entries that are actually in the ledger;
--   4. a bill cannot be settled for more than it is worth;
--   5. a receipt cannot be spread over more than it was.
--
-- SECURITY DEFINER so it can lock the two lines regardless of the caller's RLS
-- view of them; because it therefore bypasses RLS, it verifies the tenant of
-- every row it reads rather than assuming a policy already did.
-- -----------------------------------------------------------------------------
create or replace function app.party_allocations_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_debit    record;
  v_credit   record;
  v_taken    numeric(18, 4);
  v_headroom numeric(18, 4);
begin
  -- FOR UPDATE, not a plain read. Two accountants splitting two different
  -- receipts against the same invoice would otherwise both see the same
  -- headroom and both pass check 4, leaving the bill over-settled (spec §49).
  -- The lock is taken on the bill first and the receipt second, in that order,
  -- by every path into this table — so two concurrent splits queue rather than
  -- deadlock.
  select l.dealer_id, l.debit, l.credit, l.party_type, l.party_id,
         je.status, je.entry_number
    into v_debit
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.id = new.debit_line_id
     for no key update of l;

  if not found then
    raise exception 'The bill being settled no longer exists.'
      using errcode = 'no_data_found';
  end if;

  select l.dealer_id, l.debit, l.credit, l.party_type, l.party_id,
         je.status, je.entry_number
    into v_credit
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.id = new.credit_line_id
     for no key update of l;

  if not found then
    raise exception 'The receipt being split no longer exists.'
      using errcode = 'no_data_found';
  end if;

  -- 1. Sides. A journal line is one-sided by constraint, so this also rules out
  --    settling a bill with a bill or a receipt with a receipt.
  if v_debit.debit <= 0 then
    raise exception 'Entry % is not a bill: only a debit can be settled.', v_debit.entry_number
      using errcode = 'check_violation';
  end if;
  if v_credit.credit <= 0 then
    raise exception 'Entry % is not a payment: only a credit can settle a bill.', v_credit.entry_number
      using errcode = 'check_violation';
  end if;

  -- 2. Party, and with it the tenant. A split that reached across two customers
  --    would settle one person's bill with another person's money and leave
  --    both ledgers wrong.
  if v_debit.dealer_id <> new.dealer_id or v_credit.dealer_id <> new.dealer_id then
    raise exception 'A settlement cannot cross dealers.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_debit.party_type is distinct from new.party_type
     or v_debit.party_id is distinct from new.party_id
     or v_credit.party_type is distinct from new.party_type
     or v_credit.party_id is distinct from new.party_id then
    raise exception 'A payment can only be set against the same party''s own bills.'
      using errcode = 'check_violation';
  end if;

  -- 3. In the ledger. Both statuses are accepted because both are what
  --    public.party_ledger() reads: a reversed entry and its reversal are
  --    still on the statement, netting to nothing.
  if v_debit.status not in ('POSTED', 'REVERSED')
     or v_credit.status not in ('POSTED', 'REVERSED') then
    raise exception 'Only posted entries can be settled against each other.'
      using errcode = 'check_violation';
  end if;

  -- 4. The bill's remaining headroom.
  select coalesce(sum(a.amount), 0) into v_taken
    from public.party_allocations a
   where a.debit_line_id = new.debit_line_id
     and a.id <> new.id;

  v_headroom := round(v_debit.debit - v_taken, 4);
  if round(new.amount, 4) > v_headroom then
    raise exception 'Bill % has only % left to settle; % was allocated to it.',
      v_debit.entry_number, v_headroom, new.amount
      using errcode = 'check_violation';
  end if;

  -- 5. The receipt's remaining headroom.
  select coalesce(sum(a.amount), 0) into v_taken
    from public.party_allocations a
   where a.credit_line_id = new.credit_line_id
     and a.id <> new.id;

  v_headroom := round(v_credit.credit - v_taken, 4);
  if round(new.amount, 4) > v_headroom then
    raise exception 'Payment % has only % left to allocate; % was set against a bill.',
      v_credit.entry_number, v_headroom, new.amount
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

comment on function app.party_allocations_guard() is
  'Refuses any settlement that would make a party ledger disagree with itself: '
  'wrong side, wrong party, unposted entry, over-settled bill, over-spread payment.';

create trigger party_allocations_guard
  before insert or update on public.party_allocations
  for each row execute function app.party_allocations_guard();

create trigger party_allocations_audit
  after insert or update or delete on public.party_allocations
  for each row execute function app.audit_trigger();

-- -----------------------------------------------------------------------------
-- Row Level Security
-- -----------------------------------------------------------------------------
-- Reading a settlement is part of reading the ledger, so it follows the same
-- permissions the two ledgers do. Writing one is an accounting act and has a
-- permission of its own: a cashier records the money, Accounts decides what it
-- pays for (spec §6).
-- -----------------------------------------------------------------------------
alter table public.party_allocations enable row level security;

create policy party_allocations_select on public.party_allocations
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and (app.has_permission('accounting.ledgers.view')
             or app.has_permission('customers.view_ledger')
             or app.has_permission('masters.suppliers.view')))
  );

create policy party_allocations_insert on public.party_allocations
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.has_permission('accounting.allocations.manage'))
  );

-- Deletable, unlike almost everything else in this schema. An allocation is not
-- an accounting entry — nothing was posted and nothing is reversed by removing
-- one — so the correction mechanism for a wrong split is to unpick it, and the
-- audit trigger above records that it happened.
create policy party_allocations_delete on public.party_allocations
  for delete to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.has_permission('accounting.allocations.manage'))
  );

-- No UPDATE policy: public.allocate_party_payment() rewrites a receipt's split
-- wholesale, which keeps "what is this receipt against" a single decision rather
-- than a set of rows edited one at a time.

-- -----------------------------------------------------------------------------
-- public.party_open_items() — the two sides of the tally
-- -----------------------------------------------------------------------------
-- Every party-tagged line, with how much of it has been settled. Invoker-rights,
-- exactly like public.party_ledger(), so this view and the statement can never
-- show a user two different sets of rows.
-- -----------------------------------------------------------------------------
create or replace function public.party_open_items(
  p_party_type      text,
  p_party_id        uuid,
  p_include_settled boolean default false
)
returns table (
  line_id       uuid,
  entry_id      uuid,
  entry_date    date,
  entry_number  text,
  document_type text,
  document_ref  text,
  account_code  text,
  account_name  text,
  particulars   text,
  side          text,
  amount        numeric(18, 4),
  allocated     numeric(18, 4),
  outstanding   numeric(18, 4),
  age_days      integer
)
language sql
stable
as $$
  select l.id,
         je.id,
         je.entry_date,
         je.entry_number,
         je.source_document_type,
         -- The dealer knows this bill as "INV-2026-000042", not as the journal
         -- number the posting engine gave it. The cash and bank cases look the
         -- document up by journal rather than by id, because those two modules
         -- record the movement in their own book and leave source_document_id
         -- null — and a receipt the cashier can find by its slip number is the
         -- whole point of this screen. Falls back to the entry number for
         -- anything with no business document behind it — an opening balance, a
         -- manual journal — and for documents this user may not read.
         coalesce(
           case je.source_document_type
             when 'SALE' then
               (select s.invoice_number from public.sales s where s.id = je.source_document_id)
             when 'SERVICE_INVOICE' then
               (select si.invoice_number from public.service_invoices si where si.id = je.source_document_id)
             when 'BOOKING' then
               (select b.booking_number from public.bookings b where b.id = je.source_document_id)
             when 'CASH_BOOK' then
               (select ct.reference_number from public.cash_transactions ct
                 where ct.journal_entry_id = je.id and ct.reference_number is not null limit 1)
             when 'BANK_BOOK' then
               (select bt.reference_number from public.bank_transactions bt
                 where bt.journal_entry_id = je.id and bt.reference_number is not null limit 1)
           end,
           je.entry_number
         ),
         coa.code,
         coa.name,
         coalesce(l.narration, je.narration),
         case when l.debit > 0 then 'DEBIT' else 'CREDIT' end,
         greatest(l.debit, l.credit),
         coalesce(a.allocated, 0),
         round(greatest(l.debit, l.credit) - coalesce(a.allocated, 0), 4),
         (current_date - je.entry_date)::integer
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
    join public.chart_of_accounts coa on coa.id = l.account_id
    left join lateral (
      -- A line is one-sided, so at most one of the two columns can match it.
      select sum(pa.amount) as allocated
        from public.party_allocations pa
       where pa.debit_line_id = l.id or pa.credit_line_id = l.id
    ) a on true
   where l.party_type = p_party_type
     and l.party_id = p_party_id
     and je.status in ('POSTED', 'REVERSED')
     and (p_include_settled
          or round(greatest(l.debit, l.credit) - coalesce(a.allocated, 0), 4) <> 0)
   order by je.entry_date, je.entry_number, l.line_number;
$$;

comment on function public.party_open_items(text, uuid, boolean) is
  'Bills and payments with their settled and unsettled portions (spec §41). '
  'Unpaid bills less unapplied payments equals the ledger closing balance.';

-- -----------------------------------------------------------------------------
-- public.allocate_party_payment() — record how one payment was split
-- -----------------------------------------------------------------------------
-- Takes the whole split for one payment, not one line of it:
--
--   [{"debit_line_id": "…", "amount": 12000}, {"debit_line_id": "…", "amount": 8000}]
--
-- Replacing the set rather than appending to it makes the call idempotent — the
-- same submission twice leaves the same rows (spec §50) — and makes "what is
-- this receipt against" one decision the accountant can revise as a whole. An
-- empty array clears the split and returns the money to unapplied.
-- -----------------------------------------------------------------------------
create or replace function public.allocate_party_payment(
  p_credit_line_id uuid,
  p_allocations    jsonb default '[]'::jsonb,
  p_note           text default null
)
returns table (allocated numeric(18, 4), unapplied numeric(18, 4), bills integer)
language plpgsql
as $$
declare
  v_line  record;
  v_alloc record;
  v_count integer := 0;
  v_total numeric(18, 4) := 0;
begin
  if jsonb_typeof(p_allocations) <> 'array' then
    raise exception 'The split must be a list of bills and amounts.'
      using errcode = 'invalid_parameter_value';
  end if;

  select l.dealer_id, l.credit, l.party_type, l.party_id, je.status, je.entry_number
    into v_line
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.id = p_credit_line_id;

  -- Not found also covers "exists but this user may not read it": RLS makes the
  -- two indistinguishable here, which is the intent.
  if not found then
    raise exception 'That payment could not be found.' using errcode = 'no_data_found';
  end if;
  if v_line.credit <= 0 then
    raise exception 'Entry % is not a payment; only money received can be split.', v_line.entry_number
      using errcode = 'check_violation';
  end if;
  if v_line.party_type is null then
    raise exception 'Entry % is not attributed to a customer or supplier, so there is nothing to settle.',
      v_line.entry_number using errcode = 'check_violation';
  end if;

  -- The previous split goes first, so the headroom checks in the guard see the
  -- world as it will be and a re-submission of the same split is not read as a
  -- doubling of it.
  delete from public.party_allocations where credit_line_id = p_credit_line_id;

  for v_alloc in
    select (e ->> 'debit_line_id')::uuid as debit_line_id,
           round(sum((e ->> 'amount')::numeric), 4) as amount
      from jsonb_array_elements(p_allocations) e
     where nullif(e ->> 'debit_line_id', '') is not null
     group by 1
    having round(sum((e ->> 'amount')::numeric), 4) > 0
  loop
    insert into public.party_allocations
      (dealer_id, party_type, party_id, debit_line_id, credit_line_id, amount, note, created_by)
    values
      (v_line.dealer_id, v_line.party_type, v_line.party_id,
       v_alloc.debit_line_id, p_credit_line_id, v_alloc.amount,
       nullif(btrim(p_note), ''), auth.uid());

    v_count := v_count + 1;
    v_total := v_total + v_alloc.amount;
  end loop;

  allocated := v_total;
  unapplied := round(v_line.credit - v_total, 4);
  bills     := v_count;
  return next;
end;
$$;

comment on function public.allocate_party_payment(uuid, jsonb, text) is
  'Records the whole of one payment''s bill-wise split, replacing any earlier '
  'one (spec §41, §50). Writes no journal: posted entries are immutable (spec §23).';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, delete on public.party_allocations to authenticated';
    execute 'grant all on public.party_allocations to service_role';
    execute 'grant execute on function public.party_open_items(text, uuid, boolean) to authenticated';
    execute 'grant execute on function public.allocate_party_payment(uuid, jsonb, text) to authenticated';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- The permission that gates the split
-- -----------------------------------------------------------------------------
-- Inserted here as well as in seed.sql so a database that is upgraded rather
-- than re-seeded gains it, and so the ACCOUNTS and DEALER_OWNER roles — which
-- are granted the accounting module wholesale — pick it up.
-- -----------------------------------------------------------------------------
insert into public.permissions (code, module, description, is_sensitive) values
  ('accounting.allocations.manage', 'accounting',
   'Split payments against bills and settle party ledgers', false)
on conflict (code) do update
  set module      = excluded.module,
      description = excluded.description;

insert into public.role_permissions (role_id, permission_code)
select r.id, 'accounting.allocations.manage'
  from public.roles r
 where r.is_system and r.code in ('DEALER_OWNER', 'ACCOUNTS')
on conflict do nothing;
