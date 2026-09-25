/**
 * Voucher shortcuts (BUSY F21). Browser-safe: Alt+Shift with a letter, read by
 * key position (event.code) so a Mac's Option characters do not get in the
 * way, and nothing a browser already claims. A shortcut to a page the user's
 * role does not show in the sidebar does nothing.
 */
export interface Shortcut {
  readonly code: string;
  readonly keys: string;
  readonly label: string;
  readonly href: string;
}

export const SHORTCUTS: readonly Shortcut[] = [
  { code: 'KeyR', keys: 'Alt+Shift+R', label: 'Cash receipt', href: '/cash-book/receipts' },
  { code: 'KeyP', keys: 'Alt+Shift+P', label: 'Cash payment', href: '/cash-book/payments' },
  { code: 'KeyJ', keys: 'Alt+Shift+J', label: 'New journal entry', href: '/accounting/journals/new' },
  { code: 'KeyD', keys: 'Alt+Shift+D', label: 'Day book', href: '/accounting/day-book' },
  { code: 'KeyL', keys: 'Alt+Shift+L', label: 'Ledgers', href: '/accounting/ledgers' },
];

/** Alt+S saves the form the cursor is in. */
export const SAVE_SHORTCUT = 'Alt+S';
