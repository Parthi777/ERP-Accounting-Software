import { Button } from '@/components/ui/button';
import { Panel } from '@/components/ui/panel';

/** GSTIN and month, as a plain GET form: the page is the state. */
export function ReturnPeriodPicker({
  gstins,
  gstin,
  month,
}: {
  readonly gstins: readonly string[];
  readonly gstin: string;
  readonly month: string;
}) {
  return (
    <Panel className="p-4">
      <form method="get" className="flex flex-wrap items-end gap-3">
        <div>
          <label htmlFor="gstin" className="mb-1.5 block text-xs font-medium text-ink-600">GSTIN</label>
          <select id="gstin" name="gstin" defaultValue={gstin} className="h-9 field px-3 font-mono text-sm">
            {gstins.map((g) => <option key={g} value={g}>{g}</option>)}
          </select>
        </div>
        <div>
          <label htmlFor="period" className="mb-1.5 block text-xs font-medium text-ink-600">Month</label>
          <input id="period" name="period" type="month" defaultValue={month} className="h-9 field px-3 text-sm" />
        </div>
        <Button type="submit" variant="secondary" size="sm">Show</Button>
      </form>
    </Panel>
  );
}

/** `?period=2026-09` → first of the month; defaults to the current month. */
export function resolveReturnPeriod(value: string | undefined): { month: string; period: string } {
  const month = /^\d{4}-\d{2}$/.test(value ?? '') ? value! : new Date().toISOString().slice(0, 7);
  return { month, period: `${month}-01` };
}
