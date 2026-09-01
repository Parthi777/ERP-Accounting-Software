-- =============================================================================
-- link-auth-users.sql — attach Supabase Auth accounts to the ERP tenant model
-- =============================================================================
-- Run this AFTER creating the logins in the Supabase dashboard
-- (Authentication → Users → Add user), and after supabase/seed.sql.
--
-- Why this exists: a login must be created by Supabase Auth so GoTrue owns the
-- password hash and account metadata. That means the user id is generated at
-- creation time and cannot be predicted by a seed file. This script matches
-- accounts by EMAIL and provisions everything the ERP needs around them:
--
--   user_profiles  → tenant, name, branch reach, default branch
--   user_roles     → the system role granting their permissions
--   user_branches  → explicit branch grants for branch-limited staff
--   employees      → links the employee record to the login
--
-- Idempotent: safe to run again after adding another user. Accounts that do not
-- exist in auth.users yet are reported and skipped, not treated as an error.
--
-- To wire up YOUR OWN users rather than the demo set, edit the values list below:
--   email, full name, role code, has_all_branch_access, employee code (or null)
--
-- Role codes: DEALER_OWNER, ACCOUNTS, CASHIER, SALES_EXECUTIVE,
--             SERVICE_ADVISOR, COUNTER_SALES, PLATFORM_ADMIN
-- =============================================================================

do $$
declare
  v_dealer_id uuid;
  v_main      uuid;
  v_row       record;
  v_user_id   uuid;
  v_role_id   uuid;
  v_linked    int := 0;
  v_missing   int := 0;
begin
  select id into v_dealer_id from public.dealers where code = 'SBM';
  if v_dealer_id is null then
    raise exception 'Dealer SBM not found. Run supabase/seed.sql first.';
  end if;

  select id into v_main from public.branches where dealer_id = v_dealer_id and code = 'MAIN';

  for v_row in
    select * from (values
      -- email                              full name          role              all branches  employee
      ('owner@sribalajimotors.example',    'Rajesh Kumar',    'DEALER_OWNER',    true,  'EMP0001'),
      ('accounts@sribalajimotors.example', 'Priya Venkatesh', 'ACCOUNTS',        true,  'EMP0002'),
      ('cashier@sribalajimotors.example',  'Anand Raj',       'CASHIER',         false, 'EMP0003'),
      ('sales@sribalajimotors.example',    'Divya Shankar',   'SALES_EXECUTIVE', false, 'EMP0004'),
      ('service@sribalajimotors.example',  'Karthik Murali',  'SERVICE_ADVISOR', false, 'EMP0005'),
      ('counter@sribalajimotors.example',  'Meena Lakshmi',   'COUNTER_SALES',   false, 'EMP0006')
    ) as t(email, full_name, role_code, all_branches, employee_code)
  loop
    select id into v_user_id
      from auth.users
     where lower(email) = lower(v_row.email);

    if v_user_id is null then
      raise notice 'skip   % — no Supabase Auth account with that address', v_row.email;
      v_missing := v_missing + 1;
      continue;
    end if;

    insert into public.user_profiles
      (id, dealer_id, full_name, email, has_all_branch_access, default_branch_id, status)
    values
      (v_user_id, v_dealer_id, v_row.full_name, v_row.email, v_row.all_branches, v_main, 'ACTIVE')
    on conflict (id) do update
      set dealer_id             = excluded.dealer_id,
          full_name             = excluded.full_name,
          email                 = excluded.email,
          has_all_branch_access = excluded.has_all_branch_access,
          default_branch_id     = excluded.default_branch_id,
          status                = 'ACTIVE';

    select id into v_role_id
      from public.roles
     where code = v_row.role_code and dealer_id is null;

    if v_role_id is null then
      raise exception 'System role % not found. Run supabase/seed.sql first.', v_row.role_code;
    end if;

    -- One system role per demo user; replace rather than accumulate on re-runs.
    delete from public.user_roles ur
     using public.roles r
     where ur.user_id = v_user_id and r.id = ur.role_id and r.is_system;

    insert into public.user_roles (user_id, role_id)
    values (v_user_id, v_role_id)
    on conflict do nothing;

    -- Branch-limited staff get an explicit grant; all-branch users need none.
    if v_row.all_branches then
      delete from public.user_branches where user_id = v_user_id;
    else
      insert into public.user_branches (user_id, branch_id, dealer_id)
      values (v_user_id, v_main, v_dealer_id)
      on conflict do nothing;
    end if;

    if v_row.employee_code is not null then
      update public.employees
         set user_id = v_user_id
       where dealer_id = v_dealer_id
         and employee_code = v_row.employee_code;
    end if;

    raise notice 'linked % → % (%)', v_row.email, v_row.full_name, v_row.role_code;
    v_linked := v_linked + 1;
  end loop;

  raise notice '';
  raise notice '% user(s) linked, % missing from Supabase Auth.', v_linked, v_missing;

  if v_missing > 0 then
    raise notice 'Create the missing accounts in Authentication → Users, then run this again.';
  end if;
end;
$$;

-- What each account can now do. Sign in as accounts@ to see cost and margin;
-- sign in as cashier@ to confirm those same figures are absent.
select
  up.email,
  up.full_name,
  -- DISTINCT matters: the role_permissions join multiplies each role by its
  -- permission count, which would otherwise print the role name 100 times.
  string_agg(distinct r.name, ', ')                              as roles,
  case when up.has_all_branch_access then 'all branches'
       else coalesce((select string_agg(b.code, ', ')
                        from public.user_branches ub
                        join public.branches b on b.id = ub.branch_id
                       where ub.user_id = up.id), 'none') end    as branch_access,
  count(distinct rp.permission_code)                             as permissions,
  count(distinct rp.permission_code) filter (where p.is_sensitive) as restricted
from public.user_profiles up
left join public.user_roles ur      on ur.user_id = up.id
left join public.roles r            on r.id = ur.role_id
left join public.role_permissions rp on rp.role_id = r.id
left join public.permissions p      on p.code = rp.permission_code
group by up.id, up.email, up.full_name, up.has_all_branch_access
order by up.email;
