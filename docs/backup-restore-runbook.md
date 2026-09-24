# Backup and restore runbook

This runbook is for whoever runs the database: the owner, or whoever has the Supabase login.
It covers what protects the data, how to show that a backup can actually be restored, and what to do when a restore is needed for real.

## What protects the data

| Layer | What it covers | Where |
|---|---|---|
| Supabase backups | The whole project (database, Auth, Storage metadata). How often, and how long they are kept, depend on the plan; point-in-time recovery is an add-on. | Supabase dashboard → Database → Backups |
| Logical backup (`scripts/restore-drill.sh`) | The ERP's own schemas, `public` and `app`, plus the user list (`auth.users`: id, email). | Run by hand; the file is deleted after the drill unless `KEEP_DRILL=1` |
| Storage bucket `attachments` | Uploaded bills, acknowledgements and challans. **Neither the Supabase database backup nor the logical dump contains the files themselves**; they hold only the metadata rows. | Supabase dashboard → Storage; download the bucket periodically |
| Git | Schema (migrations), application code | GitHub |

Railway holds no business data (spec §3), so it is not in the backup plan. A redeploy from Git rebuilds it.

## The drill: proving a backup restores

A backup nobody has restored is only a hope. Run the drill:

- once a month;
- before applying any migration bundle to production;
- after any hand-run maintenance script, such as `remove-demo-dealer.sql`.

```bash
brew install postgresql@17        # once: pg_dump must be as new as the server (Supabase runs 17)
bash scripts/restore-drill.sh     # reads DATABASE_URL from .env.local
```

What it does:

1. Every connection to production is forced read-only (`default_transaction_read_only=on`), so the drill cannot write to production.
2. It takes a `pg_dump` of `public` and `app` (custom format, no owners or grants) and copies `auth.users (id, email, created_at)`.
3. It fingerprints production with `scripts/drill-fingerprint.sql`:
   - the schema version;
   - the row count of every table;
   - for each dealer, an MD5 checksum over every posted journal line and over the trial balance by account.
4. It scans every foreign key for orphan rows (`scripts/drill-orphans.sql`). Orphan rows are rows the live database tolerates but a restore refuses.
5. It restores into a throwaway local database in sections:
   - the Supabase shim,
   - then the tables,
   - then the data,
   - then `scripts/drill-repairs.sql` (the repairs a pending migration will make),
   - then the constraints and indexes.
6. It fingerprints the restored copy and diffs it against production. The drill passes only if the two are identical line for line and every dealer's trial balance nets to zero.
7. It deletes the dump and the drill database, because the dump holds customer data.

It prints the dump and restore times. The restore time is the recovery time a logical restore can actually promise.

### When the drill fails

| Message | Meaning | Action |
|---|---|---|
| `orphans <table> <constraint> <n>` | Rows reference something that no longer exists. This is usually the result of a script run with `session_replication_role = replica`. | Write a repair migration, and add the same statement to `scripts/drill-repairs.sql` until production has the migration. |
| `restore FAILED in pre-data` | An object depends on something outside `public`/`app`, such as an extension or a Supabase schema. | Add it to `supabase/test/00_supabase_shim.sql`. |
| `DIFFERENT` | The copy is not faithful. | Treat the backup as unusable until this is explained. Check first whether anyone posted during the drill: the fingerprint is taken right after the dump, so live activity can cause a difference. Rerun at a quiet hour. |
| A trial balance not `0.0000` | The source ledger itself is out of balance. | Stop. Investigate before anything else. |

## Restoring for real

**Decide the target first.** Restoring over a live project destroys whatever happened after the backup was taken. Unless the live data is known to be lost or corrupt, always restore to a **new** project, compare, then cut over.

### A. Whole project from a Supabase backup (the usual case)

1. Supabase dashboard → Database → Backups → pick the backup or point in time → restore. Where the plan allows, restore to a new project.
2. Apply any migrations newer than the backup, in order (`supabase/INCREMENTAL-*.sql`).
3. Check the result:
   - `select max(version) from public.schema_migrations;`
   - run the fingerprint and compare it with the last drill's figures;
   - check the Storage bucket still holds the files the `document_attachments` rows name.
4. Point Railway's `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` at the restored project, if it is a new one, and redeploy.
5. Record the incident: what was lost between the backup and the failure, and which documents must be re-entered.

### B. From a logical dump (`KEEP_DRILL=1`, or a dump taken before risky work)

1. Create a new Supabase project. Apply `supabase/ALL-IN-ONE-*.sql` only up to the **extensions and roles**, or restore into an empty project and let the dump create the schemas.
2. Restore the sections as the drill does, in this order:
   - `pg_restore --section=pre-data`,
   - then `data`,
   - then `post-data`.
   Use `--no-owner --no-privileges`, then re-run the grants block of the latest migrations.
3. Re-create the Auth users. Only id and email are in the dump, so users set passwords through "forgot password".
4. Re-upload the Storage bucket from its separate backup.
5. Check the result and cut over as in A.

## Drill log

Add a row after every drill.

| Date | Source schema | Tables | Journals (all dealers) | Dump | Restore | Result | Notes |
|---|---|---|---|---|---|---|---|
| 2026-09-24 | 0080 | 70 | 7 (DHARANI; ₹9,30,186.13 Dr = Cr) | 51 s, 2.1 MB | 1 s | **Passed with repair** | One orphan: the platform admin's `user_profiles.default_branch_id` pointed at a branch deleted by `remove-demo-dealer.sql` under replica mode. A plain restore failed on it. Repaired by migration 0086, and the script was fixed so it cannot happen again. The restore also succeeded with the repair applied. After 0086 is applied, the drill should pass with no repair. |
