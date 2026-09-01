import type { Paise } from '@/lib/money';
import type { Permission } from '@/lib/permissions/registry';
import type { TenantContext } from '@/server/auth/tenant-context';

/**
 * Report export — the shared shape.
 *
 * Spec §41, §51. Exports run on the server and re-enter the same service the
 * screen used, which is the whole point: the service resolves the tenant from
 * the authenticated session and drops restricted fields before returning
 * (§47, §52). An exporter that queried the database itself, or that serialised
 * whatever the browser happened to be holding, would be a second and weaker
 * answer to "what is this user allowed to see" — and the weaker one always wins
 * when someone changes a URL.
 *
 * So: a report is a permission, a loader, and a list of columns. Nothing here
 * knows about PDF or Excel; the two renderers consume this and nothing else.
 */

/**
 * How a value is written.
 *
 * The distinction that matters is `money`. In Excel it must land as a real
 * number with a currency format, not a formatted string — an accountant's first
 * act on an export is to sum a column, and `"₹1,25,000.00"` sums to zero. In PDF
 * it is a string, because a PDF cell is only ever ink.
 */
export type CellType = 'text' | 'number' | 'money' | 'quantity' | 'date' | 'datetime' | 'percent';

export type CellValue = string | number | Paise | Date | null | undefined;

export interface ExportColumn<T> {
  readonly key: string;
  readonly header: string;
  readonly type?: CellType;
  /** Extracts the raw value. Formatting belongs to the renderer, not here. */
  readonly value: (row: T) => CellValue;
  /** Column width in characters. Excel uses it directly; PDF uses it as a ratio. */
  readonly width?: number;
  /** Include this column in the totals row. Only meaningful for numeric types. */
  readonly total?: boolean;
}

/** A labelled fact printed above the table — period, branch, filters applied. */
export interface ExportFact {
  readonly label: string;
  readonly value: string;
}

export interface ExportData<T> {
  readonly rows: readonly T[];
  /** Filters and scope, printed in the header so a saved file explains itself. */
  readonly facts?: readonly ExportFact[];
  /**
   * Set when the loader hit its row cap. The renderers print this prominently:
   * a financial export that quietly stops at row 500 is worse than no export,
   * because nothing about the file says it is incomplete.
   */
  readonly truncatedAt?: number;
  /** Optional free text under the table — caveats, or how a figure is derived. */
  readonly notes?: readonly string[];
}

export interface ExportReport<T> {
  readonly id: string;
  readonly title: string;
  /** One line under the title explaining what the report contains. */
  readonly description?: string;
  /** Checked before the loader runs. The service checks again; both should hold. */
  readonly permission: Permission;
  /** Wider reports print landscape. Default is portrait. */
  readonly orientation?: 'portrait' | 'landscape';
  readonly load: (context: TenantContext, params: URLSearchParams) => Promise<ExportData<T>>;
  /**
   * Takes the context so a restricted column can be dropped from the header as
   * well as the data. The service already withholds the values; a column of
   * dashes would still tell a cashier that a margin exists and how many there
   * are.
   */
  readonly columns: (context: TenantContext) => readonly ExportColumn<T>[];
}

/** Erases the row type so reports of different shapes can share one registry. */
export interface AnyExportReport {
  readonly id: string;
  readonly title: string;
  readonly description?: string;
  readonly permission: Permission;
  readonly orientation?: 'portrait' | 'landscape';
  readonly load: (context: TenantContext, params: URLSearchParams) => Promise<ExportData<unknown>>;
  readonly columns: (context: TenantContext) => readonly ExportColumn<unknown>[];
}

/** Narrows a typed report into the registry's erased form. */
export function defineReport<T>(report: ExportReport<T>): AnyExportReport {
  return report as unknown as AnyExportReport;
}

export type ExportFormat = 'xlsx' | 'pdf';

export interface RenderedExport {
  readonly body: Buffer;
  readonly contentType: string;
  readonly filename: string;
}
