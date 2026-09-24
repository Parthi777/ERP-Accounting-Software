-- =============================================================================
-- drill-orphans.sql — rows whose foreign key points at nothing
-- =============================================================================
-- Read-only. A live database can hold such rows if they were written with
-- foreign keys suspended (session_replication_role = replica); a restore
-- re-creates every constraint and refuses them. Lists each constraint with
-- orphans, or nothing when there are none.
-- =============================================================================
-- Runs in a read-only session, so it reports by NOTICE rather than a table.

do $$
declare
  c record;
  v_n bigint;
begin
  for c in
    select con.conname, con.conrelid::regclass::text as tbl, con.confrelid::regclass::text as ref,
           (select string_agg(format('t.%I', a.attname), ',' order by k.ord)
              from unnest(con.conkey) with ordinality k(attnum, ord)
              join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum) as cols,
           (select string_agg(format('r.%I', a.attname), ',' order by k.ord)
              from unnest(con.confkey) with ordinality k(attnum, ord)
              join pg_attribute a on a.attrelid = con.confrelid and a.attnum = k.attnum) as rcols,
           (select string_agg(format('t.%I is not null', a.attname), ' and ' order by k.ord)
              from unnest(con.conkey) with ordinality k(attnum, ord)
              join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum) as notnull
      from pg_constraint con
      join pg_namespace n on n.oid = con.connamespace
     where con.contype = 'f' and n.nspname in ('public', 'app')
  loop
    execute format('select count(*) from %s t where %s and not exists (select 1 from %s r where (%s) = (%s))',
                   c.tbl, c.notnull, c.ref, c.rcols, c.cols) into v_n;
    if v_n > 0 then
      raise notice 'orphans % % %', c.tbl, c.conname, v_n;
    end if;
  end loop;
end $$;
