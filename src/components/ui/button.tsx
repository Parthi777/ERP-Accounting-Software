'use client';

import * as React from 'react';
import { Slot } from '@radix-ui/react-slot';
import { cva, type VariantProps } from 'class-variance-authority';

import { cn } from '@/lib/utils';

/**
 * Clay buttons (spec §7). A primary action is a raised blue pebble with a lit top
 * edge; secondary is raised clay; pressing sinks it into the surface. Danger
 * stays solid red so a destructive action is never mistaken for a routine one.
 */
const buttonVariants = cva(
  'inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-xl text-sm font-semibold transition-[box-shadow,background-color,color,transform] disabled:pointer-events-none disabled:opacity-50 active:translate-y-px [&_svg]:size-4 [&_svg]:shrink-0',
  {
    variants: {
      variant: {
        primary:
          'bg-brand-600 text-white shadow-[inset_0_2px_0_rgba(255,255,255,.28),inset_0_-3px_0_rgba(0,0,0,.16),0_8px_16px_rgba(47,91,216,.32)] hover:bg-brand-700 active:shadow-[inset_0_2px_6px_rgba(0,0,0,.25)]',
        secondary:
          'clay-raised text-ink-800 hover:text-brand-700 active:shadow-[var(--clay-pit)]',
        ghost: 'text-ink-600 hover:bg-white/60 hover:text-ink-900',
        subtle: 'clay-pit text-brand-700 hover:text-brand-800',
        danger:
          'bg-danger-600 text-white shadow-[inset_0_2px_0_rgba(255,255,255,.25),inset_0_-3px_0_rgba(0,0,0,.18),0_8px_16px_rgba(198,43,52,.28)] hover:bg-danger-700',
        link: 'text-brand-600 underline-offset-4 hover:underline',
      },
      size: {
        sm: 'h-8 px-3 text-xs',
        md: 'h-10 px-4',
        lg: 'h-11 px-5',
        icon: 'size-10',
      },
    },
    defaultVariants: { variant: 'primary', size: 'md' },
  },
);

export interface ButtonProps
  extends React.ButtonHTMLAttributes<HTMLButtonElement>,
    VariantProps<typeof buttonVariants> {
  asChild?: boolean;
}

export const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant, size, asChild = false, ...props }, ref) => {
    const Comp = asChild ? Slot : 'button';
    return (
      <Comp className={cn(buttonVariants({ variant, size, className }))} ref={ref} {...props} />
    );
  },
);
Button.displayName = 'Button';

export { buttonVariants };
