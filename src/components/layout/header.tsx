'use client';

import * as React from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { Bell, ChevronRight, CircleHelp, LogOut, Menu, Search } from 'lucide-react';

import { cn } from '@/lib/utils';
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
      <header className="glass sticky top-0 z-30 rounded-none border-x-0 border-t-0 px-4 py-3">
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

          {/* Breadcrumbs (spec §8) */}
          <nav aria-label="Breadcrumb" className="hidden min-w-0 md:block">
            <ol className="flex items-center gap-1.5 text-sm">
              <li>
                <Link href="/dashboard" className="text-ink-500 hover:text-ink-800">
                  {dealerName ?? 'TW ERP'}
                </Link>
              </li>
              {crumbs.map((crumb, index) => (
                <li key={crumb.label} className="flex items-center gap-1.5">
                  <ChevronRight className="size-3.5 text-ink-300" aria-hidden />
                  <span
                    className={cn(
                      index === crumbs.length - 1 ? 'font-medium text-ink-900' : 'text-ink-500',
                    )}
                  >
                    {crumb.label}
                  </span>
                </li>
              ))}
            </ol>
          </nav>

          <div className="flex-1" />

          {/* Global search (spec §8) */}
          <button
            type="button"
            onClick={() => setPaletteOpen(true)}
            className="flex h-9 items-center gap-2 rounded-lg border border-ink-200 bg-white/70 px-3 text-sm text-ink-400 shadow-sm transition-colors hover:bg-white sm:w-72"
          >
            <Search className="size-4 shrink-0" aria-hidden />
            <span className="hidden flex-1 text-left sm:block">Search anything…</span>
            <kbd className="hidden rounded border border-ink-200 bg-ink-50 px-1.5 font-sans text-[10px] font-medium text-ink-500 sm:block">
              ⌘K
            </kbd>
          </button>

          <Button variant="ghost" size="icon" aria-label="Notifications" className="relative">
            <Bell />
          </Button>

          <Button variant="ghost" size="icon" aria-label="Help">
            <CircleHelp />
          </Button>

          {/* User menu */}
          <div className="relative">
            <button
              type="button"
              onClick={() => setMenuOpen((open) => !open)}
              aria-haspopup="menu"
              aria-expanded={menuOpen}
              className="flex items-center gap-2 rounded-lg px-1.5 py-1 transition-colors hover:bg-ink-100"
            >
              <span className="flex size-8 items-center justify-center rounded-full bg-brand-600 text-xs font-semibold text-white">
                {initials(user.name)}
              </span>
              <span className="hidden text-left sm:block">
                <span className="block text-sm font-medium leading-tight text-ink-800">
                  {user.name}
                </span>
                <span className="block text-xs leading-tight text-ink-500">{user.roleLabel}</span>
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
