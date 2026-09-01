-- =============================================================================
-- 0039 — Dealer-wide document numbering
-- =============================================================================
-- Spec §45, §60.3, §60.5.
--
-- Seven document types still allocate their numbers from *branch-scoped*
-- counters while the tables that store them enforce *dealer-wide* uniqueness:
--
--   sales.invoice_number            sales_invoice_key            (dealer_id, …)
--   bookings.booking_number         bookings_number_key          (dealer_id, …)
--   booking_payments.receipt_number booking_payments_receipt_key (dealer_id, …)
--   sale_payments.receipt_number    sale_payments_receipt_key    (dealer_id, …)
--   service_payments.receipt_number sp_receipt_key               (dealer_id, …)
--   job_cards.job_card_number       jc_number_key                (dealer_id, …)
--   service_invoices.invoice_number si_number_key                (dealer_id, …)
--
-- Every branch's counter starts at 1 and every branch shares the same prefix, so
-- two branches both produce INV-2026-000001 and the second one to try is
-- rejected by the constraint. A single-branch dealer never sees it; a two-branch
-- dealer hits it on the second branch's first document of each type — which is
-- the multi-branch operation spec §60.3 requires to work from day one. 0038 hit
-- exactly this for transfers and deliveries; these are the remaining seven.
--
-- FIXED HERE RATHER THAN AT EACH CALL SITE.
--
-- 0038 fixed its two types by rewriting the functions that issue them to pass a
-- null branch. Repeating that for seven types means copying six large function
-- bodies into this migration — and three of them (record_sale_payment,
-- create_job_card, deliver_vehicle) are rewritten again by later migrations for
-- unrelated reasons. Every one of those rewrites would have to carry this fix
-- forward by hand, and the day one of them does not, the bug returns silently
-- with no test to catch it.
--
-- So the scope decision moves out of the call sites and into the sequence
-- allocator, where it belongs: **the scope of a document series is a property of
-- the document type, recorded in document_sequences, not of the code that asks
-- for a number.** A dealer-wide row, where one is configured, wins over the
-- branch the caller passed. Callers are unchanged and stay correct as they are
-- rewritten in future.
--
-- A type that genuinely wants a per-branch series still gets one: simply do not
-- configure a dealer-wide row for it. Nothing in the schema wants that today.
--
-- Existing numbers are left exactly as issued, and each dealer-wide counter
-- starts above the highest number any of that dealer's branches reached, so no
-- number is ever reissued.
--
-- Rollback: restore app.next_document_number() from 0006 and delete the
--           dealer-wide rows created below from public.document_sequences.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- app.next_document_number() — dealer-wide first, branch second
-- -----------------------------------------------------------------------------
create or replace function app.next_document_number(
  p_dealer_id      uuid,
  p_branch_id      uuid,
  p_doc_type       text,
  p_financial_year text
)
returns text
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_prefix  text;
  v_padding smallint;
  v_number  bigint;
begin
  -- A dealer-wide series, when configured, is authoritative for this type. The
  -- branch the caller passed is still recorded on the document; it simply is not
  -- what allocates the number (spec §45).
  update public.document_sequences ds
     set last_number = ds.last_number + 1
   where ds.dealer_id = p_dealer_id
     and ds.branch_id is null
     and ds.doc_type = p_doc_type
     and ds.financial_year = p_financial_year
  returning ds.prefix, ds.padding, ds.last_number
       into v_prefix, v_padding, v_number;

  if not found then
    update public.document_sequences ds
       set last_number = ds.last_number + 1
     where ds.dealer_id = p_dealer_id
       and ds.branch_id is not distinct from p_branch_id
       and ds.doc_type = p_doc_type
       and ds.financial_year = p_financial_year
    returning ds.prefix, ds.padding, ds.last_number
         into v_prefix, v_padding, v_number;
  end if;

  if not found then
    raise exception
      'No document sequence configured for dealer %, branch %, type %, year %.',
      p_dealer_id, coalesce(p_branch_id::text, '(dealer-wide)'), p_doc_type, p_financial_year
      using errcode = 'no_data_found',
            hint = 'Insert a row into document_sequences before issuing this document type.';
  end if;

  return v_prefix || '-' || p_financial_year || '-' || lpad(v_number::text, v_padding, '0');
end;
$$;

comment on function app.next_document_number(uuid, uuid, text, text) is
  'Returns the next number for a document scope, e.g. INV-2026-000001. '
  'A dealer-wide sequence takes precedence over a branch one, so a series that '
  'must be unique per dealer cannot be allocated from per-branch counters '
  '(spec §45, §60.3). Row-locked, so it is safe under concurrent sales (spec §49).';

-- -----------------------------------------------------------------------------
-- Dealer-wide rows for the seven types, carrying each dealer's highest counter
-- -----------------------------------------------------------------------------
-- Derived from the sequences that already exist rather than from branches, so
-- this covers the dealer / financial-year / prefix combinations actually in use
-- and stays correct for a dealer whose financial year is not the default.
--
-- PAYMENT and COUNTER_INVOICE are included although nothing issues them yet:
-- they are seeded per branch, so they carry the same latent collision and would
-- surface it the day something does.
-- -----------------------------------------------------------------------------
insert into public.document_sequences
  (dealer_id, branch_id, doc_type, financial_year, prefix, padding, last_number)
select ds.dealer_id, null::uuid, ds.doc_type, ds.financial_year, ds.prefix, max(ds.padding),
       max(ds.last_number)
  from public.document_sequences ds
 where ds.branch_id is not null
   and ds.doc_type in ('VEHICLE_INVOICE', 'BOOKING', 'RECEIPT', 'PAYMENT',
                       'JOB_CARD', 'SERVICE_INVOICE', 'COUNTER_INVOICE')
 group by ds.dealer_id, ds.doc_type, ds.financial_year, ds.prefix
on conflict on constraint document_sequences_scope_key do nothing;

-- The branch-scoped rows are left in place but are no longer consulted for these
-- types; dropping them would discard the record of what each branch had issued.

-- -----------------------------------------------------------------------------
-- Sequences for the finance documents built in 0043
-- -----------------------------------------------------------------------------
-- Created here, with the rest of the numbering, so that migration deals only
-- with finance. Dealer-wide from the start: finance_applications.application_number
-- and finance_settlements.settlement_number are both unique per dealer.
-- -----------------------------------------------------------------------------
insert into public.document_sequences
  (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
select distinct ds.dealer_id, null::uuid, d.doc_type, ds.financial_year, d.prefix, 6
  from public.document_sequences ds
 cross join (values ('FINANCE_APPLICATION', 'FA'), ('FINANCE_SETTLEMENT', 'FS')) as d(doc_type, prefix)
 where ds.branch_id is not null
on conflict on constraint document_sequences_scope_key do nothing;
