import * as React from 'react';

import { cn } from '@/lib/utils';
import { SolidPanel } from '@/components/ui/panel';

/**
 * Operational data table.
 *
 * Solid white and dense, per spec §7 — glass belongs on KPI cards, not on a grid
 * an accountant reads four hundred rows of. Headers stick (spec §8) and numeric
 * columns are right-aligned with tabular figures (spec §51).
 */

export interface Column<T> {
  readonly key: string;
  readonly header: string;
  readonly render: (row: T) => React.ReactNode;
  /** Right-aligns and applies tabular numerals. */
  readonly numeric?: boolean;
  readonly className?: string;
  readonly headerClassName?: string;
}

export function DataTable<T>({
  columns,
  rows,
  getRowKey,
  emptyMessage = 'Nothing to show yet.',
  caption,
  maxHeight = '32rem',
}: {
  readonly columns: readonly Column<T>[];
  readonly rows: readonly T[];
  readonly getRowKey: (row: T, index: number) => string;
  readonly emptyMessage?: string;
  readonly caption?: string;
  readonly maxHeight?: string;
}) {
  return (
    <SolidPanel className="overflow-hidden">
      {/* Wide tables scroll inside their own container rather than the page. */}
      <div className="table-sticky overflow-auto" style={{ maxHeight }}>
        <table className="w-full border-collapse text-sm">
          {caption && <caption className="sr-only">{caption}</caption>}

          <thead>
            <tr>
              {columns.map((column) => (
                <th
                  key={column.key}
                  scope="col"
                  className={cn(
                    'whitespace-nowrap px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500',
                    column.numeric && 'text-right',
                    column.headerClassName,
                  )}
                >
                  {column.header}
                </th>
              ))}
            </tr>
          </thead>

          <tbody>
            {rows.length === 0 ? (
              <tr>
                <td
                  colSpan={columns.length}
                  className="px-4 py-12 text-center text-sm text-ink-400"
                >
                  {emptyMessage}
                </td>
              </tr>
            ) : (
              rows.map((row, index) => (
                <tr
                  key={getRowKey(row, index)}
                  className="border-t border-ink-100 transition-colors hover:bg-brand-50/40"
                >
                  {columns.map((column) => (
                    <td
                      key={column.key}
                      className={cn(
                        'px-4 py-2.5 align-middle text-ink-700',
                        column.numeric && 'numeric',
                        column.className,
                      )}
                    >
                      {column.render(row)}
                    </td>
                  ))}
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </SolidPanel>
  );
}

/** Page header used above every operational table (spec §51). */
export function PageHeader({
  title,
  description,
  count,
  action,
}: {
  readonly title: string;
  readonly description?: string;
  readonly count?: number;
  readonly action?: React.ReactNode;
}) {
  return (
    <div className="mb-4 flex flex-wrap items-start justify-between gap-3">
      <div>
        <div className="flex items-center gap-2">
          <h1 className="text-xl font-bold tracking-tight text-ink-900">{title}</h1>
          {count !== undefined && (
            <span className="rounded-md bg-ink-100 px-2 py-0.5 text-xs font-medium text-ink-600">
              {count}
            </span>
          )}
        </div>
        {description && <p className="mt-0.5 text-sm text-ink-500">{description}</p>}
      </div>
      {action}
    </div>
  );
}
