import { redirect } from 'next/navigation';

import { isSupabaseConfigured } from '@/config/env';

export default function RootPage() {
  redirect(isSupabaseConfigured ? '/dashboard' : '/setup');
}
