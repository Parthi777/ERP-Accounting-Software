'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, Lock, Pencil, Plus, Shield, Trash2 } from 'lucide-react';

import type { PermissionOption } from '@/server/services/org/admin-service';
import {
  deleteRoleAction,
  getRoleDetailAction,
  saveRoleAction,
} from '@/server/services/org/admin-actions';
import { Panel, SolidPanel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Input, Label } from '@/components/ui/input';

/**
 * Roles and what they may do — spec §6, §47.
 *
 * Two rules the screen has to make obvious, because both are invisible in the
 * data and expensive to learn by accident:
 *
 *   A system role is shared by every dealer on the platform. Editing one would
 *   change what a Cashier can do at every other dealership, so they are locked
 *   here and a dealer makes their own role instead.
 *
 *   Nine permissions expose cost, margin, profit or a colleague's pay. They are
 *   marked, and counted on the row, because "this role can see margin" is the
 *   thing someone should notice before they assign it — not afterwards.
 */
export interface RoleSummary {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly description: string | null;
  readonly is_system: boolean;
  readonly permissionCount: number;
  readonly sensitiveCount: number;
}

export function RoleManager({
  roles,
  catalogue,
  canManage,
}: {
  readonly roles: readonly RoleSummary[];
  readonly catalogue: readonly PermissionOption[];
  readonly canManage: boolean;
}) {
  const router = useRouter();
  const [editing, setEditing] = React.useState<RoleSummary | 'new' | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);
  const [error, setError] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  const remove = (role: RoleSummary) => {
    setNotice(null);
    setError(null);
    startTransition(async () => {
      const result = await deleteRoleAction(role.id);
      if (result.ok) setNotice(result.message ?? 'Deleted.');
      else setError(result.error ?? 'The role could not be deleted.');
      router.refresh();
    });
  };

  return (
    <div className="space-y-4">
      {notice && (
        <div role="status" className="rounded-lg border border-positive-200 bg-positive-50 px-3 py-2 text-sm text-positive-700">
          {notice}
        </div>
      )}
      {error && (
        <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
          {error}
        </div>
      )}

      {canManage && (
        <div className="flex justify-end">
          <Button onClick={() => setEditing('new')}>
            <Plus aria-hidden />
            New role
          </Button>
        </div>
      )}

      <SolidPanel className="overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full border-collapse text-sm">
            <caption className="sr-only">Roles</caption>
            <thead>
              <tr className="bg-ink-50">
                <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Role</th>
                <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Scope</th>
                <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Permissions</th>
                <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Restricted</th>
                {canManage && <th scope="col" className="px-4 py-2.5" />}
              </tr>
            </thead>
            <tbody>
              {roles.map((role) => (
                <tr key={role.id} className="border-t border-ink-100">
                  <td className="px-4 py-2">
                    <span className="block font-medium text-ink-800">{role.name}</span>
                    <span className="block font-mono text-[11px] text-ink-400">{role.code}</span>
                  </td>
                  <td className="px-4 py-2">
                    {role.is_system ? (
                      <span className="flex items-center gap-1.5 text-xs text-ink-500">
                        <Lock className="size-3.5" aria-hidden />
                        Platform-wide
                      </span>
                    ) : (
                      <span className="text-xs text-ink-600">This dealer</span>
                    )}
                  </td>
                  <td className="numeric px-4 py-2 text-right">{role.permissionCount}</td>
                  <td className="numeric px-4 py-2 text-right">
                    {role.sensitiveCount > 0 ? (
                      <Badge variant="warning">{role.sensitiveCount}</Badge>
                    ) : (
                      <span className="text-ink-300">—</span>
                    )}
                  </td>
                  {canManage && (
                    <td className="px-4 py-2">
                      <span className="flex justify-end gap-1">
                        <Button variant="ghost" size="sm" onClick={() => setEditing(role)}
                          title={role.is_system ? 'View permissions' : 'Edit'}>
                          <Pencil aria-hidden />
                        </Button>
                        {!role.is_system && (
                          <Button variant="ghost" size="sm" disabled={pending}
                            onClick={() => remove(role)} title="Delete">
                            <Trash2 aria-hidden className="text-danger-600" />
                          </Button>
                        )}
                      </span>
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </SolidPanel>

      <Panel className="p-4">
        <p className="flex items-start gap-2 text-xs text-ink-600">
          <Shield className="mt-0.5 size-4 shrink-0 text-ink-400" aria-hidden />
          <span>
            The seven <span className="font-medium">platform-wide</span> roles are shared by every
            dealer and cannot be changed here — editing one would alter what a Cashier can do at
            every other dealership. Create your own role to grant a different set.
            <span className="mt-1 block">
              The <span className="font-medium">Restricted</span> column counts permissions that
              expose purchase cost, margin, profit or a colleague&rsquo;s salary.
            </span>
          </span>
        </p>
      </Panel>

      {editing && (
        <RoleDialog
          key={editing === 'new' ? 'new' : editing.id}
          role={editing === 'new' ? null : editing}
          catalogue={catalogue}
          onCancel={() => setEditing(null)}
          onSaved={(message) => {
            setEditing(null);
            setNotice(message);
            router.refresh();
          }}
        />
      )}
    </div>
  );
}

function RoleDialog({
  role,
  catalogue,
  onCancel,
  onSaved,
}: {
  readonly role: RoleSummary | null;
  readonly catalogue: readonly PermissionOption[];
  readonly onCancel: () => void;
  readonly onSaved: (message: string) => void;
}) {
  const [pending, startTransition] = React.useTransition();
  const [loading, setLoading] = React.useState(role !== null);
  const [error, setError] = React.useState<string | null>(null);
  const [code, setCode] = React.useState(role?.code ?? '');
  const [name, setName] = React.useState(role?.name ?? '');
  const [description, setDescription] = React.useState(role?.description ?? '');
  const [selected, setSelected] = React.useState<Set<string>>(new Set());

  const locked = role?.is_system ?? false;

  // An existing role's grants are fetched rather than passed down: the list page
  // carries counts, and a count is not a set.
  React.useEffect(() => {
    let live = true;
    if (!role) return;
    void getRoleDetailAction(role.id).then((detail) => {
      if (!live) return;
      setSelected(new Set(detail?.permissions ?? []));
      setLoading(false);
    });
    return () => { live = false; };
  }, [role]);

  const modules = React.useMemo(() => {
    const grouped = new Map<string, PermissionOption[]>();
    for (const permission of catalogue) {
      const list = grouped.get(permission.module) ?? [];
      list.push(permission);
      grouped.set(permission.module, list);
    }
    return [...grouped.entries()].sort(([a], [b]) => a.localeCompare(b));
  }, [catalogue]);

  const toggle = (permissionCode: string) =>
    setSelected((current) => {
      const next = new Set(current);
      if (next.has(permissionCode)) next.delete(permissionCode);
      else next.add(permissionCode);
      return next;
    });

  const toggleModule = (permissions: PermissionOption[]) =>
    setSelected((current) => {
      const next = new Set(current);
      const allOn = permissions.every((p) => next.has(p.code));
      for (const p of permissions) {
        if (allOn) next.delete(p.code);
        else next.add(p.code);
      }
      return next;
    });

  const sensitiveChosen = [...selected].filter(
    (c) => catalogue.find((p) => p.code === c)?.sensitive,
  ).length;

  const submit = () => {
    setError(null);
    if (!code.trim() || !name.trim()) return setError('A role needs a code and a name.');
    if (selected.size === 0) return setError('Choose at least one permission.');

    startTransition(async () => {
      const result = await saveRoleAction({
        id: role?.id ?? null,
        code,
        name,
        description,
        permissions: [...selected],
      });
      if (!result.ok) {
        setError(result.error ?? 'The role could not be saved.');
        return;
      }
      onSaved(result.message ?? 'Saved.');
    });
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
      role="dialog" aria-modal="true" onClick={onCancel}>
      <div className="glass-strong flex max-h-[90vh] w-full max-w-3xl flex-col rounded-2xl p-6"
        onClick={(e) => e.stopPropagation()}>
        <h2 className="text-sm font-semibold text-ink-900">
          {role ? (locked ? `${role.name} — platform-wide role` : `Edit ${role.name}`) : 'New role'}
        </h2>
        {locked && (
          <p className="mt-1 text-sm text-ink-600">
            Shared by every dealer on the platform, so it is shown here read-only. Create your own
            role to grant a different set.
          </p>
        )}

        {error && (
          <div role="alert" className="mt-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
            {error}
          </div>
        )}

        <div className="mt-4 grid gap-3 sm:grid-cols-3">
          <div>
            <Label htmlFor="role-code" className="mb-1.5 block">Code</Label>
            <Input id="role-code" value={code} disabled={role !== null}
              onChange={(e) => setCode(e.target.value)} placeholder="WORKSHOP_MANAGER" />
          </div>
          <div className="sm:col-span-2">
            <Label htmlFor="role-name" className="mb-1.5 block">Name</Label>
            <Input id="role-name" value={name} disabled={locked}
              onChange={(e) => setName(e.target.value)} placeholder="Workshop Manager" />
          </div>
          <div className="sm:col-span-3">
            <Label htmlFor="role-desc" className="mb-1.5 block">Description</Label>
            <Input id="role-desc" value={description} disabled={locked}
              onChange={(e) => setDescription(e.target.value)} />
          </div>
        </div>

        <div className="mt-4 flex flex-wrap items-center justify-between gap-2 border-b border-ink-200 pb-2">
          <h3 className="text-[11px] font-semibold uppercase tracking-wide text-ink-500">
            Permissions
          </h3>
          <span className="flex items-center gap-2 text-xs text-ink-500">
            <span>{selected.size} selected</span>
            {sensitiveChosen > 0 && <Badge variant="warning">{sensitiveChosen} restricted</Badge>}
          </span>
        </div>

        <div className="mt-3 min-h-0 flex-1 overflow-y-auto pr-1">
          {loading ? (
            <p className="py-8 text-center text-sm text-ink-400">
              <Loader2 className="mr-2 inline animate-spin" aria-hidden />
              Loading permissions…
            </p>
          ) : (
            modules.map(([module, permissions]) => {
              const on = permissions.filter((p) => selected.has(p.code)).length;
              return (
                <div key={module} className="mb-4">
                  <div className="mb-1.5 flex items-center justify-between gap-2">
                    <h4 className="text-xs font-semibold capitalize text-ink-700">
                      {module.replace(/_/g, ' ')}
                      <span className="ml-2 font-normal text-ink-400">{on}/{permissions.length}</span>
                    </h4>
                    {!locked && (
                      <Button type="button" variant="ghost" size="sm"
                        onClick={() => toggleModule(permissions)}>
                        {on === permissions.length ? 'None' : 'All'}
                      </Button>
                    )}
                  </div>
                  <div className="grid gap-1 sm:grid-cols-2">
                    {permissions.map((permission) => (
                      <label key={permission.code}
                        className="flex items-start gap-2 rounded px-1.5 py-1 text-xs hover:bg-brand-50/60">
                        <input type="checkbox" className="mt-0.5" disabled={locked}
                          checked={selected.has(permission.code)}
                          onChange={() => toggle(permission.code)} />
                        <span className="min-w-0">
                          <span className="block text-ink-700">
                            {permission.description}
                            {permission.sensitive && (
                              <span className="ml-1.5 rounded bg-warning-50 px-1 text-[10px] font-medium text-warning-700">
                                restricted
                              </span>
                            )}
                          </span>
                          <span className="block font-mono text-[10px] text-ink-400">{permission.code}</span>
                        </span>
                      </label>
                    ))}
                  </div>
                </div>
              );
            })
          )}
        </div>

        <div className="mt-4 flex justify-end gap-2 border-t border-ink-200 pt-4">
          <Button variant="secondary" size="sm" onClick={onCancel} disabled={pending}>
            {locked ? 'Close' : 'Cancel'}
          </Button>
          {!locked && (
            <Button size="sm" onClick={submit} disabled={pending || loading}>
              {pending && <Loader2 className="animate-spin" aria-hidden />}
              Save role
            </Button>
          )}
        </div>
      </div>
    </div>
  );
}
