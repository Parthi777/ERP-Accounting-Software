import { describe, expect, it, vi } from 'vitest';

/**
 * The e-invoice client, which is the only part of this product that talks to a
 * government portal.
 *
 * ── The trap this file is designed around ───────────────────────────────────
 *
 * `serverEnv()` memoises into a module-level `cachedServerEnv` (config/env.ts).
 * Import the module once and the first test's configuration is frozen for every
 * later one — `vi.stubEnv` still appears to work, the assertions still pass, and
 * each case silently re-tests the first one's environment.
 *
 * So every case goes through `load()`: reset the module registry, stub the
 * environment, *then* import. Nothing here may import the client at the top of
 * the file.
 */

const CREDENTIALS = {
  GST_API_BASE_URL: 'https://irp.example.test/api/',
  GST_API_USERNAME: 'user',
  GST_API_PASSWORD: 'pass',
  GST_API_CLIENT_ID: 'client',
  GST_API_CLIENT_SECRET: 'secret',
};

async function load(env: Record<string, string> = {}) {
  vi.resetModules();
  for (const [key, value] of Object.entries(env)) {
    vi.stubEnv(key, value);
  }
  return import('./irp-client');
}

/** Queues responses in call order: auth first, then the invoice submission. */
function mockFetch(...responses: { status: number; body: unknown }[]) {
  const calls: { url: string; init: RequestInit }[] = [];
  const fn = vi.fn(async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    const next = responses.shift() ?? { status: 500, body: {} };
    return {
      status: next.status,
      json: async () => next.body,
    } as unknown as Response;
  });
  vi.stubGlobal('fetch', fn);
  return calls;
}

describe('irpConfig', () => {
  it('is null when nothing is configured', async () => {
    const { irpConfig, isConfigured } = await load();
    expect(irpConfig()).toBeNull();
    expect(isConfigured()).toBe(false);
  });

  /**
   * All-or-nothing on purpose. A half-configured provider fails mid-filing,
   * which is the worst moment to discover a missing secret.
   */
  it('is null when any single credential is missing', async () => {
    for (const omit of Object.keys(CREDENTIALS)) {
      const partial = { ...CREDENTIALS, [omit]: '' };
      const { irpConfig } = await load(partial);
      expect(irpConfig(), `omitting ${omit}`).toBeNull();
    }
  });

  it('trims the trailing slash so URLs do not double up', async () => {
    const { irpConfig } = await load(CREDENTIALS);
    expect(irpConfig()?.baseUrl).toBe('https://irp.example.test/api');
  });
});

describe('submitToIrp', () => {
  it('reports NOT_CONFIGURED without touching the network', async () => {
    const calls = mockFetch();
    const { submitToIrp } = await load();

    const outcome = await submitToIrp({ any: 'payload' });

    expect(outcome.ok).toBe(false);
    expect(outcome).toMatchObject({ code: 'NOT_CONFIGURED', retryable: false });
    expect(calls).toHaveLength(0);
  });

  it('authenticates, then submits with the token as a Bearer header', async () => {
    const calls = mockFetch(
      { status: 200, body: { Data: { AuthToken: 'tok-123' } } },
      {
        status: 200,
        body: { Data: { Irn: 'IRN-1', AckNo: '112233', AckDt: '2026-04-01', SignedQRCode: 'QR' } },
      },
    );
    const { submitToIrp } = await load(CREDENTIALS);

    const outcome = await submitToIrp({ invoice: 1 });

    expect(calls).toHaveLength(2);
    expect(calls[0]!.url).toBe('https://irp.example.test/api/auth');
    expect(calls[1]!.url).toBe('https://irp.example.test/api/invoice');

    const headers = calls[1]!.init.headers as Record<string, string>;
    expect(headers.authorization).toBe('Bearer tok-123');
    expect(headers['client-id']).toBe('client');

    expect(outcome).toMatchObject({
      ok: true,
      irn: 'IRN-1',
      ackNumber: '112233',
      ackDate: '2026-04-01',
      signedQr: 'QR',
    });
  });

  it('reads the response whether the portal nests it under Data or not', async () => {
    mockFetch(
      { status: 200, body: { AuthToken: 'tok' } },
      { status: 200, body: { irn: 'IRN-2', ackNo: 998877 } },
    );
    const { submitToIrp } = await load(CREDENTIALS);

    const outcome = await submitToIrp({});
    expect(outcome).toMatchObject({ ok: true, irn: 'IRN-2', ackNumber: '998877' });
  });

  it('treats a duplicate as filed, since the portal returns the original IRN', async () => {
    mockFetch(
      { status: 200, body: { AuthToken: 'tok' } },
      { status: 400, body: { Desc: 'Duplicate IRN', Irn: 'IRN-ORIGINAL', AckNo: '5566' } },
    );
    const { submitToIrp } = await load(CREDENTIALS);

    const outcome = await submitToIrp({});
    expect(outcome).toMatchObject({ ok: true, irn: 'IRN-ORIGINAL' });
  });

  /**
   * The duplicate branch keys off *any* response carrying both a `Desc` and an
   * `Irn`, not off the message meaning "duplicate". A genuine rejection that
   * happened to echo an IRN back would therefore be recorded as filed. Nothing
   * observed does that — a rejection carries a null Irn, which this pins — but
   * the condition is looser than its comment claims and is worth narrowing to an
   * explicit duplicate code when someone next has portal documentation to hand.
   */
  it('does not mistake a plain rejection for a duplicate', async () => {
    mockFetch(
      { status: 200, body: { AuthToken: 'tok' } },
      { status: 400, body: { Desc: 'Invalid GSTIN', Irn: null, ErrorCode: '2172' } },
    );
    const { submitToIrp } = await load(CREDENTIALS);

    const outcome = await submitToIrp({});
    expect(outcome.ok).toBe(false);
    expect(outcome).toMatchObject({ code: '2172', retryable: false });
  });

  it('rejects bad credentials without retrying', async () => {
    mockFetch({ status: 401, body: { ErrorCode: 'AUTH', Desc: 'Invalid credentials' } });
    const { submitToIrp } = await load(CREDENTIALS);

    const outcome = await submitToIrp({});
    expect(outcome).toMatchObject({ ok: false, code: 'AUTH', retryable: false });
  });

  it('treats a 5xx during auth as the portal’s problem, so retryable', async () => {
    mockFetch({ status: 503, body: {} });
    const { submitToIrp } = await load(CREDENTIALS);

    const outcome = await submitToIrp({});
    expect(outcome).toMatchObject({ ok: false, retryable: true });
  });

  /**
   * The distinction the retry queue depends on: 4xx means the document is
   * wrong and resending it unchanged fails again; 5xx means the portal is
   * unwell and the same document will go through later.
   */
  it('marks 4xx not-retryable and 5xx retryable on submission', async () => {
    mockFetch(
      { status: 200, body: { AuthToken: 'tok' } },
      { status: 422, body: { ErrorMessage: 'Bad HSN', ErrorCode: '3028' } },
    );
    const { submitToIrp: submitBad } = await load(CREDENTIALS);
    expect(await submitBad({})).toMatchObject({ ok: false, retryable: false, code: '3028' });

    mockFetch({ status: 200, body: { AuthToken: 'tok' } }, { status: 502, body: {} });
    const { submitToIrp: submitDown } = await load(CREDENTIALS);
    expect(await submitDown({})).toMatchObject({ ok: false, retryable: true });
  });

  it('classifies a timeout as retryable and names it', async () => {
    vi.stubGlobal('fetch', async () => {
      const error = new Error('The operation timed out.');
      error.name = 'TimeoutError';
      throw error;
    });
    const { submitToIrp } = await load(CREDENTIALS);

    const outcome = await submitToIrp({});
    expect(outcome).toMatchObject({ ok: false, code: 'TIMEOUT', retryable: true });
  });

  it('classifies a transport failure as retryable', async () => {
    vi.stubGlobal('fetch', async () => {
      throw new TypeError('fetch failed');
    });
    const { submitToIrp } = await load(CREDENTIALS);

    const outcome = await submitToIrp({});
    expect(outcome).toMatchObject({ ok: false, code: 'NETWORK', retryable: true });
  });

  it('survives a non-JSON body rather than throwing on parse', async () => {
    vi.stubGlobal('fetch', async () =>
      ({
        status: 502,
        json: async () => {
          throw new SyntaxError('Unexpected token < in JSON');
        },
      }) as unknown as Response);
    const { submitToIrp } = await load(CREDENTIALS);

    const outcome = await submitToIrp({});
    expect(outcome).toMatchObject({ ok: false, retryable: true });
  });

  /**
   * The module's stated contract, and until now unenforced: nothing here may
   * throw into a request handler. A rejected promise would leave a posted
   * invoice with no e-invoice status recorded at all — worse than a failure,
   * because nothing would know to retry it.
   */
  it('never rejects, whatever the portal does', async () => {
    const disasters = [
      () => { throw new Error('boom'); },
      async () => { throw new Error('async boom'); },
      async () => ({ status: 500, json: async () => null }) as unknown as Response,
    ];

    for (const disaster of disasters) {
      vi.stubGlobal('fetch', disaster);
      const { submitToIrp } = await load(CREDENTIALS);
      await expect(submitToIrp({})).resolves.toMatchObject({ ok: false });
    }
  });
});

describe('submitEwayBill', () => {
  it('reports NOT_CONFIGURED without touching the network', async () => {
    const calls = mockFetch();
    const { submitEwayBill } = await load();

    const outcome = await submitEwayBill({ docNo: 'INV-1' });

    expect(outcome).toMatchObject({ ok: false, code: 'NOT_CONFIGURED', retryable: false });
    expect(calls).toHaveLength(0);
  });

  it('authenticates on the same token, then posts to /ewaybill', async () => {
    const calls = mockFetch(
      { status: 200, body: { Data: { AuthToken: 'tok-ew' } } },
      { status: 200, body: { Data: { ewayBillNo: '181234567890', validUpto: '02/04/2026 10:00' } } },
    );
    const { submitEwayBill } = await load(CREDENTIALS);

    const outcome = await submitEwayBill({ docNo: 'INV-1' });

    expect(calls[0]!.url).toBe('https://irp.example.test/api/auth');
    expect(calls[1]!.url).toBe('https://irp.example.test/api/ewaybill');
    expect((calls[1]!.init.headers as Record<string, string>).authorization).toBe('Bearer tok-ew');

    expect(outcome).toMatchObject({
      ok: true,
      ewayBillNumber: '181234567890',
      validUntil: '02/04/2026 10:00',
    });
  });

  it('reads the bill number under any of the names the portal uses', async () => {
    for (const key of ['ewayBillNo', 'EwbNo', 'ewbNo', 'EwayBillNo']) {
      mockFetch(
        { status: 200, body: { AuthToken: 'tok' } },
        { status: 200, body: { [key]: 991122 } },
      );
      const { submitEwayBill } = await load(CREDENTIALS);
      const outcome = await submitEwayBill({});
      expect(outcome, `key: ${key}`).toMatchObject({ ok: true, ewayBillNumber: '991122' });
    }
  });

  /**
   * The distinction the retry queue runs on: 4xx means the consignment details
   * are wrong and resending them unchanged fails again; 5xx means the portal is
   * unwell and the same request will go through later. A vehicle is usually
   * waiting, so telling the two apart is the difference between "fix the vehicle
   * number" and "wait two minutes".
   */
  it('separates a bad consignment from an unwell portal', async () => {
    mockFetch(
      { status: 200, body: { AuthToken: 'tok' } },
      { status: 400, body: { errorMessage: 'Invalid vehicle number format', errorCode: '107' } },
    );
    const { submitEwayBill: bad } = await load(CREDENTIALS);
    expect(await bad({})).toMatchObject({ ok: false, retryable: false, code: '107' });

    mockFetch({ status: 200, body: { AuthToken: 'tok' } }, { status: 503, body: {} });
    const { submitEwayBill: down } = await load(CREDENTIALS);
    expect(await down({})).toMatchObject({ ok: false, retryable: true });
  });

  it('classifies timeout and transport failure as retryable', async () => {
    vi.stubGlobal('fetch', async () => {
      const error = new Error('timed out');
      error.name = 'TimeoutError';
      throw error;
    });
    const { submitEwayBill: onTimeout } = await load(CREDENTIALS);
    expect(await onTimeout({})).toMatchObject({ ok: false, code: 'TIMEOUT', retryable: true });

    vi.stubGlobal('fetch', async () => { throw new TypeError('fetch failed'); });
    const { submitEwayBill: onNetwork } = await load(CREDENTIALS);
    expect(await onNetwork({})).toMatchObject({ ok: false, code: 'NETWORK', retryable: true });
  });

  /**
   * A 200 with no bill number is not a success. Treating it as one would mark a
   * consignment as cleared to move when the portal never issued anything, which
   * is the one outcome that puts a vehicle on the road unlawfully.
   */
  it('refuses a 200 that carries no bill number', async () => {
    mockFetch(
      { status: 200, body: { AuthToken: 'tok' } },
      { status: 200, body: { Data: { status: 'accepted' } } },
    );
    const { submitEwayBill } = await load(CREDENTIALS);
    expect(await submitEwayBill({})).toMatchObject({ ok: false });
  });

  it('never rejects, whatever the portal does', async () => {
    for (const disaster of [
      () => { throw new Error('boom'); },
      async () => { throw new Error('async boom'); },
    ]) {
      vi.stubGlobal('fetch', disaster);
      const { submitEwayBill } = await load(CREDENTIALS);
      await expect(submitEwayBill({})).resolves.toMatchObject({ ok: false });
    }
  });
});
