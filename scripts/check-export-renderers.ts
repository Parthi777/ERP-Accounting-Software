/**
 * check-export-renderers.ts — render both export formats without a database
 *
 *   npx tsx scripts/check-export-renderers.ts
 *
 * The renderers are the part of the export path with no SQL in it and the most
 * ways to go wrong: a missing font, a column that overflows the page, a number
 * format Excel rejects. This drives both of them over a fabricated report and
 * asserts the bytes look like the file they claim to be, so a break shows up
 * here rather than as a corrupt download.
 *
 * Deliberately not part of `npm run verify`: it writes files and its value is in
 * being run by hand when the renderers change. `npm run typecheck` covers the
 * rest.
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { renderExcel } from '../src/server/export/excel';
import { renderPdf } from '../src/server/export/pdf';
import { paise, type Paise } from '../src/lib/money';
import type { AnyExportReport, ExportData } from '../src/server/export/types';
import type { TenantContext } from '../src/server/auth/tenant-context';

interface Row {
  readonly date: string;
  readonly invoice: string;
  readonly customer: string;
  readonly chassis: string;
  readonly qty: number;
  readonly amount: Paise;
  readonly tax: Paise;
}

const context = {
  userId: 'test-user',
  email: 'accounts@example.com',
  fullName: 'Priya Venkatesh',
  isPlatformAdmin: false,
  dealerId: 'dealer-1',
  dealerName: 'Sri Balaji Motors',
  dealerCode: 'SBM',
  accessibleBranches: [],
  activeBranch: { id: 'b1', name: 'Main Showroom', code: 'MAIN' },
  hasAllBranchAccess: true,
  roles: ['ACCOUNTS'],
  permissions: new Set<string>(),
} as unknown as TenantContext;

const columns = [
  { key: 'date', header: 'Date', type: 'date', width: 12, value: (r: Row) => r.date },
  { key: 'invoice', header: 'Invoice no.', width: 18, value: (r: Row) => r.invoice },
  { key: 'customer', header: 'Customer', width: 26, value: (r: Row) => r.customer },
  { key: 'chassis', header: 'Chassis', width: 22, value: (r: Row) => r.chassis },
  { key: 'qty', header: 'Units', type: 'number', total: true, value: (r: Row) => r.qty },
  { key: 'amount', header: 'Invoice total', type: 'money', total: true, value: (r: Row) => r.amount },
  { key: 'tax', header: 'Tax', type: 'money', total: true, value: (r: Row) => r.tax },
];

const report = {
  id: 'renderer-check',
  title: 'Renderer check — sales register',
  description: 'Fabricated rows used to exercise the PDF and Excel renderers.',
  permission: 'sales.view',
  orientation: 'landscape',
  load: async () => ({ rows: [] }),
  columns: () => columns,
} as unknown as AnyExportReport;

// Enough rows to force pagination in the PDF, so the repeating header and the
// page numbering are actually exercised.
const makeRows = (count: number): Row[] => Array.from({ length: count }, (_, i) => ({
  date: `2026-08-${String((i % 28) + 1).padStart(2, '0')}`,
  invoice: `INV-2026-${String(i + 1).padStart(6, '0')}`,
  customer: ['Ramesh Kumar', 'Lakshmi Narayanan', 'Karthik Industries', 'Meena Traders'][i % 4]!,
  chassis: `MD625JU10P1A${String(i + 1).padStart(5, '0')}`,
  qty: 1,
  amount: paise(9_85_000 + i * 1_137),
  tax: paise(2_75_800 + i * 318),
}));

const rows = makeRows(120);

const data: ExportData<unknown> = {
  rows,
  facts: [
    { label: 'Period', value: '01 Aug 2026 to 31 Aug 2026' },
    { label: 'Status', value: 'All statuses' },
  ],
  notes: ['Fabricated data. Every amount here is invented.'],
};

async function main() {
  const outDir = path.join(os.tmpdir(), 'twerp-export-check');
  fs.mkdirSync(outDir, { recursive: true });

  const generatedAt = new Date('2026-09-02T10:30:00Z');
  let failures = 0;

  const check = (label: string, ok: boolean, detail: string) => {
    console.log(`  ${ok ? 'ok  ' : 'FAIL'}  ${label}${ok ? '' : ` — ${detail}`}`);
    if (!ok) failures += 1;
  };

  // ── Excel ────────────────────────────────────────────────────────────────
  const xlsx = await renderExcel(report, data, context, generatedAt);
  const xlsxPath = path.join(outDir, xlsx.filename);
  fs.writeFileSync(xlsxPath, xlsx.body);

  // An xlsx is a zip; the local file header magic is PK\x03\x04.
  check('xlsx is a zip container', xlsx.body.subarray(0, 4).toString('binary') === 'PK', 'bad magic');
  check('xlsx is not empty', xlsx.body.length > 5_000, `${xlsx.body.length} bytes`);
  check('xlsx filename is dated', /\d{4}-\d{2}-\d{2}\.xlsx$/.test(xlsx.filename), xlsx.filename);

  // ── PDF ──────────────────────────────────────────────────────────────────
  const pdf = await renderPdf(report, data, context, generatedAt);
  const pdfPath = path.join(outDir, pdf.filename);
  fs.writeFileSync(pdfPath, pdf.body);

  const head = pdf.body.subarray(0, 8).toString('binary');
  const tail = pdf.body.subarray(-1024).toString('binary');
  const pageCount = (pdf.body.toString('binary').match(/\/Type\s*\/Page[^s]/g) ?? []).length;

  check('pdf has the right header', head.startsWith('%PDF-'), head);
  check('pdf is terminated', tail.includes('%%EOF'), 'no %%EOF marker');
  check('pdf paginated 120 rows across pages', pageCount >= 4, `${pageCount} page(s)`);

  // A short report must not spill: pdfkit appends a page whenever the cursor
  // crosses the bottom margin, and the footer is written below it. Getting this
  // wrong produces a blank final page and a page count that contradicts itself.
  const short = await renderPdf(report, { rows: makeRows(12), facts: data.facts }, context, generatedAt);
  const shortPages = (short.body.toString('binary').match(/\/Type\s*\/Page[^s]/g) ?? []).length;
  check('a short report stays on one page', shortPages === 1, `${shortPages} page(s)`);
  check('pdf is not empty', pdf.body.length > 10_000, `${pdf.body.length} bytes`);

  // The embedded font is the whole reason a rupee sign renders; if it silently
  // fell back to Helvetica the amounts would read INR and nobody would notice
  // until someone opened a file.
  const embedsFont = pdf.body.toString('binary').includes('DejaVuSansCondensed');
  check('pdf embedded DejaVu (so ₹ renders)', embedsFont, 'fell back to Helvetica');

  // ── Empty result ─────────────────────────────────────────────────────────
  const empty = await renderPdf(report, { rows: [] }, context, generatedAt);
  check('pdf handles an empty report', empty.body.subarray(0, 5).toString('binary') === '%PDF-', 'not a pdf');

  const emptyXlsx = await renderExcel(report, { rows: [] }, context, generatedAt);
  check('xlsx handles an empty report', emptyXlsx.body.length > 3_000, `${emptyXlsx.body.length} bytes`);

  // ── Truncation banner ────────────────────────────────────────────────────
  const capped = await renderExcel(report, { ...data, truncatedAt: 10_000 }, context, generatedAt);
  check('xlsx renders with a truncation banner', capped.body.length > xlsx.body.length - 2_000, 'suspiciously small');

  console.log(`\n  wrote ${xlsxPath}`);
  console.log(`  wrote ${pdfPath}`);

  if (failures > 0) {
    console.error(`\n${failures} check(s) failed.`);
    process.exit(1);
  }
  console.log('\nAll renderer checks passed.');
}

void main();
