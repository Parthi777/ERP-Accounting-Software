-- =============================================================================
-- INCREMENTAL 0087 → 0087
-- =============================================================================
-- GENERATED FILE. Regenerate with:
--   FROM=0087 bash scripts/build-incremental.sh
--
-- For a database that ALREADY has migrations up to 0086.
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
-- SOURCE: supabase/migrations/0087_finance_dd_deductions_party_journals.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0087 — Finance DD with deductions, and journals that name the party
-- =============================================================================
-- Spec §21, §25, §27. Raised by the dealer: "when a customer took finance we
-- need to enter the finance DD and document charges and some freight charge",
-- and "the accountant needs to clear and tally the debit and credit" from the
-- customer's own page.
--
-- ── A DD rarely equals the loan ────────────────────────────────────────────
--
-- A financed sale moves the loan amount from the customer to Finance
-- Receivable (1400), on the finance company's ledger. The company then pays a
-- DD for less than the loan: it keeps its document (processing) charges, and
-- sometimes freight or other charges. disburse_finance_application() could only
-- post the DD itself — Bank Dr / Finance Receivable Cr — so the deductions sat
-- in 1400 forever as money the company "still owed", and the application never
-- showed as settled.
--
-- receive_finance_dd() takes the DD and each deduction, and says who bears it:
--
--   Bank                              Dr   DD amount
--   Customer (receivable)             Dr   charges the customer pays
--   Finance Document Charges (5920)   Dr   ┐ charges the dealer bears
--   Freight Charges (5930)            Dr   │
--   Other Expenses (5900)             Dr   ┘
--     Finance Receivable (company)       Cr   DD + every deduction
--
-- so the finance company's balance falls by the whole amount it has settled,
-- and anything the customer owes for it lands on the customer's ledger to be
-- collected like any other balance. The company ledger records the DD and each
-- deduction as its own row.
--
-- ── Party on a journal line ────────────────────────────────────────────────
--
-- Manual journals could carry a customer, supplier or finance company on a
-- line (the service passed it through), but nothing checked the party was the
-- dealer's own. A trigger on journal_entry_lines now refuses a party from
-- another tenant, or one that does not exist, whoever posts the line.
--
-- Rollback: drop receive_finance_dd(), the trigger and its function; drop the
--           deductions_amount column; restore ft_type_check without DEDUCTION;
--           rename app.seed_chart_of_accounts_0086 back.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A journal line's party must be this dealer's
-- -----------------------------------------------------------------------------
create or replace function app.journal_line_party_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ok boolean;
begin
  if new.party_id is null then
    return new;
  end if;
  v_ok := case new.party_type
    when 'CUSTOMER'        then exists (select 1 from public.customers x where x.id = new.party_id and x.dealer_id = new.dealer_id)
    when 'SUPPLIER'        then exists (select 1 from public.suppliers x where x.id = new.party_id and x.dealer_id = new.dealer_id)
    when 'FINANCE_COMPANY' then exists (select 1 from public.finance_companies x where x.id = new.party_id and x.dealer_id = new.dealer_id)
    when 'EMPLOYEE'        then exists (select 1 from public.employees x where x.id = new.party_id and x.dealer_id = new.dealer_id)
    else false end;
  if not v_ok then
    raise exception 'Journal line %: the % named on it is not one of this dealer''s.',
      new.line_number, lower(replace(coalesce(new.party_type, 'party'), '_', ' '))
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;

create trigger journal_entry_lines_party_guard
  before insert on public.journal_entry_lines
  for each row execute function app.journal_line_party_guard();

-- -----------------------------------------------------------------------------
-- Accounts and rules for what a finance company keeps back
-- -----------------------------------------------------------------------------
create or replace function app.seed_finance_deduction_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
declare
  v_added integer := 0;
  a       record;
begin
  for a in
    select * from (values
      ('5920', 'Finance Document Charges'),
      ('5930', 'Freight Charges')
    ) as t(code, name)
  loop
    insert into public.chart_of_accounts
      (dealer_id, code, name, account_type, normal_balance, is_group, parent_id, is_system, is_branch_scoped)
    select p_dealer_id, a.code, a.name, 'EXPENSE', 'DEBIT', false, p.id, true, false
      from public.chart_of_accounts p
     where p.dealer_id = p_dealer_id and p.code = '5000' and p.is_group
    on conflict on constraint coa_dealer_code_key do nothing;
    if found then v_added := v_added + 1; end if;
  end loop;

  insert into public.accounting_rules (dealer_id, module, event, component, side, account_id, description)
  select p_dealer_id, 'FINANCE', 'DISBURSEMENT', r.component, 'DEBIT', c.id, 'Default mapping'
    from (values ('DOCUMENT_CHARGES', '5920'), ('FREIGHT', '5930'), ('OTHER_DEDUCTION', '5900')) as r(component, code)
    -- A code the dealer already used for something else is left alone, and the
    -- rule unmapped: posting then says so rather than charging the wrong account.
    join public.chart_of_accounts c on c.dealer_id = p_dealer_id and c.code = r.code
                                   and not c.is_group and c.account_type = 'EXPENSE'
   where not exists (select 1 from public.accounting_rules x
                      where x.dealer_id = p_dealer_id and x.module = 'FINANCE' and x.event = 'DISBURSEMENT'
                        and x.component = r.component and x.branch_id is null and x.status = 'ACTIVE');

  return v_added;
end;
$$;

do $$
declare d record;
begin
  for d in select id from public.dealers loop
    perform app.seed_finance_deduction_accounts(d.id);
  end loop;
end $$;

alter function app.seed_chart_of_accounts(uuid) rename to seed_chart_of_accounts_0086;

create or replace function app.seed_chart_of_accounts(p_dealer_id uuid)
returns integer
language plpgsql
as $$
begin
  return app.seed_chart_of_accounts_0086(p_dealer_id) + app.seed_finance_deduction_accounts(p_dealer_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- The application remembers what was deducted; the company ledger shows it
-- -----------------------------------------------------------------------------
-- disbursed_amount stays "how much of the loan is settled", so pending_amount
-- (approved − disbursed) reaches zero when the DD and its deductions cover it.
alter table public.finance_applications
  add column if not exists deductions_amount numeric(18, 4) not null default 0;

comment on column public.finance_applications.deductions_amount is
  'Part of disbursed_amount the finance company kept back (document charges, '
  'freight, other) rather than paid by DD. The DD received is disbursed − deductions.';

alter table public.finance_transactions drop constraint ft_type_check;
alter table public.finance_transactions add constraint ft_type_check check (transaction_type in (
  'ADVANCE_RECEIVED', 'VEHICLE_ADJUSTMENT', 'SETTLEMENT',
  'REFUND', 'COMMISSION', 'MANUAL_ADJUSTMENT', 'DISBURSEMENT', 'DEDUCTION'
));

-- -----------------------------------------------------------------------------
-- public.receive_finance_dd()
-- -----------------------------------------------------------------------------
-- p_deductions: [{ "kind": "DOCUMENT_CHARGES" | "FREIGHT" | "OTHER",
--                  "amount": 1500, "borne_by": "CUSTOMER" | "DEALER",
--                  "note": "optional; required for OTHER" }]
create or replace function public.receive_finance_dd(
  p_application_id  uuid,
  p_bank_account_id uuid,
  p_dd_amount       numeric,
  p_deductions      jsonb default '[]'::jsonb,
  p_dd_number       text default null,
  p_bank_reference  text default null,
  p_date            date default current_date,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
as $$
declare
  v_app      public.finance_applications;
  v_bank     public.bank_accounts;
  v_key      text;
  v_existing uuid;
  v_pending  numeric;
  v_ded      jsonb;
  v_total_d  numeric := 0;
  v_amount   numeric;
  v_kind     text;
  v_by       text;
  v_label    text;
  v_lines    jsonb := '[]'::jsonb;
  v_entry    uuid;
  v_ref      text := nullif(btrim(coalesce(p_bank_reference, p_dd_number, '')), '');
  v_customer_part numeric := 0;
begin
  if app.current_dealer_id() is null or not app.has_permission('finance.applications.manage') then
    raise exception 'You may not record finance disbursements.' using errcode = 'insufficient_privilege';
  end if;

  select * into v_app from public.finance_applications
   where id = p_application_id and dealer_id = app.current_dealer_id() for update;
  if v_app.id is null then
    raise exception 'Application not found.' using errcode = 'no_data_found';
  end if;

  -- A repeated submission returns the entry it already made, and writes nothing.
  v_key := case when p_idempotency_key is null then null else 'fin-dd:' || p_idempotency_key end;
  if v_key is not null then
    select id into v_existing from public.journal_entries
     where dealer_id = v_app.dealer_id and idempotency_key = v_key;
    if v_existing is not null then
      return v_existing;
    end if;
  end if;

  if v_app.approval_status <> 'APPROVED' then
    raise exception 'Application % is % — only an approved application can be disbursed.',
      v_app.application_number, v_app.approval_status using errcode = 'check_violation';
  end if;
  if coalesce(p_dd_amount, 0) < 0 then
    raise exception 'The DD amount cannot be negative.' using errcode = 'check_violation';
  end if;
  if jsonb_typeof(coalesce(p_deductions, '[]'::jsonb)) <> 'array' then
    raise exception 'Deductions must be a list.' using errcode = 'check_violation';
  end if;

  -- ── Each deduction, checked before anything is written ──────────────────
  for v_ded in select * from jsonb_array_elements(coalesce(p_deductions, '[]'::jsonb)) loop
    v_amount := round(coalesce((v_ded ->> 'amount')::numeric, 0), 2);
    v_kind   := upper(coalesce(v_ded ->> 'kind', ''));
    v_by     := upper(coalesce(v_ded ->> 'borne_by', ''));
    continue when v_amount = 0;
    if v_amount < 0 then
      raise exception 'A deduction cannot be negative.' using errcode = 'check_violation';
    end if;
    if v_kind not in ('DOCUMENT_CHARGES', 'FREIGHT', 'OTHER') then
      raise exception 'A deduction is document charges, freight, or other.' using errcode = 'check_violation';
    end if;
    if v_by not in ('CUSTOMER', 'DEALER') then
      raise exception 'Say who bears the %: the customer or the dealer.', lower(replace(v_kind, '_', ' '))
        using errcode = 'check_violation';
    end if;
    if v_kind = 'OTHER' and coalesce(btrim(v_ded ->> 'note'), '') = '' then
      raise exception 'Say what the other deduction is for.' using errcode = 'check_violation';
    end if;
    v_total_d := v_total_d + v_amount;
  end loop;

  if coalesce(p_dd_amount, 0) + v_total_d <= 0 then
    raise exception 'Enter the DD amount.' using errcode = 'check_violation';
  end if;

  v_pending := coalesce(v_app.approved_amount, v_app.loan_amount) - v_app.disbursed_amount;
  if round(p_dd_amount, 2) + v_total_d > v_pending then
    raise exception 'DD % plus deductions % is more than the % still due on %.',
      round(p_dd_amount, 2), v_total_d, v_pending, v_app.application_number
      using errcode = 'check_violation';
  end if;

  if coalesce(p_dd_amount, 0) > 0 then
    select * into v_bank from public.bank_accounts
     where id = p_bank_account_id and dealer_id = v_app.dealer_id and status = 'ACTIVE';
    if v_bank.id is null then
      raise exception 'Choose the bank account the DD was deposited in.' using errcode = 'no_data_found';
    end if;
    v_lines := v_lines || jsonb_build_object(
      'account_id', v_bank.ledger_account_id, 'debit', round(p_dd_amount, 2), 'credit', 0,
      'narration', 'DD ' || coalesce(p_dd_number, '') || ' from finance company');
  end if;

  -- ── What the company kept back, charged to whoever bears it ─────────────
  for v_ded in select * from jsonb_array_elements(coalesce(p_deductions, '[]'::jsonb)) loop
    v_amount := round(coalesce((v_ded ->> 'amount')::numeric, 0), 2);
    continue when v_amount = 0;
    v_kind  := upper(v_ded ->> 'kind');
    v_by    := upper(v_ded ->> 'borne_by');
    v_label := case v_kind when 'DOCUMENT_CHARGES' then 'Document charges'
                           when 'FREIGHT' then 'Freight charges'
                           else coalesce(nullif(btrim(v_ded ->> 'note'), ''), 'Other deduction') end;

    if v_by = 'CUSTOMER' then
      v_lines := v_lines || jsonb_build_object(
        'account_id', app.require_account(v_app.dealer_id, 'SALES', 'INVOICE', 'RECEIVABLE', v_app.branch_id),
        'debit', v_amount, 'credit', 0,
        'narration', v_label || ' deducted by the financier on ' || v_app.application_number || ' — recover from customer',
        'party_type', 'CUSTOMER', 'party_id', v_app.customer_id);
      v_customer_part := v_customer_part + v_amount;
    else
      v_lines := v_lines || jsonb_build_object(
        'account_id', app.require_account(v_app.dealer_id, 'FINANCE', 'DISBURSEMENT',
          case v_kind when 'DOCUMENT_CHARGES' then 'DOCUMENT_CHARGES'
                      when 'FREIGHT' then 'FREIGHT' else 'OTHER_DEDUCTION' end, v_app.branch_id),
        'debit', v_amount, 'credit', 0,
        'narration', v_label || ' deducted by the financier on ' || v_app.application_number);
    end if;
  end loop;

  v_lines := v_lines || jsonb_build_object(
    'account_id', app.require_account(v_app.dealer_id, 'FINANCE', 'DISBURSEMENT', 'FINANCE_RECEIVABLE', v_app.branch_id),
    'debit', 0, 'credit', round(p_dd_amount, 2) + v_total_d,
    'narration', 'Settled ' || v_app.application_number || ': DD ' || round(p_dd_amount, 2)
                 || case when v_total_d > 0 then ' + deductions ' || v_total_d else '' end,
    'party_type', 'FINANCE_COMPANY', 'party_id', v_app.finance_company_id);

  v_entry := app.post_journal(
    v_app.dealer_id, v_app.branch_id, p_date, 'FINANCE',
    'Finance DD for ' || v_app.application_number
      || case when v_total_d > 0 then ' (less ' || v_total_d || ' deducted)' else '' end,
    v_lines, 'FINANCE_APPLICATION', p_application_id,
    coalesce(v_key, 'fin-dd:' || p_application_id::text || ':' || gen_random_uuid()::text));

  -- The bank book sees the DD like any other receipt.
  if coalesce(p_dd_amount, 0) > 0 then
    insert into public.bank_transactions
      (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
       reference_number, journal_entry_id, created_by)
    values
      (v_app.dealer_id, p_bank_account_id, p_date, 'RECEIPT', round(p_dd_amount, 2),
       'Finance DD ' || v_app.application_number, v_ref, v_entry, auth.uid());

    insert into public.finance_transactions
      (dealer_id, branch_id, finance_company_id, transaction_date, transaction_type,
       debit, credit, reference_type, reference_id, reference_number, narration,
       application_id, sale_id, journal_entry_id, created_by)
    values
      (v_app.dealer_id, v_app.branch_id, v_app.finance_company_id, p_date, 'DISBURSEMENT',
       round(p_dd_amount, 2), 0, 'FINANCE_APPLICATION', p_application_id,
       coalesce(p_dd_number, v_app.application_number), 'DD received', p_application_id, v_app.sale_id,
       v_entry, auth.uid());
  end if;

  -- Each deduction on the company's ledger, named.
  insert into public.finance_transactions
    (dealer_id, branch_id, finance_company_id, transaction_date, transaction_type,
     debit, credit, reference_type, reference_id, reference_number, narration,
     application_id, sale_id, journal_entry_id, created_by)
  select v_app.dealer_id, v_app.branch_id, v_app.finance_company_id, p_date, 'DEDUCTION',
         round((d ->> 'amount')::numeric, 2), 0, upper(d ->> 'kind'), p_application_id,
         v_app.application_number,
         case upper(d ->> 'kind') when 'DOCUMENT_CHARGES' then 'Document charges'
                                  when 'FREIGHT' then 'Freight charges'
                                  else coalesce(nullif(btrim(d ->> 'note'), ''), 'Other deduction') end
           || case when upper(d ->> 'borne_by') = 'CUSTOMER' then ' (to customer)' else ' (dealer cost)' end,
         p_application_id, v_app.sale_id, v_entry, auth.uid()
    from jsonb_array_elements(coalesce(p_deductions, '[]'::jsonb)) d
   where round(coalesce((d ->> 'amount')::numeric, 0), 2) > 0;

  update public.finance_applications
     set disbursed_amount  = disbursed_amount + round(p_dd_amount, 2) + v_total_d,
         deductions_amount = deductions_amount + v_total_d,
         disbursed_at      = p_date,
         dd_number         = coalesce(nullif(btrim(p_dd_number), ''), dd_number),
         bank_reference    = coalesce(nullif(btrim(p_bank_reference), ''), bank_reference),
         disbursement_status = case
           when disbursed_amount + round(p_dd_amount, 2) + v_total_d >= coalesce(approved_amount, loan_amount)
             then 'DISBURSED' else 'PARTIAL' end,
         updated_by = auth.uid()
   where id = p_application_id;

  return v_entry;
end;
$$;

comment on function public.receive_finance_dd(uuid, uuid, numeric, jsonb, text, text, date, text) is
  'Records a finance company''s DD and what it deducted (document charges, '
  'freight, other), each borne by the customer (to their ledger) or the dealer '
  '(an expense). Clears Finance Receivable by the whole amount settled. Idempotent.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.receive_finance_dd(uuid, uuid, numeric, jsonb, text, text, date, text) to authenticated';
  end if;
end $$;

insert into public.schema_migrations (version, name)
values ('0087', 'finance_dd_deductions_party_journals') on conflict (version) do nothing;


commit;
