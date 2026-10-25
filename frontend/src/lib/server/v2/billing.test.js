import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

const apiRequest = vi.fn();
vi.mock('#lib/api-helpers.js', () => ({ apiRequest: (...a) => apiRequest(...a) }));

const {
  getBilling,
  readBilling,
  syncCheckout,
  openCheckout,
  openPortal,
  changePlan,
  paymentPageUrl,
  billingRefusal,
  isPlanRefusal,
  isPlanKey,
  isSessionId,
  resetBillingAbsentMemo
} = await import('#lib/server/v2/billing.js');

const event = /** @type {any} */ ({ cookies: { get: () => 'token' } });
const failure = (/** @type {number} */ status, body = {}) =>
  Object.assign(new Error('failed'), { status, body });

const MEMBER = { plan: { key: 'a', name: 'Plan A' }, can_manage: false };
const ADMIN = {
  plan: { key: 'a', name: 'Plan A' },
  can_manage: true,
  state: { code: 'active', sentence: 'Renews on 3 December' },
  notice: null,
  plans: [
    {
      key: 'a',
      name: 'Plan A',
      price_text: 'Price A',
      features: ['Feature one'],
      current: true,
      action: null
    },
    {
      key: 'b',
      name: 'Plan B',
      price_text: 'Price B',
      features: ['Feature two', 'Feature three'],
      current: false,
      action: 'switch',
      confirm: 'Plan B starts now, and the difference is charged today.'
    }
  ]
};

beforeEach(() => {
  apiRequest.mockReset();
  resetBillingAbsentMemo();
});

describe('getBilling', () => {
  it('asks quietly and gives a member the plan name only', async () => {
    apiRequest.mockResolvedValueOnce(MEMBER);
    expect(await getBilling(event)).toEqual({
      plan: { key: 'a', name: 'Plan A' },
      canManage: false,
      state: null,
      notice: null,
      plans: null
    });
    expect(apiRequest).toHaveBeenCalledWith(
      '/billing/',
      { quietErrors: true, expectedStatuses: [404] },
      event
    );
  });

  it('gives an admin the state, the notice and every plan with its button', async () => {
    apiRequest.mockResolvedValueOnce({
      ...ADMIN,
      notice: { sentence: 'The last payment failed.' }
    });
    const answer = await getBilling(event);
    expect(answer?.canManage).toBe(true);
    expect(answer?.state).toEqual({ code: 'active', sentence: 'Renews on 3 December' });
    expect(answer?.notice).toEqual({ sentence: 'The last payment failed.' });
    expect(answer?.plans).toEqual([
      {
        key: 'a',
        name: 'Plan A',
        priceText: 'Price A',
        features: ['Feature one'],
        current: true,
        action: null,
        confirm: ''
      },
      {
        key: 'b',
        name: 'Plan B',
        priceText: 'Price B',
        features: ['Feature two', 'Feature three'],
        current: false,
        action: 'switch',
        confirm: 'Plan B starts now, and the difference is charged today.'
      }
    ]);
  });

  it('answers null where the server offers no billing, and on any failure', async () => {
    apiRequest.mockRejectedValueOnce(failure(404));
    expect(await getBilling(event)).toBeNull();
    resetBillingAbsentMemo();
    apiRequest.mockRejectedValueOnce(failure(500));
    expect(await getBilling(event)).toBeNull();
    apiRequest.mockRejectedValueOnce(new Error('fetch failed'));
    expect(await getBilling(event)).toBeNull();
  });

  it('answers null for a body without a named plan', async () => {
    for (const body of [null, {}, { plan: null }, { plan: { key: 'a' } }, { plan: { name: '' } }]) {
      apiRequest.mockResolvedValueOnce(body);
      expect(await getBilling(event)).toBeNull();
    }
  });

  it('drops plans it cannot show, repeated keys and buttons it does not know', async () => {
    apiRequest.mockResolvedValueOnce({
      ...ADMIN,
      notice: { sentence: '  ' },
      state: { code: 'active' },
      plans: [
        null,
        { key: 'BAD KEY', name: 'Bad' },
        { key: 'c', name: 'Plan C', features: 'all of them', action: 'manage', confirm: 7 },
        { key: 'd', name: '' },
        { key: 'c', name: 'Plan C again' }
      ]
    });
    const answer = await getBilling(event);
    expect(answer?.notice).toBeNull();
    expect(answer?.state).toBeNull();
    expect(answer?.plans).toEqual([
      {
        key: 'c',
        name: 'Plan C',
        priceText: '',
        features: [],
        current: false,
        action: null,
        confirm: ''
      }
    ]);
  });
});

describe('the absent memo', () => {
  afterEach(() => vi.useRealTimers());

  it('skips the API for 5 minutes after a 404', async () => {
    vi.useFakeTimers();
    apiRequest.mockRejectedValueOnce(failure(404));
    expect(await getBilling(event)).toBeNull();
    expect(await getBilling(event)).toBeNull();
    expect(apiRequest).toHaveBeenCalledTimes(1);

    vi.advanceTimersByTime(5 * 60 * 1000 + 1);
    apiRequest.mockResolvedValueOnce(MEMBER);
    expect((await getBilling(event))?.plan.name).toBe('Plan A');
    expect(apiRequest).toHaveBeenCalledTimes(2);
  });

  it('is not set by a failure that is not a 404', async () => {
    apiRequest.mockRejectedValueOnce(failure(503));
    expect(await getBilling(event)).toBeNull();
    apiRequest.mockResolvedValueOnce(MEMBER);
    expect(await getBilling(event)).not.toBeNull();
  });

  it('also answers the billing page without a call', async () => {
    apiRequest.mockRejectedValueOnce(failure(404));
    await getBilling(event);
    await expect(readBilling(event)).rejects.toMatchObject({ status: 404 });
    expect(apiRequest).toHaveBeenCalledTimes(1);
  });
});

describe('readBilling', () => {
  it('reads the answer for the page', async () => {
    apiRequest.mockResolvedValueOnce(ADMIN);
    expect((await readBilling(event)).plans).toHaveLength(2);
    expect(apiRequest).toHaveBeenCalledWith('/billing/', { expectedStatuses: [404] }, event);
  });

  it('turns a 404 into a page 404 and remembers it', async () => {
    apiRequest.mockRejectedValueOnce(failure(404));
    await expect(readBilling(event)).rejects.toMatchObject({ status: 404 });
    expect(await getBilling(event)).toBeNull();
    expect(apiRequest).toHaveBeenCalledTimes(1);
  });

  it('lets any other failure through', async () => {
    apiRequest.mockRejectedValueOnce(failure(500));
    await expect(readBilling(event)).rejects.toMatchObject({ status: 500 });
  });

  it('refuses a 200 that is not a billing answer', async () => {
    apiRequest.mockResolvedValueOnce({ detail: 'ok' });
    await expect(readBilling(event)).rejects.toMatchObject({ status: 502 });
  });
});

describe('syncCheckout', () => {
  it('asks once with the session id in the query', async () => {
    apiRequest.mockResolvedValueOnce(ADMIN);
    expect(await syncCheckout(event, 'sess_Ab12')).toBe(true);
    expect(apiRequest).toHaveBeenCalledTimes(1);
    expect(apiRequest).toHaveBeenCalledWith(
      '/billing/?session=sess_Ab12',
      { quietErrors: true, expectedStatuses: [403, 404] },
      event
    );
  });

  it('never sends an id that is not a plain token', async () => {
    for (const id of ['', 'a b', 'x&session=y', '../x', 'a'.repeat(256), null]) {
      expect(await syncCheckout(event, /** @type {any} */ (id))).toBe(false);
    }
    expect(apiRequest).not.toHaveBeenCalled();
  });

  it("is best effort: another org's session or a failure is false, not a throw", async () => {
    apiRequest.mockRejectedValueOnce(failure(404));
    expect(await syncCheckout(event, 'sess_1')).toBe(false);
    apiRequest.mockRejectedValueOnce(failure(500));
    expect(await syncCheckout(event, 'sess_1')).toBe(false);
  });
});

describe('openCheckout and openPortal', () => {
  it('posts the plan and answers the https address', async () => {
    apiRequest.mockResolvedValueOnce({ url: 'https://pay.example.com/c/1#frag' });
    expect(await openCheckout(event, 'b')).toBe('https://pay.example.com/c/1#frag');
    expect(apiRequest).toHaveBeenCalledWith(
      '/billing/checkout/',
      { method: 'POST', body: { plan: 'b' }, expectedStatuses: [400, 403, 404, 409] },
      event
    );
  });

  it('never posts a plan key that is not a key', async () => {
    for (const plan of ['', 'Plan B', 'b/../x', null, 3]) {
      await expect(openCheckout(event, /** @type {any} */ (plan))).rejects.toMatchObject({
        status: 400
      });
    }
    expect(apiRequest).not.toHaveBeenCalled();
  });

  it('posts for the portal and answers the https address', async () => {
    apiRequest.mockResolvedValueOnce({ url: 'https://portal.example.com/s/2' });
    expect(await openPortal(event)).toBe('https://portal.example.com/s/2');
    expect(apiRequest).toHaveBeenCalledWith(
      '/billing/portal/',
      { method: 'POST', expectedStatuses: [403, 404, 409] },
      event
    );
  });

  it('answers null for an address that is not https', async () => {
    for (const url of [
      'http://pay.example.com/c/1',
      'javascript:alert(1)',
      '//pay.example.com/c/1',
      '/settings',
      'https://user:pass@pay.example.com/',
      'not a url',
      '',
      undefined
    ]) {
      apiRequest.mockResolvedValueOnce({ url });
      expect(await openCheckout(event, 'b')).toBeNull();
      apiRequest.mockResolvedValueOnce({ url });
      expect(await openPortal(event)).toBeNull();
    }
  });

  it('lets a refusal through with its status and body', async () => {
    apiRequest.mockRejectedValueOnce(failure(409, { detail: 'Already on a plan.' }));
    await expect(openCheckout(event, 'b')).rejects.toMatchObject({ status: 409 });
  });
});

describe('changePlan', () => {
  it("posts the plan and answers the server's sentence", async () => {
    apiRequest.mockResolvedValueOnce({ message: 'You are on Plan B now.', plan: {} });
    expect(await changePlan(event, 'b')).toBe('You are on Plan B now.');
    expect(apiRequest).toHaveBeenCalledWith(
      '/billing/change/',
      { method: 'POST', body: { plan: 'b' }, expectedStatuses: [400, 402, 403, 404, 409] },
      event
    );
  });

  it('answers an empty sentence when the server sends none', async () => {
    apiRequest.mockResolvedValueOnce({ plan: {} });
    expect(await changePlan(event, 'b')).toBe('');
  });

  it('never posts a plan key that is not a key', async () => {
    for (const plan of ['', 'Plan B', 'b/../x', null]) {
      await expect(changePlan(event, /** @type {any} */ (plan))).rejects.toMatchObject({
        status: 400
      });
    }
    expect(apiRequest).not.toHaveBeenCalled();
  });

  it('lets a refused payment through with its status and body', async () => {
    apiRequest.mockRejectedValueOnce(failure(402, { detail: 'The payment did not go through.' }));
    await expect(changePlan(event, 'b')).rejects.toMatchObject({
      status: 402,
      body: { detail: 'The payment did not go through.' }
    });
  });
});

describe('paymentPageUrl', () => {
  it('keeps an https address whole', () => {
    expect(paymentPageUrl('https://pay.example.com/c/1?x=1')).toBe(
      'https://pay.example.com/c/1?x=1'
    );
  });

  it('refuses anything longer than a browser address should be', () => {
    expect(paymentPageUrl(`https://pay.example.com/${'a'.repeat(5000)}`)).toBeNull();
  });
});

describe('billingRefusal', () => {
  it('shows the server sentence for a 409 or a 400', () => {
    expect(billingRefusal(failure(409, { detail: 'Already on a plan.' }), 'x')).toBe(
      'Already on a plan.'
    );
    expect(billingRefusal(failure(400, { detail: 'Unknown plan.' }), 'x')).toBe('Unknown plan.');
    expect(billingRefusal(failure(402, { detail: 'The payment did not go through.' }), 'x')).toBe(
      'The payment did not go through.'
    );
    expect(billingRefusal(failure(409, { errors: 'No customer yet.' }), 'x')).toBe(
      'No customer yet.'
    );
  });

  it('says plainly who may act and where billing is not offered', () => {
    expect(billingRefusal(failure(403, { detail: 'You do not have permission.' }), 'x')).toBe(
      'Only an organization admin can change the plan.'
    );
    expect(billingRefusal(failure(404), 'x')).toBe('Billing is not available here.');
  });

  it('falls back for a server or network failure', () => {
    expect(billingRefusal(failure(500, { detail: 'Traceback' }), 'Try again.')).toBe('Try again.');
    expect(billingRefusal(new Error('fetch failed'), 'Try again.')).toBe('Try again.');
  });
});

describe('isPlanRefusal', () => {
  it('is true only for a 403 carrying a plan code', () => {
    expect(isPlanRefusal(failure(403, { code: 'plan_limit' }))).toBe(true);
    expect(isPlanRefusal(failure(403, { code: 'plan_required' }))).toBe(true);
    expect(isPlanRefusal(failure(403, { detail: 'Admins only.' }))).toBe(false);
    expect(isPlanRefusal(failure(400, { code: 'plan_limit' }))).toBe(false);
    expect(isPlanRefusal(null)).toBe(false);
  });
});

describe('the key checks', () => {
  it('accept plain keys and tokens only', () => {
    expect(isPlanKey('b')).toBe(true);
    expect(isPlanKey('plan_b2')).toBe(true);
    expect(isPlanKey('B')).toBe(false);
    expect(isPlanKey('a'.repeat(33))).toBe(false);
    expect(isSessionId('sess_AbC123')).toBe(true);
    expect(isSessionId('sess-1')).toBe(false);
  });
});
