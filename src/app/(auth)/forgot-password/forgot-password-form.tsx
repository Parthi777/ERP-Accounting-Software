'use client';

import * as React from 'react';
import { useForm } from 'react-hook-form';
import { Loader2 } from 'lucide-react';

import { getSupabaseBrowserClient } from '@/lib/supabase/client';
import { publicEnv } from '@/config/env';
import { Button } from '@/components/ui/button';
import { FieldError, Input, Label } from '@/components/ui/input';
import { forgotPasswordSchema, type ForgotPasswordInput } from '@/lib/validation/auth';

export function ForgotPasswordForm() {
  const [sent, setSent] = React.useState(false);
  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<ForgotPasswordInput>({ defaultValues: { email: '' } });

  const onSubmit = handleSubmit(async (values) => {
    const parsed = forgotPasswordSchema.safeParse(values);
    if (!parsed.success) {
      return;
    }

    const supabase = getSupabaseBrowserClient();
    await supabase.auth.resetPasswordForEmail(parsed.data.email, {
      redirectTo: `${publicEnv.appUrl}/reset-password`,
    });

    // Always report success. Revealing whether an address is registered would
    // turn this form into an account-enumeration tool.
    setSent(true);
  });

  if (sent) {
    return (
      <div className="rounded-lg border border-positive-200 bg-positive-50 px-4 py-3 text-sm text-positive-700">
        If that address belongs to an account, a reset link is on its way. Check your inbox.
      </div>
    );
  }

  return (
    <form onSubmit={onSubmit} className="space-y-4" noValidate>
      <div className="space-y-1.5">
        <Label htmlFor="email">Email</Label>
        <Input
          id="email"
          type="email"
          autoComplete="username"
          autoFocus
          placeholder="you@dealer.example"
          aria-invalid={Boolean(errors.email)}
          {...register('email', { required: 'Email is required.' })}
        />
        <FieldError>{errors.email?.message}</FieldError>
      </div>

      <Button type="submit" size="lg" className="w-full" disabled={isSubmitting}>
        {isSubmitting && <Loader2 className="animate-spin" aria-hidden />}
        Send reset link
      </Button>
    </form>
  );
}
