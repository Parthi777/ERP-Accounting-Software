'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { ExternalLink, RefreshCw } from 'lucide-react';

/**
 * Create a missing master without losing the voucher (BUSY F20). "New" opens
 * the master's own form — with its own validation — in a new tab; "Refresh
 * list" reloads the pickers here while everything typed so far stays put.
 */
export function QuickAdd({ href, noun }: { readonly href: string; readonly noun: string }) {
  const router = useRouter();
  const [pending, startTransition] = React.useTransition();
  return (
    <span className="ml-2 inline-flex items-center gap-2 text-[11px] font-normal">
      <a href={href} target="_blank" rel="noopener" className="inline-flex items-center gap-0.5 text-brand-700 hover:underline">
        New {noun}<ExternalLink className="size-3" aria-hidden />
      </a>
      <button type="button" className="inline-flex items-center gap-0.5 text-ink-500 hover:text-ink-800"
        onClick={() => startTransition(() => router.refresh())} aria-label={`Refresh the ${noun} list`}>
        <RefreshCw className={pending ? 'size-3 animate-spin' : 'size-3'} aria-hidden />refresh list
      </button>
    </span>
  );
}
