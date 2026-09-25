import Link from 'next/link';
import { Printer } from 'lucide-react';

import { SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { formatINR } from '@/lib/money';
import { formatDate } from '@/lib/format';
import type { BillRow } from '@/server/services/billing/quick-bill-service';

/** Recent bills, each one printable again. */
export function BillsTable({ rows, showVehicle }: { readonly rows: readonly BillRow[]; readonly showVehicle: boolean }) {
  const th = 'px-3 py-2.5 text-[11px] font-semibold uppercase tracking-wide text-ink-500';
  return (
    <SolidPanel className="overflow-hidden">
      <div className="table-sticky overflow-auto" style={{ maxHeight: '36rem' }}>
        <table className="w-full border-collapse text-sm">
          <thead><tr>
            <th className={`${th} text-left`}>Bill</th><th className={`${th} text-left`}>Customer</th>
            {showVehicle && <th className={`${th} text-left`}>Vehicle</th>}
            <th className={`${th} text-right`}>Total</th><th className={`${th} text-right`}>Received</th>
            <th className={`${th} text-right`}>Balance</th><th className={th} />
          </tr></thead>
          <tbody>
            {rows.length === 0 ? (
              <tr><td colSpan={showVehicle ? 7 : 6} className="px-3 py-10 text-center text-ink-400">No bills yet.</td></tr>
            ) : rows.map((b) => (
              <tr key={b.id} className="border-t border-ink-100">
                <td className="px-3 py-2">
                  <span className="font-mono text-xs font-semibold">{b.number}</span>
                  {b.status !== 'POSTED' && <Badge className="ml-2" variant="warning">{b.status}</Badge>}
                  <span className="block text-[11px] text-ink-400">{formatDate(b.date)}</span>
                </td>
                <td className="px-3 py-2">{b.customerName ?? '—'}<span className="block text-[11px] text-ink-400">{b.mobile ?? ''}</span></td>
                {showVehicle && <td className="px-3 py-2 font-mono text-xs">{b.vehicleNo ?? '—'}</td>}
                <td className="numeric px-3 py-2 font-medium">{formatINR(b.total)}</td>
                <td className="numeric px-3 py-2">{formatINR(b.paid)}</td>
                <td className={`numeric px-3 py-2 ${b.balance > 0 ? 'text-warning-700' : 'text-ink-400'}`}>{formatINR(b.balance)}</td>
                <td className="px-3 py-2 text-right">
                  <Link href={`/print/bill/${b.id}`} target="_blank" className="inline-flex items-center gap-1 text-xs text-brand-700 hover:underline">
                    <Printer className="size-3.5" aria-hidden />Print
                  </Link>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </SolidPanel>
  );
}
