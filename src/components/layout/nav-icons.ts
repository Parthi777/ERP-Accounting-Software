import {
  BadgeIndianRupee,
  Banknote,
  BookOpenCheck,
  Building2,
  ClipboardList,
  FileSpreadsheet,
  Landmark,
  LayoutDashboard,
  Package,
  Receipt,
  Settings2,
  ShoppingCart,
  Users,
  Wallet,
  Wrench,
  type LucideIcon,
} from 'lucide-react';

import type { NavIconName } from '@/config/navigation';

/**
 * Resolves the icon names carried by `src/config/navigation.ts`.
 *
 * The navigation config is evaluated on the server and handed to client
 * components, so it can only contain serializable values — a component reference
 * would fail the boundary. The mapping lives here, in client-side code, where the
 * actual components are safe to hold.
 */
export const NAV_ICONS: Record<NavIconName, LucideIcon> = {
  dashboard: LayoutDashboard,
  sales: ShoppingCart,
  bookings: BookOpenCheck,
  customers: Users,
  vehicles: BadgeIndianRupee,
  inventory: Package,
  service: Wrench,
  finance: Landmark,
  accounting: FileSpreadsheet,
  cashbook: Wallet,
  bank: Banknote,
  gst: Receipt,
  reports: ClipboardList,
  masters: Building2,
  admin: Settings2,
};
