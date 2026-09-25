import type { Metadata } from 'next';
import { notFound, redirect } from 'next/navigation';

import { getTenantContext } from '@/server/auth/tenant-context';
import { getPrintableBill } from '@/server/services/billing/quick-bill-service';
import { PrintControls } from '@/components/billing/print-controls';
import { formatINR } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Receipt' };
export const dynamic = 'force-dynamic';

/**
 * The customer's copy: bill and receipt on one slip (0088). Laid out for an
 * 80 mm thermal printer and readable on A4 — whichever printer the counter
 * machine has as its default. `?print=1` opens the print dialog on load.
 */
export default async function PrintBillPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ print?: string; size?: string }>;
}) {
  const context = await getTenantContext();
  if (!context) redirect('/login');
  const { id } = await params;
  const query = await searchParams;
  const bill = await getPrintableBill(id);
  if (!bill) notFound();

  const wide = query.size === 'a5';
  const row = 'flex justify-between gap-2';

  return (
    <main className={`receipt mx-auto bg-white p-3 font-mono text-[12px] leading-snug text-black ${wide ? 'max-w-[148mm]' : 'max-w-[80mm]'}`}>
      <style>{`
        @page { size: ${wide ? 'A5' : '80mm auto'}; margin: 4mm; }
        @media print { .no-print { display: none !important; } body { background: #fff !important; } }
        body { background: #f3f4f6; }
      `}</style>
      <PrintControls autoPrint={query.print === '1'} id={id} wide={wide} />

      <div className="text-center">
        <p className="text-[14px] font-bold uppercase">{bill.seller.name}</p>
        {bill.seller.address && <p>{bill.seller.address}</p>}
        {bill.seller.phone && <p>Ph: {bill.seller.phone}</p>}
        {bill.seller.gstin && <p>GSTIN: {bill.seller.gstin}</p>}
        <p className="mt-1 border-y border-dashed border-black py-0.5 font-bold">
          {bill.billOfSupply ? 'BILL OF SUPPLY' : 'TAX INVOICE'} · {bill.kind === 'SERVICE' ? 'SERVICE' : 'COUNTER SALE'}
        </p>
      </div>

      <div className="mt-1">
        <p className={row}><span>Bill No: {bill.number}</span><span>{formatDate(bill.date)}</span></p>
        {bill.customer && <p>Customer: {bill.customer.name}{bill.customer.code ? ` (${bill.customer.code})` : ''}</p>}
        {bill.customer?.mobile && <p>Mobile: {bill.customer.mobile}</p>}
        {bill.vehicleNo && <p>Vehicle: {bill.vehicleNo}</p>}
      </div>

      <div className="mt-1 border-t border-dashed border-black pt-1">
        {bill.lines.map((l, i) => (
          <p key={i} className={row}><span>{l.description}</span><span>{formatINR(l.amount)}</span></p>
        ))}
      </div>

      <div className="mt-1 border-t border-dashed border-black pt-1">
        {!bill.billOfSupply && (
          <>
            <p className={row}><span>Taxable value</span><span>{formatINR(bill.taxable)}</span></p>
            {bill.cgst > 0 && <p className={row}><span>CGST</span><span>{formatINR(bill.cgst)}</span></p>}
            {bill.sgst > 0 && <p className={row}><span>SGST</span><span>{formatINR(bill.sgst)}</span></p>}
            {bill.igst > 0 && <p className={row}><span>IGST</span><span>{formatINR(bill.igst)}</span></p>}
          </>
        )}
        <p className={`${row} text-[14px] font-bold`}><span>TOTAL</span><span>{formatINR(bill.total)}</span></p>
      </div>

      <div className="mt-1 border-t border-dashed border-black pt-1">
        {bill.receipts.length === 0 ? <p>Not paid yet.</p> : bill.receipts.map((r) => (
          <p key={r.number} className={row}>
            <span>Rcpt {r.number} · {r.mode}{r.reference ? ` · ${r.reference}` : ''}</span><span>{formatINR(r.amount)}</span>
          </p>
        ))}
        <p className={`${row} font-bold`}><span>Received</span><span>{formatINR(bill.paid)}</span></p>
        {bill.balance > 0 && <p className={`${row} font-bold`}><span>Balance due</span><span>{formatINR(bill.balance)}</span></p>}
      </div>

      <p className="mt-2 text-center">Thank you. Visit again.</p>
    </main>
  );
}
