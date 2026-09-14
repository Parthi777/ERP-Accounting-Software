-- =============================================================================
-- post-migration-check.sql — did the migration land?
-- =============================================================================
-- Read-only. Paste into the Supabase SQL Editor, or:
--   psql "$DATABASE_URL" -f scripts/post-migration-check.sql
--
-- Expected on a database at 0065:
--
--   schema_version         0065
--   migrations_recorded    65
--   money_fns_expect_9     9     — one definition each, so no PGRST203 overload
--   idem_columns_expect_10 10    — 4 pre-existing + 3 from 0061 + 3 from 0063
--   new_fns_expect_6       6
--   ledger_balances        t     — debits equal credits, as they must
--
--   sales / journals              your own figures; they should be unchanged
--                                 from before the migration
--
-- A count *lower* than expected means part of the migration did not apply. A
-- money_fns count *higher* than 9 means a leftover overload, which makes
-- supabase-js calls ambiguous (PGRST203) — drop the old signature.
-- =============================================================================

-- Post-migration check. Read-only: selects only, no writes.
select
  (select max(version) from public.schema_migrations)                 as schema_version,
  (select count(*)     from public.schema_migrations)                 as migrations_recorded,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in (
      'record_cash_transaction','record_bank_transaction','record_sale_payment',
      'create_vehicle_sale_draft','record_service_payment','create_counter_invoice',
      'create_booking_with_advance','refund_booking_advance','record_trade_advance'))
                                                                      as money_fns_expect_9,
  (select count(*) from information_schema.columns
    where table_schema = 'public' and column_name = 'idempotency_key') as idem_columns_expect_10,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in (
      'dashboard_unit_counts','customer_360','finance_application_totals',
      'finance_applications_list','service_invoice_totals','bank_unreconciled_counts'))
                                                                      as new_fns_expect_6,
  (select count(*) from public.sales)                                 as sales,
  (select count(*) from public.journal_entries)                       as journals,
  (select sum(debit) = sum(credit) from public.journal_entry_lines)   as ledger_balances;
