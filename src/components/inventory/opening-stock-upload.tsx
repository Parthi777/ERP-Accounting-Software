'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { AlertTriangle, CheckCircle2, FileUp, Loader2, Upload } from 'lucide-react';

import { Panel, SolidPanel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { cn } from '@/lib/utils';
import {
  commitOpeningStockAction,
  previewOpeningStockAction,
} from '@/server/services/inventory/inventory-actions';
import type { OpeningStockPreview } from '@/server/services/inventory/inventory-service';

/**
 * Accessory and spare opening stock upload — spec §14, §34.
 *
 * The flow the spec asks for, in order:
 *   Upload → Preview → Validation → Error report → Confirm Import
 *
 * Nothing is written until Confirm, and Confirm is disabled while any row has an
 * error. Spec §14: "Do not partially import silently." Importing the good rows
 * and listing the rest would leave the operator unable to tell what actually
 * landed without checking every lot by hand.
 */
export function OpeningStockUpload() {
  const router = useRouter();
  const [fileName, setFileName] = React.useState<string | null>(null);
  const [csv, setCsv] = React.useState<string | null>(null);
  const [preview, setPreview] = React.useState<OpeningStockPreview | null>(null);
  const [result, setResult] = React.useState<{ imported: number } | null>(null);
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
        setPreview(await previewOpeningStockAction(text));
      });
    };
    reader.onerror = () => setError('That file could not be read.');
    reader.readAsText(file);
  };

  const confirm = () => {
    if (!csv) return;
    setError(null);
    startTransition(async () => {
      const outcome = await commitOpeningStockAction(csv);
      if (!outcome.ok) {
        setError(outcome.error ?? 'The import failed.');
        return;
      }
      setResult({ imported: outcome.imported ?? 0 });
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

  if (result) {
    return (
      <Panel className="p-6 text-center">
        <div className="mx-auto mb-3 flex size-12 items-center justify-center rounded-2xl bg-positive-50 text-positive-600">
          <CheckCircle2 className="size-6" aria-hidden />
        </div>
        <h2 className="text-base font-semibold text-ink-900">
          {result.imported} lot{result.imported === 1 ? '' : 's'} imported
        </h2>
        <p className="mt-1 text-sm text-ink-600">
          Each is an opening movement in the stock ledger, so the quantity can be traced to the row
          that put it there.
        </p>
        <div className="mt-5 flex justify-center gap-2">
          <Button onClick={() => router.push('/inventory/ledger')}>View stock ledger</Button>
          <Button variant="secondary" onClick={reset}>Upload another file</Button>
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

      {/* Step 1 — choose a file */}
      <Panel
        className={cn('p-6 transition-colors', dragging && 'ring-2 ring-brand-400')}
        onDragOver={(e) => { e.preventDefault(); setDragging(true); }}
        onDragLeave={() => setDragging(false)}
        onDrop={(e) => {
          e.preventDefault();
          setDragging(false);
          const file = e.dataTransfer.files[0];
          if (file) read(file);
        }}
      >
        <div className="text-center">
          <div className="mx-auto mb-3 flex size-12 items-center justify-center rounded-2xl bg-brand-50 text-brand-600">
            <FileUp className="size-6" aria-hidden />
          </div>
          <h2 className="text-sm font-semibold text-ink-900">
            {fileName ?? 'Drop a CSV file here, or choose one'}
          </h2>
          <p className="mt-1 text-xs text-ink-500">
            Required columns: item_code, branch_code, source, quantity, unit_cost.
            Source is LOCAL or COMPANY — the two are stocked and valued separately.
          </p>

          <div className="mt-4 flex justify-center gap-2">
            <label>
              <input
                type="file"
                accept=".csv,text/csv"
                className="sr-only"
                onChange={(e) => {
                  const file = e.target.files?.[0];
                  if (file) read(file);
                }}
              />
              <span className="inline-flex h-9 cursor-pointer items-center gap-2 rounded-lg bg-brand-600 px-4 text-sm font-medium text-white shadow-sm hover:bg-brand-700">
                <Upload className="size-4" aria-hidden />
                Choose file
              </span>
            </label>
            <Button variant="secondary" asChild>
              <a href="/inventory-stock-template.csv" download>Download template</a>
            </Button>
            {fileName && <Button variant="ghost" onClick={reset}>Clear</Button>}
          </div>
        </div>
      </Panel>

      {pending && !preview && (
        <Panel className="flex items-center justify-center gap-2 p-6 text-sm text-ink-600">
          <Loader2 className="size-4 animate-spin" aria-hidden />
          Validating…
        </Panel>
      )}

      {/* Steps 2–4 — preview, validation, error report */}
      {preview && preview.rows.length > 0 && (
        <>
          <Panel className="flex flex-wrap items-center justify-between gap-3 p-4">
            <div className="flex items-center gap-3">
              <Badge variant={preview.errorCount === 0 ? 'positive' : 'danger'}>
                {preview.errorCount === 0 ? 'Ready to import' : `${preview.errorCount} row(s) with errors`}
              </Badge>
              <span className="text-sm text-ink-600">
                {preview.validCount} valid · {preview.errorCount} with errors · {preview.rows.length} total
              </span>
            </div>

            <Button onClick={confirm} disabled={pending || preview.errorCount > 0}>
              {pending && <Loader2 className="animate-spin" aria-hidden />}
              Confirm import
            </Button>
          </Panel>

          {preview.errorCount > 0 && (
            <div className="flex items-start gap-2 rounded-lg border border-warning-200 bg-warning-50 px-3 py-2 text-sm text-warning-800">
              <AlertTriangle className="mt-0.5 size-4 shrink-0" aria-hidden />
              <span>
                Nothing has been imported. Fix every highlighted row in your file and upload it again —
                a partial import would leave you unsure which lots actually landed.
              </span>
            </div>
          )}

          <SolidPanel className="overflow-hidden">
            <div className="table-sticky overflow-auto" style={{ maxHeight: '32rem' }}>
              <table className="w-full border-collapse text-sm">
                <caption className="sr-only">Import preview</caption>
                <thead>
                  <tr>
                    {['Row', 'Item', 'Branch', 'Source', 'Quantity', 'Unit cost', 'Result'].map((h) => (
                      <th key={h} scope="col" className="whitespace-nowrap px-3 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">
                        {h}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {preview.rows.map((row) => (
                    <tr
                      key={row.rowNumber}
                      className={cn('border-t border-ink-100', row.errors.length > 0 && 'bg-danger-50/50')}
                    >
                      <td className="px-3 py-2 text-xs text-ink-400">{row.rowNumber}</td>
                      <td className="px-3 py-2 font-mono text-xs">{row.item_code || '—'}</td>
                      <td className="px-3 py-2">{row.branch_code || '—'}</td>
                      <td className="px-3 py-2">{row.source || '—'}</td>
                      <td className="numeric px-3 py-2">{row.quantity || '—'}</td>
                      <td className="numeric px-3 py-2">{row.unit_cost || '—'}</td>
                      <td className="px-3 py-2">
                        {row.errors.length === 0 ? (
                          <span className="text-xs text-positive-700">OK</span>
                        ) : (
                          <ul className="space-y-0.5">
                            {row.errors.map((e) => (
                              <li key={e} className="text-xs text-danger-700">{e}</li>
                            ))}
                          </ul>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </SolidPanel>
        </>
      )}
    </div>
  );
}
