import type { Metadata } from 'next';
import Link from 'next/link';

import { Panel } from '@/components/ui/panel';
import { ForgotPasswordForm } from '@/app/(auth)/forgot-password/forgot-password-form';

export const metadata: Metadata = { title: 'Reset password' };

export default function ForgotPasswordPage() {
  return (
    <Panel strong className="p-6">
      <div className="mb-6">
        <h1 className="text-lg font-semibold text-ink-900">Reset your password</h1>
        <p className="mt-1 text-sm text-ink-500">
          We will email you a link to choose a new password.
        </p>
      </div>

      <ForgotPasswordForm />

      <p className="mt-4 text-center text-sm text-ink-500">
        <Link href="/login" className="text-brand-600 hover:underline">
          Back to sign in
        </Link>
      </p>
    </Panel>
  );
}
