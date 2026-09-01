import 'server-only';

import { cookies } from 'next/headers';
import { createServerClient } from '@supabase/ssr';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';

import { isSupabaseConfigured, publicEnv, serverEnv } from '@/config/env';
import type { Database } from '@/types/database.types';

/**
 * Supabase client bound to the caller's session.
 *
 * Queries issued through this client carry the user's JWT, so every RLS policy in
 * migration 0009 applies. This is the client almost all server code should use.
 */
export async function createSupabaseServerClient(): Promise<SupabaseClient<Database>> {
  if (!isSupabaseConfigured) {
    throw new Error('Supabase is not configured. See /setup.');
  }

  const cookieStore = await cookies();

  return createServerClient<Database>(publicEnv.supabaseUrl, publicEnv.supabaseAnonKey, {
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },
      setAll(cookiesToSet) {
        try {
          for (const { name, value, options } of cookiesToSet) {
            cookieStore.set(name, value, options);
          }
        } catch {
          // Called from a Server Component, where cookies are read-only. The
          // middleware refreshes the session on every request, so there is
          // nothing to recover from here.
        }
      },
    },
  });
}

let adminClient: SupabaseClient<Database> | null = null;

/**
 * Service-role client. Bypasses RLS entirely (spec §47).
 *
 * Reserved for work that legitimately has no user session: provisioning a tenant,
 * running a scheduled job, writing an audit row for a failed login. Never use it
 * to sidestep an RLS policy that is merely inconvenient — that is the policy
 * telling you the caller lacks the permission.
 */
export function createSupabaseAdminClient(): SupabaseClient<Database> {
  if (!isSupabaseConfigured) {
    throw new Error('Supabase is not configured. See /setup.');
  }

  const { SUPABASE_SERVICE_ROLE_KEY } = serverEnv();
  if (!SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error(
      'SUPABASE_SERVICE_ROLE_KEY is not set. It is required for administrative operations.',
    );
  }

  if (!adminClient) {
    adminClient = createClient<Database>(publicEnv.supabaseUrl, SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
  }

  return adminClient;
}
