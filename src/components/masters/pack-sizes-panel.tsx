import { listPackSizes } from '@/server/services/masters/item-structure-service';
import { addPackSizeAction, removePackSizeAction } from '@/server/services/masters/item-structure-actions';
import { Panel, PanelContent, PanelHeader, PanelTitle } from '@/components/ui/panel';
import { ActionForm } from '@/components/forms/action-form';

/** An item's pack sizes (F18): "1 BOX = 12 NOS", used when ordering in packs. */
export async function PackSizesPanel({
  itemId,
  units,
}: {
  readonly itemId: string;
  readonly units: readonly { code: string; label: string }[];
}) {
  const { base, packs } = await listPackSizes(itemId);
  return (
    <Panel className="mt-4">
      <PanelHeader><PanelTitle>Pack sizes</PanelTitle></PanelHeader>
      <PanelContent>
        <p className="mb-3 text-xs text-ink-500">
          Stock is kept in {base}. A pack size lets an order be placed in boxes or dozens; it is stored as {base}.
        </p>
        {packs.length > 0 && (
          <ul className="mb-4 divide-y divide-ink-100 text-sm">
            {packs.map((p) => (
              <li key={p.id} className="flex items-center justify-between py-2">
                <span>1 {p.unit} = {p.factor} {base}</span>
                <div className="w-28">
                  <ActionForm fields={[]} fixed={{ id: p.id }} action={removePackSizeAction} submitLabel="Remove" columns={1} />
                </div>
              </li>
            ))}
          </ul>
        )}
        <ActionForm action={addPackSizeAction} submitLabel="Add pack size" columns={3} fixed={{ itemId }}
          fields={[
            { name: 'unit', label: 'Pack', type: 'select', required: true,
              options: units.filter((u) => u.code !== base).map((u) => ({ value: u.code, label: u.label })) },
            { name: 'factor', label: `${base} in one pack`, type: 'number', required: true, step: '0.0001' },
          ]} />
      </PanelContent>
    </Panel>
  );
}
