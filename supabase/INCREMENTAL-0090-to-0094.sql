-- =============================================================================
-- INCREMENTAL 0090 → 0094
-- =============================================================================
-- GENERATED FILE. Regenerate with:
--   FROM=0090 bash scripts/build-incremental.sh
--
-- For a database that ALREADY has migrations up to 0089.
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
-- SOURCE: supabase/migrations/0090_ledger_master_groups_fy.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0090 — Ledger master, ledger groups, ledger modification, financial years
-- =============================================================================
-- Spec §9 (Masters → Accounting), §24, §44. Raised by the dealer with two BUSY
-- videos ("how to add party ledger", "how to modify ledger in BUSY"):
--
--   "each ledger needs an option to modify, and ledger groups are required;
--    financial year creation is also required; single ledger modification is
--    not available."
--
-- ── Groups ─────────────────────────────────────────────────────────────────
--
-- The chart had five flat headings. The accountant works with BUSY's groups —
-- Sundry Debtors, Duties & Taxes, Indirect Expenses — so those are created as
-- groups beneath the headings, and the standard ledgers are moved into them.
-- A ledger is moved only while it still sits directly under its heading, so
-- nothing the accountant has already regrouped is disturbed. Reports read the
-- account type, not the parent, so no figure moves.
--
-- ── Modifying a ledger or a group ──────────────────────────────────────────
--
-- update_account(): name, alias, code and group. A system ledger keeps its
-- code (posting finds some by code); a group cannot move beneath itself; type
-- rules stay with the 0076 guard. Every change is audited.
--
-- ── Opening balances, per ledger ───────────────────────────────────────────
--
-- set_ledger_opening_balance() sets a ledger's opening balance (Dr or Cr) —
-- an account's, or a customer's, supplier's or finance company's. It posts only
-- the difference from what is already there, against 3300 Opening Balance
-- Equity, dated the day before the first financial year: changing an opening
-- balance never edits a posted journal. Cash, bank and stock carry their
-- openings in their own masters and are refused here, as are the control
-- accounts, whose opening is the sum of their parties'.
--
-- ── The ledger master ──────────────────────────────────────────────────────
--
-- ledger_master() lists every ledger the way BUSY's account list does: the
-- accounts, and each customer, supplier and finance company as a ledger under
-- its group, with its opening and closing balance. A party's balance is its
-- statement's (advances included); a control ledger appears itself only for
-- what is on it tagged to no party.
--
-- ── Financial years ────────────────────────────────────────────────────────
--
-- create_financial_year() adds the next year after the last; balances need no
-- carry-forward entry because the balance sheet already includes the result to
-- date (0026), and document numbering starts afresh on its own (0072).
-- close_financial_year() closes a year so nothing more posts into it;
-- reopen_financial_year() needs a reason. Years are now audited.
--
-- Rollback: drop the functions and columns added here; move the ledgers back
--           under their headings; rename seed_chart_of_accounts_0089 back.
-- =============================================================================

alter table public.chart_of_accounts add column if not exists alias text;

-- -----------------------------------------------------------------------------
-- 1. Standard ledger groups
-- -----------------------------------------------------------------------------
create or replace function app.seed_ledger_groups(p_dealer_id uuid)
returns integer
language plpgsql
as $$
declare
  v_added integer := 0;
  g       record;
  m       record;
begin
  for g in
    select * from (values
      ('1001', 'Cash-in-Hand',             'ASSET',     'DEBIT',  '1000'),
      ('1002', 'Bank Accounts',            'ASSET',     'DEBIT',  '1000'),
      ('1003', 'Sundry Debtors',           'ASSET',     'DEBIT',  '1000'),
      ('1004', 'Stock-in-Hand',            'ASSET',     'DEBIT',  '1000'),
      ('1005', 'Current Assets',           'ASSET',     'DEBIT',  '1000'),
      ('2001', 'Current Liabilities',      'LIABILITY', 'CREDIT', '2000'),
      ('2002', 'Sundry Creditors',         'LIABILITY', 'CREDIT', '2000'),
      ('2003', 'Duties & Taxes',           'LIABILITY', 'CREDIT', '2000'),
      ('2004', 'Loans (Liability)',        'LIABILITY', 'CREDIT', '2000'),
      ('3001', 'Capital Account',          'EQUITY',    'CREDIT', '3000'),
      ('3002', 'Reserves & Surplus',       'EQUITY',    'CREDIT', '3000'),
      ('4001', 'Sales Accounts',           'INCOME',    'CREDIT', '4000'),
      ('4002', 'Direct Incomes',           'INCOME',    'CREDIT', '4000'),
      ('4003', 'Indirect Incomes',         'INCOME',    'CREDIT', '4000'),
      ('5001', 'Cost of Sales (Purchase)', 'EXPENSE',   'DEBIT',  '5000'),
      ('5002', 'Direct Expenses',          'EXPENSE',   'DEBIT',  '5000'),
      ('5003', 'Indirect Expenses',        'EXPENSE',   'DEBIT',  '5000')
    ) as t(code, name, account_type, normal_balance, parent_code)
  loop
    insert into public.chart_of_accounts
      (dealer_id, code, name, account_type, normal_balance, is_group, parent_id, is_system, is_branch_scoped)
    select p_dealer_id, g.code, g.name, g.account_type, g.normal_balance, true, p.id, true, false
      from public.chart_of_accounts p
     where p.dealer_id = p_dealer_id and p.code = g.parent_code and p.is_group
    on conflict on constraint coa_dealer_code_key do nothing;
    if found then v_added := v_added + 1; end if;
  end loop;

  -- The standard ledgers into their groups — only those still directly under
  -- their type heading, so an accountant's own regrouping is left alone.
  for m in
    select * from (values
      ('1100', '1001'), ('1200', '1002'), ('1300', '1003'), ('1400', '1003'),
      ('1500', '1004'), ('1600', '1004'), ('1700', '1004'), ('1850', '1004'),
      ('1800', '1005'), ('1900', '1005'), ('1910', '1005'), ('1920', '1005'),
      ('2100', '2001'), ('2600', '2001'), ('2700', '2001'), ('2710', '2001'), ('2720', '2001'),
      ('2730', '2001'), ('2740', '2001'), ('2750', '2001'),
      ('2200', '2002'),
      ('2300', '2003'), ('2400', '2003'), ('2500', '2003'), ('2590', '2003'),
      ('2800', '2004'),
      ('3100', '3001'), ('3400', '3001'), ('3200', '3002'), ('3300', '3002'),
      ('4100', '4001'), ('4200', '4001'), ('4300', '4001'), ('4420', '4001'),
      ('4400', '4002'), ('4410', '4002'), ('4700', '4002'),
      ('4500', '4003'), ('4600', '4003'), ('4800', '4003'), ('4810', '4003'),
      ('5100', '5001'), ('5200', '5001'), ('5300', '5001'), ('5400', '5001'), ('5970', '5001'),
      ('5930', '5002'),
      ('5500', '5003'), ('5510', '5003'), ('5600', '5003'), ('5700', '5003'), ('5800', '5003'),
      ('5900', '5003'), ('5920', '5003'), ('5950', '5003'), ('5960', '5003'), ('5980', '5003'),
      ('5990', '5003')
    ) as t(ledger_code, group_code)
  loop
    update public.chart_of_accounts a
       set parent_id = grp.id
      from public.chart_of_accounts grp, public.chart_of_accounts heading
     where a.dealer_id = p_dealer_id and a.code = m.ledger_code
       and grp.dealer_id = p_dealer_id and grp.code = m.group_code and grp.is_group
       and heading.id = a.parent_id and heading.parent_id is null
       and grp.account_type = a.account_type;
  end loop;

  return v_added;
end;
$$;

do $$
declare d record;
begin
  for d in select id from public.dealers loop
    perform app.seed_ledger_groups(d.id);
  end loop;
end $$;

alter function app.seed_chart_of_accounts(uuid) rename to seed_chart_of_accounts_0089;

create or replace function app.seed_chart_of_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
begin
  return app.seed_chart_of_accounts_0089(p_dealer_id) + app.seed_ledger_groups(p_dealer_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. Modifying a ledger or a group
-- -----------------------------------------------------------------------------
create or replace function public.update_account(
  p_account_id uuid,
  p_name       text,
  p_code       text,
  p_parent_id  uuid,
  p_alias      text default null
)
returns void
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_acc    public.chart_of_accounts;
  v_code   text := upper(btrim(coalesce(p_code, '')));
  v_cycle  boolean;
begin
  if v_dealer is null or not app.has_permission('accounting.coa.manage') then
    raise exception 'You may not change the chart of accounts.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_acc from public.chart_of_accounts where id = p_account_id and dealer_id = v_dealer;
  if v_acc.id is null then
    raise exception 'Ledger not found.' using errcode = 'no_data_found';
  end if;
  if coalesce(length(btrim(p_name)), 0) < 2 then
    raise exception 'Give the ledger a name.' using errcode = 'check_violation';
  end if;
  if v_code !~ '^[0-9A-Z][0-9A-Z._-]{0,29}$' then
    raise exception 'A code is letters and digits, up to 30 characters.' using errcode = 'check_violation';
  end if;
  -- Posting finds some ledgers by their code (3300, 1400, 5920 …).
  if v_acc.is_system and v_code <> v_acc.code then
    raise exception '% is a system ledger; its code stays %. Its name and group can change.', v_acc.name, v_acc.code
      using errcode = 'check_violation';
  end if;
  if v_code <> v_acc.code and exists (
       select 1 from public.chart_of_accounts where dealer_id = v_dealer and code = v_code and id <> p_account_id) then
    raise exception 'Code % is already in use.', v_code using errcode = 'unique_violation';
  end if;
  -- The five type headings are the top of the tree and stay there.
  if v_acc.parent_id is null and p_parent_id is not null then
    raise exception '% is a top heading and cannot be moved under a group.', v_acc.name using errcode = 'check_violation';
  end if;
  if v_acc.parent_id is not null and p_parent_id is null then
    raise exception 'Choose the group % belongs under.', v_acc.name using errcode = 'check_violation';
  end if;
  if p_parent_id is not null then
    with recursive up as (
      select id, parent_id from public.chart_of_accounts where id = p_parent_id
      union all
      select c.id, c.parent_id from public.chart_of_accounts c join up on c.id = up.parent_id
    )
    select exists (select 1 from up where id = p_account_id) into v_cycle;
    if v_cycle then
      raise exception 'A group cannot be moved beneath itself.' using errcode = 'check_violation';
    end if;
  end if;

  update public.chart_of_accounts
     set name = btrim(p_name), code = v_code, parent_id = p_parent_id,
         alias = nullif(btrim(coalesce(p_alias, '')), ''), updated_by = auth.uid()
   where id = p_account_id;
end;
$$;

comment on function public.update_account(uuid, text, text, uuid, text) is
  'Modifies a ledger or group: name, alias, code (not a system ledger''s) and '
  'group. Type rules are the 0076 guard''s; a group cannot move beneath itself.';

-- -----------------------------------------------------------------------------
-- 3. A ledger's opening balance
-- -----------------------------------------------------------------------------
create or replace function app.opening_date(p_dealer_id uuid)
returns date
language sql
stable
as $$
  select coalesce((select min(start_date) - 1 from public.accounting_periods where dealer_id = p_dealer_id),
                  current_date);
$$;

-- The opening balance already entered for a ledger (debit positive).
create or replace function public.ledger_opening_entered(p_kind text, p_id uuid)
returns numeric
language sql
stable
as $$
  select coalesce(sum(l.debit - l.credit), 0)
    from public.journal_entry_lines l
    join public.journal_entries je on je.id = l.journal_entry_id
   where je.dealer_id = app.current_dealer_id()
     and je.source_document_type = 'OPENING_BALANCE' and je.status in ('POSTED', 'REVERSED')
     and case when p_kind = 'ACCOUNT' then l.account_id = p_id and l.party_id is null
              else l.party_type = p_kind and l.party_id = p_id end;
$$;

create or replace function public.set_ledger_opening_balance(
  p_kind   text,
  p_id     uuid,
  p_amount numeric,
  p_side   text
)
returns uuid
language plpgsql
as $$
declare
  v_dealer  uuid := app.current_dealer_id();
  v_target  numeric;
  v_current numeric;
  v_delta   numeric;
  v_acc     public.chart_of_accounts;
  v_ledger  uuid;
  v_equity  uuid;
  v_branch  uuid;
  v_label   text;
  v_party   text;
  v_entry   uuid;
begin
  if v_dealer is null or not app.has_permission('accounting.journals.post') then
    raise exception 'Only the accountant can set opening balances.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(p_amount, 0) < 0 then
    raise exception 'Enter the opening balance as an amount, and choose Dr or Cr.' using errcode = 'check_violation';
  end if;
  if upper(coalesce(p_side, '')) not in ('DR', 'CR') then
    raise exception 'An opening balance is Dr or Cr.' using errcode = 'check_violation';
  end if;
  v_target := round(coalesce(p_amount, 0), 2) * case when upper(p_side) = 'DR' then 1 else -1 end;

  if p_kind = 'ACCOUNT' then
    select * into v_acc from public.chart_of_accounts where id = p_id and dealer_id = v_dealer;
    if v_acc.id is null or v_acc.is_group then
      raise exception 'Choose a ledger, not a group.' using errcode = 'check_violation';
    end if;
    if v_acc.code = '3300' then
      raise exception 'Opening Balance Equity is the other side of every opening balance; it takes none of its own.'
        using errcode = 'check_violation';
    end if;
    if app.is_money_ledger(v_dealer, v_acc.id) then
      raise exception '% is a cash or bank ledger: set its opening balance on the Cash or Bank account.', v_acc.name
        using errcode = 'check_violation';
    end if;
    if exists (select 1 from public.accounting_rules r
                where r.dealer_id = v_dealer and r.account_id = v_acc.id and r.status = 'ACTIVE'
                  and r.component in ('INVENTORY', 'VEHICLE_INVENTORY', 'ACCESSORY_INVENTORY', 'SPARE_INVENTORY')) then
      raise exception '% is a stock ledger: its opening comes from the opening stock upload.', v_acc.name
        using errcode = 'check_violation';
    end if;
    if exists (select 1 from public.accounting_rules r
                where r.dealer_id = v_dealer and r.account_id = v_acc.id and r.status = 'ACTIVE'
                  and r.component in ('RECEIVABLE', 'PAYABLE', 'FINANCE_RECEIVABLE')) then
      raise exception '% is a control ledger: its opening is the sum of its customers'', suppliers'' or financiers''. Set it on each party.', v_acc.name
        using errcode = 'check_violation';
    end if;
    v_ledger := v_acc.id;
    v_label := v_acc.code || ' ' || v_acc.name;
  elsif p_kind in ('CUSTOMER', 'SUPPLIER', 'FINANCE_COMPANY') then
    v_label := case p_kind
      when 'CUSTOMER' then (select name from public.customers where id = p_id and dealer_id = v_dealer)
      when 'SUPPLIER' then (select name from public.suppliers where id = p_id and dealer_id = v_dealer)
      else (select name from public.finance_companies where id = p_id and dealer_id = v_dealer) end;
    if v_label is null then
      raise exception 'Party not found.' using errcode = 'no_data_found';
    end if;
    v_ledger := case p_kind
      when 'CUSTOMER' then app.require_account(v_dealer, 'SALES', 'INVOICE', 'RECEIVABLE', null)
      when 'SUPPLIER' then app.require_account(v_dealer, 'INVENTORY', 'PURCHASE', 'PAYABLE', null)
      else app.require_account(v_dealer, 'FINANCE', 'DISBURSEMENT', 'FINANCE_RECEIVABLE', null) end;
    v_party := p_kind;
  else
    raise exception 'Unknown kind of ledger %.', p_kind using errcode = 'check_violation';
  end if;

  v_current := public.ledger_opening_entered(p_kind, p_id);
  v_delta := v_target - v_current;
  if v_delta = 0 then
    return null;   -- already what was asked for
  end if;

  select id into v_equity from public.chart_of_accounts where dealer_id = v_dealer and code = '3300';
  if v_equity is null then
    raise exception 'The Opening Balance Equity account (3300) is missing.' using errcode = 'no_data_found';
  end if;
  select id into v_branch from public.branches where dealer_id = v_dealer order by is_head_office desc, code limit 1;

  v_entry := app.post_journal(
    v_dealer, v_branch, app.opening_date(v_dealer), 'OPENING',
    'Opening balance of ' || v_label
      || case when v_current <> 0 then ' changed from ' || abs(v_current) || case when v_current > 0 then ' Dr' else ' Cr' end
              else '' end
      || ' to ' || abs(v_target) || case when v_target >= 0 then ' Dr' else ' Cr' end,
    jsonb_build_array(
      jsonb_build_object('account_id', v_ledger,
        'debit', greatest(v_delta, 0), 'credit', greatest(-v_delta, 0),
        'narration', 'Opening balance', 'party_type', v_party, 'party_id', case when v_party is null then null else p_id end),
      jsonb_build_object('account_id', v_equity,
        'debit', greatest(-v_delta, 0), 'credit', greatest(v_delta, 0),
        'narration', 'Opening balance of ' || v_label)),
    'OPENING_BALANCE', p_id, null);
  return v_entry;
end;
$$;

comment on function public.set_ledger_opening_balance(text, uuid, numeric, text) is
  'Sets a ledger''s opening balance (Dr/Cr) by posting only the difference from '
  'what is already entered, against 3300, dated the day before the first '
  'financial year. Cash, bank, stock and control ledgers are refused.';

-- -----------------------------------------------------------------------------
-- 4. The ledger master: every ledger, parties included
-- -----------------------------------------------------------------------------
create or replace function public.ledger_master(
  p_search   text default null,
  p_group_id uuid default null,
  p_from     date default null,
  p_limit    integer default 200,
  p_offset   integer default 0,
  p_kind     text default null,
  p_id       uuid default null
)
returns table (
  kind       text,
  id         uuid,
  code       text,
  name       text,
  alias      text,
  group_id   uuid,
  group_name text,
  account_type text,
  opening    numeric(18, 4),
  closing    numeric(18, 4),
  status     text,
  contact    text,
  is_system  boolean
)
language sql
stable
as $$
  with recursive d as (select app.current_dealer_id() as dealer_id,
                    coalesce(p_from, (select min(start_date) from public.accounting_periods
                                       where dealer_id = app.current_dealer_id())) as since),
  ctrl as (
    select r.component, r.account_id, a.parent_id as group_id, g.name as group_name
      from public.accounting_rules r
      join d on r.dealer_id = d.dealer_id
      join public.chart_of_accounts a on a.id = r.account_id
      left join public.chart_of_accounts g on g.id = a.parent_id
     where r.status = 'ACTIVE' and r.branch_id is null
       and ((r.module = 'SALES' and r.event = 'INVOICE' and r.component = 'RECEIVABLE')
         or (r.module = 'INVENTORY' and r.event = 'PURCHASE' and r.component = 'PAYABLE')
         or (r.module = 'FINANCE' and r.event = 'DISBURSEMENT' and r.component = 'FINANCE_RECEIVABLE'))
  ),
  -- The chosen group and every group beneath it.
  tree as (
    select id from public.chart_of_accounts where id = p_group_id
    union all
    select c.id from public.chart_of_accounts c join tree t on c.parent_id = t.id where c.is_group
  ),
  bal as (
    select l.account_id, l.party_type, l.party_id,
           sum(l.debit - l.credit) filter (where je.entry_date < d.since) as opening,
           sum(l.debit - l.credit) as closing
      from public.journal_entry_lines l
      join public.journal_entries je on je.id = l.journal_entry_id
      join d on je.dealer_id = d.dealer_id
     where je.status in ('POSTED', 'REVERSED')
     group by l.account_id, l.party_type, l.party_id
  ),
  acct_bal as (
    select account_id, sum(opening) as opening, sum(closing) as closing from bal group by account_id
  ),
  party_bal as (
    select party_type, party_id, sum(opening) as opening, sum(closing) as closing
      from bal where party_id is not null group by party_type, party_id
  ),
  rows as (
    -- Ledgers; the control accounts are shown as their parties instead.
    select 'ACCOUNT'::text as kind, a.id, a.code, a.name, a.alias, a.parent_id as group_id, g.name as group_name,
           a.account_type, coalesce(b.opening, 0) as opening, coalesce(b.closing, 0) as closing,
           a.status, null::text as contact, a.is_system
      from public.chart_of_accounts a
      join d on a.dealer_id = d.dealer_id
      left join public.chart_of_accounts g on g.id = a.parent_id
      left join acct_bal b on b.account_id = a.id
     where not a.is_group and a.id not in (select account_id from ctrl)
    union all
    -- A control ledger is shown by its parties — but anything on it tagged to
    -- no party (a walk-in bill left unpaid) would then be nowhere. It is listed
    -- here, on its own, until it is assigned.
    select 'ACCOUNT', a.id, a.code, a.name || ' — not assigned to a party', a.alias, a.parent_id, g.name,
           a.account_type, coalesce(u.opening, 0), u.closing, a.status, null, a.is_system
      from ctrl k
      join public.chart_of_accounts a on a.id = k.account_id
      left join public.chart_of_accounts g on g.id = a.parent_id
      join (select account_id, sum(opening) as opening, sum(closing) as closing
              from bal where party_id is null group by account_id) u on u.account_id = a.id
     where u.closing <> 0 or coalesce(u.opening, 0) <> 0
    union all
    select 'CUSTOMER', c.id, c.customer_code, c.name, null, k.group_id, k.group_name, 'ASSET',
           coalesce(p.opening, 0), coalesce(p.closing, 0), c.status, c.mobile, false
      from public.customers c
      join d on c.dealer_id = d.dealer_id
      left join ctrl k on k.component = 'RECEIVABLE'
      left join party_bal p on p.party_type = 'CUSTOMER' and p.party_id = c.id
    union all
    select 'SUPPLIER', s.id, s.supplier_code, s.name, null, k.group_id, k.group_name, 'LIABILITY',
           coalesce(p.opening, 0), coalesce(p.closing, 0), s.status, s.mobile, false
      from public.suppliers s
      join d on s.dealer_id = d.dealer_id
      left join ctrl k on k.component = 'PAYABLE'
      left join party_bal p on p.party_type = 'SUPPLIER' and p.party_id = s.id
    union all
    select 'FINANCE_COMPANY', f.id, f.code, f.name, null, k.group_id, k.group_name, 'ASSET',
           coalesce(p.opening, 0), coalesce(p.closing, 0), f.status, f.mobile, false
      from public.finance_companies f
      join d on f.dealer_id = d.dealer_id
      left join ctrl k on k.component = 'FINANCE_RECEIVABLE'
      left join party_bal p on p.party_type = 'FINANCE_COMPANY' and p.party_id = f.id
  )
  select r.kind, r.id, r.code, r.name, r.alias, r.group_id, r.group_name,
         r.account_type, r.opening::numeric(18, 4), r.closing::numeric(18, 4), r.status, r.contact, r.is_system
    from rows r
   where (app.has_permission('accounting.ledgers.view') or app.has_permission('accounting.coa.view'))
     and (p_search is null or btrim(p_search) = ''
          or r.name ilike '%' || btrim(p_search) || '%' or r.code ilike '%' || btrim(p_search) || '%'
          or r.alias ilike '%' || btrim(p_search) || '%' or r.contact ilike '%' || btrim(p_search) || '%')
     and (p_group_id is null or r.group_id in (select id from tree))
     and (p_id is null or (r.id = p_id and r.kind = coalesce(p_kind, r.kind)))
   order by r.name, r.kind
   limit greatest(least(coalesce(p_limit, 200), 1000), 1) offset greatest(coalesce(p_offset, 0), 0);
$$;

comment on function public.ledger_master(text, uuid, date, integer, integer, text, uuid) is
  'Every ledger — accounts, and each customer, supplier and finance company as a '
  'ledger under its group — with opening (before p_from, default the first FY) '
  'and closing balance, debit positive. The BUSY account list; p_kind/p_id '
  'pick out one ledger.';

-- -----------------------------------------------------------------------------
-- 5. Financial years
-- -----------------------------------------------------------------------------
alter table public.accounting_periods add column if not exists status_reason text;

create trigger accounting_periods_audit after insert or update or delete on public.accounting_periods
  for each row execute function app.audit_trigger();

create or replace function public.create_financial_year()
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_last   date;
  v_start  date;
  v_end    date;
  v_month  integer;
  v_id     uuid;
begin
  if v_dealer is null or not app.has_permission('accounting.periods.manage') then
    raise exception 'You may not create financial years.' using errcode = 'insufficient_privilege';
  end if;

  select max(end_date) into v_last from public.accounting_periods where dealer_id = v_dealer;
  if v_last is not null then
    v_start := v_last + 1;
  else
    select coalesce(fy_start_month, 4) into v_month from public.dealers where id = v_dealer;
    v_start := make_date(extract(year from current_date)::int, v_month, 1);
    if v_start > current_date then
      v_start := (v_start - interval '1 year')::date;
    end if;
  end if;
  v_end := (v_start + interval '1 year' - interval '1 day')::date;

  if exists (select 1 from public.accounting_periods
              where dealer_id = v_dealer and daterange(start_date, end_date, '[]') && daterange(v_start, v_end, '[]')) then
    raise exception 'A financial year already covers part of % to %.', v_start, v_end using errcode = 'check_violation';
  end if;

  insert into public.accounting_periods (dealer_id, name, start_date, end_date, status)
  values (v_dealer,
          'FY ' || extract(year from v_start)::int || '-' || lpad((extract(year from v_end)::int % 100)::text, 2, '0'),
          v_start, v_end, 'OPEN')
  returning id into v_id;
  return v_id;
end;
$$;

comment on function public.create_financial_year() is
  'Adds the next financial year after the last (or the one containing today). '
  'Balances carry forward on their own; numbering restarts on its own (0072).';

create or replace function public.close_financial_year(p_period_id uuid)
returns void
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_p      public.accounting_periods;
begin
  if v_dealer is null or not app.has_permission('accounting.periods.manage') then
    raise exception 'You may not close financial years.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_p from public.accounting_periods where id = p_period_id and dealer_id = v_dealer for update;
  if v_p.id is null then
    raise exception 'Financial year not found.' using errcode = 'no_data_found';
  end if;
  if v_p.status <> 'OPEN' then
    raise exception '% is already %.', v_p.name, lower(v_p.status) using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.accounting_periods
              where dealer_id = v_dealer and end_date < v_p.start_date and status = 'OPEN') then
    raise exception 'Close the earlier financial year first.' using errcode = 'check_violation';
  end if;
  if v_p.end_date >= current_date then
    raise exception '% has not ended yet; it can be closed after %.', v_p.name, to_char(v_p.end_date, 'DD-MM-YYYY')
      using errcode = 'check_violation';
  end if;
  update public.accounting_periods
     set status = 'CLOSED', closed_at = now(), closed_by = auth.uid(), status_reason = null
   where id = p_period_id;
end;
$$;

create or replace function public.reopen_financial_year(p_period_id uuid, p_reason text)
returns void
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_p      public.accounting_periods;
begin
  if v_dealer is null or not app.has_permission('accounting.periods.manage') then
    raise exception 'You may not reopen financial years.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(length(btrim(p_reason)), 0) < 5 then
    raise exception 'Say why the year is being reopened.' using errcode = 'check_violation';
  end if;
  select * into v_p from public.accounting_periods where id = p_period_id and dealer_id = v_dealer for update;
  if v_p.id is null then
    raise exception 'Financial year not found.' using errcode = 'no_data_found';
  end if;
  if v_p.status = 'OPEN' then
    return;
  end if;
  if exists (select 1 from public.accounting_periods
              where dealer_id = v_dealer and start_date > v_p.end_date and status <> 'OPEN') then
    raise exception 'Reopen the later financial year first.' using errcode = 'check_violation';
  end if;
  update public.accounting_periods
     set status = 'OPEN', closed_at = null, closed_by = null, status_reason = btrim(p_reason)
   where id = p_period_id;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.update_account(uuid, text, text, uuid, text) to authenticated';
    execute 'grant execute on function public.set_ledger_opening_balance(text, uuid, numeric, text) to authenticated';
    execute 'grant execute on function public.ledger_opening_entered(text, uuid) to authenticated';
    execute 'grant execute on function public.ledger_master(text, uuid, date, integer, integer, text, uuid) to authenticated';
    execute 'grant execute on function public.create_financial_year() to authenticated';
    execute 'grant execute on function public.close_financial_year(uuid) to authenticated';
    execute 'grant execute on function public.reopen_financial_year(uuid, text) to authenticated';
    execute 'grant execute on function app.opening_date(uuid) to authenticated';
  end if;
end $$;

insert into public.schema_migrations (version, name)
values ('0090', 'ledger_master_groups_fy') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0091_opening_bills_vouchers_day_book.sql
-- ═══════════════════════════════════════════════════════════════════════════

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


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0092_purchase_orders_goods_receipts.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0092 — Purchase order → goods receipt → supplier bill
-- =============================================================================
-- BUSY requirements F33–F37, F40 (docs/accounting-feature-gap-analysis.md).
--
-- Accessories and spares arrive from the OEM before, or without, the bill. Until
-- now the only way to bring them into stock was the supplier bill itself, so
-- goods on the shelf and unbilled were invisible to the books, and a bill that
-- arrived later had nothing to match against.
--
--   purchase order     what was ordered, at what rate — no accounting effect
--   goods receipt      what arrived, against which order lines, with the
--                      supplier's challan and transport details. Stock in, at
--                      the order rate:
--                          Dr Accessory / Spare Inventory
--                              Cr 2760 Goods Received Not Invoiced
--   supplier bill      a bill line pointing at a receipt line adds NO stock —
--                      the receipt already did. It clears GRNI instead:
--                          Dr 2760 GRNI (the value received)
--                          Dr/Cr 5970 Stock Adjustments (bill rate − order rate)
--                          Dr Input GST
--                              Cr Supplier
--
-- Controls, each enforced here rather than in a screen:
--   * a receipt cannot exceed what is ordered and not yet received;
--   * a bill cannot bill more of a receipt line than was received and not yet
--     billed on another posted bill;
--   * a receipt that has been billed cannot be cancelled — cancel the bill first;
--   * cancelling a receipt takes its stock back out and reverses its journal;
--   * cancelling a bill that billed a receipt reverses the journal (GRNI owed
--     again) and leaves the stock where it is, because it is still on the shelf.
--
-- 2760 at any moment is the value of goods received and not yet billed;
-- grni_outstanding() lists it line by line, and 9ZJ ties the two.
--
-- Permissions reuse the purchase set: purchases.create raises and edits orders,
-- purchases.post approves them and posts receipts, purchases.cancel cancels.
--
-- Rollback: drop the tables, functions and the grn_line_id column added here;
--           restore post_purchase_bill (0084) and cancel_purchase_bill (0052).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Goods Received Not Invoiced, and its posting rules
-- -----------------------------------------------------------------------------
create or replace function app.seed_purchase_order_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
declare
  v_added integer := 0;
  a       record;
begin
  for a in
    select * from (values
      ('2760', 'Goods Received Not Invoiced', 'LIABILITY', 'CREDIT')
    ) as t(code, name, account_type, normal_balance)
  loop
    insert into public.chart_of_accounts
      (dealer_id, code, name, account_type, normal_balance, is_group, parent_id, is_system, is_branch_scoped)
    select p_dealer_id, a.code, a.name, a.account_type, a.normal_balance, false, p.id, true, false
      from public.chart_of_accounts p
     where p.dealer_id = p_dealer_id and p.is_group
       and p.code = (select coalesce(max(code) filter (where code = '2001'), '2000')
                       from public.chart_of_accounts
                      where dealer_id = p_dealer_id and code in ('2000', '2001') and is_group)
    on conflict on constraint coa_dealer_code_key do nothing;
    if found then v_added := v_added + 1; end if;
  end loop;

  insert into public.accounting_rules (dealer_id, module, event, component, side, account_id, description)
  select p_dealer_id, 'INVENTORY', 'PURCHASE', r.component, r.side, c.id, 'Default mapping'
    from (values ('GRNI', 'CREDIT', '2760'), ('PRICE_VARIANCE', 'DEBIT', '5970')) as r(component, side, code)
    join public.chart_of_accounts c on c.dealer_id = p_dealer_id and c.code = r.code and not c.is_group
   where not exists (select 1 from public.accounting_rules x
                      where x.dealer_id = p_dealer_id and x.module = 'INVENTORY' and x.event = 'PURCHASE'
                        and x.component = r.component and x.branch_id is null and x.status = 'ACTIVE');

  return v_added;
end;
$$;

do $$
declare d record;
begin
  for d in select id from public.dealers loop
    perform app.seed_purchase_order_accounts(d.id);
  end loop;
end $$;

alter function app.seed_chart_of_accounts(uuid) rename to seed_chart_of_accounts_0091;

create or replace function app.seed_chart_of_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
begin
  return app.seed_chart_of_accounts_0091(p_dealer_id) + app.seed_purchase_order_accounts(p_dealer_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. Tables
-- -----------------------------------------------------------------------------
create table public.purchase_orders (
  id              uuid primary key default gen_random_uuid(),
  dealer_id       uuid not null references public.dealers (id) on delete restrict,
  branch_id       uuid not null,
  po_number       text not null,
  supplier_id     uuid not null,
  order_date      date not null default current_date,
  expected_date   date,
  status          text not null default 'DRAFT',
  notes           text,
  idempotency_key text,
  approved_at     timestamptz,
  approved_by     uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  created_by      uuid,
  updated_by      uuid,

  constraint purchase_orders_number_key unique (dealer_id, po_number),
  constraint purchase_orders_id_dealer_key unique (id, dealer_id),
  constraint purchase_orders_idem_key unique (dealer_id, idempotency_key),
  constraint purchase_orders_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint purchase_orders_supplier_tenant_fkey
    foreign key (supplier_id, dealer_id) references public.suppliers (id, dealer_id),
  constraint purchase_orders_status_check
    check (status in ('DRAFT', 'APPROVED', 'PARTIAL', 'RECEIVED', 'CLOSED', 'CANCELLED')),
  constraint purchase_orders_expected_check check (expected_date is null or expected_date >= order_date)
);

create table public.purchase_order_lines (
  id                uuid primary key default gen_random_uuid(),
  purchase_order_id uuid not null,
  dealer_id         uuid not null,
  line_number       integer not null,
  line_type         text not null,
  item_id           uuid not null,
  source            text not null,
  description       text not null,
  quantity          numeric(14, 3) not null,
  unit_rate         numeric(18, 4) not null,
  cgst_rate         numeric(6, 3) not null default 0,
  sgst_rate         numeric(6, 3) not null default 0,
  igst_rate         numeric(6, 3) not null default 0,

  constraint pol_order_line_key unique (purchase_order_id, line_number),
  constraint pol_id_dealer_key unique (id, dealer_id),
  constraint pol_order_tenant_fkey
    foreign key (purchase_order_id, dealer_id) references public.purchase_orders (id, dealer_id) on delete cascade,
  constraint pol_item_tenant_fkey
    foreign key (item_id, dealer_id) references public.inventory_items (id, dealer_id),
  constraint pol_type_check check (line_type in ('ACCESSORY', 'SPARE')),
  constraint pol_source_check check (source in ('LOCAL', 'COMPANY')),
  constraint pol_quantity_check check (quantity > 0),
  constraint pol_rate_check check (unit_rate >= 0),
  constraint pol_tax_check check (cgst_rate >= 0 and sgst_rate >= 0 and igst_rate >= 0
                                  and (igst_rate = 0 or (cgst_rate = 0 and sgst_rate = 0)))
);

create table public.goods_receipts (
  id                     uuid primary key default gen_random_uuid(),
  dealer_id              uuid not null references public.dealers (id) on delete restrict,
  branch_id              uuid not null,
  grn_number             text not null,
  purchase_order_id      uuid not null,
  supplier_id            uuid not null,
  receipt_date           date not null default current_date,
  supplier_challan_number text,
  transporter            text,
  lr_number              text,
  vehicle_number         text,
  origin                 text,
  origin_pincode         text,
  status                 text not null default 'POSTED',
  total_value            numeric(18, 4) not null default 0,
  journal_entry_id       uuid,
  idempotency_key        text,
  cancel_reason          text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  created_by             uuid,
  updated_by             uuid,

  constraint goods_receipts_number_key unique (dealer_id, grn_number),
  constraint goods_receipts_id_dealer_key unique (id, dealer_id),
  constraint goods_receipts_idem_key unique (dealer_id, idempotency_key),
  constraint goods_receipts_order_tenant_fkey
    foreign key (purchase_order_id, dealer_id) references public.purchase_orders (id, dealer_id),
  constraint goods_receipts_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint goods_receipts_supplier_tenant_fkey
    foreign key (supplier_id, dealer_id) references public.suppliers (id, dealer_id),
  constraint goods_receipts_status_check check (status in ('POSTED', 'CANCELLED')),
  constraint goods_receipts_pin_check check (origin_pincode is null or origin_pincode ~ '^[1-9][0-9]{5}$')
);

create table public.goods_receipt_lines (
  id                  uuid primary key default gen_random_uuid(),
  goods_receipt_id    uuid not null,
  dealer_id           uuid not null,
  po_line_id          uuid not null,
  line_number         integer not null,
  line_type           text not null,
  item_id             uuid not null,
  source              text not null,
  quantity            numeric(14, 3) not null,
  unit_cost           numeric(18, 4) not null,
  value               numeric(18, 4) not null,

  constraint grl_receipt_line_key unique (goods_receipt_id, line_number),
  constraint grl_id_dealer_key unique (id, dealer_id),
  constraint grl_receipt_tenant_fkey
    foreign key (goods_receipt_id, dealer_id) references public.goods_receipts (id, dealer_id) on delete cascade,
  constraint grl_po_line_tenant_fkey
    foreign key (po_line_id, dealer_id) references public.purchase_order_lines (id, dealer_id),
  constraint grl_item_tenant_fkey
    foreign key (item_id, dealer_id) references public.inventory_items (id, dealer_id),
  constraint grl_quantity_check check (quantity > 0),
  constraint grl_value_check check (value >= 0)
);

alter table public.purchase_bill_lines add column grn_line_id uuid;
alter table public.purchase_bill_lines
  add constraint pbl_grn_line_tenant_fkey
    foreign key (grn_line_id, dealer_id) references public.goods_receipt_lines (id, dealer_id);
alter table public.purchase_bill_lines
  add constraint pbl_grn_line_type_check check (grn_line_id is null or (line_type <> 'VEHICLE' and line_type <> 'EXPENSE'));

create index pol_order_idx on public.purchase_order_lines (purchase_order_id);
create index grl_receipt_idx on public.goods_receipt_lines (goods_receipt_id);
create index grl_po_line_idx on public.goods_receipt_lines (po_line_id);
create index pbl_grn_line_idx on public.purchase_bill_lines (grn_line_id) where grn_line_id is not null;
create index purchase_orders_dealer_status_idx on public.purchase_orders (dealer_id, status);
create index goods_receipts_order_idx on public.goods_receipts (purchase_order_id);

comment on table public.purchase_orders is 'What was ordered from a supplier (BUSY F33). No accounting effect.';
comment on table public.goods_receipts is
  'What arrived against an order (F34, F36): stock in at the order rate, Cr 2760 GRNI.';
comment on column public.purchase_bill_lines.grn_line_id is
  'The receipt line this bill line bills. Such a line adds no stock; it clears GRNI (F37).';

-- Numbers, self-provisioned per financial year as purchase bills are (0052).
create or replace function app.purchase_orders_assign_number()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_year text;
begin
  if new.po_number is not null and btrim(new.po_number) <> '' then
    return new;
  end if;
  v_year := app.financial_year_token(new.dealer_id, coalesce(new.order_date, current_date));
  insert into public.document_sequences (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
  values (new.dealer_id, null, 'PURCHASE_ORDER', v_year, 'PO', 6)
  on conflict on constraint document_sequences_scope_key do nothing;
  new.po_number := app.next_document_number(new.dealer_id, null, 'PURCHASE_ORDER', v_year);
  return new;
end;
$$;

create trigger purchase_orders_assign_number
  before insert on public.purchase_orders
  for each row execute function app.purchase_orders_assign_number();

create or replace function app.goods_receipts_assign_number()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_year text;
begin
  if new.grn_number is not null and btrim(new.grn_number) <> '' then
    return new;
  end if;
  v_year := app.financial_year_token(new.dealer_id, coalesce(new.receipt_date, current_date));
  insert into public.document_sequences (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
  values (new.dealer_id, null, 'GOODS_RECEIPT', v_year, 'GRN', 6)
  on conflict on constraint document_sequences_scope_key do nothing;
  new.grn_number := app.next_document_number(new.dealer_id, null, 'GOODS_RECEIPT', v_year);
  return new;
end;
$$;

create trigger goods_receipts_assign_number
  before insert on public.goods_receipts
  for each row execute function app.goods_receipts_assign_number();

create trigger purchase_orders_set_updated_at before update on public.purchase_orders
  for each row execute function app.set_updated_at();
create trigger goods_receipts_set_updated_at before update on public.goods_receipts
  for each row execute function app.set_updated_at();
create trigger purchase_orders_audit after insert or update or delete on public.purchase_orders
  for each row execute function app.audit_trigger();
create trigger goods_receipts_audit after insert or update or delete on public.goods_receipts
  for each row execute function app.audit_trigger();

-- -----------------------------------------------------------------------------
-- 3. Row-level security
-- -----------------------------------------------------------------------------
alter table public.purchase_orders      enable row level security;
alter table public.purchase_order_lines enable row level security;
alter table public.goods_receipts       enable row level security;
alter table public.goods_receipt_lines  enable row level security;

create policy purchase_orders_select on public.purchase_orders
  for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.can_access_branch(branch_id)
             and app.has_permission('purchases.view')));
create policy purchase_orders_write on public.purchase_orders
  for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.can_access_branch(branch_id)
             and (app.has_permission('purchases.create') or app.has_permission('purchases.post')
                  or app.has_permission('purchases.cancel'))))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.can_access_branch(branch_id)
             and (app.has_permission('purchases.create') or app.has_permission('purchases.post')
                  or app.has_permission('purchases.cancel'))));

create policy purchase_order_lines_select on public.purchase_order_lines
  for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and exists (select 1 from public.purchase_orders o where o.id = purchase_order_id)));
create policy purchase_order_lines_write on public.purchase_order_lines
  for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('purchases.create')))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('purchases.create')));

create policy goods_receipts_select on public.goods_receipts
  for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.can_access_branch(branch_id)
             and app.has_permission('purchases.view')));
create policy goods_receipts_write on public.goods_receipts
  for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.can_access_branch(branch_id)
             and (app.has_permission('purchases.post') or app.has_permission('purchases.cancel'))))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.can_access_branch(branch_id)
             and (app.has_permission('purchases.post') or app.has_permission('purchases.cancel'))));

create policy goods_receipt_lines_select on public.goods_receipt_lines
  for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and exists (select 1 from public.goods_receipts g where g.id = goods_receipt_id)));
create policy goods_receipt_lines_write on public.goods_receipt_lines
  for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('purchases.post')))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id() and app.has_permission('purchases.post')));

-- -----------------------------------------------------------------------------
-- 4. What has been received and billed, per order line and receipt line
-- -----------------------------------------------------------------------------
create or replace function app.po_line_received(p_po_line_id uuid)
returns numeric
language sql
stable
as $$
  select coalesce(sum(l.quantity), 0)
    from public.goods_receipt_lines l
    join public.goods_receipts g on g.id = l.goods_receipt_id
   where l.po_line_id = p_po_line_id and g.status = 'POSTED';
$$;

create or replace function app.grn_line_billed(p_grn_line_id uuid, p_except_bill uuid default null)
returns numeric
language sql
stable
as $$
  select coalesce(sum(bl.quantity), 0)
    from public.purchase_bill_lines bl
    join public.purchase_bills b on b.id = bl.purchase_bill_id
   where bl.grn_line_id = p_grn_line_id
     and b.status = 'POSTED'
     and (p_except_bill is null or b.id <> p_except_bill);
$$;

-- -----------------------------------------------------------------------------
-- 5. Orders
-- -----------------------------------------------------------------------------
-- p_lines: [{"item_id": "…", "source": "COMPANY", "quantity": 10, "unit_rate": 450,
--            "cgst_rate": 9, "sgst_rate": 9, "igst_rate": 0, "description": "…"}]
create or replace function public.create_purchase_order(
  p_branch_id       uuid,
  p_supplier_id     uuid,
  p_lines           jsonb,
  p_order_date      date default current_date,
  p_expected_date   date default null,
  p_notes           text default null,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_id     uuid;
  v_line   jsonb;
  v_item   public.inventory_items;
  v_n      integer := 0;
begin
  if v_dealer is null or not app.has_permission('purchases.create') then
    raise exception 'You may not raise purchase orders.' using errcode = 'insufficient_privilege';
  end if;
  if p_idempotency_key is not null then
    select id into v_id from public.purchase_orders
     where dealer_id = v_dealer and idempotency_key = p_idempotency_key;
    if v_id is not null then return v_id; end if;
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Add at least one item to the order.' using errcode = 'check_violation';
  end if;

  insert into public.purchase_orders
    (dealer_id, branch_id, supplier_id, order_date, expected_date, notes, idempotency_key, created_by)
  values
    (v_dealer, p_branch_id, p_supplier_id, coalesce(p_order_date, current_date), p_expected_date,
     nullif(btrim(p_notes), ''), p_idempotency_key, auth.uid())
  returning id into v_id;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_n := v_n + 1;
    select * into v_item from public.inventory_items
     where id = nullif(v_line ->> 'item_id', '')::uuid and dealer_id = v_dealer;
    if v_item.id is null then
      raise exception 'Line %: choose the item.', v_n using errcode = 'check_violation';
    end if;
    insert into public.purchase_order_lines
      (purchase_order_id, dealer_id, line_number, line_type, item_id, source, description,
       quantity, unit_rate, cgst_rate, sgst_rate, igst_rate)
    values
      (v_id, v_dealer, v_n, v_item.item_type, v_item.id, coalesce(nullif(v_line ->> 'source', ''), 'COMPANY'),
       coalesce(nullif(btrim(v_line ->> 'description'), ''), v_item.name),
       (v_line ->> 'quantity')::numeric, coalesce((v_line ->> 'unit_rate')::numeric, 0),
       coalesce((v_line ->> 'cgst_rate')::numeric, 0), coalesce((v_line ->> 'sgst_rate')::numeric, 0),
       coalesce((v_line ->> 'igst_rate')::numeric, 0));
  end loop;

  return v_id;
end;
$$;

create or replace function public.approve_purchase_order(p_order_id uuid)
returns void
language plpgsql
as $$
declare
  v_po public.purchase_orders;
begin
  if not app.has_permission('purchases.post') then
    raise exception 'You may not approve purchase orders.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_po from public.purchase_orders where id = p_order_id for update;
  if v_po.id is null then
    raise exception 'Purchase order not found.' using errcode = 'no_data_found';
  end if;
  if v_po.status <> 'DRAFT' then
    raise exception 'Purchase order % is %.', v_po.po_number, lower(v_po.status) using errcode = 'check_violation';
  end if;
  update public.purchase_orders
     set status = 'APPROVED', approved_at = now(), approved_by = auth.uid(), updated_by = auth.uid()
   where id = p_order_id;
end;
$$;

-- Cancel an order nothing has been received against; close one that is partly
-- received so its remainder stops showing as pending.
create or replace function public.close_purchase_order(p_order_id uuid, p_reason text)
returns text
language plpgsql
as $$
declare
  v_po       public.purchase_orders;
  v_received boolean;
begin
  if not (app.has_permission('purchases.cancel') or app.has_permission('purchases.post')) then
    raise exception 'You may not close purchase orders.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(length(btrim(p_reason)), 0) < 3 then
    raise exception 'Say why the order is being closed.' using errcode = 'check_violation';
  end if;
  select * into v_po from public.purchase_orders where id = p_order_id for update;
  if v_po.id is null then
    raise exception 'Purchase order not found.' using errcode = 'no_data_found';
  end if;
  if v_po.status in ('CLOSED', 'CANCELLED', 'RECEIVED') then
    raise exception 'Purchase order % is already %.', v_po.po_number, lower(v_po.status) using errcode = 'check_violation';
  end if;
  select exists (select 1 from public.goods_receipts where purchase_order_id = p_order_id and status = 'POSTED')
    into v_received;
  update public.purchase_orders
     set status = case when v_received then 'CLOSED' else 'CANCELLED' end,
         notes = coalesce(notes || E'\n', '') || case when v_received then 'Closed: ' else 'Cancelled: ' end || btrim(p_reason),
         updated_by = auth.uid()
   where id = p_order_id;
  return case when v_received then 'CLOSED' else 'CANCELLED' end;
end;
$$;

create or replace function app.refresh_purchase_order_status(p_order_id uuid)
returns void
language plpgsql
as $$
declare
  v_ordered  numeric;
  v_received numeric;
begin
  select coalesce(sum(quantity), 0), coalesce(sum(app.po_line_received(id)), 0)
    into v_ordered, v_received
    from public.purchase_order_lines where purchase_order_id = p_order_id;
  update public.purchase_orders
     set status = case when v_received = 0 then 'APPROVED'
                       when v_received >= v_ordered then 'RECEIVED'
                       else 'PARTIAL' end
   where id = p_order_id and status in ('APPROVED', 'PARTIAL', 'RECEIVED');
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Goods receipt
-- -----------------------------------------------------------------------------
-- p_lines: [{"po_line_id": "…", "quantity": 6}]
-- p_transport: {"supplier_challan_number": "…", "transporter": "…", "lr_number": "…",
--               "vehicle_number": "…", "origin": "…", "origin_pincode": "…"}
create or replace function public.post_goods_receipt(
  p_order_id        uuid,
  p_lines           jsonb,
  p_receipt_date    date default current_date,
  p_transport       jsonb default '{}'::jsonb,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_po      public.purchase_orders;
  v_id      uuid;
  v_line    jsonb;
  v_pol     public.purchase_order_lines;
  v_qty     numeric(14, 3);
  v_left    numeric(14, 3);
  v_value   numeric(18, 4);
  v_total   numeric(18, 4) := 0;
  v_n       integer := 0;
  v_jl      jsonb := '[]'::jsonb;
  v_grn     public.goods_receipts;
  v_entry   uuid;
  v_t       jsonb := coalesce(p_transport, '{}'::jsonb);
begin
  if not app.has_permission('purchases.post') then
    raise exception 'You may not receive goods.' using errcode = 'insufficient_privilege';
  end if;

  select * into v_po from public.purchase_orders where id = p_order_id for update;
  if v_po.id is null then
    raise exception 'Purchase order not found.' using errcode = 'no_data_found';
  end if;
  if p_idempotency_key is not null then
    select id into v_id from public.goods_receipts
     where dealer_id = v_po.dealer_id and idempotency_key = p_idempotency_key;
    if v_id is not null then return v_id; end if;
  end if;
  if v_po.status not in ('APPROVED', 'PARTIAL') then
    raise exception 'Purchase order % is % — goods are received only against an approved order.',
      v_po.po_number, lower(v_po.status) using errcode = 'check_violation';
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Enter what was received.' using errcode = 'check_violation';
  end if;
  if coalesce(p_receipt_date, current_date) < v_po.order_date then
    raise exception 'Goods cannot be received before they were ordered (%).', v_po.order_date
      using errcode = 'check_violation';
  end if;

  insert into public.goods_receipts
    (dealer_id, branch_id, purchase_order_id, supplier_id, receipt_date,
     supplier_challan_number, transporter, lr_number, vehicle_number, origin, origin_pincode,
     idempotency_key, created_by)
  values
    (v_po.dealer_id, v_po.branch_id, v_po.id, v_po.supplier_id, coalesce(p_receipt_date, current_date),
     nullif(btrim(v_t ->> 'supplier_challan_number'), ''), nullif(btrim(v_t ->> 'transporter'), ''),
     nullif(btrim(v_t ->> 'lr_number'), ''), nullif(upper(btrim(v_t ->> 'vehicle_number')), ''),
     nullif(btrim(v_t ->> 'origin'), ''), nullif(btrim(v_t ->> 'origin_pincode'), ''),
     p_idempotency_key, auth.uid())
  returning * into v_grn;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_qty := round(coalesce((v_line ->> 'quantity')::numeric, 0), 3);
    if v_qty = 0 then continue; end if;
    if v_qty < 0 then
      raise exception 'A received quantity cannot be negative.' using errcode = 'check_violation';
    end if;

    select * into v_pol from public.purchase_order_lines
     where id = nullif(v_line ->> 'po_line_id', '')::uuid and purchase_order_id = p_order_id
       for update;
    if v_pol.id is null then
      raise exception 'A received line does not belong to order %.', v_po.po_number using errcode = 'check_violation';
    end if;
    v_left := v_pol.quantity - app.po_line_received(v_pol.id);
    if v_qty > v_left then
      raise exception '% — % ordered, % still to come; % cannot be received.',
        v_pol.description, v_pol.quantity, v_left, v_qty using errcode = 'check_violation';
    end if;

    v_n := v_n + 1;
    v_value := round(v_qty * v_pol.unit_rate, 2);
    v_total := v_total + v_value;

    insert into public.goods_receipt_lines
      (goods_receipt_id, dealer_id, po_line_id, line_number, line_type, item_id, source, quantity, unit_cost, value)
    values
      (v_grn.id, v_po.dealer_id, v_pol.id, v_n, v_pol.line_type, v_pol.item_id, v_pol.source,
       v_qty, v_pol.unit_rate, v_value);

    insert into public.inventory_transactions
      (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
       reference_type, reference_id, reference_number, narration, created_by)
    values
      (v_po.dealer_id, v_po.branch_id, v_pol.item_id, v_pol.source, 'PURCHASE',
       v_qty, v_pol.unit_rate, 'GOODS_RECEIPT', v_grn.id, v_grn.grn_number,
       'Received on ' || v_grn.grn_number || ' against ' || v_po.po_number, auth.uid());

    if v_value > 0 then
      v_jl := v_jl || jsonb_build_array(jsonb_build_object(
        'account_id', app.require_account(v_po.dealer_id, 'INVENTORY', 'PURCHASE',
                        case when v_pol.line_type = 'ACCESSORY' then 'ACCESSORY_INVENTORY' else 'SPARE_INVENTORY' end,
                        v_po.branch_id),
        'debit', v_value, 'credit', 0, 'narration', v_pol.description));
    end if;
  end loop;

  if v_n = 0 then
    raise exception 'Nothing was received — every quantity is zero.' using errcode = 'check_violation';
  end if;

  if v_total > 0 then
    v_jl := v_jl || jsonb_build_array(jsonb_build_object(
      'account_id', app.require_account(v_po.dealer_id, 'INVENTORY', 'PURCHASE', 'GRNI', v_po.branch_id),
      'debit', 0, 'credit', v_total,
      'narration', 'Received, not yet billed — ' || v_po.po_number));
    v_entry := app.post_journal(
      v_po.dealer_id, v_po.branch_id, v_grn.receipt_date, 'INVENTORY',
      'Goods receipt ' || v_grn.grn_number || ' against ' || v_po.po_number,
      v_jl, 'GOODS_RECEIPT', v_grn.id, 'grn:' || v_grn.id::text);
  end if;

  update public.goods_receipts set total_value = v_total, journal_entry_id = v_entry where id = v_grn.id;
  perform app.refresh_purchase_order_status(p_order_id);
  return v_grn.id;
end;
$$;

create or replace function public.cancel_goods_receipt(p_receipt_id uuid, p_reason text)
returns void
language plpgsql
as $$
declare
  v_grn  public.goods_receipts;
  v_line record;
begin
  if not (app.has_permission('purchases.cancel') or app.has_permission('purchases.post')) then
    raise exception 'You may not cancel goods receipts.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(length(btrim(p_reason)), 0) < 3 then
    raise exception 'Cancelling a goods receipt requires a reason.' using errcode = 'check_violation';
  end if;
  select * into v_grn from public.goods_receipts where id = p_receipt_id for update;
  if v_grn.id is null then
    raise exception 'Goods receipt not found.' using errcode = 'no_data_found';
  end if;
  if v_grn.status = 'CANCELLED' then
    raise exception 'Goods receipt % is already cancelled.', v_grn.grn_number using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.purchase_bill_lines bl
               join public.purchase_bills b on b.id = bl.purchase_bill_id
               join public.goods_receipt_lines l on l.id = bl.grn_line_id
              where l.goods_receipt_id = p_receipt_id and b.status in ('DRAFT', 'POSTED')) then
    raise exception 'Goods receipt % is on a supplier bill. Remove it from the bill, or cancel the bill, first.',
      v_grn.grn_number using errcode = 'check_violation';
  end if;

  for v_line in select * from public.goods_receipt_lines where goods_receipt_id = p_receipt_id loop
    insert into public.inventory_transactions
      (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
       reference_type, reference_id, reference_number, narration, reason, created_by)
    values
      (v_grn.dealer_id, v_grn.branch_id, v_line.item_id, v_line.source, 'REVERSAL',
       -v_line.quantity, v_line.unit_cost, 'GOODS_RECEIPT', v_grn.id, v_grn.grn_number,
       'Cancelled ' || v_grn.grn_number, btrim(p_reason), auth.uid());
  end loop;

  if v_grn.journal_entry_id is not null then
    perform app.reverse_journal(v_grn.journal_entry_id, btrim(p_reason), current_date);
  end if;

  update public.goods_receipts
     set status = 'CANCELLED', cancel_reason = btrim(p_reason), updated_by = auth.uid()
   where id = p_receipt_id;
  perform app.refresh_purchase_order_status(v_grn.purchase_order_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Billing a receipt
-- -----------------------------------------------------------------------------
-- p_lines: [{"grn_line_id": "…", "quantity": 6, "unit_rate": 455}] — rate
-- defaults to the order rate; tax rates come from the order line.
create or replace function public.add_receipt_lines_to_bill(p_bill_id uuid, p_lines jsonb)
returns integer
language plpgsql
as $$
declare
  v_bill  public.purchase_bills;
  v_line  jsonb;
  v_grl   record;
  v_qty   numeric(14, 3);
  v_rate  numeric(18, 4);
  v_left  numeric(14, 3);
  v_tax   numeric(18, 4);
  v_cgst  numeric(18, 4);
  v_sgst  numeric(18, 4);
  v_igst  numeric(18, 4);
  v_n     integer;
  v_added integer := 0;
begin
  if not app.has_permission('purchases.create') then
    raise exception 'You may not edit purchase bills.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_bill from public.purchase_bills where id = p_bill_id for update;
  if v_bill.id is null then
    raise exception 'Purchase bill not found.' using errcode = 'no_data_found';
  end if;
  if v_bill.status <> 'DRAFT' then
    raise exception 'Purchase bill % is % and cannot change.', v_bill.bill_number, lower(v_bill.status)
      using errcode = 'check_violation';
  end if;

  select coalesce(max(line_number), 0) into v_n from public.purchase_bill_lines where purchase_bill_id = p_bill_id;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    select l.*, g.supplier_id, g.branch_id, g.status as grn_status, g.grn_number,
           pol.description, pol.cgst_rate, pol.sgst_rate, pol.igst_rate
      into v_grl
      from public.goods_receipt_lines l
      join public.goods_receipts g on g.id = l.goods_receipt_id
      join public.purchase_order_lines pol on pol.id = l.po_line_id
     where l.id = nullif(v_line ->> 'grn_line_id', '')::uuid
       for update of l;
    if v_grl.id is null then
      raise exception 'A receipt line was not found.' using errcode = 'no_data_found';
    end if;
    if v_grl.grn_status <> 'POSTED' then
      raise exception 'Goods receipt % is cancelled.', v_grl.grn_number using errcode = 'check_violation';
    end if;
    if v_grl.supplier_id <> v_bill.supplier_id then
      raise exception 'Goods receipt % is from another supplier.', v_grl.grn_number using errcode = 'check_violation';
    end if;
    if v_grl.branch_id <> v_bill.branch_id then
      raise exception 'Goods receipt % was received at another branch.', v_grl.grn_number using errcode = 'check_violation';
    end if;

    v_qty := round(coalesce((v_line ->> 'quantity')::numeric, v_grl.quantity), 3);
    v_rate := coalesce((v_line ->> 'unit_rate')::numeric, v_grl.unit_cost);
    v_left := v_grl.quantity - app.grn_line_billed(v_grl.id)
              - coalesce((select sum(quantity) from public.purchase_bill_lines
                           where purchase_bill_id = p_bill_id and grn_line_id = v_grl.id), 0);
    if v_qty <= 0 or v_rate < 0 then
      raise exception 'Enter a quantity above zero and a rate of zero or more.' using errcode = 'check_violation';
    end if;
    if v_qty > v_left then
      raise exception '% on % — % received and not yet billed; % cannot be billed.',
        v_grl.description, v_grl.grn_number, v_left, v_qty using errcode = 'check_violation';
    end if;

    v_tax := round(v_qty * v_rate, 2);
    v_cgst := round(v_tax * v_grl.cgst_rate / 100, 2);
    v_sgst := round(v_tax * v_grl.sgst_rate / 100, 2);
    v_igst := round(v_tax * v_grl.igst_rate / 100, 2);
    v_n := v_n + 1;

    insert into public.purchase_bill_lines
      (purchase_bill_id, dealer_id, line_number, line_type, item_id, source, description,
       quantity, unit_rate, taxable_value, cgst_rate, sgst_rate, igst_rate,
       cgst_amount, sgst_amount, igst_amount, total_amount, grn_line_id)
    values
      (p_bill_id, v_bill.dealer_id, v_n, v_grl.line_type, v_grl.item_id, v_grl.source,
       v_grl.description || ' (' || v_grl.grn_number || ')',
       v_qty, v_rate, v_tax, v_grl.cgst_rate, v_grl.sgst_rate, v_grl.igst_rate,
       v_cgst, v_sgst, v_igst, v_tax + v_cgst + v_sgst + v_igst, v_grl.id);
    v_added := v_added + 1;
  end loop;

  return v_added;
end;
$$;

-- Receipt lines still to be billed for a supplier — what the bill form offers.
create or replace function public.unbilled_receipt_lines(p_supplier_id uuid, p_branch_id uuid default null)
returns table (
  grn_line_id  uuid,
  grn_number   text,
  receipt_date date,
  po_number    text,
  item_id      uuid,
  description  text,
  source       text,
  received     numeric(14, 3),
  billed       numeric(14, 3),
  unbilled     numeric(14, 3),
  unit_cost    numeric(18, 4)
)
language sql
stable
as $$
  select l.id, g.grn_number, g.receipt_date, po.po_number, l.item_id, pol.description, l.source,
         l.quantity, app.grn_line_billed(l.id), l.quantity - app.grn_line_billed(l.id), l.unit_cost
    from public.goods_receipt_lines l
    join public.goods_receipts g on g.id = l.goods_receipt_id
    join public.purchase_orders po on po.id = g.purchase_order_id
    join public.purchase_order_lines pol on pol.id = l.po_line_id
   where g.supplier_id = p_supplier_id
     and g.status = 'POSTED'
     and (p_branch_id is null or g.branch_id = p_branch_id)
     and l.quantity > app.grn_line_billed(l.id)
   order by g.receipt_date, g.grn_number, l.line_number;
$$;

-- -----------------------------------------------------------------------------
-- 8. Reports
-- -----------------------------------------------------------------------------
create or replace function public.pending_purchase_orders(p_include_closed boolean default false)
returns table (
  order_id      uuid,
  po_number     text,
  order_date    date,
  expected_date date,
  status        text,
  supplier_name text,
  branch_name   text,
  po_line_id    uuid,
  description   text,
  ordered       numeric(14, 3),
  received      numeric(14, 3),
  billed        numeric(14, 3),
  pending       numeric(14, 3),
  unit_rate     numeric(18, 4),
  overdue       boolean
)
language sql
stable
as $$
  select po.id, po.po_number, po.order_date, po.expected_date, po.status, s.name, b.name,
         pol.id, pol.description, pol.quantity, r.received, coalesce(bl.billed, 0),
         case when po.status in ('CLOSED', 'CANCELLED') then 0 else greatest(pol.quantity - r.received, 0) end,
         pol.unit_rate,
         po.expected_date is not null and po.expected_date < current_date
           and po.status in ('APPROVED', 'PARTIAL') and pol.quantity > r.received
    from public.purchase_orders po
    join public.purchase_order_lines pol on pol.purchase_order_id = po.id
    join public.suppliers s on s.id = po.supplier_id
    join public.branches b on b.id = po.branch_id
    cross join lateral (select app.po_line_received(pol.id) as received) r
    left join lateral (
      select sum(app.grn_line_billed(l.id)) as billed
        from public.goods_receipt_lines l join public.goods_receipts g on g.id = l.goods_receipt_id
       where l.po_line_id = pol.id and g.status = 'POSTED') bl on true
   where po.dealer_id = app.current_dealer_id()
     and (p_include_closed or po.status in ('DRAFT', 'APPROVED', 'PARTIAL'))
   order by po.order_date, po.po_number, pol.line_number;
$$;

-- Goods received and not yet billed, line by line; its total is 2760's balance.
create or replace function public.grni_outstanding()
returns table (
  grn_line_id  uuid,
  grn_number   text,
  receipt_date date,
  supplier_name text,
  description  text,
  unbilled     numeric(14, 3),
  unit_cost    numeric(18, 4),
  value        numeric(18, 4)
)
language sql
stable
as $$
  select l.id, g.grn_number, g.receipt_date, s.name, pol.description,
         l.quantity - app.grn_line_billed(l.id), l.unit_cost,
         round((l.quantity - app.grn_line_billed(l.id)) * l.unit_cost, 2)
    from public.goods_receipt_lines l
    join public.goods_receipts g on g.id = l.goods_receipt_id
    join public.purchase_order_lines pol on pol.id = l.po_line_id
    join public.suppliers s on s.id = g.supplier_id
   where g.dealer_id = app.current_dealer_id()
     and g.status = 'POSTED'
     and l.quantity > app.grn_line_billed(l.id)
   order by g.receipt_date, g.grn_number;
$$;

-- -----------------------------------------------------------------------------
-- 9. Posting a bill that bills receipts
-- -----------------------------------------------------------------------------
-- 0084's post_purchase_bill with one change: an ACCESSORY/SPARE line that points
-- at a receipt line adds no stock and debits GRNI at the received value, the
-- difference to the bill's rate going to PRICE_VARIANCE; and it refuses billing
-- more than was received.
create or replace function public.post_purchase_bill(
  p_bill_id         uuid,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_bill    public.purchase_bills;
  v_line    record;
  v_lines   jsonb := '[]'::jsonb;
  v_entry   uuid;
  v_count   integer;
  v_account uuid;
  v_veh     record;
  v_total   numeric(18, 4);
  v_debit   numeric(18, 4);
  v_cgst    numeric(18, 4);
  v_sgst    numeric(18, 4);
  v_igst    numeric(18, 4);
  v_rcm     numeric(18, 4);
  v_grl     record;
  v_grni    numeric(18, 4);
  v_var     numeric(18, 4);
  v_inbill  numeric(14, 3);
begin
  select * into v_bill from public.purchase_bills where id = p_bill_id for update;

  if v_bill.id is null then
    raise exception 'Purchase bill not found.' using errcode = 'no_data_found';
  end if;
  if v_bill.status = 'POSTED' then
    return v_bill.journal_entry_id;
  end if;
  if v_bill.status <> 'DRAFT' then
    raise exception 'Purchase bill % is % and cannot be posted.',
      v_bill.bill_number, v_bill.status using errcode = 'check_violation';
  end if;

  select count(*)::integer into v_count
    from public.purchase_bill_lines where purchase_bill_id = p_bill_id;
  if v_count = 0 then
    raise exception 'Purchase bill % has no lines.', v_bill.bill_number
      using errcode = 'check_violation';
  end if;
  if v_bill.total_amount <= 0 then
    raise exception 'Purchase bill % comes to nothing.', v_bill.bill_number
      using errcode = 'check_violation';
  end if;

  for v_line in
    select * from public.purchase_bill_lines
     where purchase_bill_id = p_bill_id
     order by line_number
  loop
    v_debit := v_line.taxable_value;

    if v_line.line_type = 'VEHICLE' then
      select id, status, chassis_no into v_veh
        from public.vehicles where id = v_line.vehicle_id for update;

      if v_veh.id is null then
        raise exception 'The vehicle on line % no longer exists.', v_line.line_number
          using errcode = 'no_data_found';
      end if;
      if v_veh.status <> 'IN_STOCK' then
        raise exception 'Chassis % is % and cannot be put on a purchase bill.',
          v_veh.chassis_no, v_veh.status using errcode = 'check_violation';
      end if;

      update public.vehicles
         set purchase_cost    = v_line.taxable_value,
             purchase_invoice = coalesce(purchase_invoice, v_bill.supplier_bill_number),
             purchase_date    = coalesce(purchase_date, v_bill.bill_date),
             updated_by       = auth.uid()
       where id = v_line.vehicle_id;

      v_account := app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE',
                                       'VEHICLE_INVENTORY', v_bill.branch_id);

    elsif v_line.line_type = 'EXPENSE' then
      v_account := v_line.account_id;
      if not v_line.itc_eligible then
        v_debit := v_debit + v_line.cgst_amount + v_line.sgst_amount + v_line.igst_amount;
      end if;

    elsif v_line.grn_line_id is not null then
      -- Billing goods already received (0092): the receipt brought the stock in
      -- and credited GRNI; the bill clears GRNI at the received value and puts
      -- any difference in rate to price variance. No second stock-in.
      select l.quantity, l.unit_cost, g.status, g.grn_number into v_grl
        from public.goods_receipt_lines l
        join public.goods_receipts g on g.id = l.goods_receipt_id
       where l.id = v_line.grn_line_id
         for update of l;
      if v_grl.status is distinct from 'POSTED' then
        raise exception 'Line %: goods receipt % is cancelled.', v_line.line_number, v_grl.grn_number
          using errcode = 'check_violation';
      end if;
      select coalesce(sum(quantity), 0) into v_inbill
        from public.purchase_bill_lines
       where purchase_bill_id = p_bill_id and grn_line_id = v_line.grn_line_id;
      if v_inbill > v_grl.quantity - app.grn_line_billed(v_line.grn_line_id, p_bill_id) then
        raise exception 'Line %: % received on %, % already billed; % cannot be billed again.',
          v_line.line_number, v_grl.quantity, v_grl.grn_number,
          app.grn_line_billed(v_line.grn_line_id, p_bill_id), v_inbill using errcode = 'check_violation';
      end if;

      v_grni := round(v_line.quantity * v_grl.unit_cost, 2);
      v_var := v_line.taxable_value - v_grni;
      v_account := app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'GRNI', v_bill.branch_id);
      v_debit := v_grni;
      if v_var <> 0 then
        v_lines := v_lines || jsonb_build_object(
          'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'PRICE_VARIANCE', v_bill.branch_id),
          'debit', greatest(v_var, 0), 'credit', greatest(-v_var, 0),
          'narration', 'Rate difference on ' || v_grl.grn_number || ': ' || v_line.description);
      end if;

    else
      insert into public.inventory_transactions
        (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
         reference_type, reference_id, reference_number, narration, created_by)
      values
        (v_bill.dealer_id, v_bill.branch_id, v_line.item_id, v_line.source, 'PURCHASE',
         v_line.quantity, round(v_line.taxable_value / v_line.quantity, 4),
         'PURCHASE_BILL', p_bill_id, v_bill.bill_number,
         'Purchased on ' || v_bill.bill_number, auth.uid());

      v_account := app.require_account(
        v_bill.dealer_id, 'INVENTORY', 'PURCHASE',
        case when v_line.line_type = 'ACCESSORY' then 'ACCESSORY_INVENTORY'
             else 'SPARE_INVENTORY' end,
        v_bill.branch_id);
    end if;

    if v_debit > 0 then
      v_lines := v_lines || jsonb_build_object(
        'account_id', v_account, 'debit', v_debit, 'credit', 0,
        'narration', v_line.description);
    end if;
  end loop;

  select coalesce(sum(cgst_amount), 0), coalesce(sum(sgst_amount), 0), coalesce(sum(igst_amount), 0)
    into v_cgst, v_sgst, v_igst
    from public.purchase_bill_lines
   where purchase_bill_id = p_bill_id and itc_eligible;

  if v_cgst > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_CGST', v_bill.branch_id),
      'debit', v_cgst, 'credit', 0, 'narration', 'Input CGST ' || v_bill.bill_number);
  end if;
  if v_sgst > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_SGST', v_bill.branch_id),
      'debit', v_sgst, 'credit', 0, 'narration', 'Input SGST ' || v_bill.bill_number);
  end if;
  if v_igst > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_IGST', v_bill.branch_id),
      'debit', v_igst, 'credit', 0, 'narration', 'Input IGST ' || v_bill.bill_number);
  end if;

  -- ── Reverse charge: the dealer owes this tax to the government ───────────
  select coalesce(sum(cgst_amount + sgst_amount + igst_amount), 0) into v_rcm
    from public.purchase_bill_lines
   where purchase_bill_id = p_bill_id and reverse_charge;

  if v_rcm > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'RCM_PAYABLE', v_bill.branch_id),
      'debit', 0, 'credit', v_rcm, 'narration', 'GST on reverse charge ' || v_bill.bill_number);
  end if;

  select total_amount into v_total from public.purchase_bills where id = p_bill_id;

  v_lines := v_lines || jsonb_build_object(
    'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'PAYABLE', v_bill.branch_id),
    'debit', 0, 'credit', v_total,
    'narration', 'Bill ' || v_bill.supplier_bill_number,
    'party_type', 'SUPPLIER', 'party_id', v_bill.supplier_id);

  v_entry := app.post_journal(
    v_bill.dealer_id, v_bill.branch_id, v_bill.bill_date,
    case when exists (select 1 from public.purchase_bill_lines
                       where purchase_bill_id = p_bill_id and line_type <> 'EXPENSE')
         then 'INVENTORY' else 'EXPENSE' end,
    'Purchase ' || v_bill.bill_number || ' — ' || v_bill.supplier_bill_number,
    v_lines,
    'PURCHASE_BILL', p_bill_id,
    coalesce(p_idempotency_key, 'purchase-bill:' || p_bill_id::text)
  );

  update public.purchase_bills
     set status = 'POSTED', journal_entry_id = v_entry,
         posted_at = now(), posted_by = auth.uid(), updated_by = auth.uid()
   where id = p_bill_id;

  return v_entry;
end;
$$;

-- Cancelling a bill that billed a receipt: the journal reverses (GRNI is owed
-- again) and the stock stays — it is still on the shelf.
create or replace function public.cancel_purchase_bill(
  p_bill_id uuid,
  p_reason  text
)
returns uuid
language plpgsql
as $$
declare
  v_bill  public.purchase_bills;
  v_line  record;
  v_entry uuid;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'Cancelling a purchase bill requires a reason.'
      using errcode = 'check_violation',
            hint = 'Spec §23: the reason is part of the record, not optional.';
  end if;

  select * into v_bill from public.purchase_bills where id = p_bill_id for update;
  if v_bill.id is null then
    raise exception 'Purchase bill not found.' using errcode = 'no_data_found';
  end if;
  if v_bill.status = 'CANCELLED' then
    raise exception 'Purchase bill % is already cancelled.', v_bill.bill_number
      using errcode = 'check_violation';
  end if;

  -- A draft never reached the ledger, so there is nothing to reverse. Deleting
  -- it releases its chassis back to the unbilled list.
  if v_bill.status = 'DRAFT' then
    delete from public.purchase_bills where id = p_bill_id;
    return null;
  end if;

  -- Posted: reverse the journal and take the stock back out again.
  v_entry := app.reverse_journal(v_bill.journal_entry_id, btrim(p_reason), current_date);

  for v_line in
    select * from public.purchase_bill_lines
     where purchase_bill_id = p_bill_id and line_type in ('ACCESSORY', 'SPARE')
       -- A line that billed a goods receipt brought no stock in; the goods stay.
       and grn_line_id is null
  loop
    insert into public.inventory_transactions
      (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
       reference_type, reference_id, reference_number, narration, reason, created_by)
    values
      (v_bill.dealer_id, v_bill.branch_id, v_line.item_id, v_line.source, 'REVERSAL',
       -v_line.quantity, round(v_line.taxable_value / v_line.quantity, 4),
       'PURCHASE_BILL', p_bill_id, v_bill.bill_number,
       'Cancelled ' || v_bill.bill_number, btrim(p_reason), auth.uid());
  end loop;

  update public.purchase_bills
     set status = 'CANCELLED', updated_by = auth.uid(),
         notes = coalesce(notes || E'\n', '') || 'Cancelled: ' || btrim(p_reason)
   where id = p_bill_id;

  return v_entry;
end;
$$;

-- A goods receipt is posted by whoever may post purchases.
create or replace function app.posting_permissions(p_source_document_type text)
returns text[]
language sql
immutable
as $$
  select case p_source_document_type
    when 'SALE'               then array['sales.post', 'sales.cancel', 'sales.return']
    when 'SALE_RETURN'        then array['sales.return']
    when 'SALE_PAYMENT'       then array['sales.create', 'sales.post', 'cashbook.receipts.create']
    when 'BOOKING'            then array['bookings.create', 'bookings.cancel']
    when 'BOOKING_APPLY'      then array['sales.post', 'bookings.convert']
    when 'BOOKING_REFUND'     then array['bookings.refund']
    when 'SERVICE_INVOICE'    then array['service.billing.create', 'inventory.counter_sale.create']
    when 'SERVICE_RECEIPT'    then array['service.payments.collect', 'service.billing.create', 'inventory.counter_sale.create']
    when 'CASH_BOOK'          then array['cashbook.receipts.create', 'cashbook.payments.create']
    when 'BANK_BOOK'          then array['bank.book.record', 'cashbook.receipts.create', 'cashbook.payments.create']
    when 'CONTRA'             then array['bank.book.record', 'bank.reconcile']
    when 'BANK_ACCOUNT'       then array['bank.accounts.manage']
    when 'PURCHASE_BILL'      then array['purchases.post', 'purchases.create', 'purchases.cancel']
    when 'PURCHASE_RETURN'    then array['purchases.return', 'purchases.cancel']
    when 'GOODS_RECEIPT'      then array['purchases.post', 'purchases.cancel']
    when 'STOCK_ADJUSTMENT'   then array['inventory.stock.adjust', 'inventory.stock.approve', 'vehicles.stock.adjust']
    when 'STOCK_DAMAGE'       then array['inventory.stock.adjust']
    when 'BRANCH_TRANSFER'    then array['inventory.stock.transfer', 'vehicles.transfers.manage']
    when 'FINANCE_APPLICATION' then array['finance.applications.manage']
    when 'FINANCE_SETTLEMENT' then array['finance.settlements.manage']
    when 'TRADE_ADVANCE'      then array['finance.trade_advance.manage']
    when 'GST_NOTE'           then array['gst.notes.manage']
    when 'GST_SETOFF'         then array['gst.returns.file']
    when 'ITC_ADJUSTMENT'     then array['gst.itc.manage']
    when 'DEPRECIATION'       then array['assets.manage']
    when 'ASSET_DISPOSAL'     then array['assets.manage']
    when 'LOAN'               then array['loans.manage']
    when 'PAYROLL'            then array['hr.payroll.run']
    when 'PAYROLL_PAYMENT'    then array['hr.payroll.run']
    when 'MANUAL_JOURNAL'     then array['accounting.journals.post', 'accounting.journals.approve']
    when 'OPENING_BALANCE'    then array['accounting.journals.post']
    else array['accounting.journals.post']
  end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update, delete on public.purchase_orders, public.purchase_order_lines, public.goods_receipts, public.goods_receipt_lines to authenticated';
    execute 'grant execute on function public.create_purchase_order(uuid, uuid, jsonb, date, date, text, text) to authenticated';
    execute 'grant execute on function public.approve_purchase_order(uuid) to authenticated';
    execute 'grant execute on function public.close_purchase_order(uuid, text) to authenticated';
    execute 'grant execute on function public.post_goods_receipt(uuid, jsonb, date, jsonb, text) to authenticated';
    execute 'grant execute on function public.cancel_goods_receipt(uuid, text) to authenticated';
    execute 'grant execute on function public.add_receipt_lines_to_bill(uuid, jsonb) to authenticated';
    execute 'grant execute on function public.unbilled_receipt_lines(uuid, uuid) to authenticated';
    execute 'grant execute on function public.pending_purchase_orders(boolean) to authenticated';
    execute 'grant execute on function public.grni_outstanding() to authenticated';
    execute 'grant execute on function app.po_line_received(uuid) to authenticated';
    execute 'grant execute on function app.grn_line_billed(uuid, uuid) to authenticated';
    execute 'grant execute on function app.refresh_purchase_order_status(uuid) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant all on public.purchase_orders, public.purchase_order_lines, public.goods_receipts, public.goods_receipt_lines to service_role';
  end if;
end $$;

insert into public.schema_migrations (version, name)
values ('0092', 'purchase_orders_goods_receipts') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0093_tds.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0093 — TDS on supplier bills: sections, payees, deduction, remittance
-- =============================================================================
-- BUSY requirements F61–F67 (docs/accounting-feature-gap-analysis.md).
--
-- ── No rates are shipped ────────────────────────────────────────────────────
--
-- Nothing here knows a TDS rate or threshold. The accountant enters each
-- section — its Act, its section reference, rate, rate without PAN, single and
-- aggregate thresholds, the payee types it covers, the dates it is in force
-- and the source it was taken from — and marks it reviewed. An unreviewed
-- section deducts nothing: the bill is refused until it is reviewed.
--
-- The Income Tax Department's guidance (TDS compliance, incometax.gov.in,
-- read 26 Sep 2026): the Income-tax Act, 2025 applies where the earlier of
-- credit or payment falls on or after 1 April 2026, the Income-tax Act, 1961
-- before it; TDS provisions sit under section 393 of the new Act (194C, for
-- example, is 393(1) Table Sl. No. 6(i)), and rates and thresholds carried
-- over unchanged. Hence a section row carries its Act and effective dates, and
-- a bill takes the row in force on its own date — the credit date.
--
-- ── What a bill does ────────────────────────────────────────────────────────
--
-- When a supplier with a TDS section is billed, post_purchase_bill() works out
-- the deduction (app.tds_compute) and posts, in the same journal:
--
--     Cr Supplier                     bill total − TDS
--     Cr 2745 TDS Payable — Suppliers TDS
--
-- and writes a tds_deductions row — also when the amount is nil, because the
-- aggregate threshold is counted from those rows. The rate is the lower-
-- deduction certificate's while it is valid and within its limit, else the
-- rate without PAN when the payee's PAN is not verified, else the section rate.
-- TDS is rounded to the rupee. How a crossed aggregate threshold is applied is
-- the section's own setting:
--     THIS_BILL        deduct on the bill that crosses it, and after
--     WHOLE_AGGREGATE  also catch up the year's earlier undeducted bills
--     EXCESS_ONLY      deduct only on the part above the threshold
--
-- ── Remittance ──────────────────────────────────────────────────────────────
--
-- record_tds_remittance() records a deposit already made at the bank: challan
-- number, BSR code, date, and the deductions it covers. It is a bank payment
-- Dr 2745 Cr Bank and marks those deductions remitted. It records a payment;
-- it does not make one, and it files nothing — the TDS return is prepared and
-- filed outside this system.
--
-- 2745's balance equals the posted, unremitted deductions; tds_control_check()
-- says so, and 9ZK ties the two. Salary TDS stays on 2740 (0082).
--
-- Rollback: drop the tables, functions and columns added here; restore
--           post_purchase_bill / cancel_purchase_bill from 0092.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Permission, account, rule
-- -----------------------------------------------------------------------------
insert into public.permissions (code, module, description, is_sensitive) values
  ('accounting.tds.manage', 'accounting', 'Manage TDS sections, payee profiles and remittances', false)
on conflict (code) do update set module = excluded.module, description = excluded.description,
                                 is_sensitive = excluded.is_sensitive;

insert into public.role_permissions (role_id, permission_code)
select r.id, 'accounting.tds.manage'
  from public.roles r
 where r.is_system and r.code in ('DEALER_OWNER', 'ACCOUNTS')
on conflict do nothing;

create or replace function app.seed_tds_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
declare
  v_added integer := 0;
  a       record;
begin
  for a in
    select * from (values
      ('2745', 'TDS Payable — Suppliers', 'LIABILITY', 'CREDIT')
    ) as t(code, name, account_type, normal_balance)
  loop
    insert into public.chart_of_accounts
      (dealer_id, code, name, account_type, normal_balance, is_group, parent_id, is_system, is_branch_scoped)
    select p_dealer_id, a.code, a.name, a.account_type, a.normal_balance, false, p.id, true, false
      from public.chart_of_accounts p
     where p.dealer_id = p_dealer_id and p.is_group
       and p.code = (select coalesce(max(code) filter (where code = '2003'), '2000')
                       from public.chart_of_accounts
                      where dealer_id = p_dealer_id and code in ('2000', '2003') and is_group)
    on conflict on constraint coa_dealer_code_key do nothing;
    if found then v_added := v_added + 1; end if;
  end loop;

  insert into public.accounting_rules (dealer_id, module, event, component, side, account_id, description)
  select p_dealer_id, 'INVENTORY', 'PURCHASE', 'TDS_PAYABLE', 'CREDIT', c.id, 'Default mapping'
    from public.chart_of_accounts c
   where c.dealer_id = p_dealer_id and c.code = '2745' and not c.is_group
     and not exists (select 1 from public.accounting_rules x
                      where x.dealer_id = p_dealer_id and x.module = 'INVENTORY' and x.event = 'PURCHASE'
                        and x.component = 'TDS_PAYABLE' and x.branch_id is null and x.status = 'ACTIVE');
  return v_added;
end;
$$;

do $$
declare d record;
begin
  for d in select id from public.dealers loop
    perform app.seed_tds_accounts(d.id);
  end loop;
end $$;

alter function app.seed_chart_of_accounts(uuid) rename to seed_chart_of_accounts_0092;

create or replace function app.seed_chart_of_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
begin
  return app.seed_chart_of_accounts_0092(p_dealer_id) + app.seed_tds_accounts(p_dealer_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. The deductor, the sections, the payees
-- -----------------------------------------------------------------------------
create table public.tds_deductor (
  dealer_id   uuid primary key references public.dealers (id) on delete cascade,
  tan         text,
  enabled     boolean not null default false,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  constraint tds_deductor_tan_check check (tan is null or tan ~ '^[A-Z]{4}[0-9]{5}[A-Z]$'),
  constraint tds_deductor_enabled_needs_tan check (not enabled or tan is not null)
);

comment on table public.tds_deductor is
  'The dealer as a TDS deductor (F61): TAN, and whether bills deduct at all.';

create table public.tds_sections (
  id                  uuid primary key default gen_random_uuid(),
  dealer_id           uuid not null references public.dealers (id) on delete cascade,
  code                text not null,
  act                 text not null,
  section_ref         text not null,
  description         text not null,
  payee_types         text[],
  rate                numeric(6, 3) not null,
  rate_without_pan    numeric(6, 3),
  single_threshold    numeric(18, 2),
  aggregate_threshold numeric(18, 2),
  threshold_basis     text not null default 'THIS_BILL',
  effective_from      date not null,
  effective_to        date,
  source_note         text not null,
  reviewed_by         uuid,
  reviewed_at         timestamptz,
  created_at          timestamptz not null default now(),
  created_by          uuid,

  constraint tds_sections_id_dealer_key unique (id, dealer_id),
  constraint tds_sections_code_check check (code ~ '^[A-Z0-9][A-Z0-9_-]{1,29}$'),
  constraint tds_sections_act_check check (act in ('IT_1961', 'IT_2025')),
  constraint tds_sections_rate_check check (rate between 0 and 100
                                            and (rate_without_pan is null or rate_without_pan between 0 and 100)),
  constraint tds_sections_threshold_check check ((single_threshold is null or single_threshold >= 0)
                                                 and (aggregate_threshold is null or aggregate_threshold >= 0)),
  constraint tds_sections_basis_check check (threshold_basis in ('THIS_BILL', 'WHOLE_AGGREGATE', 'EXCESS_ONLY')),
  constraint tds_sections_dates_check check (effective_to is null or effective_to >= effective_from),
  constraint tds_sections_source_check check (length(btrim(source_note)) >= 5),
  constraint tds_sections_payee_check check (
    payee_types is null or payee_types <@ array['INDIVIDUAL_HUF', 'COMPANY', 'FIRM_LLP', 'OTHER']::text[])
);

comment on table public.tds_sections is
  'TDS sections as the accountant entered them (F62): effective-dated, with the '
  'Act, section reference and source. Rates never change in place — end a row '
  'and add the next. Unreviewed rows deduct nothing.';

create index tds_sections_lookup_idx on public.tds_sections (dealer_id, code, effective_from);

-- A section's rate, thresholds and dates of force are what a posted deduction
-- relied on; they are not edited. Review and ending are the only changes.
create or replace function app.tds_sections_guard()
returns trigger
language plpgsql
as $$
begin
  if (new.code, new.act, new.section_ref, new.rate, new.rate_without_pan, new.single_threshold,
      new.aggregate_threshold, new.threshold_basis, new.effective_from, new.payee_types)
     is distinct from
     (old.code, old.act, old.section_ref, old.rate, old.rate_without_pan, old.single_threshold,
      old.aggregate_threshold, old.threshold_basis, old.effective_from, old.payee_types) then
    raise exception 'A TDS section is not edited: end it and enter the new rate or threshold from its own date.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger tds_sections_guard before update on public.tds_sections
  for each row execute function app.tds_sections_guard();

alter table public.suppliers
  add column tds_section_code text,
  add column tds_payee_type   text,
  add column tds_pan_verified boolean not null default false,
  add column ldc_number       text,
  add column ldc_rate         numeric(6, 3),
  add column ldc_valid_from   date,
  add column ldc_valid_to     date,
  add column ldc_limit        numeric(18, 2),
  add constraint suppliers_tds_payee_check
    check (tds_payee_type is null or tds_payee_type in ('INDIVIDUAL_HUF', 'COMPANY', 'FIRM_LLP', 'OTHER')),
  add constraint suppliers_ldc_check
    check (ldc_number is null or (ldc_rate is not null and ldc_rate between 0 and 100
                                  and ldc_valid_from is not null and ldc_valid_to >= ldc_valid_from));

comment on column public.suppliers.tds_payee_type is
  'The payee''s legal status for TDS (F63) — as documented, never inferred from the name.';

alter table public.purchase_bills
  add column tds_mode text not null default 'AUTO',
  add column tds_section_code text,
  add constraint purchase_bills_tds_mode_check check (tds_mode in ('AUTO', 'NONE'));

comment on column public.purchase_bills.tds_mode is
  'AUTO deducts by the supplier''s (or this bill''s) section; NONE records that this bill bears no TDS.';

create table public.tds_deductions (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null references public.dealers (id) on delete restrict,
  purchase_bill_id uuid not null,
  supplier_id      uuid not null,
  section_id       uuid not null,
  section_code     text not null,
  act              text not null,
  section_ref      text not null,
  bill_date        date not null,
  base             numeric(18, 2) not null,
  deductible_base  numeric(18, 2) not null,
  rate             numeric(6, 3) not null,
  rate_basis       text not null,
  amount           numeric(18, 2) not null,
  certificate      text,
  status           text not null default 'POSTED',
  journal_entry_id uuid,
  remittance_id    uuid,
  created_at       timestamptz not null default now(),

  constraint tds_deductions_bill_key unique (purchase_bill_id),
  constraint tds_deductions_id_dealer_key unique (id, dealer_id),
  constraint tds_deductions_bill_tenant_fkey
    foreign key (purchase_bill_id, dealer_id) references public.purchase_bills (id, dealer_id),
  constraint tds_deductions_supplier_tenant_fkey
    foreign key (supplier_id, dealer_id) references public.suppliers (id, dealer_id),
  constraint tds_deductions_section_tenant_fkey
    foreign key (section_id, dealer_id) references public.tds_sections (id, dealer_id),
  constraint tds_deductions_basis_check check (rate_basis in ('SECTION', 'NO_PAN', 'CERTIFICATE', 'BELOW_THRESHOLD')),
  constraint tds_deductions_status_check check (status in ('POSTED', 'CANCELLED')),
  constraint tds_deductions_amount_check check (amount >= 0 and deductible_base >= 0)
);

create table public.tds_remittances (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null references public.dealers (id) on delete restrict,
  bank_account_id  uuid not null,
  deposit_date     date not null,
  challan_number   text not null,
  bsr_code         text not null,
  amount           numeric(18, 2) not null,
  bank_transaction_id bigint,
  journal_entry_id uuid,
  idempotency_key  text,
  created_at       timestamptz not null default now(),
  created_by       uuid,

  constraint tds_remittances_id_dealer_key unique (id, dealer_id),
  constraint tds_remittances_challan_key unique (dealer_id, bsr_code, deposit_date, challan_number),
  constraint tds_remittances_idem_key unique (dealer_id, idempotency_key),
  constraint tds_remittances_bsr_check check (bsr_code ~ '^[0-9]{7}$'),
  constraint tds_remittances_challan_check check (challan_number ~ '^[0-9A-Za-z/-]{1,20}$'),
  constraint tds_remittances_amount_check check (amount > 0)
);

alter table public.tds_deductions
  add constraint tds_deductions_remittance_tenant_fkey
    foreign key (remittance_id, dealer_id) references public.tds_remittances (id, dealer_id);

create index tds_deductions_supplier_idx on public.tds_deductions (dealer_id, supplier_id, section_code, bill_date);
create index tds_deductions_unremitted_idx on public.tds_deductions (dealer_id) where remittance_id is null and status = 'POSTED';

comment on table public.tds_deductions is
  'One row per bill a TDS section applied to (F64), nil deductions included — the '
  'aggregate threshold is counted from here. The subledger of 2745.';
comment on table public.tds_remittances is
  'A TDS deposit already made (F67): challan, BSR code, date. Recorded, not executed; nothing is filed.';

create trigger tds_deductor_audit after insert or update or delete on public.tds_deductor
  for each row execute function app.audit_trigger();
create trigger tds_sections_audit after insert or update or delete on public.tds_sections
  for each row execute function app.audit_trigger();
create trigger tds_deductions_audit after insert or update or delete on public.tds_deductions
  for each row execute function app.audit_trigger();
create trigger tds_remittances_audit after insert or update or delete on public.tds_remittances
  for each row execute function app.audit_trigger();

alter table public.tds_deductor    enable row level security;
alter table public.tds_sections    enable row level security;
alter table public.tds_deductions  enable row level security;
alter table public.tds_remittances enable row level security;

create policy tds_deductor_select on public.tds_deductor for select to authenticated
  using (app.is_platform_admin() or dealer_id = app.current_dealer_id());
create policy tds_deductor_write on public.tds_deductor for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.tds.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.tds.manage')));

create policy tds_sections_select on public.tds_sections for select to authenticated
  using (app.is_platform_admin() or dealer_id = app.current_dealer_id());
create policy tds_sections_write on public.tds_sections for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.tds.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.tds.manage')));

create policy tds_deductions_select on public.tds_deductions for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('accounting.tds.manage') or app.has_permission('purchases.view'))));
create policy tds_deductions_write on public.tds_deductions for all to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('purchases.post') or app.has_permission('purchases.cancel')
                  or app.has_permission('accounting.tds.manage'))))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('purchases.post') or app.has_permission('purchases.cancel')
                  or app.has_permission('accounting.tds.manage'))));

create policy tds_remittances_select on public.tds_remittances for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.tds.manage')));
create policy tds_remittances_write on public.tds_remittances for insert to authenticated
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('accounting.tds.manage')));

-- -----------------------------------------------------------------------------
-- 3. Sections: enter, review, end
-- -----------------------------------------------------------------------------
create or replace function public.review_tds_section(p_section_id uuid)
returns void
language plpgsql
as $$
begin
  if not app.has_permission('accounting.tds.manage') then
    raise exception 'You may not review TDS sections.' using errcode = 'insufficient_privilege';
  end if;
  update public.tds_sections set reviewed_by = auth.uid(), reviewed_at = now()
   where id = p_section_id and dealer_id = app.current_dealer_id() and reviewed_at is null;
  if not found then
    raise exception 'Section not found, or already reviewed.' using errcode = 'no_data_found';
  end if;
end;
$$;

create or replace function public.end_tds_section(p_section_id uuid, p_effective_to date)
returns void
language plpgsql
as $$
begin
  if not app.has_permission('accounting.tds.manage') then
    raise exception 'You may not change TDS sections.' using errcode = 'insufficient_privilege';
  end if;
  update public.tds_sections set effective_to = p_effective_to
   where id = p_section_id and dealer_id = app.current_dealer_id()
     and effective_from <= p_effective_to and (effective_to is null or effective_to > p_effective_to);
  if not found then
    raise exception 'The section cannot end on that date.' using errcode = 'check_violation';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. Working out a bill's TDS
-- -----------------------------------------------------------------------------
create or replace function app.tds_compute(p_bill_id uuid)
returns table (
  section_id      uuid,
  section_code    text,
  act             text,
  section_ref     text,
  base            numeric(18, 2),
  deductible_base numeric(18, 2),
  rate            numeric(6, 3),
  rate_basis      text,
  amount          numeric(18, 2),
  certificate     text
)
language plpgsql
stable
as $$
declare
  v_bill     public.purchase_bills;
  v_sup      public.suppliers;
  v_code     text;
  v_sec      public.tds_sections;
  v_base     numeric(18, 2);
  v_fy_start date;
  v_prior    numeric(18, 2);
  v_prior_dd numeric(18, 2);
  v_crossed  boolean;
  v_ded      numeric(18, 2);
  v_rate     numeric(6, 3);
  v_basis    text;
  v_cert     text;
  v_used     numeric(18, 2);
begin
  select * into v_bill from public.purchase_bills where id = p_bill_id;
  if v_bill.id is null or v_bill.tds_mode = 'NONE' then return; end if;
  if not coalesce((select enabled from public.tds_deductor where dealer_id = v_bill.dealer_id), false) then return; end if;

  select * into v_sup from public.suppliers where id = v_bill.supplier_id;
  v_code := coalesce(v_bill.tds_section_code, v_sup.tds_section_code);
  if v_code is null then return; end if;

  select * into v_sec from public.tds_sections s
   where s.dealer_id = v_bill.dealer_id and s.code = v_code
     and s.effective_from <= v_bill.bill_date and (s.effective_to is null or s.effective_to >= v_bill.bill_date)
     and (s.payee_types is null or v_sup.tds_payee_type = any (s.payee_types))
   order by s.effective_from desc
   limit 1;
  if v_sec.id is null then
    if exists (select 1 from public.tds_sections s where s.dealer_id = v_bill.dealer_id and s.code = v_code
                 and s.payee_types is not null and v_sup.tds_payee_type is null) then
      raise exception 'TDS section % depends on the payee type; set it on supplier %.', v_code, v_sup.name
        using errcode = 'check_violation';
    end if;
    raise exception 'No TDS section % is in force on % for supplier %.', v_code, to_char(v_bill.bill_date, 'DD-MM-YYYY'), v_sup.name
      using errcode = 'check_violation', hint = 'Enter the section for that date under Accounting → TDS, or mark this bill as bearing no TDS.';
  end if;
  if v_sec.reviewed_at is null then
    raise exception 'TDS section % (%) has not been reviewed; nothing is deducted under an unreviewed rate.', v_code, v_sec.section_ref
      using errcode = 'check_violation';
  end if;

  select coalesce(sum(taxable_value), 0) into v_base from public.purchase_bill_lines where purchase_bill_id = p_bill_id;

  select coalesce(min(p.start_date), make_date(extract(year from v_bill.bill_date)::int - case when extract(month from v_bill.bill_date) < 4 then 1 else 0 end, 4, 1))
    into v_fy_start
    from public.accounting_periods p
   where p.dealer_id = v_bill.dealer_id and v_bill.bill_date between p.start_date and p.end_date;

  select coalesce(sum(d.base), 0), coalesce(sum(d.deductible_base), 0) into v_prior, v_prior_dd
    from public.tds_deductions d
   where d.dealer_id = v_bill.dealer_id and d.supplier_id = v_bill.supplier_id and d.section_code = v_code
     and d.status = 'POSTED' and d.bill_date between v_fy_start and v_bill.bill_date and d.purchase_bill_id <> p_bill_id;

  v_crossed := (v_sec.single_threshold is null and v_sec.aggregate_threshold is null)
            or (v_sec.single_threshold is not null and v_base > v_sec.single_threshold)
            or (v_sec.aggregate_threshold is not null and v_prior + v_base > v_sec.aggregate_threshold);

  if not v_crossed then
    v_ded := 0;
  elsif v_sec.threshold_basis = 'WHOLE_AGGREGATE' then
    v_ded := v_base + greatest(v_prior - v_prior_dd, 0);
  elsif v_sec.threshold_basis = 'EXCESS_ONLY' and v_sec.aggregate_threshold is not null
        and not (v_sec.single_threshold is not null and v_base > v_sec.single_threshold) then
    v_ded := least(v_base, v_prior + v_base - v_sec.aggregate_threshold);
  else
    v_ded := v_base;
  end if;

  v_rate := v_sec.rate;
  v_basis := case when v_ded = 0 then 'BELOW_THRESHOLD' else 'SECTION' end;
  if v_ded > 0 and v_sup.ldc_number is not null
     and v_bill.bill_date between v_sup.ldc_valid_from and v_sup.ldc_valid_to then
    select coalesce(sum(d.deductible_base), 0) into v_used
      from public.tds_deductions d
     where d.supplier_id = v_sup.id and d.certificate = v_sup.ldc_number and d.status = 'POSTED'
       and d.purchase_bill_id <> p_bill_id;
    if v_sup.ldc_limit is null or v_used + v_ded <= v_sup.ldc_limit then
      v_rate := v_sup.ldc_rate; v_basis := 'CERTIFICATE'; v_cert := v_sup.ldc_number;
    end if;
  end if;
  if v_ded > 0 and v_basis = 'SECTION' and not v_sup.tds_pan_verified and v_sec.rate_without_pan is not null then
    v_rate := v_sec.rate_without_pan; v_basis := 'NO_PAN';
  end if;

  section_id := v_sec.id; section_code := v_sec.code; act := v_sec.act; section_ref := v_sec.section_ref;
  base := v_base; deductible_base := v_ded; rate := v_rate; rate_basis := v_basis; certificate := v_cert;
  amount := round(v_ded * v_rate / 100, 0);
  return next;
end;
$$;

-- What a draft bill would deduct — shown before it is posted.
create or replace function public.tds_preview(p_bill_id uuid)
returns table (section_code text, act text, section_ref text, base numeric, deductible_base numeric,
               rate numeric, rate_basis text, amount numeric, certificate text)
language sql
stable
as $$
  select section_code, act, section_ref, base, deductible_base, rate, rate_basis, amount, certificate
    from app.tds_compute(p_bill_id);
$$;

-- -----------------------------------------------------------------------------
-- 5. Posting and cancelling bills (0092's functions, with TDS)
-- -----------------------------------------------------------------------------
create or replace function public.post_purchase_bill(
  p_bill_id         uuid,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_bill    public.purchase_bills;
  v_line    record;
  v_lines   jsonb := '[]'::jsonb;
  v_entry   uuid;
  v_count   integer;
  v_account uuid;
  v_veh     record;
  v_total   numeric(18, 4);
  v_debit   numeric(18, 4);
  v_cgst    numeric(18, 4);
  v_sgst    numeric(18, 4);
  v_igst    numeric(18, 4);
  v_rcm     numeric(18, 4);
  v_grl     record;
  v_grni    numeric(18, 4);
  v_var     numeric(18, 4);
  v_inbill  numeric(14, 3);
  v_tds     record;
  v_tds_amt numeric(18, 4) := 0;
begin
  select * into v_bill from public.purchase_bills where id = p_bill_id for update;

  if v_bill.id is null then
    raise exception 'Purchase bill not found.' using errcode = 'no_data_found';
  end if;
  if v_bill.status = 'POSTED' then
    return v_bill.journal_entry_id;
  end if;
  if v_bill.status <> 'DRAFT' then
    raise exception 'Purchase bill % is % and cannot be posted.',
      v_bill.bill_number, v_bill.status using errcode = 'check_violation';
  end if;

  select count(*)::integer into v_count
    from public.purchase_bill_lines where purchase_bill_id = p_bill_id;
  if v_count = 0 then
    raise exception 'Purchase bill % has no lines.', v_bill.bill_number
      using errcode = 'check_violation';
  end if;
  if v_bill.total_amount <= 0 then
    raise exception 'Purchase bill % comes to nothing.', v_bill.bill_number
      using errcode = 'check_violation';
  end if;

  for v_line in
    select * from public.purchase_bill_lines
     where purchase_bill_id = p_bill_id
     order by line_number
  loop
    v_debit := v_line.taxable_value;

    if v_line.line_type = 'VEHICLE' then
      select id, status, chassis_no into v_veh
        from public.vehicles where id = v_line.vehicle_id for update;

      if v_veh.id is null then
        raise exception 'The vehicle on line % no longer exists.', v_line.line_number
          using errcode = 'no_data_found';
      end if;
      if v_veh.status <> 'IN_STOCK' then
        raise exception 'Chassis % is % and cannot be put on a purchase bill.',
          v_veh.chassis_no, v_veh.status using errcode = 'check_violation';
      end if;

      update public.vehicles
         set purchase_cost    = v_line.taxable_value,
             purchase_invoice = coalesce(purchase_invoice, v_bill.supplier_bill_number),
             purchase_date    = coalesce(purchase_date, v_bill.bill_date),
             updated_by       = auth.uid()
       where id = v_line.vehicle_id;

      v_account := app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE',
                                       'VEHICLE_INVENTORY', v_bill.branch_id);

    elsif v_line.line_type = 'EXPENSE' then
      v_account := v_line.account_id;
      if not v_line.itc_eligible then
        v_debit := v_debit + v_line.cgst_amount + v_line.sgst_amount + v_line.igst_amount;
      end if;

    elsif v_line.grn_line_id is not null then
      -- Billing goods already received (0092): the receipt brought the stock in
      -- and credited GRNI; the bill clears GRNI at the received value and puts
      -- any difference in rate to price variance. No second stock-in.
      select l.quantity, l.unit_cost, g.status, g.grn_number into v_grl
        from public.goods_receipt_lines l
        join public.goods_receipts g on g.id = l.goods_receipt_id
       where l.id = v_line.grn_line_id
         for update of l;
      if v_grl.status is distinct from 'POSTED' then
        raise exception 'Line %: goods receipt % is cancelled.', v_line.line_number, v_grl.grn_number
          using errcode = 'check_violation';
      end if;
      select coalesce(sum(quantity), 0) into v_inbill
        from public.purchase_bill_lines
       where purchase_bill_id = p_bill_id and grn_line_id = v_line.grn_line_id;
      if v_inbill > v_grl.quantity - app.grn_line_billed(v_line.grn_line_id, p_bill_id) then
        raise exception 'Line %: % received on %, % already billed; % cannot be billed again.',
          v_line.line_number, v_grl.quantity, v_grl.grn_number,
          app.grn_line_billed(v_line.grn_line_id, p_bill_id), v_inbill using errcode = 'check_violation';
      end if;

      v_grni := round(v_line.quantity * v_grl.unit_cost, 2);
      v_var := v_line.taxable_value - v_grni;
      v_account := app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'GRNI', v_bill.branch_id);
      v_debit := v_grni;
      if v_var <> 0 then
        v_lines := v_lines || jsonb_build_object(
          'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'PRICE_VARIANCE', v_bill.branch_id),
          'debit', greatest(v_var, 0), 'credit', greatest(-v_var, 0),
          'narration', 'Rate difference on ' || v_grl.grn_number || ': ' || v_line.description);
      end if;

    else
      insert into public.inventory_transactions
        (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
         reference_type, reference_id, reference_number, narration, created_by)
      values
        (v_bill.dealer_id, v_bill.branch_id, v_line.item_id, v_line.source, 'PURCHASE',
         v_line.quantity, round(v_line.taxable_value / v_line.quantity, 4),
         'PURCHASE_BILL', p_bill_id, v_bill.bill_number,
         'Purchased on ' || v_bill.bill_number, auth.uid());

      v_account := app.require_account(
        v_bill.dealer_id, 'INVENTORY', 'PURCHASE',
        case when v_line.line_type = 'ACCESSORY' then 'ACCESSORY_INVENTORY'
             else 'SPARE_INVENTORY' end,
        v_bill.branch_id);
    end if;

    if v_debit > 0 then
      v_lines := v_lines || jsonb_build_object(
        'account_id', v_account, 'debit', v_debit, 'credit', 0,
        'narration', v_line.description);
    end if;
  end loop;

  select coalesce(sum(cgst_amount), 0), coalesce(sum(sgst_amount), 0), coalesce(sum(igst_amount), 0)
    into v_cgst, v_sgst, v_igst
    from public.purchase_bill_lines
   where purchase_bill_id = p_bill_id and itc_eligible;

  if v_cgst > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_CGST', v_bill.branch_id),
      'debit', v_cgst, 'credit', 0, 'narration', 'Input CGST ' || v_bill.bill_number);
  end if;
  if v_sgst > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_SGST', v_bill.branch_id),
      'debit', v_sgst, 'credit', 0, 'narration', 'Input SGST ' || v_bill.bill_number);
  end if;
  if v_igst > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_IGST', v_bill.branch_id),
      'debit', v_igst, 'credit', 0, 'narration', 'Input IGST ' || v_bill.bill_number);
  end if;

  -- ── Reverse charge: the dealer owes this tax to the government ───────────
  select coalesce(sum(cgst_amount + sgst_amount + igst_amount), 0) into v_rcm
    from public.purchase_bill_lines
   where purchase_bill_id = p_bill_id and reverse_charge;

  if v_rcm > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'RCM_PAYABLE', v_bill.branch_id),
      'debit', 0, 'credit', v_rcm, 'narration', 'GST on reverse charge ' || v_bill.bill_number);
  end if;

  select total_amount into v_total from public.purchase_bills where id = p_bill_id;

  -- TDS (0093): what the dealer keeps back from the supplier for the government.
  select * into v_tds from app.tds_compute(p_bill_id);
  v_tds_amt := coalesce(v_tds.amount, 0);
  if v_tds_amt >= v_total then
    raise exception 'TDS of % would take the whole bill of %.', v_tds_amt, v_total using errcode = 'check_violation';
  end if;
  if v_tds_amt > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'TDS_PAYABLE', v_bill.branch_id),
      'debit', 0, 'credit', v_tds_amt,
      'narration', 'TDS ' || v_tds.section_ref || ' on ' || v_bill.supplier_bill_number);
  end if;

  v_lines := v_lines || jsonb_build_object(
    'account_id', app.require_account(v_bill.dealer_id, 'INVENTORY', 'PURCHASE', 'PAYABLE', v_bill.branch_id),
    'debit', 0, 'credit', v_total - v_tds_amt,
    'narration', 'Bill ' || v_bill.supplier_bill_number,
    'party_type', 'SUPPLIER', 'party_id', v_bill.supplier_id);

  v_entry := app.post_journal(
    v_bill.dealer_id, v_bill.branch_id, v_bill.bill_date,
    case when exists (select 1 from public.purchase_bill_lines
                       where purchase_bill_id = p_bill_id and line_type <> 'EXPENSE')
         then 'INVENTORY' else 'EXPENSE' end,
    'Purchase ' || v_bill.bill_number || ' — ' || v_bill.supplier_bill_number,
    v_lines,
    'PURCHASE_BILL', p_bill_id,
    coalesce(p_idempotency_key, 'purchase-bill:' || p_bill_id::text)
  );

  if v_tds.section_id is not null then
    insert into public.tds_deductions
      (dealer_id, purchase_bill_id, supplier_id, section_id, section_code, act, section_ref, bill_date,
       base, deductible_base, rate, rate_basis, amount, certificate, journal_entry_id)
    values
      (v_bill.dealer_id, p_bill_id, v_bill.supplier_id, v_tds.section_id, v_tds.section_code, v_tds.act,
       v_tds.section_ref, v_bill.bill_date, v_tds.base, v_tds.deductible_base, v_tds.rate, v_tds.rate_basis,
       v_tds.amount, v_tds.certificate, v_entry);
  end if;

  update public.purchase_bills
     set status = 'POSTED', journal_entry_id = v_entry,
         posted_at = now(), posted_by = auth.uid(), updated_by = auth.uid()
   where id = p_bill_id;

  return v_entry;
end;
$$;

create or replace function public.cancel_purchase_bill(
  p_bill_id uuid,
  p_reason  text
)
returns uuid
language plpgsql
as $$
declare
  v_bill  public.purchase_bills;
  v_line  record;
  v_entry uuid;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'Cancelling a purchase bill requires a reason.'
      using errcode = 'check_violation',
            hint = 'Spec §23: the reason is part of the record, not optional.';
  end if;

  select * into v_bill from public.purchase_bills where id = p_bill_id for update;
  if v_bill.id is null then
    raise exception 'Purchase bill not found.' using errcode = 'no_data_found';
  end if;
  if v_bill.status = 'CANCELLED' then
    raise exception 'Purchase bill % is already cancelled.', v_bill.bill_number
      using errcode = 'check_violation';
  end if;

  -- A draft never reached the ledger, so there is nothing to reverse. Deleting
  -- it releases its chassis back to the unbilled list.
  if v_bill.status = 'DRAFT' then
    delete from public.purchase_bills where id = p_bill_id;
    return null;
  end if;

  -- Posted: reverse the journal and take the stock back out again.
  -- TDS already deposited against this bill cannot simply vanish (0093).
  if exists (select 1 from public.tds_deductions
              where purchase_bill_id = p_bill_id and status = 'POSTED' and remittance_id is not null) then
    raise exception 'The TDS on bill % has been deposited. Record a debit note for the goods instead of cancelling the bill.',
      v_bill.bill_number using errcode = 'check_violation';
  end if;

  v_entry := app.reverse_journal(v_bill.journal_entry_id, btrim(p_reason), current_date);

  update public.tds_deductions set status = 'CANCELLED' where purchase_bill_id = p_bill_id;

  for v_line in
    select * from public.purchase_bill_lines
     where purchase_bill_id = p_bill_id and line_type in ('ACCESSORY', 'SPARE')
       -- A line that billed a goods receipt brought no stock in; the goods stay.
       and grn_line_id is null
  loop
    insert into public.inventory_transactions
      (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
       reference_type, reference_id, reference_number, narration, reason, created_by)
    values
      (v_bill.dealer_id, v_bill.branch_id, v_line.item_id, v_line.source, 'REVERSAL',
       -v_line.quantity, round(v_line.taxable_value / v_line.quantity, 4),
       'PURCHASE_BILL', p_bill_id, v_bill.bill_number,
       'Cancelled ' || v_bill.bill_number, btrim(p_reason), auth.uid());
  end loop;

  update public.purchase_bills
     set status = 'CANCELLED', updated_by = auth.uid(),
         notes = coalesce(notes || E'\n', '') || 'Cancelled: ' || btrim(p_reason)
   where id = p_bill_id;

  return v_entry;
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Remittance — recording a deposit already made
-- -----------------------------------------------------------------------------
create or replace function public.record_tds_remittance(
  p_bank_account_id uuid,
  p_deposit_date    date,
  p_challan_number  text,
  p_bsr_code        text,
  p_deduction_ids   uuid[],
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_id     uuid;
  v_total  numeric(18, 2);
  v_count  integer;
  v_bad    integer;
  v_acc    uuid;
  v_bank   record;
begin
  if v_dealer is null or not app.has_permission('accounting.tds.manage') then
    raise exception 'You may not record TDS deposits.' using errcode = 'insufficient_privilege';
  end if;
  if p_idempotency_key is not null then
    select id into v_id from public.tds_remittances where dealer_id = v_dealer and idempotency_key = p_idempotency_key;
    if v_id is not null then return v_id; end if;
  end if;
  if coalesce(array_length(p_deduction_ids, 1), 0) = 0 then
    raise exception 'Choose the deductions this deposit covers.' using errcode = 'check_violation';
  end if;
  if p_deposit_date > current_date then
    raise exception 'A deposit is recorded once it has been made, not in advance.' using errcode = 'check_violation';
  end if;

  -- Lock the deductions first, so two deposits cannot claim the same one.
  perform 1 from public.tds_deductions where dealer_id = v_dealer and id = any (p_deduction_ids) for update;
  select count(*), coalesce(sum(amount), 0),
         count(*) filter (where status <> 'POSTED' or remittance_id is not null or amount = 0)
    into v_count, v_total, v_bad
    from public.tds_deductions
   where dealer_id = v_dealer and id = any (p_deduction_ids);
  if v_count <> array_length(p_deduction_ids, 1) then
    raise exception 'A chosen deduction was not found.' using errcode = 'no_data_found';
  end if;
  if v_bad > 0 then
    raise exception 'A chosen deduction is cancelled, nil, or already deposited.' using errcode = 'check_violation';
  end if;

  v_acc := app.require_account(v_dealer, 'INVENTORY', 'PURCHASE', 'TDS_PAYABLE', null);
  select * into v_bank from public.record_bank_transaction(
    p_bank_account_id, 'PAYMENT', v_total,
    'TDS deposited — challan ' || btrim(p_challan_number) || ', BSR ' || btrim(p_bsr_code),
    v_acc, p_deposit_date, btrim(p_challan_number), null, btrim(p_bsr_code), null, null,
    case when p_idempotency_key is null then null else 'tds:' || p_idempotency_key end);

  insert into public.tds_remittances
    (dealer_id, bank_account_id, deposit_date, challan_number, bsr_code, amount,
     bank_transaction_id, journal_entry_id, idempotency_key, created_by)
  values
    (v_dealer, p_bank_account_id, p_deposit_date, btrim(p_challan_number), btrim(p_bsr_code), v_total,
     v_bank.transaction_id, v_bank.journal_entry_id, p_idempotency_key, auth.uid())
  returning id into v_id;

  update public.tds_deductions set remittance_id = v_id where id = any (p_deduction_ids);
  return v_id;
end;
$$;

comment on function public.record_tds_remittance(uuid, date, text, text, uuid[], text) is
  'Records a TDS deposit already made at the bank (F67): Dr 2745 Cr Bank through '
  'the bank book, and marks the deductions deposited. Makes no payment; files nothing.';

-- -----------------------------------------------------------------------------
-- 7. Reports
-- -----------------------------------------------------------------------------
create or replace function public.tds_register(p_from date, p_to date)
returns table (
  deduction_id    uuid,
  bill_date       date,
  bill_number     text,
  supplier_name   text,
  pan             text,
  payee_type      text,
  section_code    text,
  act             text,
  section_ref     text,
  base            numeric(18, 2),
  deductible_base numeric(18, 2),
  rate            numeric(6, 3),
  rate_basis      text,
  amount          numeric(18, 2),
  status          text,
  challan_number  text,
  bsr_code        text,
  deposit_date    date
)
language sql
stable
as $$
  select d.id, d.bill_date, b.bill_number, s.name, s.pan, s.tds_payee_type, d.section_code, d.act, d.section_ref,
         d.base, d.deductible_base, d.rate, d.rate_basis, d.amount, d.status,
         r.challan_number, r.bsr_code, r.deposit_date
    from public.tds_deductions d
    join public.purchase_bills b on b.id = d.purchase_bill_id
    join public.suppliers s on s.id = d.supplier_id
    left join public.tds_remittances r on r.id = d.remittance_id
   where d.dealer_id = app.current_dealer_id()
     and d.bill_date between p_from and p_to
   order by d.bill_date, b.bill_number;
$$;

-- 2745 against its subledger: they must agree.
create or replace function public.tds_control_check(p_as_on date default current_date)
returns table (ledger_balance numeric(18, 2), unremitted numeric(18, 2), difference numeric(18, 2))
language sql
stable
as $$
  with led as (
    select coalesce(sum(l.credit - l.debit), 0) as bal
      from public.journal_entry_lines l
      join public.journal_entries je on je.id = l.journal_entry_id
     where je.dealer_id = app.current_dealer_id()
       and je.status in ('POSTED', 'REVERSED') and je.entry_date <= p_as_on
       and l.account_id = app.require_account(app.current_dealer_id(), 'INVENTORY', 'PURCHASE', 'TDS_PAYABLE', null)
  ),
  sub as (
    select coalesce(sum(d.amount), 0) as open
      from public.tds_deductions d
      left join public.tds_remittances r on r.id = d.remittance_id
     where d.dealer_id = app.current_dealer_id() and d.status = 'POSTED' and d.bill_date <= p_as_on
       and (r.id is null or r.deposit_date > p_as_on)
  )
  select led.bal::numeric(18, 2), sub.open::numeric(18, 2), (led.bal - sub.open)::numeric(18, 2) from led, sub;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert, update on public.tds_deductor, public.tds_sections to authenticated';
    execute 'grant select, insert, update on public.tds_deductions to authenticated';
    execute 'grant select, insert on public.tds_remittances to authenticated';
    execute 'grant execute on function public.review_tds_section(uuid) to authenticated';
    execute 'grant execute on function public.end_tds_section(uuid, date) to authenticated';
    execute 'grant execute on function app.tds_compute(uuid) to authenticated';
    execute 'grant execute on function public.tds_preview(uuid) to authenticated';
    execute 'grant execute on function public.record_tds_remittance(uuid, date, text, text, uuid[], text) to authenticated';
    execute 'grant execute on function public.tds_register(date, date) to authenticated';
    execute 'grant execute on function public.tds_control_check(date) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant all on public.tds_deductor, public.tds_sections, public.tds_deductions, public.tds_remittances to service_role';
  end if;
end $$;

insert into public.schema_migrations (version, name)
values ('0093', 'tds') on conflict (version) do nothing;


-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0094_units_conversions_item_groups.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0094 — Units, pack conversion, item groups
-- =============================================================================
-- BUSY requirements F14, F15, F18 (docs/accounting-feature-gap-analysis.md).
--
-- F15  Units were a fixed check list on inventory_items.uom. They become a
--      master, each with its decimal places and the GST unit quantity code
--      (UQC) returns report it under; the item's uom now references it.
-- F18  An item is stocked in one unit and bought in others: "1 BOX = 12 NOS".
--      item_unit_conversions holds the factor per item. A purchase order line
--      entered in packs is stored in the base unit — quantity × factor, rate
--      ÷ factor — with what was entered kept beside it, so stock, receipts and
--      bills never deal in two units.
-- F14  Item groups: a managed, optionally nested list. The free-text category
--      stays; each distinct category becomes a group and items are linked.
--
-- Rollback: drop item_unit_conversions, item_groups, the new columns and the
--           units foreign key; restore inventory_items_uom_check and 0092's
--           create_purchase_order.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Units
-- -----------------------------------------------------------------------------
create table public.units (
  code      text primary key,
  name      text not null,
  decimals  smallint not null default 0,
  gst_uqc   text not null,
  constraint units_code_check check (code ~ '^[A-Z]{2,8}$'),
  constraint units_decimals_check check (decimals between 0 and 3),
  constraint units_uqc_check check (gst_uqc ~ '^[A-Z]{3}$')
);

comment on table public.units is
  'Units of measure (F15) with their decimal places and GST unit quantity code. Shared by every dealer.';

insert into public.units (code, name, decimals, gst_uqc) values
  ('NOS',  'Numbers',   0, 'NOS'),
  ('PCS',  'Pieces',    0, 'PCS'),
  ('SET',  'Sets',      0, 'SET'),
  ('PAIR', 'Pairs',     0, 'PRS'),
  ('BOX',  'Boxes',     0, 'BOX'),
  ('DOZ',  'Dozens',    0, 'DOZ'),
  ('LTR',  'Litres',    3, 'LTR'),
  ('KG',   'Kilograms', 3, 'KGS'),
  ('MTR',  'Metres',    3, 'MTR')
on conflict (code) do nothing;

alter table public.units enable row level security;
create policy units_select on public.units for select to authenticated using (true);
create policy units_write on public.units for all to authenticated
  using (app.is_platform_admin()) with check (app.is_platform_admin());

alter table public.inventory_items drop constraint inventory_items_uom_check;
alter table public.inventory_items
  add constraint inventory_items_uom_fkey foreign key (uom) references public.units (code);

-- -----------------------------------------------------------------------------
-- 2. Pack conversions
-- -----------------------------------------------------------------------------
create table public.item_unit_conversions (
  id         uuid primary key default gen_random_uuid(),
  dealer_id  uuid not null references public.dealers (id) on delete cascade,
  item_id    uuid not null,
  unit_code  text not null references public.units (code),
  factor     numeric(14, 4) not null,
  created_at timestamptz not null default now(),
  created_by uuid,

  constraint iuc_item_unit_key unique (item_id, unit_code),
  constraint iuc_item_tenant_fkey
    foreign key (item_id, dealer_id) references public.inventory_items (id, dealer_id) on delete cascade,
  constraint iuc_factor_check check (factor > 0)
);

comment on table public.item_unit_conversions is
  'How many base units one of this unit holds, per item (F18): 1 BOX = 12 NOS.';

-- The base unit itself is not a conversion.
create or replace function app.item_unit_conversions_guard()
returns trigger
language plpgsql
as $$
begin
  if new.unit_code = (select uom from public.inventory_items where id = new.item_id) then
    raise exception '% is this item''s own unit; a conversion is to another unit.', new.unit_code
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger item_unit_conversions_guard before insert or update on public.item_unit_conversions
  for each row execute function app.item_unit_conversions_guard();
create trigger item_unit_conversions_audit after insert or update or delete on public.item_unit_conversions
  for each row execute function app.audit_trigger();

alter table public.item_unit_conversions enable row level security;
create policy iuc_select on public.item_unit_conversions for select to authenticated
  using (app.is_platform_admin() or dealer_id = app.current_dealer_id());
create policy iuc_write on public.item_unit_conversions for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('inventory.items.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('inventory.items.manage')));

-- How many base units one p_unit of the item is: 1 for the base unit itself.
create or replace function app.unit_factor(p_item_id uuid, p_unit text)
returns numeric
language plpgsql
stable
as $$
declare
  v_base   text;
  v_factor numeric;
begin
  select uom into v_base from public.inventory_items where id = p_item_id;
  if p_unit is null or p_unit = v_base then
    return 1;
  end if;
  select factor into v_factor from public.item_unit_conversions where item_id = p_item_id and unit_code = p_unit;
  if v_factor is null then
    raise exception 'No conversion from % to % is set for this item.', p_unit, v_base
      using errcode = 'check_violation', hint = 'Add it on the item: how many ' || v_base || ' one ' || p_unit || ' holds.';
  end if;
  return v_factor;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. Item groups
-- -----------------------------------------------------------------------------
create table public.item_groups (
  id         uuid primary key default gen_random_uuid(),
  dealer_id  uuid not null references public.dealers (id) on delete cascade,
  name       text not null,
  parent_id  uuid,
  status     text not null default 'ACTIVE',
  created_at timestamptz not null default now(),
  created_by uuid,

  constraint item_groups_name_key unique (dealer_id, name),
  constraint item_groups_id_dealer_key unique (id, dealer_id),
  constraint item_groups_parent_tenant_fkey
    foreign key (parent_id, dealer_id) references public.item_groups (id, dealer_id),
  constraint item_groups_self_check check (parent_id is null or parent_id <> id),
  constraint item_groups_name_check check (length(btrim(name)) between 2 and 60),
  constraint item_groups_status_check check (status in ('ACTIVE', 'INACTIVE'))
);

comment on table public.item_groups is 'Groups of accessories and spares (F14), optionally nested.';

alter table public.inventory_items add column item_group_id uuid;
alter table public.inventory_items
  add constraint inventory_items_group_tenant_fkey
    foreign key (item_group_id, dealer_id) references public.item_groups (id, dealer_id);
create index inventory_items_group_idx on public.inventory_items (item_group_id) where item_group_id is not null;

create trigger item_groups_audit after insert or update or delete on public.item_groups
  for each row execute function app.audit_trigger();

alter table public.item_groups enable row level security;
create policy item_groups_select on public.item_groups for select to authenticated
  using (app.is_platform_admin() or dealer_id = app.current_dealer_id());
create policy item_groups_write on public.item_groups for all to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('inventory.items.manage')))
  with check (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('inventory.items.manage')));

-- Each distinct category becomes a group, and its items join it.
insert into public.item_groups (dealer_id, name)
select distinct dealer_id, btrim(category)
  from public.inventory_items
 where length(btrim(coalesce(category, ''))) between 2 and 60
on conflict (dealer_id, name) do nothing;

update public.inventory_items i
   set item_group_id = g.id
  from public.item_groups g
 where g.dealer_id = i.dealer_id and g.name = btrim(i.category) and i.item_group_id is null;

-- -----------------------------------------------------------------------------
-- 4. Purchase orders entered in packs
-- -----------------------------------------------------------------------------
alter table public.purchase_order_lines
  add column entry_unit     text references public.units (code),
  add column entry_quantity numeric(14, 3),
  add column entry_rate     numeric(18, 4),
  add column entry_factor   numeric(14, 4) not null default 1;

comment on column public.purchase_order_lines.entry_unit is
  'The unit the line was ordered in, when not the base unit; quantity and unit_rate are in the base unit.';

create or replace function public.create_purchase_order(
  p_branch_id       uuid,
  p_supplier_id     uuid,
  p_lines           jsonb,
  p_order_date      date default current_date,
  p_expected_date   date default null,
  p_notes           text default null,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_id     uuid;
  v_line   jsonb;
  v_item   public.inventory_items;
  v_n      integer := 0;
  v_unit   text;
  v_factor numeric;
  v_qty    numeric;
  v_rate   numeric;
begin
  if v_dealer is null or not app.has_permission('purchases.create') then
    raise exception 'You may not raise purchase orders.' using errcode = 'insufficient_privilege';
  end if;
  if p_idempotency_key is not null then
    select id into v_id from public.purchase_orders
     where dealer_id = v_dealer and idempotency_key = p_idempotency_key;
    if v_id is not null then return v_id; end if;
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Add at least one item to the order.' using errcode = 'check_violation';
  end if;

  insert into public.purchase_orders
    (dealer_id, branch_id, supplier_id, order_date, expected_date, notes, idempotency_key, created_by)
  values
    (v_dealer, p_branch_id, p_supplier_id, coalesce(p_order_date, current_date), p_expected_date,
     nullif(btrim(p_notes), ''), p_idempotency_key, auth.uid())
  returning id into v_id;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_n := v_n + 1;
    select * into v_item from public.inventory_items
     where id = nullif(v_line ->> 'item_id', '')::uuid and dealer_id = v_dealer;
    if v_item.id is null then
      raise exception 'Line %: choose the item.', v_n using errcode = 'check_violation';
    end if;
    -- Ordered in packs (0094): stored in the base unit, the entry kept beside it.
    v_unit := nullif(v_line ->> 'unit', '');
    v_factor := app.unit_factor(v_item.id, v_unit);
    v_qty := (v_line ->> 'quantity')::numeric;
    v_rate := coalesce((v_line ->> 'unit_rate')::numeric, 0);
    insert into public.purchase_order_lines
      (purchase_order_id, dealer_id, line_number, line_type, item_id, source, description,
       quantity, unit_rate, entry_unit, entry_quantity, entry_rate, entry_factor,
       cgst_rate, sgst_rate, igst_rate)
    values
      (v_id, v_dealer, v_n, v_item.item_type, v_item.id, coalesce(nullif(v_line ->> 'source', ''), 'COMPANY'),
       coalesce(nullif(btrim(v_line ->> 'description'), ''), v_item.name)
         || case when v_factor <> 1 then ' (' || v_qty || ' ' || v_unit || ' × ' || v_factor || ' ' || v_item.uom || ')' else '' end,
       round(v_qty * v_factor, 3), round(v_rate / v_factor, 4),
       case when v_factor <> 1 then v_unit end, case when v_factor <> 1 then v_qty end,
       case when v_factor <> 1 then v_rate end, v_factor,
       coalesce((v_line ->> 'cgst_rate')::numeric, 0), coalesce((v_line ->> 'sgst_rate')::numeric, 0),
       coalesce((v_line ->> 'igst_rate')::numeric, 0));
  end loop;

  return v_id;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select on public.units to authenticated';
    execute 'grant select, insert, update, delete on public.item_unit_conversions, public.item_groups to authenticated';
    execute 'grant execute on function app.unit_factor(uuid, text) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant all on public.units, public.item_unit_conversions, public.item_groups to service_role';
  end if;
end $$;

insert into public.schema_migrations (version, name)
values ('0094', 'units_conversions_item_groups') on conflict (version) do nothing;


commit;
