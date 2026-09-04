/**
 * Permission catalogue — spec §6, §47.
 *
 * Authorization is permission-based, never role-name-based. A role is a row that
 * bundles codes from this list, so a dealer can invent its own roles without a
 * code change, and a check never reads "is this user a Cashier?".
 *
 * This file is the source of truth. `supabase/seed.sql` inserts the same codes
 * into `public.permissions`, and `npm run check:permissions` fails the build if
 * the two ever drift apart.
 */

export type PermissionModule =
  | 'dashboard'
  | 'sales'
  | 'bookings'
  | 'customers'
  | 'vehicles'
  | 'inventory'
  | 'purchases'
  | 'hr'
  | 'service'
  | 'finance'
  | 'accounting'
  | 'cashbook'
  | 'bank'
  | 'gst'
  | 'reports'
  | 'masters'
  | 'admin';

export interface PermissionDefinition {
  readonly code: string;
  readonly module: PermissionModule;
  readonly description: string;
  /**
   * Guards purchase cost, COGS, margin, profit or commission. Spec §10 and §52
   * require these to be withheld from the API response, not merely hidden in the
   * UI — see `scrubRestrictedFields`.
   */
  readonly sensitive?: true;
}

export const PERMISSIONS = [
  // ── Dashboard ─────────────────────────────────────────────────────────────
  { code: 'dashboard.view', module: 'dashboard', description: 'View the dashboard' },
  { code: 'dashboard.view_consolidated', module: 'dashboard', description: 'View all branches consolidated' },
  { code: 'dashboard.view_margin', module: 'dashboard', description: 'View margin and profit KPIs', sensitive: true },

  // ── Sales ─────────────────────────────────────────────────────────────────
  { code: 'sales.view', module: 'sales', description: 'View vehicle sales' },
  { code: 'sales.create', module: 'sales', description: 'Create a vehicle sale draft' },
  { code: 'sales.submit', module: 'sales', description: 'Submit a sale for verification' },
  { code: 'sales.verify', module: 'sales', description: 'Perform accounts verification of a sale' },
  { code: 'sales.approve', module: 'sales', description: 'Approve a verified sale' },
  { code: 'sales.post', module: 'sales', description: 'Post a sale to the accounting engine' },
  { code: 'sales.deliver', module: 'sales', description: 'Record vehicle delivery' },
  { code: 'sales.cancel', module: 'sales', description: 'Cancel a sale' },
  { code: 'sales.return', module: 'sales', description: 'Record a sales return' },
  { code: 'sales.view_cost', module: 'sales', description: 'View purchase cost and COGS on a sale', sensitive: true },

  // ── Bookings ──────────────────────────────────────────────────────────────
  { code: 'bookings.view', module: 'bookings', description: 'View bookings' },
  { code: 'bookings.create', module: 'bookings', description: 'Create a booking and advance receipt' },
  { code: 'bookings.cancel', module: 'bookings', description: 'Cancel a booking' },
  { code: 'bookings.convert', module: 'bookings', description: 'Convert a booking into a vehicle sale' },
  { code: 'bookings.refund', module: 'bookings', description: 'Refund a cancelled booking advance' },

  // ── Customers ─────────────────────────────────────────────────────────────
  { code: 'customers.view', module: 'customers', description: 'View and search customers' },
  { code: 'customers.create', module: 'customers', description: 'Create a customer' },
  { code: 'customers.edit', module: 'customers', description: 'Edit customer details' },
  { code: 'customers.view_ledger', module: 'customers', description: 'View customer ledger and outstanding' },

  // ── Vehicles ──────────────────────────────────────────────────────────────
  { code: 'vehicles.stock.view', module: 'vehicles', description: 'View chassis-level vehicle stock' },
  { code: 'vehicles.stock.upload', module: 'vehicles', description: 'Upload vehicle stock from CSV/Excel' },
  { code: 'vehicles.stock.adjust', module: 'vehicles', description: 'Adjust vehicle stock' },
  { code: 'vehicles.models.view', module: 'vehicles', description: 'View models and variants' },
  { code: 'vehicles.models.manage', module: 'vehicles', description: 'Manage models and variants' },
  { code: 'vehicles.pricing.view', module: 'vehicles', description: 'View vehicle pricing and price history' },
  { code: 'vehicles.pricing.manage', module: 'vehicles', description: 'Configure vehicle price versions' },
  { code: 'vehicles.pricing.approve', module: 'vehicles', description: 'Approve a price version' },
  { code: 'vehicles.transfers.view', module: 'vehicles', description: 'View vehicle transfers' },
  { code: 'vehicles.transfers.manage', module: 'vehicles', description: 'Raise and receive vehicle transfers' },
  { code: 'vehicles.view_cost', module: 'vehicles', description: 'View vehicle purchase cost', sensitive: true },

  // ── Inventory (accessories and spares) ────────────────────────────────────
  { code: 'inventory.view', module: 'inventory', description: 'View accessory and spare stock' },
  { code: 'inventory.items.manage', module: 'inventory', description: 'Manage accessory and spare items' },
  { code: 'inventory.stock.upload', module: 'inventory', description: 'Upload accessory/spare stock' },
  { code: 'inventory.stock.transfer', module: 'inventory', description: 'Transfer stock between branches' },
  { code: 'inventory.stock.adjust', module: 'inventory', description: 'Adjust stock quantities' },
  { code: 'inventory.ledger.view', module: 'inventory', description: 'View the stock ledger' },
  { code: 'inventory.counter_sale.create', module: 'inventory', description: 'Create counter sales invoices' },
  { code: 'inventory.view_cost', module: 'inventory', description: 'View item purchase cost', sensitive: true },

  // ── Purchases ─────────────────────────────────────────────────────────────
  { code: 'purchases.view', module: 'purchases', description: 'View purchase bills' },
  { code: 'purchases.create', module: 'purchases', description: 'Create and edit draft purchase bills' },
  { code: 'purchases.post', module: 'purchases', description: 'Post a purchase bill to the accounts' },
  { code: 'purchases.cancel', module: 'purchases', description: 'Cancel or reverse a purchase bill' },

  // ── HR ────────────────────────────────────────────────────────────────────
  { code: 'hr.settings.manage', module: 'hr', description: 'Manage shifts and leave types' },
  { code: 'hr.salary.view', module: 'hr', description: 'View employee salary structures', sensitive: true },
  { code: 'hr.salary.manage', module: 'hr', description: 'Set and revise employee salary structures', sensitive: true },
  { code: 'hr.leave.view', module: 'hr', description: 'View employee leave balances' },
  { code: 'hr.leave.manage', module: 'hr', description: 'Set and adjust leave balances' },
  { code: 'hr.documents.view', module: 'hr', description: 'View employee documents' },
  { code: 'hr.documents.manage', module: 'hr', description: 'Upload and manage employee documents' },
  { code: 'hr.attendance.view', module: 'hr', description: 'View the attendance register' },
  { code: 'hr.attendance.sync', module: 'hr', description: 'Pull attendance from the external system' },
  { code: 'hr.attendance.edit', module: 'hr', description: 'Correct an attendance day by hand' },
  { code: 'hr.mapping.manage', module: 'hr', description: 'Map employees to the external attendance system' },

  // ── Service ───────────────────────────────────────────────────────────────
  { code: 'service.jobcards.view', module: 'service', description: 'View job cards' },
  { code: 'service.jobcards.create', module: 'service', description: 'Create job cards' },
  { code: 'service.billing.create', module: 'service', description: 'Create service bills' },
  { code: 'service.payments.collect', module: 'service', description: 'Collect service payments' },
  { code: 'service.history.view', module: 'service', description: 'View vehicle and customer service history' },

  // ── Finance ───────────────────────────────────────────────────────────────
  { code: 'finance.companies.view', module: 'finance', description: 'View finance companies' },
  { code: 'finance.companies.manage', module: 'finance', description: 'Manage finance companies' },
  { code: 'finance.applications.view', module: 'finance', description: 'View HP/finance applications' },
  { code: 'finance.applications.manage', module: 'finance', description: 'Manage HP/finance applications' },
  { code: 'finance.trade_advance.view', module: 'finance', description: 'View finance-company trade advances' },
  { code: 'finance.trade_advance.manage', module: 'finance', description: 'Record trade advance transactions' },
  { code: 'finance.settlements.manage', module: 'finance', description: 'Record finance settlements' },
  { code: 'finance.commission.view', module: 'finance', description: 'View finance commission income', sensitive: true },

  // ── Accounting ────────────────────────────────────────────────────────────
  { code: 'accounting.coa.view', module: 'accounting', description: 'View the chart of accounts' },
  { code: 'accounting.coa.manage', module: 'accounting', description: 'Manage the chart of accounts' },
  { code: 'accounting.journals.view', module: 'accounting', description: 'View journal entries' },
  { code: 'accounting.journals.create', module: 'accounting', description: 'Create draft journal entries' },
  { code: 'accounting.journals.post', module: 'accounting', description: 'Post journal entries' },
  { code: 'accounting.journals.reverse', module: 'accounting', description: 'Reverse a posted journal entry' },
  { code: 'accounting.periods.manage', module: 'accounting', description: 'Open, close and lock accounting periods' },
  { code: 'accounting.ledgers.view', module: 'accounting', description: 'View customer, supplier and finance ledgers' },
  { code: 'accounting.allocations.manage', module: 'accounting', description: 'Split payments against bills and settle party ledgers' },
  { code: 'accounting.reports.view', module: 'accounting', description: 'View trial balance, P&L and balance sheet' },

  // ── Cash book ─────────────────────────────────────────────────────────────
  { code: 'cashbook.view', module: 'cashbook', description: 'View the daily cash book' },
  { code: 'cashbook.receipts.create', module: 'cashbook', description: 'Record cash receipts' },
  { code: 'cashbook.payments.create', module: 'cashbook', description: 'Record cash payments' },
  { code: 'cashbook.day_close', module: 'cashbook', description: 'Count cash and close the day' },
  { code: 'cashbook.day_reopen', module: 'cashbook', description: 'Reopen a closed day for adjustment' },

  // ── Bank ──────────────────────────────────────────────────────────────────
  { code: 'bank.accounts.view', module: 'bank', description: 'View bank accounts' },
  { code: 'bank.accounts.manage', module: 'bank', description: 'Manage bank accounts' },
  { code: 'bank.book.view', module: 'bank', description: 'View the bank book' },
  { code: 'bank.book.record', module: 'bank', description: 'Record bank receipts and payments' },
  { code: 'bank.statement.import', module: 'bank', description: 'Import bank statements' },
  { code: 'bank.reconcile', module: 'bank', description: 'Reconcile bank transactions' },

  // ── GST ───────────────────────────────────────────────────────────────────
  { code: 'gst.summary.view', module: 'gst', description: 'View GST summary' },
  { code: 'gst.einvoice.generate', module: 'gst', description: 'Generate e-invoices' },
  { code: 'gst.einvoice.retry', module: 'gst', description: 'Retry failed e-invoice requests' },
  { code: 'gst.ewaybill.generate', module: 'gst', description: 'Generate e-way bills' },
  { code: 'gst.reports.view', module: 'gst', description: 'View GST reports' },

  // ── Reports ───────────────────────────────────────────────────────────────
  { code: 'reports.sales.view', module: 'reports', description: 'View sales reports' },
  { code: 'reports.inventory.view', module: 'reports', description: 'View inventory reports' },
  { code: 'reports.finance.view', module: 'reports', description: 'View finance reports' },
  { code: 'reports.accounting.view', module: 'reports', description: 'View accounting reports' },
  { code: 'reports.branch_performance.view', module: 'reports', description: 'View branch performance' },
  { code: 'reports.consolidated.view', module: 'reports', description: 'View consolidated MIS across branches' },
  { code: 'reports.margin.view', module: 'reports', description: 'View margin reports', sensitive: true },
  { code: 'reports.profitability.view', module: 'reports', description: 'View profitability reports', sensitive: true },

  // ── Masters ───────────────────────────────────────────────────────────────
  { code: 'masters.tax.view', module: 'masters', description: 'View tax codes' },
  { code: 'masters.tax.manage', module: 'masters', description: 'Manage tax codes and GST rates' },
  { code: 'masters.hsn.view', module: 'masters', description: 'View HSN/SAC codes' },
  { code: 'masters.hsn.manage', module: 'masters', description: 'Manage HSN/SAC codes' },
  { code: 'masters.employees.view', module: 'masters', description: 'View employees' },
  { code: 'masters.employees.manage', module: 'masters', description: 'Manage employees' },
  { code: 'masters.pricing.manage', module: 'masters', description: 'Manage pricing templates' },
  { code: 'masters.suppliers.view', module: 'masters', description: 'View suppliers' },
  { code: 'masters.suppliers.manage', module: 'masters', description: 'Manage suppliers' },

  // ── Administration ────────────────────────────────────────────────────────
  { code: 'admin.dealers.view', module: 'admin', description: 'View dealer configuration' },
  { code: 'admin.dealers.manage', module: 'admin', description: 'Manage dealer configuration' },
  { code: 'admin.branches.view', module: 'admin', description: 'View branches' },
  { code: 'admin.branches.manage', module: 'admin', description: 'Create and manage branches' },
  { code: 'admin.users.view', module: 'admin', description: 'View users' },
  { code: 'admin.users.manage', module: 'admin', description: 'Create and manage users and their access' },
  { code: 'admin.roles.view', module: 'admin', description: 'View roles and permissions' },
  { code: 'admin.roles.manage', module: 'admin', description: 'Manage roles and permission assignments' },
  { code: 'admin.audit.view', module: 'admin', description: 'View the audit trail' },
  { code: 'admin.settings.view', module: 'admin', description: 'View system settings' },
  { code: 'admin.settings.manage', module: 'admin', description: 'Manage system settings and document sequences' },
] as const satisfies readonly PermissionDefinition[];

/** Union of every valid permission code. A typo is a compile error. */
export type Permission = (typeof PERMISSIONS)[number]['code'];

export const PERMISSION_CODES: readonly Permission[] = PERMISSIONS.map((p) => p.code);

/**
 * Permissions that gate cost, margin, profit or commission data (spec §10, §52).
 * Used by `scrubRestrictedFields` to strip fields from a response payload.
 */
export const SENSITIVE_PERMISSIONS: readonly Permission[] = PERMISSIONS.filter(
  (p): p is Extract<(typeof PERMISSIONS)[number], { sensitive: true }> => 'sensitive' in p,
).map((p) => p.code);

/** System role codes shipped with the product (spec §6). */
export const SYSTEM_ROLES = {
  PLATFORM_ADMIN: 'PLATFORM_ADMIN',
  DEALER_OWNER: 'DEALER_OWNER',
  ACCOUNTS: 'ACCOUNTS',
  CASHIER: 'CASHIER',
  SALES_EXECUTIVE: 'SALES_EXECUTIVE',
  SERVICE_ADVISOR: 'SERVICE_ADVISOR',
  COUNTER_SALES: 'COUNTER_SALES',
} as const;

export type SystemRole = (typeof SYSTEM_ROLES)[keyof typeof SYSTEM_ROLES];

export function isPermission(value: string): value is Permission {
  return (PERMISSION_CODES as readonly string[]).includes(value);
}
