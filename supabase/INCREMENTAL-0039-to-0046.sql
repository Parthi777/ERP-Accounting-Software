-- =============================================================================
-- INCREMENTAL 0039 → 0046
-- =============================================================================
-- GENERATED FILE. Regenerate with:
--   FROM=0039 bash scripts/build-incremental.sh
--
-- For a database that ALREADY has migrations up to 0038.
-- Running the full ALL-IN-ONE.sql on such a database fails on the first table
-- that already exists; this contains only what is missing.
--
-- Wrapped in one transaction. If any statement fails the whole thing rolls back
-- and the database is left exactly as it was — there is no half-applied state to
-- clean up, and it is safe to fix the cause and run again.
--
-- Paste into the Supabase SQL Editor and Run.
-- =============================================================================

begin;



-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0039_dealer_wide_document_numbering.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0039 — Dealer-wide document numbering
-- =============================================================================
-- Spec §45, §60.3, §60.5.
--
-- Seven document types still allocate their numbers from *branch-scoped*
-- counters while the tables that store them enforce *dealer-wide* uniqueness:
--
--   sales.invoice_number            sales_invoice_key            (dealer_id, …)
--   bookings.booking_number         bookings_number_key          (dealer_id, …)
--   booking_payments.receipt_number booking_payments_receipt_key (dealer_id, …)
--   sale_payments.receipt_number    sale_payments_receipt_key    (dealer_id, …)
--   service_payments.receipt_number sp_receipt_key               (dealer_id, …)
--   job_cards.job_card_number       jc_number_key                (dealer_id, …)
--   service_invoices.invoice_number si_number_key                (dealer_id, …)
--
-- Every branch's counter starts at 1 and every branch shares the same prefix, so
-- two branches both produce INV-2026-000001 and the second one to try is
-- rejected by the constraint. A single-branch dealer never sees it; a two-branch
-- dealer hits it on the second branch's first document of each type — which is
-- the multi-branch operation spec §60.3 requires to work from day one. 0038 hit
-- exactly this for transfers and deliveries; these are the remaining seven.
--
-- FIXED HERE RATHER THAN AT EACH CALL SITE.
--
-- 0038 fixed its two types by rewriting the functions that issue them to pass a
-- null branch. Repeating that for seven types means copying six large function
-- bodies into this migration — and three of them (record_sale_payment,
-- create_job_card, deliver_vehicle) are rewritten again by later migrations for
-- unrelated reasons. Every one of those rewrites would have to carry this fix
-- forward by hand, and the day one of them does not, the bug returns silently
-- with no test to catch it.
--
-- So the scope decision moves out of the call sites and into the sequence
-- allocator, where it belongs: **the scope of a document series is a property of
-- the document type, recorded in document_sequences, not of the code that asks
-- for a number.** A dealer-wide row, where one is configured, wins over the
-- branch the caller passed. Callers are unchanged and stay correct as they are
-- rewritten in future.
--
-- A type that genuinely wants a per-branch series still gets one: simply do not
-- configure a dealer-wide row for it. Nothing in the schema wants that today.
--
-- Existing numbers are left exactly as issued, and each dealer-wide counter
-- starts above the highest number any of that dealer's branches reached, so no
-- number is ever reissued.
--
-- Rollback: restore app.next_document_number() from 0006 and delete the
--           dealer-wide rows created below from public.document_sequences.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- app.next_document_number() — dealer-wide first, branch second
-- -----------------------------------------------------------------------------
create or replace function app.next_document_number(
  p_dealer_id      uuid,
  p_branch_id      uuid,
  p_doc_type       text,
  p_financial_year text
)
returns text
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_prefix  text;
  v_padding smallint;
  v_number  bigint;
begin
  -- A dealer-wide series, when configured, is authoritative for this type. The
  -- branch the caller passed is still recorded on the document; it simply is not
  -- what allocates the number (spec §45).
  update public.document_sequences ds
     set last_number = ds.last_number + 1
   where ds.dealer_id = p_dealer_id
     and ds.branch_id is null
     and ds.doc_type = p_doc_type
     and ds.financial_year = p_financial_year
  returning ds.prefix, ds.padding, ds.last_number
       into v_prefix, v_padding, v_number;

  if not found then
    update public.document_sequences ds
       set last_number = ds.last_number + 1
     where ds.dealer_id = p_dealer_id
       and ds.branch_id is not distinct from p_branch_id
       and ds.doc_type = p_doc_type
       and ds.financial_year = p_financial_year
    returning ds.prefix, ds.padding, ds.last_number
         into v_prefix, v_padding, v_number;
  end if;

  if not found then
    raise exception
      'No document sequence configured for dealer %, branch %, type %, year %.',
      p_dealer_id, coalesce(p_branch_id::text, '(dealer-wide)'), p_doc_type, p_financial_year
      using errcode = 'no_data_found',
            hint = 'Insert a row into document_sequences before issuing this document type.';
  end if;

  return v_prefix || '-' || p_financial_year || '-' || lpad(v_number::text, v_padding, '0');
end;
$$;

comment on function app.next_document_number(uuid, uuid, text, text) is
  'Returns the next number for a document scope, e.g. INV-2026-000001. '
  'A dealer-wide sequence takes precedence over a branch one, so a series that '
  'must be unique per dealer cannot be allocated from per-branch counters '
  '(spec §45, §60.3). Row-locked, so it is safe under concurrent sales (spec §49).';

-- -----------------------------------------------------------------------------
-- Dealer-wide rows for the seven types, carrying each dealer's highest counter
-- -----------------------------------------------------------------------------
-- Derived from the sequences that already exist rather than from branches, so
-- this covers the dealer / financial-year / prefix combinations actually in use
-- and stays correct for a dealer whose financial year is not the default.
--
-- PAYMENT and COUNTER_INVOICE are included although nothing issues them yet:
-- they are seeded per branch, so they carry the same latent collision and would
-- surface it the day something does.
-- -----------------------------------------------------------------------------
insert into public.document_sequences
  (dealer_id, branch_id, doc_type, financial_year, prefix, padding, last_number)
select ds.dealer_id, null::uuid, ds.doc_type, ds.financial_year, ds.prefix, max(ds.padding),
       max(ds.last_number)
  from public.document_sequences ds
 where ds.branch_id is not null
   and ds.doc_type in ('VEHICLE_INVOICE', 'BOOKING', 'RECEIPT', 'PAYMENT',
                       'JOB_CARD', 'SERVICE_INVOICE', 'COUNTER_INVOICE')
 group by ds.dealer_id, ds.doc_type, ds.financial_year, ds.prefix
on conflict on constraint document_sequences_scope_key do nothing;

-- The branch-scoped rows are left in place but are no longer consulted for these
-- types; dropping them would discard the record of what each branch had issued.

-- -----------------------------------------------------------------------------
-- Sequences for the finance documents built in 0043
-- -----------------------------------------------------------------------------
-- Created here, with the rest of the numbering, so that migration deals only
-- with finance. Dealer-wide from the start: finance_applications.application_number
-- and finance_settlements.settlement_number are both unique per dealer.
-- -----------------------------------------------------------------------------
insert into public.document_sequences
  (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
select distinct ds.dealer_id, null::uuid, d.doc_type, ds.financial_year, d.prefix, 6
  from public.document_sequences ds
 cross join (values ('FINANCE_APPLICATION', 'FA'), ('FINANCE_SETTLEMENT', 'FS')) as d(doc_type, prefix)
 where ds.branch_id is not null
on conflict on constraint document_sequences_scope_key do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0040_suppliers.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0040 — Supplier master
-- =============================================================================
-- Spec §24, §41, §44.
--
-- The chart of accounts has carried "Supplier Payables" (2200) since the first
-- seed, journal_entry_lines.party_type has always accepted 'SUPPLIER', and the
-- CASH/BANK PAYMENT rules post to 2200 — but there has never been a supplier
-- table to point party_id at, so the payable has only ever been a single lump
-- with no subsidiary detail behind it. Spec §41 asks for a supplier ledger; this
-- is the record it needs.
--
-- Dealer-scoped, not branch-scoped: a supplier deals with the dealer, and any
-- branch may buy from them. Modelled on public.customers (0013), including the
-- self-provisioning code trigger — a supplier code is an identifier, not a
-- financial document, so issuing one must never fail for want of configuration.
--
-- Rollback: drop table public.suppliers; drop function app.suppliers_assign_code();
--           delete from public.document_sequences where doc_type = 'SUPPLIER';
-- =============================================================================

create table public.suppliers (
  id                uuid primary key default gen_random_uuid(),
  dealer_id         uuid not null references public.dealers (id) on delete restrict,

  -- Mandatory, dealer-unique, server-issued (spec §60.6, as for customers).
  supplier_code     text not null,

  name              text not null,
  supplier_type     text not null default 'GOODS',

  contact_person    text,
  mobile            text,
  alternate_mobile  text,
  email             text,

  address_line1     text,
  address_line2     text,
  city              text,
  state             text,
  state_code        text,
  pincode           text,

  gstin             text,
  pan               text,

  -- Payment terms, for an ageing view of the payable.
  credit_days       smallint not null default 0,

  notes             text,
  status            text not null default 'ACTIVE',

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid,
  updated_by        uuid,

  constraint suppliers_dealer_code_key unique (dealer_id, supplier_code),
  -- Load-bearing: every composite tenant foreign key that ever points at a
  -- supplier depends on this, exactly as customers_id_dealer_key does.
  constraint suppliers_id_dealer_key   unique (id, dealer_id),

  constraint suppliers_type_check   check (supplier_type in ('GOODS', 'SERVICE', 'OEM')),
  constraint suppliers_status_check check (status in ('ACTIVE', 'INACTIVE', 'BLOCKED')),
  constraint suppliers_name_check   check (length(btrim(name)) between 2 and 150),
  constraint suppliers_mobile_check check (mobile is null or mobile ~ '^[6-9][0-9]{9}$'),
  constraint suppliers_alt_mobile_check check (
    alternate_mobile is null or alternate_mobile ~ '^[6-9][0-9]{9}$'
  ),
  constraint suppliers_email_check check (
    email is null or email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[a-zA-Z]{2,}$'
  ),
  constraint suppliers_gstin_check check (
    gstin is null or gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[0-9A-Z]{1}Z[0-9A-Z]{1}$'
  ),
  constraint suppliers_pan_check     check (pan is null or pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  constraint suppliers_pincode_check check (pincode is null or pincode ~ '^[1-9][0-9]{5}$'),
  constraint suppliers_credit_days_check check (credit_days between 0 and 365)
);

comment on table public.suppliers is
  'Supplier master (spec §41, §44). Dealer-scoped: a supplier serves every branch. '
  'party_id on a journal line tagged party_type = ''SUPPLIER'' points here.';
comment on column public.suppliers.supplier_code is
  'Auto-generated, dealer-unique, issued server-side. Never supplied by the client.';

-- The same GSTIN twice within a dealer is a duplicate record. Enforced only for
-- active suppliers, so a blocked record does not prevent re-registering later.
create unique index suppliers_dealer_gstin_key
  on public.suppliers (dealer_id, gstin)
  where gstin is not null and status = 'ACTIVE';

-- -----------------------------------------------------------------------------
-- Supplier code assignment
-- -----------------------------------------------------------------------------
-- Self-provisioning, like app.customers_assign_code(). A financial document
-- whose sequence is missing should fail loudly; an identifier should not, or a
-- newly provisioned dealer cannot record its first supplier without setup.
-- -----------------------------------------------------------------------------
create or replace function app.suppliers_assign_code()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_year text;
begin
  if new.supplier_code is not null and btrim(new.supplier_code) <> '' then
    return new;  -- an explicit code (data migration) is respected
  end if;

  v_year := app.financial_year_token(new.dealer_id, coalesce(new.created_at::date, current_date));

  insert into public.document_sequences (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
  values (new.dealer_id, null, 'SUPPLIER', v_year, 'SUPP', 6)
  on conflict on constraint document_sequences_scope_key do nothing;

  new.supplier_code := app.next_document_number(new.dealer_id, null, 'SUPPLIER', v_year);
  return new;
end;
$$;

create trigger suppliers_assign_code
  before insert on public.suppliers
  for each row execute function app.suppliers_assign_code();

create trigger suppliers_set_updated_at
  before update on public.suppliers
  for each row execute function app.set_updated_at();

create trigger suppliers_audit
  after insert or update or delete on public.suppliers
  for each row execute function app.audit_trigger();

-- -----------------------------------------------------------------------------
-- Row Level Security
-- -----------------------------------------------------------------------------
alter table public.suppliers enable row level security;

create policy suppliers_select on public.suppliers
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and (app.has_permission('masters.suppliers.view')
             or app.has_permission('accounting.ledgers.view')))
  );

create policy suppliers_insert on public.suppliers
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('masters.suppliers.manage'))
  );

create policy suppliers_update on public.suppliers
  for update to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('masters.suppliers.manage'))
  )
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id() and app.has_permission('masters.suppliers.manage'))
  );

-- No DELETE policy. A supplier with postings behind them must never vanish;
-- set status to INACTIVE or BLOCKED instead.

-- -----------------------------------------------------------------------------
-- Indexes
-- -----------------------------------------------------------------------------
create index suppliers_dealer_name_idx   on public.suppliers (dealer_id, lower(name));
create index suppliers_dealer_status_idx on public.suppliers (dealer_id, status);
create index suppliers_mobile_idx        on public.suppliers (dealer_id, mobile) where mobile is not null;
create index suppliers_created_idx       on public.suppliers (dealer_id, created_at desc);

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.suppliers to authenticated';
    execute 'grant all on public.suppliers to service_role';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0041_party_ledger_and_supplier_payments.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0041 — Party ledger, and supplier tagging on money movements
-- =============================================================================
-- Spec §11, §41.
--
-- Two halves of one problem: a supplier ledger needs a query that can read a
-- party account, and it needs journal lines actually tagged with the supplier.
-- Neither existed. Every writer in the codebase hardcoded party_type='CUSTOMER',
-- so account 2200 (Supplier Payables) has only ever held an undifferentiated
-- total, and no subsidiary ledger could be derived from it.
--
-- 1. The ledger from 0037 is generalised over party type. customer_ledger and
--    customer_ledger_opening become thin wrappers, so everything already calling
--    them — src/server/services/accounting/ledger-service.ts and
--    supabase/test/90_customer_ledger.sql — keeps working untouched, and the two
--    party ledgers can never drift apart because there is only one of them.
--
-- 2. record_cash_transaction and record_bank_transaction learn about suppliers.
--    These are DROPPED and recreated rather than replaced: they gain a
--    parameter, and `create or replace` cannot change a signature. Leaving both
--    signatures in place would create an overload, which makes supabase.rpc()
--    ambiguous at runtime and makes scripts/generate-types.mjs emit the same key
--    twice — a TypeScript error. The old grants die with the old functions and
--    are reissued below.
--
-- Rollback: restore record_cash_transaction from 0030 and record_bank_transaction
--           from 0031 with their grants; drop public.party_ledger,
--           public.party_ledger_opening; restore customer_ledger and
--           customer_ledger_opening from 0037; drop the columns added below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.party_ledger_opening() — what a party's balance was before a date
-- -----------------------------------------------------------------------------
-- Debit positive throughout, for every party type. For a customer that reads as
-- "they owe us"; for a supplier the natural sign is the mirror, so a supplier
-- balance is normally negative here and the view labels it Cr. Keeping one
-- convention in the data and inverting only for display is what lets both
-- ledgers reconcile to their control accounts with the same arithmetic.
-- -----------------------------------------------------------------------------
create or replace function public.party_ledger_opening(
  p_party_type text,
  p_party_id   uuid,
  p_as_on      date
)
returns numeric
language sql
stable
as $$
  select coalesce(sum(l.debit - l.credit), 0)::numeric(18, 4)
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.party_type = p_party_type
     and l.party_id = p_party_id
     and je.status in ('POSTED', 'REVERSED')
     and je.entry_date < p_as_on;
$$;

comment on function public.party_ledger_opening(text, uuid, date) is
  'Balance carried into a date for any party (spec §41). Debit positive.';

-- -----------------------------------------------------------------------------
-- public.party_ledger() — the running account for any party
-- -----------------------------------------------------------------------------
create or replace function public.party_ledger(
  p_party_type text,
  p_party_id   uuid,
  p_from       date,
  p_to         date
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
  -- Derived from party-tagged journal lines, so a subsidiary ledger reconciles
  -- to its control account by construction. The running balance starts from the
  -- carried-forward balance, so any row read on its own is the party's actual
  -- position on that date rather than a total of the window on screen.
  select je.entry_date, je.entry_number, coalesce(l.narration, je.narration),
         l.debit, l.credit,
         public.party_ledger_opening(p_party_type, p_party_id, p_from)
           + sum(l.debit - l.credit) over (order by je.entry_date, je.entry_number, l.line_number
                                           rows between unbounded preceding and current row)
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where l.party_type = p_party_type
     and l.party_id = p_party_id
     and je.status in ('POSTED', 'REVERSED')
     and je.entry_date between p_from and p_to
   order by je.entry_date, je.entry_number, l.line_number;
$$;

comment on function public.party_ledger(text, uuid, date, date) is
  'Running account for any party from the general ledger (spec §41), opening '
  'balance included, so the subsidiary ledger and the control account agree.';

-- -----------------------------------------------------------------------------
-- The customer ledger becomes a wrapper — one implementation, two entry points
-- -----------------------------------------------------------------------------
create or replace function public.customer_ledger_opening(
  p_customer_id uuid,
  p_as_on       date
)
returns numeric
language sql
stable
as $$
  select public.party_ledger_opening('CUSTOMER', p_customer_id, p_as_on);
$$;

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
  select * from public.party_ledger('CUSTOMER', p_customer_id, p_from, p_to);
$$;

-- -----------------------------------------------------------------------------
-- Party columns on the money movements
-- -----------------------------------------------------------------------------
-- cash_transactions already carries customer_id; bank_transactions carried no
-- party at all, so a bank receipt from a customer could not be attributed.
alter table public.cash_transactions
  add column if not exists supplier_id uuid;

alter table public.bank_transactions
  add column if not exists supplier_id uuid,
  add column if not exists customer_id uuid;

alter table public.cash_transactions
  add constraint cash_transactions_supplier_tenant_fkey
  foreign key (supplier_id, dealer_id) references public.suppliers (id, dealer_id);

alter table public.bank_transactions
  add constraint bank_transactions_supplier_tenant_fkey
  foreign key (supplier_id, dealer_id) references public.suppliers (id, dealer_id);

alter table public.bank_transactions
  add constraint bank_transactions_customer_tenant_fkey
  foreign key (customer_id, dealer_id) references public.customers (id, dealer_id);

create index cash_transactions_supplier_idx on public.cash_transactions (supplier_id)
  where supplier_id is not null;
create index bank_transactions_supplier_idx on public.bank_transactions (supplier_id)
  where supplier_id is not null;
create index bank_transactions_customer_idx on public.bank_transactions (customer_id)
  where customer_id is not null;

-- -----------------------------------------------------------------------------
-- public.record_cash_transaction() — spec §37, now party-aware
-- -----------------------------------------------------------------------------
drop function if exists public.record_cash_transaction(uuid, text, numeric, text, uuid, uuid, text, date);

create function public.record_cash_transaction(
  p_branch_id   uuid,
  p_direction   text,
  p_amount      numeric,
  p_particular  text,
  p_account_id  uuid,
  p_customer_id uuid default null,
  p_reference   text default null,
  p_date        date default current_date,
  p_supplier_id uuid default null
)
returns table (transaction_id bigint, journal_entry_id uuid, balance_after numeric)
language plpgsql
as $$
declare
  v_dealer   uuid;
  v_account  public.cash_accounts;
  v_entry    uuid;
  v_cash_acc uuid;
  v_txn      bigint;
  v_balance  numeric(18, 4);
  v_party    text;
  v_party_id uuid;
begin
  if p_amount <= 0 then
    raise exception 'The amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_direction not in ('RECEIPT', 'PAYMENT') then
    raise exception 'Direction must be RECEIPT or PAYMENT.' using errcode = 'check_violation';
  end if;
  -- A journal line carries one party. Two would make the entry belong to both
  -- subsidiary ledgers and reconcile against neither.
  if p_customer_id is not null and p_supplier_id is not null then
    raise exception 'An entry belongs to a customer or a supplier, not both.'
      using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  select * into v_account from public.cash_accounts where branch_id = p_branch_id;

  if v_account.id is null then
    raise exception 'This branch has no cash account.' using errcode = 'no_data_found';
  end if;

  -- Opens the day if needed, and fails if it is already closed (spec §36).
  perform public.ensure_cash_day(p_branch_id, p_date);

  v_cash_acc := v_account.ledger_account_id;

  v_party := case
               when p_customer_id is not null then 'CUSTOMER'
               when p_supplier_id is not null then 'SUPPLIER'
             end;
  v_party_id := coalesce(p_customer_id, p_supplier_id);

  -- A receipt debits cash and credits whatever the money was for; a payment is
  -- the mirror. The contra account is chosen by the operator, because "what was
  -- this for" is a judgement the software cannot make.
  v_entry := app.post_journal(
    v_dealer, p_branch_id, p_date,
    'CASH',
    p_particular,
    case when p_direction = 'RECEIPT' then
      jsonb_build_array(
        jsonb_build_object('account_id', v_cash_acc, 'debit', p_amount, 'credit', 0,
                           'narration', p_particular),
        jsonb_build_object('account_id', p_account_id, 'debit', 0, 'credit', p_amount,
                           'narration', p_particular,
                           'party_type', v_party, 'party_id', v_party_id)
      )
    else
      jsonb_build_array(
        jsonb_build_object('account_id', p_account_id, 'debit', p_amount, 'credit', 0,
                           'narration', p_particular,
                           'party_type', v_party, 'party_id', v_party_id),
        jsonb_build_object('account_id', v_cash_acc, 'debit', 0, 'credit', p_amount,
                           'narration', p_particular)
      )
    end,
    'CASH_BOOK', null, null
  );

  insert into public.cash_transactions
    (dealer_id, branch_id, cash_account_id, business_date, direction, amount,
     particular, reference_number, customer_id, supplier_id, journal_entry_id, created_by)
  values
    (v_dealer, p_branch_id, v_account.id, p_date, p_direction, p_amount,
     p_particular, p_reference, p_customer_id, p_supplier_id, v_entry, auth.uid())
  returning id, cash_transactions.balance_after into v_txn, v_balance;

  transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_bank_transaction() — spec §38, now party-aware
-- -----------------------------------------------------------------------------
drop function if exists public.record_bank_transaction(uuid, text, numeric, text, uuid, date, text, text, text);

create function public.record_bank_transaction(
  p_bank_account_id uuid,
  p_direction       text,
  p_amount          numeric,
  p_particular      text,
  p_account_id      uuid,
  p_date            date default current_date,
  p_reference       text default null,
  p_utr             text default null,
  p_instrument      text default null,
  p_customer_id     uuid default null,
  p_supplier_id     uuid default null
)
returns table (transaction_id bigint, journal_entry_id uuid, balance_after numeric)
language plpgsql
as $$
declare
  v_bank     public.bank_accounts;
  v_entry    uuid;
  v_txn      bigint;
  v_balance  numeric(18, 4);
  v_party    text;
  v_party_id uuid;
begin
  if p_amount <= 0 then
    raise exception 'The amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_direction not in ('RECEIPT', 'PAYMENT') then
    raise exception 'Direction must be RECEIPT or PAYMENT.' using errcode = 'check_violation';
  end if;
  if p_customer_id is not null and p_supplier_id is not null then
    raise exception 'An entry belongs to a customer or a supplier, not both.'
      using errcode = 'check_violation';
  end if;

  select * into v_bank from public.bank_accounts where id = p_bank_account_id;
  if v_bank.id is null then
    raise exception 'Bank account not found.' using errcode = 'no_data_found';
  end if;
  if v_bank.status <> 'ACTIVE' then
    raise exception 'Bank account % is %.', v_bank.name, v_bank.status
      using errcode = 'check_violation';
  end if;

  v_party := case
               when p_customer_id is not null then 'CUSTOMER'
               when p_supplier_id is not null then 'SUPPLIER'
             end;
  v_party_id := coalesce(p_customer_id, p_supplier_id);

  v_entry := app.post_journal(
    v_bank.dealer_id, v_bank.branch_id, p_date,
    'BANK',
    p_particular,
    case when p_direction = 'RECEIPT' then
      jsonb_build_array(
        jsonb_build_object('account_id', v_bank.ledger_account_id, 'debit', p_amount, 'credit', 0,
                           'narration', p_particular),
        jsonb_build_object('account_id', p_account_id, 'debit', 0, 'credit', p_amount,
                           'narration', p_particular,
                           'party_type', v_party, 'party_id', v_party_id)
      )
    else
      jsonb_build_array(
        jsonb_build_object('account_id', p_account_id, 'debit', p_amount, 'credit', 0,
                           'narration', p_particular,
                           'party_type', v_party, 'party_id', v_party_id),
        jsonb_build_object('account_id', v_bank.ledger_account_id, 'debit', 0, 'credit', p_amount,
                           'narration', p_particular)
      )
    end,
    'BANK_BOOK', null, null
  );

  insert into public.bank_transactions
    (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
     reference_number, utr, instrument_number, customer_id, supplier_id,
     journal_entry_id, created_by)
  values
    (v_bank.dealer_id, p_bank_account_id, p_date, p_direction, p_amount, p_particular,
     p_reference, nullif(btrim(p_utr), ''), nullif(btrim(p_instrument), ''),
     p_customer_id, p_supplier_id, v_entry, auth.uid())
  returning id, bank_transactions.balance_after into v_txn, v_balance;

  transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
  return next;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.party_ledger(text, uuid, date, date) to authenticated';
    execute 'grant execute on function public.party_ledger_opening(text, uuid, date) to authenticated';
    execute 'grant execute on function public.customer_ledger(uuid, date, date) to authenticated';
    execute 'grant execute on function public.customer_ledger_opening(uuid, date) to authenticated';
    execute 'grant execute on function public.record_cash_transaction(uuid, text, numeric, text, uuid, uuid, text, date, uuid) to authenticated';
    execute 'grant execute on function public.record_bank_transaction(uuid, text, numeric, text, uuid, date, text, text, text, uuid, uuid) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0042_finance_accounting_rules.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0042 — Accounting rules for the remaining finance events
-- =============================================================================
-- Spec §22, §25, §26.
--
-- 0027 seeded FINANCE (DISBURSEMENT, INVOICE, COMMISSION) and TRADE_ADVANCE
-- (RECEIVED, ADJUSTMENT). Spec §26 lists six trade-advance transaction types and
-- finance_transactions.ft_type_check allows seven; four of them have no account
-- mapping, so posting one would fail at app.require_account() with "No accounting
-- rule for …". These are the missing four.
--
-- Added as a second seeder rather than by rewriting the 0027 function, so the
-- eighty rows of existing mappings are not duplicated into this file where the
-- two copies could drift. Both are idempotent and neither overwrites a mapping a
-- dealer has repointed deliberately.
--
-- Rollback: drop function app.seed_finance_accounting_rules(uuid); and
--           delete from public.accounting_rules
--            where module = 'TRADE_ADVANCE'
--              and event in ('SETTLEMENT', 'REFUND', 'COMMISSION', 'MANUAL_ADJUSTMENT');
-- =============================================================================

create or replace function app.seed_finance_accounting_rules(p_dealer_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_inserted integer := 0;
begin
  insert into public.accounting_rules (dealer_id, module, event, component, side, account_id, description)
  select p_dealer_id, r.module, r.event, r.component, r.side, c.id, 'Default mapping'
    from (values
      -- Settlement: the finance company pays what it owes. The receivable
      -- clears at gross; commission and deductions they withheld are the
      -- difference between gross and what actually arrived in the bank.
      ('TRADE_ADVANCE', 'SETTLEMENT', 'BANK',               'DEBIT',  '1200'),
      ('TRADE_ADVANCE', 'SETTLEMENT', 'FINANCE_RECEIVABLE', 'CREDIT', '1400'),
      ('TRADE_ADVANCE', 'SETTLEMENT', 'COMMISSION',         'DEBIT',  '5900'),
      ('TRADE_ADVANCE', 'SETTLEMENT', 'DEDUCTION',          'DEBIT',  '5900'),

      -- Refund: unused advance goes back, so the payable the dealer held clears.
      ('TRADE_ADVANCE', 'REFUND', 'FINANCE_PAYABLE', 'DEBIT',  '2600'),
      ('TRADE_ADVANCE', 'REFUND', 'BANK',            'CREDIT', '1200'),

      -- Commission earned but not yet received is receivable, not cash.
      ('TRADE_ADVANCE', 'COMMISSION', 'FINANCE_RECEIVABLE', 'DEBIT',  '1400'),
      ('TRADE_ADVANCE', 'COMMISSION', 'COMMISSION_INCOME',  'CREDIT', '4500'),

      -- A manual correction moves value between the two finance accounts. It
      -- exists because the ledger is append-only: a mistake is corrected by a
      -- further entry, never by editing the original (spec §23).
      ('TRADE_ADVANCE', 'MANUAL_ADJUSTMENT', 'FINANCE_RECEIVABLE', 'DEBIT',  '1400'),
      ('TRADE_ADVANCE', 'MANUAL_ADJUSTMENT', 'FINANCE_PAYABLE',    'CREDIT', '2600')
    ) as r(module, event, component, side, account_code)
    join public.chart_of_accounts c
      on c.dealer_id = p_dealer_id and c.code = r.account_code
   -- Leave an existing mapping alone: a dealer may have repointed it deliberately.
   where not exists (
     select 1 from public.accounting_rules ar
      where ar.dealer_id = p_dealer_id
        and ar.module = r.module and ar.event = r.event and ar.component = r.component
        and ar.branch_id is null
   );

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;

comment on function app.seed_finance_accounting_rules(uuid) is
  'Installs the trade-advance mappings spec §26 needs beyond those in 0027 '
  '(spec §22). Idempotent: customised rules are never overwritten.';

-- Apply to every dealer that already exists.
do $$
declare
  d record;
begin
  for d in select id from public.dealers loop
    perform app.seed_finance_accounting_rules(d.id);
  end loop;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function app.seed_finance_accounting_rules(uuid) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0043_finance_operations.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0043 — Finance operations
-- =============================================================================
-- Spec §25, §26, §27.
--
-- The finance tables have existed since 0021 with no way to write to them: no
-- function creates an application, records a trade advance, or posts a
-- settlement. Everything below is that missing half.
--
-- TWO CONVENTIONS, STATED ONCE AND HELD THROUGHOUT.
--
-- 1. The company side of every posting resolves through
--    app.require_account(… FINANCE_RECEIVABLE / FINANCE_PAYABLE …) and is
--    identified by party_type = 'FINANCE_COMPANY' + party_id.
--    finance_companies.ledger_account_id is NOT used for posting. Using both
--    would split one company's balance across two accounts, and neither would
--    reconcile to the subsidiary ledger.
--
-- 2. finance_transactions is the dealer's net position with a company:
--    **positive means the company owes the dealer.** A credit increases it, a
--    debit reduces it — which is what the BEFORE INSERT trigger in 0021 already
--    computes. balance_after is never written by these functions.
--
-- Also note ft_one_sided_check: exactly one of debit/credit must be strictly
-- positive, so a zero-amount ledger row is impossible and must be skipped rather
-- than written.
--
-- Rollback: drop the six functions below; restore the ft_insert policy and
--           public.record_sale_payment from 0021 and 0028; drop
--           public.finance_settlements.branch_id.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A settlement needs a branch
-- -----------------------------------------------------------------------------
-- journal_entries.branch_id is NOT NULL, and finance_settlements had no branch
-- at all. Backfilled to the head office rather than defaulted at post time, so
-- the branch is a recorded fact rather than a guess made later.
-- -----------------------------------------------------------------------------
alter table public.finance_settlements add column if not exists branch_id uuid;

update public.finance_settlements fs
   set branch_id = (
     select b.id from public.branches b
      where b.dealer_id = fs.dealer_id
      order by b.is_head_office desc, b.code
      limit 1)
 where fs.branch_id is null;

do $$
begin
  if exists (select 1 from public.finance_settlements where branch_id is null) then
    raise notice 'finance_settlements rows without a branch remain; leaving column nullable.';
  else
    execute 'alter table public.finance_settlements alter column branch_id set not null';
  end if;
end;
$$;

alter table public.finance_settlements
  add constraint fs_branch_tenant_fkey
  foreign key (branch_id, dealer_id) references public.branches (id, dealer_id);

-- -----------------------------------------------------------------------------
-- The insert policy has to admit the role that disburses
-- -----------------------------------------------------------------------------
-- ft_insert listed trade_advance.manage, settlements.manage and sales.post but
-- not finance.applications.manage — so disbursing an application, which is
-- exactly what that permission is for, was refused by RLS.
-- -----------------------------------------------------------------------------
drop policy if exists ft_insert on public.finance_transactions;

create policy ft_insert on public.finance_transactions
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and (app.has_permission('finance.trade_advance.manage')
             or app.has_permission('finance.settlements.manage')
             or app.has_permission('finance.applications.manage')
             or app.has_permission('sales.post')))
  );

comment on column public.finance_companies.ledger_account_id is
  'Reporting hint only. Posting resolves accounts through accounting_rules '
  '(spec §22); see 0043.';

-- -----------------------------------------------------------------------------
-- public.create_finance_application() — spec §27
-- -----------------------------------------------------------------------------
-- No journal: an application is a request, not a transaction. Nothing is owed
-- until the finance company approves and disburses.
-- -----------------------------------------------------------------------------
create or replace function public.create_finance_application(
  p_branch_id          uuid,
  p_customer_id        uuid,
  p_finance_company_id uuid,
  p_loan_amount        numeric,
  p_down_payment       numeric default 0,
  p_vehicle_id         uuid default null,
  p_sale_id            uuid default null,
  p_tenure_months      smallint default null,
  p_interest_rate      numeric default null,
  p_commission_amount  numeric default 0,
  p_application_date   date default current_date,
  p_notes              text default null
)
returns table (application_id uuid, application_number text)
language plpgsql
as $$
declare
  v_dealer uuid;
  v_number text;
  v_id     uuid;
begin
  if p_loan_amount <= 0 then
    raise exception 'The loan amount must be greater than zero.' using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  v_number := app.next_document_number(
    v_dealer, p_branch_id, 'FINANCE_APPLICATION',
    app.financial_year_token(v_dealer, p_application_date));

  insert into public.finance_applications
    (dealer_id, branch_id, application_number, application_date, customer_id,
     finance_company_id, vehicle_id, sale_id, loan_amount, down_payment,
     tenure_months, interest_rate, commission_amount, notes, created_by)
  values
    (v_dealer, p_branch_id, v_number, p_application_date, p_customer_id,
     p_finance_company_id, p_vehicle_id, p_sale_id, p_loan_amount, p_down_payment,
     p_tenure_months, p_interest_rate, coalesce(p_commission_amount, 0), p_notes, auth.uid())
  returning id into v_id;

  application_id := v_id; application_number := v_number;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.decide_finance_application() — approve or reject
-- -----------------------------------------------------------------------------
create or replace function public.decide_finance_application(
  p_application_id  uuid,
  p_decision        text,
  p_approved_amount numeric default null,
  p_rejection_reason text default null
)
returns void
language plpgsql
as $$
declare
  v_app public.finance_applications;
begin
  select * into v_app from public.finance_applications where id = p_application_id for update;

  if v_app.id is null then
    raise exception 'Application not found.' using errcode = 'no_data_found';
  end if;
  if v_app.approval_status <> 'PENDING' then
    raise exception 'Application % is already %.', v_app.application_number, v_app.approval_status
      using errcode = 'check_violation';
  end if;
  if p_decision not in ('APPROVED', 'REJECTED', 'CANCELLED') then
    raise exception 'The decision must be APPROVED, REJECTED or CANCELLED.'
      using errcode = 'check_violation';
  end if;

  -- Mirrors fa_approved_amount_check and fa_rejection_check, so the caller gets
  -- a sentence rather than a constraint violation.
  if p_decision = 'APPROVED' and p_approved_amount is null then
    raise exception 'An approval must state the amount approved.'
      using errcode = 'check_violation';
  end if;
  if p_decision = 'REJECTED' and coalesce(btrim(p_rejection_reason), '') = '' then
    raise exception 'A rejection must state a reason.'
      using errcode = 'check_violation';
  end if;

  update public.finance_applications
     set approval_status  = p_decision,
         approved_amount  = case when p_decision = 'APPROVED' then p_approved_amount else approved_amount end,
         approved_at      = case when p_decision = 'APPROVED' then now() else approved_at end,
         rejection_reason = case when p_decision = 'REJECTED' then btrim(p_rejection_reason) else rejection_reason end,
         disbursement_status = case when p_decision in ('REJECTED', 'CANCELLED') then 'CANCELLED'
                                    else disbursement_status end,
         updated_by = auth.uid()
   where id = p_application_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.disburse_finance_application() — spec §27
-- -----------------------------------------------------------------------------
-- Money arrives from the finance company against a vehicle already invoiced, so
-- the finance receivable clears and the bank rises. The bank book gets its row
-- in the same transaction, or the money would be in the ledger and not in the
-- bank book.
-- -----------------------------------------------------------------------------
create or replace function public.disburse_finance_application(
  p_application_id  uuid,
  p_amount          numeric,
  p_bank_account_id uuid,
  p_dd_number       text default null,
  p_bank_reference  text default null,
  p_date            date default current_date
)
-- Two ledger rows are written, so both ids are returned by name. A single
-- "transaction_id" would leave the caller guessing which one it held.
returns table (journal_entry_id uuid, bank_transaction_id bigint, finance_transaction_id bigint)
language plpgsql
as $$
declare
  v_app     public.finance_applications;
  v_bank    public.bank_accounts;
  v_entry   uuid;
  v_txn     bigint;
  v_fin     bigint;
  v_debit   uuid;
  v_credit  uuid;
  v_pending numeric(18, 4);
begin
  if p_amount <= 0 then
    raise exception 'The amount must be greater than zero.' using errcode = 'check_violation';
  end if;

  select * into v_app from public.finance_applications where id = p_application_id for update;
  if v_app.id is null then
    raise exception 'Application not found.' using errcode = 'no_data_found';
  end if;
  if v_app.approval_status <> 'APPROVED' then
    raise exception 'Application % is % — only an approved application can be disbursed.',
      v_app.application_number, v_app.approval_status using errcode = 'check_violation';
  end if;

  v_pending := coalesce(v_app.approved_amount, v_app.loan_amount) - v_app.disbursed_amount;
  if p_amount > v_pending then
    raise exception 'Only % is still to be disbursed on %.', v_pending, v_app.application_number
      using errcode = 'check_violation';
  end if;

  select * into v_bank from public.bank_accounts where id = p_bank_account_id;
  if v_bank.id is null then
    raise exception 'Bank account not found.' using errcode = 'no_data_found';
  end if;

  v_debit  := coalesce(v_bank.ledger_account_id,
                       app.require_account(v_app.dealer_id, 'FINANCE', 'DISBURSEMENT', 'BANK', v_app.branch_id));
  v_credit := app.require_account(v_app.dealer_id, 'FINANCE', 'DISBURSEMENT', 'FINANCE_RECEIVABLE', v_app.branch_id);

  v_entry := app.post_journal(
    v_app.dealer_id, v_app.branch_id, p_date, 'FINANCE',
    'Disbursement against ' || v_app.application_number,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', 'Received from finance company'),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', 'Against ' || v_app.application_number,
                         'party_type', 'FINANCE_COMPANY', 'party_id', v_app.finance_company_id)
    ),
    'FINANCE_APPLICATION', p_application_id,
    'fin-disb:' || p_application_id::text || ':' || p_amount::text || ':' || p_date::text
  );

  -- The bank book and reconciliation must see this like any other credit.
  insert into public.bank_transactions
    (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
     reference_number, journal_entry_id, created_by)
  values
    (v_app.dealer_id, p_bank_account_id, p_date, 'RECEIPT', p_amount,
     'Finance disbursement ' || v_app.application_number,
     coalesce(p_bank_reference, p_dd_number), v_entry, auth.uid())
  returning id into v_txn;

  -- Debit: the company owed the dealer and has now paid, so the position falls.
  insert into public.finance_transactions
    (dealer_id, branch_id, finance_company_id, transaction_date, transaction_type,
     debit, credit, reference_type, reference_id, reference_number, narration,
     application_id, sale_id, journal_entry_id, created_by)
  values
    (v_app.dealer_id, v_app.branch_id, v_app.finance_company_id, p_date, 'DISBURSEMENT',
     p_amount, 0, 'FINANCE_APPLICATION', p_application_id, v_app.application_number,
     'Disbursement received', p_application_id, v_app.sale_id, v_entry, auth.uid())
  returning id into v_fin;

  update public.finance_applications
     set disbursed_amount = disbursed_amount + p_amount,
         disbursed_at = p_date,
         dd_number = coalesce(p_dd_number, dd_number),
         bank_reference = coalesce(p_bank_reference, bank_reference),
         disbursement_status = case
           when disbursed_amount + p_amount >= coalesce(approved_amount, loan_amount) then 'DISBURSED'
           else 'PARTIAL' end,
         updated_by = auth.uid()
   where id = p_application_id;

  journal_entry_id := v_entry; bank_transaction_id := v_txn; finance_transaction_id := v_fin;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_trade_advance() — spec §26
-- -----------------------------------------------------------------------------
-- Six transaction types, each with its own pair of accounts. The mapping is
-- declared here rather than left to the caller so a trade advance cannot be
-- posted to whatever account someone picked in a form.
-- -----------------------------------------------------------------------------
create or replace function public.record_trade_advance(
  p_finance_company_id uuid,
  p_branch_id          uuid,
  p_type               text,
  p_amount             numeric,
  p_bank_account_id    uuid default null,
  p_date               date default current_date,
  p_narration          text default null,
  p_reference          text default null
)
returns table (transaction_id bigint, journal_entry_id uuid)
language plpgsql
as $$
declare
  v_dealer  uuid;
  v_company public.finance_companies;
  v_bank    public.bank_accounts;
  v_bank_acc uuid;
  v_debit   uuid;
  v_credit  uuid;
  v_entry   uuid;
  v_txn     bigint;
  v_debit_amt  numeric(18, 4) := 0;
  v_credit_amt numeric(18, 4) := 0;
  v_narration text;
begin
  -- ft_one_sided_check forbids a zero row, so this is not merely tidiness.
  if p_amount <= 0 then
    raise exception 'The amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_type not in ('ADVANCE_RECEIVED', 'VEHICLE_ADJUSTMENT', 'SETTLEMENT',
                    'REFUND', 'COMMISSION', 'MANUAL_ADJUSTMENT') then
    raise exception 'Unknown trade advance type %.', p_type using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  select * into v_company from public.finance_companies where id = p_finance_company_id;
  if v_company.id is null then
    raise exception 'Finance company not found.' using errcode = 'no_data_found';
  end if;

  if p_bank_account_id is not null then
    select * into v_bank from public.bank_accounts where id = p_bank_account_id;
  end if;

  v_narration := coalesce(p_narration, replace(initcap(replace(p_type, '_', ' ')), ' ', ' ')
                          || ' — ' || v_company.name);

  -- Money in or out needs a bank account; the internal moves do not.
  if p_type in ('ADVANCE_RECEIVED', 'SETTLEMENT', 'REFUND') and v_bank.id is null then
    raise exception 'A % needs the bank account the money moved through.', lower(replace(p_type, '_', ' '))
      using errcode = 'check_violation';
  end if;

  v_bank_acc := v_bank.ledger_account_id;

  if p_type = 'ADVANCE_RECEIVED' then
    -- The company funds the dealer ahead of sales: cash in, liability up.
    v_debit  := coalesce(v_bank_acc, app.require_account(v_dealer, 'TRADE_ADVANCE', 'RECEIVED', 'BANK', p_branch_id));
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'RECEIVED', 'FINANCE_PAYABLE', p_branch_id);
    v_debit_amt := p_amount;          -- the dealer holds their money, so the position falls
  elsif p_type = 'VEHICLE_ADJUSTMENT' then
    -- An advance is consumed by a vehicle the company financed.
    v_debit  := app.require_account(v_dealer, 'TRADE_ADVANCE', 'ADJUSTMENT', 'FINANCE_PAYABLE', p_branch_id);
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'ADJUSTMENT', 'FINANCE_RECEIVABLE', p_branch_id);
    v_credit_amt := p_amount;
  elsif p_type = 'SETTLEMENT' then
    v_debit  := coalesce(v_bank_acc, app.require_account(v_dealer, 'TRADE_ADVANCE', 'SETTLEMENT', 'BANK', p_branch_id));
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'SETTLEMENT', 'FINANCE_RECEIVABLE', p_branch_id);
    v_debit_amt := p_amount;
  elsif p_type = 'REFUND' then
    v_debit  := app.require_account(v_dealer, 'TRADE_ADVANCE', 'REFUND', 'FINANCE_PAYABLE', p_branch_id);
    v_credit := coalesce(v_bank_acc, app.require_account(v_dealer, 'TRADE_ADVANCE', 'REFUND', 'BANK', p_branch_id));
    v_credit_amt := p_amount;
  elsif p_type = 'COMMISSION' then
    v_debit  := app.require_account(v_dealer, 'TRADE_ADVANCE', 'COMMISSION', 'FINANCE_RECEIVABLE', p_branch_id);
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'COMMISSION', 'COMMISSION_INCOME', p_branch_id);
    v_credit_amt := p_amount;         -- earned but unpaid: the company owes more
  else -- MANUAL_ADJUSTMENT
    v_debit  := app.require_account(v_dealer, 'TRADE_ADVANCE', 'MANUAL_ADJUSTMENT', 'FINANCE_RECEIVABLE', p_branch_id);
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'MANUAL_ADJUSTMENT', 'FINANCE_PAYABLE', p_branch_id);
    v_credit_amt := p_amount;
  end if;

  v_entry := app.post_journal(
    v_dealer, p_branch_id, p_date, 'TRADE_ADVANCE', v_narration,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', v_narration,
                         'party_type', 'FINANCE_COMPANY', 'party_id', p_finance_company_id),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', v_narration,
                         'party_type', 'FINANCE_COMPANY', 'party_id', p_finance_company_id)
    ),
    'TRADE_ADVANCE', null, null
  );

  insert into public.finance_transactions
    (dealer_id, branch_id, finance_company_id, transaction_date, transaction_type,
     debit, credit, reference_type, reference_number, narration, journal_entry_id, created_by)
  values
    (v_dealer, p_branch_id, p_finance_company_id, p_date, p_type,
     v_debit_amt, v_credit_amt, 'TRADE_ADVANCE', p_reference, v_narration, v_entry, auth.uid())
  returning id into v_txn;

  -- Money that moved through a bank account belongs in the bank book too.
  if v_bank.id is not null and p_type in ('ADVANCE_RECEIVED', 'SETTLEMENT', 'REFUND') then
    insert into public.bank_transactions
      (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
       reference_number, journal_entry_id, created_by)
    values
      (v_dealer, p_bank_account_id, p_date,
       case when p_type = 'REFUND' then 'PAYMENT' else 'RECEIPT' end,
       p_amount, v_narration, p_reference, v_entry, auth.uid());
  end if;

  transaction_id := v_txn; journal_entry_id := v_entry;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.create_finance_settlement() / post_finance_settlement() — spec §26
-- -----------------------------------------------------------------------------
create or replace function public.create_finance_settlement(
  p_finance_company_id uuid,
  p_branch_id          uuid,
  p_from               date,
  p_to                 date,
  p_gross              numeric,
  p_commission         numeric default 0,
  p_deductions         numeric default 0,
  p_settlement_date    date default current_date,
  p_notes              text default null
)
returns table (settlement_id uuid, settlement_number text)
language plpgsql
as $$
declare
  v_dealer uuid;
  v_number text;
  v_id     uuid;
begin
  if p_gross <= 0 then
    raise exception 'The gross amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if coalesce(p_commission, 0) + coalesce(p_deductions, 0) > p_gross then
    raise exception 'Commission and deductions cannot exceed the gross amount.'
      using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  v_number := app.next_document_number(
    v_dealer, p_branch_id, 'FINANCE_SETTLEMENT',
    app.financial_year_token(v_dealer, p_settlement_date));

  insert into public.finance_settlements
    (dealer_id, branch_id, finance_company_id, settlement_number, settlement_date,
     from_date, to_date, gross_amount, commission_amount, deductions, notes, created_by)
  values
    (v_dealer, p_branch_id, p_finance_company_id, v_number, p_settlement_date,
     p_from, p_to, p_gross, coalesce(p_commission, 0), coalesce(p_deductions, 0),
     p_notes, auth.uid())
  returning id into v_id;

  settlement_id := v_id; settlement_number := v_number;
  return next;
end;
$$;

create or replace function public.post_finance_settlement(
  p_settlement_id   uuid,
  p_bank_account_id uuid
)
returns uuid
language plpgsql
as $$
declare
  v_s      public.finance_settlements;
  v_bank   public.bank_accounts;
  v_lines  jsonb;
  v_entry  uuid;
  v_bank_acc uuid;
begin
  select * into v_s from public.finance_settlements where id = p_settlement_id for update;
  if v_s.id is null then
    raise exception 'Settlement not found.' using errcode = 'no_data_found';
  end if;
  if v_s.status <> 'DRAFT' then
    raise exception 'Settlement % is % and cannot be posted again.', v_s.settlement_number, v_s.status
      using errcode = 'check_violation';
  end if;

  select * into v_bank from public.bank_accounts where id = p_bank_account_id;
  if v_bank.id is null then
    raise exception 'Bank account not found.' using errcode = 'no_data_found';
  end if;

  v_bank_acc := coalesce(v_bank.ledger_account_id,
                         app.require_account(v_s.dealer_id, 'TRADE_ADVANCE', 'SETTLEMENT', 'BANK', v_s.branch_id));

  -- The receivable clears at gross; what the company withheld is the difference
  -- between gross and what reached the bank. A zero commission or deduction adds
  -- no line: an empty line is noise in the journal and would be rejected as a
  -- finance_transactions row.
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_bank_acc, 'debit', v_s.net_amount, 'credit', 0,
                       'narration', 'Settlement ' || v_s.settlement_number)
  );

  if v_s.commission_amount > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', app.require_account(v_s.dealer_id, 'TRADE_ADVANCE', 'SETTLEMENT', 'COMMISSION', v_s.branch_id),
      'debit', v_s.commission_amount, 'credit', 0, 'narration', 'Commission withheld'));
  end if;

  if v_s.deductions > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', app.require_account(v_s.dealer_id, 'TRADE_ADVANCE', 'SETTLEMENT', 'DEDUCTION', v_s.branch_id),
      'debit', v_s.deductions, 'credit', 0, 'narration', 'Deductions'));
  end if;

  v_lines := v_lines || jsonb_build_array(jsonb_build_object(
    'account_id', app.require_account(v_s.dealer_id, 'TRADE_ADVANCE', 'SETTLEMENT', 'FINANCE_RECEIVABLE', v_s.branch_id),
    'debit', 0, 'credit', v_s.gross_amount, 'narration', 'Settled ' || v_s.settlement_number,
    'party_type', 'FINANCE_COMPANY', 'party_id', v_s.finance_company_id));

  v_entry := app.post_journal(
    v_s.dealer_id, v_s.branch_id, v_s.settlement_date, 'TRADE_ADVANCE',
    'Settlement ' || v_s.settlement_number, v_lines,
    'FINANCE_SETTLEMENT', p_settlement_id, 'fin-settle:' || p_settlement_id::text
  );

  insert into public.finance_transactions
    (dealer_id, branch_id, finance_company_id, transaction_date, transaction_type,
     debit, credit, reference_type, reference_id, reference_number, narration,
     journal_entry_id, created_by)
  values
    (v_s.dealer_id, v_s.branch_id, v_s.finance_company_id, v_s.settlement_date, 'SETTLEMENT',
     v_s.gross_amount, 0, 'FINANCE_SETTLEMENT', p_settlement_id, v_s.settlement_number,
     'Settlement posted', v_entry, auth.uid());

  insert into public.bank_transactions
    (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
     reference_number, journal_entry_id, created_by)
  values
    (v_s.dealer_id, p_bank_account_id, v_s.settlement_date, 'RECEIPT', v_s.net_amount,
     'Settlement ' || v_s.settlement_number, v_s.settlement_number, v_entry, auth.uid());

  update public.finance_settlements
     set status = 'POSTED', journal_entry_id = v_entry
   where id = p_settlement_id;

  return v_entry;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.create_finance_application(uuid, uuid, uuid, numeric, numeric, uuid, uuid, smallint, numeric, numeric, date, text) to authenticated';
    execute 'grant execute on function public.decide_finance_application(uuid, text, numeric, text) to authenticated';
    execute 'grant execute on function public.disburse_finance_application(uuid, numeric, uuid, text, text, date) to authenticated';
    execute 'grant execute on function public.record_trade_advance(uuid, uuid, text, numeric, uuid, date, text, text) to authenticated';
    execute 'grant execute on function public.create_finance_settlement(uuid, uuid, date, date, numeric, numeric, numeric, date, text) to authenticated';
    execute 'grant execute on function public.post_finance_settlement(uuid, uuid) to authenticated';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_sale_payment() — name the finance company on the receivable
-- -----------------------------------------------------------------------------
-- A sale settled by finance debits Finance Receivable, but the line carried no
-- party, so account 1400 held a total with no subsidiary detail behind it and
-- the company ledger could not see money owed against its own vehicles.
--
-- Only the party tagging and the VEHICLE_ADJUSTMENT row are new; the body is
-- otherwise 0028's. The numbering is untouched because 0039 fixed scope inside
-- app.next_document_number() rather than at each call site, so there is no
-- earlier fix here to carry forward.
-- -----------------------------------------------------------------------------
create or replace function public.record_sale_payment(
  p_sale_id      uuid,
  p_amount       numeric,
  p_payment_mode text,
  p_reference    text default null,
  p_finance_company_id uuid default null
)
returns table (receipt_number text, journal_entry_id uuid)
language plpgsql
as $$
declare
  v_sale     public.sales;
  v_year     text;
  v_rnumber  text;
  v_entry    uuid;
  v_debit    uuid;
  v_credit   uuid;
  v_component text;
  v_party    text;
  v_party_id uuid;
begin
  if p_amount <= 0 then
    raise exception 'The payment amount must be greater than zero.' using errcode = 'check_violation';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;
  if v_sale.id is null then
    raise exception 'Sale not found.' using errcode = 'no_data_found';
  end if;
  if v_sale.status not in ('POSTED', 'DELIVERED') then
    raise exception 'Payments can only be recorded against a posted invoice; this one is %.', v_sale.status
      using errcode = 'check_violation';
  end if;

  v_year := app.financial_year_token(v_sale.dealer_id, current_date);
  v_rnumber := app.next_document_number(v_sale.dealer_id, v_sale.branch_id, 'RECEIPT', v_year);

  -- Finance disbursement moves the debt to the finance company rather than
  -- settling it in cash (spec §27).
  if p_payment_mode = 'FINANCE' then
    if p_finance_company_id is null then
      raise exception 'A finance payment must name the finance company carrying the debt.'
        using errcode = 'check_violation';
    end if;
    v_component := 'FINANCE_RECEIVABLE';
    v_debit  := app.require_account(v_sale.dealer_id, 'FINANCE', 'INVOICE', 'FINANCE_RECEIVABLE', v_sale.branch_id);
    v_party := 'FINANCE_COMPANY';
    v_party_id := p_finance_company_id;
  else
    v_component := case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end;
    v_debit := app.require_account(
      v_sale.dealer_id,
      case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
      'RECEIPT', v_component, v_sale.branch_id);
  end if;

  v_credit := app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'RECEIVABLE', v_sale.branch_id);

  v_entry := app.post_journal(
    v_sale.dealer_id, v_sale.branch_id, current_date,
    case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
    'Receipt ' || v_rnumber || ' against ' || v_sale.invoice_number,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', p_payment_mode || ' received',
                         'party_type', v_party, 'party_id', v_party_id),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', 'Against ' || v_sale.invoice_number,
                         'party_type', 'CUSTOMER', 'party_id', v_sale.customer_id)
    ),
    'SALE_PAYMENT', p_sale_id, 'receipt:' || v_rnumber
  );

  insert into public.sale_payments
    (dealer_id, sale_id, receipt_number, amount, payment_mode, reference,
     finance_company_id, journal_entry_id, created_by)
  values
    (v_sale.dealer_id, p_sale_id, v_rnumber, p_amount, p_payment_mode, p_reference,
     p_finance_company_id, v_entry, auth.uid());

  -- The company now owes the dealer for this vehicle, so its position rises.
  if p_payment_mode = 'FINANCE' then
    insert into public.finance_transactions
      (dealer_id, branch_id, finance_company_id, transaction_date, transaction_type,
       debit, credit, reference_type, reference_id, reference_number, narration,
       sale_id, journal_entry_id, created_by)
    values
      (v_sale.dealer_id, v_sale.branch_id, p_finance_company_id, current_date, 'VEHICLE_ADJUSTMENT',
       0, p_amount, 'SALE', p_sale_id, v_sale.invoice_number,
       'Financed ' || v_sale.invoice_number, p_sale_id, v_entry, auth.uid());
  end if;

  receipt_number := v_rnumber; journal_entry_id := v_entry;
  return next;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0044_price_approval_workflow.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0044 — Price approval workflow
-- =============================================================================
-- Spec §15, §17, §60.9.
--
-- 0018 built a price version for an approval workflow it never got: the status
-- check allows DRAFT → SUBMITTED → APPROVED → ACTIVE, the table carries
-- submitted_at/submitted_by/approved_at/approved_by, and the permission
-- `vehicles.pricing.approve` exists — but nothing ever moves a version between
-- those states. createPriceVersion inserts ACTIVE with the approval stamps
-- pre-filled, so a price goes live the moment one person saves it. Spec §15 asks
-- for DRAFT → SUBMITTED → APPROVED → ACTIVE precisely because a price change is
-- what every future invoice is computed from.
--
-- Two things are fixed here:
--
-- 1. `masters.pricing.manage` granted no database access at all. The Masters
--    screen is gated on it, so a user holding only that permission passed the
--    page check and then saw nothing, because the RLS on this table knows only
--    `vehicles.pricing.*`. The policies now recognise both.
--
-- 2. public.decide_price_version() moves a version through the workflow, and is
--    the only way a price goes live. Activation supersedes the incumbent in the
--    same statement, because vpv_active_scope_key permits exactly one ACTIVE
--    price per scope.
--
-- Rollback: restore the three policies from 0018 and drop
--           public.decide_price_version(uuid, text, text).
-- =============================================================================

drop policy if exists vpv_select on public.vehicle_price_versions;
drop policy if exists vpv_insert on public.vehicle_price_versions;
drop policy if exists vpv_update on public.vehicle_price_versions;

create policy vpv_select on public.vehicle_price_versions for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('vehicles.pricing.view')
                  or app.has_permission('masters.pricing.manage'))));

create policy vpv_insert on public.vehicle_price_versions for insert to authenticated
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('vehicles.pricing.manage')
                  or app.has_permission('masters.pricing.manage'))));

create policy vpv_update on public.vehicle_price_versions for update to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('vehicles.pricing.manage')
                  or app.has_permission('vehicles.pricing.approve')
                  or app.has_permission('masters.pricing.manage'))))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('vehicles.pricing.manage')
                  or app.has_permission('vehicles.pricing.approve')
                  or app.has_permission('masters.pricing.manage'))));

-- -----------------------------------------------------------------------------
-- public.decide_price_version() — spec §15
-- -----------------------------------------------------------------------------
create or replace function public.decide_price_version(
  p_version_id uuid,
  p_action     text,
  p_reason     text default null
)
returns text
language plpgsql
as $$
declare
  v_v      public.vehicle_price_versions;
  v_status text;
begin
  select * into v_v from public.vehicle_price_versions where id = p_version_id for update;

  if v_v.id is null then
    raise exception 'Price version not found.' using errcode = 'no_data_found';
  end if;
  if p_action not in ('SUBMIT', 'APPROVE', 'REJECT', 'ACTIVATE') then
    raise exception 'Unknown action %.', p_action using errcode = 'check_violation';
  end if;

  if p_action = 'SUBMIT' then
    if v_v.status <> 'DRAFT' then
      raise exception 'Only a draft can be submitted; version % is %.', v_v.version_number, v_v.status
        using errcode = 'check_violation';
    end if;
    update public.vehicle_price_versions
       set status = 'SUBMITTED', submitted_at = now(), submitted_by = auth.uid()
     where id = p_version_id;
    v_status := 'SUBMITTED';

  elsif p_action = 'APPROVE' then
    if v_v.status <> 'SUBMITTED' then
      raise exception 'Only a submitted price can be approved; version % is %.',
        v_v.version_number, v_v.status using errcode = 'check_violation';
    end if;
    -- A price one person can write, submit and approve alone is not reviewed at
    -- all, and DEALER_OWNER holds both permissions.
    if v_v.submitted_by is not null and v_v.submitted_by = auth.uid() then
      raise exception 'A price must be approved by someone other than the person who submitted it.'
        using errcode = 'insufficient_privilege',
              hint = 'Spec §15: the approval step exists to be a second pair of eyes.';
    end if;
    update public.vehicle_price_versions
       set status = 'APPROVED', approved_at = now(), approved_by = auth.uid()
     where id = p_version_id;
    v_status := 'APPROVED';

  elsif p_action = 'REJECT' then
    if v_v.status <> 'SUBMITTED' then
      raise exception 'Only a submitted price can be rejected; version % is %.',
        v_v.version_number, v_v.status using errcode = 'check_violation';
    end if;
    if coalesce(btrim(p_reason), '') = '' then
      raise exception 'A rejection must say why.'
        using errcode = 'check_violation',
              hint = 'Spec §15: the reason is what makes the rejection reviewable.';
    end if;
    update public.vehicle_price_versions
       set status = 'REJECTED',
           notes = coalesce(notes || E'\n', '') || 'Rejected: ' || btrim(p_reason)
     where id = p_version_id;
    v_status := 'REJECTED';

  else -- ACTIVATE
    if v_v.status <> 'APPROVED' then
      raise exception 'Only an approved price can go live; version % is %.',
        v_v.version_number, v_v.status using errcode = 'check_violation';
    end if;

    -- Supersede the incumbent first: vpv_active_scope_key allows exactly one
    -- ACTIVE row per (dealer, model, variant, branch), so activating before
    -- retiring the old one would violate it.
    update public.vehicle_price_versions
       set status = 'SUPERSEDED',
           effective_to = v_v.effective_from - 1
     where dealer_id = v_v.dealer_id
       and model_id = v_v.model_id
       and coalesce(variant_id, '00000000-0000-0000-0000-000000000000'::uuid)
             = coalesce(v_v.variant_id, '00000000-0000-0000-0000-000000000000'::uuid)
       and coalesce(branch_id, '00000000-0000-0000-0000-000000000000'::uuid)
             = coalesce(v_v.branch_id, '00000000-0000-0000-0000-000000000000'::uuid)
       and status = 'ACTIVE'
       and id <> p_version_id;

    update public.vehicle_price_versions set status = 'ACTIVE' where id = p_version_id;
    v_status := 'ACTIVE';
  end if;

  return v_status;
end;
$$;

comment on function public.decide_price_version(uuid, text, text) is
  'Moves a price version through DRAFT → SUBMITTED → APPROVED → ACTIVE (spec §15). '
  'The only way a price goes live; activation supersedes the incumbent.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.decide_price_version(uuid, text, text) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0045_customer_vehicle_writer.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0045 — Somebody has to write customer_vehicles
-- =============================================================================
-- Spec §11, §32, §33.
--
-- customer_vehicles has existed since 0023 with no writer anywhere in the
-- codebase: job cards carry a free-text registration and never link to it, and
-- delivery never records that a customer now owns the unit. The table has always
-- been empty, so "which vehicles does this customer own" and "what is this
-- vehicle's service history" could not be answered at all.
--
-- Two writers, at the two moments ownership becomes a fact:
--   * delivery — the dealer sold it, so everything about it is known;
--   * a job card for a walk-in — the dealer did not sell it, but the workshop
--     now knows the registration, so the record starts from there.
--
-- Rollback: restore public.deliver_vehicle() from 0038 and public.create_job_card()
--           from 0033, drop index cv_vehicle_key, restore policy cv_write from
--           0023, and drop public.customer_service_summary(uuid, uuid).
-- =============================================================================

-- A vehicle has one current owner. Needed as an ON CONFLICT target, and it makes
-- a resold unit update to the new owner rather than accumulate rows.
create unique index if not exists cv_vehicle_key
  on public.customer_vehicles (vehicle_id) where vehicle_id is not null;

-- -----------------------------------------------------------------------------
-- The writer needs to be allowed to write
-- -----------------------------------------------------------------------------
-- cv_write is FOR ALL, so its USING clause governs the UPDATE half of an upsert.
-- It admitted customers.edit and service.jobcards.create — neither of which a
-- delivery clerk holds — so re-delivering a unit to a new owner would fail on
-- the conflict path while a first delivery succeeded. Adding sales.deliver makes
-- both work.
-- -----------------------------------------------------------------------------
drop policy if exists cv_write on public.customer_vehicles;

create policy cv_write on public.customer_vehicles for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('customers.edit')
                  or app.has_permission('service.jobcards.create')
                  or app.has_permission('sales.deliver'))))
  with check (app.is_platform_admin() or dealer_id = app.current_dealer_id());

-- -----------------------------------------------------------------------------
-- public.deliver_vehicle() — spec §19, now recording ownership
-- -----------------------------------------------------------------------------
create or replace function public.deliver_vehicle(
  p_sale_id      uuid,
  p_received_by  text default null,
  p_odometer     numeric default null,
  p_remarks      text default null
)
returns text
language plpgsql
as $$
declare
  v_sale    public.sales;
  v_year    text;
  v_number  text;
begin
  select * into v_sale from public.sales where id = p_sale_id for update;

  if v_sale.id is null then
    raise exception 'Sale not found.' using errcode = 'no_data_found';
  end if;
  if v_sale.status <> 'POSTED' then
    raise exception 'Only a POSTED sale can be delivered; this one is %.', v_sale.status
      using errcode = 'check_violation';
  end if;

  v_year := app.financial_year_token(v_sale.dealer_id, current_date);
  v_number := app.next_document_number(v_sale.dealer_id, null, 'DELIVERY', v_year);

  insert into public.deliveries
    (dealer_id, branch_id, sale_id, vehicle_id, delivery_number,
     delivered_by, received_by_name, odometer, remarks)
  values
    (v_sale.dealer_id, v_sale.branch_id, p_sale_id, v_sale.vehicle_id, v_number,
     auth.uid(), p_received_by, p_odometer, p_remarks);

  -- The customer now owns this unit. Recorded here because delivery is the
  -- moment it becomes true, and everything needed is already known.
  insert into public.customer_vehicles
    (dealer_id, customer_id, vehicle_id, model_id, variant_id,
     chassis_no, engine_no, registration_no, purchase_date, status)
  select v_sale.dealer_id, v_sale.customer_id, v.id, v.model_id, v.variant_id,
         v.chassis_no, v.engine_no, v.registration_no, current_date, 'ACTIVE'
    from public.vehicles v
   where v.id = v_sale.vehicle_id
  on conflict (vehicle_id) where vehicle_id is not null
  do update set customer_id = excluded.customer_id,
                registration_no = coalesce(excluded.registration_no, public.customer_vehicles.registration_no),
                status = 'ACTIVE',
                updated_at = now();

  update public.vehicles set status = 'DELIVERED', updated_by = auth.uid()
   where id = v_sale.vehicle_id;

  update public.sales set status = 'DELIVERED', delivered_by = auth.uid()
   where id = p_sale_id;

  return v_number;
end;
$$;

comment on function public.deliver_vehicle(uuid, text, numeric, text) is
  'Records the handover, closes the sale and registers the customer as the '
  'vehicle''s owner (spec §19, §11).';

-- -----------------------------------------------------------------------------
-- public.create_job_card() — spec §32, now linking the vehicle
-- -----------------------------------------------------------------------------
create or replace function public.create_job_card(
  p_branch_id       uuid,
  p_customer_id     uuid,
  p_service_type    text default 'PAID',
  p_registration_no text default null,
  p_odometer        numeric default null,
  p_complaint       text default null,
  p_customer_vehicle_id uuid default null,
  p_service_advisor_id  uuid default null,
  p_technician_id       uuid default null,
  p_promised_at     timestamptz default null,
  p_job_date        date default current_date
)
returns table (job_card_id uuid, job_card_number text)
language plpgsql
as $$
declare
  v_dealer uuid;
  v_number text;
  v_id     uuid;
  v_reg    text;
  v_cv     uuid := p_customer_vehicle_id;
begin
  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  v_number := app.next_document_number(
    v_dealer, p_branch_id, 'JOB_CARD', app.financial_year_token(v_dealer, p_job_date));

  v_reg := nullif(upper(btrim(p_registration_no)), '');

  -- A walk-in the dealer never sold still has a vehicle, and the workshop now
  -- knows its registration. Registering it here is what lets the second visit
  -- find the first. cv_registration_key is partial, so ON CONFLICT has to repeat
  -- its predicate or Postgres will not match the index.
  if v_cv is null and v_reg is not null then
    insert into public.customer_vehicles
      (dealer_id, customer_id, registration_no, status)
    values (v_dealer, p_customer_id, v_reg, 'ACTIVE')
    on conflict (dealer_id, registration_no) where registration_no is not null
    do update set customer_id = excluded.customer_id, updated_at = now()
    returning id into v_cv;
  end if;

  insert into public.job_cards
    (dealer_id, branch_id, job_card_number, job_date, customer_id, customer_vehicle_id,
     registration_no, odometer, service_type, complaint, service_advisor_id, technician_id,
     promised_at, created_by)
  values
    (v_dealer, p_branch_id, v_number, p_job_date, p_customer_id, v_cv,
     v_reg, p_odometer, p_service_type, p_complaint,
     p_service_advisor_id, p_technician_id, p_promised_at, auth.uid())
  returning id into v_id;

  job_card_id := v_id; job_card_number := v_number;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.customer_service_summary() — spec §33
-- -----------------------------------------------------------------------------
-- A rollup per customer, not per visit. /service/history already answers "what
-- happened on this job"; the question this answers is "who has stopped coming,
-- and who is worth the most", which no per-visit list makes visible.
-- -----------------------------------------------------------------------------
create or replace function public.customer_service_summary(
  p_customer_id uuid default null,
  p_branch_id   uuid default null
)
returns table (
  customer_id     uuid,
  customer_code   text,
  customer_name   text,
  mobile          text,
  vehicle_count   int,
  visit_count     int,
  first_visit     date,
  last_visit      date,
  days_since_last int,
  lifetime_value  numeric(18, 4),
  open_jobs       int
)
language sql
stable
as $$
  select c.id, c.customer_code, c.name, c.mobile,
         (select count(*)::int from public.customer_vehicles cv
           where cv.customer_id = c.id and cv.status = 'ACTIVE'),
         count(distinct j.id)::int,
         min(j.job_date),
         max(j.job_date),
         (current_date - max(j.job_date))::int,
         coalesce(sum(i.total_amount), 0)::numeric(18, 4),
         count(distinct j.id) filter (where j.status in ('OPEN', 'IN_PROGRESS', 'READY'))::int
    from public.customers c
    join public.job_cards j on j.customer_id = c.id
    left join public.service_invoices i
      on i.job_card_id = j.id and i.status <> 'CANCELLED'
   where (p_customer_id is null or c.id = p_customer_id)
     and (p_branch_id is null or j.branch_id = p_branch_id)
   group by c.id, c.customer_code, c.name, c.mobile
   order by max(j.job_date) desc;
$$;

comment on function public.customer_service_summary(uuid, uuid) is
  'Per-customer service rollup (spec §33): visits, lifetime value and how long '
  'since the last one, for spotting customers who have stopped coming.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.customer_service_summary(uuid, uuid) to authenticated';
  end if;
end;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0046_booking_advances.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0046 — Booking advances: applied on sale, refundable on cancellation
-- =============================================================================
-- Spec §18, §23, §41.
--
-- 0027 seeded BOOKING/APPLY/CUSTOMER_ADVANCE and BOOKING/APPLY/RECEIVABLE, and
-- nothing has ever invoked them. Converting a booking marks it CONVERTED and
-- stops there, so account 2100 (Customer Advances) accumulates every advance the
-- dealer has ever taken and releases none of them. The liability grows forever
-- and the customer's receivable is overstated by the advance they already paid.
--
-- Two functions close that:
--   * app.apply_booking_advance() releases the advance when the sale posts;
--   * public.refund_booking_advance() returns it when a booking is cancelled.
--
-- REFUND IS NOT AUTOMATIC ON CANCELLATION, deliberately. A cancelled booking's
-- advance is often retained as a forfeit, and auto-refunding would post money
-- the dealer never paid. It is a separate act, separately permitted.
--
-- Existing data keeps its stale 2100 balance: this releases advances from here
-- on, and back-posting entries for historical bookings would put journals into
-- closed periods. /bookings/advances shows the control balance alongside the
-- derived figure so the difference is visible rather than papered over.
--
-- Rollback: drop trigger sales_apply_advance on public.sales, then drop
--           app.sales_apply_advance(), app.apply_booking_advance(uuid) and
--           public.refund_booking_advance(uuid, numeric, text, text, uuid, uuid, date).
--           post_vehicle_sale() is untouched by this migration.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- app.apply_booking_advance() — spec §18
-- -----------------------------------------------------------------------------
-- Dr Customer Advances / Cr Customer Receivable: the money the customer already
-- paid stops being a liability and settles part of what they now owe. Both lines
-- carry the customer, so their ledger shows the advance being used.
--
-- Idempotent on the sale, so posting twice applies once.
-- -----------------------------------------------------------------------------
create or replace function app.apply_booking_advance(p_sale_id uuid)
returns uuid
language plpgsql
as $$
declare
  v_sale    public.sales;
  v_advance numeric(18, 4);
  v_apply   numeric(18, 4);
  v_debit   uuid;
  v_credit  uuid;
begin
  select * into v_sale from public.sales where id = p_sale_id;

  if v_sale.id is null or v_sale.booking_id is null then
    return null;  -- a walk-in sale has no advance to release
  end if;

  select coalesce(sum(amount), 0) into v_advance
    from public.booking_payments
   where booking_id = v_sale.booking_id and status = 'RECEIVED';

  if v_advance <= 0 then
    return null;
  end if;

  -- Never release more than the invoice is worth: the remainder stays a
  -- liability until it is refunded or applied elsewhere.
  v_apply := least(v_advance, v_sale.total_amount);

  v_debit  := app.require_account(v_sale.dealer_id, 'BOOKING', 'APPLY', 'CUSTOMER_ADVANCE', v_sale.branch_id);
  v_credit := app.require_account(v_sale.dealer_id, 'BOOKING', 'APPLY', 'RECEIVABLE', v_sale.branch_id);

  return app.post_journal(
    v_sale.dealer_id, v_sale.branch_id, v_sale.invoice_date, 'BOOKING',
    'Advance applied to ' || v_sale.invoice_number,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', v_apply, 'credit', 0,
                         'narration', 'Advance applied',
                         'party_type', 'CUSTOMER', 'party_id', v_sale.customer_id),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', v_apply,
                         'narration', 'Against ' || v_sale.invoice_number,
                         'party_type', 'CUSTOMER', 'party_id', v_sale.customer_id)
    ),
    'BOOKING_APPLY', p_sale_id, 'booking-apply:' || p_sale_id::text
  );
end;
$$;

comment on function app.apply_booking_advance(uuid) is
  'Releases a booking advance from Customer Advances against the invoice it was '
  'taken for (spec §18). Idempotent on the sale.';

-- -----------------------------------------------------------------------------
-- The advance is released when the sale posts
-- -----------------------------------------------------------------------------
-- A trigger rather than a change to post_vehicle_sale(). Rewriting that function
-- here would mean copying its hundred-line body into this migration, where the
-- copy would have to be kept in step with the original by hand forever. It also
-- means the release happens however a sale reaches POSTED, not only down the one
-- code path — the same reasoning as app.vehicles_log_movement() in 0017.
--
-- AFTER UPDATE, so the sale journal already exists and both entries land in the
-- same transaction.
-- -----------------------------------------------------------------------------
create or replace function app.sales_apply_advance()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'POSTED' and old.status is distinct from 'POSTED' then
    perform app.apply_booking_advance(new.id);
  end if;
  return null;
end;
$$;

create trigger sales_apply_advance
  after update on public.sales
  for each row execute function app.sales_apply_advance();

-- -----------------------------------------------------------------------------
-- public.refund_booking_advance() — spec §18, §23
-- -----------------------------------------------------------------------------
create or replace function public.refund_booking_advance(
  p_booking_id      uuid,
  p_amount          numeric,
  p_mode            text,
  p_reason          text,
  p_cash_branch_id  uuid default null,
  p_bank_account_id uuid default null,
  p_date            date default current_date
)
returns table (journal_entry_id uuid)
language plpgsql
as $$
declare
  v_b        public.bookings;
  v_received numeric(18, 4);
  v_debit    uuid;
  v_credit   uuid;
  v_entry    uuid;
  v_bank     public.bank_accounts;
  v_cash     public.cash_accounts;
  v_branch   uuid;
begin
  if p_amount <= 0 then
    raise exception 'The refund must be greater than zero.' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'A refund must say why.'
      using errcode = 'check_violation',
            hint = 'Spec §23: the reason is part of the record, not optional.';
  end if;

  select * into v_b from public.bookings where id = p_booking_id for update;
  if v_b.id is null then
    raise exception 'Booking not found.' using errcode = 'no_data_found';
  end if;

  -- Only a cancelled booking. A refund against a live booking would leave the
  -- customer with a reservation they have not paid for.
  if v_b.status <> 'CANCELLED' then
    raise exception 'Booking % is % — cancel it before refunding the advance.',
      v_b.booking_number, v_b.status using errcode = 'check_violation';
  end if;

  select coalesce(sum(amount), 0) into v_received
    from public.booking_payments
   where booking_id = p_booking_id and status = 'RECEIVED';

  if p_amount > v_received then
    raise exception 'Only % was received against %.', v_received, v_b.booking_number
      using errcode = 'check_violation';
  end if;

  v_debit := app.require_account(v_b.dealer_id, 'BOOKING', 'APPLY', 'CUSTOMER_ADVANCE', v_b.branch_id);

  if p_mode = 'CASH' then
    v_branch := coalesce(p_cash_branch_id, v_b.branch_id);
    select * into v_cash from public.cash_accounts where branch_id = v_branch;
    if v_cash.id is null then
      raise exception 'That branch has no cash account.' using errcode = 'no_data_found';
    end if;
    v_credit := v_cash.ledger_account_id;
    -- The day guard applies: a closed day cannot take a payment (spec §36).
    perform public.ensure_cash_day(v_branch, p_date);
  else
    select * into v_bank from public.bank_accounts where id = p_bank_account_id;
    if v_bank.id is null then
      raise exception 'Choose the bank account the refund was paid from.'
        using errcode = 'no_data_found';
    end if;
    v_branch := coalesce(v_bank.branch_id, v_b.branch_id);
    v_credit := v_bank.ledger_account_id;
  end if;

  v_entry := app.post_journal(
    v_b.dealer_id, v_branch, p_date, 'BOOKING',
    'Advance refunded on ' || v_b.booking_number,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', btrim(p_reason),
                         'party_type', 'CUSTOMER', 'party_id', v_b.customer_id),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', 'Refund of booking advance')
    ),
    'BOOKING_REFUND', p_booking_id, 'booking-refund:' || p_booking_id::text || ':' || p_amount::text
  );

  if p_mode = 'CASH' then
    insert into public.cash_transactions
      (dealer_id, branch_id, cash_account_id, business_date, direction, amount,
       particular, customer_id, journal_entry_id, created_by)
    values
      (v_b.dealer_id, v_branch, v_cash.id, p_date, 'PAYMENT', p_amount,
       'Advance refund ' || v_b.booking_number, v_b.customer_id, v_entry, auth.uid());
  else
    insert into public.bank_transactions
      (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
       customer_id, journal_entry_id, created_by)
    values
      (v_b.dealer_id, p_bank_account_id, p_date, 'PAYMENT', p_amount,
       'Advance refund ' || v_b.booking_number, v_b.customer_id, v_entry, auth.uid());
  end if;

  -- Reversing the receipts is what makes bookings.received_amount fall: the
  -- trigger in 0020 recomputes it from the RECEIVED rows.
  update public.booking_payments
     set status = 'REVERSED'
   where booking_id = p_booking_id and status = 'RECEIVED';

  journal_entry_id := v_entry;
  return next;
end;
$$;

comment on function public.refund_booking_advance(uuid, numeric, text, text, uuid, uuid, date) is
  'Returns a cancelled booking''s advance, clearing the liability and writing the '
  'cash or bank payment (spec §18, §23). Never automatic: an advance is often forfeit.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.refund_booking_advance(uuid, numeric, text, text, uuid, uuid, date) to authenticated';
  end if;
end;
$$;


commit;
