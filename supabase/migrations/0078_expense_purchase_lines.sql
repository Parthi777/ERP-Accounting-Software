-- =============================================================================
-- 0078 — Expenses and fixed assets on a purchase bill
-- =============================================================================
-- Spec §16, §21, §22, §24, §40, §41, §48.
--
-- A purchase bill could only carry stock: a VEHICLE, an ACCESSORY or a SPARE.
-- Everything else a dealer buys on a GST invoice — the showroom rent, the
-- electricity, a computer, a signboard, the auditor's fee — had no document.
-- It could be typed in as a manual journal, which put the cost somewhere but
-- lost the supplier bill, and its input GST never reached gst_input_summary():
-- that reads purchase bills, so the ITC on every overhead was invisible at
-- filing time and the liability overstated by exactly that much.
--
-- An EXPENSE line names the account it is charged to — an expense, or a fixed
-- asset when the thing bought is capital — and otherwise behaves like any other
-- line: taxable value, GST computed server-side, payable to the supplier.
--
-- ITC eligibility. Not every input tax can be claimed (blocked credits under
-- s.17(5) — food, personal use, motor vehicles for own use, and so on). A line
-- marked itc_eligible = false charges its GST into its own account instead of
-- to Input CGST/SGST/IGST, and is left out of the input-tax summary. This is the
-- line-level switch the return needs; which purchases are blocked remains the
-- accountant's judgement, as it has to be.
--
-- Stock never arrives this way: an EXPENSE line may not name an inventory, input
-- tax or payable account — those have their own lines and rules — nor a cash or
-- bank ledger.
--
-- Rollback: delete EXPENSE lines (none posted), restore the constraints and
--           public.post_purchase_bill from 0052, public.gst_input_summary from
--           0058 and public.returnable_purchase_lines from 0057; drop the columns
--           and trigger added here.
-- =============================================================================

alter table public.purchase_bill_lines
  add column if not exists account_id   uuid,
  add column if not exists hsn_sac      text,
  add column if not exists itc_eligible boolean not null default true;

alter table public.purchase_bill_lines
  add constraint pbl_account_tenant_fkey
    foreign key (account_id, dealer_id) references public.chart_of_accounts (id, dealer_id);

alter table public.purchase_bill_lines drop constraint pbl_type_check;
alter table public.purchase_bill_lines
  add constraint pbl_type_check check (line_type in ('VEHICLE', 'ACCESSORY', 'SPARE', 'EXPENSE'));

alter table public.purchase_bill_lines drop constraint pbl_shape_check;
alter table public.purchase_bill_lines
  add constraint pbl_shape_check check (
    (line_type = 'VEHICLE'
       and vehicle_id is not null and item_id is null and source is null
       and account_id is null and quantity = 1)
    or (line_type in ('ACCESSORY', 'SPARE')
       and item_id is not null and vehicle_id is null and source is not null
       and account_id is null and quantity > 0)
    or (line_type = 'EXPENSE'
       and account_id is not null and item_id is null and vehicle_id is null
       and source is null and quantity > 0)
  );

-- Blocked credit is an expense-line concept: stock carries its input tax, and
-- folding blocked GST into a stock lot's cost is a costing change of its own.
alter table public.purchase_bill_lines
  add constraint pbl_itc_scope_check check (itc_eligible or line_type = 'EXPENSE');

alter table public.purchase_bill_lines
  add constraint pbl_hsn_sac_shape_check check (hsn_sac is null or hsn_sac ~ '^[0-9]{4,8}$');

create index if not exists purchase_bill_lines_account_idx
  on public.purchase_bill_lines (account_id) where account_id is not null;

-- -----------------------------------------------------------------------------
-- Which accounts an EXPENSE line may be charged to
-- -----------------------------------------------------------------------------
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
  if v_acc.account_type not in ('EXPENSE', 'ASSET') then
    raise exception 'A purchase is charged to an expense or an asset; % % is %.',
      v_acc.code, v_acc.name, lower(v_acc.account_type)
      using errcode = 'check_violation';
  end if;
  if app.is_money_ledger(new.dealer_id, new.account_id) then
    raise exception 'Account % % is cash or bank, not something bought.', v_acc.code, v_acc.name
      using errcode = 'check_violation';
  end if;
  -- Inventory, input tax and the payable each have their own path onto a bill.
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

create trigger purchase_bill_lines_account_guard
  before insert or update on public.purchase_bill_lines
  for each row execute function app.purchase_bill_lines_account_guard();

-- -----------------------------------------------------------------------------
-- public.post_purchase_bill() — EXPENSE lines, and blocked ITC
-- -----------------------------------------------------------------------------
-- As 0052, with two changes: an EXPENSE line debits its own account (plus its
-- GST when the credit is blocked) and moves no stock; and the input-tax debits
-- are summed from the eligible lines rather than read off the header.
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
      -- No stock moves. Blocked input tax is part of what the thing cost.
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

  -- ── Input GST, from the lines whose credit can be claimed ────────────────
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

comment on function public.post_purchase_bill(uuid, text) is
  'Posts a purchase bill (spec §21, §48): stock onto the balance sheet, expenses '
  'and fixed assets to their accounts, eligible input GST to ITC, and the payable '
  'onto the supplier''s ledger. Idempotent (spec §50).';

-- -----------------------------------------------------------------------------
-- Returns are for goods that go back; an expense is corrected by cancelling
-- -----------------------------------------------------------------------------
create or replace function public.returnable_purchase_lines(p_bill_id uuid)
returns table (
  bill_line_id        uuid,
  line_number         smallint,
  line_type           text,
  description         text,
  source              text,
  chassis_no          text,
  item_code           text,
  vehicle_status      text,
  billed_quantity     numeric(18, 3),
  returned_quantity   numeric(18, 3),
  returnable_quantity numeric(18, 3),
  unit_rate           numeric(18, 4),
  cgst_rate           numeric(6, 3),
  sgst_rate           numeric(6, 3),
  igst_rate           numeric(6, 3)
)
language sql
stable
as $$
  select l.id, l.line_number, l.line_type, l.description, l.source,
         v.chassis_no, i.item_code, v.status,
         l.quantity,
         coalesce(r.returned, 0)::numeric(18, 3),
         (l.quantity - coalesce(r.returned, 0))::numeric(18, 3),
         l.unit_rate, l.cgst_rate, l.sgst_rate, l.igst_rate
    from public.purchase_bill_lines l
    left join public.vehicles v on v.id = l.vehicle_id
    left join public.inventory_items i on i.id = l.item_id
    left join lateral (
      select sum(rl.quantity) as returned
        from public.purchase_return_lines rl
        join public.purchase_returns pr on pr.id = rl.purchase_return_id
       where rl.purchase_bill_line_id = l.id
         and pr.status = 'POSTED'
    ) r on true
   where l.purchase_bill_id = p_bill_id
     and l.line_type <> 'EXPENSE'
   order by l.line_number;
$$;

-- post_purchase_return() walks the lines it is given; an EXPENSE line has no
-- stock to take back. Refused with a reason rather than a constraint name.
create or replace function app.purchase_return_lines_type_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if exists (select 1 from public.purchase_bill_lines
              where id = new.purchase_bill_line_id and line_type = 'EXPENSE') then
    raise exception 'An expense line cannot be returned. Cancel the bill, or post the supplier''s credit note as a journal.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger purchase_return_lines_type_guard
  before insert on public.purchase_return_lines
  for each row execute function app.purchase_return_lines_type_guard();

-- -----------------------------------------------------------------------------
-- gst_input_summary() — expense lines by their HSN/SAC, blocked credit left out
-- -----------------------------------------------------------------------------
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

comment on function public.gst_input_summary(date, date, uuid) is
  'HSN/SAC-wise claimable input tax for a period (spec §40, §41): stock and '
  'expense lines on purchase bills, less debit notes. Lines marked ITC-ineligible '
  'are excluded — their tax is a cost, not a credit.';

insert into public.schema_migrations (version, name)
values ('0078', 'expense_purchase_lines') on conflict (version) do nothing;
