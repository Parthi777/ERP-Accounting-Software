import type { Metadata } from 'next';
import { redirect } from 'next/navigation';
import { AlertTriangle, CheckCircle2, Database, Terminal } from 'lucide-react';

import { isSupabaseConfigured, missingPublicEnv } from '@/config/env';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';

export const metadata: Metadata = { title: 'Setup' };

/**
 * Shown when Supabase is not configured.
 *
 * The alternative — throwing on import — turns a missing environment variable
 * into an opaque stack trace on every route. This states exactly what is missing
 * and what to do about it.
 */
export default function SetupPage() {
  if (isSupabaseConfigured) {
    redirect('/dashboard');
  }

  return (
    <div className="mx-auto flex min-h-dvh max-w-3xl flex-col justify-center px-4 py-12">
      <div className="mb-8">
        <div className="mb-4 inline-flex items-center gap-2 rounded-full border border-warning-200 bg-warning-50 px-3 py-1 text-xs font-medium text-warning-700">
          <AlertTriangle className="size-3.5" aria-hidden />
          Not configured
        </div>
        <h1 className="text-2xl font-bold tracking-tight text-ink-900">Connect TW ERP to Supabase</h1>
        <p className="mt-2 text-sm text-ink-600">
          The application is running, but it has no database yet. Complete the three steps below and
          reload.
        </p>
      </div>

      {missingPublicEnv.length > 0 && (
        <Panel className="mb-6 p-5">
          <h2 className="mb-3 text-sm font-semibold text-ink-900">Missing or invalid variables</h2>
          <ul className="space-y-1.5">
            {missingPublicEnv.map((name) => (
              <li key={name} className="flex items-center gap-2 text-sm">
                <span className="size-1.5 rounded-full bg-danger-500" aria-hidden />
                <code className="font-mono text-[13px] text-danger-700">{name}</code>
              </li>
            ))}
          </ul>
        </Panel>
      )}

      <ol className="space-y-4">
        <Step
          number={1}
          icon={Database}
          title="Create a Supabase project"
          body={
            <>
              Sign in at <code className="rounded bg-ink-100 px-1 py-0.5 text-xs">supabase.com</code>{' '}
              and create a project. From <strong>Project Settings → API</strong>, copy the project
              URL, the <code className="rounded bg-ink-100 px-1 py-0.5 text-xs">anon</code> key, and
              the <code className="rounded bg-ink-100 px-1 py-0.5 text-xs">service_role</code> key.
            </>
          }
        />

        <Step
          number={2}
          icon={Terminal}
          title="Apply the migrations"
          body={
            <>
              Run every file in{' '}
              <code className="rounded bg-ink-100 px-1 py-0.5 text-xs">supabase/migrations/</code> in
              numerical order through the SQL editor, then{' '}
              <code className="rounded bg-ink-100 px-1 py-0.5 text-xs">supabase/seed.sql</code> for
              the permission catalogue and system roles. Add{' '}
              <code className="rounded bg-ink-100 px-1 py-0.5 text-xs">seed-demo-ledger.sql</code>{' '}
              only if you want demo figures on the dashboard.
              <span className="mt-2 block text-xs text-ink-500">
                See <code className="text-[11px]">docs/deployment-railway.md</code> for the full
                order and the Supabase CLI alternative.
              </span>
            </>
          }
        />

        <Step
          number={3}
          icon={CheckCircle2}
          title="Set the environment variables"
          body={
            <>
              Copy <code className="rounded bg-ink-100 px-1 py-0.5 text-xs">.env.example</code> to{' '}
              <code className="rounded bg-ink-100 px-1 py-0.5 text-xs">.env.local</code> and fill in
              the values from step 1. On Railway, add the same variables under{' '}
              <strong>Variables</strong> and redeploy.
              <span className="mt-2 block text-xs text-ink-500">
                Keep <code className="text-[11px]">SUPABASE_SERVICE_ROLE_KEY</code> server-side. It
                bypasses row level security and must never be prefixed with{' '}
                <code className="text-[11px]">NEXT_PUBLIC_</code>.
              </span>
            </>
          }
        />
      </ol>

      <Panel className="mt-8 p-5">
        <div className="flex items-start gap-3">
          <Badge variant="info">Note</Badge>
          <p className="text-sm text-ink-600">
            Until this is done, every route redirects here. Only{' '}
            <code className="rounded bg-ink-100 px-1 py-0.5 text-xs">/api/health</code> stays
            reachable, so a Railway health check still passes during a first deploy.
          </p>
        </div>
      </Panel>
    </div>
  );
}

function Step({
  number,
  icon: Icon,
  title,
  body,
}: {
  readonly number: number;
  readonly icon: React.ComponentType<{ className?: string }>;
  readonly title: string;
  readonly body: React.ReactNode;
}) {
  return (
    <li>
      <Panel className="flex gap-4 p-5">
        <div className="flex size-10 shrink-0 items-center justify-center rounded-xl bg-brand-50 text-brand-600">
          <Icon className="size-5" />
        </div>
        <div className="min-w-0">
          <h2 className="text-sm font-semibold text-ink-900">
            <span className="mr-2 text-ink-400">{number}.</span>
            {title}
          </h2>
          <div className="mt-1.5 text-sm leading-relaxed text-ink-600">{body}</div>
        </div>
      </Panel>
    </li>
  );
}
