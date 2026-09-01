import type { Metadata } from 'next';
import Link from 'next/link';

import { Panel } from '@/components/ui/panel';
import { LoginForm } from '@/app/(auth)/login/login-form';

export const metadata: Metadata = { title: 'Sign in' };

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ next?: string; message?: string }>;
}) {
  const params = await searchParams;

  return (
    <Panel strong className="p-6">
      <div className="mb-6">
        <h1 className="text-lg font-semibold text-ink-900">Sign in</h1>
        <p className="mt-1 text-sm text-ink-500">Use the credentials issued by your dealer admin.</p>
      </div>

      {params.message && (
        <div className="mb-4 rounded-lg border border-positive-200 bg-positive-50 px-3 py-2 text-sm text-positive-700">
          {params.message}
        </div>
      )}

      <LoginForm nextPath={params.next ?? '/dashboard'} />

      <p className="mt-4 text-center text-sm text-ink-500">
        <Link href="/forgot-password" className="text-brand-600 hover:underline">
          Forgot your password?
        </Link>
      </p>
    </Panel>
  );
}
