import * as React from 'react';

import { cn } from '@/lib/utils';

export const Input = React.forwardRef<HTMLInputElement, React.InputHTMLAttributes<HTMLInputElement>>(
  ({ className, type = 'text', ...props }, ref) => (
    <input
      ref={ref}
      type={type}
      // A clay well: pressed into the surface, with the focus ring and invalid
      // state carried by the `field` utility in globals.css.
      className={cn('field flex h-10 w-full px-3 py-1 text-sm', className)}
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
