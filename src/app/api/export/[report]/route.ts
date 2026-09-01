import { NextResponse } from 'next/server';

import { getTenantContext, hasPermission } from '@/server/auth/tenant-context';
import { renderExcel } from '@/server/export/excel';
import { renderPdf } from '@/server/export/pdf';
import { findReport } from '@/server/export/registry';
import type { ExportFormat } from '@/server/export/types';
import { recordAudit } from '@/server/services/audit/record-audit';

/**
 * Report export — `GET /api/export/<report>?format=xlsx|pdf&…`
 *
 * The query string is whatever the screen was showing, so the file matches what
 * the user had on screen. The report id selects a registry entry; the entry's
 * loader calls the same service the page called, which is what makes the export
 * obey the same tenant scoping and the same restricted-field rules (spec §47,
 * §52). Nothing here queries the database directly, and nothing accepts a
 * dealer or a column list from the caller.
 *
 * Three gates, in order: an authenticated session, the report's permission, and
 * then the service's own `requirePermission` inside the loader. The third is the
 * one that actually protects the data; the first two exist so an unauthorised
 * request gets a clean 401/403 instead of an exception.
 *
 * Every successful export is audited (spec §46). Exporting the customer ledger
 * or a margin report is exactly the kind of act an audit trail is for — the data
 * leaves the system and nothing downstream is under the dealer's control.
 */

// Reports read live data, and PDF generation needs Node APIs.
export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

const FORMATS: Record<string, ExportFormat> = { xlsx: 'xlsx', pdf: 'pdf' };

export async function GET(
  request: Request,
  { params }: { params: Promise<{ report: string }> },
) {
  const { report: reportId } = await params;
  const url = new URL(request.url);

  const format = FORMATS[url.searchParams.get('format') ?? 'xlsx'];
  if (!format) {
    return NextResponse.json(
      { error: 'Unsupported format. Use xlsx or pdf.' },
      { status: 400 },
    );
  }

  const report = findReport(reportId);
  if (!report) {
    return NextResponse.json({ error: 'Unknown report.' }, { status: 404 });
  }

  const context = await getTenantContext();
  if (!context) {
    return NextResponse.json({ error: 'Not signed in.' }, { status: 401 });
  }

  if (!hasPermission(context, report.permission)) {
    return NextResponse.json(
      { error: 'You do not have permission to export this report.' },
      { status: 403 },
    );
  }

  const generatedAt = new Date();

  try {
    const data = await report.load(context, url.searchParams);

    const rendered =
      format === 'pdf'
        ? await renderPdf(report, data, context, generatedAt)
        : await renderExcel(report, data, context, generatedAt);

    // Audited after a successful render, so a failed export is not recorded as
    // one. Awaited rather than fired and forgotten: on a serverless runtime the
    // response ends the invocation, and a floating promise would be dropped.
    await recordAudit({
      action: 'EXPORT',
      entityType: 'report',
      entityId: report.id,
      dealerId: context.dealerId,
      branchId: context.activeBranch?.id ?? null,
      userId: context.userId,
      userEmail: context.email,
      newData: {
        report: report.id,
        title: report.title,
        format,
        rows: data.rows.length,
        truncated: data.truncatedAt !== undefined,
        filters: Object.fromEntries(url.searchParams),
      },
    });

    return new NextResponse(new Uint8Array(rendered.body), {
      status: 200,
      headers: {
        'Content-Type': rendered.contentType,
        'Content-Length': String(rendered.body.length),
        'Content-Disposition': contentDisposition(rendered.filename),
        // A report is a snapshot of live figures; a cached copy would be wrong
        // the moment anything posts.
        'Cache-Control': 'no-store, must-revalidate',
      },
    });
  } catch (error) {
    // The message can name accounts, customers and amounts, so it goes to the
    // server log and the caller gets something safe to show (spec §55).
    console.error(`[export] ${report.id} (${format}) failed`, error);
    return NextResponse.json(
      { error: 'The report could not be generated. Please try again, or narrow the date range.' },
      { status: 500 },
    );
  }
}

/**
 * A Content-Disposition that survives non-ASCII.
 *
 * Dealer and report names carry en dashes and rupee signs; a bare `filename=`
 * is latin-1 only, so the RFC 5987 `filename*` form carries the real name and
 * the plain parameter holds an ASCII fallback for older clients.
 */
function contentDisposition(filename: string): string {
  const ascii = filename.replace(/[^\x20-\x7E]/g, '_').replace(/["\\]/g, '_');
  return `attachment; filename="${ascii}"; filename*=UTF-8''${encodeURIComponent(filename)}`;
}
