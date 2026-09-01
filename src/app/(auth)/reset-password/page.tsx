import type { Metadata } from 'next';

import { Panel } from '@/components/ui/panel';
import { ResetPasswordForm } from '@/app/(auth)/reset-password/reset-password-form';

export const metadata: Metadata = { title: 'Choose a new password' };

export default function ResetPasswordPage() {
  return (
    <Panel strong className="p-6">
      <div className="mb-6">
        <h1 className="text-lg font-semibold text-ink-900">Choose a new password</h1>
        <p className="mt-1 text-sm text-ink-500">
          At least 12 characters, with upper case, lower case and a number.
        </p>
      </div>

      <ResetPasswordForm />
    </Panel>
  );
}
