'use client';

import * as React from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { Bell, ChevronRight, CircleHelp, LogOut, Menu, Search } from 'lucide-react';

import { initials } from '@/lib/format';
import { breadcrumbsFor } from '@/config/navigation';
import { Button } from '@/components/ui/button';
import { signOut } from '@/server/auth/actions';
import { CommandPalette } from '@/components/layout/command-palette';
import type { NavSection } from '@/config/navigation';

interface HeaderProps {
  readonly user: { readonly name: string; readonly email: string; readonly roleLabel: string };
  readonly dealerName: string | null;
  readonly sections: readonly NavSection[];
  readonly onToggleSidebar: () => void;
}

export function Header({ user, dealerName, sections, onToggleSidebar }: HeaderProps) {
  const pathname = usePathname();
  const [paletteOpen, setPaletteOpen] = React.useState(false);
  const [menuOpen, setMenuOpen] = React.useState(false);
  const crumbs = breadcrumbsFor(pathname);

  // ⌘K / Ctrl+K opens the command palette (spec §8).
  React.useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key.toLowerCase() === 'k' && (event.metaKey || event.ctrlKey)) {
        event.preventDefault();
        setPaletteOpen((open) => !open);
      }
    };
    document.addEventListener('keydown', onKeyDown);
    return () => document.removeEventListener('keydown', onKeyDown);
  }, []);

  return (
    <>
      <header className="glass-strong sticky top-0 z-30 rounded-none border-x-0 border-t-0 px-4 py-3 sm:px-6">
        <div className="flex items-center gap-3">
          <Button
            variant="ghost"
            size="icon"
            className="lg:hidden"
            onClick={onToggleSidebar}
            aria-label="Toggle navigation"
          >
            <Menu />
          </Button>

          {/* The page title carries the heading; the trail sits under it, so a
              deep route still says where it is without a second row of chrome. */}
          <div className="min-w-0">
            <h1 className="truncate text-[22px] font-bold leading-tight tracking-tight text-ink-900 sm:text-[25px]">
              {crumbs.at(-1)?.label ?? 'Dashboard'}
            </h1>
            {crumbs.length > 1 && (
              <nav aria-label="Breadcrumb" className="hidden md:block">
                <ol className="flex items-center gap-1 text-[11.5px] leading-tight">
                  <li>
                    <Link href="/dashboard" className="text-ink-400 hover:text-ink-700">
                      {dealerName ?? 'TW ERP'}
                    </Link>
                  </li>
                  {crumbs.slice(0, -1).map((crumb) => (
                    <li key={crumb.label} className="flex items-center gap-1">
                      <ChevronRight className="size-3 text-ink-300" aria-hidden />
                      <span className="text-ink-400">{crumb.label}</span>
                    </li>
                  ))}
                </ol>
              </nav>
            )}
          </div>

          <div className="flex-1" />

          {/* Global search (spec §8) */}
          <button
            type="button"
            onClick={() => setPaletteOpen(true)}
            className="flex h-9 items-center gap-2 rounded-xl border border-ink-200 bg-white px-3 text-sm text-ink-400 shadow-sm transition-colors hover:border-brand-200 hover:text-ink-600 sm:w-64"
          >
            <Search className="size-4 shrink-0" aria-hidden />
            <span className="hidden flex-1 text-left sm:block">Search anything…</span>
            <kbd className="hidden rounded border border-ink-200 bg-ink-50 px-1.5 font-sans text-[10px] font-medium text-ink-500 sm:block">
              ⌘K
            </kbd>
          </button>

          <Button
            variant="secondary"
            size="icon"
            aria-label="Notifications"
            className="relative rounded-xl"
          >
            <Bell />
          </Button>

          <Button variant="secondary" size="icon" aria-label="Help" className="hidden rounded-xl sm:inline-flex">
            <CircleHelp />
          </Button>

          {/* User menu */}
          <div className="relative">
            <button
              type="button"
              onClick={() => setMenuOpen((open) => !open)}
              aria-haspopup="menu"
              aria-expanded={menuOpen}
              className="flex items-center rounded-full transition-opacity hover:opacity-85"
            >
              <span className="flex size-9 items-center justify-center rounded-full bg-gradient-to-br from-brand-500 to-brand-700 text-[11px] font-semibold text-white">
                {initials(user.name)}
              </span>
            </button>

            {menuOpen && (
              <>
                <div className="fixed inset-0 z-40" onClick={() => setMenuOpen(false)} aria-hidden />
                <div
                  role="menu"
                  className="glass-strong absolute right-0 z-50 mt-2 w-60 rounded-xl p-1"
                >
                  <div className="px-3 py-2">
                    <p className="truncate text-sm font-medium text-ink-900">{user.name}</p>
                    <p className="truncate text-xs text-ink-500">{user.email}</p>
                  </div>
                  <div className="my-1 h-px bg-ink-200/70" />
                  <form action={signOut}>
                    <button
                      type="submit"
                      role="menuitem"
                      className="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left text-sm text-ink-700 transition-colors hover:bg-ink-100"
                    >
                      <LogOut className="size-4" aria-hidden />
                      Sign out
                    </button>
                  </form>
                </div>
              </>
            )}
          </div>
        </div>
      </header>

      <CommandPalette open={paletteOpen} onOpenChange={setPaletteOpen} sections={sections} />
    </>
  );
}
