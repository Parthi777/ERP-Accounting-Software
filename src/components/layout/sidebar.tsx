'use client';

import * as React from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { ChevronDown, Bike, Power } from 'lucide-react';

import { NAV_ICONS } from '@/components/layout/nav-icons';

import { cn } from '@/lib/utils';
import { initials } from '@/lib/format';
import { NAV_GROUPS, type NavSection } from '@/config/navigation';
import { signOut } from '@/server/auth/actions';
import { BranchSwitcher, type BranchOption } from '@/components/layout/branch-switcher';

interface SidebarProps {
  readonly sections: readonly NavSection[];
  readonly dealerName: string | null;
  readonly user: { readonly name: string; readonly roleLabel: string };
  readonly branches: readonly BranchOption[];
  readonly activeBranchId: string | null;
  readonly open: boolean;
}

/**
 * Primary navigation.
 *
 * The tree it renders has already been filtered to the session's permissions on
 * the server, so this component never decides what a user may see — it only
 * decides how it looks (spec §6).
 */
export function Sidebar({ sections, dealerName, user, branches, activeBranchId, open }: SidebarProps) {
  const pathname = usePathname();

  // A section starts expanded when the current route lives inside it.
  const [expanded, setExpanded] = React.useState<Set<string>>(() => {
    const initial = new Set<string>();
    for (const section of sections) {
      if (section.items?.some((item) => pathname.startsWith(item.href))) {
        initial.add(section.label);
      }
    }
    return initial;
  });

  // Grouped for rendering only. A group with nothing in it — every section
  // filtered out by permission — is not rendered at all, so a cashier does not
  // get a "Setup" heading with nothing under it.
  const grouped = React.useMemo(
    () =>
      NAV_GROUPS.map((group) => ({
        group,
        sections: sections.filter((section) => section.group === group),
      })).filter((entry) => entry.sections.length > 0),
    [sections],
  );

  const toggle = (label: string) =>
    setExpanded((current) => {
      const next = new Set(current);
      if (next.has(label)) {
        next.delete(label);
      } else {
        next.add(label);
      }
      return next;
    });

  return (
    <aside
      className={cn(
        'sidebar-surface fixed inset-y-0 left-0 z-40 flex w-[264px] flex-col transition-transform lg:translate-x-0',
        open ? 'translate-x-0' : '-translate-x-full',
      )}
    >
      {/* Brand */}
      <div className="flex items-center gap-3 px-4 py-5">
        <div className="flex size-11 shrink-0 items-center justify-center rounded-2xl bg-gradient-to-br from-brand-500 to-brand-700 text-white shadow-sm">
          <Bike className="size-[22px]" aria-hidden />
        </div>
        <div className="min-w-0">
          <p className="truncate text-[15px] font-bold leading-tight tracking-tight text-ink-900">
            {dealerName ?? 'TW ERP'}
          </p>
          <p className="truncate text-[11.5px] leading-tight text-ink-500">One place for everything</p>
        </div>
      </div>

      {/* Navigation */}
      <nav className="nav-scroll flex-1 overflow-y-auto px-3 pb-4" aria-label="Main">
        {grouped.map(({ group, sections: groupSections }) => (
        <div key={group} className="mb-1">
        <p className="px-3 pb-1.5 pt-3 text-[10px] font-semibold uppercase tracking-[0.11em] text-ink-400">
          {group}
        </p>
        <ul className="space-y-[3px]">
          {groupSections.map((section) => {
            const Icon = NAV_ICONS[section.icon];

            if (!section.items) {
              const active = pathname === section.href;
              return (
                <li key={section.label}>
                  <Link
                    href={section.href ?? '#'}
                    aria-current={active ? 'page' : undefined}
                    className={cn(
                      'flex items-center gap-3 rounded-xl px-3 py-[9px] text-[14px] transition-colors',
                      active
                        ? 'bg-brand-50 font-semibold text-brand-700'
                        : 'font-medium text-ink-600 hover:bg-ink-100/70 hover:text-ink-900',
                    )}
                  >
                    <Icon
                      className={cn('size-[18px] shrink-0', active ? 'text-brand-600' : 'text-ink-400')}
                      aria-hidden
                    />
                    {section.label}
                  </Link>
                </li>
              );
            }

            const isOpen = expanded.has(section.label);
            const containsActive = section.items.some((item) => pathname === item.href);

            return (
              <li key={section.label}>
                <button
                  type="button"
                  onClick={() => toggle(section.label)}
                  aria-expanded={isOpen}
                  className={cn(
                    'flex w-full items-center gap-3 rounded-xl px-3 py-[9px] text-[14px] transition-colors',
                    containsActive
                      ? 'font-semibold text-brand-700'
                      : 'font-medium text-ink-600 hover:bg-ink-100/70 hover:text-ink-900',
                  )}
                >
                  <Icon
                    className={cn(
                      'size-[18px] shrink-0',
                      containsActive ? 'text-brand-600' : 'text-ink-400',
                    )}
                    aria-hidden
                  />
                  <span className="flex-1 text-left">{section.label}</span>
                  <ChevronDown
                    className={cn(
                      'size-3.5 shrink-0 text-ink-300 transition-transform',
                      isOpen && 'rotate-180',
                    )}
                    aria-hidden
                  />
                </button>

                {isOpen && (
                  <ul className="ml-[22px] mt-[3px] space-y-[2px] border-l border-brand-100 pb-1 pl-3">
                    {section.items.map((item) => {
                      const active = pathname === item.href;
                      return (
                        <li key={item.href}>
                          <Link
                            href={item.href}
                            aria-current={active ? 'page' : undefined}
                            className={cn(
                              'flex items-center justify-between gap-2 rounded-lg px-3 py-[7px] text-[13px] transition-colors',
                              active
                                ? 'bg-brand-50 font-semibold text-brand-700'
                                : 'text-ink-500 hover:bg-ink-100/70 hover:text-ink-800',
                            )}
                          >
                            <span className="truncate">{item.label}</span>
                            {item.status === 'planned' && (
                              <span
                                className="shrink-0 rounded bg-ink-100 px-1 text-[10px] font-medium text-ink-400"
                                title={`Arrives in phase ${item.phase ?? '—'}`}
                              >
                                P{item.phase ?? '?'}
                              </span>
                            )}
                          </Link>
                        </li>
                      );
                    })}
                  </ul>
                )}
              </li>
            );
          })}
        </ul>
        </div>
        ))}
      </nav>

      {/* Branch context + user */}
      <div className="space-y-2 border-t border-ink-200/70 p-3">
        <BranchSwitcher branches={branches} activeBranchId={activeBranchId} />

        <div className="flex items-center gap-3 rounded-xl px-2 py-1.5">
          <div className="flex size-9 shrink-0 items-center justify-center rounded-full bg-gradient-to-br from-brand-500 to-brand-700 text-[11px] font-semibold text-white">
            {initials(user.name)}
          </div>
          <div className="min-w-0 flex-1">
            <p className="truncate text-[13.5px] font-semibold leading-tight text-ink-800">{user.name}</p>
            <p className="truncate text-[11.5px] leading-tight text-ink-500">{user.roleLabel}</p>
          </div>
          <form action={signOut}>
            <button
              type="submit"
              aria-label="Sign out"
              title="Sign out"
              className="flex size-8 items-center justify-center rounded-lg text-ink-400 transition-colors hover:bg-danger-50 hover:text-danger-600"
            >
              <Power className="size-[17px]" aria-hidden />
            </button>
          </form>
        </div>
      </div>
    </aside>
  );
}
