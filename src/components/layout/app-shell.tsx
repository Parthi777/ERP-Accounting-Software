'use client';

import * as React from 'react';

import { Sidebar } from '@/components/layout/sidebar';
import { Header } from '@/components/layout/header';
import type { FinancialYearOption } from '@/components/layout/financial-year-switcher';
import type { NavSection } from '@/config/navigation';
import type { BranchOption } from '@/components/layout/branch-switcher';

/**
 * The authenticated shell: sidebar, header, and the page beneath them.
 *
 * Everything it needs is passed in from the server layout, already filtered by
 * permission. The shell holds only presentation state — whether the sidebar is
 * open on a small screen.
 */
export function AppShell({
  user,
  dealerName,
  dealerCode,
  sections,
  financialYears,
  activeFinancialYearId,
  branches,
  activeBranchId,
  children,
}: {
  readonly user: { readonly name: string; readonly email: string; readonly roleLabel: string };
  readonly dealerName: string | null;
  /**
   * Stamped onto the shell as `data-dealer-code`.
   *
   * Anything driving this app through a browser can then tell whose books it is
   * looking at before it writes to them. The write-path e2e suite refuses to run
   * unless this matches the throwaway tenant it was told to use — a posted
   * journal is immutable (spec §23), so "point it at the wrong environment" is a
   * mistake with no undo, and a comment is not a guard.
   */
  readonly dealerCode: string | null;
  readonly sections: readonly NavSection[];
  readonly financialYears: readonly FinancialYearOption[];
  readonly activeFinancialYearId: string | null;
  readonly branches: readonly BranchOption[];
  readonly activeBranchId: string | null;
  readonly children: React.ReactNode;
}) {
  const [sidebarOpen, setSidebarOpen] = React.useState(false);

  return (
    <div className="min-h-dvh" data-dealer-code={dealerCode ?? ''}>
      <Sidebar
        sections={sections}
        dealerName={dealerName}
        user={{ name: user.name, roleLabel: user.roleLabel }}
        branches={branches}
        activeBranchId={activeBranchId}
        open={sidebarOpen}
      />

      {/* Scrim for the mobile drawer */}
      {sidebarOpen && (
        <div
          className="fixed inset-0 z-30 bg-ink-900/20 backdrop-blur-sm lg:hidden"
          onClick={() => setSidebarOpen(false)}
          aria-hidden
        />
      )}

      <div className="lg:pl-[264px]">
        <Header
          user={user}
          dealerName={dealerName}
          sections={sections}
          financialYears={financialYears}
          activeFinancialYearId={activeFinancialYearId}
          onToggleSidebar={() => setSidebarOpen((open) => !open)}
        />
        <main className="px-4 py-5 sm:px-6">{children}</main>
        <footer className="px-6 pb-6 pt-2 text-xs text-ink-400">
          <div className="flex flex-wrap items-center justify-between gap-2 border-t border-ink-200/70 pt-4">
            <span>© {new Date().getFullYear()} TW ERP. All rights reserved.</span>
            <span>Version 1.0.0 · Phase 1 foundation</span>
          </div>
        </footer>
      </div>
    </div>
  );
}
