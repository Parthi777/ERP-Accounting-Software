-- =============================================================================
-- create-platform-admin.sql — grant someone platform administration
-- =============================================================================
-- A platform administrator is the account that onboards dealers. It is the only
-- role that can reach Administration → Dealers → New tenant; without one, that
-- screen shows a dealer's own profile instead — which is why onboarding looks
-- like it is missing.
--
-- There is deliberately no UI for this. The first platform admin cannot be made
-- from inside the application, because making it is what grants the authority to
-- make it.
--
-- ── How to run it ───────────────────────────────────────────────────────────
--
--   1. Supabase Dashboard → Authentication → Users → Add user.
--      Use an address that is NOT one of your dealer logins, for example
--      platform@yourdomain.com. Set a password and tick "Auto Confirm User".
--
--   2. Change the address on the ONE line marked below.
--
--   3. Paste this whole file into the Supabase SQL Editor and Run.
--      (Or: psql "$DATABASE_URL" -f scripts/create-platform-admin.sql)
--
-- ── Why a separate account, and not your existing one ───────────────────────
--
-- A platform admin has dealer_id = null on purpose. app.is_platform_admin()
-- bypasses every RLS policy, so an account that is BOTH a platform admin and
-- attached to a dealer sees every tenant's data mixed into its own screens.
-- Harmless while there is one dealer; misleading the moment there are two.
--
-- Keep the identities apart: your dealership login for dealership work, this one
-- for onboarding.
-- =============================================================================

do $$
declare
  -- ─────────────────────────────────────────────────────────────────────────
  v_email text := 'platform@example.com';   -- ← CHANGE THIS, then Run
  -- ─────────────────────────────────────────────────────────────────────────
  v_uid   uuid;
  v_role  uuid;
begin
  select id into v_uid from auth.users where lower(email) = lower(btrim(v_email));

  if v_uid is null then
    raise exception
      'No Supabase Auth user with the address %. Create it first: Dashboard → Authentication → Users → Add user.',
      v_email;
  end if;

  -- dealer_id stays null: this identity administers the platform and belongs to
  -- no tenant. See the note at the top of this file.
  insert into public.user_profiles
    (id, dealer_id, full_name, email, is_platform_admin, has_all_branch_access, status)
  values
    (v_uid, null, 'Platform Administrator', lower(btrim(v_email)), true, true, 'ACTIVE')
  on conflict (id) do update
    set is_platform_admin = true,
        status            = 'ACTIVE';

  -- Two separate things, both needed. The ROLE puts Administration → Dealers in
  -- the sidebar (it carries the admin.* permissions); the FLAG is what makes
  -- that page show the tenant console instead of a dealer profile.
  select id into v_role from public.roles where code = 'PLATFORM_ADMIN' and dealer_id is null;
  if v_role is null then
    raise exception 'The PLATFORM_ADMIN system role is missing. Run supabase/seed.sql first.';
  end if;

  insert into public.user_roles (user_id, role_id) values (v_uid, v_role)
  on conflict do nothing;

  raise notice '% is now a platform administrator.', v_email;
  raise notice 'Sign in as them and open Administration → Dealers → New tenant.';
end;
$$;

-- Confirms it took. Expect one row, is_platform_admin = t, no_tenant = t.
select up.email,
       up.is_platform_admin,
       up.dealer_id is null      as no_tenant,
       count(rp.permission_code) as permissions
  from public.user_profiles up
  left join public.user_roles ur       on ur.user_id = up.id
  left join public.role_permissions rp on rp.role_id = ur.role_id
 where up.is_platform_admin
 group by up.email, up.is_platform_admin, up.dealer_id;
