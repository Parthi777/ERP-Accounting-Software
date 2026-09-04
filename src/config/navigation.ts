/**
 * Application navigation — spec §9.
 *
 * The sidebar renders from this tree and nothing else. Every leaf carries the
 * permission that reveals it, so a Cashier and an Accounts user get genuinely
 * different navigation from the same component (spec §6).
 *
 * `status` marks which modules are actually built: `ready` is a working screen,
 * `planned` is a routed placeholder that the sidebar badges with its phase, so
 * the navigation is complete and each module has a home to land in.
 *
 * This has to track reality — a shipped module still marked `planned` wears a
 * "coming later" badge in the sidebar and quietly misreports the product. When
 * a placeholder is replaced by a real screen, flip its status in the same
 * change.
 */

import type { Permission } from '@/lib/permissions/registry';

/**
 * Icons are named here, not imported here.
 *
 * This module is read by a Server Component (the authenticated layout) and the
 * result is handed to a Client Component (the sidebar). A React component is a
 * function, and functions cannot cross that boundary — passing `LucideIcon`
 * values directly throws "Functions cannot be passed directly to Client
 * Components" at render time. The client resolves these names against its own
 * icon map in `src/components/layout/nav-icons.ts`.
 */
export type NavIconName =
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

export type ModuleStatus = 'ready' | 'planned';

export interface NavItem {
  readonly label: string;
  readonly href: string;
  readonly permission: Permission;
  readonly status: ModuleStatus;
  /** Development phase from spec §56, shown on placeholder pages. */
  readonly phase?: number;
}

/**
 * Sidebar groupings.
 *
 * Fifteen top-level entries in one flat list is a list you read rather than
 * scan. Grouping them by what someone is at the machine to do — take money,
 * move stock, close the books — turns it back into navigation. Order here is
 * the order they render.
 */
export const NAV_GROUPS = ['Overview', 'Daily operation', 'Stock control', 'Money', 'Insight', 'Setup'] as const;

export type NavGroup = (typeof NAV_GROUPS)[number];

export interface NavSection {
  readonly label: string;
  readonly group: NavGroup;
  readonly icon: NavIconName;
  /** Sections without children link straight to `href`. */
  readonly href?: string;
  readonly permission: Permission;
  readonly status: ModuleStatus;
  readonly phase?: number;
  readonly items?: readonly NavItem[];
}

export const NAVIGATION: readonly NavSection[] = [
  {
    label: 'Dashboard',
    group: 'Overview',
    icon: 'dashboard',
    href: '/dashboard',
    permission: 'dashboard.view',
    status: 'ready',
  },
  {
    label: 'Sales',
    group: 'Daily operation',
    icon: 'sales',
    permission: 'sales.view',
    status: 'ready',
    items: [
      { label: 'Vehicle Sales', href: '/sales', permission: 'sales.view', status: 'ready' },
      { label: 'Sales Returns', href: '/sales/returns', permission: 'sales.return', status: 'ready', phase: 4 },
    ],
  },
  {
    label: 'Bookings',
    group: 'Daily operation',
    icon: 'bookings',
    permission: 'bookings.view',
    status: 'ready',
    items: [
      { label: 'Booking List', href: '/bookings', permission: 'bookings.view', status: 'ready' },
      { label: 'New Booking', href: '/bookings/new', permission: 'bookings.create', status: 'ready' },
      { label: 'Booking Advances', href: '/bookings/advances', permission: 'bookings.view', status: 'ready', phase: 4 },
    ],
  },
  {
    label: 'Customers',
    group: 'Daily operation',
    icon: 'customers',
    permission: 'customers.view',
    status: 'ready',
    items: [
      { label: 'Customer Master', href: '/customers', permission: 'customers.view', status: 'ready' },
      { label: 'Customer Ledger', href: '/customers/ledger', permission: 'customers.view_ledger', status: 'ready', phase: 5 },
      { label: 'Vehicle History', href: '/customers/vehicles', permission: 'customers.view', status: 'ready', phase: 2 },
      { label: 'Service History', href: '/customers/service', permission: 'service.history.view', status: 'ready', phase: 6 },
    ],
  },
  {
    label: 'Vehicles',
    group: 'Stock control',
    icon: 'vehicles',
    permission: 'vehicles.stock.view',
    status: 'ready',
    items: [
      { label: 'Vehicle Stock', href: '/vehicles', permission: 'vehicles.stock.view', status: 'ready' },
      { label: 'Stock Upload', href: '/vehicles/upload', permission: 'vehicles.stock.upload', status: 'ready' },
      { label: 'Vehicle Models', href: '/vehicles/models', permission: 'vehicles.models.view', status: 'ready' },
      { label: 'Variants', href: '/vehicles/variants', permission: 'vehicles.models.view', status: 'ready' },
      { label: 'Price History', href: '/vehicles/pricing', permission: 'vehicles.pricing.view', status: 'ready' },
      { label: 'Vehicle Transfers', href: '/vehicles/transfers', permission: 'vehicles.transfers.view', status: 'ready', phase: 3 },
    ],
  },
  {
    label: 'Purchases',
    group: 'Stock control',
    icon: 'purchases',
    permission: 'purchases.view',
    status: 'ready',
    items: [
      { label: 'Purchase Bills', href: '/purchases', permission: 'purchases.view', status: 'ready' },
      { label: 'New Purchase Bill', href: '/purchases/new', permission: 'purchases.create', status: 'ready' },
    ],
  },
  {
    label: 'Inventory',
    group: 'Stock control',
    icon: 'inventory',
    permission: 'inventory.view',
    status: 'ready',
    phase: 3,
    items: [
      { label: 'Accessories', href: '/inventory/accessories', permission: 'inventory.view', status: 'ready' },
      { label: 'Spares', href: '/inventory/spares', permission: 'inventory.view', status: 'ready' },
      { label: 'Stock Upload', href: '/inventory/upload', permission: 'inventory.stock.upload', status: 'ready', phase: 3 },
      { label: 'Stock Transfer', href: '/inventory/transfers', permission: 'inventory.stock.transfer', status: 'ready', phase: 3 },
      { label: 'Stock Adjustment', href: '/inventory/adjustments', permission: 'inventory.stock.adjust', status: 'ready', phase: 3 },
      { label: 'Counter Sales', href: '/inventory/counter-sales', permission: 'inventory.counter_sale.create', status: 'ready' },
      { label: 'Stock Ledger', href: '/inventory/ledger', permission: 'inventory.ledger.view', status: 'ready', phase: 3 },
    ],
  },
  {
    label: 'Service',
    group: 'Daily operation',
    icon: 'service',
    permission: 'service.jobcards.view',
    status: 'ready',
    phase: 6,
    items: [
      { label: 'Job Cards', href: '/service', permission: 'service.jobcards.view', status: 'ready', phase: 6 },
      { label: 'Service Billing', href: '/service/billing', permission: 'service.billing.create', status: 'ready', phase: 6 },
      { label: 'Service History', href: '/service/history', permission: 'service.history.view', status: 'ready', phase: 6 },
    ],
  },
  {
    label: 'Finance',
    group: 'Money',
    icon: 'finance',
    permission: 'finance.companies.view',
    status: 'ready',
    phase: 4,
    items: [
      { label: 'Finance Companies', href: '/finance/companies', permission: 'finance.companies.view', status: 'ready' },
      { label: 'HP Sales', href: '/finance/hp-sales', permission: 'finance.applications.view', status: 'ready', phase: 4 },
      { label: 'Trade Advances', href: '/finance/trade-advances', permission: 'finance.trade_advance.view', status: 'ready', phase: 4 },
      { label: 'Finance Settlement', href: '/finance/settlements', permission: 'finance.settlements.manage', status: 'ready', phase: 4 },
    ],
  },
  {
    label: 'Accounting',
    group: 'Money',
    icon: 'accounting',
    permission: 'accounting.coa.view',
    status: 'ready',
    items: [
      { label: 'Chart of Accounts', href: '/accounting/chart-of-accounts', permission: 'accounting.coa.view', status: 'ready' },
      { label: 'Journal Entries', href: '/accounting/journals', permission: 'accounting.journals.view', status: 'ready' },
      { label: 'Customer Ledger', href: '/accounting/customer-ledger', permission: 'accounting.ledgers.view', status: 'ready', phase: 5 },
      { label: 'Supplier Ledger', href: '/accounting/supplier-ledger', permission: 'accounting.ledgers.view', status: 'ready', phase: 5 },
      { label: 'Trial Balance', href: '/accounting/trial-balance', permission: 'accounting.reports.view', status: 'ready' },
      { label: 'Profit & Loss', href: '/accounting/profit-and-loss', permission: 'accounting.reports.view', status: 'ready' },
      { label: 'Balance Sheet', href: '/accounting/balance-sheet', permission: 'accounting.reports.view', status: 'ready' },
    ],
  },
  {
    label: 'Cash Book',
    group: 'Money',
    icon: 'cashbook',
    permission: 'cashbook.view',
    status: 'ready',
    phase: 5,
    items: [
      { label: 'Daily Cash Book', href: '/cash-book', permission: 'cashbook.view', status: 'ready', phase: 5 },
      { label: 'Cash Receipts', href: '/cash-book/receipts', permission: 'cashbook.receipts.create', status: 'ready', phase: 5 },
      { label: 'Cash Payments', href: '/cash-book/payments', permission: 'cashbook.payments.create', status: 'ready', phase: 5 },
      { label: 'Day Close', href: '/cash-book/day-close', permission: 'cashbook.day_close', status: 'ready', phase: 5 },
    ],
  },
  {
    label: 'Bank',
    group: 'Money',
    icon: 'bank',
    permission: 'bank.accounts.view',
    status: 'ready',
    phase: 7,
    items: [
      { label: 'Bank Accounts', href: '/bank', permission: 'bank.accounts.view', status: 'ready', phase: 5 },
      { label: 'Bank Book', href: '/bank/book', permission: 'bank.book.view', status: 'ready', phase: 5 },
      { label: 'Statement Import', href: '/bank/import', permission: 'bank.statement.import', status: 'ready', phase: 7 },
      { label: 'Reconciliation', href: '/bank/reconciliation', permission: 'bank.reconcile', status: 'ready', phase: 7 },
    ],
  },
  {
    label: 'GST',
    group: 'Money',
    icon: 'gst',
    permission: 'gst.summary.view',
    status: 'ready',
    phase: 7,
    items: [
      { label: 'GST Summary', href: '/gst', permission: 'gst.summary.view', status: 'ready', phase: 7 },
      { label: 'E-Invoice', href: '/gst/e-invoice', permission: 'gst.einvoice.generate', status: 'ready', phase: 7 },
      { label: 'E-Way Bill', href: '/gst/e-way-bill', permission: 'gst.ewaybill.generate', status: 'ready', phase: 7 },
      { label: 'GST Reports', href: '/gst/reports', permission: 'gst.reports.view', status: 'ready', phase: 7 },
    ],
  },
  {
    label: 'Reports',
    group: 'Insight',
    icon: 'reports',
    permission: 'reports.sales.view',
    status: 'ready',
    phase: 8,
    items: [
      { label: 'Sales', href: '/reports/sales', permission: 'reports.sales.view', status: 'ready', phase: 8 },
      { label: 'Inventory', href: '/reports/inventory', permission: 'reports.inventory.view', status: 'ready', phase: 8 },
      { label: 'Finance', href: '/reports/finance', permission: 'reports.finance.view', status: 'ready', phase: 8 },
      { label: 'Margin', href: '/reports/margin', permission: 'reports.margin.view', status: 'ready', phase: 8 },
      { label: 'Branch Performance', href: '/reports/branch-performance', permission: 'reports.branch_performance.view', status: 'ready', phase: 8 },
      { label: 'Consolidated MIS', href: '/reports/consolidated', permission: 'reports.consolidated.view', status: 'ready', phase: 8 },
    ],
  },
  {
    label: 'HR',
    group: 'Setup',
    icon: 'hr',
    permission: 'masters.employees.view',
    status: 'ready',
    items: [
      { label: 'Employees', href: '/hr', permission: 'masters.employees.view', status: 'ready' },
      { label: 'Attendance', href: '/hr/attendance', permission: 'hr.attendance.view', status: 'ready' },
      { label: 'Shifts & Leave', href: '/hr/settings', permission: 'masters.employees.view', status: 'ready' },
    ],
  },
  {
    label: 'Masters',
    group: 'Setup',
    icon: 'masters',
    permission: 'masters.tax.view',
    status: 'ready',
    items: [
      { label: 'Tax', href: '/masters/tax', permission: 'masters.tax.view', status: 'ready' },
      { label: 'HSN / SAC', href: '/masters/hsn', permission: 'masters.hsn.view', status: 'ready' },
      { label: 'Customers', href: '/masters/customers', permission: 'customers.view', status: 'ready' },
      { label: 'Employees', href: '/masters/employees', permission: 'masters.employees.view', status: 'ready' },
      { label: 'Finance Companies', href: '/masters/finance-companies', permission: 'finance.companies.view', status: 'ready' },
      { label: 'Suppliers', href: '/masters/suppliers', permission: 'masters.suppliers.view', status: 'ready' },
      { label: 'Accessories', href: '/masters/accessories', permission: 'inventory.items.manage', status: 'ready' },
      { label: 'Spares', href: '/masters/spares', permission: 'inventory.items.manage', status: 'ready' },
      { label: 'Pricing', href: '/masters/pricing', permission: 'masters.pricing.manage', status: 'ready', phase: 3 },
    ],
  },
  {
    label: 'Administration',
    group: 'Setup',
    icon: 'admin',
    permission: 'admin.branches.view',
    status: 'ready',
    items: [
      { label: 'Dealers', href: '/admin/dealers', permission: 'admin.dealers.view', status: 'ready' },
      { label: 'Branches', href: '/admin/branches', permission: 'admin.branches.view', status: 'ready' },
      { label: 'Users', href: '/admin/users', permission: 'admin.users.view', status: 'ready' },
      { label: 'Roles & Permissions', href: '/admin/roles', permission: 'admin.roles.view', status: 'ready' },
      { label: 'Audit Logs', href: '/admin/audit', permission: 'admin.audit.view', status: 'ready' },
      { label: 'Settings', href: '/admin/settings', permission: 'admin.settings.view', status: 'ready' },
    ],
  },
];

/** Filters the tree down to what a permission set may see. */
export function visibleNavigation(
  has: (permission: Permission) => boolean,
): readonly NavSection[] {
  return NAVIGATION.map((section) => {
    if (!section.items) {
      return has(section.permission) ? section : null;
    }
    const items = section.items.filter((item) => has(item.permission));
    if (items.length === 0) {
      return null;
    }
    return { ...section, items };
  }).filter((section): section is NavSection => section !== null);
}

/** Breadcrumb trail for a pathname, e.g. Accounting › Journal Entries. */
export function breadcrumbsFor(pathname: string): readonly { label: string; href?: string }[] {
  for (const section of NAVIGATION) {
    if (section.href === pathname) {
      return [{ label: section.label }];
    }
    const match = section.items?.find((item) => item.href === pathname);
    if (match) {
      return [{ label: section.label }, { label: match.label }];
    }
  }
  return [];
}

/** The nav entry for a pathname, used by placeholder pages to describe themselves. */
export function navEntryFor(pathname: string): NavItem | NavSection | null {
  for (const section of NAVIGATION) {
    if (section.href === pathname) {
      return section;
    }
    const match = section.items?.find((item) => item.href === pathname);
    if (match) {
      return match;
    }
  }
  return null;
}
