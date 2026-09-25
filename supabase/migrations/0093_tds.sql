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
