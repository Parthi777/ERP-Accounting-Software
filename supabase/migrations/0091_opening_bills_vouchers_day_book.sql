-- =============================================================================
-- 0091 — Bill-wise opening balances, split vouchers, the day book, narrations
-- =============================================================================
-- From the BUSY requirements review (docs/accounting-feature-gap-analysis.md):
--
-- F12  A party's opening balance is a set of bills, not one figure. Each bill
--      keeps its number, date and due date so it can be settled and aged on
--      its own — "₹1,00,000 payable" is really three invoices of different
--      ages, and the payment made next week is against one of them.
-- F24  One cash or bank payment split over several heads — fuel, tea and
--      courier out of one petty-cash voucher — is one book row and one journal.
-- F32  The day book: every voucher of a day, with its lines, and each branch's
--      cash position for that day.
-- F13  Reusable narrations per voucher type.
--
-- ── Opening bills ───────────────────────────────────────────────────────────
--
-- Posted journal lines are immutable (0007), and the posting engine takes no
-- bill fields, so a bill's number and dates live beside its line in
-- opening_bills (one row per line). post_opening_bills() posts the lines and
-- writes the rows in one transaction. party_open_items() and party_ageing()
-- read the bill number and date from there when present; nothing else about
-- them changes, so every other open item reads exactly as before.
--
-- ── Split vouchers ──────────────────────────────────────────────────────────
--
-- record_money_voucher() is record_cash_transaction / record_bank_transaction
-- with N counter lines. It writes one book row (so the cash book and its day
-- close see one voucher) and one balanced journal, with the same idempotency
-- keys, source types and permission path as the single-line functions. The
-- book row names a customer or supplier only when every line is that party's.
--
-- Rollback: drop the functions and tables added here and restore
--           party_open_items / party_ageing from 0050 / 0080.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Opening bills
-- -----------------------------------------------------------------------------
create table public.opening_bills (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null references public.dealers (id) on delete restrict,
  party_type     text not null,
  party_id       uuid not null,
  line_id        uuid not null,
  bill_reference text not null,
  bill_date      date not null,
  due_date       date,
  created_at     timestamptz not null default now(),
  created_by     uuid,

  constraint opening_bills_line_key unique (line_id),
  constraint opening_bills_party_ref_key unique (dealer_id, party_type, party_id, bill_reference),
  constraint opening_bills_line_tenant_fkey
    foreign key (line_id, dealer_id) references public.journal_entry_lines (id, dealer_id),
  constraint opening_bills_party_type_check check (party_type in ('CUSTOMER', 'SUPPLIER')),
  constraint opening_bills_ref_check check (length(btrim(bill_reference)) between 1 and 60),
  constraint opening_bills_due_check check (due_date is null or due_date >= bill_date)
);

comment on table public.opening_bills is
  'The bill behind each opening-balance line (spec §41, BUSY F12): number, bill '
  'date and due date, so an opening balance is settled and aged bill by bill.';

create index opening_bills_party_idx on public.opening_bills (dealer_id, party_type, party_id);

alter table public.opening_bills enable row level security;

create policy opening_bills_select on public.opening_bills
  for select to authenticated
  using (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy opening_bills_insert on public.opening_bills
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.journals.post'))
  );

create trigger opening_bills_audit after insert or update or delete on public.opening_bills
  for each row execute function app.audit_trigger();

-- p_rows: [{"party_code": "SUP-0001", "bill_reference": "INV/881", "bill_date":
-- "2026-02-10", "due_date": "2026-03-12", "amount": 40000}, …]. Amount is what
-- the bill still has open, positive. A customer's bill is a debit, a supplier's
-- a credit; the balancing line goes to 3300 Opening Balance Equity.
create function public.post_opening_bills(
  p_party_type      text,
  p_rows            jsonb,
  p_as_on           date default null,
  p_idempotency_key text default null
)
returns table (journal_entry_id uuid, bills integer, total numeric)
language plpgsql
as $$
declare
  v_dealer   uuid := app.current_dealer_id();
  v_branch   uuid;
  v_control  uuid;
  v_equity   uuid;
  v_as_on    date;
  v_row      jsonb;
  v_party    uuid;
  v_code     text;
  v_ref      text;
  v_bill     date;
  v_due      date;
  v_amount   numeric(18, 4);
  v_lines    jsonb := '[]'::jsonb;
  v_meta     jsonb := '[]'::jsonb;
  v_total    numeric(18, 4) := 0;
  v_count    integer := 0;
  v_entry    uuid;
  v_line     record;
  v_key      text := case when p_idempotency_key is null then null else 'opening-bills:' || p_idempotency_key end;
begin
  if v_dealer is null or not app.has_permission('accounting.journals.post') then
    raise exception 'Only the accountant can post opening balances.' using errcode = 'insufficient_privilege';
  end if;
  if p_party_type not in ('CUSTOMER', 'SUPPLIER') then
    raise exception 'Bill-wise opening balances are for CUSTOMER or SUPPLIER, not %.', p_party_type
      using errcode = 'check_violation';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'No bills to post.' using errcode = 'check_violation';
  end if;

  if v_key is not null then
    select je.id into v_entry from public.journal_entries je
     where je.dealer_id = v_dealer and je.idempotency_key = v_key;
    if v_entry is not null then
      select count(*), coalesce(sum(greatest(l.debit, l.credit)), 0) into v_count, v_total
        from public.journal_entry_lines l join public.opening_bills ob on ob.line_id = l.id
       where l.journal_entry_id = v_entry;
      journal_entry_id := v_entry; bills := v_count; total := v_total;
      return next;
      return;
    end if;
  end if;

  v_as_on := coalesce(p_as_on, app.opening_date(v_dealer));
  select id into v_branch from public.branches where dealer_id = v_dealer order by is_head_office desc, code limit 1;
  v_control := case when p_party_type = 'CUSTOMER'
    then app.require_account(v_dealer, 'SALES', 'INVOICE', 'RECEIVABLE', null)
    else app.require_account(v_dealer, 'INVENTORY', 'PURCHASE', 'PAYABLE', null) end;
  select id into v_equity from public.chart_of_accounts where dealer_id = v_dealer and code = '3300';
  if v_equity is null then
    raise exception 'The Opening Balance Equity account (3300) is missing.' using errcode = 'no_data_found';
  end if;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_code := btrim(coalesce(v_row ->> 'party_code', ''));
    v_ref  := btrim(coalesce(v_row ->> 'bill_reference', ''));
    begin
      v_amount := round((v_row ->> 'amount')::numeric, 2);
      v_bill   := (v_row ->> 'bill_date')::date;
      v_due    := nullif(v_row ->> 'due_date', '')::date;
    exception when others then
      raise exception 'Bill % of % has an amount or date that is not valid.', v_ref, v_code
        using errcode = 'check_violation';
    end;

    if v_ref = '' then
      raise exception 'Every bill needs its number (party %).', v_code using errcode = 'check_violation';
    end if;
    if v_amount is null or v_amount <= 0 then
      raise exception 'Bill % of % must have an open amount above zero.', v_ref, v_code using errcode = 'check_violation';
    end if;
    if v_bill is null or v_bill > v_as_on then
      raise exception 'Bill % of % must be dated on or before %.', v_ref, v_code, v_as_on using errcode = 'check_violation';
    end if;
    if v_due is not null and v_due < v_bill then
      raise exception 'Bill % of % is due before it is dated.', v_ref, v_code using errcode = 'check_violation';
    end if;

    if p_party_type = 'CUSTOMER' then
      select id into v_party from public.customers where dealer_id = v_dealer and customer_code = v_code;
    else
      select id into v_party from public.suppliers where dealer_id = v_dealer and supplier_code = v_code;
    end if;
    if v_party is null then
      raise exception 'No % with code %.', lower(p_party_type), v_code using errcode = 'no_data_found';
    end if;
    if exists (select 1 from public.opening_bills
                where dealer_id = v_dealer and party_type = p_party_type and party_id = v_party
                  and bill_reference = v_ref)
       or exists (select 1 from jsonb_array_elements(v_meta) m
                   where m ->> 'party_id' = v_party::text and m ->> 'bill_reference' = v_ref) then
      raise exception 'Bill % of % is already entered.', v_ref, v_code using errcode = 'unique_violation';
    end if;

    v_count := v_count + 1;
    v_total := v_total + v_amount;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', v_control,
      'debit',  case when p_party_type = 'CUSTOMER' then v_amount else 0 end,
      'credit', case when p_party_type = 'SUPPLIER' then v_amount else 0 end,
      'narration', 'Opening bill ' || v_ref,
      'party_type', p_party_type, 'party_id', v_party));
    v_meta := v_meta || jsonb_build_array(jsonb_build_object(
      'line_number', v_count, 'party_id', v_party, 'bill_reference', v_ref,
      'bill_date', v_bill, 'due_date', v_due));
  end loop;

  v_lines := v_lines || jsonb_build_array(jsonb_build_object(
    'account_id', v_equity,
    'debit',  case when p_party_type = 'SUPPLIER' then v_total else 0 end,
    'credit', case when p_party_type = 'CUSTOMER' then v_total else 0 end,
    'narration', 'Opening bills brought forward'));

  v_entry := app.post_journal(
    v_dealer, v_branch, v_as_on, 'OPENING',
    'Opening ' || lower(p_party_type) || ' bills as at ' || to_char(v_as_on, 'DD-MM-YYYY'),
    v_lines, 'OPENING_BALANCE', null, v_key);

  for v_line in
    select l.id, l.line_number from public.journal_entry_lines l
     where l.journal_entry_id = v_entry and l.party_id is not null
  loop
    insert into public.opening_bills
      (dealer_id, party_type, party_id, line_id, bill_reference, bill_date, due_date, created_by)
    select v_dealer, p_party_type, (m ->> 'party_id')::uuid, v_line.id, m ->> 'bill_reference',
           (m ->> 'bill_date')::date, nullif(m ->> 'due_date', '')::date, auth.uid()
      from jsonb_array_elements(v_meta) m
     where (m ->> 'line_number')::int = v_line.line_number;
  end loop;

  journal_entry_id := v_entry; bills := v_count; total := v_total;
  return next;
end;
$$;

comment on function public.post_opening_bills(text, jsonb, date, text) is
  'Posts a party''s opening balance bill by bill against 3300 — each bill a '
  'party-tagged control line with its number, date and due date in '
  'opening_bills — so it can be settled and aged on its own (BUSY F12).';

-- Open items and ageing read an opening bill's number and date (unchanged otherwise).
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
         coalesce(ob.bill_date, je.entry_date),
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
           ob.bill_reference,
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
         (current_date - coalesce(ob.bill_date, je.entry_date))::integer
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
    join public.chart_of_accounts coa on coa.id = l.account_id
    left join public.opening_bills ob on ob.line_id = l.id
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
   order by coalesce(ob.bill_date, je.entry_date), je.entry_number, l.line_number;
$$;

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
    select l.id, l.party_id, coalesce(ob.bill_date, je.entry_date) as entry_date,
           -- Positive = the bill side (what is owed), negative = what settles it.
           case when p_party_type = 'SUPPLIER' then l.credit - l.debit else l.debit - l.credit end as amt
      from public.journal_entry_lines l
      join public.journal_entries je on je.id = l.journal_entry_id
      join public.chart_of_accounts c on c.id = l.account_id
      left join public.opening_bills ob on ob.line_id = l.id
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

-- -----------------------------------------------------------------------------
-- 2. A cash or bank voucher split over several heads
-- -----------------------------------------------------------------------------
-- p_lines: [{"account_id": "…", "amount": 450, "narration": "Fuel",
--            "party_type": "SUPPLIER", "party_id": "…"}, …]
create function public.record_money_voucher(
  p_book            text,
  p_direction       text,
  p_lines           jsonb,
  p_particular      text,
  p_branch_id       uuid default null,
  p_bank_account_id uuid default null,
  p_date            date default current_date,
  p_reference       text default null,
  p_utr             text default null,
  p_instrument      text default null,
  p_idempotency_key text default null
)
returns table (transaction_id bigint, journal_entry_id uuid, balance_after numeric)
language plpgsql
as $$
declare
  v_dealer    uuid;
  v_branch    uuid;
  v_cash      public.cash_accounts;
  v_bank      public.bank_accounts;
  v_money_acc uuid;
  v_line      jsonb;
  v_amount    numeric(18, 4);
  v_total     numeric(18, 4) := 0;
  v_lines     jsonb := '[]'::jsonb;
  v_parties   text[] := '{}';
  v_customer  uuid;
  v_supplier  uuid;
  v_entry     uuid;
  v_txn       bigint;
  v_balance   numeric(18, 4);
  v_count     integer := 0;
begin
  if p_book not in ('CASH', 'BANK') then
    raise exception 'A voucher is written to the CASH or the BANK book.' using errcode = 'check_violation';
  end if;
  if p_direction not in ('RECEIPT', 'PAYMENT') then
    raise exception 'Direction must be RECEIPT or PAYMENT.' using errcode = 'check_violation';
  end if;
  if coalesce(length(btrim(p_particular)), 0) < 2 then
    raise exception 'Say what the voucher is for.' using errcode = 'check_violation';
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Add at least one line.' using errcode = 'check_violation';
  end if;

  if p_book = 'CASH' then
    select dealer_id into v_dealer from public.branches where id = p_branch_id;
    select * into v_cash from public.cash_accounts where branch_id = p_branch_id;
    if v_cash.id is null then
      raise exception 'This branch has no cash account.' using errcode = 'no_data_found';
    end if;
    v_branch := p_branch_id;
    v_money_acc := v_cash.ledger_account_id;
  else
    select * into v_bank from public.bank_accounts where id = p_bank_account_id;
    if v_bank.id is null then
      raise exception 'Bank account not found.' using errcode = 'no_data_found';
    end if;
    v_dealer := v_bank.dealer_id;
    v_branch := v_bank.branch_id;
    v_money_acc := v_bank.ledger_account_id;
  end if;

  -- A replay returns what the first call wrote.
  if p_idempotency_key is not null then
    if p_book = 'CASH' then
      select t.id, t.journal_entry_id, t.balance_after into v_txn, v_entry, v_balance
        from public.cash_transactions t where t.dealer_id = v_dealer and t.idempotency_key = p_idempotency_key;
    else
      select t.id, t.journal_entry_id, t.balance_after into v_txn, v_entry, v_balance
        from public.bank_transactions t where t.dealer_id = v_dealer and t.idempotency_key = p_idempotency_key;
    end if;
    if v_txn is not null then
      transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
      return next;
      return;
    end if;
  end if;

  if p_book = 'BANK' and v_bank.status <> 'ACTIVE' then
    raise exception 'Bank account % is %.', v_bank.name, v_bank.status using errcode = 'check_violation';
  end if;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_count := v_count + 1;
    begin
      v_amount := round((v_line ->> 'amount')::numeric, 2);
    exception when others then
      raise exception 'Line %: the amount is not a number.', v_count using errcode = 'check_violation';
    end;
    if v_amount is null or v_amount <= 0 then
      raise exception 'Line %: the amount must be greater than zero.', v_count using errcode = 'check_violation';
    end if;
    if nullif(v_line ->> 'account_id', '') is null then
      raise exception 'Line %: choose the account.', v_count using errcode = 'check_violation';
    end if;
    if app.is_money_ledger(v_dealer, (v_line ->> 'account_id')::uuid) then
      raise exception 'Line %: cash or bank on the other side is a Contra voucher, not a payment or receipt.', v_count
        using errcode = 'check_violation';
    end if;
    if nullif(v_line ->> 'party_type', '') is not null
       and v_line ->> 'party_type' not in ('CUSTOMER', 'SUPPLIER', 'FINANCE_COMPANY', 'EMPLOYEE') then
      raise exception 'Line %: unknown party type %.', v_count, v_line ->> 'party_type' using errcode = 'check_violation';
    end if;

    v_total := v_total + v_amount;
    v_parties := v_parties || coalesce((v_line ->> 'party_type') || ':' || (v_line ->> 'party_id'), '-');
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', v_line ->> 'account_id',
      'debit',  case when p_direction = 'PAYMENT' then v_amount else 0 end,
      'credit', case when p_direction = 'RECEIPT' then v_amount else 0 end,
      'narration', coalesce(nullif(btrim(v_line ->> 'narration'), ''), p_particular),
      'party_type', nullif(v_line ->> 'party_type', ''),
      'party_id', nullif(v_line ->> 'party_id', '')));
  end loop;

  -- The money side, one line for the whole voucher.
  v_lines := case when p_direction = 'RECEIPT'
    then jsonb_build_array(jsonb_build_object('account_id', v_money_acc, 'debit', v_total, 'credit', 0,
                                              'narration', p_particular)) || v_lines
    else v_lines || jsonb_build_array(jsonb_build_object('account_id', v_money_acc, 'debit', 0, 'credit', v_total,
                                                         'narration', p_particular)) end;

  -- The book row names the party only when every line is that one party's.
  if (select count(distinct p) from unnest(v_parties) p) = 1 then
    if v_parties[1] like 'CUSTOMER:%' then v_customer := split_part(v_parties[1], ':', 2)::uuid; end if;
    if v_parties[1] like 'SUPPLIER:%' then v_supplier := split_part(v_parties[1], ':', 2)::uuid; end if;
  end if;

  if p_book = 'CASH' then
    perform public.ensure_cash_day(v_branch, p_date);
    v_entry := app.post_journal(
      v_dealer, v_branch, p_date, 'CASH', p_particular, v_lines, 'CASH_BOOK', null,
      case when p_idempotency_key is null then null else 'cash:' || p_idempotency_key end);
    insert into public.cash_transactions
      (dealer_id, branch_id, cash_account_id, business_date, direction, amount,
       particular, reference_number, customer_id, supplier_id, journal_entry_id,
       idempotency_key, created_by)
    values
      (v_dealer, v_branch, v_cash.id, p_date, p_direction, v_total,
       p_particular, nullif(btrim(p_reference), ''), v_customer, v_supplier, v_entry,
       p_idempotency_key, auth.uid())
    returning id, cash_transactions.balance_after into v_txn, v_balance;
  else
    v_entry := app.post_journal(
      v_dealer, v_branch, p_date, 'BANK', p_particular, v_lines, 'BANK_BOOK', null,
      case when p_idempotency_key is null then null else 'bank:' || p_idempotency_key end);
    insert into public.bank_transactions
      (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
       reference_number, utr, instrument_number, customer_id, supplier_id,
       journal_entry_id, idempotency_key, created_by)
    values
      (v_dealer, p_bank_account_id, p_date, p_direction, v_total, p_particular,
       nullif(btrim(p_reference), ''), nullif(btrim(p_utr), ''), nullif(btrim(p_instrument), ''),
       v_customer, v_supplier, v_entry, p_idempotency_key, auth.uid())
    returning id, bank_transactions.balance_after into v_txn, v_balance;
  end if;

  transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
  return next;
end;
$$;

comment on function public.record_money_voucher(text, text, jsonb, text, uuid, uuid, date, text, text, text, text) is
  'A cash or bank receipt/payment split over several accounts: one book row, one '
  'balanced journal, idempotent like record_cash_transaction (BUSY F24).';

-- -----------------------------------------------------------------------------
-- 3. The day book
-- -----------------------------------------------------------------------------
create function public.day_book(p_date date, p_branch_id uuid default null)
returns table (
  entry_id      uuid,
  entry_number  text,
  entry_time    timestamptz,
  document_type text,
  document_ref  text,
  narration     text,
  status        text,
  branch_name   text,
  line_number   integer,
  account_code  text,
  account_name  text,
  party_name    text,
  line_narration text,
  debit         numeric(18, 4),
  credit        numeric(18, 4)
)
language sql
stable
as $$
  select je.id, je.entry_number, je.created_at, je.source_document_type,
         coalesce(
           case je.source_document_type
             when 'SALE' then (select s.invoice_number from public.sales s where s.id = je.source_document_id)
             when 'SERVICE_INVOICE' then (select si.invoice_number from public.service_invoices si where si.id = je.source_document_id)
             when 'BOOKING' then (select b.booking_number from public.bookings b where b.id = je.source_document_id)
             when 'CASH_BOOK' then (select ct.reference_number from public.cash_transactions ct
                                     where ct.journal_entry_id = je.id and ct.reference_number is not null limit 1)
             when 'BANK_BOOK' then (select bt.reference_number from public.bank_transactions bt
                                     where bt.journal_entry_id = je.id and bt.reference_number is not null limit 1)
           end, je.entry_number),
         je.narration, je.status, b.name,
         l.line_number, c.code, c.name,
         case l.party_type
           when 'CUSTOMER' then (select name from public.customers where id = l.party_id)
           when 'SUPPLIER' then (select name from public.suppliers where id = l.party_id)
           when 'FINANCE_COMPANY' then (select name from public.finance_companies where id = l.party_id)
           when 'EMPLOYEE' then (select e.name from public.employees e where e.id = l.party_id)
         end,
         l.narration, l.debit, l.credit
    from public.journal_entries je
    join public.journal_entry_lines l on l.journal_entry_id = je.id
    join public.chart_of_accounts c on c.id = l.account_id
    left join public.branches b on b.id = je.branch_id
   where je.dealer_id = app.current_dealer_id()
     and je.entry_date = p_date
     and je.status in ('POSTED', 'REVERSED')
     and (p_branch_id is null or je.branch_id = p_branch_id)
   order by je.created_at, je.entry_number, l.line_number;
$$;

comment on function public.day_book(date, uuid) is
  'Every posted voucher of a day with its lines, document number and parties '
  '(BUSY F32). Reads through RLS: a user sees the branches they may.';

-- -----------------------------------------------------------------------------
-- 4. Narration templates
-- -----------------------------------------------------------------------------
create table public.narration_templates (
  id           uuid primary key default gen_random_uuid(),
  dealer_id    uuid not null references public.dealers (id) on delete cascade,
  voucher_type text not null,
  text         text not null,
  status       text not null default 'ACTIVE',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  created_by   uuid,
  updated_by   uuid,

  constraint narration_templates_type_check check (voucher_type in ('PAYMENT', 'RECEIPT', 'JOURNAL', 'CONTRA', 'ANY')),
  constraint narration_templates_text_check check (length(btrim(text)) between 2 and 300),
  constraint narration_templates_status_check check (status in ('ACTIVE', 'INACTIVE')),
  constraint narration_templates_text_key unique (dealer_id, voucher_type, text)
);

comment on table public.narration_templates is
  'Reusable narrations per voucher type (BUSY F13). Picked into a voucher and '
  'still editable there; the posted narration is a copy, not a reference.';

alter table public.narration_templates enable row level security;

create policy narration_templates_select on public.narration_templates
  for select to authenticated
  using (app.is_platform_admin() or dealer_id = app.current_dealer_id());

create policy narration_templates_write on public.narration_templates
  for all to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.settings.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('admin.settings.manage'))
  );

create trigger narration_templates_set_updated_at before update on public.narration_templates
  for each row execute function app.set_updated_at();
create trigger narration_templates_audit after insert or update or delete on public.narration_templates
  for each row execute function app.audit_trigger();

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert on public.opening_bills to authenticated';
    execute 'grant select, insert, update, delete on public.narration_templates to authenticated';
    execute 'grant execute on function public.post_opening_bills(text, jsonb, date, text) to authenticated';
    execute 'grant execute on function public.record_money_voucher(text, text, jsonb, text, uuid, uuid, date, text, text, text, text) to authenticated';
    execute 'grant execute on function public.day_book(date, uuid) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant all on public.opening_bills to service_role';
    execute 'grant all on public.narration_templates to service_role';
  end if;
end $$;

insert into public.schema_migrations (version, name)
values ('0091', 'opening_bills_vouchers_day_book') on conflict (version) do nothing;
