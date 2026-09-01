import 'server-only';

import { serverEnv } from '@/config/env';

/**
 * The Invoice Registration Portal client — spec §40.
 *
 * This is the only place in the application that talks to the tax portal, and it
 * is deliberately the only place that knows the portal exists. Everything above
 * it deals in "submit this document, here is what came back".
 *
 * Three rules shape it, all from spec §40:
 *
 *   1. **A portal failure must never corrupt accounting.** Nothing here writes
 *      to the ledger, and every failure path returns a result rather than
 *      throwing — the invoice stays posted and its e-invoice goes FAILED, which
 *      is a state the queue already knows how to retry.
 *
 *   2. **Store the technical error, show a readable one.** `message` is for the
 *      operator; `code` and `raw` go into the row for whoever has to ring the
 *      GSP.
 *
 *   3. **Unconfigured is not an error.** A dealer without a GSP account should
 *      see "not configured", not a stack trace. `isConfigured()` is how callers
 *      ask before offering the button.
 *
 * The shape follows the common GSP wrapper around the NIC API: authenticate for
 * a token, then POST the invoice. Providers differ in detail; the seam for that
 * is this file and nothing else.
 */

export interface IrpConfig {
  readonly baseUrl: string;
  readonly username: string;
  readonly password: string;
  readonly clientId: string;
  readonly clientSecret: string;
  readonly gstin?: string;
}

export type IrpOutcome =
  | {
      readonly ok: true;
      readonly irn: string;
      readonly ackNumber: string;
      readonly ackDate: string | null;
      readonly signedQr: string | null;
      readonly raw: unknown;
    }
  | {
      readonly ok: false;
      /** Safe to show an operator. */
      readonly message: string;
      /** The portal's own code, kept for support calls. */
      readonly code: string | null;
      readonly raw: unknown;
      /** True when retrying might work: a timeout, a 5xx, a token expiry. */
      readonly retryable: boolean;
    };

/** Ten seconds: long enough for the portal on a bad day, short enough that a queue does not stall. */
const TIMEOUT_MS = 10_000;

export function irpConfig(): IrpConfig | null {
  const env = serverEnv();
  const baseUrl = env.GST_API_BASE_URL?.trim();

  // Credentials are all-or-nothing. A half-configured provider fails at the
  // worst moment — mid-filing — so it is treated as unconfigured here.
  if (!baseUrl || !env.GST_API_USERNAME || !env.GST_API_PASSWORD || !env.GST_API_CLIENT_ID || !env.GST_API_CLIENT_SECRET) {
    return null;
  }

  return {
    baseUrl: baseUrl.replace(/\/+$/, ''),
    username: env.GST_API_USERNAME,
    password: env.GST_API_PASSWORD,
    clientId: env.GST_API_CLIENT_ID,
    clientSecret: env.GST_API_CLIENT_SECRET,
    gstin: env.GST_API_GSTIN,
  };
}

export function isConfigured(): boolean {
  return irpConfig() !== null;
}

async function postJson(
  url: string,
  body: unknown,
  headers: Record<string, string>,
): Promise<{ status: number; json: unknown }> {
  // AbortSignal.timeout rather than a manual race: it cancels the socket too, so
  // a hung portal does not hold a connection open behind us.
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(TIMEOUT_MS),
    cache: 'no-store',
  });

  let json: unknown = null;
  try {
    json = await response.json();
  } catch {
    // A non-JSON body is itself the diagnostic; keep the status and move on.
    json = { parseError: 'The portal did not return JSON.' };
  }

  return { status: response.status, json };
}

function readString(source: unknown, ...keys: readonly string[]): string | null {
  if (typeof source !== 'object' || source === null) return null;
  const record = source as Record<string, unknown>;
  for (const key of keys) {
    const value = record[key];
    if (typeof value === 'string' && value.length > 0) return value;
    if (typeof value === 'number') return String(value);
  }
  return null;
}

/**
 * Authenticates and submits one invoice.
 *
 * Returns an outcome for every path, including transport failure. Callers record
 * it and carry on; nothing here is allowed to throw into a request handler.
 */
export async function submitToIrp(payload: unknown): Promise<IrpOutcome> {
  const config = irpConfig();

  if (!config) {
    return {
      ok: false,
      message:
        'No e-invoice provider is configured. Set GST_API_BASE_URL and the API credentials to file with the portal.',
      code: 'NOT_CONFIGURED',
      raw: null,
      // Retrying changes nothing until someone edits the environment.
      retryable: false,
    };
  }

  try {
    // ── Authenticate ────────────────────────────────────────────────────────
    const auth = await postJson(
      `${config.baseUrl}/auth`,
      {
        UserName: config.username,
        Password: config.password,
        AppKey: config.clientId,
        ForceRefreshAccessToken: false,
      },
      { 'client-id': config.clientId, 'client-secret': config.clientSecret },
    );

    const token =
      readString(auth.json, 'AuthToken', 'authToken', 'token') ??
      readString((auth.json as { Data?: unknown } | null)?.Data, 'AuthToken', 'authToken');

    if (auth.status >= 400 || !token) {
      return {
        ok: false,
        message: 'The e-invoice provider rejected the credentials.',
        code: readString(auth.json, 'ErrorCode', 'errorCode') ?? `HTTP_${auth.status}`,
        raw: auth.json,
        // A 5xx during auth is the portal's problem, not the credentials'.
        retryable: auth.status >= 500,
      };
    }

    // ── Submit ──────────────────────────────────────────────────────────────
    const response = await postJson(`${config.baseUrl}/invoice`, payload, {
      'client-id': config.clientId,
      'client-secret': config.clientSecret,
      authorization: `Bearer ${token}`,
      ...(config.gstin ? { gstin: config.gstin } : {}),
    });

    const body = response.json as { Data?: unknown; Status?: unknown } | null;
    const data = body?.Data ?? body;
    const irn = readString(data, 'Irn', 'irn');
    const ackNumber = readString(data, 'AckNo', 'ackNo', 'AckNumber');

    if (response.status < 400 && irn && ackNumber) {
      return {
        ok: true,
        irn,
        ackNumber,
        ackDate: readString(data, 'AckDt', 'ackDt'),
        signedQr: readString(data, 'SignedQRCode', 'signedQRCode'),
        raw: response.json,
      };
    }

    // A duplicate is not a failure: the portal already has this invoice, and it
    // returns the original IRN. Treating it as an error would leave a filed
    // document marked unfiled.
    const duplicateIrn = readString(data, 'Desc') === null ? null : readString(data, 'Irn', 'irn');
    if (duplicateIrn && ackNumber) {
      return {
        ok: true,
        irn: duplicateIrn,
        ackNumber,
        ackDate: readString(data, 'AckDt', 'ackDt'),
        signedQr: readString(data, 'SignedQRCode', 'signedQRCode'),
        raw: response.json,
      };
    }

    return {
      ok: false,
      message:
        readString(data, 'ErrorMessage', 'errorMessage', 'Desc', 'message') ??
        `The portal refused the invoice (HTTP ${response.status}).`,
      code: readString(data, 'ErrorCode', 'errorCode') ?? `HTTP_${response.status}`,
      raw: response.json,
      // 4xx means the document is wrong; resending it unchanged will fail again.
      retryable: response.status >= 500,
    };
  } catch (error) {
    const timedOut = error instanceof Error && error.name === 'TimeoutError';
    return {
      ok: false,
      message: timedOut
        ? 'The e-invoice provider did not respond in time. The invoice is unchanged; try again.'
        : 'The e-invoice provider could not be reached. The invoice is unchanged; try again.',
      code: timedOut ? 'TIMEOUT' : 'NETWORK',
      raw: { error: error instanceof Error ? error.message : String(error) },
      retryable: true,
    };
  }
}
