import { describe, expect, it } from 'vitest';

import { evaluateAmount, isExpression } from './calc';

describe('evaluateAmount', () => {
  it('works out simple sums', () => {
    expect(evaluateAmount('1200*3+500')).toBe(4100);
    expect(evaluateAmount('(450+120.50)*2')).toBe(1141);
    expect(evaluateAmount('1,25,000')).toBe(125000);
    expect(evaluateAmount('₹ 999.999')).toBe(1000);
    expect(evaluateAmount('100/3')).toBe(33.33);
    expect(evaluateAmount('-50+100')).toBe(50);
    expect(evaluateAmount('12 × 4')).toBe(48);
  });

  it('refuses anything that is not a sum', () => {
    expect(evaluateAmount('')).toBeNull();
    expect(evaluateAmount('alert(1)')).toBeNull();
    expect(evaluateAmount('1/0')).toBeNull();
    expect(evaluateAmount('2**3')).toBeNull();
    expect(evaluateAmount('(1+2')).toBeNull();
    expect(evaluateAmount('1+')).toBeNull();
  });

  it('tells a sum from a plain number', () => {
    expect(isExpression('1200*3')).toBe(true);
    expect(isExpression('1,200.50')).toBe(false);
    expect(isExpression('-50')).toBe(false);
  });
});
