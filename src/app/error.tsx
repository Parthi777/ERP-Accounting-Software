'use client';

import { useEffect } from 'react';
import { AlertTriangle, RotateCw } from 'lucide-react';

import { Button } from '@/components/ui/button';

/**
 * Error boundary. Spec §55: never fail silently, and never show a user a raw
 * technical message. The digest identifies the entry in the server log.
 */
export default function GlobalError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    console.error('[app] unhandled error', error);
  }, [error]);

  return (
    <div className="flex min-h-dvh items-center justify-center px-4">
      <div className="glass w-full max-w-md rounded-2xl p-6 text-center">
        <div className="mx-auto mb-4 flex size-12 items-center justify-center rounded-2xl bg-danger-50 text-danger-600">
          <AlertTriangle className="size-6" aria-hidden />
        </div>
        <h1 className="text-lg font-semibold text-ink-900">Something went wrong</h1>
        <p className="mt-2 text-sm text-ink-600">
          The action could not be completed. Nothing was saved, so it is safe to try again.
        </p>
        {error.digest && (
          <p className="mt-3 font-mono text-[11px] text-ink-400">Reference: {error.digest}</p>
        )}
        <Button onClick={reset} className="mt-5">
          <RotateCw aria-hidden />
          Try again
        </Button>
      </div>
    </div>
  );
}
