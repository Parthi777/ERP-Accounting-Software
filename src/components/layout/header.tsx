'use client';

import * as React from 'react';
import Link from 'next/link';
import { usePathname, useRouter } from 'next/navigation';
import { ChevronRight, CircleHelp, LogOut, Menu, Search } from 'lucide-react';

import { initials } from '@/lib/format';
import { breadcrumbsFor } from '@/config/navigation';
import { guideSectionFor } from '@/content/process-guide';
import { Button } from '@/components/ui/button';
import { signOut } from '@/server/auth/actions';
import { CommandPalette } from '@/components/layout/command-palette';
import { SHORTCUTS } from '@/config/shortcuts';
import {
  FinancialYearSwitcher,
  type FinancialYearOption,
} from '@/components/layout/financial-year-switcher';
import type { NavSection } from '@/config/navigation';

interface HeaderProps {
  readonly user: { readonly name: string; readonly email: string; readonly roleLabel: string };
  readonly dealerName: string | null;
  readonly sections: readonly NavSection[];
  readonly financialYears: readonly FinancialYearOption[];
  readonly activeFinancialYearId: string | null;
  readonly onToggleSidebar: () => void;
}

export function Header({
  user,
  dealerName,
  sections,
  financialYears,
  activeFinancialYearId,
  onToggleSidebar,
}: HeaderProps) {
  const pathname = usePathname();
  const router = useRouter();
  const [paletteOpen, setPaletteOpen] = React.useState(false);
  const [menuOpen, setMenuOpen] = React.useState(false);
  const crumbs = breadcrumbsFor(pathname);

  // Help opens the guide at the process for whatever screen you are on, and at
  // the top of it when nothing matches. A help button that always lands in the
  // same place is one people stop pressing.
  const guide = guideSectionFor(pathname);
  const helpHref = guide ? `/help#${guide.id}` : '/help';
  const helpLabel = guide ? `Help: ${guide.title}` : 'Help';

  // ⌘K / Ctrl+K opens the command palette (spec §8).
  React.useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key.toLowerCase() === 'k' && (event.metaKey || event.ctrlKey)) {
        event.preventDefault();
        setPaletteOpen((open) => !open);
        return;
      }
      // Alt+S saves the form the cursor is in (BUSY F21).
      if (event.altKey && !event.shiftKey && !event.metaKey && !event.ctrlKey && event.code === 'KeyS') {
        const form = (document.activeElement as HTMLElement | null)?.closest('form');
        if (form) {
          event.preventDefault();
          form.requestSubmit();
        }
        return;
      }
      // Alt+Shift+letter opens a voucher or a book — only one the role can see.
      if (event.altKey && event.shiftKey && !event.metaKey && !event.ctrlKey) {
        const shortcut = SHORTCUTS.find((s) => s.code === event.code);
        const allowed = shortcut && sections.some((section) =>
          section.href === shortcut.href || section.items?.some((item) => item.href === shortcut.href));
        if (shortcut && allowed) {
          event.preventDefault();
          router.push(shortcut.href);
        }
      }
    };
    document.addEventListener('keydown', onKeyDown);
    return () => document.removeEventListener('keydown', onKeyDown);
  }, [router, sections]);

  return (
    <>
      {/* A floating clay bar rather than a full-bleed strip: it sits on the same
          ground as everything else and rises above the page as it scrolls. */}
      <header className="sticky top-0 z-30 px-4 pt-3 sm:px-6">
        <div className="glass-strong flex items-center gap-3 rounded-[1.25rem] px-4 py-2.5">
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

          {/* Which year everything dated defaults to (spec §24, §51). Before the
              search rather than after: it qualifies what the page below is
              showing, and reads left-to-right as "this dealer, this year". */}
          <FinancialYearSwitcher years={financialYears} activeYearId={activeFinancialYearId} />

          {/* Global search (spec §8) */}
          <button
            type="button"
            onClick={() => setPaletteOpen(true)}
            className="clay-pit flex h-10 items-center gap-2 rounded-xl px-3 text-sm text-ink-500 transition-colors hover:text-ink-700 sm:w-72"
          >
            <Search className="size-4 shrink-0" aria-hidden />
            <span className="hidden flex-1 text-left sm:block">Jump to a page…</span>
            <kbd className="clay-raised hidden rounded-md px-1.5 font-sans text-[10px] font-semibold text-ink-500 sm:block">
              ⌘K
            </kbd>
          </button>

          <Button
            variant="secondary"
            size="icon"
            aria-label={helpLabel}
            title={helpLabel}
            className="hidden rounded-xl sm:inline-flex"
            asChild
          >
            <Link href={helpHref}>
              <CircleHelp />
            </Link>
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
              <span className="clay-raised flex size-10 items-center justify-center rounded-full text-[12px] font-bold text-brand-700">
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
