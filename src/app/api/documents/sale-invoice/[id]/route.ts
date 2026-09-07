import { NextResponse } from 'next/server';

import { getTenantContext } from '@/server/auth/tenant-context';
import { getTaxInvoiceDocument } from '@/server/services/sales/invoice-document-service';
import { renderTaxInvoice } from '@/server/documents/tax-invoice';
import { recordAudit } from '@/server/services/audit/record-audit';

/**
 * The customer's tax invoice — `GET /api/documents/sale-invoice/<sale id>`
 *
 * Same three gates as the report export, in the same order: a session, then the
 * service's own `requirePermission('sales.view')`, then RLS on the row itself.
 * The service is the gate that matters; the 401 here exists so an expired
 * session gets a clean status instead of an exception.
 *
 * A sale that is not POSTED or DELIVERED comes back as null and is answered 404
 * rather than 403 — the invoice does not exist yet, which is a different fact
 * from the caller not being allowed to see it, and the caller is allowed to know
 * which.
 *
 * Every render is audited. The invoice is the document the dealer's GST position
 * rests on; who printed a copy of it, and when, is exactly what an audit trail
 * is for (spec §46).
 */

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ id: string }> },
) {
  const { id } = await params;

  const context = await getTenantContext();
  if (!context) {
    return NextResponse.json({ error: 'Not signed in.' }, { status: 401 });
  }

  try {
    const invoice = await getTaxInvoiceDocument(id);

    if (!invoice) {
      return NextResponse.json(
        { error: 'No posted invoice exists for that sale.' },
        { status: 404 },
      );
    }

    const rendered = await renderTaxInvoice(invoice, new Date());

    // Awaited, not fired and forgotten: the response ends the invocation and a
    // floating promise would be dropped on a serverless runtime.
    await recordAudit({
      action: 'EXPORT',
      entityType: 'sales',
      entityId: id,
      dealerId: context.dealerId,
      branchId: context.activeBranch?.id ?? null,
      userId: context.userId,
      userEmail: context.email,
      newData: {
        document: 'TAX_INVOICE',
        invoice_number: invoice.invoiceNumber,
        total: invoice.totalAmount,
      },
    });

    return new NextResponse(new Uint8Array(rendered.body), {
      status: 200,
      headers: {
        'Content-Type': rendered.contentType,
        'Content-Length': String(rendered.body.length),
        // `inline` so it opens in the browser's viewer — the common case is a
        // counter clerk pressing print, not saving a file.
        'Content-Disposition': `inline; filename="${rendered.filename}"`,
        'Cache-Control': 'no-store, must-revalidate',
      },
    });
  } catch (error) {
    // The message can name the customer and the amounts, so it goes to the log
    // and the caller gets something safe to show (spec §55).
    console.error(`[documents] tax invoice ${id} failed`, error);
    return NextResponse.json(
      { error: 'The invoice could not be generated. Please try again.' },
      { status: 500 },
    );
  }
}
