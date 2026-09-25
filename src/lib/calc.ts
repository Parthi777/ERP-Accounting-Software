/**
 * Arithmetic in an amount field (BUSY F22): `1200*3+500` becomes 4100.
 *
 * A small recursive-descent parser for + − × ÷, parentheses and decimals —
 * never `eval`, so nothing typed into a field can run as code. Returns null
 * for anything that is not a plain sum, and for division by zero. The server
 * still validates the resulting number like any other.
 */
export function evaluateAmount(input: string): number | null {
  const text = input.replace(/[,\s₹]/g, '').replace(/[×x]/g, '*').replace(/÷/g, '/');
  if (text === '' || !/^[0-9.+\-*/()]+$/.test(text)) return null;
  let pos = 0;

  const peek = () => text[pos];
  const number = (): number | null => {
    const match = /^\d*\.?\d+|^\d+\.?/.exec(text.slice(pos));
    if (!match) return null;
    pos += match[0].length;
    return Number(match[0]);
  };
  const factor = (): number | null => {
    if (peek() === '-') { pos += 1; const v = factor(); return v === null ? null : -v; }
    if (peek() === '+') { pos += 1; return factor(); }
    if (peek() === '(') {
      pos += 1;
      const v = expression();
      if (v === null || peek() !== ')') return null;
      pos += 1;
      return v;
    }
    return number();
  };
  const term = (): number | null => {
    let v = factor();
    while (v !== null && (peek() === '*' || peek() === '/')) {
      const op = text[pos++];
      const r = factor();
      if (r === null) return null;
      if (op === '/' && r === 0) return null;
      v = op === '*' ? v * r : v / r;
    }
    return v;
  };
  function expression(): number | null {
    let v = term();
    while (v !== null && (peek() === '+' || peek() === '-')) {
      const op = text[pos++];
      const r = term();
      if (r === null) return null;
      v = op === '+' ? v + r : v - r;
    }
    return v;
  }

  const result = expression();
  if (result === null || pos !== text.length || !Number.isFinite(result)) return null;
  return Math.round(result * 100) / 100;
}

/** True when the text is an expression rather than a plain number. */
export function isExpression(input: string): boolean {
  return /[+*/()×÷x]|.-/.test(input.replace(/[,\s₹]/g, ''));
}
