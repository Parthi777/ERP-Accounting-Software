# Database

PostgreSQL via Supabase. 56 tables, 124 RLS policies, 301 indexes, 478 constraints, 101 triggers.

These figures are printed by `npm run db:verify`, which is the only place worth reading them from —
any number written here by hand goes stale on the next migration.

## Migration order

Forward-only, applied in numerical order. Each file opens with its purpose and rollback notes.

| File | Contents |
|---|---|
| `0001_extensions_and_app_schema.sql` | `app` schema; `set_updated_at()`, `forbid_mutation()` |
| `0002_organization.sql` | `dealers`, `branches` |
| `0003_identity.sql` | `user_profiles`, `roles`, `permissions`, `role_permissions`, `user_roles`, `user_branches`, `employees` |
| `0004_rls_helpers.sql` | The five SECURITY DEFINER functions every policy is written in terms of |
| `0005_audit.sql` | `audit_logs` and the generic row auditor |
| `0006_document_sequences.sql` | `document_sequences`, `next_document_number()` |
| `0007_accounting_core.sql` | `chart_of_accounts`, `accounting_periods`, `journal_entries`, `journal_entry_lines` |
| `0008_system_settings.sql` | `system_settings` |
| `0009_rls_policies.sql` | RLS enabled, policies on every table |
| `0010_indexes.sql` | Tenant-leading and foreign-key indexes |
| `0011_grants.sql` | Privileges for `authenticated`, `anon`, `service_role` |
| `0012_reporting_functions.sql` | `account_balances()` |
| `0013_customers.sql` | `customers`, and the self-provisioning customer-code trigger |
| `0014_tax_and_hsn.sql` | `hsn_codes`, `tax_codes`, effective-dated; `resolve_tax_code()` |
| `0015_vehicle_catalogue.sql` | `vehicle_models`, `vehicle_variants`, `vehicle_colours` |
| `0016_inventory_items.sql` | `inventory_items`, `finance_companies` |
| `0017_vehicle_stock.sql` | `vehicles`, `vehicle_stock_transactions`, `vehicle_transfers`; the status guard and the movement log |
| `0018_vehicle_pricing.sql` | `vehicle_price_versions`, immutability guard, `resolve_vehicle_price()` |
| `0019_inventory_stock.sql` | `inventory_stock`, `inventory_transactions`, `accessory_vehicle_mappings`; `allocate_stock()` |
| `0020_bookings_and_sales.sql` | `bookings`, `booking_payments`, `sales`, `sale_lines`, `sale_payments`, `deliveries` |
| `0021_finance.sql` | `finance_applications`, `finance_transactions`, `finance_settlements`; `finance_company_ledger()` |
| `0022_cash_and_bank.sql` | `cash_accounts`, `cash_transactions`, `cash_day_closings`, `bank_accounts`, `bank_transactions`, reconciliation |
| `0023_service.sql` | `customer_vehicles`, `job_cards`, `service_invoices`, `service_lines`, `service_payments` |
| `0024_gst_and_accounting_rules.sql` | `accounting_rules`, `resolve_account()`; `einvoices`, `eway_bills` |
| `0025_posting_engine.sql` | `app.post_journal()`, `app.reverse_journal()`, `app.require_account()`, `post_vehicle_sale()` |
| `0026_reports.sql` | Trial balance, P&L, balance sheet, customer ledger |
| `0027_default_accounting_rules.sql` | `app.seed_default_accounting_rules()` — the default account mapping |
| `0028_booking_and_sale_operations.sql` | `create_booking_with_advance()`, `record_sale_payment()`, `deliver_vehicle()` |
| `0029_create_sale_draft.sql` | `create_vehicle_sale_draft()` — priced from the version in force |
| `0030_cash_operations.sql` | `record_cash_transaction()`, `ensure_cash_day()`, `close_cash_day()`, `cash_book()` |
| `0031_bank_operations.sql` | `record_bank_transaction()`, statement import, matching, `bank_book()` |
| `0032_bank_entry_permission.sql` | `bank.book.record` |
| `0033_service_operations.sql` | `create_job_card()`, `add_service_line()`, `post_service_invoice()`, `record_service_payment()` |
| `0034_gst_reports.sql` | `gstr1_summary()`, `gst_document_register()`, the e-invoice queue |
| `0035_mis_reports.sql` | `finance_summary()`, `branch_performance()`, `margin_report()`, `consolidated_mis()` |
| `0036_transfers_returns_adjustments.sql` | Vehicle transfers, stock transfers and adjustments, `return_vehicle_sale()` |
| `0037_customer_ledger_opening.sql` | Opening balance on the customer ledger, so a mid-year window is not off by everything before it |
| `0038_delivery_document_sequence.sql` | Deliveries get their own series; transfers and deliveries move to dealer-wide numbering |
| `0039_dealer_wide_document_numbering.sql` | A dealer-wide sequence wins over a branch one, so a per-dealer unique number cannot come from per-branch counters |
| `0040_suppliers.sql` | `suppliers`, with the same self-provisioning code trigger as customers |
| `0041_party_ledger_and_supplier_payments.sql` | `party_ledger()` for any party; cash and bank movements gain `supplier_id` |
| `0042_finance_accounting_rules.sql` | The trade-advance mappings spec §26 needs beyond 0027 |
| `0043_finance_operations.sql` | Finance applications, disbursement, trade advances, settlements |
| `0044_price_approval_workflow.sql` | `decide_price_version()` — DRAFT → SUBMITTED → APPROVED → ACTIVE |
| `0045_customer_vehicle_writer.sql` | Delivery and job cards populate `customer_vehicles`; `customer_service_summary()` |
| `0046_booking_advances.sql` | Advances released when the sale posts; `refund_booking_advance()` |
| `0047_counter_sales.sql` | `create_counter_invoice()` — counter sales reuse the service billing engine |
| `0048_einvoice_payload.sql` | `einvoice_payload()` builds the IRP document; `record_einvoice_request()` stores it before transmission |
| `0049_cash_book_and_cogs_classification.sql` | Module receipts reach the cash and bank books; accessory cost is charged to the accessory accounts |
| `0050_party_payment_allocation.sql` | `party_allocations` — bill-wise settlement; `party_open_items()` and `allocate_party_payment()` |
| `0051_sale_return_refund.sql` | A sales return refunds what was received through the cash or bank book; the receipts are reversed and the stock comes back |
| `0052_purchases.sql` | `purchase_bills` — stock and input GST onto the balance sheet, the payable onto the supplier ledger; Input CGST/SGST/IGST accounts |
| `0053_hr_foundations.sql` | `shifts`, `leave_types`, `employee_salary_structures` (effective-dated), `employee_leave_balances`, `employee_documents`; employees gains its HR fields |
| `0054_attendance_integration.sql` | `attendance_days` mirror and `attendance_sync_runs`; `employees.external_ref` maps to the external attendance system |
| `0055_dealer_status_gate.sql` | `app.current_dealer_id()` also requires `dealers.status = 'ACTIVE'` — suspending a tenant finally ends access |
| `0056_dealer_provisioning.sql` | `provision_dealer()`, `dealer_readiness()`, `purge_dealer()` — onboarding a tenant in one transaction |

No extensions are required. `gen_random_uuid()` has been core since PostgreSQL 13, and
case-insensitive email uses a `lower()` unique index rather than `citext` — which keeps the
migrations runnable against any PostgreSQL 15+ server, including the local verification harness.

Requires PostgreSQL 15+ for `UNIQUE NULLS NOT DISTINCT`.

## Tenant isolation

Three independent mechanisms, in order of authority:

### 1. Composite foreign keys

`branches` carries `UNIQUE (id, dealer_id)` alongside its primary key. It looks redundant; it is what
lets every branch-scoped table declare:

```sql
foreign key (branch_id, dealer_id) references public.branches (id, dealer_id)
```

Attaching Dealer A's employee to Dealer B's branch is then not merely forbidden — it is
unrepresentable. No application code participates.

### 2. Row Level Security

Every table has RLS enabled with the same policy shape:

```sql
-- Read: platform admin, or my dealer (and my branch, where the row is branch-specific)
create policy employees_select on public.employees
  for select to authenticated
  using (
    app.is_platform_admin()
    or (dealer_id = app.current_dealer_id()
        and app.can_access_branch(branch_id)
        and app.has_permission('masters.employees.view'))
  );
```

Writes additionally require a permission code — never a role name, so §6's roles stay data.

### 3. Service-layer checks

`requirePermission()` in the service layer. First to run, last in authority.

## The RLS helpers

`0004_rls_helpers.sql` defines five functions that every policy is written against:

| Function | Returns |
|---|---|
| `app.is_platform_admin()` | Platform admins sit above the tenant model |
| `app.current_dealer_id()` | The session's tenant, or NULL |
| `app.has_all_branch_access()` | Owners and accounts see every branch |
| `app.can_access_branch(uuid)` | Branch-level narrowing |
| `app.has_permission(text)` | The single authorization primitive |

**All are `SECURITY DEFINER`, and that is not optional.** A policy on `user_profiles` that reads
`user_profiles` to decide visibility re-enters its own policy and recurses until PostgreSQL aborts.
Definer rights make the lookup run as the function owner, bypassing RLS for that read alone.

Each pins `search_path = public, pg_temp` so a caller cannot shadow `public` with a temp-schema table
and feed forged rows to a definer-rights function.

For the same reason RLS is **ENABLED but not FORCED**. Forcing it would subject these helpers to the
very policies they exist to answer. Client sessions connect as `authenticated`, never as the table
owner, so policies still apply to every request that comes from a browser.

`app.current_dealer_id()` returning NULL for an unauthenticated caller is deliberate:
`dealer_id = NULL` is never true, so the default is deny.

## Privileges

RLS narrows a privilege; it does not grant one. A table with perfect policies and no `GRANT` is
unreadable, and a table with a `GRANT` and no policy is wide open. `0011_grants.sql` sets both
explicitly rather than relying on Supabase defaults.

- `anon` receives nothing. Every read requires a session.
- `authenticated` may attempt any DML; policies decide the outcome. Except:
  - no INSERT/UPDATE/DELETE on `audit_logs` — a session cannot forge its own audit trail
  - no DELETE on `journal_entries` or `journal_entry_lines` — corrections are reversals
  - no DELETE on `dealers`, no writes to `permissions`
- `service_role` bypasses RLS by design. Server-only; never expose it to the browser.

Default privileges are set so a future migration that forgets its grants still produces a usable
table.

## Accounting integrity

Three rules the database enforces, independent of application code:

**A posted journal balances.** `journal_entries_balanced_check` compares the stored totals; the
`app.journal_entries_guard()` trigger recomputes them from the lines during the `DRAFT → POSTED`
transition and refuses the change if debits ≠ credits or there are fewer than two lines. Entries must
be *created* as DRAFT, so the line-level check cannot be skipped by inserting a pre-posted row with
hand-written totals.

**A posted journal is immutable.** The same trigger rejects every `UPDATE` and `DELETE` on a POSTED
or REVERSED entry. Exactly one change is permitted: recording that the entry has since been reversed,
which requires both a reversal id and a reason. `app.journal_lines_guard()` applies the same rule to
the lines.

**Corrections are reversals.** `reversal_of_id` requires `reversal_reason`
(`journal_entries_reversal_reason_check`). The pair nets to zero, so the ledger is unchanged by the
correction — which is the point.

Lines are one-sided (`jel_one_sided_check`): a line is a debit or a credit, never both and never
neither.

## Document numbering

`app.next_document_number(dealer, branch, doc_type, year)` increments under a row lock and returns
`INV-2026-000001`. Two cashiers saving at the same instant get different numbers. Spec §45 forbids
generating financial document numbers in frontend JavaScript; this is why.

An unconfigured document type raises rather than inventing a number.

## Audit trail

`app.audit_trigger()` attaches to any table and reads `dealer_id` / `branch_id` from the row via
JSONB, so one function serves differently shaped tables. It records only fields that actually changed,
ignoring `updated_at`.

`audit_logs` carries a `BEFORE UPDATE OR DELETE` trigger that raises unconditionally. An audit log
that can be rewritten is not an audit log.

Events with no row behind them — login, branch switch, export — are recorded by `recordAudit()` in
the service layer, through the service-role client.

## Reporting

`public.account_balances(from, to, branch)` returns per-account debit and credit totals for a period
and cumulatively to the end date. Balance-sheet accounts need the cumulative figure, P&L accounts the
period movement; both are returned so the caller picks per account type rather than issuing two
queries.

It is `SECURITY INVOKER`, so RLS still scopes it to the caller's dealer and branches. Reporting does
not get to bypass tenant isolation for convenience.

## Verification

```bash
npm run db:verify            # create, verify, drop
KEEP_DB=1 npm run db:verify  # leave twerp_migration_check for inspection
```

`scripts/verify-migrations.sh` creates a throwaway database, loads `supabase/test/00_supabase_shim.sql`
(a local-only stand-in for Supabase's `auth` schema, `auth.uid()` and the `anon`/`authenticated`/
`service_role` roles), applies every migration and seed, then runs the tests. Existing databases are
never touched.

64 assertions across two files:

- `10_rls_isolation.sql` — a second dealer is created, then a Dealer A user attempts to read and
  write its data across every tenant table. Also covers branch-level narrowing, cashier permission
  gating, privilege escalation, and that an anonymous session sees nothing.
- `20_accounting_integrity.sql` — double entry, immutability, reversal, idempotency, cross-tenant
  foreign keys, append-only audit, and that the trial balance balances.

Note the asymmetry the isolation test encodes: `UPDATE`/`DELETE` against another tenant are filtered
by the policy's `USING` clause and affect **zero rows without raising**, while `INSERT` is rejected by
`WITH CHECK` and does raise. A test that only asserts "an error was thrown" would miss a real leak.

**What this does not cover.** The shim is not Supabase. Real `auth.uid()` derived from a JWT, the
Supabase Auth signup and password-reset flows, and Storage are unverified until the project exists.
Schema, constraints, triggers, policy expressions and privileges are all exercised for real.
