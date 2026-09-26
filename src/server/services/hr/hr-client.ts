import 'server-only';

import { serverEnv } from '@/config/env';

/**
 * The HR Payroll app's integration API — the only file that knows its shape
 * (spec §40, the same seam attendance-client.ts and irp-client.ts give their
 * systems). Every call returns a result rather than throwing, and an
 * unconfigured connection is "not connected", not an error.
 */

export interface HrEmployee {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly mobile?: string | null;
  readonly email?: string | null;
  readonly status?: string;
  readonly joiningDate?: string;
  readonly branchId: string;
  readonly branchName: string;
  readonly department?: string | null;
  readonly designation?: string | null;
}

export interface HrClaim {
  readonly id: string;
  readonly claimNo: number | null;
  readonly voucherNo: number | null;
  readonly status: string;
  readonly type: string;
  readonly typeLabel: string;
  readonly title: string;
  readonly amount: number;
  readonly employee: HrEmployee;
  readonly updatedAt: string;
}

export interface HrPayrollLine {
  readonly employee: HrEmployee;
  readonly gross: number;
  readonly pf: number;
  readonly esi: number;
  readonly professionalTax: number;
  readonly tds: number;
  readonly other: number;
  readonly net: number;
}

export type HrResult<T> = { ok: true; data: T } | { ok: false; message: string; status?: number };

export function isHrConfigured(): boolean {
  const env = serverEnv();
  return Boolean(env.HR_API_BASE_URL && env.HR_API_KEY && env.HR_DEALER_CODE);
}

async function call<T>(path: string, init: RequestInit = {}): Promise<HrResult<T>> {
  const env = serverEnv();
  if (!env.HR_API_BASE_URL || !env.HR_API_KEY) {
    return { ok: false, message: 'The HR app is not connected. Set HR_API_BASE_URL and HR_API_KEY.' };
  }
  const url = `${env.HR_API_BASE_URL.replace(/\/+$/, '')}/api/integration/v1${path}`;
  try {
    const response = await fetch(url, {
      ...init,
      headers: {
        accept: 'application/json',
        authorization: `Bearer ${env.HR_API_KEY}`,
        ...(init.body ? { 'content-type': 'application/json' } : {}),
        ...init.headers,
      },
      signal: AbortSignal.timeout(15_000),
      cache: 'no-store',
    });
    if (!response.ok) {
      const text = (await response.text()).slice(0, 300);
      const message =
        response.status === 401
          ? 'The HR app refused the key — it may have been replaced or switched off there.'
          : `The HR app answered ${response.status}: ${text}`;
      return { ok: false, message, status: response.status };
    }
    return { ok: true, data: (await response.json()) as T };
  } catch (error) {
    return { ok: false, message: `The HR app could not be reached: ${error instanceof Error ? error.message : String(error)}` };
  }
}

export const hrClient = {
  whoami: () => call<{ workspace: { slug: string; name: string }; connection: { name: string; paysClaims: boolean } }>('/whoami'),
  employees: (since?: string | null) =>
    call<{ employees: HrEmployee[] }>(`/employees${since ? `?since=${encodeURIComponent(since)}` : ''}`),
  claims: (status: string, since?: string | null) =>
    call<{ claims: HrClaim[] }>(`/claims?status=${encodeURIComponent(status)}&limit=500${since ? `&since=${encodeURIComponent(since)}` : ''}`),
  payroll: (year: number, month: number) =>
    call<{ finalized: boolean; lines: HrPayrollLine[] }>(`/payroll/${year}/${month}`),
  markPaid: (claimId: string, erpVoucherNo: string, paidAt: string) =>
    call<unknown>(`/claims/${encodeURIComponent(claimId)}/paid`, {
      method: 'POST',
      body: JSON.stringify({ erpVoucherNo, paidAt }),
    }),
  /** The receipt photo or PDF, streamed through this server so the key never reaches a browser. */
  async file(claimId: string, which: 'photo' | 'pdf'): Promise<Response | null> {
    const env = serverEnv();
    if (!env.HR_API_BASE_URL || !env.HR_API_KEY) return null;
    const response = await fetch(
      `${env.HR_API_BASE_URL.replace(/\/+$/, '')}/api/integration/v1/claims/${encodeURIComponent(claimId)}/file?which=${which}`,
      { headers: { authorization: `Bearer ${env.HR_API_KEY}` }, signal: AbortSignal.timeout(20_000), redirect: 'follow' },
    ).catch(() => null);
    return response && response.ok ? response : null;
  },
};
