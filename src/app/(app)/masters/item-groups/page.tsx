import type { Metadata } from 'next';

import { listItemGroups, type ItemGroupRow } from '@/server/services/masters/item-structure-service';
import { addItemGroupAction } from '@/server/services/masters/item-structure-actions';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel, PanelContent, PanelHeader, PanelTitle } from '@/components/ui/panel';
import { ActionForm } from '@/components/forms/action-form';

export const metadata: Metadata = { title: 'Item Groups' };
export const dynamic = 'force-dynamic';

const columns: Column<ItemGroupRow>[] = [
  { key: 'name', header: 'Group', render: (g) => <span className="text-ink-800">{g.name}</span> },
  { key: 'parent', header: 'Under', render: (g) => g.parentName ?? <span className="text-ink-400">—</span> },
  { key: 'items', header: 'Items', numeric: true, render: (g) => g.items || '—' },
];

/** Item groups (F14): accessories and spares grouped for lists, stock and reports. */
export default async function ItemGroupsPage() {
  const context = await requirePermission('inventory.view');
  const groups = await listItemGroups();
  return (
    <div className="space-y-4">
      <PageHeader title="Item Groups" count={groups.length}
        description="Groups for accessories and spares. A group can sit under another. Choose an item's group on the item itself." />
      {hasPermission(context, 'inventory.items.manage') && (
        <Panel>
          <PanelHeader><PanelTitle>Add a group</PanelTitle></PanelHeader>
          <PanelContent>
            <ActionForm action={addItemGroupAction} submitLabel="Add group" columns={2}
              fields={[
                { name: 'name', label: 'Name', required: true, placeholder: 'Lighting' },
                { name: 'parentId', label: 'Under group', type: 'select', options: groups.map((g) => ({ value: g.id, label: g.name })) },
              ]} />
          </PanelContent>
        </Panel>
      )}
      <DataTable columns={columns} rows={groups} getRowKey={(g) => g.id} caption="Item groups" emptyMessage="No item groups yet." />
    </div>
  );
}
