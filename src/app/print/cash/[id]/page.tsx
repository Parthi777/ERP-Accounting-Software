import type { Metadata } from 'next';
import { notFound, redirect } from 'next/navigation';

import { getTenantContext } from '@/server/auth/tenant-context';
import { getPrintableCashEntry } from '@/server/services/cash/cash-service';
import { PrintControls } from '@/components/billing/print-controls';
import { formatINR } from '@/lib/money';
import { formatDate } from '@/lib/format';
import { amountInWords } from '@/lib/words';

export const metadata: Metadata = { title: 'Cash receipt' };
export const dynamic = 'force-dynamic';

/** A cash-book receipt (money in) or payment voucher (money out), for the printer. */
export default async function PrintCashPage({
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
  const entry = await getPrintableCashEntry(id);
  if (!entry) notFound();

  const wide = query.size === 'a5';
  const receipt = entry.direction === 'RECEIPT';

  return (
    <main className={`mx-auto bg-white p-3 font-mono text-[12px] leading-snug text-black ${wide ? 'max-w-[148mm]' : 'max-w-[80mm]'}`}>
      <style>{`
        @page { size: ${wide ? 'A5' : '80mm auto'}; margin: 4mm; }
        @media print { .no-print { display: none !important; } body { background: #fff !important; } }
        body { background: #f3f4f6; }
      `}</style>
      <PrintControls autoPrint={query.print === '1'} id={id} wide={wide} base="/print/cash" />

      <div className="text-center">
        <p className="text-[14px] font-bold uppercase">{entry.seller.name}</p>
        {entry.seller.address && <p>{entry.seller.address}</p>}
        {entry.seller.phone && <p>Ph: {entry.seller.phone}</p>}
        {entry.seller.gstin && <p>GSTIN: {entry.seller.gstin}</p>}
        <p className="mt-1 border-y border-dashed border-black py-0.5 font-bold">
          {receipt ? 'CASH RECEIPT' : 'CASH PAYMENT VOUCHER'}
        </p>
      </div>

      <div className="mt-1 space-y-0.5">
        <p className="flex justify-between"><span>No: {entry.number}</span><span>{formatDate(entry.date)}</span></p>
        {entry.party && <p>{receipt ? 'Received from' : 'Paid to'}: {entry.party}</p>}
        {entry.mobile && <p>Mobile: {entry.mobile}</p>}
        <p>Towards: {entry.particular}</p>
      </div>

      <div className="mt-1 border-y border-dashed border-black py-1">
        <p className="flex justify-between text-[14px] font-bold"><span>AMOUNT</span><span>{formatINR(entry.amount)}</span></p>
        <p className="text-[11px]">{amountInWords(entry.amount)}</p>
      </div>

      <div className="mt-6 flex justify-between text-[11px]">
        <span>{receipt ? 'Customer' : 'Receiver'}</span><span>Cashier</span>
      </div>
    </main>
  );
}
