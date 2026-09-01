-- =============================================================================
-- 0027 — Default accounting rules
-- =============================================================================
-- Spec §22 requires account mapping to be configuration rather than code, and
-- 0024 provides the table. But an unconfigured dealer cannot post anything: the
-- posting engine refuses rather than guessing, which is correct and also means a
-- fresh install has a sales screen that always errors.
--
-- This installs a sensible default mapping against the standard chart of accounts
-- from seed.sql, so posting works out of the box. Every rule remains editable —
-- a dealer whose chart differs simply repoints them.
--
-- Idempotent: existing rules are left alone, so a dealer who has customised a
-- mapping does not have it overwritten by a later run.
--
-- Rollback: delete from public.accounting_rules where description = 'Default mapping';
-- =============================================================================

create or replace function app.seed_default_accounting_rules(p_dealer_id uuid)
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
      -- Vehicle sale (spec §20, §22). Each invoice component posts to its own
      -- account, which is why the price is held as components rather than a
      -- single on-road figure.
      ('SALES', 'INVOICE', 'RECEIVABLE',   'DEBIT',  '1300'),
      ('SALES', 'INVOICE', 'VEHICLE',      'CREDIT', '4100'),
      ('SALES', 'INVOICE', 'ACCESSORY',    'CREDIT', '4200'),
      ('SALES', 'INVOICE', 'FITTING',      'CREDIT', '4200'),
      ('SALES', 'INVOICE', 'SPARE',        'CREDIT', '4300'),
      ('SALES', 'INVOICE', 'LABOUR',       'CREDIT', '4400'),
      ('SALES', 'INVOICE', 'INSURANCE',    'CREDIT', '4800'),
      ('SALES', 'INVOICE', 'REGISTRATION', 'CREDIT', '4800'),
      ('SALES', 'INVOICE', 'FORWARDING',   'CREDIT', '4700'),
      ('SALES', 'INVOICE', 'OTHER_CHARGE', 'CREDIT', '4800'),
      ('SALES', 'INVOICE', 'DISCOUNT',     'DEBIT',  '4100'),
      ('SALES', 'INVOICE', 'CGST',         'CREDIT', '2300'),
      ('SALES', 'INVOICE', 'SGST',         'CREDIT', '2400'),
      ('SALES', 'INVOICE', 'IGST',         'CREDIT', '2500'),
      ('SALES', 'INVOICE', 'COGS',         'DEBIT',  '5100'),
      ('SALES', 'INVOICE', 'INVENTORY',    'CREDIT', '1500'),

      -- Booking advance (spec §18): a booking is money held, not revenue earned.
      ('BOOKING', 'ADVANCE', 'CASH',             'DEBIT',  '1100'),
      ('BOOKING', 'ADVANCE', 'BANK',             'DEBIT',  '1200'),
      ('BOOKING', 'ADVANCE', 'CUSTOMER_ADVANCE', 'CREDIT', '2100'),
      -- Applying the advance against an invoice clears the liability.
      ('BOOKING', 'APPLY',   'CUSTOMER_ADVANCE', 'DEBIT',  '2100'),
      ('BOOKING', 'APPLY',   'RECEIVABLE',       'CREDIT', '1300'),

      -- Service and counter sales (spec §32, §33).
      ('SERVICE', 'INVOICE', 'RECEIVABLE',   'DEBIT',  '1300'),
      ('SERVICE', 'INVOICE', 'LABOUR',       'CREDIT', '4400'),
      ('SERVICE', 'INVOICE', 'SPARE',        'CREDIT', '4300'),
      ('SERVICE', 'INVOICE', 'ACCESSORY',    'CREDIT', '4200'),
      ('SERVICE', 'INVOICE', 'OTHER_CHARGE', 'CREDIT', '4800'),
      ('SERVICE', 'INVOICE', 'CGST',         'CREDIT', '2300'),
      ('SERVICE', 'INVOICE', 'SGST',         'CREDIT', '2400'),
      ('SERVICE', 'INVOICE', 'IGST',         'CREDIT', '2500'),
      ('SERVICE', 'INVOICE', 'COGS',         'DEBIT',  '5300'),
      ('SERVICE', 'INVOICE', 'INVENTORY',    'CREDIT', '1700'),

      -- Cash and bank movements.
      ('CASH', 'RECEIPT', 'CASH',       'DEBIT',  '1100'),
      ('CASH', 'RECEIPT', 'RECEIVABLE', 'CREDIT', '1300'),
      ('CASH', 'PAYMENT', 'CASH',       'CREDIT', '1100'),
      ('CASH', 'PAYMENT', 'PAYABLE',    'DEBIT',  '2200'),
      ('BANK', 'RECEIPT', 'BANK',       'DEBIT',  '1200'),
      ('BANK', 'RECEIPT', 'RECEIVABLE', 'CREDIT', '1300'),
      ('BANK', 'PAYMENT', 'BANK',       'CREDIT', '1200'),
      ('BANK', 'PAYMENT', 'PAYABLE',    'DEBIT',  '2200'),

      -- Finance: disbursement settles the receivable; commission is income.
      ('FINANCE', 'DISBURSEMENT', 'BANK',               'DEBIT',  '1200'),
      ('FINANCE', 'DISBURSEMENT', 'FINANCE_RECEIVABLE', 'CREDIT', '1400'),
      ('FINANCE', 'INVOICE',      'FINANCE_RECEIVABLE', 'DEBIT',  '1400'),
      ('FINANCE', 'COMMISSION',   'BANK',               'DEBIT',  '1200'),
      ('FINANCE', 'COMMISSION',   'COMMISSION_INCOME',  'CREDIT', '4500'),

      -- Trade advance from a finance company (spec §26).
      ('TRADE_ADVANCE', 'RECEIVED',   'BANK',            'DEBIT',  '1200'),
      ('TRADE_ADVANCE', 'RECEIVED',   'FINANCE_PAYABLE', 'CREDIT', '2600'),
      ('TRADE_ADVANCE', 'ADJUSTMENT', 'FINANCE_PAYABLE', 'DEBIT',  '2600'),
      ('TRADE_ADVANCE', 'ADJUSTMENT', 'FINANCE_RECEIVABLE', 'CREDIT', '1400'),

      -- Stock receipt from a supplier.
      ('INVENTORY', 'PURCHASE', 'INVENTORY', 'DEBIT',  '1600'),
      ('INVENTORY', 'PURCHASE', 'PAYABLE',   'CREDIT', '2200'),
      ('INVENTORY', 'PURCHASE', 'VEHICLE_INVENTORY', 'DEBIT', '1500')
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

comment on function app.seed_default_accounting_rules(uuid) is
  'Installs the default account mapping for a dealer against the standard chart '
  'of accounts (spec §22). Idempotent: customised rules are never overwritten.';

-- Apply to every dealer that already exists.
do $$
declare
  d record;
  n integer;
begin
  for d in select id, code from public.dealers loop
    n := app.seed_default_accounting_rules(d.id);
    raise notice 'Dealer %: % default accounting rule(s) installed.', d.code, n;
  end loop;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function app.seed_default_accounting_rules(uuid) to authenticated';
  end if;
end;
$$;
