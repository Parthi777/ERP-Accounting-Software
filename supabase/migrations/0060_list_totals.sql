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
