'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { AlertTriangle, CheckCircle2, FileUp, Loader2, Upload } from 'lucide-react';

import { Panel, SolidPanel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { cn } from '@/lib/utils';
import { formatINR, fromRupees } from '@/lib/money';
import { formatDate } from '@/lib/format';
import { importStatementAction, previewStatementAction } from '@/server/services/bank/bank-actions';
import type { StatementParseResult } from '@/server/services/bank/statement-parser';

interface BankOption {
  readonly id: string;
  readonly label: string;
}

/**
 * Bank statement import — spec §39.
 *
 * Upload → Preview → Confirm, the same shape as the vehicle stock import. Rows
 * that could not be read are listed with their line numbers rather than dropped
 * quietly, because a statement missing three rows reconciles to a number that
 * looks plausible and is wrong.
 *
 * Unlike the stock import, unreadable rows do not block the import: a bank export
 * routinely carries header junk and summary lines that are not transactions at
 * all. They are shown, and the operator decides.
 */
export function StatementImport({ accounts }: { readonly accounts: readonly BankOption[] }) {
  const router = useRouter();
  const [accountId, setAccountId] = React.useState(accounts[0]?.id ?? '');
  const [fileName, setFileName] = React.useState<string | null>(null);
  const [csv, setCsv] = React.useState<string | null>(null);
  const [preview, setPreview] = React.useState<StatementParseResult | null>(null);
  const [result, setResult] = React.useState<{ imported: number; skipped: number } | null>(null);
  const [error, setError] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();
  const [dragging, setDragging] = React.useState(false);

  const read = (file: File) => {
    setError(null);
    setResult(null);
    setFileName(file.name);

    const reader = new FileReader();
    reader.onload = () => {
      const text = String(reader.result ?? '');
      setCsv(text);
      startTransition(async () => {
        setPreview(await previewStatementAction(text));
      });
    };
    reader.onerror = () => setError('That file could not be read.');
    reader.readAsText(file);
  };

  const confirm = () => {
    if (!csv || !preview || !accountId) return;
    setError(null);
    startTransition(async () => {
      const outcome = await importStatementAction(accountId, preview.rows);
      if (!outcome.ok) {
        setError(outcome.error ?? 'The import failed.');
        return;
      }
      setResult({ imported: outcome.imported ?? 0, skipped: outcome.skipped ?? 0 });
      setPreview(null);
      setCsv(null);
      router.refresh();
    });
  };

  const reset = () => {
    setCsv(null);
    setPreview(null);
    setFileName(null);
    setResult(null);
    setError(null);
  };

  if (accounts.length === 0) {
    return (
      <Panel className="p-6">
        <p className="text-sm text-ink-700">
          No bank accounts exist yet. One must be created before a statement can be imported.
        </p>
      </Panel>
    );
  }

  if (result) {
    return (
      <Panel className="p-6 text-center">
        <div className="mx-auto mb-3 flex size-12 items-center justify-center rounded-2xl bg-positive-50 text-positive-600">
          <CheckCircle2 className="size-6" aria-hidden />
        </div>
        <h2 className="text-base font-semibold text-ink-900">
          {result.imported} line{result.imported === 1 ? '' : 's'} imported
        </h2>
        <p className="mt-1 text-sm text-ink-600">
          {result.skipped > 0
            ? `${result.skipped} were skipped as duplicates of lines already staged.`
            : 'Nothing was skipped.'}
        </p>
        <div className="mt-4 flex justify-center gap-2">
          <Button size="sm" asChild>
            <Link href={`/bank/reconciliation?account=${accountId}`}>Reconcile now</Link>
          </Button>
          <Button variant="secondary" size="sm" onClick={reset}>Import another</Button>
        </div>
      </Panel>
    );
  }

  return (
    <div className="space-y-4">
      {error && (
        <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
          {error}
        </div>
      )}

      <Panel className="p-5">
        <label htmlFor="bank-account" className="mb-1.5 block text-sm font-medium text-ink-700">
          Import into
        </label>
        <select id="bank-account" value={accountId} onChange={(e) => setAccountId(e.target.value)}
          className="h-9 w-full max-w-md rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
          {accounts.map((a) => <option key={a.id} value={a.id}>{a.label}</option>)}
        </select>
      </Panel>

      {!preview && (
        <Panel
          className={cn('border-2 border-dashed p-8 text-center transition-colors',
            dragging ? 'border-brand-400 bg-brand-50/50' : 'border-ink-200')}
          onDragOver={(e) => { e.preventDefault(); setDragging(true); }}
          onDragLeave={() => setDragging(false)}
          onDrop={(e) => {
            e.preventDefault();
            setDragging(false);
            const file = e.dataTransfer.files[0];
            if (file) read(file);
          }}
        >
          <div className="mx-auto mb-3 flex size-12 items-center justify-center rounded-2xl bg-brand-50 text-brand-600">
            {pending ? <Loader2 className="size-6 animate-spin" aria-hidden /> : <FileUp className="size-6" aria-hidden />}
          </div>
          <p className="text-sm font-medium text-ink-900">Drop the bank statement CSV here</p>
          <p className="mt-1 text-xs text-ink-500">
            Column names are matched automatically — date, narration, debit/credit or amount with a Cr/Dr
            marker, and UTR or cheque number where the bank provides them.
          </p>
          <label className="mt-4 inline-flex cursor-pointer items-center gap-2 rounded-lg border border-ink-200 bg-white px-3 py-1.5 text-sm font-medium text-ink-700 shadow-sm hover:bg-ink-50">
            <Upload className="size-4" aria-hidden />
            Choose a file
            <input type="file" accept=".csv,text/csv" className="sr-only"
              onChange={(e) => { const file = e.target.files?.[0]; if (file) read(file); }} />
          </label>
        </Panel>
      )}

      {preview && (
        <>
          <Panel className="p-5">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div>
                <h2 className="text-sm font-semibold text-ink-900">{fileName}</h2>
                <p className="mt-0.5 text-xs text-ink-500">
                  {preview.totalLines} rows read · {preview.rows.length} importable
                  {preview.errors.length > 0 && ` · ${preview.errors.length} unreadable`}
                </p>
              </div>
              <div className="flex gap-2">
                <Button size="sm" onClick={confirm} disabled={pending || preview.rows.length === 0}>
                  {pending && <Loader2 className="animate-spin" aria-hidden />}
                  Import {preview.rows.length} lines
                </Button>
                <Button variant="secondary" size="sm" onClick={reset} disabled={pending}>Start over</Button>
              </div>
            </div>
          </Panel>

          {preview.errors.length > 0 && (
            <Panel className="border-warning-200 bg-warning-50 p-4">
              <p className="flex items-center gap-2 text-sm font-medium text-warning-900">
                <AlertTriangle className="size-4" aria-hidden />
                {preview.errors.length} row{preview.errors.length === 1 ? '' : 's'} could not be read
              </p>
              <ul className="mt-2 space-y-0.5 text-xs text-warning-800">
                {preview.errors.slice(0, 10).map((e) => (
                  <li key={e.line}>Line {e.line}: {e.message}</li>
                ))}
                {preview.errors.length > 10 && <li>…and {preview.errors.length - 10} more.</li>}
              </ul>
              <p className="mt-2 text-xs text-warning-800">
                Bank exports often carry header and summary rows that are not transactions. Check that
                nothing here is a real entry before importing.
              </p>
            </Panel>
          )}

          <SolidPanel className="overflow-hidden">
            <div className="max-h-[28rem] overflow-auto">
              <table className="w-full border-collapse text-sm">
                <thead className="sticky top-0 bg-ink-50 text-left text-xs font-medium text-ink-600">
                  <tr>
                    <th className="px-3 py-2">Date</th>
                    <th className="px-3 py-2">Narration</th>
                    <th className="px-3 py-2">Reference</th>
                    <th className="px-3 py-2 text-right">Debit</th>
                    <th className="px-3 py-2 text-right">Credit</th>
                  </tr>
                </thead>
                <tbody>
                  {preview.rows.slice(0, 200).map((row, i) => (
                    <tr key={i} className="border-t border-ink-100">
                      <td className="whitespace-nowrap px-3 py-1.5">{formatDate(row.statement_date)}</td>
                      <td className="max-w-md truncate px-3 py-1.5" title={row.narration}>{row.narration}</td>
                      <td className="px-3 py-1.5 font-mono text-xs text-ink-500">
                        {row.utr ?? row.cheque_number ?? row.reference ?? '—'}
                      </td>
                      <td className="numeric px-3 py-1.5 text-right text-danger-700">
                        {row.debit > 0 ? formatINR(fromRupees(row.debit)) : '—'}
                      </td>
                      <td className="numeric px-3 py-1.5 text-right text-positive-700">
                        {row.credit > 0 ? formatINR(fromRupees(row.credit)) : '—'}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {preview.rows.length > 200 && (
              <p className="border-t border-ink-100 px-3 py-2 text-xs text-ink-500">
                Showing the first 200 of {preview.rows.length} rows. All of them will be imported.
              </p>
            )}
          </SolidPanel>

          <Panel className="p-4">
            <p className="text-xs text-ink-500">
              Detected columns: {preview.headers.map((h) => <Badge key={h} variant="neutral" className="mr-1">{h}</Badge>)}
            </p>
          </Panel>
        </>
      )}
    </div>
  );
}
