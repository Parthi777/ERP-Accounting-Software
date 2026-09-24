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
