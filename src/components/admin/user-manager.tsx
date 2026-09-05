'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { KeyRound, Loader2, Pencil, Plus, ShieldCheck } from 'lucide-react';

import {
  createUserAction,
  getUserDetailAction,
  resetUserPasswordAction,
  updateUserAction,
} from '@/server/services/org/admin-actions';
import { SolidPanel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Input, Label } from '@/components/ui/input';
import { formatDateTime, formatMobile } from '@/lib/format';

/**
 * Logins, their roles, and the branches they reach — spec §5, §6, §47.
 *
 * The credential choice is the part worth getting right. A dealership has staff
 * with working email and staff without — a counter hand or a workshop mechanic
 * often has neither an address nor the habit of checking one. So the
 * administrator picks per person: send an invite, or set a password and hand it
 * over. Forcing invites alone would mean half the staff never get in.
 */
export interface UserSummary {
  readonly id: string;
  readonly full_name: string;
  readonly email: string;
  readonly mobile: string | null;
  readonly status: string;
  readonly has_all_branch_access: boolean;
  readonly is_platform_admin: boolean;
  readonly last_login_at: string | null;
  readonly roles: readonly string[];
}

export interface RoleOption {
  readonly id: string;
  readonly name: string;
  readonly isSystem: boolean;
}

export interface BranchOption {
  readonly id: string;
  readonly code: string;
  readonly name: string;
}

export function UserManager({
  users,
  roles,
  branches,
  canManage,
  currentUserId,
}: {
  readonly users: readonly UserSummary[];
  readonly roles: readonly RoleOption[];
  readonly branches: readonly BranchOption[];
  readonly canManage: boolean;
  readonly currentUserId: string;
}) {
  const router = useRouter();
  const [editing, setEditing] = React.useState<UserSummary | 'new' | null>(null);
  const [resetting, setResetting] = React.useState<UserSummary | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);
  const [error, setError] = React.useState<string | null>(null);

  const TONE: Record<string, 'positive' | 'warning' | 'neutral'> = {
    ACTIVE: 'positive',
    SUSPENDED: 'warning',
    DISABLED: 'neutral',
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
            New user
          </Button>
        </div>
      )}

      <SolidPanel className="overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full border-collapse text-sm">
            <caption className="sr-only">Users</caption>
            <thead>
              <tr className="bg-ink-50">
                <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">User</th>
                <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Roles</th>
                <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Branches</th>
                <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Last signed in</th>
                <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Status</th>
                {canManage && <th scope="col" className="px-4 py-2.5" />}
              </tr>
            </thead>
            <tbody>
              {users.map((user) => (
                <tr key={user.id} className="border-t border-ink-100">
                  <td className="px-4 py-2">
                    <span className="flex flex-wrap items-center gap-2">
                      <span className="font-medium text-ink-800">{user.full_name}</span>
                      {user.is_platform_admin && (
                        <Badge variant="accent">
                          <ShieldCheck aria-hidden className="size-3" />
                          Platform
                        </Badge>
                      )}
                      {user.id === currentUserId && <Badge variant="info">You</Badge>}
                    </span>
                    <span className="block text-[11px] text-ink-400">
                      {user.email}{user.mobile ? ` · ${formatMobile(user.mobile)}` : ''}
                    </span>
                  </td>
                  <td className="px-4 py-2 text-xs text-ink-600">
                    {user.roles.length > 0 ? user.roles.join(', ') : <span className="text-danger-600">No role</span>}
                  </td>
                  <td className="px-4 py-2 text-xs text-ink-600">
                    {user.has_all_branch_access ? 'All branches' : 'Selected branches'}
                  </td>
                  <td className="px-4 py-2 text-xs text-ink-500">
                    {user.last_login_at ? formatDateTime(user.last_login_at) : <span className="text-ink-300">Never</span>}
                  </td>
                  <td className="px-4 py-2">
                    <Badge variant={TONE[user.status] ?? 'neutral'}>{user.status}</Badge>
                  </td>
                  {canManage && (
                    <td className="px-4 py-2">
                      <span className="flex justify-end gap-1">
                        <Button variant="ghost" size="sm" onClick={() => setResetting(user)}
                          title="Set a password or send a reset link">
                          <KeyRound aria-hidden />
                        </Button>
                        <Button variant="ghost" size="sm" onClick={() => setEditing(user)} title="Edit">
                          <Pencil aria-hidden />
                        </Button>
                      </span>
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </SolidPanel>

      {editing && (
        <UserDialog
          key={editing === 'new' ? 'new' : editing.id}
          user={editing === 'new' ? null : editing}
          roles={roles}
          branches={branches}
          isSelf={editing !== 'new' && editing.id === currentUserId}
          onCancel={() => setEditing(null)}
          onDone={(message, ok) => {
            setEditing(null);
            if (ok) { setNotice(message); setError(null); } else { setError(message); }
            router.refresh();
          }}
        />
      )}

      {resetting && (
        <PasswordDialog
          key={resetting.id}
          user={resetting}
          onCancel={() => setResetting(null)}
          onDone={(message, ok) => {
            setResetting(null);
            if (ok) { setNotice(message); setError(null); } else { setError(message); }
          }}
        />
      )}
    </div>
  );
}

function UserDialog({
  user,
  roles,
  branches,
  isSelf,
  onCancel,
  onDone,
}: {
  readonly user: UserSummary | null;
  readonly roles: readonly RoleOption[];
  readonly branches: readonly BranchOption[];
  readonly isSelf: boolean;
  readonly onCancel: () => void;
  readonly onDone: (message: string, ok: boolean) => void;
}) {
  const [pending, startTransition] = React.useTransition();
  const [loading, setLoading] = React.useState(user !== null);
  const [error, setError] = React.useState<string | null>(null);

  const [fullName, setFullName] = React.useState(user?.full_name ?? '');
  const [email, setEmail] = React.useState(user?.email ?? '');
  const [mobile, setMobile] = React.useState(user?.mobile ?? '');
  const [status, setStatus] = React.useState<'ACTIVE' | 'SUSPENDED' | 'DISABLED'>(
    (user?.status as 'ACTIVE') ?? 'ACTIVE',
  );
  const [allBranches, setAllBranches] = React.useState(user?.has_all_branch_access ?? false);
  const [roleIds, setRoleIds] = React.useState<Set<string>>(new Set());
  const [branchIds, setBranchIds] = React.useState<Set<string>>(new Set());
  const [mode, setMode] = React.useState<'INVITE' | 'PASSWORD'>('PASSWORD');
  const [password, setPassword] = React.useState('');

  React.useEffect(() => {
    let live = true;
    if (!user) return;
    void getUserDetailAction(user.id).then((detail) => {
      if (!live || !detail) return;
      setRoleIds(new Set(detail.roleIds));
      setBranchIds(new Set(detail.branchIds));
      setLoading(false);
    });
    return () => { live = false; };
  }, [user]);

  const toggle = (set: Set<string>, id: string, apply: (s: Set<string>) => void) => {
    const next = new Set(set);
    if (next.has(id)) next.delete(id); else next.add(id);
    apply(next);
  };

  const submit = () => {
    setError(null);
    if (!fullName.trim()) return setError('A name is required.');
    if (roleIds.size === 0) return setError('Give them at least one role, or they can sign in and do nothing.');
    if (!allBranches && branchIds.size === 0) {
      return setError('Choose at least one branch, or give them access to all of them.');
    }

    startTransition(async () => {
      const result = user
        ? await updateUserAction({
            id: user.id, fullName, mobile,
            roleIds: [...roleIds], branchIds: [...branchIds],
            hasAllBranchAccess: allBranches, status,
          })
        : await createUserAction({
            fullName, email, mobile,
            roleIds: [...roleIds], branchIds: [...branchIds],
            hasAllBranchAccess: allBranches,
            credentialMode: mode,
            password: mode === 'PASSWORD' ? password : null,
          });

      if (!result.ok) {
        setError(result.error ?? 'That could not be saved.');
        return;
      }
      onDone(result.message ?? 'Saved.', true);
    });
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
      role="dialog" aria-modal="true" onClick={onCancel}>
      <div className="glass-strong flex max-h-[90vh] w-full max-w-2xl flex-col overflow-y-auto rounded-2xl p-6"
        onClick={(e) => e.stopPropagation()}>
        <h2 className="text-sm font-semibold text-ink-900">
          {user ? `Edit ${user.full_name}` : 'New user'}
        </h2>

        {error && (
          <div role="alert" className="mt-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
            {error}
          </div>
        )}

        <div className="mt-4 grid gap-3 sm:grid-cols-2">
          <div>
            <Label htmlFor="u-name" className="mb-1.5 block">Name<span className="ml-0.5 text-danger-600">*</span></Label>
            <Input id="u-name" value={fullName} onChange={(e) => setFullName(e.target.value)} />
          </div>
          <div>
            <Label htmlFor="u-email" className="mb-1.5 block">Email<span className="ml-0.5 text-danger-600">*</span></Label>
            <Input id="u-email" type="email" value={email} disabled={user !== null}
              onChange={(e) => setEmail(e.target.value)} />
            {user && <p className="mt-1 text-xs text-ink-400">The sign-in address cannot be changed here.</p>}
          </div>
          <div>
            <Label htmlFor="u-mobile" className="mb-1.5 block">Mobile</Label>
            <Input id="u-mobile" value={mobile} onChange={(e) => setMobile(e.target.value)} />
          </div>
          {user && (
            <div>
              <Label htmlFor="u-status" className="mb-1.5 block">Status</Label>
              <select id="u-status" value={status} disabled={isSelf}
                onChange={(e) => setStatus(e.target.value as 'ACTIVE')}
                className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
                <option value="ACTIVE">Active</option>
                <option value="SUSPENDED">Suspended</option>
                <option value="DISABLED">Disabled</option>
              </select>
              {isSelf && <p className="mt-1 text-xs text-ink-400">You cannot deactivate your own login.</p>}
            </div>
          )}
        </div>

        {!user && (
          <>
            <h3 className="mt-5 text-[11px] font-semibold uppercase tracking-wide text-ink-500">
              How they sign in first
            </h3>
            <div className="mt-2 space-y-2">
              <label className="flex items-start gap-2 rounded-lg border border-ink-200 p-3 text-sm">
                <input type="radio" name="mode" className="mt-1" checked={mode === 'PASSWORD'}
                  onChange={() => setMode('PASSWORD')} />
                <span>
                  <span className="block font-medium text-ink-800">Set a password now</span>
                  <span className="block text-xs text-ink-500">
                    You hand it over directly. Right for counter and workshop staff who have no
                    working email — and the only option if outbound email is not configured.
                  </span>
                </span>
              </label>
              <label className="flex items-start gap-2 rounded-lg border border-ink-200 p-3 text-sm">
                <input type="radio" name="mode" className="mt-1" checked={mode === 'INVITE'}
                  onChange={() => setMode('INVITE')} />
                <span>
                  <span className="block font-medium text-ink-800">Send an invite email</span>
                  <span className="block text-xs text-ink-500">
                    They choose their own password and nobody else ever knows it.
                  </span>
                </span>
              </label>
            </div>

            {mode === 'PASSWORD' && (
              <div className="mt-3">
                <Label htmlFor="u-pass" className="mb-1.5 block">
                  Password<span className="ml-0.5 text-danger-600">*</span>
                </Label>
                <Input id="u-pass" type="text" value={password} autoComplete="new-password"
                  onChange={(e) => setPassword(e.target.value)} placeholder="At least 8 characters" />
                <p className="mt-1 text-xs text-ink-400">
                  Shown as you type so you can read it out. Ask them to change it once signed in.
                </p>
              </div>
            )}
          </>
        )}

        <h3 className="mt-5 text-[11px] font-semibold uppercase tracking-wide text-ink-500">Roles</h3>
        {loading ? (
          <p className="mt-2 text-sm text-ink-400"><Loader2 className="mr-2 inline animate-spin" aria-hidden />Loading…</p>
        ) : (
          <div className="mt-2 grid gap-1 sm:grid-cols-2">
            {roles.map((role) => (
              <label key={role.id} className="flex items-center gap-2 rounded px-1.5 py-1 text-sm hover:bg-brand-50/60">
                <input type="checkbox" checked={roleIds.has(role.id)}
                  onChange={() => toggle(roleIds, role.id, setRoleIds)} />
                <span className="text-ink-700">{role.name}</span>
              </label>
            ))}
          </div>
        )}

        <h3 className="mt-5 text-[11px] font-semibold uppercase tracking-wide text-ink-500">Branches</h3>
        <label className="mt-2 flex items-center gap-2 text-sm text-ink-700">
          <input type="checkbox" checked={allBranches} onChange={(e) => setAllBranches(e.target.checked)} />
          Every branch, including any added later
        </label>

        {!allBranches && (
          <div className="mt-2 grid gap-1 sm:grid-cols-2">
            {branches.map((branch) => (
              <label key={branch.id} className="flex items-center gap-2 rounded px-1.5 py-1 text-sm hover:bg-brand-50/60">
                <input type="checkbox" checked={branchIds.has(branch.id)}
                  onChange={() => toggle(branchIds, branch.id, setBranchIds)} />
                <span className="text-ink-700">{branch.name}</span>
                <span className="font-mono text-[11px] text-ink-400">{branch.code}</span>
              </label>
            ))}
          </div>
        )}

        <div className="mt-5 flex justify-end gap-2 border-t border-ink-200 pt-4">
          <Button variant="secondary" size="sm" onClick={onCancel} disabled={pending}>Cancel</Button>
          <Button size="sm" onClick={submit} disabled={pending || loading}>
            {pending && <Loader2 className="animate-spin" aria-hidden />}
            {user ? 'Save changes' : 'Create user'}
          </Button>
        </div>
      </div>
    </div>
  );
}

function PasswordDialog({
  user,
  onCancel,
  onDone,
}: {
  readonly user: UserSummary;
  readonly onCancel: () => void;
  readonly onDone: (message: string, ok: boolean) => void;
}) {
  const [pending, startTransition] = React.useTransition();
  const [mode, setMode] = React.useState<'INVITE' | 'PASSWORD'>('PASSWORD');
  const [password, setPassword] = React.useState('');
  const [error, setError] = React.useState<string | null>(null);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
      role="dialog" aria-modal="true" onClick={onCancel}>
      <div className="glass-strong w-full max-w-md rounded-2xl p-6" onClick={(e) => e.stopPropagation()}>
        <h2 className="text-sm font-semibold text-ink-900">Reset the password for {user.full_name}</h2>
        <p className="mt-1 text-sm text-ink-600">{user.email}</p>

        {error && (
          <div role="alert" className="mt-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
            {error}
          </div>
        )}

        <div className="mt-4 space-y-2">
          <label className="flex items-start gap-2 rounded-lg border border-ink-200 p-3 text-sm">
            <input type="radio" name="reset" className="mt-1" checked={mode === 'PASSWORD'}
              onChange={() => setMode('PASSWORD')} />
            <span>
              <span className="block font-medium text-ink-800">Set one now</span>
              <span className="block text-xs text-ink-500">You hand it over directly.</span>
            </span>
          </label>
          <label className="flex items-start gap-2 rounded-lg border border-ink-200 p-3 text-sm">
            <input type="radio" name="reset" className="mt-1" checked={mode === 'INVITE'}
              onChange={() => setMode('INVITE')} />
            <span>
              <span className="block font-medium text-ink-800">Email them a link</span>
              <span className="block text-xs text-ink-500">They set it themselves.</span>
            </span>
          </label>
        </div>

        {mode === 'PASSWORD' && (
          <div className="mt-3">
            <Label htmlFor="r-pass" className="mb-1.5 block">New password</Label>
            <Input id="r-pass" type="text" value={password} autoComplete="new-password"
              onChange={(e) => setPassword(e.target.value)} placeholder="At least 8 characters" />
          </div>
        )}

        <div className="mt-4 flex justify-end gap-2">
          <Button variant="secondary" size="sm" onClick={onCancel} disabled={pending}>Cancel</Button>
          <Button size="sm" disabled={pending || (mode === 'PASSWORD' && password.length < 8)}
            onClick={() => startTransition(async () => {
              setError(null);
              const result = await resetUserPasswordAction(user.id, mode, password);
              if (!result.ok) { setError(result.error ?? 'That did not work.'); return; }
              onDone(result.message ?? 'Done.', true);
            })}>
            {pending && <Loader2 className="animate-spin" aria-hidden />}
            {mode === 'PASSWORD' ? 'Set password' : 'Send link'}
          </Button>
        </div>
      </div>
    </div>
  );
}
