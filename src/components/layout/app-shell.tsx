'use client';

import * as React from 'react';

import { Sidebar } from '@/components/layout/sidebar';
import { Header } from '@/components/layout/header';
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
  sections,
  branches,
  activeBranchId,
  children,
}: {
  readonly user: { readonly name: string; readonly email: string; readonly roleLabel: string };
  readonly dealerName: string | null;
  readonly sections: readonly NavSection[];
  readonly branches: readonly BranchOption[];
  readonly activeBranchId: string | null;
  readonly children: React.ReactNode;
}) {
  const [sidebarOpen, setSidebarOpen] = React.useState(false);

  return (
    <div className="min-h-dvh">
      <Sidebar
        sections={sections}
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

      <div className="lg:pl-64">
        <Header
          user={user}
          dealerName={dealerName}
          sections={sections}
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
