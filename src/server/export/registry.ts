import 'server-only';

import { accountingReports } from './reports/accounting';
import { financeReports } from './reports/finance';
import { inventoryReports } from './reports/inventory';
import { operationsReports } from './reports/operations';
import { salesReports } from './reports/sales';
import type { AnyExportReport } from './types';

/**
 * The catalogue of exportable reports.
 *
 * One entry per report, and the entry owns everything the exporter needs: the
 * permission to hold, the loader to call, and the columns to write. Adding an
 * export to a screen is therefore a registry entry plus an <ExportButtons/>,
 * with no new route and no second copy of the query.
 *
 * `server-only` because the loaders reach the database and the registry names
 * every report a session might be allowed to run. Neither belongs in a bundle
 * sent to the browser.
 */

const ALL: readonly AnyExportReport[] = [
  ...accountingReports,
  ...salesReports,
  ...inventoryReports,
  ...financeReports,
  ...operationsReports,
];

const BY_ID = new Map<string, AnyExportReport>(ALL.map((report) => [report.id, report]));

// A duplicate id would mean one report silently shadowing another, and the only
// symptom would be the wrong file downloading. Fail at import instead.
if (BY_ID.size !== ALL.length) {
  const seen = new Set<string>();
  const duplicates = ALL.map((r) => r.id).filter((id) => (seen.has(id) ? true : (seen.add(id), false)));
  throw new Error(`Duplicate export report id(s): ${[...new Set(duplicates)].join(', ')}`);
}

export function findReport(id: string): AnyExportReport | undefined {
  return BY_ID.get(id);
}

export function listReports(): readonly AnyExportReport[] {
  return ALL;
}

export type { AnyExportReport };
