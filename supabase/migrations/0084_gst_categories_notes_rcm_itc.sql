-- =============================================================================
-- 0084 — Tax categories, credit and debit notes, reverse charge, ITC categories
-- =============================================================================
-- Spec §16, §20, §21, §40, §41. Audit checklist §04 (tax setup), §05 (GST
-- documents), §08 (input tax).
--
-- ── Tax categories ─────────────────────────────────────────────────────────
--
-- A tax code carried a rate and nothing else, so a zero-rate line could be nil
-- rated, exempt, outside GST or simply unconfigured, and GSTR-3B table 3.1(c)/
-- (e) and table 5 need to know which. tax_codes.tax_category says; the three
-- non-taxable categories may not carry a rate. Sale and service lines keep the
-- code they were billed under (spec §16), so their category is read from the
-- code version in force on the invoice date; purchase lines record the
-- supplier's category directly, as they record the supplier's rate.
--
-- An invoice whose every line is non-taxable is a bill of supply (rule 49), not
-- a tax invoice; the printed document says so.
--
-- ── Credit and debit notes (s.34) ──────────────────────────────────────────
--
-- A price revision, a post-sale discount, a short supply: nothing recorded any
-- of these against the invoice they amend. gst_notes does, for both sides:
--
--   issued to a customer   CREDIT  income + output GST Dr / receivable Cr
--                          DEBIT   receivable Dr / income + output GST Cr
--   from a supplier        CREDIT  payable Dr / expense + input GST Cr
--                          DEBIT   expense + input GST Dr / payable Cr
--
-- Every note names the invoice or bill it amends, takes that document's tax
-- mode (IGST or CGST+SGST), and credit notes may not exceed what they amend.
-- A note is corrected by cancelling it, which reverses its journal.
--
-- ── Reverse charge ─────────────────────────────────────────────────────────
--
-- On a reverse-charge purchase (GTA freight, legal fees, an unregistered
-- landlord) the supplier's bill carries no tax and the dealer pays it instead:
--
--   Expense Dr  /  Input GST Dr (if claimable)  /  Supplier Cr (value only)
--                                              /  GST Payable (RCM) Cr
--
-- purchase_bill_lines.reverse_charge marks the line; the bill's header tax is
-- what the supplier charged, and reverse_charge_tax is what the dealer owes.
--
-- ── ITC categories ─────────────────────────────────────────────────────────
--
-- itc_eligible (0078) was a yes/no. itc_category records why: ELIGIBLE,
-- CAPITAL_GOODS, COMMON (claimed, then apportioned under rule 42), BLOCKED
-- (s.17(5)) or PERSONAL; itc_eligible follows from it. itc_adjustments records
-- reversals and re-claims — rule 37 (supplier unpaid after 180 days), rule 42/43
-- (common credit), s.17(5) — each posting ITC ⇄ 5990 Input Tax Credit Reversed,
-- and a re-claim can never exceed what was reversed. itc_rule37_candidates()
-- finds the bills a rule 37 reversal is due on.
--
-- Rollback: drop gst_notes, itc_adjustments and their functions; restore
--           post_purchase_bill (0078), purchase_bill_lines_sync_totals (0052),
--           gstr1_summary and gst_document_register (0034), gst_summary and
--           gst_input_summary (0078), app.seed_chart_of_accounts (rename
--           _0083 back); drop the columns added here.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Accounts, rules and category codes
-- -----------------------------------------------------------------------------
create or replace function app.seed_gst_compliance(p_dealer_id uuid)
returns integer
language plpgsql
as $$
declare
  v_added integer := 0;
  a       record;
begin
  for a in
    select * from (values
      ('2590', 'GST Payable — Reverse Charge',   'LIABILITY', '2000'),
      ('5990', 'Input Tax Credit Reversed',      'EXPENSE',   '5000')
    ) as t(code, name, account_type, parent_code)
  loop
    insert into public.chart_of_accounts
      (dealer_id, code, name, account_type, normal_balance, is_group, parent_id, is_system, is_branch_scoped)
    select p_dealer_id, a.code, a.name, a.account_type,
           case when a.account_type in ('ASSET', 'EXPENSE') then 'DEBIT' else 'CREDIT' end,
           false, p.id, true, false
      from public.chart_of_accounts p
     where p.dealer_id = p_dealer_id and p.code = a.parent_code and p.is_group
    on conflict on constraint coa_dealer_code_key do nothing;
    if found then v_added := v_added + 1; end if;
  end loop;

  insert into public.accounting_rules (dealer_id, module, event, component, side, account_id, description)
  select p_dealer_id, r.module, r.event, r.component, r.side, c.id, 'Default mapping'
    from (values
      ('INVENTORY', 'PURCHASE', 'RCM_PAYABLE', 'CREDIT', '2590'),
      ('EXPENSE',   'ITC',      'REVERSED',    'DEBIT',  '5990')
    ) as r(module, event, component, side, code)
    -- A dealer who already used the code for something else keeps it, and the
    -- rule is left unmapped: posting then says so instead of hitting the wrong account.
    join public.chart_of_accounts c on c.dealer_id = p_dealer_id and c.code = r.code
                                   and not c.is_group
                                   and c.account_type = case r.code when '2590' then 'LIABILITY' else 'EXPENSE' end
   where not exists (select 1 from public.accounting_rules x
                      where x.dealer_id = p_dealer_id and x.module = r.module
                        and x.event = r.event and x.component = r.component
                        and x.branch_id is null and x.status = 'ACTIVE');

  -- The three non-taxable categories, ready to put on an item or a line.
  insert into public.tax_codes
    (dealer_id, code, name, cgst_rate, sgst_rate, igst_rate, effective_from, tax_category)
  select p_dealer_id, t.code, t.name, 0, 0, 0, date '2017-07-01', t.category
    from (values
      ('NIL_RATED', 'Nil rated (0%)',          'NIL_RATED'),
      ('EXEMPT',    'Exempt supply',           'EXEMPT'),
      ('NON_GST',   'Non-GST supply',          'NON_GST')
    ) as t(code, name, category)
   where not exists (select 1 from public.tax_codes x
                      where x.dealer_id = p_dealer_id and x.code = t.code);

  return v_added;
end;
$$;

alter table public.tax_codes
  add column if not exists tax_category text not null default 'TAXABLE';
alter table public.tax_codes
  add constraint tax_codes_category_check
    check (tax_category in ('TAXABLE', 'ZERO_RATED', 'NIL_RATED', 'EXEMPT', 'NON_GST'));
-- Nil rated, exempt and non-GST supplies carry no tax, by definition.
alter table public.tax_codes
  add constraint tax_codes_category_rate_check
    check (tax_category in ('TAXABLE', 'ZERO_RATED')
           or (cgst_rate = 0 and sgst_rate = 0 and igst_rate = 0 and cess_rate = 0));

comment on column public.tax_codes.tax_category is
  'What GSTR-3B calls the supply: TAXABLE, ZERO_RATED (export/SEZ), NIL_RATED, '
  'EXEMPT or NON_GST. The last three carry no rate.';

do $$
declare d record;
begin
  for d in select id from public.dealers loop
    perform app.seed_gst_compliance(d.id);
  end loop;
end $$;

alter function app.seed_chart_of_accounts(uuid) rename to seed_chart_of_accounts_0083;

create or replace function app.seed_chart_of_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
begin
  return app.seed_chart_of_accounts_0083(p_dealer_id) + app.seed_gst_compliance(p_dealer_id);
end;
$$;

-- The category of a billed line: the code version in force on the invoice date.
-- A line with no code is TAXABLE if it was taxed and unclassified if not — an
-- untagged zero-rate line is a question for the accountant, not a guess.
create or replace function app.supply_category(
  p_dealer_id uuid, p_tax_code text, p_on date, p_tax numeric
)
returns text
language sql
stable
as $$
  select coalesce(
    (select t.tax_category from public.tax_codes t
      where t.dealer_id = p_dealer_id and t.code = p_tax_code
        and t.effective_from <= p_on and (t.effective_to is null or t.effective_to >= p_on)
      order by t.effective_from desc limit 1),
    case when coalesce(p_tax, 0) > 0 then 'TAXABLE' else 'UNCLASSIFIED' end);
$$;

-- -----------------------------------------------------------------------------
-- Purchase lines: category, reverse charge, ITC category
-- -----------------------------------------------------------------------------
alter table public.purchase_bill_lines
  add column if not exists tax_category   text not null default 'TAXABLE',
  add column if not exists reverse_charge boolean not null default false,
  add column if not exists itc_category   text not null default 'ELIGIBLE';

alter table public.purchase_bills
  add column if not exists reverse_charge_tax numeric(18, 4) not null default 0;

alter table public.purchase_bill_lines
  add constraint pbl_tax_category_check
    check (tax_category in ('TAXABLE', 'ZERO_RATED', 'NIL_RATED', 'EXEMPT', 'NON_GST')),
  add constraint pbl_tax_category_rate_check
    check (tax_category in ('TAXABLE', 'ZERO_RATED') or (cgst_amount = 0 and sgst_amount = 0 and igst_amount = 0)),
  add constraint pbl_itc_category_check
    check (itc_category in ('ELIGIBLE', 'CAPITAL_GOODS', 'COMMON', 'BLOCKED', 'PERSONAL')),
  -- Stock is always bought for business; the finer categories are for overheads.
  add constraint pbl_itc_category_scope_check
    check (itc_category = 'ELIGIBLE' or line_type = 'EXPENSE'),
  add constraint pbl_rcm_scope_check
    check (not reverse_charge or (line_type = 'EXPENSE' and tax_category = 'TAXABLE')),
  -- The supplier is owed the value alone; the tax is the dealer's to pay.
  add constraint pbl_rcm_total_check
    check (not reverse_charge or total_amount = taxable_value);

comment on column public.purchase_bill_lines.reverse_charge is
  'Tax payable by the dealer under s.9(3)/(4): the line''s tax is self-assessed, '
  'credited to GST Payable (RCM) and not owed to the supplier.';
comment on column public.purchase_bill_lines.itc_category is
  'Why the input tax is or is not claimed. ELIGIBLE, CAPITAL_GOODS and COMMON are '
  'claimed (COMMON is then apportioned); BLOCKED (s.17(5)) and PERSONAL are cost.';

-- A personal purchase paid by the business is the owner's drawing: it may be
-- charged to an equity account. Otherwise as 0078.
create or replace function app.purchase_bill_lines_account_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_acc public.chart_of_accounts;
begin
  if new.line_type <> 'EXPENSE' then
    return new;
  end if;

  select * into v_acc from public.chart_of_accounts
   where id = new.account_id and dealer_id = new.dealer_id;

  if v_acc.id is null then
    raise exception 'The account on this line is not in your chart of accounts.'
      using errcode = 'foreign_key_violation';
  end if;
  if v_acc.is_group or v_acc.status <> 'ACTIVE' then
    raise exception 'Account % % cannot be charged: it is a heading or inactive.', v_acc.code, v_acc.name
      using errcode = 'check_violation';
  end if;
  if not (v_acc.account_type in ('EXPENSE', 'ASSET')
          or (v_acc.account_type = 'EQUITY' and new.itc_category = 'PERSONAL')) then
    raise exception 'A purchase is charged to an expense or an asset (or, if personal, to drawings); % % is %.',
      v_acc.code, v_acc.name, lower(v_acc.account_type)
      using errcode = 'check_violation';
  end if;
  if app.is_money_ledger(new.dealer_id, new.account_id) then
    raise exception 'Account % % is cash or bank, not something bought.', v_acc.code, v_acc.name
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.accounting_rules r
              where r.dealer_id = new.dealer_id and r.account_id = new.account_id
                and r.module = 'INVENTORY' and r.event = 'PURCHASE'
                and r.status = 'ACTIVE') then
    raise exception 'Account % % is posted by stock lines and tax, not charged directly. Use a vehicle, accessory or spare line.',
      v_acc.code, v_acc.name using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

-- itc_eligible follows the category. A caller that still sends only the 0078
-- flag (false) gets BLOCKED, which is what false meant there.
create or replace function app.purchase_line_itc_category()
returns trigger
language plpgsql
as $$
begin
  if new.itc_category = 'ELIGIBLE' and not new.itc_eligible then
    new.itc_category := 'BLOCKED';
  end if;
  new.itc_eligible := new.itc_category in ('ELIGIBLE', 'CAPITAL_GOODS', 'COMMON');
  -- A reverse-charge line's total is its value alone; pbl_rcm_total_check
  -- refuses anything else rather than this trigger quietly rewriting it.
  return new;
end;
$$;

create trigger purchase_bill_lines_itc_category
  before insert or update on public.purchase_bill_lines
  for each row execute function app.purchase_line_itc_category();

-- The header's tax is what the supplier charged; reverse-charge tax is shown
-- beside it, so taxable + tax = total still holds on every bill.
create or replace function app.purchase_bill_lines_sync_totals()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_bill   uuid := coalesce(new.purchase_bill_id, old.purchase_bill_id);
  v_status text;
  v_number text;
begin
  select status, bill_number into v_status, v_number
    from public.purchase_bills where id = v_bill;

  if v_status is null then
    return coalesce(new, old);
  end if;

  if v_status <> 'DRAFT' then
    raise exception 'Cannot % lines of purchase bill %: it is %.',
      lower(tg_op), v_number, v_status
      using errcode = 'insufficient_privilege';
  end if;

  update public.purchase_bills b
     set taxable_value      = coalesce(t.taxable, 0),
         cgst_amount        = coalesce(t.cgst, 0),
         sgst_amount        = coalesce(t.sgst, 0),
         igst_amount        = coalesce(t.igst, 0),
         reverse_charge_tax = coalesce(t.rcm, 0),
         total_amount       = coalesce(t.total, 0)
    from (
      select sum(l.taxable_value) as taxable,
             sum(l.cgst_amount) filter (where not l.reverse_charge) as cgst,
             sum(l.sgst_amount) filter (where not l.reverse_charge) as sgst,
             sum(l.igst_amount) filter (where not l.reverse_charge) as igst,
             sum(l.cgst_amount + l.sgst_amount + l.igst_amount) filter (where l.reverse_charge) as rcm,
             sum(l.total_amount) as total
        from public.purchase_bill_lines l
       where l.purchase_bill_id = v_bill
    ) t
   where b.id = v_bill;

  return coalesce(new, old);
end;
$$;

-- -----------------------------------------------------------------------------
-- public.post_purchase_bill() — reverse charge
-- -----------------------------------------------------------------------------
-- As 0078, plus: the tax on reverse-charge lines is credited to GST Payable
-- (RCM) rather than owed to the supplier, and claimed as input tax when the
-- line's credit is claimable.
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

-- -----------------------------------------------------------------------------
-- Permissions
-- -----------------------------------------------------------------------------
insert into public.permissions (code, module, description, is_sensitive) values
  ('gst.notes.manage', 'gst', 'Issue and cancel credit and debit notes', false),
  ('gst.itc.manage',   'gst', 'Reverse and re-claim input tax credit', false)
on conflict (code) do update set module = excluded.module, description = excluded.description,
                                 is_sensitive = excluded.is_sensitive;

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join (values ('gst.notes.manage'), ('gst.itc.manage')) as p(code)
 where r.is_system and r.code in ('DEALER_OWNER', 'ACCOUNTS')
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- gst_notes — credit and debit notes against an invoice or a bill (s.34)
-- -----------------------------------------------------------------------------
create table public.gst_notes (
  id                       uuid primary key default gen_random_uuid(),
  dealer_id                uuid not null references public.dealers (id) on delete restrict,
  branch_id                uuid not null,
  note_number              text not null,
  note_type                text not null,
  party_type               text not null,
  customer_id              uuid,
  supplier_id              uuid,
  -- For a supplier's note: the number on their document.
  party_note_number        text,
  original_document_type   text not null,
  original_document_id     uuid not null,
  original_document_number text not null,
  original_document_date   date not null,
  note_date                date not null,
  reason                   text not null,
  description              text not null,
  account_id               uuid not null,
  hsn_sac                  text,
  gst_rate                 numeric(6, 3) not null default 0,
  taxable_value            numeric(18, 4) not null,
  cgst_amount              numeric(18, 4) not null default 0,
  sgst_amount              numeric(18, 4) not null default 0,
  igst_amount              numeric(18, 4) not null default 0,
  total_amount             numeric(18, 4) not null,
  itc_eligible             boolean not null default true,
  status                   text not null default 'POSTED',
  journal_entry_id         uuid,
  cancel_journal_id        uuid,
  cancel_reason            text,
  idempotency_key          text,
  created_by               uuid,
  created_at               timestamptz not null default now(),

  constraint gst_notes_number_key unique (dealer_id, note_number),
  constraint gst_notes_idempotency_key unique (dealer_id, idempotency_key),
  constraint gst_notes_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint gst_notes_customer_tenant_fkey
    foreign key (customer_id, dealer_id) references public.customers (id, dealer_id),
  constraint gst_notes_supplier_tenant_fkey
    foreign key (supplier_id, dealer_id) references public.suppliers (id, dealer_id),
  constraint gst_notes_account_tenant_fkey
    foreign key (account_id, dealer_id) references public.chart_of_accounts (id, dealer_id),
  constraint gst_notes_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint gst_notes_type_check   check (note_type in ('CREDIT', 'DEBIT')),
  constraint gst_notes_party_check  check (
    (party_type = 'CUSTOMER' and customer_id is not null and supplier_id is null
       and original_document_type in ('SALE', 'SERVICE_INVOICE'))
    or (party_type = 'SUPPLIER' and supplier_id is not null and customer_id is null
       and original_document_type = 'PURCHASE_BILL')
  ),
  constraint gst_notes_reason_check check (reason in (
    'PRICE_REVISION', 'DISCOUNT', 'SHORT_SUPPLY', 'DEFICIENCY', 'RATE_CORRECTION', 'OTHER')),
  constraint gst_notes_status_check check (status in ('POSTED', 'CANCELLED')),
  constraint gst_notes_amounts_check check (
    taxable_value > 0 and cgst_amount >= 0 and sgst_amount >= 0 and igst_amount >= 0
    and total_amount = taxable_value + cgst_amount + sgst_amount + igst_amount),
  constraint gst_notes_tax_split_check check (igst_amount = 0 or (cgst_amount = 0 and sgst_amount = 0)),
  constraint gst_notes_hsn_check check (hsn_sac is null or hsn_sac ~ '^[0-9]{4,8}$'),
  constraint gst_notes_cancel_check check (
    status <> 'CANCELLED' or (cancel_journal_id is not null and cancel_reason is not null))
);

comment on table public.gst_notes is
  'Credit and debit notes (s.34, spec §40): issued to customers against a sale or '
  'service invoice, or received from suppliers against a purchase bill. Posted '
  'on issue; corrected only by cancellation, which reverses the journal.';

create index gst_notes_original_idx on public.gst_notes (original_document_id);
create index gst_notes_dealer_date_idx on public.gst_notes (dealer_id, note_date desc);

-- A note is a posted document: after issue only its journal link (once) and its
-- cancellation (once) may be written.
create or replace function app.gst_notes_guard()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'A credit or debit note cannot be deleted; cancel it.'
      using errcode = 'insufficient_privilege';
  end if;
  if (new.id, new.dealer_id, new.branch_id, new.note_number, new.note_type, new.party_type,
      new.original_document_id, new.note_date, new.taxable_value, new.cgst_amount,
      new.sgst_amount, new.igst_amount, new.account_id)
     is distinct from
     (old.id, old.dealer_id, old.branch_id, old.note_number, old.note_type, old.party_type,
      old.original_document_id, old.note_date, old.taxable_value, old.cgst_amount,
      old.sgst_amount, old.igst_amount, old.account_id) then
    raise exception 'Note % is posted and cannot be edited; cancel it and issue another.', old.note_number
      using errcode = 'insufficient_privilege';
  end if;
  if old.journal_entry_id is not null and new.journal_entry_id is distinct from old.journal_entry_id then
    raise exception 'The journal of note % cannot be changed.', old.note_number
      using errcode = 'insufficient_privilege';
  end if;
  if old.status = 'CANCELLED' then
    raise exception 'Note % is already cancelled.', old.note_number
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger gst_notes_guard
  before update or delete on public.gst_notes
  for each row execute function app.gst_notes_guard();

create trigger gst_notes_audit after insert or update on public.gst_notes
  for each row execute function app.audit_trigger();

alter table public.gst_notes enable row level security;

create policy gst_notes_select on public.gst_notes for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('gst.reports.view') or app.has_permission('gst.notes.manage'))));
create policy gst_notes_insert on public.gst_notes for insert to authenticated
  with check (dealer_id = app.current_dealer_id() and app.has_permission('gst.notes.manage'));
create policy gst_notes_update on public.gst_notes for update to authenticated
  using (dealer_id = app.current_dealer_id() and app.has_permission('gst.notes.manage'))
  with check (dealer_id = app.current_dealer_id() and app.has_permission('gst.notes.manage'));

-- -----------------------------------------------------------------------------
-- public.issue_gst_note()
-- -----------------------------------------------------------------------------
create or replace function public.issue_gst_note(
  p_note_type          text,
  p_original_type      text,
  p_original_id        uuid,
  p_taxable_value      numeric,
  p_gst_rate           numeric,
  p_account_id         uuid,
  p_reason             text,
  p_description        text,
  p_note_date          date default current_date,
  p_party_note_number  text default null,
  p_itc_eligible       boolean default true,
  p_hsn_sac            text default null,
  p_idempotency_key    text default null
)
returns uuid
language plpgsql
as $$
declare
  v_dealer   uuid := app.current_dealer_id();
  v_existing uuid;
  v_branch   uuid;
  v_customer uuid;
  v_supplier uuid;
  v_number   text;
  v_date     date;
  v_taxable  numeric;
  v_inter    boolean;
  v_credited numeric;
  v_acc      public.chart_of_accounts;
  v_party    text;
  v_module   text;
  v_value    numeric := round(p_taxable_value, 2);
  v_cgst     numeric := 0;
  v_sgst     numeric := 0;
  v_igst     numeric := 0;
  v_tax      numeric;
  v_doc_type text;
  v_prefix   text;
  v_year     text;
  v_note     public.gst_notes;
  v_lines    jsonb := '[]'::jsonb;
  v_entry    uuid;
  v_hsn      text := nullif(btrim(coalesce(p_hsn_sac, '')), '');
  v_tax_acc  text;
begin
  if v_dealer is null or not app.has_permission('gst.notes.manage') then
    raise exception 'You do not have permission to issue credit or debit notes.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_idempotency_key is not null then
    select id into v_existing from public.gst_notes
     where dealer_id = v_dealer and idempotency_key = p_idempotency_key;
    if v_existing is not null then
      return v_existing;
    end if;
  end if;
  if p_note_type not in ('CREDIT', 'DEBIT') then
    raise exception 'A note is a credit note or a debit note.' using errcode = 'check_violation';
  end if;
  if not (v_value > 0) then
    raise exception 'Enter the value of the note.' using errcode = 'check_violation';
  end if;
  if p_gst_rate is null or p_gst_rate < 0 or p_gst_rate > 40 then
    raise exception 'Enter the GST rate of the original supply.' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_description), '') = '' then
    raise exception 'Say what the note is for.' using errcode = 'check_violation';
  end if;

  -- ── The document it amends ───────────────────────────────────────────────
  if p_original_type = 'SALE' then
    select s.branch_id, s.customer_id, s.invoice_number, s.invoice_date, s.taxable_value,
           s.igst_amount > 0 or (s.cgst_amount = 0 and s.place_of_supply is not null
                                 and s.place_of_supply <> b.state_code)
      into v_branch, v_customer, v_number, v_date, v_taxable, v_inter
      from public.sales s join public.branches b on b.id = s.branch_id
     where s.id = p_original_id and s.dealer_id = v_dealer and s.status in ('POSTED', 'DELIVERED');
    v_party := 'CUSTOMER'; v_module := 'SALES';
  elsif p_original_type = 'SERVICE_INVOICE' then
    select si.branch_id, si.customer_id, si.invoice_number, si.invoice_date, si.taxable_value,
           si.igst_amount > 0 or (si.cgst_amount = 0 and si.place_of_supply is not null
                                  and si.place_of_supply <> b.state_code)
      into v_branch, v_customer, v_number, v_date, v_taxable, v_inter
      from public.service_invoices si join public.branches b on b.id = si.branch_id
     where si.id = p_original_id and si.dealer_id = v_dealer and si.status = 'POSTED';
    v_party := 'CUSTOMER'; v_module := 'SERVICE';
  elsif p_original_type = 'PURCHASE_BILL' then
    select pb.branch_id, pb.supplier_id, pb.bill_number, pb.bill_date, pb.taxable_value,
           exists (select 1 from public.purchase_bill_lines l
                    where l.purchase_bill_id = pb.id and l.igst_amount > 0)
      into v_branch, v_supplier, v_number, v_date, v_taxable, v_inter
      from public.purchase_bills pb
     where pb.id = p_original_id and pb.dealer_id = v_dealer and pb.status = 'POSTED';
    v_party := 'SUPPLIER'; v_module := 'INVENTORY';
  else
    raise exception 'A note amends a sale, a service invoice or a purchase bill.'
      using errcode = 'check_violation';
  end if;

  if v_number is null then
    raise exception 'The document this note amends was not found, or is not posted.'
      using errcode = 'no_data_found';
  end if;
  if v_party = 'CUSTOMER' and v_customer is null then
    raise exception 'Invoice % has no customer; a note needs someone to issue it to.', v_number
      using errcode = 'check_violation';
  end if;
  if p_note_date < v_date then
    raise exception 'A note cannot be dated before the document it amends (%).', to_char(v_date, 'DD-MM-YYYY')
      using errcode = 'check_violation';
  end if;
  if p_note_date > current_date then
    raise exception 'A note cannot be dated in the future.' using errcode = 'check_violation';
  end if;
  if not app.can_access_branch(v_branch) then
    raise exception 'You do not have access to the branch that issued %.', v_number
      using errcode = 'insufficient_privilege';
  end if;

  -- Credit notes cannot take back more than was supplied.
  if p_note_type = 'CREDIT' then
    select coalesce(sum(taxable_value), 0) into v_credited
      from public.gst_notes
     where original_document_id = p_original_id and note_type = 'CREDIT' and status = 'POSTED';
    if v_credited + v_value > v_taxable then
      raise exception 'Credit notes on % would come to % against a taxable value of %.',
        v_number, v_credited + v_value, v_taxable using errcode = 'check_violation';
    end if;
  end if;

  -- ── The account the value goes to ────────────────────────────────────────
  select * into v_acc from public.chart_of_accounts where id = p_account_id and dealer_id = v_dealer;
  if v_acc.id is null or v_acc.is_group or v_acc.status <> 'ACTIVE' then
    raise exception 'Choose an active account from your chart of accounts.' using errcode = 'check_violation';
  end if;
  if (v_party = 'CUSTOMER' and v_acc.account_type not in ('INCOME', 'EXPENSE'))
     or (v_party = 'SUPPLIER' and v_acc.account_type not in ('EXPENSE', 'ASSET', 'INCOME'))
     or app.is_money_ledger(v_dealer, v_acc.id) then
    raise exception 'Account % % cannot carry the value of this note.', v_acc.code, v_acc.name
      using errcode = 'check_violation';
  end if;

  -- ── Tax, in the original's mode ──────────────────────────────────────────
  if v_inter then
    v_igst := round(v_value * p_gst_rate / 100, 2);
  else
    v_cgst := round(v_value * p_gst_rate / 200, 2);
    v_sgst := round(v_value * p_gst_rate / 200, 2);
  end if;
  v_tax := v_cgst + v_sgst + v_igst;

  if v_hsn is null and v_party = 'CUSTOMER' then
    select l.hsn_code into v_hsn from (
      select hsn_code, line_number from public.sale_lines where sale_id = p_original_id and hsn_code is not null
      union all
      select hsn_code, line_number from public.service_lines where invoice_id = p_original_id and hsn_code is not null
    ) l order by l.line_number limit 1;
  end if;

  -- ── Number ───────────────────────────────────────────────────────────────
  v_doc_type := case when v_party = 'CUSTOMER' then p_note_type || '_NOTE'
                     else 'SUPPLIER_' || p_note_type || '_NOTE' end;
  v_prefix := case v_doc_type when 'CREDIT_NOTE' then 'CN' when 'DEBIT_NOTE' then 'DBN'
                              when 'SUPPLIER_CREDIT_NOTE' then 'SCN' else 'SDN' end;
  v_year := app.financial_year_token(v_dealer, p_note_date);
  insert into public.document_sequences (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
  values (v_dealer, null, v_doc_type, v_year, v_prefix, 6)
  on conflict on constraint document_sequences_scope_key do nothing;

  insert into public.gst_notes
    (dealer_id, branch_id, note_number, note_type, party_type, customer_id, supplier_id,
     party_note_number, original_document_type, original_document_id, original_document_number,
     original_document_date, note_date, reason, description, account_id, hsn_sac, gst_rate,
     taxable_value, cgst_amount, sgst_amount, igst_amount, total_amount, itc_eligible,
     idempotency_key, created_by)
  values
    (v_dealer, v_branch, app.next_document_number(v_dealer, null, v_doc_type, v_year),
     p_note_type, v_party, v_customer, v_supplier,
     nullif(btrim(coalesce(p_party_note_number, '')), ''), p_original_type, p_original_id, v_number,
     v_date, p_note_date, coalesce(p_reason, 'OTHER'), btrim(p_description), p_account_id, v_hsn,
     p_gst_rate, v_value, v_cgst, v_sgst, v_igst, v_value + v_tax,
     case when v_party = 'SUPPLIER' then coalesce(p_itc_eligible, true) else true end,
     p_idempotency_key, auth.uid())
  returning * into v_note;

  -- ── Journal ──────────────────────────────────────────────────────────────
  -- Built as the entry that increases the party's balance (a debit note); a
  -- credit note is the same lines with the sides swapped.
  if v_party = 'CUSTOMER' then
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', app.require_account(v_dealer, v_module, 'INVOICE', 'RECEIVABLE', v_branch),
        'debit', v_note.total_amount, 'credit', 0, 'narration', v_note.note_number || ' on ' || v_number,
        'party_type', 'CUSTOMER', 'party_id', v_customer),
      jsonb_build_object('account_id', p_account_id, 'debit', 0, 'credit', v_value,
        'narration', v_note.description));
    foreach v_tax_acc in array array['CGST', 'SGST', 'IGST'] loop
      if (case v_tax_acc when 'CGST' then v_cgst when 'SGST' then v_sgst else v_igst end) > 0 then
        v_lines := v_lines || jsonb_build_object(
          'account_id', app.require_account(v_dealer, v_module, 'INVOICE', v_tax_acc, v_branch),
          'debit', 0, 'credit', case v_tax_acc when 'CGST' then v_cgst when 'SGST' then v_sgst else v_igst end,
          'narration', 'Output ' || v_tax_acc || ' ' || v_note.note_number);
      end if;
    end loop;
  else
    -- A supplier's debit note: more cost, more input tax, more owed.
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', p_account_id, 'debit',
        v_value + case when v_note.itc_eligible then 0 else v_tax end, 'credit', 0,
        'narration', v_note.description),
      jsonb_build_object('account_id', app.require_account(v_dealer, 'INVENTORY', 'PURCHASE', 'PAYABLE', v_branch),
        'debit', 0, 'credit', v_note.total_amount,
        'narration', v_note.note_number || ' on ' || v_number,
        'party_type', 'SUPPLIER', 'party_id', v_supplier));
    if v_note.itc_eligible then
      foreach v_tax_acc in array array['CGST', 'SGST', 'IGST'] loop
        if (case v_tax_acc when 'CGST' then v_cgst when 'SGST' then v_sgst else v_igst end) > 0 then
          v_lines := v_lines || jsonb_build_object(
            'account_id', app.require_account(v_dealer, 'INVENTORY', 'PURCHASE', 'INPUT_' || v_tax_acc, v_branch),
            'debit', case v_tax_acc when 'CGST' then v_cgst when 'SGST' then v_sgst else v_igst end, 'credit', 0,
            'narration', 'Input ' || v_tax_acc || ' ' || v_note.note_number);
        end if;
      end loop;
    end if;
  end if;

  if p_note_type = 'CREDIT' then
    select jsonb_agg(l || jsonb_build_object('debit', l->'credit', 'credit', l->'debit'))
      into v_lines from jsonb_array_elements(v_lines) l;
  end if;

  v_entry := app.post_journal(
    v_dealer, v_branch, p_note_date, v_module,
    initcap(lower(p_note_type)) || ' note ' || v_note.note_number || ' on ' || v_number,
    v_lines, 'GST_NOTE', v_note.id, 'gst-note:' || v_note.id::text);

  update public.gst_notes set journal_entry_id = v_entry where id = v_note.id;
  return v_note.id;
end;
$$;

comment on function public.issue_gst_note(text, text, uuid, numeric, numeric, uuid, text, text, date, text, boolean, text, text) is
  'Issues (to a customer) or records (from a supplier) a credit or debit note '
  'against a posted document, in that document''s tax mode, and posts it. '
  'Credit notes cannot exceed the original taxable value. Idempotent.';

create or replace function public.cancel_gst_note(p_note_id uuid, p_reason text)
returns uuid
language plpgsql
as $$
declare
  v_note  public.gst_notes;
  v_entry uuid;
begin
  if not app.has_permission('gst.notes.manage') then
    raise exception 'You do not have permission to cancel notes.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_note from public.gst_notes
   where id = p_note_id and dealer_id = app.current_dealer_id() for update;
  if v_note.id is null then
    raise exception 'Note not found.' using errcode = 'no_data_found';
  end if;
  if v_note.status = 'CANCELLED' then
    return v_note.cancel_journal_id;
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why the note is being cancelled.' using errcode = 'check_violation';
  end if;

  v_entry := app.reverse_journal(v_note.journal_entry_id, 'Cancelled ' || v_note.note_number || ': ' || btrim(p_reason), current_date);
  update public.gst_notes
     set status = 'CANCELLED', cancel_journal_id = v_entry, cancel_reason = btrim(p_reason)
   where id = p_note_id;
  return v_entry;
end;
$$;

-- -----------------------------------------------------------------------------
-- itc_adjustments — reversals and re-claims of input tax credit
-- -----------------------------------------------------------------------------
create table public.itc_adjustments (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null references public.dealers (id) on delete restrict,
  branch_id        uuid not null,
  adjustment_date  date not null,
  direction        text not null,
  rule             text not null,
  purchase_bill_id uuid,
  cgst_amount      numeric(18, 4) not null default 0,
  sgst_amount      numeric(18, 4) not null default 0,
  igst_amount      numeric(18, 4) not null default 0,
  total_amount     numeric(18, 4) generated always as (cgst_amount + sgst_amount + igst_amount) stored,
  note             text not null,
  journal_entry_id uuid,
  idempotency_key  text,
  created_by       uuid,
  created_at       timestamptz not null default now(),

  constraint itc_adj_idempotency_key unique (dealer_id, idempotency_key),
  constraint itc_adj_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id),
  constraint itc_adj_bill_tenant_fkey
    foreign key (purchase_bill_id, dealer_id) references public.purchase_bills (id, dealer_id),
  constraint itc_adj_journal_tenant_fkey
    foreign key (journal_entry_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint itc_adj_direction_check check (direction in ('REVERSAL', 'RECLAIM')),
  constraint itc_adj_rule_check check (rule in ('RULE_37', 'RULE_42', 'RULE_43', 'SECTION_17_5', 'OTHER')),
  constraint itc_adj_amounts_check check (
    cgst_amount >= 0 and sgst_amount >= 0 and igst_amount >= 0
    and cgst_amount + sgst_amount + igst_amount > 0)
);

comment on table public.itc_adjustments is
  'Input tax credit reversed (rule 37, 42, 43, s.17(5)) and re-claimed, each '
  'posted ITC ⇄ 5990. GSTR-3B table 4(B) reads the reversals, 4(A)(5) the re-claims.';

create index itc_adj_dealer_date_idx on public.itc_adjustments (dealer_id, adjustment_date);
create index itc_adj_bill_idx on public.itc_adjustments (purchase_bill_id) where purchase_bill_id is not null;

-- Append-only: the one write after insert is the journal link, once.
create or replace function app.itc_adjustments_append_only()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' or old.journal_entry_id is not null
     -- total_amount is generated, and not yet computed in a BEFORE trigger.
     or (to_jsonb(new) - 'journal_entry_id' - 'total_amount')
        is distinct from (to_jsonb(old) - 'journal_entry_id' - 'total_amount') then
    raise exception 'An ITC adjustment is permanent; record the opposite adjustment instead.'
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;

create trigger itc_adjustments_append_only
  before update or delete on public.itc_adjustments
  for each row execute function app.itc_adjustments_append_only();

alter table public.itc_adjustments enable row level security;
create policy itc_adj_select on public.itc_adjustments for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id()
         and (app.has_permission('gst.reports.view') or app.has_permission('gst.itc.manage'))));
create policy itc_adj_insert on public.itc_adjustments for insert to authenticated
  with check (dealer_id = app.current_dealer_id() and app.has_permission('gst.itc.manage'));
create policy itc_adj_update on public.itc_adjustments for update to authenticated
  using (dealer_id = app.current_dealer_id() and app.has_permission('gst.itc.manage'))
  with check (dealer_id = app.current_dealer_id() and app.has_permission('gst.itc.manage'));

create or replace function public.record_itc_adjustment(
  p_direction        text,
  p_rule             text,
  p_branch_id        uuid,
  p_cgst             numeric,
  p_sgst             numeric,
  p_igst             numeric,
  p_note             text,
  p_date             date default current_date,
  p_purchase_bill_id uuid default null,
  p_idempotency_key  text default null
)
returns uuid
language plpgsql
as $$
declare
  v_dealer   uuid := app.current_dealer_id();
  v_existing uuid;
  v_adj      public.itc_adjustments;
  v_reversed numeric;
  v_claimed  numeric;
  v_lines    jsonb := '[]'::jsonb;
  v_head     text;
  v_amount   numeric;
  v_entry    uuid;
  v_input    numeric := 0;
begin
  if v_dealer is null or not app.has_permission('gst.itc.manage') then
    raise exception 'You do not have permission to adjust input tax credit.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_idempotency_key is not null then
    select id into v_existing from public.itc_adjustments
     where dealer_id = v_dealer and idempotency_key = p_idempotency_key;
    if v_existing is not null then return v_existing; end if;
  end if;
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'Say why the credit is being adjusted.' using errcode = 'check_violation';
  end if;
  if not app.can_access_branch(p_branch_id) then
    raise exception 'You do not have access to that branch.' using errcode = 'insufficient_privilege';
  end if;
  if p_purchase_bill_id is not null and not exists (
       select 1 from public.purchase_bills where id = p_purchase_bill_id and dealer_id = v_dealer and status = 'POSTED') then
    raise exception 'That purchase bill is not posted.' using errcode = 'no_data_found';
  end if;

  -- A re-claim gives back credit that was taken away, never more.
  if p_direction = 'RECLAIM' then
    select coalesce(sum(total_amount) filter (where direction = 'REVERSAL'), 0),
           coalesce(sum(total_amount) filter (where direction = 'RECLAIM'), 0)
      into v_reversed, v_claimed
      from public.itc_adjustments
     where dealer_id = v_dealer and rule = p_rule
       and purchase_bill_id is not distinct from p_purchase_bill_id;
    if v_claimed + coalesce(p_cgst, 0) + coalesce(p_sgst, 0) + coalesce(p_igst, 0) > v_reversed then
      raise exception 'Only % of credit reversed under % is left to re-claim.',
        v_reversed - v_claimed, replace(p_rule, '_', ' ') using errcode = 'check_violation';
    end if;
  end if;

  insert into public.itc_adjustments
    (dealer_id, branch_id, adjustment_date, direction, rule, purchase_bill_id,
     cgst_amount, sgst_amount, igst_amount, note, idempotency_key, created_by)
  values
    (v_dealer, p_branch_id, p_date, p_direction, p_rule, p_purchase_bill_id,
     round(coalesce(p_cgst, 0), 2), round(coalesce(p_sgst, 0), 2), round(coalesce(p_igst, 0), 2),
     btrim(p_note), p_idempotency_key, auth.uid())
  returning * into v_adj;

  foreach v_head in array array['CGST', 'SGST', 'IGST'] loop
    v_amount := case v_head when 'CGST' then v_adj.cgst_amount when 'SGST' then v_adj.sgst_amount
                            else v_adj.igst_amount end;
    if v_amount > 0 then
      v_lines := v_lines || jsonb_build_object(
        'account_id', app.require_account(v_dealer, 'INVENTORY', 'PURCHASE', 'INPUT_' || v_head, p_branch_id),
        'debit',  case when p_direction = 'RECLAIM' then v_amount else 0 end,
        'credit', case when p_direction = 'REVERSAL' then v_amount else 0 end,
        'narration', initcap(lower(p_direction)) || ' of input ' || v_head);
      v_input := v_input + v_amount;
    end if;
  end loop;
  v_lines := v_lines || jsonb_build_object(
    'account_id', app.require_account(v_dealer, 'EXPENSE', 'ITC', 'REVERSED', p_branch_id),
    'debit',  case when p_direction = 'REVERSAL' then v_input else 0 end,
    'credit', case when p_direction = 'RECLAIM' then v_input else 0 end,
    'narration', btrim(p_note));

  v_entry := app.post_journal(
    v_dealer, p_branch_id, p_date, 'EXPENSE',
    'ITC ' || lower(p_direction) || ' — ' || replace(p_rule, '_', ' ') || ': ' || btrim(p_note),
    v_lines, 'ITC_ADJUSTMENT', v_adj.id, 'itc-adjustment:' || v_adj.id::text);

  update public.itc_adjustments set journal_entry_id = v_entry where id = v_adj.id;
  return v_adj.id;
end;
$$;

comment on function public.record_itc_adjustment(text, text, uuid, numeric, numeric, numeric, text, date, uuid, text) is
  'Reverses or re-claims input tax credit and posts it (ITC ⇄ 5990). A re-claim '
  'may not exceed what was reversed under the same rule and bill. Idempotent.';

-- Rule 37: credit on a bill not paid within 180 days is reversed until it is.
-- Payments are applied oldest bill first, so what a supplier is still owed sits
-- on the newest bills; a bill older than 180 days that still carries any of it
-- has that share of its credit due for reversal, less what is already reversed.
create or replace function public.itc_rule37_candidates(p_as_on date default current_date)
returns table (
  purchase_bill_id uuid,
  bill_number      text,
  supplier_bill_number text,
  supplier_name    text,
  branch_id        uuid,
  bill_date        date,
  days_outstanding integer,
  bill_total       numeric(18, 4),
  unpaid           numeric(18, 4),
  cgst_due         numeric(18, 4),
  sgst_due         numeric(18, 4),
  igst_due         numeric(18, 4)
)
language sql
stable
as $$
  with owed as (
    select l.party_id as supplier_id, sum(l.credit - l.debit) as outstanding
      from public.journal_entry_lines l
      join public.journal_entries je on je.id = l.journal_entry_id
     where l.party_type = 'SUPPLIER' and je.status in ('POSTED', 'REVERSED')
       and je.entry_date <= p_as_on and je.dealer_id = app.current_dealer_id()
     group by l.party_id
  ),
  bills as (
    select b.*, s.name as supplier_name,
           sum(b.total_amount) over (partition by b.supplier_id
                                      order by b.bill_date desc, b.bill_number desc
                                      rows unbounded preceding) - b.total_amount as newer
      from public.purchase_bills b
      join public.suppliers s on s.id = b.supplier_id
     where b.status = 'POSTED' and b.bill_date <= p_as_on and b.dealer_id = app.current_dealer_id()
  ),
  unpaid as (
    select b.*, greatest(0, least(b.total_amount, coalesce(o.outstanding, 0) - b.newer)) as unpaid_amt
      from bills b left join owed o on o.supplier_id = b.supplier_id
  ),
  credit as (
    select l.purchase_bill_id,
           sum(l.cgst_amount) as cgst, sum(l.sgst_amount) as sgst, sum(l.igst_amount) as igst
      from public.purchase_bill_lines l
     where l.itc_eligible and not l.reverse_charge
     group by l.purchase_bill_id
  ),
  done as (
    select a.purchase_bill_id,
           sum(case when a.direction = 'REVERSAL' then a.cgst_amount else -a.cgst_amount end) as cgst,
           sum(case when a.direction = 'REVERSAL' then a.sgst_amount else -a.sgst_amount end) as sgst,
           sum(case when a.direction = 'REVERSAL' then a.igst_amount else -a.igst_amount end) as igst
      from public.itc_adjustments a
     where a.rule = 'RULE_37' and a.purchase_bill_id is not null
     group by a.purchase_bill_id
  )
  select u.id, u.bill_number, u.supplier_bill_number, u.supplier_name, u.branch_id, u.bill_date,
         (p_as_on - u.bill_date)::integer, u.total_amount, u.unpaid_amt,
         greatest(0, round(c.cgst * u.unpaid_amt / u.total_amount, 2) - coalesce(d.cgst, 0)),
         greatest(0, round(c.sgst * u.unpaid_amt / u.total_amount, 2) - coalesce(d.sgst, 0)),
         greatest(0, round(c.igst * u.unpaid_amt / u.total_amount, 2) - coalesce(d.igst, 0))
    from unpaid u
    join credit c on c.purchase_bill_id = u.id
    left join done d on d.purchase_bill_id = u.id
   where u.bill_date <= p_as_on - 180
     and u.unpaid_amt > 0
     and greatest(0, round(c.cgst * u.unpaid_amt / u.total_amount, 2) - coalesce(d.cgst, 0))
       + greatest(0, round(c.sgst * u.unpaid_amt / u.total_amount, 2) - coalesce(d.sgst, 0))
       + greatest(0, round(c.igst * u.unpaid_amt / u.total_amount, 2) - coalesce(d.igst, 0)) > 0
   order by u.bill_date;
$$;

-- -----------------------------------------------------------------------------
-- Reports
-- -----------------------------------------------------------------------------
-- Outward and inward supplies by category — GSTR-3B 3.1(a)(b)(c)(e) and 5.
create or replace function public.gst_supply_categories(
  p_from date, p_to date, p_branch_id uuid default null
)
returns table (
  direction      text,
  tax_category   text,
  document_count bigint,
  taxable_value  numeric(18, 4),
  total_tax      numeric(18, 4)
)
language sql
stable
as $$
  with lines as (
    select 'OUTWARD'::text as dir,
           app.supply_category(s.dealer_id, l.tax_code, s.invoice_date,
                               l.cgst_amount + l.sgst_amount + l.igst_amount) as cat,
           s.id as doc, l.taxable_value, l.cgst_amount + l.sgst_amount + l.igst_amount as tax
      from public.sale_lines l join public.sales s on s.id = l.sale_id
     where s.status in ('POSTED', 'DELIVERED') and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select 'OUTWARD',
           app.supply_category(si.dealer_id, l.tax_code, si.invoice_date,
                               l.cgst_amount + l.sgst_amount + l.igst_amount),
           si.id, l.taxable_value, l.cgst_amount + l.sgst_amount + l.igst_amount
      from public.service_lines l join public.service_invoices si on si.id = l.invoice_id
     where si.status = 'POSTED' and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
    union all
    select 'INWARD', l.tax_category, b.id, l.taxable_value,
           l.cgst_amount + l.sgst_amount + l.igst_amount
      from public.purchase_bill_lines l join public.purchase_bills b on b.id = l.purchase_bill_id
     where b.status = 'POSTED' and b.bill_date between p_from and p_to
       and (p_branch_id is null or b.branch_id = p_branch_id)
  )
  select dir, cat, count(distinct doc), sum(taxable_value), sum(tax)
    from lines
   group by dir, cat
   order by dir desc, cat;
$$;

-- GSTR-1: notes to registered customers are CDNR, to others CDNUR; a credit
-- note is shown negative so each section nets to what is owed.
create or replace function public.gstr1_summary(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  section        text,
  document_count bigint,
  taxable_value  numeric(18, 4),
  cgst_amount    numeric(18, 4),
  sgst_amount    numeric(18, 4),
  igst_amount    numeric(18, 4),
  total_tax      numeric(18, 4),
  invoice_value  numeric(18, 4)
)
language sql
stable
as $$
  with docs as (
    select case when nullif(btrim(coalesce(c.gstin, '')), '') is not null then 'B2B' else 'B2C' end as section,
           s.id, s.taxable_value, s.cgst_amount, s.sgst_amount, s.igst_amount, s.total_amount
      from public.sales s
      left join public.customers c on c.id = s.customer_id
     where s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select case when nullif(btrim(coalesce(c.gstin, '')), '') is not null then 'B2B' else 'B2C' end,
           si.id, si.taxable_value, si.cgst_amount, si.sgst_amount, si.igst_amount, si.total_amount
      from public.service_invoices si
      left join public.customers c on c.id = si.customer_id
     where si.status = 'POSTED'
       and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
    union all
    select case when nullif(btrim(coalesce(c.gstin, '')), '') is not null then 'CDNR' else 'CDNUR' end,
           n.id,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.taxable_value,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.cgst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.sgst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.igst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.total_amount
      from public.gst_notes n
      join public.customers c on c.id = n.customer_id
     where n.party_type = 'CUSTOMER' and n.status = 'POSTED'
       and n.note_date between p_from and p_to
       and (p_branch_id is null or n.branch_id = p_branch_id)
  )
  select docs.section, count(*), sum(docs.taxable_value), sum(docs.cgst_amount), sum(docs.sgst_amount),
         sum(docs.igst_amount), sum(docs.cgst_amount + docs.sgst_amount + docs.igst_amount),
         sum(docs.total_amount)
    from docs
   group by 1
   order by 1;
$$;

create or replace function public.gst_document_register(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null,
  p_section   text default null
)
returns table (
  document_type   text,
  document_id     uuid,
  document_number text,
  document_date   date,
  customer_name   text,
  gstin           text,
  place_of_supply text,
  section         text,
  taxable_value   numeric(18, 4),
  cgst_amount     numeric(18, 4),
  sgst_amount     numeric(18, 4),
  igst_amount     numeric(18, 4),
  invoice_value   numeric(18, 4),
  einvoice_status text,
  irn             text
)
language sql
stable
as $$
  with docs as (
    select 'SALE'::text as dtype, s.id, s.invoice_number, s.invoice_date,
           coalesce(c.name, 'Cash customer') as cname, c.gstin, c.state as pos,
           s.taxable_value, s.cgst_amount, s.sgst_amount, s.igst_amount, s.total_amount,
           case when nullif(btrim(coalesce(c.gstin, '')), '') is not null then 'B2B' else 'B2C' end as sect
      from public.sales s
      left join public.customers c on c.id = s.customer_id
     where s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select 'SERVICE_INVOICE', si.id, si.invoice_number, si.invoice_date,
           coalesce(c.name, 'Counter sale'), c.gstin, c.state,
           si.taxable_value, si.cgst_amount, si.sgst_amount, si.igst_amount, si.total_amount,
           case when nullif(btrim(coalesce(c.gstin, '')), '') is not null then 'B2B' else 'B2C' end
      from public.service_invoices si
      left join public.customers c on c.id = si.customer_id
     where si.status = 'POSTED'
       and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
    union all
    select n.note_type || '_NOTE', n.id, n.note_number, n.note_date,
           c.name, c.gstin, c.state,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.taxable_value,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.cgst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.sgst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.igst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.total_amount,
           case when nullif(btrim(coalesce(c.gstin, '')), '') is not null then 'CDNR' else 'CDNUR' end
      from public.gst_notes n
      join public.customers c on c.id = n.customer_id
     where n.party_type = 'CUSTOMER' and n.status = 'POSTED'
       and n.note_date between p_from and p_to
       and (p_branch_id is null or n.branch_id = p_branch_id)
  )
  select d.dtype, d.id, d.invoice_number, d.invoice_date, d.cname, d.gstin, d.pos, d.sect,
         d.taxable_value, d.cgst_amount, d.sgst_amount, d.igst_amount, d.total_amount,
         coalesce(e.status, 'NOT_REQUESTED'), e.irn
    from docs d
    left join public.einvoices e on e.document_type = d.dtype and e.document_id = d.id
   where p_section is null or p_section = d.sect
   order by d.invoice_date, d.invoice_number;
$$;

-- HSN summary: customer notes net against the HSN they amend.
create or replace function public.gst_summary(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  hsn_code      text,
  description   text,
  taxable_value numeric(18, 4),
  cgst_amount   numeric(18, 4),
  sgst_amount   numeric(18, 4),
  igst_amount   numeric(18, 4),
  total_tax     numeric(18, 4),
  document_count bigint
)
language sql
stable
as $$
  with lines as (
    select coalesce(l.hsn_code, 'UNSPECIFIED') hsn, s.dealer_id, l.taxable_value,
           l.cgst_amount, l.sgst_amount, l.igst_amount, s.id doc
      from public.sale_lines l
      join public.sales s on s.id = l.sale_id
     where s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select coalesce(l.hsn_code, 'UNSPECIFIED'), si.dealer_id, l.taxable_value,
           l.cgst_amount, l.sgst_amount, l.igst_amount, si.id
      from public.service_lines l
      join public.service_invoices si on si.id = l.invoice_id
     where si.status = 'POSTED'
       and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
    union all
    select coalesce(n.hsn_sac, 'UNSPECIFIED'), n.dealer_id,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.taxable_value,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.cgst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.sgst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.igst_amount,
           n.id
      from public.gst_notes n
     where n.party_type = 'CUSTOMER' and n.status = 'POSTED'
       and n.note_date between p_from and p_to
       and (p_branch_id is null or n.branch_id = p_branch_id)
  )
  select lines.hsn,
         coalesce(max(h.description), ''),
         sum(lines.taxable_value), sum(lines.cgst_amount), sum(lines.sgst_amount),
         sum(lines.igst_amount),
         sum(lines.cgst_amount + lines.sgst_amount + lines.igst_amount),
         count(distinct lines.doc)
    from lines
    left join public.hsn_codes h
      on h.code = lines.hsn and h.dealer_id = lines.dealer_id
   group by lines.hsn
   order by lines.hsn;
$$;

-- Input tax: supplier notes adjust the credit they amend (when it was claimable).
create or replace function public.gst_input_summary(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  hsn_code       text,
  description    text,
  taxable_value  numeric(18, 4),
  cgst_amount    numeric(18, 4),
  sgst_amount    numeric(18, 4),
  igst_amount    numeric(18, 4),
  total_tax      numeric(18, 4),
  document_count bigint
)
language sql
stable
as $$
  with lines as (
    select coalesce(h.code, l.hsn_sac, 'UNSPECIFIED') as hsn,
           coalesce(h.description, case when l.line_type = 'EXPENSE' then c.name end, '') as descr,
           l.taxable_value, l.cgst_amount, l.sgst_amount, l.igst_amount,
           b.id as doc
      from public.purchase_bill_lines l
      join public.purchase_bills b on b.id = l.purchase_bill_id
      left join public.inventory_items i on i.id = l.item_id
      left join public.vehicles v on v.id = l.vehicle_id
      left join public.vehicle_models m on m.id = v.model_id
      left join public.hsn_codes h on h.id = coalesce(i.hsn_code_id, m.hsn_code_id)
      left join public.chart_of_accounts c on c.id = l.account_id
     where b.status = 'POSTED'
       and l.itc_eligible
       and b.bill_date between p_from and p_to
       and (p_branch_id is null or b.branch_id = p_branch_id)

    union all

    select coalesce(h.code, 'UNSPECIFIED'),
           coalesce(h.description, ''),
           -rl.taxable_value, -rl.cgst_amount, -rl.sgst_amount, -rl.igst_amount,
           r.id
      from public.purchase_return_lines rl
      join public.purchase_returns r on r.id = rl.purchase_return_id
      left join public.inventory_items i on i.id = rl.item_id
      left join public.vehicles v on v.id = rl.vehicle_id
      left join public.vehicle_models m on m.id = v.model_id
      left join public.hsn_codes h on h.id = coalesce(i.hsn_code_id, m.hsn_code_id)
     where r.status = 'POSTED'
       and r.return_date between p_from and p_to
       and (p_branch_id is null or r.branch_id = p_branch_id)

    union all

    select coalesce(n.hsn_sac, 'UNSPECIFIED'), coalesce(c.name, ''),
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.taxable_value,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.cgst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.sgst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.igst_amount,
           n.id
      from public.gst_notes n
      left join public.chart_of_accounts c on c.id = n.account_id
     where n.party_type = 'SUPPLIER' and n.status = 'POSTED' and n.itc_eligible
       and n.note_date between p_from and p_to
       and (p_branch_id is null or n.branch_id = p_branch_id)
  )
  select lines.hsn,
         max(lines.descr),
         sum(lines.taxable_value), sum(lines.cgst_amount), sum(lines.sgst_amount),
         sum(lines.igst_amount),
         sum(lines.cgst_amount + lines.sgst_amount + lines.igst_amount),
         count(distinct lines.doc)
    from lines
   group by lines.hsn
   order by lines.hsn;
$$;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;
  execute 'grant select, insert, update on public.gst_notes to authenticated';
  execute 'grant select, insert, update on public.itc_adjustments to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0084', 'gst_categories_notes_rcm_itc') on conflict (version) do nothing;
