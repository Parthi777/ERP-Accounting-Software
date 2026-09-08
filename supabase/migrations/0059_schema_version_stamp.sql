-- =============================================================================
-- 0059 — A database that can say which migration it is on
-- =============================================================================
-- Spec §59, §60.20.
--
-- The problem this closes. The application deploys to Railway on push, while
-- migrations are applied to Supabase by hand. Those two facts guarantee a window
-- in which the running code expects a schema the database does not have, and
-- nothing anywhere reports it. The symptom reaches a user as a PostgREST error
-- about a function signature, which tells the person who pressed the button
-- nothing they can act on, and tells the person who could fix it nothing at all
-- because they are not the one who saw it.
--
-- Two services already work around this by hand — settlement-service.ts guesses
-- from an error string that 0050 is missing, sale-service.ts does the same for
-- 0051. Both are honest patches over a missing fact: the database does not know
-- what it is. So record it.
--
-- ── Why a table and not a setting ───────────────────────────────────────────
--
-- system_settings is dealer-scoped configuration that an administrator changes.
-- The schema version is neither: it is one fact about the whole database, it is
-- written by migrations rather than by people, and it is a list rather than a
-- value — knowing 0058 was applied on Tuesday and 0059 has not been applied at
-- all is the useful form. A table keeps the history; a setting would keep only
-- the last answer.
--
-- ── On the backfilled timestamps ────────────────────────────────────────────
--
-- Every migration before this one is inserted here as applied, because a
-- database running this file necessarily ran them: migrations are applied in
-- order, and both bundles are wrapped in a single transaction. Their applied_at
-- is therefore the moment this migration ran, not the moment they did. That is a
-- true statement about *what* is applied and a false one about *when*, so the
-- column is named and commented accordingly rather than pretending to a history
-- that was never recorded.
--
-- From here on each migration stamps itself as its last statement, and
-- `npm run check:schema-version` fails the build if one forgets.
--
-- Rollback: drop table public.schema_migrations.
-- =============================================================================

create table public.schema_migrations (
  version     text primary key,
  name        text not null,
  -- When this row was written, which for rows backfilled by 0059 is when
  -- 0059 ran rather than when the migration itself was applied.
  applied_at  timestamptz not null default now()
);

comment on table public.schema_migrations is
  'Which migrations this database has. Written by migrations, never by users. '
  'Compared against the version the running application was built against, so a '
  'deploy that has outrun its schema is visible instead of being guessed at from '
  'PostgREST error strings.';

-- Not tenant data: one row per migration, identical for every dealer on this
-- database. Every public table carries RLS regardless (verify-migrations.sh
-- checks), so the policy is an explicit "any session may read this" rather than
-- an absence of one.
alter table public.schema_migrations enable row level security;

create policy schema_migrations_read on public.schema_migrations
  for select to authenticated using (true);

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  -- Release-managed, like public.permissions: readable by any session, writable
  -- only by migrations running as the owner or the service role.
  execute 'revoke insert, update, delete on public.schema_migrations from authenticated';
end $$;

-- -----------------------------------------------------------------------------
-- Backfill: everything up to and including this migration
-- -----------------------------------------------------------------------------
insert into public.schema_migrations (version, name) values
    ('0001', 'extensions_and_app_schema'),
    ('0002', 'organization'),
    ('0003', 'identity'),
    ('0004', 'rls_helpers'),
    ('0005', 'audit'),
    ('0006', 'document_sequences'),
    ('0007', 'accounting_core'),
    ('0008', 'system_settings'),
    ('0009', 'rls_policies'),
    ('0010', 'indexes'),
    ('0011', 'grants'),
    ('0012', 'reporting_functions'),
    ('0013', 'customers'),
    ('0014', 'tax_and_hsn'),
    ('0015', 'vehicle_catalogue'),
    ('0016', 'inventory_items'),
    ('0017', 'vehicle_stock'),
    ('0018', 'vehicle_pricing'),
    ('0019', 'inventory_stock'),
    ('0020', 'bookings_and_sales'),
    ('0021', 'finance'),
    ('0022', 'cash_and_bank'),
    ('0023', 'service'),
    ('0024', 'gst_and_accounting_rules'),
    ('0025', 'posting_engine'),
    ('0026', 'reports'),
    ('0027', 'default_accounting_rules'),
    ('0028', 'booking_and_sale_operations'),
    ('0029', 'create_sale_draft'),
    ('0030', 'cash_operations'),
    ('0031', 'bank_operations'),
    ('0032', 'bank_entry_permission'),
    ('0033', 'service_operations'),
    ('0034', 'gst_reports'),
    ('0035', 'mis_reports'),
    ('0036', 'transfers_returns_adjustments'),
    ('0037', 'customer_ledger_opening'),
    ('0038', 'delivery_document_sequence'),
    ('0039', 'dealer_wide_document_numbering'),
    ('0040', 'suppliers'),
    ('0041', 'party_ledger_and_supplier_payments'),
    ('0042', 'finance_accounting_rules'),
    ('0043', 'finance_operations'),
    ('0044', 'price_approval_workflow'),
    ('0045', 'customer_vehicle_writer'),
    ('0046', 'booking_advances'),
    ('0047', 'counter_sales'),
    ('0048', 'einvoice_payload'),
    ('0049', 'cash_book_and_cogs_classification'),
    ('0050', 'party_payment_allocation'),
    ('0051', 'sale_return_refund'),
    ('0052', 'purchases'),
    ('0053', 'hr_foundations'),
    ('0054', 'attendance_integration'),
    ('0055', 'dealer_status_gate'),
    ('0056', 'dealer_provisioning'),
    ('0057', 'purchase_returns'),
    ('0058', 'gst_input_tax'),
    ('0059', 'schema_version_stamp')
on conflict (version) do nothing;
