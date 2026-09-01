import { SolidPanel } from '@/components/ui/panel';
import { formatINR, type Paise } from '@/lib/money';
import { cn } from '@/lib/utils';

/**
 * One section of a financial statement: rows, then a ruled total.
 *
 * Shared by the P&L and the balance sheet so the two read identically — an
 * accountant moving between them should not have to relearn the layout.
 */
export function StatementSection({
  title,
  rows,
  total,
  tone = 'info',
}: {
  readonly title: string;
  readonly rows: readonly { readonly code: string; readonly name: string; readonly amount: Paise }[];
  readonly total: Paise;
  readonly tone?: 'info' | 'positive' | 'warning' | 'danger' | 'accent';
}) {
  const accent: Record<string, string> = {
    info: 'text-brand-700',
    positive: 'text-positive-700',
    warning: 'text-warning-700',
    danger: 'text-danger-700',
    accent: 'text-accent-600',
  };

  return (
    <SolidPanel className="overflow-hidden">
      <div className="border-b border-ink-100 px-5 py-3">
        <h2 className={cn('text-sm font-semibold', accent[tone])}>{title}</h2>
      </div>

      <table className="w-full border-collapse text-sm">
        <caption className="sr-only">{title}</caption>
        <tbody>
          {rows.length === 0 ? (
            <tr>
              <td colSpan={2} className="px-5 py-8 text-center text-sm text-ink-400">
                Nothing posted.
              </td>
            </tr>
          ) : (
            rows.map((row) => (
              <tr key={row.code} className="border-t border-ink-100">
                <td className="px-5 py-2 text-ink-700">
                  <span className="mr-2 font-mono text-xs text-ink-400">{row.code}</span>
                  {row.name}
                </td>
                <td className="numeric px-5 py-2 text-ink-900">{formatINR(row.amount)}</td>
              </tr>
            ))
          )}
        </tbody>
        <tfoot>
          <tr className="border-t-2 border-ink-200 bg-ink-50">
            <td className="px-5 py-2.5 text-sm font-semibold text-ink-900">Total {title}</td>
            <td className="numeric px-5 py-2.5 text-sm font-bold text-ink-900">{formatINR(total)}</td>
          </tr>
        </tfoot>
      </table>
    </SolidPanel>
  );
}
