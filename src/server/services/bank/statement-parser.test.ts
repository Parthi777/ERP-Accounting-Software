import { describe, expect, it } from 'vitest';

import { parseStatement } from './statement-parser';

/**
 * A statement parser gets one thing catastrophically wrong or nothing wrong: if
 * direction is inferred incorrectly, every receipt in the file becomes a payment
 * and the reconciliation fails against a bank balance that is right. These
 * assertions are mostly about refusing to guess.
 */

const csv = (...lines: string[]) => lines.join('\n');

describe('parseStatement', () => {
  it('reads separate debit and credit columns', () => {
    const result = parseStatement(
      csv(
        'Date,Narration,Withdrawal Amt,Deposit Amt,Closing Balance',
        '01/02/2026,NEFT from customer,,5000.00,15000.00',
        '02/02/2026,Rent paid,12000.00,,3000.00',
      ),
    );

    expect(result.errors).toEqual([]);
    expect(result.rows).toHaveLength(2);

    expect(result.rows[0]).toMatchObject({
      statement_date: '2026-02-01',
      narration: 'NEFT from customer',
      debit: 0,
      credit: 5000,
      running_balance: 15000,
    });
    expect(result.rows[1]).toMatchObject({ debit: 12000, credit: 0 });
  });

  /**
   * The single assertion that protects a whole statement. One amount column and
   * no Cr/Dr marker is unreadable, and guessing — from a sign, from the balance
   * moving, from anything — would silently reverse every row in a file using the
   * opposite convention. The row is dropped and the line reported.
   */
  it('refuses a single amount with no Cr/Dr marker, rather than guessing', () => {
    const result = parseStatement(
      csv('Date,Narration,Amount', '01/02/2026,Mystery transaction,5000.00'),
    );

    expect(result.rows).toHaveLength(0);
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]!.message).toMatch(/direction is unknown/i);
  });

  it('uses an explicit Cr/Dr marker when there is one', () => {
    const result = parseStatement(
      csv(
        'Date,Narration,Amount,Dr/Cr',
        '01/02/2026,Deposit,5000.00,Cr',
        '02/02/2026,Withdrawal,2000.00,Dr',
        '03/02/2026,Spelled out,100.00,CREDIT',
      ),
    );

    expect(result.errors).toEqual([]);
    expect(result.rows.map((r) => [r.debit, r.credit])).toEqual([
      [0, 5000],
      [2000, 0],
      [0, 100],
    ]);
  });

  /** Error lines are 1-based on the file. An off-by-one makes every message useless. */
  it('numbers error lines as the operator sees them, header included', () => {
    const result = parseStatement(
      csv(
        'Date,Narration,Deposit',
        '01/02/2026,Good row,100.00',
        'not-a-date,Bad row,100.00',
        '03/02/2026,Another good row,100.00',
        '04/02/2026,,100.00',
      ),
    );

    expect(result.rows).toHaveLength(2);
    expect(result.errors.map((e) => e.line)).toEqual([3, 5]);
    expect(result.errors[1]!.message).toMatch(/no narration/i);
  });

  it('rejects a row carrying both a debit and a credit', () => {
    const result = parseStatement(
      csv('Date,Narration,Debit,Credit', '01/02/2026,Both sides,100.00,200.00'),
    );
    expect(result.rows).toHaveLength(0);
    expect(result.errors[0]!.message).toMatch(/both a debit and a credit/i);
  });

  it('rejects a row with neither', () => {
    const result = parseStatement(
      csv('Date,Narration,Debit,Credit', '01/02/2026,Nothing,,'),
    );
    expect(result.rows).toHaveLength(0);
    expect(result.errors[0]!.message).toMatch(/neither/i);
  });

  /**
   * A real HDFC-shaped header. This is what catches someone tidying ALIASES:
   * drop `chq_ref_no` and this file stops finding references, which no other
   * assertion would notice.
   */
  it('parses a real bank header row clean', () => {
    const result = parseStatement(
      csv(
        'Date,Narration,Chq/Ref No,Value Dt,Withdrawal Amt,Deposit Amt,Closing Balance',
        '15/08/2026,UPI-RAMESH-9876543210,UPI123456789,15/08/2026,,2500.00,47500.00',
      ),
    );

    expect(result.errors).toEqual([]);
    expect(result.rows[0]).toMatchObject({
      statement_date: '2026-08-15',
      value_date: '2026-08-15',
      reference: 'UPI123456789',
      credit: 2500,
    });
  });

  it('finds a UTR under any of the names banks use for it', () => {
    for (const header of ['UTR', 'UTR No', 'RRN', 'Transaction ID']) {
      const result = parseStatement(
        csv(`Date,Narration,Deposit,${header}`, '01/02/2026,NEFT in,100.00,ABC123'),
      );
      expect(result.rows[0]!.utr, `header: ${header}`).toBe('ABC123');
    }
  });

  it('leaves optional fields null rather than empty strings', () => {
    const result = parseStatement(
      csv('Date,Narration,Deposit', '01/02/2026,Minimal row,100.00'),
    );
    expect(result.rows[0]).toMatchObject({
      value_date: null,
      reference: null,
      utr: null,
      cheque_number: null,
      running_balance: null,
    });
  });

  it('reports a file with no usable header instead of throwing', () => {
    const result = parseStatement('');
    expect(result.rows).toEqual([]);
    expect(result.errors).toHaveLength(1);
    expect(result.totalLines).toBe(0);
  });

  it('counts every data line, including the ones it rejected', () => {
    const result = parseStatement(
      csv('Date,Narration,Deposit', '01/02/2026,Good,100.00', 'bad,Bad,100.00'),
    );
    expect(result.totalLines).toBe(2);
    expect(result.rows).toHaveLength(1);
    expect(result.errors).toHaveLength(1);
  });
});
