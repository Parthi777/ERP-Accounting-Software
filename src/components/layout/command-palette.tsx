'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Command } from 'cmdk';
import { Search } from 'lucide-react';

import type { NavSection } from '@/config/navigation';

/**
 * Command palette (spec §8).
 *
 * Navigates the sections this session is allowed to see — the list is the same
 * permission-filtered tree the sidebar renders, so the palette can never be used
 * to reach a page the sidebar hides.
 */
export function CommandPalette({
  open,
  onOpenChange,
  sections,
}: {
  readonly open: boolean;
  readonly onOpenChange: (open: boolean) => void;
  readonly sections: readonly NavSection[];
}) {
  const router = useRouter();

  const go = React.useCallback(
    (href: string) => {
      onOpenChange(false);
      router.push(href);
    },
    [onOpenChange, router],
  );

  if (!open) {
    return null;
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-start justify-center bg-ink-900/20 p-4 pt-[12vh] backdrop-blur-sm"
      onClick={() => onOpenChange(false)}
    >
      <div
        className="glass-strong w-full max-w-xl overflow-hidden rounded-2xl"
        onClick={(event) => event.stopPropagation()}
      >
        <Command label="Command palette" loop>
          <div className="flex items-center gap-3 border-b border-ink-200/70 px-4">
            <Search className="size-4 shrink-0 text-ink-400" aria-hidden />
            <Command.Input
              autoFocus
              placeholder="Search pages, customers, invoices…"
              className="h-12 flex-1 bg-transparent text-sm text-ink-900 outline-none placeholder:text-ink-400"
            />
            <kbd className="rounded border border-ink-200 bg-white/60 px-1.5 py-0.5 font-sans text-[10px] text-ink-500">
              ESC
            </kbd>
          </div>

          <Command.List className="max-h-[52vh] overflow-y-auto p-2">
            <Command.Empty className="px-3 py-8 text-center text-sm text-ink-500">
              Nothing matched that search.
            </Command.Empty>

            {sections.map((section) => (
              <Command.Group
                key={section.label}
                heading={section.label}
                className="px-1 py-1 text-[11px] font-medium uppercase tracking-wide text-ink-400 [&_[cmdk-group-items]]:mt-1 [&_[cmdk-group-items]]:space-y-0.5"
              >
                {section.href && (
                  <PaletteItem
                    label={section.label}
                    hint="Go to"
                    onSelect={() => go(section.href!)}
                  />
                )}
                {section.items?.map((item) => (
                  <PaletteItem
                    key={item.href}
                    label={item.label}
                    hint={item.status === 'planned' ? `Phase ${item.phase ?? '—'}` : 'Go to'}
                    onSelect={() => go(item.href)}
                  />
                ))}
              </Command.Group>
            ))}
          </Command.List>
        </Command>
      </div>
    </div>
  );
}

function PaletteItem({
  label,
  hint,
  onSelect,
}: {
  readonly label: string;
  readonly hint: string;
  readonly onSelect: () => void;
}) {
  return (
    <Command.Item
      onSelect={onSelect}
      className="flex cursor-pointer items-center justify-between gap-3 rounded-lg px-3 py-2 text-sm font-normal normal-case tracking-normal text-ink-700 data-[selected=true]:bg-brand-50 data-[selected=true]:text-brand-700"
    >
      <span className="truncate">{label}</span>
      <span className="shrink-0 text-[11px] text-ink-400">{hint}</span>
    </Command.Item>
  );
}
