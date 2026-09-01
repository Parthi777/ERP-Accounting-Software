'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { Loader2 } from 'lucide-react';

import { getSupabaseBrowserClient } from '@/lib/supabase/client';
import { Button } from '@/components/ui/button';
import { FieldError, Input, Label } from '@/components/ui/input';
import { loginSchema, type LoginInput } from '@/lib/validation/auth';

/**
 * Sign-in form.
 *
 * Supabase Auth issues the session cookie; the middleware then refreshes it on
 * every request. Failures are reported generically — telling an attacker whether
 * an email exists is a free enumeration oracle.
 */
export function LoginForm({ nextPath }: { readonly nextPath: string }) {
  const router = useRouter();
  const [formError, setFormError] = React.useState<string | null>(null);

  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<LoginInput>({ defaultValues: { email: '', password: '' } });

  const onSubmit = handleSubmit(async (values) => {
    setFormError(null);

    const parsed = loginSchema.safeParse(values);
    if (!parsed.success) {
      setFormError(parsed.error.issues[0]?.message ?? 'Please check the details you entered.');
      return;
    }

    const supabase = getSupabaseBrowserClient();
    const { error } = await supabase.auth.signInWithPassword({
      email: parsed.data.email,
      password: parsed.data.password,
    });

    if (error) {
      setFormError('Those credentials were not recognised.');
      return;
    }

    // Redirect within the app: an open redirect would let a phishing link bounce
    // through our own domain.
    const destination = nextPath.startsWith('/') && !nextPath.startsWith('//') ? nextPath : '/dashboard';
    router.replace(destination);
    router.refresh();
  });

  return (
    <form onSubmit={onSubmit} className="space-y-4" noValidate>
      {formError && (
        <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
          {formError}
        </div>
      )}

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

      <div className="space-y-1.5">
        <Label htmlFor="password">Password</Label>
        <Input
          id="password"
          type="password"
          autoComplete="current-password"
          placeholder="••••••••"
          aria-invalid={Boolean(errors.password)}
          {...register('password', { required: 'Password is required.' })}
        />
        <FieldError>{errors.password?.message}</FieldError>
      </div>

      <Button type="submit" size="lg" className="w-full" disabled={isSubmitting}>
        {isSubmitting && <Loader2 className="animate-spin" aria-hidden />}
        {isSubmitting ? 'Signing in…' : 'Sign in'}
      </Button>
    </form>
  );
}
