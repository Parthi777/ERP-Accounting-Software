'use client';

import * as React from 'react';
import { useSearchParams } from 'next/navigation';
import { FileSpreadsheet, FileText, Loader2 } from 'lucide-react';

import { Button } from '@/components/ui/button';
import { cn } from '@/lib/utils';

/**
 * Export buttons — spec §51 ("Export" on every operational screen).
 *
 * The report is generated on the server, so the button is a download rather than
 * anything clever in the browser: the file contains the whole filtered result
 * set, not the page that happens to be rendered, and it is built by the same
 * service that built the screen.
 *
 * The current query string is forwarded as-is, so the export matches the filters
 * the user has applied. `extra` covers the cases where the screen holds a filter
 * that is not in the URL — the selected bank account or ledger party, typically.
 *
 * Fetched rather than linked so a failure can be reported. A plain <a download>
 * navigates away on a 500 and leaves the user on an error page with their
 * filters lost; here the screen stays put and shows what went wrong.
 */
export function ExportButtons({
  report,
  extra,
  className,
  size = 'sm',
  label = true,
}: {
  /** Registry id, e.g. `trial-balance`. */
  readonly report: string;
  /** Filters the screen holds outside the URL. */
  readonly extra?: Readonly<Record<string, string | number | null | undefined>>;
  readonly className?: string;
  readonly size?: 'sm' | 'md';
  /** False renders icon-only buttons, for tight toolbars. */
  readonly label?: boolean;
}) {
  const searchParams = useSearchParams();
  const [busy, setBusy] = React.useState<'xlsx' | 'pdf' | null>(null);
  const [error, setError] = React.useState<string | null>(null);

  async function download(format: 'xlsx' | 'pdf') {
    setBusy(format);
    setError(null);

    const params = new URLSearchParams(searchParams?.toString() ?? '');
    for (const [key, value] of Object.entries(extra ?? {})) {
      if (value !== null && value !== undefined && value !== '') {
        params.set(key, String(value));
      }
    }
    params.set('format', format);

    try {
      const response = await fetch(`/api/export/${report}?${params.toString()}`);

      if (!response.ok) {
        const message = await response
          .json()
          .then((body: { error?: string }) => body.error)
          .catch(() => null);
        setError(message ?? 'The export could not be generated.');
        return;
      }

      const blob = await response.blob();
      const url = URL.createObjectURL(blob);
      const anchor = document.createElement('a');
      anchor.href = url;
      anchor.download = filenameFrom(response.headers.get('Content-Disposition'), report, format);
      document.body.appendChild(anchor);
      anchor.click();
      anchor.remove();
      // Revoking immediately can cancel the download in some browsers; a tick is
      // enough for the click to have been handled.
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    } catch {
      setError('The export could not be downloaded. Check your connection and try again.');
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className={cn('flex flex-wrap items-center gap-2', className)}>
      <Button
        type="button"
        variant="secondary"
        size={size}
        onClick={() => void download('xlsx')}
        disabled={busy !== null}
        aria-label="Export to Excel"
      >
        {busy === 'xlsx' ? <Loader2 className="animate-spin" /> : <FileSpreadsheet />}
        {label && <span>Excel</span>}
      </Button>

      <Button
        type="button"
        variant="secondary"
        size={size}
        onClick={() => void download('pdf')}
        disabled={busy !== null}
        aria-label="Export to PDF"
      >
        {busy === 'pdf' ? <Loader2 className="animate-spin" /> : <FileText />}
        {label && <span>PDF</span>}
      </Button>

      {error && (
        <p role="alert" className="text-xs text-danger-700">
          {error}
        </p>
      )}
    </div>
  );
}

/** Prefers the server's filename, falling back to something sensible. */
function filenameFrom(disposition: string | null, report: string, format: string): string {
  const encoded = disposition?.match(/filename\*=UTF-8''([^;]+)/i)?.[1];
  if (encoded) {
    try {
      return decodeURIComponent(encoded);
    } catch {
      // Fall through to the plain parameter.
    }
  }

  const plain = disposition?.match(/filename="([^"]+)"/i)?.[1];
  return plain ?? `${report}.${format}`;
}
