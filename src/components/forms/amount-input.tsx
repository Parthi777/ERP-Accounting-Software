'use client';

import * as React from 'react';

import { Input } from '@/components/ui/input';
import { evaluateAmount, isExpression } from '@/lib/calc';
import { cn } from '@/lib/utils';

/**
 * An amount field that works out a sum (BUSY F22): type `1200*3+500` and it
 * becomes 4100 on leaving the field or pressing Enter. Anything that is not a
 * plain sum is left as typed for the form's own validation to name.
 */
export function AmountInput({
  value,
  onValueChange,
  className,
  ...props
}: Omit<React.ComponentProps<typeof Input>, 'value' | 'onChange' | 'type'> & {
  readonly value: string;
  readonly onValueChange: (value: string) => void;
}) {
  const settle = () => {
    if (!isExpression(value)) return;
    const result = evaluateAmount(value);
    if (result !== null) onValueChange(String(result));
  };
  return (
    <Input
      {...props}
      type="text"
      inputMode="decimal"
      autoComplete="off"
      className={cn('numeric', className)}
      value={value}
      onChange={(e) => onValueChange(e.target.value)}
      onBlur={(e) => { settle(); props.onBlur?.(e); }}
      onKeyDown={(e) => {
        if (e.key === 'Enter' && isExpression(value)) { e.preventDefault(); settle(); }
        props.onKeyDown?.(e);
      }}
      title="Amounts can be worked out here: 1200*3+500"
    />
  );
}
