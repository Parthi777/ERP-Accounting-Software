import { NextResponse } from 'next/server';

import { getTenantContext } from '@/server/auth/tenant-context';
import { renderProcessGuide } from '@/server/documents/process-guide';

/**
 * The process guide as a PDF — `GET /api/documents/process-guide`
 *
 * Signed in, and nothing more. The guide describes how the system is used and
 * carries no dealer data beyond the name on the cover, so gating it on a module
 * permission would only keep it from the people most likely to need it.
 *
 * Not audited either, for the same reason: this is a handbook, not a record.
 */

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

export async function GET() {
  const context = await getTenantContext();
  if (!context) {
    return NextResponse.json({ error: 'Not signed in.' }, { status: 401 });
  }

  try {
    const rendered = await renderProcessGuide(context.dealerName, new Date());

    return new NextResponse(new Uint8Array(rendered.body), {
      status: 200,
      headers: {
        'Content-Type': rendered.contentType,
        'Content-Length': String(rendered.body.length),
        // `attachment`: the common case is printing copies for new starters, not
        // reading it on screen — the Help page is better for that.
        'Content-Disposition': `attachment; filename="${rendered.filename}"`,
        'Cache-Control': 'no-store, must-revalidate',
      },
    });
  } catch (error) {
    console.error('[documents] process guide failed', error);
    return NextResponse.json(
      { error: 'The guide could not be generated. Please try again.' },
      { status: 500 },
    );
  }
}
