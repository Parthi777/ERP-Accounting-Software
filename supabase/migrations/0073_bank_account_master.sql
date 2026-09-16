-- =============================================================================
-- 0073 — Creating a bank account, which nothing could do
-- =============================================================================
-- Spec §38, §22, §24, §46, §48, §60.25.
--
-- public.bank_accounts has been readable since 0022 and writable by nobody. The
-- service layer has getBankAccounts() and no create; there is no action, no
-- form, and no screen. Rows arrive only from provisioning SQL or by hand.
--
-- The permission for the screen was defined and never used: bank.accounts.manage
-- has sat in the registry since 0009 with nothing calling it. That is the shape
-- of an oversight rather than a decision.
--
-- What it costs: a dealer with no bank account cannot receipt a sale paid by
-- NEFT, UPI, cheque or card, cannot open the bank book, cannot import a
-- statement, cannot reconcile, and cannot record a finance company's
-- disbursement — which arrives by bank transfer, always. The live tenant has
-- been trading on purchases alone with zero bank accounts, so the whole
-- bank-side money surface is unreachable rather than merely empty.
--
-- WHY THIS IS A FUNCTION AND NOT AN INSERT.
--
-- bank_accounts.opening_balance is the figure the bank book counts up from
-- (0031's bank_book() reads it as the running start). Setting it with a plain
-- insert would put a balance in the bank book that exists in no journal — the
-- bank book and the trial balance would disagree from the first day, and
-- nothing in the system would say which was right.
--
-- post_opening_balances() (0066, 0067) cannot help: it refuses anything that is
-- not CUSTOMER or SUPPLIER. So there is no path today by which a cut-over
-- dealer's real bank balance can enter the books at all.
--
-- This posts it, against 3300 Opening Balance Equity, exactly as the party
-- opening balances do — one balanced journal, in the same transaction as the
-- row. An overdraft posts the other way round. A zero opening balance posts
-- nothing, because an entry with no amount is noise in the day book.
--
-- The ledger account is resolved here from the chart of accounts (1200 Bank),
-- never passed in from the browser: spec §22 forbids account ids in frontend
-- code, and the caller has no business choosing which control account a bank
-- balance lands in.
--
-- Rollback: drop function public.create_bank_account(text, text, text, text,
--           text, uuid, numeric, date, text);
--           drop function public.update_bank_account(uuid, text, text, text,
--           text, text);
--           alter table public.bank_accounts drop column created_by,
--                                            drop column updated_by;
--           Journals already posted are immutable (spec §23) and are not undone
--           by this; reverse them from Accounting → Journal Entries if needed.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Attribution, which this table never had
-- -----------------------------------------------------------------------------
-- Spec §46 wants to know who created a financial master. Every comparable table
-- carries these; bank_accounts was written before that settled.
-- -----------------------------------------------------------------------------
alter table public.bank_accounts
  add column if not exists created_by uuid,
  add column if not exists updated_by uuid;

-- -----------------------------------------------------------------------------
-- public.create_bank_account()
-- -----------------------------------------------------------------------------
create or replace function public.create_bank_account(
  p_name            text,
  p_bank_name       text,
  p_account_number  text,
  p_ifsc            text default null,
  p_account_type    text default 'CURRENT',
  p_branch_id       uuid default null,
  p_opening_balance numeric default 0,
  p_as_on           date default current_date,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_dealer  uuid;
  v_ledger  uuid;
  v_equity  uuid;
  v_bank    uuid;
  v_jbranch uuid;
  v_amount  numeric(18, 4);
  v_lines   jsonb;
begin
  if not app.has_permission('bank.accounts.manage') then
    raise exception 'You may not manage bank accounts.'
      using errcode = 'insufficient_privilege';
  end if;

  v_dealer := app.current_dealer_id();
  if v_dealer is null then
    raise exception 'Your account is not attached to a dealer.'
      using errcode = 'insufficient_privilege';
  end if;

  if coalesce(btrim(p_name), '') = '' or coalesce(btrim(p_bank_name), '') = ''
     or coalesce(btrim(p_account_number), '') = '' then
    raise exception 'A bank account needs a name, a bank and an account number.'
      using errcode = 'check_violation';
  end if;

  -- A branch from another tenant is refused here rather than by the composite
  -- foreign key, so the message names the cause.
  if p_branch_id is not null
     and not exists (select 1 from public.branches b
                      where b.id = p_branch_id and b.dealer_id = v_dealer) then
    raise exception 'That branch does not belong to your dealer.'
      using errcode = 'insufficient_privilege';
  end if;

  -- ── The control account, resolved not supplied (spec §22) ────────────────
  select id into v_ledger from public.chart_of_accounts
   where dealer_id = v_dealer and code = '1200' and status = 'ACTIVE';
  if v_ledger is null then
    raise exception 'The Bank control account (1200) is missing from the chart of accounts.'
      using errcode = 'no_data_found',
            hint = 'Seed the chart of accounts before adding a bank account.';
  end if;

  v_amount := round(coalesce(p_opening_balance, 0)::numeric, 4);

  insert into public.bank_accounts
    (dealer_id, branch_id, name, bank_name, account_number, ifsc, account_type,
     ledger_account_id, opening_balance, current_balance, status, created_by)
  values
    (v_dealer, p_branch_id, btrim(p_name), btrim(p_bank_name), btrim(p_account_number),
     nullif(btrim(upper(coalesce(p_ifsc, ''))), ''), coalesce(p_account_type, 'CURRENT'),
     v_ledger, v_amount, v_amount, 'ACTIVE', auth.uid())
  returning id into v_bank;

  -- ── The opening balance, if there is one, as a real journal ──────────────
  if v_amount <> 0 then
    select id into v_equity from public.chart_of_accounts
     where dealer_id = v_dealer and code = '3300';
    if v_equity is null then
      raise exception 'The Opening Balance Equity account (3300) is missing.'
        using errcode = 'no_data_found';
    end if;

    v_lines := jsonb_build_array(
      jsonb_build_object(
        'account_id', v_ledger,
        'debit',  case when v_amount > 0 then v_amount else 0 end,
        'credit', case when v_amount < 0 then abs(v_amount) else 0 end,
        'narration', 'Opening balance — ' || btrim(p_name)),
      jsonb_build_object(
        'account_id', v_equity,
        'debit',  case when v_amount < 0 then abs(v_amount) else 0 end,
        'credit', case when v_amount > 0 then v_amount else 0 end,
        'narration', 'Opening balance brought forward'));

    -- journal_entries.branch_id is not null, but a bank account need not belong
    -- to a branch — a dealer-wide collection account is the normal case. The
    -- entry is attributed to the first branch when the account names none, the
    -- same way post_opening_balances() does it (0067).
    v_jbranch := coalesce(p_branch_id,
                          (select b.id from public.branches b
                            where b.dealer_id = v_dealer order by b.code limit 1));
    if v_jbranch is null then
      raise exception 'This dealer has no branch to attribute the opening entry to.'
        using errcode = 'no_data_found';
    end if;

    perform app.post_journal(
      v_dealer, v_jbranch, p_as_on, 'OPENING',
      'Opening bank balance — ' || btrim(p_name) || ' as at ' || p_as_on::text,
      v_lines, 'BANK_ACCOUNT', v_bank,
      coalesce(p_idempotency_key, 'bank-opening:' || v_bank::text));
  end if;

  return v_bank;
end;
$$;

comment on function public.create_bank_account(text, text, text, text, text, uuid, numeric, date, text) is
  'Creates a bank account and, when it opens with a balance, posts that balance '
  'against 3300 Opening Balance Equity in the same transaction (spec §38, §24). '
  'The control account is resolved from the chart of accounts, never supplied '
  'by the caller (spec §22).';

-- -----------------------------------------------------------------------------
-- public.update_bank_account()
-- -----------------------------------------------------------------------------
-- Everything except the opening balance, which is a posted journal by the time
-- this could be called. Correcting it is a reversal, not an edit (spec §23).
-- -----------------------------------------------------------------------------
create or replace function public.update_bank_account(
  p_id             uuid,
  p_name           text default null,
  p_bank_name      text default null,
  p_ifsc           text default null,
  p_account_type   text default null,
  p_status         text default null
)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid;
begin
  if not app.has_permission('bank.accounts.manage') then
    raise exception 'You may not manage bank accounts.'
      using errcode = 'insufficient_privilege';
  end if;

  v_dealer := app.current_dealer_id();

  update public.bank_accounts ba
     set name           = coalesce(nullif(btrim(p_name), ''), ba.name),
         bank_name      = coalesce(nullif(btrim(p_bank_name), ''), ba.bank_name),
         ifsc           = case when p_ifsc is null then ba.ifsc
                               else nullif(btrim(upper(p_ifsc)), '') end,
         account_type   = coalesce(nullif(btrim(p_account_type), ''), ba.account_type),
         status         = coalesce(nullif(btrim(p_status), ''), ba.status),
         updated_by     = auth.uid()
   where ba.id = p_id and ba.dealer_id = v_dealer;

  if not found then
    raise exception 'Bank account not found.' using errcode = 'no_data_found';
  end if;

  return p_id;
end;
$$;

comment on function public.update_bank_account(uuid, text, text, text, text, text) is
  'Edits a bank account''s descriptive fields. The opening balance is not among '
  'them: it is a posted journal, and a posted journal is corrected by reversal '
  '(spec §23).';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.create_bank_account(text, text, text, text, text, uuid, numeric, date, text) to authenticated';
    execute 'grant execute on function public.update_bank_account(uuid, text, text, text, text, text) to authenticated';
  end if;
end $$;

revoke execute on function public.create_bank_account(text, text, text, text, text, uuid, numeric, date, text) from public;
revoke execute on function public.update_bank_account(uuid, text, text, text, text, text) from public;

insert into public.schema_migrations (version, name)
values ('0073', 'bank_account_master') on conflict (version) do nothing;
