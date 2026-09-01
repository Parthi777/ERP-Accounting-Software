import 'server-only';

import { parseAmount, parseCsv, parseStatementDate } from '@/lib/csv';
import type { ParsedStatementRow } from '@/server/services/bank/bank-service';

/**
 * Turns a bank's CSV export into rows the importer can stage — spec §39.
 *
 * No two Indian banks agree on column names, so each field accepts the aliases
 * seen in practice. What is *not* guessed is the amount convention: a file must
 * say which side each row is on, either through separate debit/credit columns or
 * through an explicit Cr/Dr marker. Inferring direction from a sign would quietly
 * reverse every entry in a statement that uses the opposite convention.
 */

const ALIASES = {
  date: ['transaction_date', 'txn_date', 'date', 'tran_date', 'posting_date', 'transaction_date_'],
  valueDate: ['value_date', 'value_dt', 'val_date'],
  narration: ['narration', 'description', 'particulars', 'remarks', 'transaction_remarks', 'details'],
  reference: ['reference', 'ref_no', 'reference_no', 'chq_ref_no', 'cheque_ref', 'ref'],
  utr: ['utr', 'utr_no', 'utr_number', 'rrn', 'transaction_id', 'txn_id'],
  cheque: ['cheque_number', 'cheque_no', 'chq_no', 'instrument_no', 'instrument_number'],
  debit: ['debit', 'withdrawal', 'withdrawal_amt', 'withdrawal_amount', 'dr', 'dr_amount', 'debit_amount', 'paid_out'],
  credit: ['credit', 'deposit', 'deposit_amt', 'deposit_amount', 'cr', 'cr_amount', 'credit_amount', 'paid_in'],
  amount: ['amount', 'transaction_amount', 'txn_amount'],
  type: ['type', 'dr_cr', 'drcr', 'transaction_type', 'debit_credit'],
  balance: ['balance', 'closing_balance', 'running_balance', 'balance_amt'],
} as const;

function pick(row: Record<string, string>, keys: readonly string[]): string | undefined {
  for (const key of keys) {
    const value = row[key];
    if (value !== undefined && value !== '') return value;
  }
  return undefined;
}

export interface StatementParseResult {
  readonly rows: readonly ParsedStatementRow[];
  readonly errors: readonly { readonly line: number; readonly message: string }[];
  readonly totalLines: number;
  readonly headers: readonly string[];
}

export function parseStatement(text: string): StatementParseResult {
  const { headers, rows: raw } = parseCsv(text);

  if (headers.length === 0) {
    return {
      rows: [],
      errors: [{ line: 0, message: 'The file has no header row, or no rows beneath it.' }],
      totalLines: 0,
      headers: [],
    };
  }

  const rows: ParsedStatementRow[] = [];
  const errors: { line: number; message: string }[] = [];

  raw.forEach((row, index) => {
    const line = index + 2; // Header is line 1.

    const statementDate = parseStatementDate(pick(row, ALIASES.date));
    if (!statementDate) {
      errors.push({
        line,
        message: `Could not read a transaction date from "${pick(row, ALIASES.date) ?? '(blank)'}".`,
      });
      return;
    }

    let debit = parseAmount(pick(row, ALIASES.debit));
    let credit = parseAmount(pick(row, ALIASES.credit));

    // A single-amount statement: the Cr/Dr marker decides the side. Without one
    // there is no honest way to tell a receipt from a payment.
    if (debit === 0 && credit === 0) {
      const amount = parseAmount(pick(row, ALIASES.amount));
      const marker = (pick(row, ALIASES.type) ?? '').trim().toLowerCase();

      if (amount > 0) {
        if (marker.startsWith('c') || marker.includes('credit') || marker.includes('deposit')) {
          credit = amount;
        } else if (marker.startsWith('d') || marker.includes('debit') || marker.includes('withdraw')) {
          debit = amount;
        } else {
          errors.push({
            line,
            message: 'The row has one amount but no Cr/Dr marker, so its direction is unknown.',
          });
          return;
        }
      }
    }

    if (debit === 0 && credit === 0) {
      errors.push({ line, message: 'The row has neither a debit nor a credit amount.' });
      return;
    }
    if (debit > 0 && credit > 0) {
      errors.push({ line, message: 'The row has both a debit and a credit amount.' });
      return;
    }

    const narration = (pick(row, ALIASES.narration) ?? '').trim();
    if (!narration) {
      errors.push({ line, message: 'The row has no narration.' });
      return;
    }

    rows.push({
      statement_date: statementDate,
      value_date: parseStatementDate(pick(row, ALIASES.valueDate)),
      narration,
      reference: pick(row, ALIASES.reference) ?? null,
      utr: pick(row, ALIASES.utr) ?? null,
      cheque_number: pick(row, ALIASES.cheque) ?? null,
      debit,
      credit,
      running_balance: pick(row, ALIASES.balance) ? parseAmount(pick(row, ALIASES.balance)) : null,
    });
  });

  return { rows, errors, totalLines: raw.length, headers };
}
