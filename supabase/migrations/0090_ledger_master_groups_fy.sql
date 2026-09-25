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
