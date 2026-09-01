import * as React from 'react';

import { cn } from '@/lib/utils';

export const Input = React.forwardRef<HTMLInputElement, React.InputHTMLAttributes<HTMLInputElement>>(
  ({ className, type = 'text', ...props }, ref) => (
    <input
      ref={ref}
      type={type}
      className={cn(
        'flex h-9 w-full rounded-lg border border-ink-200 bg-white px-3 py-1 text-sm text-ink-900',
        'placeholder:text-ink-400 shadow-sm transition-colors',
        'focus:border-brand-400 focus:outline-none focus:ring-2 focus:ring-brand-500/20',
        'disabled:cursor-not-allowed disabled:bg-ink-50 disabled:text-ink-400',
        'aria-[invalid=true]:border-danger-500 aria-[invalid=true]:ring-danger-500/20',
        className,
      )}
      {...props}
    />
  ),
);
Input.displayName = 'Input';

export const Label = React.forwardRef<
  HTMLLabelElement,
  React.LabelHTMLAttributes<HTMLLabelElement>
>(({ className, ...props }, ref) => (
  <label
    ref={ref}
    className={cn('text-sm font-medium text-ink-700', className)}
    {...props}
  />
));
Label.displayName = 'Label';

/** Inline validation message (spec §8, §55). */
export function FieldError({ children }: { children?: React.ReactNode }) {
  if (!children) {
    return null;
  }
  return (
    <p role="alert" className="text-xs text-danger-600">
      {children}
    </p>
  );
}
