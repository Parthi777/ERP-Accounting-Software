-- =============================================================================
-- INCREMENTAL 0067 → 0067
-- =============================================================================
-- GENERATED FILE. Regenerate with:
--   FROM=0067 bash scripts/build-incremental.sh
--
-- For a database that ALREADY has migrations up to 0066.
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
-- SOURCE: supabase/migrations/0067_opening_balances_tenant.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0067 — Opening balances must name their tenant, not guess it
-- =============================================================================
-- Spec §4, §24, §47.
--
-- 0066 resolved the dealer with
--
--     select id into v_dealer from public.dealers limit 1;   -- RLS scopes this
--
-- which is true for an ordinary session and false for the one that matters. RLS
-- narrows `dealers` to one row for a dealer user, so `limit 1` happens to be
-- right — but a platform administrator bypasses RLS entirely and sees every
-- tenant, so the same statement picks an arbitrary one. A platform admin running
-- a cut-over would post one dealer's opening balances into another dealer's
-- ledger, and nothing in the entry would look wrong afterwards.
--
-- A rehearsal found it: the dry run signs in as a platform admin to provision the
-- tenant — which is the only way to provision one — and then the balances went
-- looking for a customer in the wrong dealer.
--
-- The fix is to stop inferring. app.current_dealer_id() is the tenant of the
-- authenticated user and returns NULL for a platform admin precisely so that
-- "deny by default" holds (0004). So the session's own dealer is used when there
-- is one, and a platform admin must say which tenant they mean.
--
-- Rollback: restore public.post_opening_balances from 0066.
-- =============================================================================

drop function if exists public.post_opening_balances(text, jsonb, date, text, text);

create function public.post_opening_balances(
  p_party_type      text,
  p_rows            jsonb,
  p_as_on           date default current_date,
  p_narration       text default null,
  p_idempotency_key text default null,
  -- Only a platform admin may set this, and only a platform admin needs to:
  -- every other session has exactly one tenant and it is not theirs to choose.
  p_dealer_id       uuid default null
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

  -- ── Whose books are these? ──────────────────────────────────────────────
  v_dealer := app.current_dealer_id();

  if v_dealer is null then
    -- A platform admin, or nobody. Either way the tenant has to be stated.
    if p_dealer_id is null then
      raise exception 'Name the dealer these balances belong to.'
        using errcode = 'check_violation',
              hint = 'A platform administrator has no tenant of their own, so '
                     'p_dealer_id is required.';
    end if;
    if not app.is_platform_admin() then
      raise exception 'You may not post opening balances for another dealer.'
        using errcode = 'insufficient_privilege';
    end if;
    v_dealer := p_dealer_id;
  elsif p_dealer_id is not null and p_dealer_id <> v_dealer then
    -- A dealer session naming someone else's tenant is either a mistake or an
    -- attempt; both deserve the same answer.
    raise exception 'You may not post opening balances for another dealer.'
      using errcode = 'insufficient_privilege';
  end if;

  if not exists (select 1 from public.dealers d where d.id = v_dealer) then
    raise exception 'Dealer not found.' using errcode = 'no_data_found';
  end if;

  select id into v_branch from public.branches
   where dealer_id = v_dealer order by code limit 1;

  -- ── The JOURNAL sequence for the year being posted into ─────────────────
  --
  -- provision_dealer seeds financial-document sequences for the *current*
  -- financial year only, and that is the right default: 0056 says plainly that
  -- an identifier may self-provision but a financial document should fail rather
  -- than invent a series nobody configured.
  --
  -- An opening balance is the one financial document that is always back-dated —
  -- it is dated the day before trading starts, which for an April cut-over is the
  -- previous financial year. So the very first thing a newly provisioned tenant
  -- does would fail with "No document sequence configured", and there is no
  -- screen on which to create one.
  --
  -- Hence this narrow exception, for this document type and only for the year
  -- this entry lands in. A rehearsal found it; a real cut-over would have found
  -- it too, in front of the dealer.
  insert into public.document_sequences
    (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
  values
    (v_dealer, null, 'JOURNAL', app.financial_year_token(v_dealer, p_as_on), 'JE', 6)
  on conflict on constraint document_sequences_scope_key do nothing;

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
    -- whichever account that is; "the dealer owes the party" is a credit.
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

comment on function public.post_opening_balances(text, jsonb, date, text, text, uuid) is
  'Posts a whole party ledger as one balanced journal against 3300 Opening '
  'Balance Equity (spec §24). The tenant comes from the session, never from '
  '"whichever dealer is first" — a platform admin bypasses RLS and must name it.';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  execute 'grant execute on function public.post_opening_balances(text, jsonb, date, text, text, uuid) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0067', 'opening_balances_tenant') on conflict (version) do nothing;


commit;
