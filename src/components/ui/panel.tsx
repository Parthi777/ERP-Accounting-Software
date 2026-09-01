import * as React from 'react';

import { cn } from '@/lib/utils';

/**
 * Surface primitives.
 *
 * `Panel` is glass — for KPI cards, filter bars and summary panels.
 * `SolidPanel` is opaque white — for anything holding dense rows of numbers.
 *
 * Keeping both in one file makes the choice explicit at every call site, which is
 * how spec §7's "do not overuse glass effects" survives contact with a growing
 * codebase.
 */

export function Panel({
  className,
  strong = false,
  ...props
}: React.HTMLAttributes<HTMLDivElement> & { strong?: boolean }) {
  return (
    <div
      className={cn(
        strong ? 'glass-strong' : 'glass',
        'rounded-[--radius-panel]',
        className,
      )}
      {...props}
    />
  );
}

/** Opaque surface for tables and other dense, high-contrast content. */
export function SolidPanel({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn('surface-solid rounded-[--radius-panel]', className)} {...props} />;
}

export function PanelHeader({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      className={cn('flex items-center justify-between gap-3 px-5 py-4', className)}
      {...props}
    />
  );
}

export function PanelTitle({ className, ...props }: React.HTMLAttributes<HTMLHeadingElement>) {
  return <h2 className={cn('text-sm font-semibold text-ink-900', className)} {...props} />;
}

export function PanelDescription({ className, ...props }: React.HTMLAttributes<HTMLParagraphElement>) {
  return <p className={cn('text-xs text-ink-500', className)} {...props} />;
}

export function PanelContent({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn('px-5 pb-5', className)} {...props} />;
}
