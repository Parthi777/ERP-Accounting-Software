-- =============================================================================
-- 0069 — Manual journal entries, and reversal from the screen
-- =============================================================================
-- Spec §9, §21, §23, §60.12, §60.13.
--
-- What was missing. `accounting.journals.create` and `accounting.journals.post`
-- have existed as permissions since 0003, spec §9 lists Journal Entries under
-- Accounting, and the screen has only ever *listed* journals. There has been no
-- way to write one: every entry in the ledger arrived through a sale, a receipt
-- or a purchase. A dealer with a bank charge, a depreciation entry, a director's
-- expense or a correction from their accountant had nowhere to put it.
--
-- ── What this is NOT ────────────────────────────────────────────────────────
--
-- It is not an edit. A posted journal cannot be changed — the trigger in 0007
-- refuses it, and its own hint says why: "post a reversal and a corrected entry
-- instead of editing" (spec §23, §60.12). That is not a limitation of the
-- implementation; an immutable ledger is the difference between a book of
-- account and a spreadsheet, and the audit trail depends on it.
--
-- So correcting an entry is two documents and both are visible: the reversal
-- that undoes it, carrying a reason and its author, and the replacement that
-- says what should have happened. Anyone reading the ledger afterwards can see
-- that a correction occurred, which is the entire point.
--
-- app.reverse_journal has done the first half since 0025 and nothing in the UI
-- could reach it. public.reverse_journal_entry is that door.
--
-- Rollback: drop both functions.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- public.post_manual_journal() — an entry a person writes
-- -----------------------------------------------------------------------------
-- p_lines is [{ "account_id": uuid, "debit": n, "credit": n,
--               "narration": text, "party_type": text, "party_id": uuid }, …]
--
-- Balance, line count and account validity are all enforced by app.post_journal
-- and the constraints beneath it. Nothing is re-checked here: a second copy of
-- those rules is a second place for them to drift.
-- -----------------------------------------------------------------------------
create or replace function public.post_manual_journal(
  p_entry_date      date,
  p_narration       text,
  p_lines           jsonb,
  p_branch_id       uuid default null,
  p_idempotency_key text default null
)
returns table (journal_entry_id uuid, entry_number text)
language plpgsql
as $$
declare
  v_dealer uuid;
  v_branch uuid;
  v_entry  uuid;
begin
  v_dealer := app.current_dealer_id();
  if v_dealer is null then
    -- A platform admin has no tenant and no business writing into one's books.
    raise exception 'Only a dealer user can post a journal entry.'
      using errcode = 'insufficient_privilege';
  end if;

  if coalesce(btrim(p_narration), '') = '' then
    raise exception 'A journal entry must say what it is for.'
      using errcode = 'check_violation',
            hint = 'The narration is what makes the entry readable a year later.';
  end if;

  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    raise exception 'A journal entry needs at least two lines.'
      using errcode = 'check_violation';
  end if;

  v_branch := coalesce(p_branch_id, (select id from public.branches
                                      where dealer_id = v_dealer order by code limit 1));

  -- Every line must belong to this dealer's chart. Without this a caller could
  -- name another tenant's account id and post into their books — RLS governs
  -- what is *read*, and this is a write through a SECURITY-scoped path.
  if exists (
    select 1
      from jsonb_array_elements(p_lines) l
     where not exists (
       select 1 from public.chart_of_accounts c
        where c.id = (l ->> 'account_id')::uuid
          and c.dealer_id = v_dealer
     )
  ) then
    raise exception 'A line names an account that does not belong to this dealer.'
      using errcode = 'insufficient_privilege';
  end if;

  v_entry := app.post_journal(
    v_dealer, v_branch, p_entry_date, 'MANUAL', btrim(p_narration), p_lines,
    'MANUAL_JOURNAL', null,
    case when p_idempotency_key is null then null else 'manual:' || p_idempotency_key end
  );

  journal_entry_id := v_entry;
  select je.entry_number into entry_number from public.journal_entries je where je.id = v_entry;
  return next;
end;
$$;

comment on function public.post_manual_journal(date, text, jsonb, uuid, text) is
  'A journal entry written by a person (spec §9, §21) — a bank charge, a '
  'depreciation entry, an accountant''s correction. Balance and line rules come '
  'from app.post_journal; this adds the tenant checks a caller-supplied account '
  'id needs.';

-- -----------------------------------------------------------------------------
-- public.reverse_journal_entry() — the sanctioned correction (spec §23)
-- -----------------------------------------------------------------------------
create or replace function public.reverse_journal_entry(
  p_journal_entry_id uuid,
  p_reason           text,
  p_reversal_date    date default current_date
)
returns table (journal_entry_id uuid, entry_number text)
language plpgsql
as $$
declare
  v_dealer uuid;
  v_owner  uuid;
  v_entry  uuid;
begin
  v_dealer := app.current_dealer_id();

  select dealer_id into v_owner from public.journal_entries where id = p_journal_entry_id;
  if v_owner is null then
    raise exception 'Journal entry not found.' using errcode = 'no_data_found';
  end if;
  if v_dealer is null or v_owner <> v_dealer then
    raise exception 'That journal belongs to another dealer.'
      using errcode = 'insufficient_privilege';
  end if;

  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'A reversal must say why.'
      using errcode = 'check_violation',
            hint = 'Spec §23: the reason is part of the record, not optional.';
  end if;

  v_entry := app.reverse_journal(p_journal_entry_id, btrim(p_reason), p_reversal_date);

  journal_entry_id := v_entry;
  select je.entry_number into entry_number from public.journal_entries je where je.id = v_entry;
  return next;
end;
$$;

comment on function public.reverse_journal_entry(uuid, text, date) is
  'Reverses a posted journal and links the two (spec §23). The only way to undo '
  'a posting: the original stays, the reversal states why, and both are visible '
  'to whoever reads the ledger afterwards.';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice 'Role "authenticated" not present; skipping grants (non-Supabase target).';
    return;
  end if;

  execute 'grant execute on function public.post_manual_journal(date, text, jsonb, uuid, text) to authenticated';
  execute 'grant execute on function public.reverse_journal_entry(uuid, text, date) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0069', 'manual_journal') on conflict (version) do nothing;
