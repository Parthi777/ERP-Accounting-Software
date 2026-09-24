import * as React from 'react';
import { cva, type VariantProps } from 'class-variance-authority';

import { cn } from '@/lib/utils';

/**
 * Status badge. Spec §8 asks for clear status badges; the variants map to the
 * status palette in §7 so a colour always means the same thing across modules.
 */
const badgeVariants = cva(
  'inline-flex items-center gap-1 rounded-full px-2.5 py-0.5 text-[11px] font-semibold leading-5 shadow-[inset_1px_1px_0_rgba(255,255,255,.7)]',
  {
    variants: {
      variant: {
        neutral: 'bg-ink-100 text-ink-600',
        info: 'bg-brand-100 text-brand-700',
        positive: 'bg-positive-50 text-positive-700',
        warning: 'bg-warning-50 text-warning-700',
        danger: 'bg-danger-50 text-danger-700',
        accent: 'bg-accent-50 text-accent-600',
      },
    },
    defaultVariants: { variant: 'neutral' },
  },
);

export interface BadgeProps
  extends React.HTMLAttributes<HTMLSpanElement>,
    VariantProps<typeof badgeVariants> {}

export function Badge({ className, variant, ...props }: BadgeProps) {
  return <span className={cn(badgeVariants({ variant }), className)} {...props} />;
}
