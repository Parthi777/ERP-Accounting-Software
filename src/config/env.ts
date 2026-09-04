/**
 * Environment configuration.
 *
 * Two rules shape this file:
 *
 *  1. A missing Supabase configuration must not crash the app. The project is
 *     provisioned separately, so an unconfigured deployment boots and serves
 *     /setup with instructions instead of throwing on import.
 *  2. `NEXT_PUBLIC_*` variables are inlined by the bundler at build time, which
 *     only works when they appear as complete literal member expressions. They
 *     are therefore read one by one below rather than through a loop.
 */

import { z } from 'zod';

// ─────────────────────────────────────────────────────────────────────────────
// Public — safe to reach the browser
// ─────────────────────────────────────────────────────────────────────────────

const publicSchema = z.object({
  NEXT_PUBLIC_SUPABASE_URL: z.string().url(),
  NEXT_PUBLIC_SUPABASE_ANON_KEY: z.string().min(20),
  NEXT_PUBLIC_APP_URL: z.string().url().optional(),
});

const publicValues = {
  NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL,
  NEXT_PUBLIC_SUPABASE_ANON_KEY: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
  NEXT_PUBLIC_APP_URL: process.env.NEXT_PUBLIC_APP_URL,
};

const publicParsed = publicSchema.safeParse(publicValues);

/** True when Supabase is configured well enough to attempt a connection. */
export const isSupabaseConfigured = publicParsed.success;

/**
 * Which variables are missing or malformed. Rendered on /setup so the operator
 * sees exactly what to add rather than a stack trace.
 */
export const missingPublicEnv: readonly string[] = publicParsed.success
  ? []
  : publicParsed.error.issues.map((issue) => String(issue.path[0] ?? 'unknown'));

export const publicEnv = {
  supabaseUrl: publicValues.NEXT_PUBLIC_SUPABASE_URL ?? '',
  supabaseAnonKey: publicValues.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? '',
  appUrl: publicValues.NEXT_PUBLIC_APP_URL ?? 'http://localhost:3000',
} as const;

// ─────────────────────────────────────────────────────────────────────────────
// Server — never bundled into client code
// ─────────────────────────────────────────────────────────────────────────────

const serverSchema = z.object({
  SUPABASE_SERVICE_ROLE_KEY: z.string().min(20).optional(),
  DATABASE_URL: z.string().optional(),
  APP_SECRET: z.string().min(32).optional(),
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  GST_API_BASE_URL: z.string().url().optional().or(z.literal('')),
  GST_API_USERNAME: z.string().optional(),
  GST_API_PASSWORD: z.string().optional(),
  GST_API_CLIENT_ID: z.string().optional(),
  GST_API_CLIENT_SECRET: z.string().optional(),
  /** The GSTIN documents are filed under, when it differs from the dealer's. */
  GST_API_GSTIN: z.string().optional(),
  SUPABASE_STORAGE_BUCKET: z.string().default('tw-erp-documents'),

  // External attendance system — spec §40. Unconfigured is a state, not an
  // error: a dealer without one sees "not connected", never a stack trace.
  ATTENDANCE_API_BASE_URL: z.string().url().optional().or(z.literal('')),
  ATTENDANCE_API_KEY: z.string().optional(),
  /** 'bearer' sends Authorization: Bearer <key>; 'header' sends x-api-key. */
  ATTENDANCE_API_AUTH: z.enum(['bearer', 'header', 'basic']).default('bearer'),
  /** Header name when ATTENDANCE_API_AUTH is 'header'. */
  ATTENDANCE_API_KEY_HEADER: z.string().default('x-api-key'),
  /** Path appended to the base URL for the attendance query. */
  ATTENDANCE_API_PATH: z.string().default('/attendance'),
});

type ServerEnv = z.infer<typeof serverSchema>;

let cachedServerEnv: ServerEnv | null = null;

/**
 * Server-only configuration. Throws if called from the browser, which turns an
 * accidental client import into a loud failure rather than a leaked secret.
 */
export function serverEnv(): ServerEnv {
  if (typeof window !== 'undefined') {
    throw new Error('serverEnv() was called in the browser. Server configuration must stay server-side.');
  }

  if (cachedServerEnv) {
    return cachedServerEnv;
  }

  const parsed = serverSchema.safeParse({
    SUPABASE_SERVICE_ROLE_KEY: process.env.SUPABASE_SERVICE_ROLE_KEY,
    DATABASE_URL: process.env.DATABASE_URL,
    APP_SECRET: process.env.APP_SECRET,
    NODE_ENV: process.env.NODE_ENV,
    GST_API_BASE_URL: process.env.GST_API_BASE_URL,
    GST_API_USERNAME: process.env.GST_API_USERNAME,
    GST_API_PASSWORD: process.env.GST_API_PASSWORD,
    GST_API_CLIENT_ID: process.env.GST_API_CLIENT_ID,
    GST_API_CLIENT_SECRET: process.env.GST_API_CLIENT_SECRET,
    GST_API_GSTIN: process.env.GST_API_GSTIN,
    SUPABASE_STORAGE_BUCKET: process.env.SUPABASE_STORAGE_BUCKET,
    ATTENDANCE_API_BASE_URL: process.env.ATTENDANCE_API_BASE_URL,
    ATTENDANCE_API_KEY: process.env.ATTENDANCE_API_KEY,
    ATTENDANCE_API_AUTH: process.env.ATTENDANCE_API_AUTH,
    ATTENDANCE_API_KEY_HEADER: process.env.ATTENDANCE_API_KEY_HEADER,
    ATTENDANCE_API_PATH: process.env.ATTENDANCE_API_PATH,
  });

  if (!parsed.success) {
    const detail = parsed.error.issues
      .map((issue) => `${String(issue.path[0])}: ${issue.message}`)
      .join('; ');
    throw new Error(`Invalid server environment — ${detail}`);
  }

  cachedServerEnv = parsed.data;
  return cachedServerEnv;
}

export const isProduction = process.env.NODE_ENV === 'production';
