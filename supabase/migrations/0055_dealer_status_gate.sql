-- =============================================================================
-- 0055 — A suspended dealer is actually suspended
-- =============================================================================
-- Spec §4, §6, §47, §60.3, §60.20.
--
-- public.dealers.status has accepted 'ACTIVE', 'SUSPENDED' and 'CLOSED' since
-- migration 0002. Nothing has ever read it.
--
-- app.current_dealer_id() is the function every RLS policy in the schema resolves
-- the tenant through, and it checks only that the USER is active:
--
--     select up.dealer_id from public.user_profiles up
--      where up.id = auth.uid() and up.status = 'ACTIVE';
--
-- So a dealer marked SUSPENDED keeps working exactly as before, for every one of
-- their users. There is no way to stop serving a tenant — not for non-payment,
-- not during a dispute, not when they leave. Marking them CLOSED changes a label
-- and nothing else.
--
-- One clause fixes it everywhere at once, which is the point of having a single
-- tenant-resolution function: 133 policies inherit the change without being
-- touched.
--
-- ── Why this ships on its own ───────────────────────────────────────────────
--
-- It alters what every policy in the database returns. That is worth deploying
-- and verifying by itself rather than inside a larger change, because the
-- failure mode in the other direction — a wrong predicate here — locks every
-- tenant out of everything simultaneously.
--
-- Platform admins are unaffected: app.is_platform_admin() is a separate check
-- that does not go through this function, so a suspended dealer can still be
-- administered, looked at and reactivated.
--
-- Rollback: restore app.current_dealer_id() from 0004.
-- =============================================================================

create or replace function app.current_dealer_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select up.dealer_id
    from public.user_profiles up
    join public.dealers d on d.id = up.dealer_id
   where up.id = auth.uid()
     and up.status = 'ACTIVE'
     -- The tenant has to be live too. Without this the status column is a label
     -- rather than a switch, and there is no way to stop serving a dealer.
     and d.status = 'ACTIVE';
$$;

comment on function app.current_dealer_id() is
  'Tenant of the current session, resolved from the JWT (spec §4). Returns NULL '
  'for platform admins, unauthenticated callers, inactive users AND suspended or '
  'closed dealers — so `dealer_id = app.current_dealer_id()` is false for all of '
  'them, and access ends everywhere at once. Deny by default.';
