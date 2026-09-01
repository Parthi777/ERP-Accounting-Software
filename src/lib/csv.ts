/**
 * CSV parsing for uploaded files — vehicle stock, bank statements, and whatever
 * else a dealer exports from another system.
 *
 * A naive `split(',')` breaks on any address, narration or description containing
 * a comma, which real exports invariably do. Quoted fields and doubled quotes are
 * handled here so no caller has to think about them.
 */

/** Splits one CSV line, respecting quoted fields. */
export function splitCsvLine(line: string): string[] {
  const cells: string[] = [];
  let current = '';
  let inQuotes = false;

  for (let i = 0; i < line.length; i += 1) {
    const char = line[i];
    if (char === '"') {
      // A doubled quote inside a quoted field is a literal quote.
      if (inQuotes && line[i + 1] === '"') {
        current += '"';
        i += 1;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (char === ',' && !inQuotes) {
      cells.push(current);
      current = '';
    } else {
      current += char;
    }
  }
  cells.push(current);
  return cells;
}

/**
 * Parses a CSV into header-keyed rows.
 *
 * Headers are normalised to lower_snake_case so that "Value Date", "value date"
 * and "VALUE_DATE" all arrive as `value_date` — bank exports are not consistent
 * about this even between two statements from the same bank.
 */
export function parseCsv(text: string): { headers: string[]; rows: Record<string, string>[] } {
  const lines = text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0);

  if (lines.length < 2) {
    return { headers: [], rows: [] };
  }

  const headers = splitCsvLine(lines[0]!).map((h) =>
    h.trim().toLowerCase().replace(/^"|"$/g, '').replace(/\s+/g, '_'),
  );

  const rows: Record<string, string>[] = [];
  for (let i = 1; i < lines.length; i += 1) {
    const cells = splitCsvLine(lines[i]!);
    const row: Record<string, string> = {};
    headers.forEach((header, index) => {
      row[header] = (cells[index] ?? '').trim();
    });
    rows.push(row);
  }

  return { headers, rows };
}

/**
 * Reads a number from a statement cell.
 *
 * Indian bank exports write amounts as "1,25,000.00", sometimes with a trailing
 * Cr/Dr marker, sometimes blank for the side that does not apply. Anything that
 * is not a number comes back as 0 rather than NaN, so a blank debit column is
 * simply zero.
 */
export function parseAmount(value: string | undefined | null): number {
  if (!value) return 0;
  const cleaned = value.replace(/[₹,\s]/g, '').replace(/(cr|dr)$/i, '');
  const parsed = Number(cleaned);
  return Number.isFinite(parsed) ? Math.abs(parsed) : 0;
}

/**
 * Normalises a date cell to ISO `YYYY-MM-DD`.
 *
 * Bank statements use DD/MM/YYYY and DD-MM-YYYY far more often than ISO, and
 * `new Date("01/02/2026")` reads that as 2 January in the American convention.
 * Guessing wrongly here would date every entry in a statement to the wrong month
 * for eleven days of every twelve, so the day-first forms are parsed explicitly
 * and anything unrecognised is rejected rather than approximated.
 */
export function parseStatementDate(value: string | undefined | null): string | null {
  if (!value) return null;
  const text = value.trim();

  // Already ISO.
  const iso = /^(\d{4})-(\d{2})-(\d{2})/.exec(text);
  if (iso) return `${iso[1]}-${iso[2]}-${iso[3]}`;

  // DD/MM/YYYY or DD-MM-YYYY, with a two- or four-digit year.
  const dayFirst = /^(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})$/.exec(text);
  if (dayFirst) {
    const day = dayFirst[1]!.padStart(2, '0');
    const month = dayFirst[2]!.padStart(2, '0');
    let year = dayFirst[3]!;
    if (year.length === 2) year = `20${year}`;
    if (Number(month) < 1 || Number(month) > 12 || Number(day) < 1 || Number(day) > 31) {
      return null;
    }
    return `${year}-${month}-${day}`;
  }

  // DD-MMM-YYYY, e.g. 15-Aug-2026 — common in HDFC and ICICI exports.
  const monthNames = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
  const named = /^(\d{1,2})[-\s]([A-Za-z]{3})[A-Za-z]*[-\s](\d{2,4})$/.exec(text);
  if (named) {
    const index = monthNames.indexOf(named[2]!.toLowerCase());
    if (index === -1) return null;
    const day = named[1]!.padStart(2, '0');
    let year = named[3]!;
    if (year.length === 2) year = `20${year}`;
    return `${year}-${String(index + 1).padStart(2, '0')}-${day}`;
  }

  return null;
}
