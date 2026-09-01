-- =============================================================================
-- seed.sql — permission catalogue, system roles, and a demo dealer
-- =============================================================================
-- Two distinct kinds of data live here:
--
--   REQUIRED   The permission catalogue and the seven system roles from spec §6.
--              The application cannot authorize anything without these.
--
--   DEMO       One dealer ("Sri Balaji Motors"), three branches, seven users,
--              employees and a chart of accounts. Every demo row is created
--              inside the `demo` block at the bottom and is removable with the
--              single DELETE at the end of this file.
--
-- Idempotent: safe to run repeatedly. Re-running refreshes the catalogue without
-- disturbing dealer data.
--
-- Demo logins all use the password below; change or remove them before going live.
--   PASSWORD: TwErp@2026
-- =============================================================================

-- =============================================================================
-- REQUIRED — permission catalogue (mirrors src/lib/permissions/registry.ts)
-- =============================================================================
insert into public.permissions (code, module, description, is_sensitive) values
  ('dashboard.view',                  'dashboard',  'View the dashboard', false),
  ('dashboard.view_consolidated',     'dashboard',  'View all branches consolidated', false),
  ('dashboard.view_margin',           'dashboard',  'View margin and profit KPIs', true),

  ('sales.view',                      'sales',      'View vehicle sales', false),
  ('sales.create',                    'sales',      'Create a vehicle sale draft', false),
  ('sales.submit',                    'sales',      'Submit a sale for verification', false),
  ('sales.verify',                    'sales',      'Perform accounts verification of a sale', false),
  ('sales.approve',                   'sales',      'Approve a verified sale', false),
  ('sales.post',                      'sales',      'Post a sale to the accounting engine', false),
  ('sales.deliver',                   'sales',      'Record vehicle delivery', false),
  ('sales.cancel',                    'sales',      'Cancel a sale', false),
  ('sales.return',                    'sales',      'Record a sales return', false),
  ('sales.view_cost',                 'sales',      'View purchase cost and COGS on a sale', true),

  ('bookings.view',                   'bookings',   'View bookings', false),
  ('bookings.create',                 'bookings',   'Create a booking and advance receipt', false),
  ('bookings.cancel',                 'bookings',   'Cancel a booking', false),
  ('bookings.convert',                'bookings',   'Convert a booking into a vehicle sale', false),
  ('bookings.refund',                 'bookings',   'Refund a cancelled booking advance', false),

  ('customers.view',                  'customers',  'View and search customers', false),
  ('customers.create',                'customers',  'Create a customer', false),
  ('customers.edit',                  'customers',  'Edit customer details', false),
  ('customers.view_ledger',           'customers',  'View customer ledger and outstanding', false),

  ('vehicles.stock.view',             'vehicles',   'View chassis-level vehicle stock', false),
  ('vehicles.stock.upload',           'vehicles',   'Upload vehicle stock from CSV/Excel', false),
  ('vehicles.stock.adjust',           'vehicles',   'Adjust vehicle stock', false),
  ('vehicles.models.view',            'vehicles',   'View models and variants', false),
  ('vehicles.models.manage',          'vehicles',   'Manage models and variants', false),
  ('vehicles.pricing.view',           'vehicles',   'View vehicle pricing and price history', false),
  ('vehicles.pricing.manage',         'vehicles',   'Configure vehicle price versions', false),
  ('vehicles.pricing.approve',        'vehicles',   'Approve a price version', false),
  ('vehicles.transfers.view',         'vehicles',   'View vehicle transfers', false),
  ('vehicles.transfers.manage',       'vehicles',   'Raise and receive vehicle transfers', false),
  ('vehicles.view_cost',              'vehicles',   'View vehicle purchase cost', true),

  ('inventory.view',                  'inventory',  'View accessory and spare stock', false),
  ('inventory.items.manage',          'inventory',  'Manage accessory and spare items', false),
  ('inventory.stock.upload',          'inventory',  'Upload accessory/spare stock', false),
  ('inventory.stock.transfer',        'inventory',  'Transfer stock between branches', false),
  ('inventory.stock.adjust',          'inventory',  'Adjust stock quantities', false),
  ('inventory.ledger.view',           'inventory',  'View the stock ledger', false),
  ('inventory.counter_sale.create',   'inventory',  'Create counter sales invoices', false),
  ('inventory.view_cost',             'inventory',  'View item purchase cost', true),

  ('service.jobcards.view',           'service',    'View job cards', false),
  ('service.jobcards.create',         'service',    'Create job cards', false),
  ('service.billing.create',          'service',    'Create service bills', false),
  ('service.payments.collect',        'service',    'Collect service payments', false),
  ('service.history.view',            'service',    'View vehicle and customer service history', false),

  ('finance.companies.view',          'finance',    'View finance companies', false),
  ('finance.companies.manage',        'finance',    'Manage finance companies', false),
  ('finance.applications.view',       'finance',    'View HP/finance applications', false),
  ('finance.applications.manage',     'finance',    'Manage HP/finance applications', false),
  ('finance.trade_advance.view',      'finance',    'View finance-company trade advances', false),
  ('finance.trade_advance.manage',    'finance',    'Record trade advance transactions', false),
  ('finance.settlements.manage',      'finance',    'Record finance settlements', false),
  ('finance.commission.view',         'finance',    'View finance commission income', true),

  ('accounting.coa.view',             'accounting', 'View the chart of accounts', false),
  ('accounting.coa.manage',           'accounting', 'Manage the chart of accounts', false),
  ('accounting.journals.view',        'accounting', 'View journal entries', false),
  ('accounting.journals.create',      'accounting', 'Create draft journal entries', false),
  ('accounting.journals.post',        'accounting', 'Post journal entries', false),
  ('accounting.journals.reverse',     'accounting', 'Reverse a posted journal entry', false),
  ('accounting.periods.manage',       'accounting', 'Open, close and lock accounting periods', false),
  ('accounting.ledgers.view',         'accounting', 'View customer, supplier and finance ledgers', false),
  ('accounting.reports.view',         'accounting', 'View trial balance, P&L and balance sheet', false),

  ('cashbook.view',                   'cashbook',   'View the daily cash book', false),
  ('cashbook.receipts.create',        'cashbook',   'Record cash receipts', false),
  ('cashbook.payments.create',        'cashbook',   'Record cash payments', false),
  ('cashbook.day_close',              'cashbook',   'Count cash and close the day', false),
  ('cashbook.day_reopen',             'cashbook',   'Reopen a closed day for adjustment', false),

  ('bank.accounts.view',              'bank',       'View bank accounts', false),
  ('bank.accounts.manage',            'bank',       'Manage bank accounts', false),
  ('bank.book.view',                  'bank',       'View the bank book', false),
  ('bank.book.record',                'bank',       'Record bank receipts and payments', false),
  ('bank.statement.import',           'bank',       'Import bank statements', false),
  ('bank.reconcile',                  'bank',       'Reconcile bank transactions', false),

  ('gst.summary.view',                'gst',        'View GST summary', false),
  ('gst.einvoice.generate',           'gst',        'Generate e-invoices', false),
  ('gst.einvoice.retry',              'gst',        'Retry failed e-invoice requests', false),
  ('gst.ewaybill.generate',           'gst',        'Generate e-way bills', false),
  ('gst.reports.view',                'gst',        'View GST reports', false),

  ('reports.sales.view',              'reports',    'View sales reports', false),
  ('reports.inventory.view',          'reports',    'View inventory reports', false),
  ('reports.finance.view',            'reports',    'View finance reports', false),
  ('reports.accounting.view',         'reports',    'View accounting reports', false),
  ('reports.branch_performance.view', 'reports',    'View branch performance', false),
  ('reports.consolidated.view',       'reports',    'View consolidated MIS across branches', false),
  ('reports.margin.view',             'reports',    'View margin reports', true),
  ('reports.profitability.view',      'reports',    'View profitability reports', true),

  ('masters.tax.view',                'masters',    'View tax codes', false),
  ('masters.tax.manage',              'masters',    'Manage tax codes and GST rates', false),
  ('masters.hsn.view',                'masters',    'View HSN/SAC codes', false),
  ('masters.hsn.manage',              'masters',    'Manage HSN/SAC codes', false),
  ('masters.employees.view',          'masters',    'View employees', false),
  ('masters.employees.manage',        'masters',    'Manage employees', false),
  ('masters.pricing.manage',          'masters',    'Manage pricing templates', false),
  ('masters.suppliers.view',          'masters',    'View suppliers', false),
  ('masters.suppliers.manage',        'masters',    'Manage suppliers', false),

  ('admin.dealers.view',              'admin',      'View dealer configuration', false),
  ('admin.dealers.manage',            'admin',      'Manage dealer configuration', false),
  ('admin.branches.view',             'admin',      'View branches', false),
  ('admin.branches.manage',           'admin',      'Create and manage branches', false),
  ('admin.users.view',                'admin',      'View users', false),
  ('admin.users.manage',              'admin',      'Create and manage users and their access', false),
  ('admin.roles.view',                'admin',      'View roles and permissions', false),
  ('admin.roles.manage',              'admin',      'Manage roles and permission assignments', false),
  ('admin.audit.view',                'admin',      'View the audit trail', false),
  ('admin.settings.view',             'admin',      'View system settings', false),
  ('admin.settings.manage',           'admin',      'Manage system settings and document sequences', false)
on conflict (code) do update
  set module       = excluded.module,
      description  = excluded.description,
      is_sensitive = excluded.is_sensitive;

-- =============================================================================
-- REQUIRED — system roles (spec §6)
-- =============================================================================
insert into public.roles (code, name, description, is_system, dealer_id) values
  ('PLATFORM_ADMIN',  'Platform Admin',   'Manages dealers and platform configuration', true, null),
  ('DEALER_OWNER',    'Dealer Owner',     'Full access to the dealer, all branches, all financials', true, null),
  ('ACCOUNTS',        'Accounts',         'Accounting, pricing, GST, verification and margin visibility', true, null),
  ('CASHIER',         'Cashier',          'Bookings, receipts and sales drafts; no cost or margin access', true, null),
  ('SALES_EXECUTIVE', 'Sales Executive',  'Customers, bookings and sale preparation', true, null),
  ('SERVICE_ADVISOR', 'Service Advisor',  'Job cards, service billing and service payments', true, null),
  ('COUNTER_SALES',   'Counter Sales',    'Accessory and spare counter sales', true, null)
-- Matches the partial index roles_system_code_key (unique on code where dealer_id is null).
on conflict (code) where dealer_id is null do update
  set name        = excluded.name,
      description = excluded.description;

-- -----------------------------------------------------------------------------
-- Role → permission grants
-- -----------------------------------------------------------------------------
-- Rebuilt from scratch on every run so the matrix here is authoritative.
delete from public.role_permissions rp
 using public.roles r
 where r.id = rp.role_id and r.is_system;

-- PLATFORM_ADMIN: platform-level administration. Tenant data access comes from
-- app.is_platform_admin(), not from these grants.
insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join public.permissions p
 where r.code = 'PLATFORM_ADMIN'
   and p.module = 'admin';

-- DEALER_OWNER: everything except platform administration (spec §6).
insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join public.permissions p
 where r.code = 'DEALER_OWNER'
   and p.code <> 'admin.dealers.manage';

-- ACCOUNTS: stock upload, pricing, GST, verification, all ledgers and reports,
-- and full cost/margin visibility (spec §6).
insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join public.permissions p
 where r.code = 'ACCOUNTS'
   and (
        p.module in ('accounting', 'cashbook', 'bank', 'gst', 'reports', 'masters', 'inventory', 'vehicles', 'finance')
     or p.code in (
          'dashboard.view', 'dashboard.view_consolidated', 'dashboard.view_margin',
          'sales.view', 'sales.verify', 'sales.approve', 'sales.post', 'sales.cancel',
          'sales.return', 'sales.view_cost',
          'bookings.view', 'bookings.cancel', 'bookings.refund',
          'customers.view', 'customers.view_ledger',
          'service.jobcards.view', 'service.history.view',
          'admin.audit.view', 'admin.settings.view', 'admin.settings.manage',
          'admin.branches.view', 'admin.users.view'
        )
   );

-- CASHIER: bookings, receipts, sale drafts, selling price and customer balance.
-- Explicitly excludes every sensitive permission (spec §6, §52).
insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join public.permissions p
 where r.code = 'CASHIER'
   and not p.is_sensitive
   and p.code in (
     'dashboard.view',
     'customers.view', 'customers.create', 'customers.edit', 'customers.view_ledger',
     'bookings.view', 'bookings.create',
     'sales.view', 'sales.create', 'sales.submit',
     'vehicles.stock.view', 'vehicles.pricing.view',
     'inventory.view',
     'cashbook.view', 'cashbook.receipts.create'
   );

-- SALES_EXECUTIVE: customers, bookings, sale preparation, vehicle availability.
insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join public.permissions p
 where r.code = 'SALES_EXECUTIVE'
   and not p.is_sensitive
   and p.code in (
     'dashboard.view',
     'customers.view', 'customers.create', 'customers.edit',
     'bookings.view', 'bookings.create',
     'sales.view', 'sales.create', 'sales.submit',
     'vehicles.stock.view', 'vehicles.models.view', 'vehicles.pricing.view'
   );

-- SERVICE_ADVISOR: job cards, service billing, service payments.
insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join public.permissions p
 where r.code = 'SERVICE_ADVISOR'
   and not p.is_sensitive
   and p.code in (
     'dashboard.view',
     'customers.view', 'customers.create', 'customers.edit',
     'service.jobcards.view', 'service.jobcards.create',
     'service.billing.create', 'service.payments.collect', 'service.history.view',
     'inventory.view',
     'vehicles.stock.view'
   );

-- COUNTER_SALES: accessory and spare sales over the counter.
insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join public.permissions p
 where r.code = 'COUNTER_SALES'
   and not p.is_sensitive
   and p.code in (
     'dashboard.view',
     'customers.view', 'customers.create',
     'inventory.view', 'inventory.counter_sale.create',
     'cashbook.view', 'cashbook.receipts.create'
   );

-- =============================================================================
-- DEMO — one dealer, three branches, seven users, chart of accounts
-- =============================================================================
-- Remove everything below with:
--   psql "$DATABASE_URL" -f scripts/remove-demo-dealer.sql
--
-- Not a plain `delete from public.dealers where code = 'SBM'` — that fails on
-- branches_dealer_id_fkey, and deleting the children first fails on the
-- append-only ledger triggers. Both are the schema defending itself correctly;
-- the script is the sanctioned way through.
-- =============================================================================
do $$
declare
  v_dealer_id   uuid;
  v_main        uuid;
  v_north       uuid;
  v_south       uuid;
  v_fy          text := '2026';
  v_user        record;
  v_role_id     uuid;
  v_account     record;
  v_parent_id   uuid;
  -- Real Supabase's auth.users carries encrypted_password; the local shim does not.
  v_is_shim     boolean := not exists (
    select 1 from information_schema.columns
     where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password'
  );
begin
  -- ── Dealer ────────────────────────────────────────────────────────────────
  insert into public.dealers (code, legal_name, trade_name, gstin, pan,
                              address_line1, city, state, state_code, pincode, phone, email)
  values ('SBM', 'Sri Balaji Motors Private Limited', 'Sri Balaji Motors',
          '33AABCS1429B1ZQ', 'AABCS1429B',
          '142 Anna Salai', 'Chennai', 'Tamil Nadu', '33', '600002',
          '+914428520000', 'accounts@sribalajimotors.example')
  on conflict (code) do update set legal_name = excluded.legal_name
  returning id into v_dealer_id;

  -- ── Branches ──────────────────────────────────────────────────────────────
  insert into public.branches (dealer_id, code, name, gstin, city, state, state_code, pincode, is_head_office)
  values (v_dealer_id, 'MAIN', 'Main Branch', '33AABCS1429B1ZQ', 'Chennai', 'Tamil Nadu', '33', '600002', true)
  on conflict (dealer_id, code) do update set name = excluded.name
  returning id into v_main;

  insert into public.branches (dealer_id, code, name, gstin, city, state, state_code, pincode)
  values (v_dealer_id, 'NORTH', 'Ambattur Branch', '33AABCS1429B1ZQ', 'Chennai', 'Tamil Nadu', '33', '600053')
  on conflict (dealer_id, code) do update set name = excluded.name
  returning id into v_north;

  insert into public.branches (dealer_id, code, name, gstin, city, state, state_code, pincode)
  values (v_dealer_id, 'SOUTH', 'Tambaram Branch', '33AABCS1429B1ZQ', 'Chennai', 'Tamil Nadu', '33', '600045')
  on conflict (dealer_id, code) do update set name = excluded.name
  returning id into v_south;

  -- ── Users, one per system role ────────────────────────────────────────────
  -- Only against the local test shim.
  --
  -- On a real Supabase project, a login must be created through Supabase Auth so
  -- GoTrue owns the password hash and the account metadata. Writing rows into
  -- auth.users by hand produces accounts that cannot sign in, and worse, squats
  -- on the email address so creating the account properly later fails on the
  -- unique index.
  --
  -- So: create the users in Authentication → Users, then run
  -- scripts/link-auth-users.sql, which matches them by email and wires up the
  -- profile, role and branch rows.
  if not v_is_shim then
    raise notice 'Real Supabase detected — skipping demo user creation.';
    raise notice 'Create the logins in Authentication → Users, then run scripts/link-auth-users.sql.';
  end if;

  for v_user in
    select * from (values
      ('11111111-1111-4111-8111-111111111111'::uuid, 'owner@sribalajimotors.example',   'Rajesh Kumar',   'DEALER_OWNER',    true),
      ('22222222-2222-4222-8222-222222222222'::uuid, 'accounts@sribalajimotors.example','Priya Venkatesh','ACCOUNTS',        true),
      ('33333333-3333-4333-8333-333333333333'::uuid, 'cashier@sribalajimotors.example', 'Anand Raj',      'CASHIER',         false),
      ('44444444-4444-4444-8444-444444444444'::uuid, 'sales@sribalajimotors.example',   'Divya Shankar',  'SALES_EXECUTIVE', false),
      ('55555555-5555-4555-8555-555555555555'::uuid, 'service@sribalajimotors.example', 'Karthik Murali', 'SERVICE_ADVISOR', false),
      ('66666666-6666-4666-8666-666666666666'::uuid, 'counter@sribalajimotors.example', 'Meena Lakshmi',  'COUNTER_SALES',   false)
    ) as t(id, email, full_name, role_code, all_branches)
  loop
    continue when not v_is_shim;

    insert into auth.users (id, email) values (v_user.id, v_user.email)
    on conflict (id) do nothing;

    insert into public.user_profiles (id, dealer_id, full_name, email, has_all_branch_access, default_branch_id)
    values (v_user.id, v_dealer_id, v_user.full_name, v_user.email, v_user.all_branches, v_main)
    on conflict (id) do update
      set full_name             = excluded.full_name,
          has_all_branch_access = excluded.has_all_branch_access,
          default_branch_id     = excluded.default_branch_id;

    select id into v_role_id from public.roles where code = v_user.role_code and dealer_id is null;
    insert into public.user_roles (user_id, role_id) values (v_user.id, v_role_id)
    on conflict do nothing;

    -- Branch-limited users get an explicit grant to the main branch only.
    if not v_user.all_branches then
      insert into public.user_branches (user_id, branch_id, dealer_id)
      values (v_user.id, v_main, v_dealer_id)
      on conflict do nothing;
    end if;
  end loop;

  -- A platform admin, outside the tenant model. Shim only, for the same reason.
  if v_is_shim then
    insert into auth.users (id, email)
    values ('00000000-0000-4000-8000-000000000000', 'platform@twerp.example')
    on conflict (id) do nothing;

    insert into public.user_profiles (id, dealer_id, full_name, email, is_platform_admin)
    values ('00000000-0000-4000-8000-000000000000', null, 'Platform Administrator', 'platform@twerp.example', true)
    on conflict (id) do update set is_platform_admin = true;

    insert into public.user_roles (user_id, role_id)
    select '00000000-0000-4000-8000-000000000000',
           id from public.roles where code = 'PLATFORM_ADMIN' and dealer_id is null
    on conflict do nothing;
  end if;

  -- ── Employees (spec §12) ──────────────────────────────────────────────────
  -- user_id is attached only under the shim; on Supabase, link-auth-users.sql
  -- fills it in once the real logins exist.
  insert into public.employees (dealer_id, branch_id, employee_code, name, department, designation, mobile, joining_date, user_id)
  select e.dealer_id, e.branch_id, e.employee_code, e.name, e.department, e.designation,
         e.mobile, e.joining_date, case when v_is_shim then e.user_id else null end
    from (values
    (v_dealer_id, v_main,  'EMP0001', 'Rajesh Kumar',    'Management', 'Managing Director', '9840012001', date '2015-04-01', '11111111-1111-4111-8111-111111111111'),
    (v_dealer_id, v_main,  'EMP0002', 'Priya Venkatesh', 'Accounts',   'Accounts Manager',  '9840012002', date '2018-06-15', '22222222-2222-4222-8222-222222222222'),
    (v_dealer_id, v_main,  'EMP0003', 'Anand Raj',       'Front Desk', 'Cashier',           '9840012003', date '2021-01-11', '33333333-3333-4333-8333-333333333333'),
    (v_dealer_id, v_main,  'EMP0004', 'Divya Shankar',   'Sales',      'Sales Executive',   '9840012004', date '2022-08-01', '44444444-4444-4444-8444-444444444444'),
    (v_dealer_id, v_main,  'EMP0005', 'Karthik Murali',  'Service',    'Service Advisor',   '9840012005', date '2020-03-02', '55555555-5555-4555-8555-555555555555'),
    (v_dealer_id, v_main,  'EMP0006', 'Meena Lakshmi',   'Counter',    'Counter Sales',     '9840012006', date '2023-05-20', '66666666-6666-4666-8666-666666666666'),
    (v_dealer_id, v_north, 'EMP0007', 'Suresh Babu',     'Sales',      'Branch Manager',    '9840012007', date '2019-09-09', null),
    (v_dealer_id, v_south, 'EMP0008', 'Vidya Ramesh',    'Sales',      'Branch Manager',    '9840012008', date '2019-11-01', null::uuid)
  ) as e(dealer_id, branch_id, employee_code, name, department, designation, mobile, joining_date, user_id)
  on conflict (dealer_id, employee_code) do update set name = excluded.name;

  -- ── Chart of accounts (spec §24) ──────────────────────────────────────────
  -- Group headers first, then the postable leaves beneath them.
  for v_account in
    select * from (values
      ('1000', 'Assets',                    'ASSET',     'DEBIT',  true,  null,   false),
      ('1100', 'Cash',                      'ASSET',     'DEBIT',  false, '1000', true),
      ('1200', 'Bank',                      'ASSET',     'DEBIT',  false, '1000', true),
      ('1300', 'Customer Receivable',       'ASSET',     'DEBIT',  false, '1000', false),
      ('1400', 'Finance Receivable',        'ASSET',     'DEBIT',  false, '1000', false),
      ('1500', 'Vehicle Inventory',         'ASSET',     'DEBIT',  false, '1000', true),
      ('1600', 'Accessories Inventory',     'ASSET',     'DEBIT',  false, '1000', true),
      ('1700', 'Spare Inventory',           'ASSET',     'DEBIT',  false, '1000', true),
      ('1800', 'Other Receivables',         'ASSET',     'DEBIT',  false, '1000', false),

      ('2000', 'Liabilities',               'LIABILITY', 'CREDIT', true,  null,   false),
      ('2100', 'Customer Advances',         'LIABILITY', 'CREDIT', false, '2000', false),
      ('2200', 'Supplier Payables',         'LIABILITY', 'CREDIT', false, '2000', false),
      ('2300', 'Output CGST',               'LIABILITY', 'CREDIT', false, '2000', false),
      ('2400', 'Output SGST',               'LIABILITY', 'CREDIT', false, '2000', false),
      ('2500', 'Output IGST',               'LIABILITY', 'CREDIT', false, '2000', false),
      ('2600', 'Finance Company Payable',   'LIABILITY', 'CREDIT', false, '2000', false),
      ('2700', 'Other Payables',            'LIABILITY', 'CREDIT', false, '2000', false),

      ('3000', 'Equity',                    'EQUITY',    'CREDIT', true,  null,   false),
      ('3100', 'Share Capital',             'EQUITY',    'CREDIT', false, '3000', false),
      ('3200', 'Retained Earnings',         'EQUITY',    'CREDIT', false, '3000', false),

      ('4000', 'Income',                    'INCOME',    'CREDIT', true,  null,   false),
      ('4100', 'Vehicle Sales',             'INCOME',    'CREDIT', false, '4000', true),
      ('4200', 'Accessories Sales',         'INCOME',    'CREDIT', false, '4000', true),
      ('4300', 'Spare Sales',               'INCOME',    'CREDIT', false, '4000', true),
      ('4400', 'Service Labour',            'INCOME',    'CREDIT', false, '4000', true),
      ('4500', 'Finance Commission',        'INCOME',    'CREDIT', false, '4000', true),
      ('4600', 'Insurance Commission',      'INCOME',    'CREDIT', false, '4000', true),
      ('4700', 'Forwarding Income',         'INCOME',    'CREDIT', false, '4000', true),
      ('4800', 'Other Income',              'INCOME',    'CREDIT', false, '4000', true),

      ('5000', 'Costs and Expenses',        'EXPENSE',   'DEBIT',  true,  null,   false),
      ('5100', 'Vehicle COGS',              'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5200', 'Accessories COGS',          'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5300', 'Spare COGS',                'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5400', 'Service Cost',              'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5500', 'Salaries',                  'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5600', 'Rent',                      'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5700', 'Utilities',                 'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5800', 'Bank Charges',              'EXPENSE',   'DEBIT',  false, '5000', true),
      ('5900', 'Other Expenses',            'EXPENSE',   'DEBIT',  false, '5000', true)
    ) as t(code, name, account_type, normal_balance, is_group, parent_code, branch_scoped)
    order by code
  loop
    v_parent_id := null;
    if v_account.parent_code is not null then
      select id into v_parent_id
        from public.chart_of_accounts
       where dealer_id = v_dealer_id and code = v_account.parent_code;
    end if;

    insert into public.chart_of_accounts
      (dealer_id, code, name, account_type, normal_balance, is_group, parent_id, is_system, is_branch_scoped)
    values
      (v_dealer_id, v_account.code, v_account.name, v_account.account_type,
       v_account.normal_balance, v_account.is_group, v_parent_id, true, v_account.branch_scoped)
    on conflict (dealer_id, code) do update set name = excluded.name;
  end loop;

  -- ── Default accounting rules (spec §22) ───────────────────────────────────
  -- Called here rather than relying on migration 0027's loop: at migration time
  -- this dealer and its chart of accounts do not exist yet, so there is nothing
  -- for that loop to map. (The loop still serves a database that is being
  -- upgraded, where the dealer is already present.)
  perform app.seed_default_accounting_rules(v_dealer_id);
  perform app.seed_finance_accounting_rules(v_dealer_id);

  -- ── Accounting period: Indian FY 2026-27 ──────────────────────────────────
  insert into public.accounting_periods (dealer_id, name, start_date, end_date, status)
  values (v_dealer_id, 'FY 2026-27', date '2026-04-01', date '2027-03-31', 'OPEN')
  on conflict (dealer_id, start_date, end_date) do nothing;

  -- ── Document sequences (spec §45) ─────────────────────────────────────────
  -- All dealer-wide (branch_id null).
  --
  -- Every number below is stored in a column that is unique per *dealer* —
  -- sales_invoice_key, bookings_number_key, the three receipt keys, jc_number_key,
  -- si_number_key, vehicle_transfers_number_key, deliveries_number_key. A
  -- per-branch counter cannot feed a per-dealer unique column: every branch
  -- starts at 1 with the same prefix, so the second branch to issue its first
  -- document collides with the first (spec §45, §60.3).
  --
  -- The branch is still recorded on every document; it is simply not what
  -- allocates the number. app.next_document_number() prefers a dealer-wide row
  -- over a branch one, so a type that ever needs a per-branch series just omits
  -- its dealer-wide row here.
  insert into public.document_sequences (dealer_id, branch_id, doc_type, financial_year, prefix, padding)
  values (v_dealer_id, null, 'VEHICLE_INVOICE',     v_fy, 'INV', 6),
         (v_dealer_id, null, 'BOOKING',             v_fy, 'BK',  6),
         (v_dealer_id, null, 'RECEIPT',             v_fy, 'REC', 6),
         (v_dealer_id, null, 'PAYMENT',             v_fy, 'PAY', 6),
         (v_dealer_id, null, 'JOB_CARD',            v_fy, 'JC',  6),
         (v_dealer_id, null, 'SERVICE_INVOICE',     v_fy, 'SVC', 6),
         (v_dealer_id, null, 'COUNTER_INVOICE',     v_fy, 'CSI', 6),
         (v_dealer_id, null, 'JOURNAL',             v_fy, 'JE',  6),
         (v_dealer_id, null, 'BANK_RECONCILIATION', v_fy, 'BRS', 6),
         (v_dealer_id, null, 'STOCK_TRANSFER',      v_fy, 'TRF', 6),
         (v_dealer_id, null, 'DELIVERY',            v_fy, 'DN',  6),
         (v_dealer_id, null, 'FINANCE_APPLICATION', v_fy, 'FA',  6),
         (v_dealer_id, null, 'FINANCE_SETTLEMENT',  v_fy, 'FS',  6)
  on conflict on constraint document_sequences_scope_key do nothing;

  -- ── Settings ──────────────────────────────────────────────────────────────
  insert into public.system_settings (dealer_id, key, value, value_type, description, is_public)
  values
    (v_dealer_id, 'accounting.booking_recognises_revenue', 'false'::jsonb, 'boolean',
     'Bookings post to Customer Advances rather than revenue (spec §18).', true),
    (v_dealer_id, 'inventory.allow_negative_stock', 'false'::jsonb, 'boolean',
     'Counter sales cannot drive stock below zero (spec §33).', true),
    (v_dealer_id, 'inventory.accessory_allocation_order', '["LOCAL","COMPANY"]'::jsonb, 'json',
     'Consume local accessory stock before company stock (spec §31).', true),
    (v_dealer_id, 'cashbook.require_daily_close', 'true'::jsonb, 'boolean',
     'Daily cash closing is mandatory (spec §60.15).', true),
    (v_dealer_id, 'counter_sale.require_customer', 'false'::jsonb, 'boolean',
     'Require a customer on every counter sale (spec §33).', true)
  on conflict on constraint system_settings_scope_key do update set value = excluded.value;

  raise notice 'Seeded dealer %: % branches, % users, % employees, % accounts.',
    v_dealer_id,
    (select count(*) from public.branches           where dealer_id = v_dealer_id),
    (select count(*) from public.user_profiles      where dealer_id = v_dealer_id),
    (select count(*) from public.employees          where dealer_id = v_dealer_id),
    (select count(*) from public.chart_of_accounts  where dealer_id = v_dealer_id);
end;
$$;
