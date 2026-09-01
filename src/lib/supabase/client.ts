'use client';

import { createBrowserClient } from '@supabase/ssr';
import type { SupabaseClient } from '@supabase/supabase-js';

import { publicEnv } from '@/config/env';
import type { Database } from '@/types/database.types';

let browserClient: SupabaseClient<Database> | null = null;

/**
 * Browser Supabase client, carrying the anon key only.
 *
 * Every query it issues is subject to RLS. It is used for auth (sign-in, sign-out,
 * password reset) and for realtime; business reads go through server components
 * and route handlers so that permission checks and field redaction happen before
 * data leaves the server.
 */
export function getSupabaseBrowserClient(): SupabaseClient<Database> {
  if (!browserClient) {
    browserClient = createBrowserClient<Database>(publicEnv.supabaseUrl, publicEnv.supabaseAnonKey);
  }
  return browserClient;
}
