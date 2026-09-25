-- =============================================================================
-- drill-repairs.sql — repairs a pending migration will make, applied to the
-- restored copy only
-- =============================================================================
-- The restore drill applies this between the data and the constraints. Each
-- statement must mirror a migration that repairs the live database, and must be
-- a no-op once that migration is applied — so the fingerprint comparison still
-- holds. Remove a repair once production has the migration.
-- =============================================================================

-- (none pending: 0086 is applied in production, and its repair removed from here.)
select 1;
