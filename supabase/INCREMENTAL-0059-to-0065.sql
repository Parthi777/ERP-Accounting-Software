-- =============================================================================
-- INCREMENTAL 0059 → 0065
-- =============================================================================
-- GENERATED FILE. Regenerate with:
--   FROM=0059 bash scripts/build-incremental.sh
--
-- For a database that ALREADY has migrations up to 0058.
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
-- SOURCE: supabase/migrations/0059_schema_version_stamp.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0059 — A database that can say which migration it is on
-- =============================================================================
-- Spec §59, §60.20.
--
-- The problem this closes. The application deploys to Railway on push, while
-- migrations are applied to Supabase by hand. Those two facts guarantee a window
-- in which the running code expects a schema the database does not have, and
-- nothing anywhere reports it. The symptom reaches a user as a PostgREST error
-- about a function signature, which tells the person who pressed the button
-- nothing they can act on, and tells the person who could fix it nothing at all
-- because they are not the one who saw it.
--
-- Two services already work around this by hand — settlement-service.ts guesses
-- from an error string that 0050 is missing, sale-service.ts does the same for
-- 0051. Both are honest patches over a missing fact: the database does not know
-- what it is. So record it.
--
-- ── Why a table and not a setting ───────────────────────────────────────────
--
-- system_settings is dealer-scoped configuration that an administrator changes.
-- The schema version is neither: it is one fact about the whole database, it is
-- written by migrations rather than by people, and it is a list rather than a
-- value — knowing 0058 was applied on Tuesday and 0059 has not been applied at
-- all is the useful form. A table keeps the history; a setting would keep only
-- the last answer.
--
-- ── On the backfilled timestamps ────────────────────────────────────────────
--
-- Every migration before this one is inserted here as applied, because a
-- database running this file necessarily ran them: migrations are applied in
-- order, and both bundles are wrapped in a single transaction. Their applied_at
-- is therefore the moment this migration ran, not the moment they did. That is a
-- true statement about *what* is applied and a false one about *when*, so the
-- column is named and commented accordingly rather than pretending to a history
-- that was never recorded.
--
-- From here on each migration stamps itself as its last statement, and
-- `npm run check:schema-version` fails the build if one forgets.
--
-- Rollback: drop table public.schema_migrations.
-- =============================================================================

create table public.schema_migrations (
  version     text primary key,
  name        text not null,
  -- When this row was written, which for rows backfilled by 0059 is when
  -- 0059 ran rather than when the migration itself was applied.
  applied_at  timestamptz not null default now()
);

comment on table public.schema_migrations is
  'Which migrations this database has. Written by migrations, never by users. '
  'Compared against the version the running application was built against, so a '
  'deploy that has outrun its schema is visible instead of being guessed at from '
  'PostgREST error strings.';

-- Not tenant data: one row per migration, identical for every dealer on this
-- database. Every public table carries RLS regardless (verify-migrations.sh
-- checks), so the policy is an explicit "any session may read this" rather than
-- an absence of one.
alter table public.schema_migrations enable row level security;

create policy schema_migrations_read on public.schema_migrations
  for select to authenticated using (true);

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  -- Release-managed, like public.permissions: readable by any session, writable
  -- only by migrations running as the owner or the service role.
  execute 'revoke insert, update, delete on public.schema_migrations from authenticated';
end $$;

-- -----------------------------------------------------------------------------
-- Backfill: everything up to and including this migration
-- -----------------------------------------------------------------------------
insert into public.schema_migrations (version, name) values
    ('0001', 'extensions_and_app_schema'),
    ('0002', 'organization'),
    ('0003', 'identity'),
    ('0004', 'rls_helpers'),
    ('0005', 'audit'),
    ('0006', 'document_sequences'),
    ('0007', 'accounting_core'),
    ('0008', 'system_settings'),
    ('0009', 'rls_policies'),
    ('0010', 'indexes'),
    ('0011', 'grants'),
    ('0012', 'reporting_functions'),
    ('0013', 'customers'),
    ('0014', 'tax_and_hsn'),
    ('0015', 'vehicle_catalogue'),
    ('0016', 'inventory_items'),
    ('0017', 'vehicle_stock'),
    ('0018', 'vehicle_pricing'),
    ('0019', 'inventory_stock'),
    ('0020', 'bookings_and_sales'),
    ('0021', 'finance'),
    ('0022', 'cash_and_bank'),
    ('0023', 'service'),
    ('0024', 'gst_and_accounting_rules'),
    ('0025', 'posting_engine'),
    ('0026', 'reports'),
    ('0027', 'default_accounting_rules'),
    ('0028', 'booking_and_sale_operations'),
    ('0029', 'create_sale_draft'),
    ('0030', 'cash_operations'),
    ('0031', 'bank_operations'),
    ('0032', 'bank_entry_permission'),
    ('0033', 'service_operations'),
    ('0034', 'gst_reports'),
    ('0035', 'mis_reports'),
    ('0036', 'transfers_returns_adjustments'),
    ('0037', 'customer_ledger_opening'),
    ('0038', 'delivery_document_sequence'),
    ('0039', 'dealer_wide_document_numbering'),
    ('0040', 'suppliers'),
    ('0041', 'party_ledger_and_supplier_payments'),
    ('0042', 'finance_accounting_rules'),
    ('0043', 'finance_operations'),
    ('0044', 'price_approval_workflow'),
    ('0045', 'customer_vehicle_writer'),
    ('0046', 'booking_advances'),
    ('0047', 'counter_sales'),
    ('0048', 'einvoice_payload'),
    ('0049', 'cash_book_and_cogs_classification'),
    ('0050', 'party_payment_allocation'),
    ('0051', 'sale_return_refund'),
    ('0052', 'purchases'),
    ('0053', 'hr_foundations'),
    ('0054', 'attendance_integration'),
    ('0055', 'dealer_status_gate'),
    ('0056', 'dealer_provisioning'),
    ('0057', 'purchase_returns'),
    ('0058', 'gst_input_tax'),
    ('0059', 'schema_version_stamp')
on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0060_list_totals.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0060 — Totals that do not depend on how many rows the screen drew
-- =============================================================================
-- Spec §41, §43, §51, §59.
--
-- The bug. A screen loads a capped list and then reduces over it to render the
-- figures at the top:
--
--     const rows   = await getFinanceApplications({ status, q });  -- limit 200
--     const totals = summarise(rows);                              -- "the period"
--
-- Under demo data every one of these is right, because there are never 200 rows.
-- A dealer passes 200 finance applications or 200 service invoices inside a
-- month, and from then on the tiles quietly report the most recent 200 while
-- presenting themselves as the period. The table underneath looks correct, which
-- is what makes it hard to notice: nothing is visibly broken, the numbers are
-- just smaller than the truth and drifting further every week.
--
-- A wrong total that announces itself is a bug. A wrong total that looks
-- plausible is a decision made on bad information.
--
-- ── Why SQL and not a bigger limit ──────────────────────────────────────────
--
-- Raising the cap moves the cliff, it does not remove it, and it makes the page
-- slower for everyone to postpone a wrong answer for whoever grows fastest. An
-- aggregate computed in Postgres has no cliff: it reads what matches and returns
-- one row.
--
-- ── Why the finance list moves here too ─────────────────────────────────────
--
-- getFinanceApplications() applied its search *in TypeScript, after* the limit,
-- so searching for a customer whose application was the 250th most recent
-- returned nothing — the row was never fetched. Fixing the totals alone would
-- have left the list and the totals disagreeing about what "matching" means, so
-- both now come from the same WHERE clause in this file. Two functions that must
-- agree should read one definition, not two copies of one.
--
-- Both are `stable` and `security invoker`, so RLS decides what a session may
-- count — a total that includes rows the reader may not see would be a leak.
--
-- Rollback: drop the three functions below.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- app.finance_application_match() — the shared predicate
-- -----------------------------------------------------------------------------
-- One definition of "matching", used by both the list and the totals. Inlined by
-- the planner; it exists so the two can never drift apart.
-- -----------------------------------------------------------------------------
create or replace function app.finance_application_match(
  p_status     text,
  p_row_status text,
  p_branch     uuid,
  p_row_branch uuid,
  p_q          text,
  p_haystack   text
)
returns boolean
language sql
immutable
as $$
  select (p_status is null or p_status = 'ALL' or p_row_status = p_status)
     and (p_branch is null or p_row_branch = p_branch)
     and (
       p_q is null
       or btrim(p_q) = ''
       or p_haystack ilike '%' || btrim(p_q) || '%'
     );
$$;

comment on function app.finance_application_match(text, text, uuid, uuid, text, text) is
  'Whether one finance application matches the screen filters. Shared by '
  'finance_applications_list and finance_application_totals so a searched list '
  'and its summary can never disagree about what was counted.';

-- -----------------------------------------------------------------------------
-- public.finance_applications_list() — the rows a screen draws
-- -----------------------------------------------------------------------------
create or replace function public.finance_applications_list(
  p_status    text default 'ALL',
  p_branch_id uuid default null,
  p_q         text default null,
  p_limit     integer default 200
)
returns table (
  id                  uuid,
  application_number  text,
  application_date    date,
  customer_id         uuid,
  customer_name       text,
  finance_company_id  uuid,
  company_name        text,
  chassis_no          text,
  branch_name         text,
  loan_amount         numeric(18, 4),
  down_payment        numeric(18, 4),
  approved_amount     numeric(18, 4),
  disbursed_amount    numeric(18, 4),
  pending_amount      numeric(18, 4),
  approval_status     text,
  disbursement_status text,
  dd_number           text,
  bank_reference      text,
  commission_amount   numeric(18, 4)
)
language sql
stable
as $$
  select f.id, f.application_number, f.application_date,
         f.customer_id, c.name, f.finance_company_id, fc.name,
         v.chassis_no, b.name,
         f.loan_amount, f.down_payment, f.approved_amount, f.disbursed_amount,
         f.pending_amount, f.approval_status, f.disbursement_status,
         f.dd_number, f.bank_reference, f.commission_amount
    from public.finance_applications f
    join public.customers        c  on c.id  = f.customer_id
    join public.finance_companies fc on fc.id = f.finance_company_id
    join public.branches         b  on b.id  = f.branch_id
    left join public.vehicles    v  on v.id  = f.vehicle_id
   where app.finance_application_match(
           p_status, f.approval_status,
           p_branch_id, f.branch_id,
           p_q,
           f.application_number || ' ' || c.name || ' ' || fc.name ||
             ' ' || coalesce(v.chassis_no, '')
         )
   order by f.application_date desc, f.application_number desc
   limit greatest(p_limit, 1);
$$;

comment on function public.finance_applications_list(text, uuid, text, integer) is
  'Finance applications matching the screen filters (spec §27). The search runs '
  'here rather than in the application, which used to filter the already-capped '
  'page and so could not find the 250th row.';

-- -----------------------------------------------------------------------------
-- public.finance_application_totals() — the figures above the list
-- -----------------------------------------------------------------------------
-- No limit. This is the whole point: the tiles describe the period, not the page.
-- -----------------------------------------------------------------------------
create or replace function public.finance_application_totals(
  p_status    text default 'ALL',
  p_branch_id uuid default null,
  p_q         text default null
)
returns table (
  applications      bigint,
  approved          bigint,
  pending           bigint,
  rejected          bigint,
  loan_amount       numeric(18, 4),
  disbursed_amount  numeric(18, 4),
  pending_amount    numeric(18, 4),
  commission_amount numeric(18, 4)
)
language sql
stable
as $$
  select count(*),
         count(*) filter (where f.approval_status = 'APPROVED'),
         count(*) filter (where f.approval_status = 'PENDING'),
         count(*) filter (where f.approval_status = 'REJECTED'),
         coalesce(sum(f.loan_amount), 0),
         coalesce(sum(f.disbursed_amount), 0),
         coalesce(sum(f.pending_amount), 0),
         coalesce(sum(f.commission_amount), 0)
    from public.finance_applications f
    join public.customers         c  on c.id  = f.customer_id
    join public.finance_companies fc on fc.id = f.finance_company_id
    left join public.vehicles     v  on v.id  = f.vehicle_id
   where app.finance_application_match(
           p_status, f.approval_status,
           p_branch_id, f.branch_id,
           p_q,
           f.application_number || ' ' || c.name || ' ' || fc.name ||
             ' ' || coalesce(v.chassis_no, '')
         );
$$;

comment on function public.finance_application_totals(text, uuid, text) is
  'Finance figures over every matching application, not the page (spec §27, §51). '
  'commission_amount is summed here and dropped in the service layer for sessions '
  'without finance.commission.view — the redaction stays where it always was.';

-- -----------------------------------------------------------------------------
-- public.service_invoice_totals() — the figures above the service billing list
-- -----------------------------------------------------------------------------
create or replace function public.service_invoice_totals(
  p_status    text default 'ALL',
  p_branch_id uuid default null
)
returns table (
  invoices     bigint,
  total_amount numeric(18, 4),
  paid_amount  numeric(18, 4),
  balance      numeric(18, 4)
)
language sql
stable
as $$
  select count(*),
         coalesce(sum(si.total_amount), 0),
         coalesce(sum(si.paid_amount), 0),
         coalesce(sum(si.total_amount - si.paid_amount), 0)
    from public.service_invoices si
   -- Counter sales share this table but are their own screen (spec §33), and the
   -- list this summarises excludes them. A total counting both would not match
   -- the rows underneath it.
   where si.invoice_type = 'SERVICE'
     and (p_status is null or p_status = 'ALL' or si.status = p_status)
     and (p_branch_id is null or si.branch_id = p_branch_id);
$$;

comment on function public.service_invoice_totals(text, uuid) is
  'Billed and outstanding over every matching service invoice, not the page '
  '(spec §51). Excludes counter sales, matching the list it sits above.';

-- -----------------------------------------------------------------------------
-- public.bank_unreconciled_counts() — how many items each account still has
-- -----------------------------------------------------------------------------
-- The bank screen used to fetch every unreconciled transaction and count them in
-- JavaScript. That is the same defect in a quieter form: it works, it is slow in
-- proportion to how long the dealer has been trading, and it is wrong the moment
-- PostgREST is configured with a row ceiling — at which point the badge simply
-- stops going up and nobody can tell.
--
-- Counting is the database's job.
-- -----------------------------------------------------------------------------
create or replace function public.bank_unreconciled_counts()
returns table (
  bank_account_id uuid,
  unreconciled    bigint
)
language sql
stable
as $$
  select t.bank_account_id, count(*)
    from public.bank_transactions t
   where t.reconciled = false
     and t.status = 'ACTIVE'
   group by t.bank_account_id;
$$;

comment on function public.bank_unreconciled_counts() is
  'Unreconciled item count per bank account (spec §39). One grouped count rather '
  'than fetching every transaction to length-check it in the application.';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  execute 'grant execute on function public.finance_applications_list(text, uuid, text, integer) to authenticated';
  execute 'grant execute on function public.finance_application_totals(text, uuid, text) to authenticated';
  execute 'grant execute on function public.service_invoice_totals(text, uuid) to authenticated';
  execute 'grant execute on function public.bank_unreconciled_counts() to authenticated';
  execute 'grant execute on function app.finance_application_match(text, text, uuid, uuid, text, text) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0060', 'list_totals') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0061_idempotent_receipts.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0061 — A retried receipt is the same receipt (spec §50)
-- =============================================================================
-- Spec §50, §36, §37, §38, §48.
--
-- What is broken. record_sale_payment, record_cash_transaction and
-- record_bank_transaction have no duplicate protection of any kind. Submit one
-- twice — a double-click that outran the disabled button, a phone that retried
-- on a flaky shop connection, a browser that resent the POST — and the dealer
-- has two receipts, two journals, and a cash book that is over by the amount.
--
-- Nothing downstream catches it. These are not corrections that a later screen
-- reconciles; they are the primary record. The cash book balances perfectly
-- against a day that never happened.
--
-- ── The slot that was there and did nothing ─────────────────────────────────
--
-- record_sale_payment already passed an idempotency key to app.post_journal:
--
--     'receipt:' || v_rnumber
--
-- where v_rnumber is minted from the document sequence two lines earlier. A
-- fresh number every call, so the key is unique every call, so it can never
-- match — the parameter was filled in and inert. Journal-level protection would
-- not have been enough anyway: a second call getting the first journal id back
-- would still insert a second sale_payments row against it, putting the receipt
-- twice in the receipts list and once in the trial balance, hidden from the one
-- report that would have caught it.
--
-- So the guard belongs at the top of each function, on its own document table,
-- before any sequence is consumed.
--
-- ── Why not a generic idempotency table ─────────────────────────────────────
--
-- A shared app-level table would be a second source of truth that any direct
-- RPC call bypasses, and a check-then-insert against it has a race that a unique
-- constraint does not. The constraint *is* the mechanism. 0057 already works
-- this way for purchase returns; this follows it.
--
-- ── What is deliberately NOT changed ────────────────────────────────────────
--
-- post_vehicle_sale, post_purchase_bill and post_service_invoice accept a key
-- and default it to one derived from the document id — 'sale:' || id, and so on.
-- That is strictly better than a client-minted key for posting an existing
-- document: it dedupes across sessions, devices and page refreshes, because the
-- key is a property of the document rather than of a browser tab. They are left
-- alone on purpose.
--
-- The distinction worth keeping: *posting* an existing document derives its key
-- from the document; *creating* one has no id yet, so the caller must supply it.
-- This migration covers the second kind.
--
-- Rollback: restore the three functions from 0041 and 0049, then
--   alter table public.cash_transactions drop column idempotency_key;  (&c.)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The columns, and the constraints that do the actual work
-- -----------------------------------------------------------------------------
-- Partial unique indexes: null keys are exempt, so every existing row and every
-- caller that does not supply one is unaffected. Scoped by dealer, because one
-- tenant must not be able to poison another's key namespace.
alter table public.cash_transactions add column if not exists idempotency_key text;
alter table public.bank_transactions add column if not exists idempotency_key text;
alter table public.sale_payments     add column if not exists idempotency_key text;

create unique index if not exists cash_txn_idempotency_key
  on public.cash_transactions (dealer_id, idempotency_key) where idempotency_key is not null;
create unique index if not exists bank_txn_idempotency_key
  on public.bank_transactions (dealer_id, idempotency_key) where idempotency_key is not null;
create unique index if not exists sale_payment_idempotency_key
  on public.sale_payments (dealer_id, idempotency_key) where idempotency_key is not null;

comment on column public.cash_transactions.idempotency_key is
  'Caller-supplied key making a retry replay rather than repeat (spec §50). Null '
  'for entries made before 0061 and for callers that do not supply one.';

-- -----------------------------------------------------------------------------
-- public.record_cash_transaction() — spec §37, now idempotent
-- -----------------------------------------------------------------------------
-- Adding a parameter needs a drop: `create or replace` with a different argument
-- list makes an *overload*, and supabase-js sends named arguments, so a call
-- omitting the new one becomes ambiguous and fails with PGRST203. Precedent for
-- the drop-and-recreate is 0041 itself.
-- -----------------------------------------------------------------------------
drop function if exists public.record_cash_transaction(uuid, text, numeric, text, uuid, uuid, text, date, uuid);

create function public.record_cash_transaction(
  p_branch_id   uuid,
  p_direction   text,
  p_amount      numeric,
  p_particular  text,
  p_account_id  uuid,
  p_customer_id uuid default null,
  p_reference   text default null,
  p_date        date default current_date,
  p_supplier_id uuid default null,
  p_idempotency_key text default null
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

  -- ── The guard (spec §50) ────────────────────────────────────────────────
  -- Before ensure_cash_day, deliberately. A retry arriving after the day was
  -- closed must replay the receipt it already wrote, not raise "the day is
  -- closed" at someone who is looking at a spinner.
  if p_idempotency_key is not null then
    select t.id, t.journal_entry_id, t.balance_after
      into v_txn, v_entry, v_balance
      from public.cash_transactions t
     where t.dealer_id = v_dealer
       and t.idempotency_key = p_idempotency_key;

    if v_txn is not null then
      transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
      return next;
      return;
    end if;
  end if;

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
    'CASH_BOOK', null,
    case when p_idempotency_key is null then null else 'cash:' || p_idempotency_key end
  );

  insert into public.cash_transactions
    (dealer_id, branch_id, cash_account_id, business_date, direction, amount,
     particular, reference_number, customer_id, supplier_id, journal_entry_id,
     idempotency_key, created_by)
  values
    (v_dealer, p_branch_id, v_account.id, p_date, p_direction, p_amount,
     p_particular, p_reference, p_customer_id, p_supplier_id, v_entry,
     p_idempotency_key, auth.uid())
  returning id, cash_transactions.balance_after into v_txn, v_balance;

  transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_bank_transaction() — spec §38, now idempotent
-- -----------------------------------------------------------------------------
drop function if exists public.record_bank_transaction(uuid, text, numeric, text, uuid, date, text, text, text, uuid, uuid);

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
  p_supplier_id     uuid default null,
  p_idempotency_key text default null
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

  -- ── The guard (spec §50) ────────────────────────────────────────────────
  -- Before the ACTIVE check, for the same reason the cash guard precedes the
  -- day-close check: a retry must replay what it wrote, not report a state that
  -- changed after it wrote it.
  if p_idempotency_key is not null then
    select t.id, t.journal_entry_id, t.balance_after
      into v_txn, v_entry, v_balance
      from public.bank_transactions t
     where t.dealer_id = v_bank.dealer_id
       and t.idempotency_key = p_idempotency_key;

    if v_txn is not null then
      transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
      return next;
      return;
    end if;
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
    'BANK_BOOK', null,
    case when p_idempotency_key is null then null else 'bank:' || p_idempotency_key end
  );

  insert into public.bank_transactions
    (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
     reference_number, utr, instrument_number, customer_id, supplier_id,
     journal_entry_id, idempotency_key, created_by)
  values
    (v_bank.dealer_id, p_bank_account_id, p_date, p_direction, p_amount, p_particular,
     p_reference, nullif(btrim(p_utr), ''), nullif(btrim(p_instrument), ''),
     p_customer_id, p_supplier_id, v_entry, p_idempotency_key, auth.uid())
  returning id, bank_transactions.balance_after into v_txn, v_balance;

  transaction_id := v_txn; journal_entry_id := v_entry; balance_after := v_balance;
  return next;
end;
$$;


-- -----------------------------------------------------------------------------
-- public.record_sale_payment() — spec §19, §27, now idempotent
-- -----------------------------------------------------------------------------
-- The one with no defence whatever: a POSTED sale accepts payments repeatedly by
-- design, which is correct — a customer may pay in instalments — and is exactly
-- why a repeated submission is indistinguishable from a second instalment
-- without a key to tell them apart.
-- -----------------------------------------------------------------------------
drop function if exists public.record_sale_payment(uuid, numeric, text, text, uuid);

create function public.record_sale_payment(
  p_sale_id      uuid,
  p_amount       numeric,
  p_payment_mode text,
  p_reference    text default null,
  p_finance_company_id uuid default null,
  p_idempotency_key text default null
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
  -- ── The guard (spec §50) ────────────────────────────────────────────────
  -- After the row lock, so a concurrent retry waits rather than racing; before
  -- the status check, so a retry arriving after delivery replays its receipt
  -- instead of raising; and before next_document_number, so a replay does not
  -- burn a RECEIPT number. A gap in a financial series is not cosmetic.
  if p_idempotency_key is not null then
    select p.receipt_number, p.journal_entry_id
      into receipt_number, journal_entry_id
      from public.sale_payments p
     where p.dealer_id = v_sale.dealer_id
       and p.idempotency_key = p_idempotency_key;

    if receipt_number is not null then
      return next;
      return;
    end if;
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
    'SALE_PAYMENT', p_sale_id,
    -- Was 'receipt:' || v_rnumber, which is minted from the sequence a few lines
    -- above: a different key on every call, so it could never match and the
    -- parameter did nothing. The caller's key is the one that can.
    coalesce('receipt:' || p_idempotency_key, 'receipt:' || v_rnumber)
  );

  insert into public.sale_payments
    (dealer_id, sale_id, receipt_number, amount, payment_mode, reference,
     finance_company_id, journal_entry_id, idempotency_key, created_by)
  values
    (v_sale.dealer_id, p_sale_id, v_rnumber, p_amount, p_payment_mode, p_reference,
     p_finance_company_id, v_entry, p_idempotency_key, auth.uid());

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

  -- 0049: FINANCE returns immediately inside the helper — no money has moved.
  perform app.record_money_movement(
    v_sale.dealer_id, v_sale.branch_id, current_date, p_payment_mode, 'RECEIPT',
    p_amount, 'Receipt ' || v_rnumber || ' — ' || v_sale.invoice_number,
    coalesce(p_reference, v_rnumber), v_entry, v_sale.customer_id);

  receipt_number := v_rnumber; journal_entry_id := v_entry;
  return next;
end;
$$;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  -- Grants are per-signature and were dropped with the old functions.
  execute 'grant execute on function public.record_cash_transaction(uuid, text, numeric, text, uuid, uuid, text, date, uuid, text) to authenticated';
  execute 'grant execute on function public.record_bank_transaction(uuid, text, numeric, text, uuid, date, text, text, text, uuid, uuid, text) to authenticated';
  execute 'grant execute on function public.record_sale_payment(uuid, numeric, text, text, uuid, text) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0061', 'idempotent_receipts') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0062_idempotent_sale_draft.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0062 — The dead column on public.sales, finally written to
-- =============================================================================
-- Spec §50, §45, §19.
--
-- sales.idempotency_key and its unique index have existed since 0020. Nothing
-- has ever written them: create_vehicle_sale_draft took no key, so the column
-- was null on every row and the index guarded nothing. A guarantee that is
-- declared and not wired is worse than an absent one, because it reads as
-- handled.
--
-- What happens today without it. A double-submitted sale is caught — but by
-- sales_vehicle_active_key, the unique index on the chassis, and only *after*
-- app.next_document_number has issued an invoice number and the transaction has
-- rolled it away. The dealer is protected from a duplicate sale and left with a
-- hole in the invoice series, which under GST is not a cosmetic problem: the
-- series is expected to be continuous, and every gap is a question to answer at
-- filing time.
--
-- The guard therefore goes before the number is drawn, and before the
-- availability check — a retry arriving after the first call moved the chassis
-- to SOLD_PENDING_DELIVERY must replay its draft, not report the vehicle as
-- unavailable to someone who is looking at a spinner.
--
-- Rollback: restore create_vehicle_sale_draft from 0029.
-- =============================================================================

drop function if exists public.create_vehicle_sale_draft(uuid, uuid, date, uuid, uuid, numeric, text);

create function public.create_vehicle_sale_draft(
  p_customer_id  uuid,
  p_vehicle_id   uuid,
  p_invoice_date date default current_date,
  p_booking_id   uuid default null,
  p_sales_executive_id uuid default null,
  p_discount     numeric default 0,
  p_notes        text default null,
  p_idempotency_key text default null
)
returns table (sale_id uuid, invoice_number text, total_amount numeric)
language plpgsql
as $$
declare
  v_vehicle  public.vehicles;
  v_price    record;
  v_tax      record;
  v_dealer   uuid;
  v_year     text;
  v_number   text;
  v_sale     uuid;
  v_line     smallint := 0;
  v_hsn      text;
  v_model_tax text;
begin
  select * into v_vehicle from public.vehicles where id = p_vehicle_id for update;

  if v_vehicle.id is null then
    raise exception 'Vehicle not found.' using errcode = 'no_data_found';
  end if;
  v_dealer := v_vehicle.dealer_id;

  -- ── The guard (spec §50) ────────────────────────────────────────────────
  -- Before the availability check, deliberately. A retry arriving after the
  -- vehicle has moved to SOLD_PENDING_DELIVERY — which the first call did —
  -- must replay the draft it created, not report the chassis as unavailable.
  --
  -- And long before next_document_number. sales_vehicle_active_key already
  -- rejected a second draft for the same chassis, but only *after* an invoice
  -- number had been issued and thrown away, leaving a hole in the GST series
  -- that has to be explained at filing time.
  if p_idempotency_key is not null then
    select s.id, s.invoice_number into v_sale, v_number
      from public.sales s
     where s.dealer_id = v_dealer
       and s.idempotency_key = p_idempotency_key;

    if v_sale is not null then
      sale_id := v_sale;
      invoice_number := v_number;
      select s.total_amount into total_amount from public.sales s where s.id = v_sale;
      return next;
      return;
    end if;
  end if;

  if v_vehicle.status not in ('IN_STOCK', 'BOOKED') then
    raise exception 'Vehicle % is % and is not available for sale.', v_vehicle.chassis_no, v_vehicle.status
      using errcode = 'check_violation';
  end if;

  -- The price in force on the invoice date, not today's price (spec §42).
  select * into v_price
    from public.resolve_vehicle_price(v_dealer, v_vehicle.model_id, v_vehicle.variant_id,
                                      v_vehicle.branch_id, p_invoice_date);

  if v_price.price_version_id is null then
    raise exception 'No price is configured for this model on %.', p_invoice_date
      using errcode = 'no_data_found',
            hint = 'Add a price version before selling this model.';
  end if;

  select m.tax_code, h.code into v_model_tax, v_hsn
    from public.vehicle_models m
    left join public.hsn_codes h on h.id = m.hsn_code_id
   where m.id = v_vehicle.model_id;

  select * into v_tax
    from public.resolve_tax_code(v_dealer, coalesce(v_price.tax_code, v_model_tax), p_invoice_date);

  v_year := app.financial_year_token(v_dealer, p_invoice_date);
  v_number := app.next_document_number(v_dealer, v_vehicle.branch_id, 'VEHICLE_INVOICE', v_year);

  insert into public.sales
    (dealer_id, branch_id, invoice_number, invoice_date, customer_id, vehicle_id,
     booking_id, price_version_id, sales_executive_id, notes, idempotency_key, created_by)
  values
    (v_dealer, v_vehicle.branch_id, v_number, p_invoice_date, p_customer_id, p_vehicle_id,
     p_booking_id, v_price.price_version_id, p_sales_executive_id, p_notes,
     p_idempotency_key, auth.uid())
  returning id into v_sale;

  -- ── One line per price component (spec §20) ───────────────────────────────
  -- Only the vehicle itself carries GST here; insurance and registration are
  -- pass-through in most dealer setups, and forwarding is taxed separately by
  -- configuration. A dealer whose treatment differs edits the lines before
  -- submitting, which is why the invoice is a draft first.
  if v_price.ex_showroom > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, hsn_code, quantity, unit_rate,
       taxable_value, tax_code, cgst_rate, sgst_rate, cgst_amount, sgst_amount, total_amount,
       unit_cost, cost_amount)
    values
      (v_sale, v_dealer, v_line, 'VEHICLE',
       coalesce((select m.brand || ' ' || m.name from public.vehicle_models m where m.id = v_vehicle.model_id), 'Vehicle'),
       v_hsn, 1, v_price.ex_showroom, v_price.ex_showroom,
       v_tax.code, coalesce(v_tax.cgst_rate, 0), coalesce(v_tax.sgst_rate, 0),
       round(v_price.ex_showroom * coalesce(v_tax.cgst_rate, 0) / 100, 2),
       round(v_price.ex_showroom * coalesce(v_tax.sgst_rate, 0) / 100, 2),
       v_price.ex_showroom
         + round(v_price.ex_showroom * coalesce(v_tax.cgst_rate, 0) / 100, 2)
         + round(v_price.ex_showroom * coalesce(v_tax.sgst_rate, 0) / 100, 2),
       -- COGS uses what this specific unit cost, not the price master's figure.
       v_vehicle.purchase_cost, v_vehicle.purchase_cost);
  end if;

  if v_price.insurance > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'INSURANCE', 'Insurance', 1,
            v_price.insurance, v_price.insurance, v_price.insurance);
  end if;

  if v_price.registration > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'REGISTRATION', 'Registration (LTRT)', 1,
            v_price.registration, v_price.registration, v_price.registration);
  end if;

  if v_price.mandatory_accessories > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'ACCESSORY', 'Mandatory accessories', 1,
            v_price.mandatory_accessories, v_price.mandatory_accessories, v_price.mandatory_accessories);
  end if;

  if v_price.forwarding_charge > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'FORWARDING', 'Forwarding charges', 1,
            v_price.forwarding_charge, v_price.forwarding_charge, v_price.forwarding_charge);
  end if;

  if v_price.other_charges > 0 then
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'OTHER_CHARGE', 'Other charges', 1,
            v_price.other_charges, v_price.other_charges, v_price.other_charges);
  end if;

  -- A discount beyond what the price version permits is a policy breach, not a
  -- rounding difference (spec §15).
  if p_discount > 0 then
    if p_discount > v_price.max_discount then
      raise exception 'A discount of % exceeds the maximum of % allowed on this price version.',
        p_discount, v_price.max_discount
        using errcode = 'check_violation';
    end if;
    v_line := v_line + 1;
    insert into public.sale_lines
      (sale_id, dealer_id, line_number, line_type, description, quantity, unit_rate,
       discount, taxable_value, total_amount)
    values (v_sale, v_dealer, v_line, 'DISCOUNT', 'Discount', 1, 0, p_discount, 0, 0);
  end if;

  -- Reserve the chassis so no other draft can claim it (spec §49).
  if v_vehicle.status = 'IN_STOCK' then
    update public.vehicles set status = 'BOOKED', updated_by = auth.uid() where id = p_vehicle_id;
  end if;

  -- Converting a booking closes it.
  if p_booking_id is not null then
    update public.bookings
       set status = 'CONVERTED', converted_sale_id = v_sale, updated_by = auth.uid()
     where id = p_booking_id and status = 'OPEN';
  end if;

  sale_id := v_sale;
  invoice_number := v_number;
  select s.total_amount into total_amount from public.sales s where s.id = v_sale;
  return next;
end;
$$;

comment on function public.create_vehicle_sale_draft(uuid, uuid, date, uuid, uuid, numeric, text, text) is
  'Creates a DRAFT vehicle sale priced at the invoice date (spec §19, §42). '
  'A repeated call carrying the same idempotency key replays the draft it made '
  'rather than drawing a second invoice number (spec §50).';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  -- Per-signature, and the old one went with the drop.
  execute 'grant execute on function public.create_vehicle_sale_draft(uuid, uuid, date, uuid, uuid, numeric, text, text) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0062', 'idempotent_sale_draft') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0063_idempotent_second_wave.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0063 — Idempotency for the remaining money endpoints (spec §50)
-- =============================================================================
-- Spec §50, §18, §26, §32, §33.
--
-- 0061 and 0062 covered the endpoints a cashier touches most: sale payments,
-- cash, bank, and the sale draft. These five are the rest of the money surface —
-- service receipts, counter invoices, booking advances, advance refunds and
-- finance-company trade advances. Every one of them writes a document and a
-- journal, and every one of them could be submitted twice.
--
-- Three different shapes turned up, which is worth recording because the third
-- is the one that looks safe:
--
--   1. No protection at all — record_service_payment and record_trade_advance
--      passed a null idempotency key to app.post_journal.
--
--   2. A key that could never match — create_booking_with_advance passed
--      'booking:' || v_booking, minted from the row it had just inserted. The
--      same defect 0061 found in record_sale_payment: the parameter was filled
--      in and inert.
--
--   3. A deterministic key that made things *worse* — refund_booking_advance
--      passes 'booking-refund:<booking>:<amount>', which is stable across calls,
--      so app.post_journal correctly replays the first journal on a second call.
--      The function then carried on and inserted a second cash or bank row
--      against that replayed journal. The refund appeared twice in the cash book
--      and once in the ledger: over-reported on the day sheet, and invisible to
--      the trial balance that would otherwise have caught it. Half a guard was
--      worse than none, because it moved the damage somewhere nobody reconciles.
--
-- The fix in all three cases is the same and is the rule 0061 established: guard
-- at the top of the function, on its own document table, before any sequence is
-- consumed and before any row is written.
--
-- Rollback: restore these five from 0043, 0046, 0047 and 0049, then drop the
-- three columns added below.
-- =============================================================================

-- service_invoices has carried idempotency_key since 0023 and bookings did not;
-- the partial unique indexes exempt nulls, so nothing that predates this or
-- declines to opt in is affected.
alter table public.service_payments     add column if not exists idempotency_key text;
alter table public.bookings             add column if not exists idempotency_key text;
alter table public.finance_transactions add column if not exists idempotency_key text;

create unique index if not exists service_payment_idempotency_key
  on public.service_payments (dealer_id, idempotency_key) where idempotency_key is not null;
create unique index if not exists booking_idempotency_key
  on public.bookings (dealer_id, idempotency_key) where idempotency_key is not null;
create unique index if not exists finance_txn_idempotency_key
  on public.finance_transactions (dealer_id, idempotency_key) where idempotency_key is not null;

-- -----------------------------------------------------------------------------
-- public.record_service_payment() — spec §32, §33
-- -----------------------------------------------------------------------------
drop function if exists public.record_service_payment(uuid, numeric, text, text, date);

create function public.record_service_payment(
  p_invoice_id   uuid,
  p_amount       numeric,
  p_payment_mode text default 'CASH',
  p_reference    text default null,
  p_date         date default current_date,
  p_idempotency_key text default null
)
returns table (payment_id uuid, receipt_number text, balance_due numeric)
language plpgsql
as $$
declare
  v_invoice public.service_invoices;
  v_number  text;
  v_entry   uuid;
  v_debit   uuid;
  v_credit  uuid;
  v_id      uuid;
  v_balance numeric(18, 4);
begin
  select * into v_invoice from public.service_invoices where id = p_invoice_id for update;

  if v_invoice.id is null then
    raise exception 'Invoice not found.' using errcode = 'no_data_found';
  end if;
  -- The guard (spec §50): after the invoice lock, before the status and
  -- outstanding checks, and well before next_document_number. A retry arriving
  -- once the invoice is fully paid must replay its receipt, not be told the
  -- amount exceeds what is outstanding.
  if p_idempotency_key is not null then
    select p.id, p.receipt_number into v_id, v_number
      from public.service_payments p
     where p.dealer_id = v_invoice.dealer_id
       and p.idempotency_key = p_idempotency_key;

    if v_id is not null then
      select si.total_amount - si.paid_amount into v_balance
        from public.service_invoices si where si.id = p_invoice_id;
      payment_id := v_id; receipt_number := v_number; balance_due := v_balance;
      return next;
      return;
    end if;
  end if;

  if v_invoice.status <> 'POSTED' then
    raise exception 'Invoice % is % — only a posted invoice can take a payment.',
      v_invoice.invoice_number, v_invoice.status using errcode = 'check_violation';
  end if;
  if p_amount <= 0 then
    raise exception 'The payment amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_amount > v_invoice.total_amount - v_invoice.paid_amount then
    raise exception 'That is more than the % outstanding on this invoice.',
      v_invoice.total_amount - v_invoice.paid_amount using errcode = 'check_violation';
  end if;

  v_number := app.next_document_number(
    v_invoice.dealer_id, v_invoice.branch_id, 'RECEIPT',
    app.financial_year_token(v_invoice.dealer_id, p_date));

  v_debit := app.require_account(
    v_invoice.dealer_id,
    case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
    'RECEIPT',
    case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
    v_invoice.branch_id);

  v_credit := app.require_account(v_invoice.dealer_id, 'SERVICE', 'INVOICE', 'RECEIVABLE', v_invoice.branch_id);

  v_entry := app.post_journal(
    v_invoice.dealer_id, v_invoice.branch_id, p_date,
    case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
    'Receipt ' || v_number || ' against ' || v_invoice.invoice_number,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', v_number),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', v_invoice.invoice_number,
                         'party_type', case when v_invoice.customer_id is not null then 'CUSTOMER' end,
                         'party_id', v_invoice.customer_id)
    ),
    'SERVICE_RECEIPT', p_invoice_id, null);

  insert into public.service_payments
    (dealer_id, invoice_id, receipt_number, payment_date, amount, payment_mode,
     reference, journal_entry_id, idempotency_key, created_by)
  values
    (v_invoice.dealer_id, p_invoice_id, v_number, p_date, p_amount, p_payment_mode,
     p_reference, v_entry, p_idempotency_key, auth.uid())
  returning id into v_id;

  -- 0049: counter and workshop takings reach the cash book.
  perform app.record_money_movement(
    v_invoice.dealer_id, v_invoice.branch_id, p_date, p_payment_mode, 'RECEIPT',
    p_amount, 'Receipt ' || v_number || ' — ' || v_invoice.invoice_number,
    coalesce(p_reference, v_number), v_entry, v_invoice.customer_id);

  select si.total_amount - si.paid_amount into v_balance
    from public.service_invoices si where si.id = p_invoice_id;

  payment_id := v_id; receipt_number := v_number; balance_due := v_balance;
  return next;
end;
$$;
-- -----------------------------------------------------------------------------
-- public.create_counter_invoice() — spec §33
-- -----------------------------------------------------------------------------
drop function if exists public.create_counter_invoice(uuid, uuid, date);

create function public.create_counter_invoice(
  p_branch_id    uuid,
  p_customer_id  uuid default null,
  p_invoice_date date default current_date,
  p_idempotency_key text default null
)
returns table (invoice_id uuid, invoice_number text)
language plpgsql
as $$
declare
  v_dealer   uuid;
  v_number   text;
  v_id       uuid;
  v_required boolean;
begin
  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  -- The guard (spec §50). service_invoices has carried idempotency_key since
  -- 0023 for the workshop side; the counter never used it.
  if p_idempotency_key is not null then
    select si.id, si.invoice_number into v_id, v_number
      from public.service_invoices si
     where si.dealer_id = v_dealer
       and si.idempotency_key = p_idempotency_key;

    if v_id is not null then
      invoice_id := v_id; invoice_number := v_number;
      return next;
      return;
    end if;
  end if;

  select coalesce((value)::text = 'true', false) into v_required
    from public.system_settings
   where key = 'counter_sale.require_customer'
     and (dealer_id = v_dealer or dealer_id is null)
   order by dealer_id nulls last
   limit 1;

  if coalesce(v_required, false) and p_customer_id is null then
    raise exception 'This dealer requires a customer on every counter sale.'
      using errcode = 'check_violation',
            hint = 'Spec §33: the customer is optional or required by configuration.';
  end if;

  v_number := app.next_document_number(
    v_dealer, p_branch_id, 'COUNTER_INVOICE',
    app.financial_year_token(v_dealer, p_invoice_date));

  insert into public.service_invoices
    (dealer_id, branch_id, invoice_number, invoice_date, invoice_type,
     job_card_id, customer_id, idempotency_key, created_by)
  values
    (v_dealer, p_branch_id, v_number, p_invoice_date, 'COUNTER',
     null, p_customer_id, p_idempotency_key, auth.uid())
  returning id into v_id;

  invoice_id := v_id; invoice_number := v_number;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.create_booking_with_advance() — spec §18
-- -----------------------------------------------------------------------------
drop function if exists public.create_booking_with_advance(uuid, uuid, uuid, numeric, numeric, text, uuid, uuid, date, uuid, text, text);

create function public.create_booking_with_advance(
  p_customer_id       uuid,
  p_model_id          uuid,
  p_branch_id         uuid,
  p_booking_amount    numeric,
  p_advance_amount    numeric,
  p_payment_mode      text,
  p_variant_id        uuid default null,
  p_vehicle_id        uuid default null,
  p_expected_delivery date default null,
  p_sales_executive_id uuid default null,
  p_reference         text default null,
  p_notes             text default null,
  p_idempotency_key   text default null
)
returns table (booking_id uuid, booking_number text, receipt_number text, journal_entry_id uuid)
language plpgsql
as $$
declare
  v_dealer_id uuid;
  v_year      text;
  v_booking   uuid;
  v_bnumber   text;
  v_rnumber   text;
  v_entry     uuid;
  v_debit_acc uuid;
  v_credit_acc uuid;
  v_cash_component text;
begin
  if p_advance_amount <= 0 then
    raise exception 'The advance amount must be greater than zero.'
      using errcode = 'check_violation';
  end if;
  if p_booking_amount > 0 and p_advance_amount > p_booking_amount then
    raise exception 'The advance cannot exceed the booking amount.'
      using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer_id from public.branches where id = p_branch_id;
  if v_dealer_id is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  -- The guard (spec §50): before two document numbers are drawn. The journal
  -- key this function already passed was 'booking:' || v_booking, minted from
  -- the row it had just created — unique every call, so it could never match.
  if p_idempotency_key is not null then
    select b.id, b.booking_number into v_booking, v_bnumber
      from public.bookings b
     where b.dealer_id = v_dealer_id
       and b.idempotency_key = p_idempotency_key;

    if v_booking is not null then
      select bp.receipt_number, bp.journal_entry_id into v_rnumber, v_entry
        from public.booking_payments bp
       where bp.booking_id = v_booking and bp.status = 'RECEIVED'
       order by bp.created_at limit 1;

      booking_id := v_booking; booking_number := v_bnumber;
      receipt_number := v_rnumber; journal_entry_id := v_entry;
      return next;
      return;
    end if;
  end if;

  v_year := app.financial_year_token(v_dealer_id, current_date);

  -- Resolve accounts before writing anything: an unconfigured mapping should
  -- fail before a booking number is consumed.
  v_cash_component := case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end;
  v_debit_acc  := app.require_account(v_dealer_id, 'BOOKING', 'ADVANCE', v_cash_component, p_branch_id);
  v_credit_acc := app.require_account(v_dealer_id, 'BOOKING', 'ADVANCE', 'CUSTOMER_ADVANCE', p_branch_id);

  v_bnumber := app.next_document_number(v_dealer_id, p_branch_id, 'BOOKING', v_year);
  v_rnumber := app.next_document_number(v_dealer_id, p_branch_id, 'RECEIPT', v_year);

  insert into public.bookings
    (dealer_id, branch_id, booking_number, customer_id, model_id, variant_id, vehicle_id,
     booking_amount, expected_delivery, sales_executive_id, notes, idempotency_key, created_by)
  values
    (v_dealer_id, p_branch_id, v_bnumber, p_customer_id, p_model_id, p_variant_id, p_vehicle_id,
     p_booking_amount, p_expected_delivery, p_sales_executive_id, p_notes,
     p_idempotency_key, auth.uid())
  returning id into v_booking;

  -- Spec §18: the advance is a liability until the sale is raised.
  v_entry := app.post_journal(
    v_dealer_id, p_branch_id, current_date, 'BOOKING',
    'Booking advance ' || v_bnumber,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit_acc, 'debit', p_advance_amount, 'credit', 0,
                         'narration', p_payment_mode || ' received'),
      jsonb_build_object('account_id', v_credit_acc, 'debit', 0, 'credit', p_advance_amount,
                         'narration', 'Customer advance',
                         'party_type', 'CUSTOMER', 'party_id', p_customer_id)
    ),
    'BOOKING', v_booking, 'booking:' || v_booking::text
  );

  insert into public.booking_payments
    (dealer_id, booking_id, receipt_number, amount, payment_mode, reference,
     journal_entry_id, created_by)
  values
    (v_dealer_id, v_booking, v_rnumber, p_advance_amount, p_payment_mode, p_reference,
     v_entry, auth.uid());

  -- Reserving a specific chassis takes it out of available stock (spec §13).
  if p_vehicle_id is not null then
    update public.vehicles set status = 'BOOKED', updated_by = auth.uid()
     where id = p_vehicle_id and status = 'IN_STOCK';
  end if;

  -- 0049: and into the cash or bank book, which is where the cashier looks.
  perform app.record_money_movement(
    v_dealer_id, p_branch_id, current_date, p_payment_mode, 'RECEIPT',
    p_advance_amount, 'Booking advance ' || v_bnumber, coalesce(p_reference, v_rnumber),
    v_entry, p_customer_id);

  booking_id := v_booking; booking_number := v_bnumber;
  receipt_number := v_rnumber; journal_entry_id := v_entry;
  return next;
end;
$$;
-- -----------------------------------------------------------------------------
-- public.refund_booking_advance() — spec §18, §23
-- -----------------------------------------------------------------------------
drop function if exists public.refund_booking_advance(uuid, numeric, text, text, uuid, uuid, date);

create function public.refund_booking_advance(
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

  -- The guard (spec §50).
  --
  -- This one already had half a defence and it made things worse. The journal
  -- key below is deterministic — 'booking-refund:<booking>:<amount>' — so
  -- app.post_journal replays the first entry on a second call. The function then
  -- carried on and inserted a *second* cash or bank row against that same
  -- journal, so the refund appeared twice in the cash book and once in the
  -- ledger: over-reported in the day sheet, and invisible to the trial balance
  -- that would otherwise have caught it.
  --
  -- Returning here is what makes the replay complete rather than partial.
  --
  -- And it sits above the status and received-amount checks deliberately. The
  -- first call reverses the booking_payments rows, so a replay that reached
  -- those checks would be told "only 0.0000 was received" — refusing to repeat
  -- itself with an error that describes the state it created. A guard placed
  -- after the checks it is meant to skip is not a guard.
  select je.id into v_entry
    from public.journal_entries je
   where je.dealer_id = v_b.dealer_id
     and je.idempotency_key =
         'booking-refund:' || p_booking_id::text || ':' || p_amount::text;

  if v_entry is not null then
    journal_entry_id := v_entry;
    return next;
    return;
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
-- -----------------------------------------------------------------------------
-- public.record_trade_advance() — spec §26
-- -----------------------------------------------------------------------------
drop function if exists public.record_trade_advance(uuid, uuid, text, numeric, uuid, date, text, text);

create function public.record_trade_advance(
  p_finance_company_id uuid,
  p_branch_id          uuid,
  p_type               text,
  p_amount             numeric,
  p_bank_account_id    uuid default null,
  p_date               date default current_date,
  p_narration          text default null,
  p_reference          text default null,
  p_idempotency_key    text default null
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

  -- The guard (spec §50). A finance company's ledger is reconciled against the
  -- financier's own statement; a duplicated advance is an argument with someone
  -- who has the money.
  if p_idempotency_key is not null then
    select ft.id, ft.journal_entry_id into v_txn, v_entry
      from public.finance_transactions ft
     where ft.dealer_id = v_dealer
       and ft.idempotency_key = p_idempotency_key;

    if v_txn is not null then
      transaction_id := v_txn; journal_entry_id := v_entry;
      return next;
      return;
    end if;
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
     debit, credit, reference_type, reference_number, narration, journal_entry_id,
     idempotency_key, created_by)
  values
    (v_dealer, p_branch_id, p_finance_company_id, p_date, p_type,
     v_debit_amt, v_credit_amt, 'TRADE_ADVANCE', p_reference, v_narration, v_entry,
     p_idempotency_key, auth.uid())
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
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  -- Per-signature, and every one of them went with its drop.
  execute 'grant execute on function public.record_service_payment(uuid, numeric, text, text, date, text) to authenticated';
  execute 'grant execute on function public.create_counter_invoice(uuid, uuid, date, text) to authenticated';
  execute 'grant execute on function public.create_booking_with_advance(uuid, uuid, uuid, numeric, numeric, text, uuid, uuid, date, uuid, text, text, text) to authenticated';
  execute 'grant execute on function public.refund_booking_advance(uuid, numeric, text, text, uuid, uuid, date) to authenticated';
  execute 'grant execute on function public.record_trade_advance(uuid, uuid, text, numeric, uuid, date, text, text, text) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0063', 'idempotent_second_wave') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0064_dashboard_unit_counts.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0064 — The unit counts the dashboard has been apologising for
-- =============================================================================
-- Spec §10, §43, §59.
--
-- Seven of the dashboard's KPI tiles have been rendering dimmed, with a badge
-- naming the phase that would deliver them:
--
--   Vehicle Sales · Bookings · Deliveries · Vehicle Stock (Qty)
--   Accessories Stock (Qty) · Spare Stock (Qty) · Finance Units
--
-- Every one of those phases has shipped. The tiles were honest when written —
-- dashboard-service.ts sets out the rule that a card must not invent a number —
-- and they have been wrong for months, telling a dealer that modules they use
-- daily have not arrived. That is the same failure as a fake number, pointed the
-- other way.
--
-- ── Why the ledger could not answer ─────────────────────────────────────────
--
-- The file's own comment explains it: a journal records value, not units. Every
-- `ready` tile comes from account_balances(), which cannot say how many vehicles
-- were sold, only what they were worth. So these seven need their own aggregate,
-- and this is it — one round trip for all of them rather than seven.
--
-- Stock counts are "as at now", not "within the period". A stock figure is a
-- position, and a position has no date range: asking how much stock existed
-- between two dates is not a question with an answer. The period filter applies
-- to the four flow counts and is deliberately ignored by the three stock ones.
--
-- Rollback: drop function public.dashboard_unit_counts(date, date, uuid);
-- =============================================================================

create or replace function public.dashboard_unit_counts(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  vehicle_sales_units bigint,
  bookings            bigint,
  deliveries          bigint,
  vehicle_stock_qty   bigint,
  accessory_stock_qty numeric,
  spare_stock_qty     numeric,
  finance_units       bigint
)
language sql
stable
as $$
  select
    -- Sold, by invoice date. POSTED and DELIVERED both count: the sale is made
    -- when it is posted, and delivery is a later event with its own tile.
    (select count(*) from public.sales s
      where s.status in ('POSTED', 'DELIVERED')
        and s.invoice_date between p_from and p_to
        and (p_branch_id is null or s.branch_id = p_branch_id)),

    -- Taken, by booking date. Cancelled bookings are excluded: a dealer asking
    -- "how many bookings this month" means live ones.
    (select count(*) from public.bookings b
      where b.status <> 'CANCELLED'
        and b.booking_date between p_from and p_to
        and (p_branch_id is null or b.branch_id = p_branch_id)),

    -- Handed over, by the date of delivery rather than of the invoice — a
    -- vehicle invoiced in March and delivered in April is an April delivery.
    (select count(*) from public.sales s
      where s.status = 'DELIVERED'
        and s.delivered_at::date between p_from and p_to
        and (p_branch_id is null or s.branch_id = p_branch_id)),

    -- A position, not a flow: what is on the floor now (spec §13).
    (select count(*) from public.vehicles v
      where v.status = 'IN_STOCK'
        and (p_branch_id is null or v.branch_id = p_branch_id)),

    -- Local and company lots summed for the headline; the split stays visible
    -- on the inventory screens, which is where spec §28 requires it.
    (select coalesce(sum(st.quantity), 0) from public.inventory_stock st
      join public.inventory_items i on i.id = st.item_id
     where i.item_type = 'ACCESSORY'
       and (p_branch_id is null or st.branch_id = p_branch_id)),

    (select coalesce(sum(st.quantity), 0) from public.inventory_stock st
      join public.inventory_items i on i.id = st.item_id
     where i.item_type = 'SPARE'
       and (p_branch_id is null or st.branch_id = p_branch_id)),

    -- Financed units for the period: applications raised, excluding those the
    -- financier or the dealer withdrew.
    (select count(*) from public.finance_applications f
      where f.approval_status <> 'CANCELLED'
        and f.application_date between p_from and p_to
        and (p_branch_id is null or f.branch_id = p_branch_id));
$$;

comment on function public.dashboard_unit_counts(date, date, uuid) is
  'The seven unit counts spec §10 requires on the dashboard, which the ledger '
  'cannot answer because a journal records value and not units. Flow counts obey '
  'the period; the three stock counts are positions as at now and ignore it.';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  execute 'grant execute on function public.dashboard_unit_counts(date, date, uuid) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0064', 'dashboard_unit_counts') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0065_customer_360.sql
-- ═══════════════════════════════════════════════════════════════════════════

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


commit;
