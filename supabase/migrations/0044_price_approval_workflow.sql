-- =============================================================================
-- 0044 — Price approval workflow
-- =============================================================================
-- Spec §15, §17, §60.9.
--
-- 0018 built a price version for an approval workflow it never got: the status
-- check allows DRAFT → SUBMITTED → APPROVED → ACTIVE, the table carries
-- submitted_at/submitted_by/approved_at/approved_by, and the permission
-- `vehicles.pricing.approve` exists — but nothing ever moves a version between
-- those states. createPriceVersion inserts ACTIVE with the approval stamps
-- pre-filled, so a price goes live the moment one person saves it. Spec §15 asks
-- for DRAFT → SUBMITTED → APPROVED → ACTIVE precisely because a price change is
-- what every future invoice is computed from.
--
-- Two things are fixed here:
--
-- 1. `masters.pricing.manage` granted no database access at all. The Masters
--    screen is gated on it, so a user holding only that permission passed the
--    page check and then saw nothing, because the RLS on this table knows only
--    `vehicles.pricing.*`. The policies now recognise both.
--
-- 2. public.decide_price_version() moves a version through the workflow, and is
--    the only way a price goes live. Activation supersedes the incumbent in the
--    same statement, because vpv_active_scope_key permits exactly one ACTIVE
--    price per scope.
--
-- Rollback: restore the three policies from 0018 and drop
--           public.decide_price_version(uuid, text, text).
-- =============================================================================

drop policy if exists vpv_select on public.vehicle_price_versions;
drop policy if exists vpv_insert on public.vehicle_price_versions;
drop policy if exists vpv_update on public.vehicle_price_versions;

create policy vpv_select on public.vehicle_price_versions for select to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('vehicles.pricing.view')
                  or app.has_permission('masters.pricing.manage'))));

create policy vpv_insert on public.vehicle_price_versions for insert to authenticated
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('vehicles.pricing.manage')
                  or app.has_permission('masters.pricing.manage'))));

create policy vpv_update on public.vehicle_price_versions for update to authenticated
  using (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('vehicles.pricing.manage')
                  or app.has_permission('vehicles.pricing.approve')
                  or app.has_permission('masters.pricing.manage'))))
  with check (app.is_platform_admin()
         or (dealer_id = app.current_dealer_id()
             and (app.has_permission('vehicles.pricing.manage')
                  or app.has_permission('vehicles.pricing.approve')
                  or app.has_permission('masters.pricing.manage'))));

-- -----------------------------------------------------------------------------
-- public.decide_price_version() — spec §15
-- -----------------------------------------------------------------------------
create or replace function public.decide_price_version(
  p_version_id uuid,
  p_action     text,
  p_reason     text default null
)
returns text
language plpgsql
as $$
declare
  v_v      public.vehicle_price_versions;
  v_status text;
begin
  select * into v_v from public.vehicle_price_versions where id = p_version_id for update;

  if v_v.id is null then
    raise exception 'Price version not found.' using errcode = 'no_data_found';
  end if;
  if p_action not in ('SUBMIT', 'APPROVE', 'REJECT', 'ACTIVATE') then
    raise exception 'Unknown action %.', p_action using errcode = 'check_violation';
  end if;

  if p_action = 'SUBMIT' then
    if v_v.status <> 'DRAFT' then
      raise exception 'Only a draft can be submitted; version % is %.', v_v.version_number, v_v.status
        using errcode = 'check_violation';
    end if;
    update public.vehicle_price_versions
       set status = 'SUBMITTED', submitted_at = now(), submitted_by = auth.uid()
     where id = p_version_id;
    v_status := 'SUBMITTED';

  elsif p_action = 'APPROVE' then
    if v_v.status <> 'SUBMITTED' then
      raise exception 'Only a submitted price can be approved; version % is %.',
        v_v.version_number, v_v.status using errcode = 'check_violation';
    end if;
    -- A price one person can write, submit and approve alone is not reviewed at
    -- all, and DEALER_OWNER holds both permissions.
    if v_v.submitted_by is not null and v_v.submitted_by = auth.uid() then
      raise exception 'A price must be approved by someone other than the person who submitted it.'
        using errcode = 'insufficient_privilege',
              hint = 'Spec §15: the approval step exists to be a second pair of eyes.';
    end if;
    update public.vehicle_price_versions
       set status = 'APPROVED', approved_at = now(), approved_by = auth.uid()
     where id = p_version_id;
    v_status := 'APPROVED';

  elsif p_action = 'REJECT' then
    if v_v.status <> 'SUBMITTED' then
      raise exception 'Only a submitted price can be rejected; version % is %.',
        v_v.version_number, v_v.status using errcode = 'check_violation';
    end if;
    if coalesce(btrim(p_reason), '') = '' then
      raise exception 'A rejection must say why.'
        using errcode = 'check_violation',
              hint = 'Spec §15: the reason is what makes the rejection reviewable.';
    end if;
    update public.vehicle_price_versions
       set status = 'REJECTED',
           notes = coalesce(notes || E'\n', '') || 'Rejected: ' || btrim(p_reason)
     where id = p_version_id;
    v_status := 'REJECTED';

  else -- ACTIVATE
    if v_v.status <> 'APPROVED' then
      raise exception 'Only an approved price can go live; version % is %.',
        v_v.version_number, v_v.status using errcode = 'check_violation';
    end if;

    -- Supersede the incumbent first: vpv_active_scope_key allows exactly one
    -- ACTIVE row per (dealer, model, variant, branch), so activating before
    -- retiring the old one would violate it.
    update public.vehicle_price_versions
       set status = 'SUPERSEDED',
           effective_to = v_v.effective_from - 1
     where dealer_id = v_v.dealer_id
       and model_id = v_v.model_id
       and coalesce(variant_id, '00000000-0000-0000-0000-000000000000'::uuid)
             = coalesce(v_v.variant_id, '00000000-0000-0000-0000-000000000000'::uuid)
       and coalesce(branch_id, '00000000-0000-0000-0000-000000000000'::uuid)
             = coalesce(v_v.branch_id, '00000000-0000-0000-0000-000000000000'::uuid)
       and status = 'ACTIVE'
       and id <> p_version_id;

    update public.vehicle_price_versions set status = 'ACTIVE' where id = p_version_id;
    v_status := 'ACTIVE';
  end if;

  return v_status;
end;
$$;

comment on function public.decide_price_version(uuid, text, text) is
  'Moves a price version through DRAFT → SUBMITTED → APPROVED → ACTIVE (spec §15). '
  'The only way a price goes live; activation supersedes the incumbent.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.decide_price_version(uuid, text, text) to authenticated';
  end if;
end;
$$;
