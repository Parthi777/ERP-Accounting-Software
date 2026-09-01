-- =============================================================================
-- 0043 — Finance operations
-- =============================================================================
-- Spec §25, §26, §27.
--
-- The finance tables have existed since 0021 with no way to write to them: no
-- function creates an application, records a trade advance, or posts a
-- settlement. Everything below is that missing half.
--
-- TWO CONVENTIONS, STATED ONCE AND HELD THROUGHOUT.
--
-- 1. The company side of every posting resolves through
--    app.require_account(… FINANCE_RECEIVABLE / FINANCE_PAYABLE …) and is
--    identified by party_type = 'FINANCE_COMPANY' + party_id.
--    finance_companies.ledger_account_id is NOT used for posting. Using both
--    would split one company's balance across two accounts, and neither would
--    reconcile to the subsidiary ledger.
--
-- 2. finance_transactions is the dealer's net position with a company:
--    **positive means the company owes the dealer.** A credit increases it, a
--    debit reduces it — which is what the BEFORE INSERT trigger in 0021 already
--    computes. balance_after is never written by these functions.
--
-- Also note ft_one_sided_check: exactly one of debit/credit must be strictly
-- positive, so a zero-amount ledger row is impossible and must be skipped rather
-- than written.
--
-- Rollback: drop the six functions below; restore the ft_insert policy and
--           public.record_sale_payment from 0021 and 0028; drop
--           public.finance_settlements.branch_id.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A settlement needs a branch
-- -----------------------------------------------------------------------------
-- journal_entries.branch_id is NOT NULL, and finance_settlements had no branch
-- at all. Backfilled to the head office rather than defaulted at post time, so
-- the branch is a recorded fact rather than a guess made later.
-- -----------------------------------------------------------------------------
alter table public.finance_settlements add column if not exists branch_id uuid;

update public.finance_settlements fs
   set branch_id = (
     select b.id from public.branches b
      where b.dealer_id = fs.dealer_id
      order by b.is_head_office desc, b.code
      limit 1)
 where fs.branch_id is null;

do $$
begin
  if exists (select 1 from public.finance_settlements where branch_id is null) then
    raise notice 'finance_settlements rows without a branch remain; leaving column nullable.';
  else
    execute 'alter table public.finance_settlements alter column branch_id set not null';
  end if;
end;
$$;

alter table public.finance_settlements
  add constraint fs_branch_tenant_fkey
  foreign key (branch_id, dealer_id) references public.branches (id, dealer_id);

-- -----------------------------------------------------------------------------
-- The insert policy has to admit the role that disburses
-- -----------------------------------------------------------------------------
-- ft_insert listed trade_advance.manage, settlements.manage and sales.post but
-- not finance.applications.manage — so disbursing an application, which is
-- exactly what that permission is for, was refused by RLS.
-- -----------------------------------------------------------------------------
drop policy if exists ft_insert on public.finance_transactions;

create policy ft_insert on public.finance_transactions
  for insert to authenticated
  with check (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and (app.has_permission('finance.trade_advance.manage')
             or app.has_permission('finance.settlements.manage')
             or app.has_permission('finance.applications.manage')
             or app.has_permission('sales.post')))
  );

comment on column public.finance_companies.ledger_account_id is
  'Reporting hint only. Posting resolves accounts through accounting_rules '
  '(spec §22); see 0043.';

-- -----------------------------------------------------------------------------
-- public.create_finance_application() — spec §27
-- -----------------------------------------------------------------------------
-- No journal: an application is a request, not a transaction. Nothing is owed
-- until the finance company approves and disburses.
-- -----------------------------------------------------------------------------
create or replace function public.create_finance_application(
  p_branch_id          uuid,
  p_customer_id        uuid,
  p_finance_company_id uuid,
  p_loan_amount        numeric,
  p_down_payment       numeric default 0,
  p_vehicle_id         uuid default null,
  p_sale_id            uuid default null,
  p_tenure_months      smallint default null,
  p_interest_rate      numeric default null,
  p_commission_amount  numeric default 0,
  p_application_date   date default current_date,
  p_notes              text default null
)
returns table (application_id uuid, application_number text)
language plpgsql
as $$
declare
  v_dealer uuid;
  v_number text;
  v_id     uuid;
begin
  if p_loan_amount <= 0 then
    raise exception 'The loan amount must be greater than zero.' using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  v_number := app.next_document_number(
    v_dealer, p_branch_id, 'FINANCE_APPLICATION',
    app.financial_year_token(v_dealer, p_application_date));

  insert into public.finance_applications
    (dealer_id, branch_id, application_number, application_date, customer_id,
     finance_company_id, vehicle_id, sale_id, loan_amount, down_payment,
     tenure_months, interest_rate, commission_amount, notes, created_by)
  values
    (v_dealer, p_branch_id, v_number, p_application_date, p_customer_id,
     p_finance_company_id, p_vehicle_id, p_sale_id, p_loan_amount, p_down_payment,
     p_tenure_months, p_interest_rate, coalesce(p_commission_amount, 0), p_notes, auth.uid())
  returning id into v_id;

  application_id := v_id; application_number := v_number;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.decide_finance_application() — approve or reject
-- -----------------------------------------------------------------------------
create or replace function public.decide_finance_application(
  p_application_id  uuid,
  p_decision        text,
  p_approved_amount numeric default null,
  p_rejection_reason text default null
)
returns void
language plpgsql
as $$
declare
  v_app public.finance_applications;
begin
  select * into v_app from public.finance_applications where id = p_application_id for update;

  if v_app.id is null then
    raise exception 'Application not found.' using errcode = 'no_data_found';
  end if;
  if v_app.approval_status <> 'PENDING' then
    raise exception 'Application % is already %.', v_app.application_number, v_app.approval_status
      using errcode = 'check_violation';
  end if;
  if p_decision not in ('APPROVED', 'REJECTED', 'CANCELLED') then
    raise exception 'The decision must be APPROVED, REJECTED or CANCELLED.'
      using errcode = 'check_violation';
  end if;

  -- Mirrors fa_approved_amount_check and fa_rejection_check, so the caller gets
  -- a sentence rather than a constraint violation.
  if p_decision = 'APPROVED' and p_approved_amount is null then
    raise exception 'An approval must state the amount approved.'
      using errcode = 'check_violation';
  end if;
  if p_decision = 'REJECTED' and coalesce(btrim(p_rejection_reason), '') = '' then
    raise exception 'A rejection must state a reason.'
      using errcode = 'check_violation';
  end if;

  update public.finance_applications
     set approval_status  = p_decision,
         approved_amount  = case when p_decision = 'APPROVED' then p_approved_amount else approved_amount end,
         approved_at      = case when p_decision = 'APPROVED' then now() else approved_at end,
         rejection_reason = case when p_decision = 'REJECTED' then btrim(p_rejection_reason) else rejection_reason end,
         disbursement_status = case when p_decision in ('REJECTED', 'CANCELLED') then 'CANCELLED'
                                    else disbursement_status end,
         updated_by = auth.uid()
   where id = p_application_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.disburse_finance_application() — spec §27
-- -----------------------------------------------------------------------------
-- Money arrives from the finance company against a vehicle already invoiced, so
-- the finance receivable clears and the bank rises. The bank book gets its row
-- in the same transaction, or the money would be in the ledger and not in the
-- bank book.
-- -----------------------------------------------------------------------------
create or replace function public.disburse_finance_application(
  p_application_id  uuid,
  p_amount          numeric,
  p_bank_account_id uuid,
  p_dd_number       text default null,
  p_bank_reference  text default null,
  p_date            date default current_date
)
-- Two ledger rows are written, so both ids are returned by name. A single
-- "transaction_id" would leave the caller guessing which one it held.
returns table (journal_entry_id uuid, bank_transaction_id bigint, finance_transaction_id bigint)
language plpgsql
as $$
declare
  v_app     public.finance_applications;
  v_bank    public.bank_accounts;
  v_entry   uuid;
  v_txn     bigint;
  v_fin     bigint;
  v_debit   uuid;
  v_credit  uuid;
  v_pending numeric(18, 4);
begin
  if p_amount <= 0 then
    raise exception 'The amount must be greater than zero.' using errcode = 'check_violation';
  end if;

  select * into v_app from public.finance_applications where id = p_application_id for update;
  if v_app.id is null then
    raise exception 'Application not found.' using errcode = 'no_data_found';
  end if;
  if v_app.approval_status <> 'APPROVED' then
    raise exception 'Application % is % — only an approved application can be disbursed.',
      v_app.application_number, v_app.approval_status using errcode = 'check_violation';
  end if;

  v_pending := coalesce(v_app.approved_amount, v_app.loan_amount) - v_app.disbursed_amount;
  if p_amount > v_pending then
    raise exception 'Only % is still to be disbursed on %.', v_pending, v_app.application_number
      using errcode = 'check_violation';
  end if;

  select * into v_bank from public.bank_accounts where id = p_bank_account_id;
  if v_bank.id is null then
    raise exception 'Bank account not found.' using errcode = 'no_data_found';
  end if;

  v_debit  := coalesce(v_bank.ledger_account_id,
                       app.require_account(v_app.dealer_id, 'FINANCE', 'DISBURSEMENT', 'BANK', v_app.branch_id));
  v_credit := app.require_account(v_app.dealer_id, 'FINANCE', 'DISBURSEMENT', 'FINANCE_RECEIVABLE', v_app.branch_id);

  v_entry := app.post_journal(
    v_app.dealer_id, v_app.branch_id, p_date, 'FINANCE',
    'Disbursement against ' || v_app.application_number,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', 'Received from finance company'),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', 'Against ' || v_app.application_number,
                         'party_type', 'FINANCE_COMPANY', 'party_id', v_app.finance_company_id)
    ),
    'FINANCE_APPLICATION', p_application_id,
    'fin-disb:' || p_application_id::text || ':' || p_amount::text || ':' || p_date::text
  );

  -- The bank book and reconciliation must see this like any other credit.
  insert into public.bank_transactions
    (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
     reference_number, journal_entry_id, created_by)
  values
    (v_app.dealer_id, p_bank_account_id, p_date, 'RECEIPT', p_amount,
     'Finance disbursement ' || v_app.application_number,
     coalesce(p_bank_reference, p_dd_number), v_entry, auth.uid())
  returning id into v_txn;

  -- Debit: the company owed the dealer and has now paid, so the position falls.
  insert into public.finance_transactions
    (dealer_id, branch_id, finance_company_id, transaction_date, transaction_type,
     debit, credit, reference_type, reference_id, reference_number, narration,
     application_id, sale_id, journal_entry_id, created_by)
  values
    (v_app.dealer_id, v_app.branch_id, v_app.finance_company_id, p_date, 'DISBURSEMENT',
     p_amount, 0, 'FINANCE_APPLICATION', p_application_id, v_app.application_number,
     'Disbursement received', p_application_id, v_app.sale_id, v_entry, auth.uid())
  returning id into v_fin;

  update public.finance_applications
     set disbursed_amount = disbursed_amount + p_amount,
         disbursed_at = p_date,
         dd_number = coalesce(p_dd_number, dd_number),
         bank_reference = coalesce(p_bank_reference, bank_reference),
         disbursement_status = case
           when disbursed_amount + p_amount >= coalesce(approved_amount, loan_amount) then 'DISBURSED'
           else 'PARTIAL' end,
         updated_by = auth.uid()
   where id = p_application_id;

  journal_entry_id := v_entry; bank_transaction_id := v_txn; finance_transaction_id := v_fin;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_trade_advance() — spec §26
-- -----------------------------------------------------------------------------
-- Six transaction types, each with its own pair of accounts. The mapping is
-- declared here rather than left to the caller so a trade advance cannot be
-- posted to whatever account someone picked in a form.
-- -----------------------------------------------------------------------------
create or replace function public.record_trade_advance(
  p_finance_company_id uuid,
  p_branch_id          uuid,
  p_type               text,
  p_amount             numeric,
  p_bank_account_id    uuid default null,
  p_date               date default current_date,
  p_narration          text default null,
  p_reference          text default null
)
returns table (transaction_id bigint, journal_entry_id uuid)
language plpgsql
as $$
declare
  v_dealer  uuid;
  v_company public.finance_companies;
  v_bank    public.bank_accounts;
  v_bank_acc uuid;
  v_debit   uuid;
  v_credit  uuid;
  v_entry   uuid;
  v_txn     bigint;
  v_debit_amt  numeric(18, 4) := 0;
  v_credit_amt numeric(18, 4) := 0;
  v_narration text;
begin
  -- ft_one_sided_check forbids a zero row, so this is not merely tidiness.
  if p_amount <= 0 then
    raise exception 'The amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if p_type not in ('ADVANCE_RECEIVED', 'VEHICLE_ADJUSTMENT', 'SETTLEMENT',
                    'REFUND', 'COMMISSION', 'MANUAL_ADJUSTMENT') then
    raise exception 'Unknown trade advance type %.', p_type using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  select * into v_company from public.finance_companies where id = p_finance_company_id;
  if v_company.id is null then
    raise exception 'Finance company not found.' using errcode = 'no_data_found';
  end if;

  if p_bank_account_id is not null then
    select * into v_bank from public.bank_accounts where id = p_bank_account_id;
  end if;

  v_narration := coalesce(p_narration, replace(initcap(replace(p_type, '_', ' ')), ' ', ' ')
                          || ' — ' || v_company.name);

  -- Money in or out needs a bank account; the internal moves do not.
  if p_type in ('ADVANCE_RECEIVED', 'SETTLEMENT', 'REFUND') and v_bank.id is null then
    raise exception 'A % needs the bank account the money moved through.', lower(replace(p_type, '_', ' '))
      using errcode = 'check_violation';
  end if;

  v_bank_acc := v_bank.ledger_account_id;

  if p_type = 'ADVANCE_RECEIVED' then
    -- The company funds the dealer ahead of sales: cash in, liability up.
    v_debit  := coalesce(v_bank_acc, app.require_account(v_dealer, 'TRADE_ADVANCE', 'RECEIVED', 'BANK', p_branch_id));
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'RECEIVED', 'FINANCE_PAYABLE', p_branch_id);
    v_debit_amt := p_amount;          -- the dealer holds their money, so the position falls
  elsif p_type = 'VEHICLE_ADJUSTMENT' then
    -- An advance is consumed by a vehicle the company financed.
    v_debit  := app.require_account(v_dealer, 'TRADE_ADVANCE', 'ADJUSTMENT', 'FINANCE_PAYABLE', p_branch_id);
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'ADJUSTMENT', 'FINANCE_RECEIVABLE', p_branch_id);
    v_credit_amt := p_amount;
  elsif p_type = 'SETTLEMENT' then
    v_debit  := coalesce(v_bank_acc, app.require_account(v_dealer, 'TRADE_ADVANCE', 'SETTLEMENT', 'BANK', p_branch_id));
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'SETTLEMENT', 'FINANCE_RECEIVABLE', p_branch_id);
    v_debit_amt := p_amount;
  elsif p_type = 'REFUND' then
    v_debit  := app.require_account(v_dealer, 'TRADE_ADVANCE', 'REFUND', 'FINANCE_PAYABLE', p_branch_id);
    v_credit := coalesce(v_bank_acc, app.require_account(v_dealer, 'TRADE_ADVANCE', 'REFUND', 'BANK', p_branch_id));
    v_credit_amt := p_amount;
  elsif p_type = 'COMMISSION' then
    v_debit  := app.require_account(v_dealer, 'TRADE_ADVANCE', 'COMMISSION', 'FINANCE_RECEIVABLE', p_branch_id);
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'COMMISSION', 'COMMISSION_INCOME', p_branch_id);
    v_credit_amt := p_amount;         -- earned but unpaid: the company owes more
  else -- MANUAL_ADJUSTMENT
    v_debit  := app.require_account(v_dealer, 'TRADE_ADVANCE', 'MANUAL_ADJUSTMENT', 'FINANCE_RECEIVABLE', p_branch_id);
    v_credit := app.require_account(v_dealer, 'TRADE_ADVANCE', 'MANUAL_ADJUSTMENT', 'FINANCE_PAYABLE', p_branch_id);
    v_credit_amt := p_amount;
  end if;

  v_entry := app.post_journal(
    v_dealer, p_branch_id, p_date, 'TRADE_ADVANCE', v_narration,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', v_narration,
                         'party_type', 'FINANCE_COMPANY', 'party_id', p_finance_company_id),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', v_narration,
                         'party_type', 'FINANCE_COMPANY', 'party_id', p_finance_company_id)
    ),
    'TRADE_ADVANCE', null, null
  );

  insert into public.finance_transactions
    (dealer_id, branch_id, finance_company_id, transaction_date, transaction_type,
     debit, credit, reference_type, reference_number, narration, journal_entry_id, created_by)
  values
    (v_dealer, p_branch_id, p_finance_company_id, p_date, p_type,
     v_debit_amt, v_credit_amt, 'TRADE_ADVANCE', p_reference, v_narration, v_entry, auth.uid())
  returning id into v_txn;

  -- Money that moved through a bank account belongs in the bank book too.
  if v_bank.id is not null and p_type in ('ADVANCE_RECEIVED', 'SETTLEMENT', 'REFUND') then
    insert into public.bank_transactions
      (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
       reference_number, journal_entry_id, created_by)
    values
      (v_dealer, p_bank_account_id, p_date,
       case when p_type = 'REFUND' then 'PAYMENT' else 'RECEIPT' end,
       p_amount, v_narration, p_reference, v_entry, auth.uid());
  end if;

  transaction_id := v_txn; journal_entry_id := v_entry;
  return next;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.create_finance_settlement() / post_finance_settlement() — spec §26
-- -----------------------------------------------------------------------------
create or replace function public.create_finance_settlement(
  p_finance_company_id uuid,
  p_branch_id          uuid,
  p_from               date,
  p_to                 date,
  p_gross              numeric,
  p_commission         numeric default 0,
  p_deductions         numeric default 0,
  p_settlement_date    date default current_date,
  p_notes              text default null
)
returns table (settlement_id uuid, settlement_number text)
language plpgsql
as $$
declare
  v_dealer uuid;
  v_number text;
  v_id     uuid;
begin
  if p_gross <= 0 then
    raise exception 'The gross amount must be greater than zero.' using errcode = 'check_violation';
  end if;
  if coalesce(p_commission, 0) + coalesce(p_deductions, 0) > p_gross then
    raise exception 'Commission and deductions cannot exceed the gross amount.'
      using errcode = 'check_violation';
  end if;

  select dealer_id into v_dealer from public.branches where id = p_branch_id;
  if v_dealer is null then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;

  v_number := app.next_document_number(
    v_dealer, p_branch_id, 'FINANCE_SETTLEMENT',
    app.financial_year_token(v_dealer, p_settlement_date));

  insert into public.finance_settlements
    (dealer_id, branch_id, finance_company_id, settlement_number, settlement_date,
     from_date, to_date, gross_amount, commission_amount, deductions, notes, created_by)
  values
    (v_dealer, p_branch_id, p_finance_company_id, v_number, p_settlement_date,
     p_from, p_to, p_gross, coalesce(p_commission, 0), coalesce(p_deductions, 0),
     p_notes, auth.uid())
  returning id into v_id;

  settlement_id := v_id; settlement_number := v_number;
  return next;
end;
$$;

create or replace function public.post_finance_settlement(
  p_settlement_id   uuid,
  p_bank_account_id uuid
)
returns uuid
language plpgsql
as $$
declare
  v_s      public.finance_settlements;
  v_bank   public.bank_accounts;
  v_lines  jsonb;
  v_entry  uuid;
  v_bank_acc uuid;
begin
  select * into v_s from public.finance_settlements where id = p_settlement_id for update;
  if v_s.id is null then
    raise exception 'Settlement not found.' using errcode = 'no_data_found';
  end if;
  if v_s.status <> 'DRAFT' then
    raise exception 'Settlement % is % and cannot be posted again.', v_s.settlement_number, v_s.status
      using errcode = 'check_violation';
  end if;

  select * into v_bank from public.bank_accounts where id = p_bank_account_id;
  if v_bank.id is null then
    raise exception 'Bank account not found.' using errcode = 'no_data_found';
  end if;

  v_bank_acc := coalesce(v_bank.ledger_account_id,
                         app.require_account(v_s.dealer_id, 'TRADE_ADVANCE', 'SETTLEMENT', 'BANK', v_s.branch_id));

  -- The receivable clears at gross; what the company withheld is the difference
  -- between gross and what reached the bank. A zero commission or deduction adds
  -- no line: an empty line is noise in the journal and would be rejected as a
  -- finance_transactions row.
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_bank_acc, 'debit', v_s.net_amount, 'credit', 0,
                       'narration', 'Settlement ' || v_s.settlement_number)
  );

  if v_s.commission_amount > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', app.require_account(v_s.dealer_id, 'TRADE_ADVANCE', 'SETTLEMENT', 'COMMISSION', v_s.branch_id),
      'debit', v_s.commission_amount, 'credit', 0, 'narration', 'Commission withheld'));
  end if;

  if v_s.deductions > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', app.require_account(v_s.dealer_id, 'TRADE_ADVANCE', 'SETTLEMENT', 'DEDUCTION', v_s.branch_id),
      'debit', v_s.deductions, 'credit', 0, 'narration', 'Deductions'));
  end if;

  v_lines := v_lines || jsonb_build_array(jsonb_build_object(
    'account_id', app.require_account(v_s.dealer_id, 'TRADE_ADVANCE', 'SETTLEMENT', 'FINANCE_RECEIVABLE', v_s.branch_id),
    'debit', 0, 'credit', v_s.gross_amount, 'narration', 'Settled ' || v_s.settlement_number,
    'party_type', 'FINANCE_COMPANY', 'party_id', v_s.finance_company_id));

  v_entry := app.post_journal(
    v_s.dealer_id, v_s.branch_id, v_s.settlement_date, 'TRADE_ADVANCE',
    'Settlement ' || v_s.settlement_number, v_lines,
    'FINANCE_SETTLEMENT', p_settlement_id, 'fin-settle:' || p_settlement_id::text
  );

  insert into public.finance_transactions
    (dealer_id, branch_id, finance_company_id, transaction_date, transaction_type,
     debit, credit, reference_type, reference_id, reference_number, narration,
     journal_entry_id, created_by)
  values
    (v_s.dealer_id, v_s.branch_id, v_s.finance_company_id, v_s.settlement_date, 'SETTLEMENT',
     v_s.gross_amount, 0, 'FINANCE_SETTLEMENT', p_settlement_id, v_s.settlement_number,
     'Settlement posted', v_entry, auth.uid());

  insert into public.bank_transactions
    (dealer_id, bank_account_id, transaction_date, direction, amount, particular,
     reference_number, journal_entry_id, created_by)
  values
    (v_s.dealer_id, p_bank_account_id, v_s.settlement_date, 'RECEIPT', v_s.net_amount,
     'Settlement ' || v_s.settlement_number, v_s.settlement_number, v_entry, auth.uid());

  update public.finance_settlements
     set status = 'POSTED', journal_entry_id = v_entry
   where id = p_settlement_id;

  return v_entry;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.create_finance_application(uuid, uuid, uuid, numeric, numeric, uuid, uuid, smallint, numeric, numeric, date, text) to authenticated';
    execute 'grant execute on function public.decide_finance_application(uuid, text, numeric, text) to authenticated';
    execute 'grant execute on function public.disburse_finance_application(uuid, numeric, uuid, text, text, date) to authenticated';
    execute 'grant execute on function public.record_trade_advance(uuid, uuid, text, numeric, uuid, date, text, text) to authenticated';
    execute 'grant execute on function public.create_finance_settlement(uuid, uuid, date, date, numeric, numeric, numeric, date, text) to authenticated';
    execute 'grant execute on function public.post_finance_settlement(uuid, uuid) to authenticated';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.record_sale_payment() — name the finance company on the receivable
-- -----------------------------------------------------------------------------
-- A sale settled by finance debits Finance Receivable, but the line carried no
-- party, so account 1400 held a total with no subsidiary detail behind it and
-- the company ledger could not see money owed against its own vehicles.
--
-- Only the party tagging and the VEHICLE_ADJUSTMENT row are new; the body is
-- otherwise 0028's. The numbering is untouched because 0039 fixed scope inside
-- app.next_document_number() rather than at each call site, so there is no
-- earlier fix here to carry forward.
-- -----------------------------------------------------------------------------
create or replace function public.record_sale_payment(
  p_sale_id      uuid,
  p_amount       numeric,
  p_payment_mode text,
  p_reference    text default null,
  p_finance_company_id uuid default null
)
returns table (receipt_number text, journal_entry_id uuid)
language plpgsql
as $$
declare
  v_sale     public.sales;
  v_year     text;
  v_rnumber  text;
  v_entry    uuid;
  v_debit    uuid;
  v_credit   uuid;
  v_component text;
  v_party    text;
  v_party_id uuid;
begin
  if p_amount <= 0 then
    raise exception 'The payment amount must be greater than zero.' using errcode = 'check_violation';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;
  if v_sale.id is null then
    raise exception 'Sale not found.' using errcode = 'no_data_found';
  end if;
  if v_sale.status not in ('POSTED', 'DELIVERED') then
    raise exception 'Payments can only be recorded against a posted invoice; this one is %.', v_sale.status
      using errcode = 'check_violation';
  end if;

  v_year := app.financial_year_token(v_sale.dealer_id, current_date);
  v_rnumber := app.next_document_number(v_sale.dealer_id, v_sale.branch_id, 'RECEIPT', v_year);

  -- Finance disbursement moves the debt to the finance company rather than
  -- settling it in cash (spec §27).
  if p_payment_mode = 'FINANCE' then
    if p_finance_company_id is null then
      raise exception 'A finance payment must name the finance company carrying the debt.'
        using errcode = 'check_violation';
    end if;
    v_component := 'FINANCE_RECEIVABLE';
    v_debit  := app.require_account(v_sale.dealer_id, 'FINANCE', 'INVOICE', 'FINANCE_RECEIVABLE', v_sale.branch_id);
    v_party := 'FINANCE_COMPANY';
    v_party_id := p_finance_company_id;
  else
    v_component := case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end;
    v_debit := app.require_account(
      v_sale.dealer_id,
      case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
      'RECEIPT', v_component, v_sale.branch_id);
  end if;

  v_credit := app.require_account(v_sale.dealer_id, 'SALES', 'INVOICE', 'RECEIVABLE', v_sale.branch_id);

  v_entry := app.post_journal(
    v_sale.dealer_id, v_sale.branch_id, current_date,
    case when p_payment_mode = 'CASH' then 'CASH' else 'BANK' end,
    'Receipt ' || v_rnumber || ' against ' || v_sale.invoice_number,
    jsonb_build_array(
      jsonb_build_object('account_id', v_debit, 'debit', p_amount, 'credit', 0,
                         'narration', p_payment_mode || ' received',
                         'party_type', v_party, 'party_id', v_party_id),
      jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', p_amount,
                         'narration', 'Against ' || v_sale.invoice_number,
                         'party_type', 'CUSTOMER', 'party_id', v_sale.customer_id)
    ),
    'SALE_PAYMENT', p_sale_id, 'receipt:' || v_rnumber
  );

  insert into public.sale_payments
    (dealer_id, sale_id, receipt_number, amount, payment_mode, reference,
     finance_company_id, journal_entry_id, created_by)
  values
    (v_sale.dealer_id, p_sale_id, v_rnumber, p_amount, p_payment_mode, p_reference,
     p_finance_company_id, v_entry, auth.uid());

  -- The company now owes the dealer for this vehicle, so its position rises.
  if p_payment_mode = 'FINANCE' then
    insert into public.finance_transactions
      (dealer_id, branch_id, finance_company_id, transaction_date, transaction_type,
       debit, credit, reference_type, reference_id, reference_number, narration,
       sale_id, journal_entry_id, created_by)
    values
      (v_sale.dealer_id, v_sale.branch_id, p_finance_company_id, current_date, 'VEHICLE_ADJUSTMENT',
       0, p_amount, 'SALE', p_sale_id, v_sale.invoice_number,
       'Financed ' || v_sale.invoice_number, p_sale_id, v_entry, auth.uid());
  end if;

  receipt_number := v_rnumber; journal_entry_id := v_entry;
  return next;
end;
$$;
