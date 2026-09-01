import * as React from 'react';
import { cva, type VariantProps } from 'class-variance-authority';

import { cn } from '@/lib/utils';

/**
 * Status badge. Spec §8 asks for clear status badges; the variants map to the
 * status palette in §7 so a colour always means the same thing across modules.
 */
const badgeVariants = cva(
  'inline-flex items-center gap-1 rounded-md border px-2 py-0.5 text-[11px] font-medium leading-5',
  {
    variants: {
      variant: {
        neutral: 'border-ink-200 bg-ink-50 text-ink-600',
        info: 'border-brand-200 bg-brand-50 text-brand-700',
        positive: 'border-positive-200 bg-positive-50 text-positive-700',
        warning: 'border-warning-200 bg-warning-50 text-warning-700',
        danger: 'border-danger-200 bg-danger-50 text-danger-700',
        accent: 'border-accent-200 bg-accent-50 text-accent-600',
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
