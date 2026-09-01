'use client';

import * as React from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { ChevronDown, Bike } from 'lucide-react';

import { NAV_ICONS } from '@/components/layout/nav-icons';

import { cn } from '@/lib/utils';
import { initials } from '@/lib/format';
import type { NavSection } from '@/config/navigation';
import { BranchSwitcher, type BranchOption } from '@/components/layout/branch-switcher';

interface SidebarProps {
  readonly sections: readonly NavSection[];
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
export function Sidebar({ sections, user, branches, activeBranchId, open }: SidebarProps) {
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
        'fixed inset-y-0 left-0 z-40 flex w-64 flex-col border-r border-ink-200/70 bg-white/80 backdrop-blur-xl transition-transform lg:translate-x-0',
        open ? 'translate-x-0' : '-translate-x-full',
      )}
    >
      {/* Brand */}
      <div className="flex items-center gap-3 px-5 py-5">
        <div className="flex size-10 items-center justify-center rounded-xl bg-brand-50 text-brand-600">
          <Bike className="size-6" aria-hidden />
        </div>
        <div className="min-w-0">
          <p className="truncate text-base font-bold tracking-tight text-ink-900">TW ERP</p>
          <p className="truncate text-xs text-ink-500">Two Wheeler ERP</p>
        </div>
      </div>

      {/* Navigation */}
      <nav className="flex-1 overflow-y-auto px-3 pb-4" aria-label="Main">
        <ul className="space-y-0.5">
          {sections.map((section) => {
            const Icon = NAV_ICONS[section.icon];

            if (!section.items) {
              const active = pathname === section.href;
              return (
                <li key={section.label}>
                  <Link
                    href={section.href ?? '#'}
                    aria-current={active ? 'page' : undefined}
                    className={cn(
                      'flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition-colors',
                      active
                        ? 'bg-brand-600 text-white shadow-sm'
                        : 'text-ink-600 hover:bg-ink-100 hover:text-ink-900',
                    )}
                  >
                    <Icon className="size-[18px] shrink-0" aria-hidden />
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
                    'flex w-full items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition-colors',
                    containsActive
                      ? 'text-brand-700'
                      : 'text-ink-600 hover:bg-ink-100 hover:text-ink-900',
                  )}
                >
                  <Icon className="size-[18px] shrink-0" aria-hidden />
                  <span className="flex-1 text-left">{section.label}</span>
                  <ChevronDown
                    className={cn('size-4 text-ink-400 transition-transform', isOpen && 'rotate-180')}
                    aria-hidden
                  />
                </button>

                {isOpen && (
                  <ul className="mt-0.5 space-y-0.5 border-l border-ink-200 pb-1 pl-3 ml-[22px]">
                    {section.items.map((item) => {
                      const active = pathname === item.href;
                      return (
                        <li key={item.href}>
                          <Link
                            href={item.href}
                            aria-current={active ? 'page' : undefined}
                            className={cn(
                              'flex items-center justify-between gap-2 rounded-md px-3 py-1.5 text-[13px] transition-colors',
                              active
                                ? 'bg-brand-50 font-medium text-brand-700'
                                : 'text-ink-500 hover:bg-ink-100 hover:text-ink-800',
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
      </nav>

      {/* Branch context + user */}
      <div className="space-y-2 border-t border-ink-200/70 p-3">
        <BranchSwitcher branches={branches} activeBranchId={activeBranchId} />

        <div className="flex items-center gap-3 rounded-lg px-2 py-2">
          <div className="flex size-8 shrink-0 items-center justify-center rounded-full bg-brand-600 text-xs font-semibold text-white">
            {initials(user.name)}
          </div>
          <div className="min-w-0 flex-1">
            <p className="truncate text-sm font-medium text-ink-800">{user.name}</p>
            <p className="truncate text-xs text-ink-500">{user.roleLabel}</p>
          </div>
        </div>
      </div>
    </aside>
  );
}
