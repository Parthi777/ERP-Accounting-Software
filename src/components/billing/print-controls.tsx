'use client';

import * as React from 'react';

/** Print on load when asked, and buttons that never reach the paper. */
export function PrintControls({ autoPrint, id, wide, base = '/print/bill' }: { readonly autoPrint: boolean; readonly id: string; readonly wide: boolean; readonly base?: string }) {
  React.useEffect(() => {
    if (autoPrint) {
      const t = window.setTimeout(() => window.print(), 300);
      return () => window.clearTimeout(t);
    }
  }, [autoPrint]);

  return (
    <div className="no-print mb-3 flex flex-wrap gap-2 font-sans text-sm">
      <button type="button" onClick={() => window.print()} className="rounded-md bg-blue-600 px-3 py-1.5 font-semibold text-white">
        Print
      </button>
      <a href={`${base}/${id}${wide ? '' : '?size=a5'}`} className="rounded-md border border-gray-300 px-3 py-1.5">
        {wide ? '80 mm slip' : 'A5 page'}
      </a>
      <button type="button" onClick={() => window.close()} className="rounded-md border border-gray-300 px-3 py-1.5">
        Close
      </button>
    </div>
  );
}
