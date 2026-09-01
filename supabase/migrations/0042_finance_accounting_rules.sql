-- =============================================================================
-- 0042 — Accounting rules for the remaining finance events
-- =============================================================================
-- Spec §22, §25, §26.
--
-- 0027 seeded FINANCE (DISBURSEMENT, INVOICE, COMMISSION) and TRADE_ADVANCE
-- (RECEIVED, ADJUSTMENT). Spec §26 lists six trade-advance transaction types and
-- finance_transactions.ft_type_check allows seven; four of them have no account
-- mapping, so posting one would fail at app.require_account() with "No accounting
-- rule for …". These are the missing four.
--
-- Added as a second seeder rather than by rewriting the 0027 function, so the
-- eighty rows of existing mappings are not duplicated into this file where the
-- two copies could drift. Both are idempotent and neither overwrites a mapping a
-- dealer has repointed deliberately.
--
-- Rollback: drop function app.seed_finance_accounting_rules(uuid); and
--           delete from public.accounting_rules
--            where module = 'TRADE_ADVANCE'
--              and event in ('SETTLEMENT', 'REFUND', 'COMMISSION', 'MANUAL_ADJUSTMENT');
-- =============================================================================

create or replace function app.seed_finance_accounting_rules(p_dealer_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_inserted integer := 0;
begin
  insert into public.accounting_rules (dealer_id, module, event, component, side, account_id, description)
  select p_dealer_id, r.module, r.event, r.component, r.side, c.id, 'Default mapping'
    from (values
      -- Settlement: the finance company pays what it owes. The receivable
      -- clears at gross; commission and deductions they withheld are the
      -- difference between gross and what actually arrived in the bank.
      ('TRADE_ADVANCE', 'SETTLEMENT', 'BANK',               'DEBIT',  '1200'),
      ('TRADE_ADVANCE', 'SETTLEMENT', 'FINANCE_RECEIVABLE', 'CREDIT', '1400'),
      ('TRADE_ADVANCE', 'SETTLEMENT', 'COMMISSION',         'DEBIT',  '5900'),
      ('TRADE_ADVANCE', 'SETTLEMENT', 'DEDUCTION',          'DEBIT',  '5900'),

      -- Refund: unused advance goes back, so the payable the dealer held clears.
      ('TRADE_ADVANCE', 'REFUND', 'FINANCE_PAYABLE', 'DEBIT',  '2600'),
      ('TRADE_ADVANCE', 'REFUND', 'BANK',            'CREDIT', '1200'),

      -- Commission earned but not yet received is receivable, not cash.
      ('TRADE_ADVANCE', 'COMMISSION', 'FINANCE_RECEIVABLE', 'DEBIT',  '1400'),
      ('TRADE_ADVANCE', 'COMMISSION', 'COMMISSION_INCOME',  'CREDIT', '4500'),

      -- A manual correction moves value between the two finance accounts. It
      -- exists because the ledger is append-only: a mistake is corrected by a
      -- further entry, never by editing the original (spec §23).
      ('TRADE_ADVANCE', 'MANUAL_ADJUSTMENT', 'FINANCE_RECEIVABLE', 'DEBIT',  '1400'),
      ('TRADE_ADVANCE', 'MANUAL_ADJUSTMENT', 'FINANCE_PAYABLE',    'CREDIT', '2600')
    ) as r(module, event, component, side, account_code)
    join public.chart_of_accounts c
      on c.dealer_id = p_dealer_id and c.code = r.account_code
   -- Leave an existing mapping alone: a dealer may have repointed it deliberately.
   where not exists (
     select 1 from public.accounting_rules ar
      where ar.dealer_id = p_dealer_id
        and ar.module = r.module and ar.event = r.event and ar.component = r.component
        and ar.branch_id is null
   );

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;

comment on function app.seed_finance_accounting_rules(uuid) is
  'Installs the trade-advance mappings spec §26 needs beyond those in 0027 '
  '(spec §22). Idempotent: customised rules are never overwritten.';

-- Apply to every dealer that already exists.
do $$
declare
  d record;
begin
  for d in select id from public.dealers loop
    perform app.seed_finance_accounting_rules(d.id);
  end loop;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function app.seed_finance_accounting_rules(uuid) to authenticated';
  end if;
end;
$$;
