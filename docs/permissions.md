# Permissions

103 permission codes across 15 modules. Defined once in `src/lib/permissions/registry.ts`, seeded
into `public.permissions`, and kept in step by `npm run check:permissions`.

Authorization is **permission-based, never role-name-based**. No check anywhere asks "is this user a
Cashier?" — it asks whether the session holds `sales.view_cost`. Roles are rows that bundle codes, so
a dealer can define its own without a code change (spec §6).

## Format

`module.entity.action` — `sales.view`, `accounting.journals.post`, `admin.users.manage`.

## Enforcement, three layers deep

1. **Navigation.** `visibleNavigation()` filters the sidebar on the server. The browser never
   receives menu entries the session cannot use.
2. **Service.** `requirePermission('sales.post')` throws `ForbiddenError` before any work happens.
3. **Database.** RLS policies gate writes on `app.has_permission(...)`. Even a direct API call with a
   valid JWT is refused.

## Restricted permissions

Seven codes gate cost, margin, profit and commission:

| Code | Gates |
|---|---|
| `dashboard.view_margin` | Margin and profit KPIs |
| `sales.view_cost` | Purchase cost and COGS on a sale |
| `vehicles.view_cost` | Vehicle purchase cost |
| `inventory.view_cost` | Item purchase cost |
| `finance.commission.view` | Finance commission income |
| `reports.margin.view` | Margin reports |
| `reports.profitability.view` | Profitability reports |

Spec §10 and §52 require that a Cashier not *receive* these fields, which is stronger than not
displaying them. Two mechanisms deliver that:

- `scrubRestrictedFields()` removes matching field names from any payload at the service boundary,
  recursing through nested objects and arrays.
- The dashboard service does not construct the margin KPIs at all when the permission is absent —
  they are not in the response to be stripped.

Hiding them in the browser would leave them in the network tab, which is not privacy.

## System roles

Seven roles ship with the product (spec §6). Dealers may add their own; system roles cannot be
edited by a dealer.

| Role | Scope |
|---|---|
| **Platform Admin** | Manages dealers and platform configuration. Sits above the tenant model — tenant access comes from `app.is_platform_admin()`, not from grants |
| **Dealer Owner** | Everything except platform administration, including all restricted permissions |
| **Accounts** | Stock upload, pricing, GST, sale verification, all ledgers, cash book, bank reconciliation, reports, and full cost and margin visibility |
| **Cashier** | Customers, bookings, receipts, sale drafts, selling price, customer balance. **No** restricted permissions |
| **Sales Executive** | Customers, bookings, sale preparation, vehicle availability |
| **Service Advisor** | Job cards, service billing, service payments, service history |
| **Counter Sales** | Accessory and spare counter sales, stock check, invoicing |

The Cashier, Sales Executive, Service Advisor and Counter Sales grants are built in `seed.sql` with
an explicit `and not p.is_sensitive` filter, so adding a new restricted permission cannot silently
widen them.

## Branch access

Separate from permissions, and both must pass.

- `has_all_branch_access` on `user_profiles` — owners and accounts staff see every branch
- `user_branches` — explicit grants for everyone else

`app.can_access_branch()` combines them in RLS; `getTenantContext()` mirrors it in the service layer.
Switching branch is a server action that re-validates membership before writing the cookie: a forged
cookie falls back to the default branch.

## Adding a permission

1. Add it to `src/lib/permissions/registry.ts`.
2. Add the identical row to the `insert into public.permissions` block in `supabase/seed.sql`.
3. Grant it to the appropriate roles in the same file.
4. `npm run check:permissions`.

The check compares code, module and sensitivity in both directions and fails on duplicates. Drift is
not cosmetic: a permission in code but not the database is a check that always denies, and one in the
database but not in code is a grant nothing enforces.
