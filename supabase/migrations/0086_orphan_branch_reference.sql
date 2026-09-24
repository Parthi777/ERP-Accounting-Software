-- =============================================================================
-- 0086 — Repair: a profile pointing at a branch that no longer exists
-- =============================================================================
-- Found by the restore drill (scripts/restore-drill.sh, docs/backup-restore-
-- runbook.md): a logical backup of production could not be restored, because
-- one user_profiles row had a default_branch_id for a branch that had been
-- deleted. The foreign key is ON DELETE SET NULL, but the branch was removed by
-- scripts/remove-demo-dealer.sql under session_replication_role = replica, which
-- suspends foreign-key actions along with the checks, so the SET NULL never ran.
-- The live database worked (the reference is only a UI default), but a restore —
-- which re-creates the constraint — refused it. A backup that cannot be restored
-- is not a backup.
--
-- A scan of every foreign key in public and app found this one orphan and no
-- other. The script now clears such references before its sweep.
--
-- Rollback: none needed; the cleared value referred to nothing.
-- =============================================================================

update public.user_profiles p
   set default_branch_id = null
 where p.default_branch_id is not null
   and not exists (select 1 from public.branches b where b.id = p.default_branch_id);

insert into public.schema_migrations (version, name)
values ('0086', 'orphan_branch_reference') on conflict (version) do nothing;
