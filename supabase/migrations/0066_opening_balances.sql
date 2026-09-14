-- =============================================================================
-- 0066 — Opening balances: what the dealer was owed before they had this
-- =============================================================================
-- Spec §24, §41, §44, §59.
--
-- A dealer switching systems does not start at zero. They arrive owed money by
-- customers and owing it to suppliers, and until those balances are on the books
-- the customer ledger, the supplier ledger, the trial balance and every ageing
-- report describe a business that began the day they signed up.
--
-- `customer_ledger_opening` (0037) *computes* an opening from journals. There
-- has never been a way to *enter* one, so the only path was typing a journal
-- line per party by hand — which for a few hundred parties is a week's work and
-- a guaranteed transposition error.
--
-- ── One journal, not one per party ──────────────────────────────────────────
--
-- Every party is a line in a single entry balanced against 3300 Opening Balance
-- Equity. That is the standard treatment and it has a practical virtue: the
-- whole cut-over is one reversible document. If the figures turn out wrong — and
-- on a first attempt they usually do — the fix is one reversal, not several
-- hundred, and the trial balance is never half-migrated in between.
--
-- ── Why a suspense account and not Retained Earnings ────────────────────────
--
-- 3300 exists so the migration is visible as its own number. Posting straight to
-- retained earnings would mix "what we were owed on day one" into the same line
-- as trading profit, and nobody could later tell which was which. The dealer's
-- accountant clears 3300 into 3200 once they are satisfied the balances match
-- the old system — and a non-zero 3300 is itself a useful signal that the
-- reconciliation has not been finished.
--
-- Rollback: drop function public.post_opening_balances(...); the 3300 account
-- can stay, being harmless when unused.
-- =============================================================================

-- ── The account, for dealers who already exist ──────────────────────────────
-- New dealers get it from app.seed_chart_of_accounts below; this is the backfill
-- for the ones provisioned before today.
insert into public.chart_of_accounts
  (dealer_id, code, name, account_type, normal_balance, is_group, parent_id,
   is_system, is_branch_scoped)
select d.id, '3300', 'Opening Balance Equity', 'EQUITY', 'CREDIT', false,
       (select c.id from public.chart_of_accounts c
         where c.dealer_id = d.id and c.code = '3000'),
       true, false
  from public.dealers d
on conflict on constraint coa_dealer_code_key do nothing;

-- ── And for every dealer provisioned from now on ────────────────────────────
-- The original is renamed rather than copied. Reproducing its sixty-account
-- table here would leave two lists to keep in step — the exact failure this
-- migration exists to prevent elsewhere. app.provision_dealer still calls
-- app.seed_chart_of_accounts by name, so it picks up the wrapper unchanged.
alter function app.seed_chart_of_accounts(uuid) rename to seed_chart_of_accounts_base;

create or replace function app.seed_chart_of_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
declare
  v_added integer := 0;
begin
  v_added := app.seed_chart_of_accounts_base(p_dealer_id);

  insert into public.chart_of_accounts
    (dealer_id, code, name, account_type, normal_balance, is_group, parent_id,
     is_system, is_branch_scoped)
  values
    (p_dealer_id, '3300', 'Opening Balance Equity', 'EQUITY', 'CREDIT', false,
     (select c.id from public.chart_of_accounts c
       where c.dealer_id = p_dealer_id and c.code = '3000'),
     true, false)
  on conflict on constraint coa_dealer_code_key do nothing;

  if found then v_added := v_added + 1; end if;
  return v_added;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.post_opening_balances() — one balanced entry for a whole party ledger
-- -----------------------------------------------------------------------------
-- p_rows is [{ "party_code": "CUST-000001", "amount": 12500.00 }, …].
--
-- A positive amount means the party owes the dealer; negative means the dealer
-- owes the party. One sign convention for both directions, because a file with
-- a separate debit and credit column invites rows carrying both.
-- -----------------------------------------------------------------------------
create or replace function public.post_opening_balances(
  p_party_type      text,
  p_rows            jsonb,
  p_as_on           date default current_date,
  p_narration       text default null,
  p_idempotency_key text default null
)
returns table (journal_entry_id uuid, parties integer, total numeric)
language plpgsql
as $$
declare
  v_dealer   uuid;
  v_branch   uuid;
  v_control  uuid;
  v_equity   uuid;
  v_row      jsonb;
  v_party    uuid;
  v_code     text;
  v_amount   numeric(18, 4);
  v_lines    jsonb := '[]'::jsonb;
  v_net      numeric(18, 4) := 0;
  v_count    integer := 0;
  v_entry    uuid;
begin
  if p_party_type not in ('CUSTOMER', 'SUPPLIER') then
    raise exception 'Opening balances are for CUSTOMER or SUPPLIER, not %.', p_party_type
      using errcode = 'check_violation';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'No opening balances to post.' using errcode = 'check_violation';
  end if;

  select id into v_dealer from public.dealers limit 1;      -- RLS scopes this to one
  if v_dealer is null then
    raise exception 'No dealer in scope.' using errcode = 'no_data_found';
  end if;

  select id into v_branch from public.branches
   where dealer_id = v_dealer order by code limit 1;

  -- The guard (spec §50). A cut-over run twice would double every balance, and
  -- of all the things to post twice this is the worst: nobody notices until a
  -- customer disputes a statement.
  if p_idempotency_key is not null then
    select je.id into v_entry from public.journal_entries je
     where je.dealer_id = v_dealer and je.idempotency_key = 'opening:' || p_idempotency_key;
    if v_entry is not null then
      select count(*), coalesce(sum(abs(l.debit - l.credit)), 0)
        into v_count, v_net
        from public.journal_entry_lines l
       where l.journal_entry_id = v_entry and l.party_id is not null;
      journal_entry_id := v_entry; parties := v_count; total := v_net;
      return next;
      return;
    end if;
  end if;

  -- The two control accounts a party ledger reconciles against. The triples are
  -- the ones the posting engine already uses, so an opening balance lands in the
  -- same account a later invoice will (0027:34, 0027:96).
  v_control := case
    when p_party_type = 'CUSTOMER'
      then app.require_account(v_dealer, 'SALES', 'INVOICE', 'RECEIVABLE', v_branch)
    else app.require_account(v_dealer, 'INVENTORY', 'PURCHASE', 'PAYABLE', v_branch)
  end;

  select id into v_equity from public.chart_of_accounts
   where dealer_id = v_dealer and code = '3300';
  if v_equity is null then
    raise exception 'The Opening Balance Equity account (3300) is missing.'
      using errcode = 'no_data_found';
  end if;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_code   := btrim(v_row ->> 'party_code');
    v_amount := round((v_row ->> 'amount')::numeric, 4);

    if v_amount = 0 then
      continue;  -- nothing owed either way is not a line, it is an absence
    end if;

    if p_party_type = 'CUSTOMER' then
      select id into v_party from public.customers
       where dealer_id = v_dealer and customer_code = v_code;
    else
      select id into v_party from public.suppliers
       where dealer_id = v_dealer and supplier_code = v_code;
    end if;

    if v_party is null then
      raise exception 'No % with code %.', lower(p_party_type), v_code
        using errcode = 'no_data_found';
    end if;

    -- The sign decides the direction, and it does so the same way for both party
    -- types. "The party owes the dealer" is a debit to the control account
    -- whichever account that is; "the dealer owes the party" is a credit. The
    -- control account differs — 1300 for a customer, 2200 for a supplier — but
    -- the direction does not, and making it depend on the party type as well was
    -- a bug that inverted every supplier balance.
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', v_control,
      'debit',  case when v_amount > 0 then v_amount else 0 end,
      'credit', case when v_amount < 0 then abs(v_amount) else 0 end,
      'narration', 'Opening balance ' || v_code,
      'party_type', p_party_type,
      'party_id', v_party
    ));

    v_net := v_net + v_amount;   -- net debit across the party lines
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception 'Every row was zero — there is nothing to post.'
      using errcode = 'check_violation';
  end if;

  -- The balancing line. v_net is the net debit across the party lines, so the
  -- equity side is its mirror and the entry sums to zero by construction rather
  -- than by hoping the file added up.
  v_lines := v_lines || jsonb_build_array(jsonb_build_object(
    'account_id', v_equity,
    'debit',  case when v_net < 0 then abs(v_net) else 0 end,
    'credit', case when v_net > 0 then v_net else 0 end,
    'narration', 'Opening balances brought forward'
  ));

  v_entry := app.post_journal(
    v_dealer, v_branch, p_as_on, 'OPENING',
    coalesce(p_narration,
             'Opening ' || lower(p_party_type) || ' balances as at ' || p_as_on::text),
    v_lines,
    'OPENING_BALANCE', null,
    case when p_idempotency_key is null then null else 'opening:' || p_idempotency_key end
  );

  journal_entry_id := v_entry; parties := v_count; total := abs(v_net);
  return next;
end;
$$;

comment on function public.post_opening_balances(text, jsonb, date, text, text) is
  'Posts a whole party ledger as one balanced journal against 3300 Opening '
  'Balance Equity (spec §24). One document, so a wrong cut-over is one reversal '
  'rather than several hundred.';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  execute 'grant execute on function public.post_opening_balances(text, jsonb, date, text, text) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0066', 'opening_balances') on conflict (version) do nothing;
