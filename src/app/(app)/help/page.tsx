import type { Metadata } from 'next';
import Link from 'next/link';
import { Download } from 'lucide-react';

import { requireTenantContext } from '@/server/auth/tenant-context';
import { GUIDE_SECTIONS, GUIDE_SUBTITLE, GUIDE_TITLE } from '@/content/process-guide';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';

export const metadata: Metadata = { title: 'How this system is used' };
export const dynamic = 'force-dynamic';

/**
 * The process guide on screen — spec §8, §55.
 *
 * Every authenticated user can read it, whatever their role: someone who cannot
 * post a journal still benefits from knowing why the person next to them cannot
 * edit one either.
 *
 * Same text as the PDF, from src/content/process-guide.ts. The Help button in
 * the header links straight to the section for whatever screen you were on.
 */
export default async function Page() {
  await requireTenantContext();

  return (
    <div className="mx-auto max-w-4xl">
      <PageHeader
        title={GUIDE_TITLE}
        description={GUIDE_SUBTITLE}
        action={
          <Button variant="secondary" size="sm" asChild>
            {/* A plain link, not a fetch: the browser handles the download and
                the file never passes through React. */}
            <a href="/api/documents/process-guide">
              <Download aria-hidden />
              Download PDF
            </a>
          </Button>
        }
      />

      {/* Contents. Anchors, so a link to one process can be shared or pinned. */}
      <Panel className="mb-6 p-4">
        <p className="mb-2 text-xs font-medium uppercase tracking-wide text-ink-500">Contents</p>
        <ol className="grid gap-1 sm:grid-cols-2">
          {GUIDE_SECTIONS.map((section, index) => (
            <li key={section.id} className="text-sm">
              <Link href={`#${section.id}`} className="text-brand-600 hover:underline">
                {index + 1}. {section.title}
              </Link>
            </li>
          ))}
        </ol>
      </Panel>

      <div className="space-y-6">
        {GUIDE_SECTIONS.map((section, index) => (
          <Panel key={section.id} id={section.id} className="scroll-mt-24 p-5">
            <h2 className="text-lg font-semibold text-ink-900">
              {index + 1}. {section.title}
            </h2>
            <p className="mt-1 text-[11px] font-medium uppercase tracking-wide text-brand-600">
              {section.who}
            </p>
            {section.where && <p className="text-xs text-ink-500">{section.where}</p>}

            <div className="mt-3 space-y-2">
              {section.why.map((paragraph) => (
                <p key={paragraph.slice(0, 40)} className="text-sm leading-relaxed text-ink-700">
                  {paragraph}
                </p>
              ))}
            </div>

            {section.steps && section.steps.length > 0 && (
              <ol className="mt-4 space-y-3">
                {section.steps.map((step, i) => (
                  <li key={step.text.slice(0, 40)} className="flex gap-3">
                    <span className="numeric mt-0.5 inline-flex size-5 shrink-0 items-center justify-center rounded-md bg-brand-50 text-[11px] font-semibold text-brand-700">
                      {i + 1}
                    </span>
                    <span className="min-w-0">
                      <span className="block text-sm font-medium text-ink-900">{step.text}</span>
                      {step.note && (
                        <span className="mt-0.5 block text-xs leading-relaxed text-ink-500">
                          {step.note}
                        </span>
                      )}
                    </span>
                  </li>
                ))}
              </ol>
            )}

            {section.watchOut && section.watchOut.length > 0 && (
              <div className="mt-4 rounded-lg bg-warning-50 px-4 py-3">
                <p className="text-[11px] font-semibold uppercase tracking-wide text-warning-700">
                  Watch out
                </p>
                <ul className="mt-1.5 space-y-1.5">
                  {section.watchOut.map((line) => (
                    <li key={line.slice(0, 40)} className="text-xs leading-relaxed text-warning-800">
                      {line}
                    </li>
                  ))}
                </ul>
              </div>
            )}
          </Panel>
        ))}
      </div>
    </div>
  );
}
