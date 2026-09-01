-- =============================================================================
-- 0010 — Indexes
-- =============================================================================
-- Spec §57.7. Two categories:
--   * Tenant-leading indexes. Every RLS policy filters on dealer_id first, so
--     dealer_id belongs at the front of almost every composite index.
--   * Foreign-key indexes. Postgres does not create these automatically, and
--     without them a cascade or a join scans the child table.
--
-- Rollback: drop index ...;
-- =============================================================================

-- Organization ---------------------------------------------------------------
create index branches_dealer_idx            on public.branches (dealer_id) where status = 'ACTIVE';
create index branches_dealer_name_idx       on public.branches (dealer_id, name);

-- Identity -------------------------------------------------------------------
create index user_profiles_dealer_idx       on public.user_profiles (dealer_id) where status = 'ACTIVE';
create index user_profiles_default_branch_idx on public.user_profiles (default_branch_id);
create index roles_dealer_idx               on public.roles (dealer_id);
create index role_permissions_permission_idx on public.role_permissions (permission_code);
create index user_roles_role_idx            on public.user_roles (role_id);
create index user_branches_branch_idx       on public.user_branches (branch_id);
create index user_branches_dealer_idx       on public.user_branches (dealer_id);

-- Employees: the two lookups the UI actually performs (spec §12).
create index employees_dealer_branch_idx    on public.employees (dealer_id, branch_id) where status = 'ACTIVE';
create index employees_name_search_idx      on public.employees (dealer_id, lower(name));
create index employees_mobile_idx           on public.employees (dealer_id, mobile) where mobile is not null;
create index employees_user_idx             on public.employees (user_id) where user_id is not null;

-- Audit ----------------------------------------------------------------------
-- The audit screen is "show me recent activity for this tenant", newest first.
create index audit_logs_dealer_time_idx     on public.audit_logs (dealer_id, created_at desc);
create index audit_logs_entity_idx          on public.audit_logs (entity_type, entity_id, created_at desc);
create index audit_logs_user_time_idx       on public.audit_logs (user_id, created_at desc);
create index audit_logs_branch_time_idx     on public.audit_logs (branch_id, created_at desc) where branch_id is not null;

-- Accounting -----------------------------------------------------------------
create index coa_dealer_type_idx            on public.chart_of_accounts (dealer_id, account_type) where status = 'ACTIVE';
create index coa_parent_idx                 on public.chart_of_accounts (parent_id) where parent_id is not null;

create index accounting_periods_dealer_status_idx on public.accounting_periods (dealer_id, status);

-- Ledger and trial-balance queries are "this dealer, this date range".
create index journal_entries_dealer_date_idx    on public.journal_entries (dealer_id, entry_date desc);
create index journal_entries_branch_date_idx    on public.journal_entries (branch_id, entry_date desc);
create index journal_entries_status_idx         on public.journal_entries (dealer_id, status) where status = 'DRAFT';
create index journal_entries_source_idx         on public.journal_entries (source_document_type, source_document_id)
  where source_document_id is not null;
create index journal_entries_period_idx         on public.journal_entries (period_id) where period_id is not null;
create index journal_entries_reversal_of_idx    on public.journal_entries (reversal_of_id) where reversal_of_id is not null;
create index journal_entries_reversed_by_idx    on public.journal_entries (reversed_by_id) where reversed_by_id is not null;

-- Account ledger: every line for one account, plus the FK index for cascades.
create index jel_account_idx                on public.journal_entry_lines (account_id);
create index jel_entry_idx                  on public.journal_entry_lines (journal_entry_id);
create index jel_branch_idx                 on public.journal_entry_lines (branch_id) where branch_id is not null;
-- Subsidiary ledgers (customer / finance company outstanding).
create index jel_party_idx                  on public.journal_entry_lines (party_type, party_id)
  where party_id is not null;

-- Sequences and settings -----------------------------------------------------
create index document_sequences_dealer_idx  on public.document_sequences (dealer_id, doc_type);
create index system_settings_dealer_idx     on public.system_settings (dealer_id);
