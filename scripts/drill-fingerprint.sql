-- =============================================================================
-- drill-fingerprint.sql — what a database holds, in a form two can be compared
-- =============================================================================
-- Read-only: selects only. Run against production and against a restored copy;
-- the two outputs must be identical, line for line (scripts/restore-drill.sh
-- diffs them). Row counts for every table, the schema version, and for each
-- dealer a checksum of the ledger and of the trial balance — a restore that
-- lost one journal line, or one rupee, changes the checksum.
-- =============================================================================
\pset format unaligned
\pset tuples_only on
\pset fieldsep ' | '

select 'schema_version', max(version) from public.schema_migrations;

select 'rows ' || table_schema || '.' || table_name,
       (xpath('/row/c/text()',
              query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text
  from information_schema.tables
 where table_schema in ('public', 'app') and table_type = 'BASE TABLE'
 order by table_schema, table_name;

select 'ledger ' || d.code,
       count(distinct je.id) || ' journals',
       coalesce(sum(l.debit), 0) || ' Dr',
       coalesce(sum(l.credit), 0) || ' Cr',
       md5(coalesce(string_agg(je.entry_number || ':' || l.line_number || ':' || l.debit || ':' || l.credit,
                               ',' order by je.entry_number, l.line_number), ''))
  from public.dealers d
  left join public.journal_entries je on je.dealer_id = d.id and je.status in ('POSTED', 'REVERSED')
  left join public.journal_entry_lines l on l.journal_entry_id = je.id
 group by d.code
 order by d.code;

select 'trial_balance ' || d.code,
       md5(coalesce(string_agg(t.code || ':' || t.net, ',' order by t.code), '')),
       coalesce(sum(t.net), 0) || ' (must be 0)'
  from public.dealers d
  left join lateral (
    select c.code, sum(l.debit - l.credit) as net
      from public.journal_entry_lines l
      join public.journal_entries je on je.id = l.journal_entry_id and je.status in ('POSTED', 'REVERSED')
      join public.chart_of_accounts c on c.id = l.account_id
     where je.dealer_id = d.id
     group by c.code) t on true
 group by d.code
 order by d.code;

select 'stock ' || d.code,
       coalesce((select sum(quantity) || ' units / ' || sum(stock_value) from public.inventory_stock s where s.dealer_id = d.id), 'none'),
       (select count(*) from public.vehicles v where v.dealer_id = d.id) || ' vehicles'
  from public.dealers d order by d.code;
