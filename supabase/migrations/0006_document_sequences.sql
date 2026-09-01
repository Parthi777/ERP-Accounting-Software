-- =============================================================================
-- 0006 — Document numbering
-- =============================================================================
-- Spec §45: financial document numbers are never generated in frontend JavaScript.
-- app.next_document_number() increments under a row lock, so two cashiers hitting
-- "save" at the same instant get different invoice numbers (spec §49).
--
-- Rollback: drop function app.next_document_number(...); drop table public.document_sequences;
-- =============================================================================

create table public.document_sequences (
  id             uuid primary key default gen_random_uuid(),
  dealer_id      uuid not null references public.dealers (id) on delete cascade,
  -- NULL for dealer-wide sequences (e.g. journal numbers shared across branches).
  branch_id      uuid,

  doc_type       text not null,
  -- The year token that appears inside the number, e.g. '2026' in INV-2026-000001.
  financial_year text not null,

  prefix         text not null,
  padding        smallint not null default 6,
  last_number    bigint not null default 0,

  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),

  constraint document_sequences_scope_key
    unique nulls not distinct (dealer_id, branch_id, doc_type, financial_year),
  constraint document_sequences_branch_tenant_fkey
    foreign key (branch_id, dealer_id) references public.branches (id, dealer_id) on delete cascade,
  constraint document_sequences_doc_type_check check (doc_type ~ '^[A-Z][A-Z0-9_]{1,30}$'),
  constraint document_sequences_prefix_check   check (prefix ~ '^[A-Z]{1,6}$'),
  constraint document_sequences_padding_check  check (padding between 3 and 12),
  constraint document_sequences_last_number_check check (last_number >= 0)
);

comment on table public.document_sequences is
  'Per dealer/branch/document-type/year counters (spec §45). Never bypassed by the client.';

create trigger document_sequences_set_updated_at
  before update on public.document_sequences
  for each row execute function app.set_updated_at();

-- -----------------------------------------------------------------------------
-- app.next_document_number() — atomic, gap-free within a committed transaction
-- -----------------------------------------------------------------------------
-- The UPDATE ... RETURNING takes a row-level lock for the duration of the calling
-- transaction, so concurrent callers serialize on this row rather than colliding.
-- Numbers are consumed on rollback only if the whole transaction rolls back, which
-- is the behaviour financial documents want (no reserved-then-abandoned numbers).
-- -----------------------------------------------------------------------------
create or replace function app.next_document_number(
  p_dealer_id      uuid,
  p_branch_id      uuid,
  p_doc_type       text,
  p_financial_year text
)
returns text
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_prefix  text;
  v_padding smallint;
  v_number  bigint;
begin
  update public.document_sequences ds
     set last_number = ds.last_number + 1
   where ds.dealer_id = p_dealer_id
     and ds.branch_id is not distinct from p_branch_id
     and ds.doc_type = p_doc_type
     and ds.financial_year = p_financial_year
  returning ds.prefix, ds.padding, ds.last_number
       into v_prefix, v_padding, v_number;

  if not found then
    raise exception
      'No document sequence configured for dealer %, branch %, type %, year %.',
      p_dealer_id, coalesce(p_branch_id::text, '(dealer-wide)'), p_doc_type, p_financial_year
      using errcode = 'no_data_found',
            hint = 'Insert a row into document_sequences before issuing this document type.';
  end if;

  return v_prefix || '-' || p_financial_year || '-' || lpad(v_number::text, v_padding, '0');
end;
$$;

comment on function app.next_document_number(uuid, uuid, text, text) is
  'Returns the next number for a document scope, e.g. INV-2026-000001. '
  'Row-locked, so it is safe under concurrent sales (spec §45, §49).';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function app.next_document_number(uuid, uuid, text, text) to authenticated';
  end if;
end;
$$;

revoke execute on function app.next_document_number(uuid, uuid, text, text) from public;
