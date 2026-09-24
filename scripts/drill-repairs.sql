-- =============================================================================
-- drill-repairs.sql — repairs a pending migration will make, applied to the
-- restored copy only
-- =============================================================================
-- The restore drill applies this between the data and the constraints. Each
-- statement must mirror a migration that repairs the live database, and must be
-- a no-op once that migration is applied — so the fingerprint comparison still
-- holds. Remove a repair once production has the migration.
-- =============================================================================

-- 0086: a profile's default branch deleted with foreign keys suspended.
update public.user_profiles p
   set default_branch_id = null
 where p.default_branch_id is not null
   and not exists (select 1 from public.branches b where b.id = p.default_branch_id);
