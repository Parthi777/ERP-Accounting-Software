'use client';

import { useEffect } from 'react';

/**
 * Root error boundary — spec §55.
 *
 * `error.tsx` catches failures inside the layout. This catches failures *of* the
 * layout, which is why it renders its own `<html>` and `<body>`: at this point
 * nothing above it is left standing.
 *
 * It is also here for a build reason. Without a `global-error.tsx`, Next
 * generates a built-in `/_global-error` page and prerenders it, and that
 * prerender fails on some Node versions with
 * `TypeError: Cannot read properties of null (reading 'useContext')` — a build
 * that succeeds locally and fails in CI on nothing the application did.
 * Supplying our own page replaces the generated one, so the build no longer
 * depends on Next's fallback rendering cleanly.
 *
 * Deliberately styled inline. A layout failure may well be a stylesheet
 * failure, and an error page that needs the thing that just broke is no error
 * page at all.
 */
export default function GlobalError({
  error,
  reset,
}: {
  readonly error: Error & { digest?: string };
  readonly reset: () => void;
}) {
  useEffect(() => {
    // The digest is the only thread back to the server log, so it is worth
    // getting into the browser console even when the page renders.
    console.error('[global-error]', error.digest ?? '(no digest)', error.message);
  }, [error]);

  return (
    <html lang="en">
      <body
        style={{
          margin: 0,
          minHeight: '100vh',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          background: '#f8fafc',
          color: '#0f172a',
          fontFamily:
            'ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif',
        }}
      >
        <main style={{ maxWidth: '32rem', padding: '2rem', textAlign: 'center' }}>
          <h1 style={{ fontSize: '1.25rem', fontWeight: 600, margin: '0 0 0.5rem' }}>
            Something went wrong
          </h1>
          <p style={{ fontSize: '0.875rem', color: '#475569', margin: '0 0 1.5rem' }}>
            The page could not be displayed. Nothing you were working on has been saved, so no
            half-finished entry has been recorded.
          </p>

          {error.digest && (
            <p
              style={{
                fontSize: '0.75rem',
                color: '#64748b',
                fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
                margin: '0 0 1.5rem',
              }}
            >
              Reference {error.digest}
            </p>
          )}

          <button
            type="button"
            onClick={reset}
            style={{
              height: '2.25rem',
              padding: '0 1rem',
              borderRadius: '0.5rem',
              border: 'none',
              background: '#2563eb',
              color: '#ffffff',
              fontSize: '0.875rem',
              fontWeight: 500,
              cursor: 'pointer',
            }}
          >
            Try again
          </button>
        </main>
      </body>
    </html>
  );
}
