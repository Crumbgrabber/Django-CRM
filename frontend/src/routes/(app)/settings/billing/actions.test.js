import { describe, it, expect, vi, beforeEach } from 'vitest';

const apiRequest = vi.fn();
vi.mock('#lib/api-helpers.js', () => ({ apiRequest: (...a) => apiRequest(...a) }));

const { load, actions } = /** @type {any} */ (await import('./+page.server.js'));
const { resetBillingAbsentMemo } = await import('#lib/server/v2/billing.js');

const cookies = /** @type {any} */ ({ get: () => 'token' });

const MEMBER = { plan: { key: 'a', name: 'Plan A' }, can_manage: false };
const ADMIN = {
  plan: { key: 'a', name: 'Plan A' },
  can_manage: false,
  state: { code: 'free', sentence: 'On Plan A.' },
  notice: null,
  plans: [
    { key: 'a', name: 'Plan A', price_text: 'Price A', features: [], current: true, action: null },
    {
      key: 'b',
      name: 'Plan B',
      price_text: 'Price B',
      features: ['More'],
      current: false,
      action: 'choose'
    }
  ]
};

const failure = (/** @type {number} */ status, body = {}) =>
  Object.assign(new Error('x'), { status, body });

/**
 * @param {Record<string, string>} [fields]
 * @param {string} [query]
 */
function event(fields = {}, query = '') {
  const body = new FormData();
  for (const [key, value] of Object.entries(fields)) body.set(key, value);
  return /** @type {any} */ ({
    request: new Request('http://test/settings/billing', { method: 'POST', body }),
    url: new URL(`http://test/settings/billing${query}`),
    cookies
  });
}

/** @param {() => Promise<any>} run */
async function thrownBy(run) {
  try {
    await run();
  } catch (/** @type {any} */ thrown) {
    return thrown;
  }
  throw new Error('expected a throw');
}

const posts = () => apiRequest.mock.calls.filter((c) => c[1]?.method === 'POST');

beforeEach(() => {
  apiRequest.mockReset();
  resetBillingAbsentMemo();
});

describe('load', () => {
  it('gives a member the plan name and nothing else', async () => {
    apiRequest.mockResolvedValueOnce(MEMBER);
    const { answer } = await load(event());
    expect(answer.plan.name).toBe('Plan A');
    expect(answer.state).toBeNull();
    expect(answer.plans).toBeNull();
    expect(answer.canManage).toBe(false);
  });

  it('gives an admin the state and every plan with its button', async () => {
    apiRequest.mockResolvedValueOnce(ADMIN);
    const { answer } = await load(event());
    expect(answer.state.sentence).toBe('On Plan A.');
    expect(answer.plans.map((/** @type {any} */ p) => [p.key, p.action])).toEqual([
      ['a', null],
      ['b', 'choose']
    ]);
  });

  it("carries a subscribed admin's switch and keep, with the sentence to confirm", async () => {
    apiRequest.mockResolvedValueOnce({
      ...ADMIN,
      can_manage: true,
      plans: [
        { key: 'a', name: 'Plan A', current: true, action: 'keep', confirm: null },
        { key: 'b', name: 'Plan B', current: false, action: 'switch', confirm: 'B starts now.' }
      ]
    });
    const { answer } = await load(event());
    expect(
      answer.plans.map((/** @type {any} */ p) => [p.key, p.current, p.action, p.confirm])
    ).toEqual([
      ['a', true, 'keep', ''],
      ['b', false, 'switch', 'B starts now.']
    ]);
  });

  it('is a 404 where the server offers no billing', async () => {
    apiRequest.mockRejectedValueOnce(failure(404));
    expect(await thrownBy(() => load(event()))).toMatchObject({ status: 404 });
  });

  it('syncs the way back from the payment page once, then drops the session from the address', async () => {
    apiRequest.mockResolvedValueOnce(ADMIN);
    const thrown = await thrownBy(() => load(event({}, '?session_id=sess_123')));
    expect(thrown).toMatchObject({ status: 303, location: '/settings/billing' });
    expect(apiRequest).toHaveBeenCalledTimes(1);
    expect(apiRequest.mock.calls[0][0]).toBe('/billing/?session=sess_123');
  });

  it('still lands on the page when the sync is refused or fails', async () => {
    for (const status of [403, 404, 500]) {
      apiRequest.mockReset();
      apiRequest.mockRejectedValueOnce(failure(status));
      const thrown = await thrownBy(() => load(event({}, '?session_id=sess_123')));
      expect(thrown).toMatchObject({ status: 303, location: '/settings/billing' });
      expect(apiRequest).toHaveBeenCalledTimes(1);
    }
  });

  it('never sends a session id that is not a plain token', async () => {
    for (const id of ['', 'a%20b', 'x%26session%3Dy', '..%2Fx']) {
      const thrown = await thrownBy(() => load(event({}, `?session_id=${id}`)));
      expect(thrown).toMatchObject({ status: 303, location: '/settings/billing' });
    }
    expect(apiRequest).not.toHaveBeenCalled();
  });
});

describe('choose', () => {
  it('posts the plan and sends the browser to the payment page', async () => {
    apiRequest.mockResolvedValueOnce({ url: 'https://pay.example.com/c/1#x' });
    const thrown = await thrownBy(() => actions.choose(event({ plan: 'b' })));
    expect(thrown).toMatchObject({ status: 303, location: 'https://pay.example.com/c/1#x' });
    expect(posts()).toEqual([
      [
        '/billing/checkout/',
        { method: 'POST', body: { plan: 'b' }, expectedStatuses: [400, 403, 404, 409] },
        { cookies }
      ]
    ]);
  });

  it("shows the server's sentence for a 409 beside the plan", async () => {
    apiRequest.mockRejectedValueOnce(
      failure(409, { detail: 'This organization already pays for a plan. Manage it instead.' })
    );
    const result = await actions.choose(event({ plan: 'b' }));
    expect(result.status).toBe(409);
    expect(result.data).toEqual({
      error: 'This organization already pays for a plan. Manage it instead.',
      plan: 'b'
    });
  });

  it('never follows an address that is not https', async () => {
    for (const url of ['http://pay.example.com/c/1', 'javascript:alert(1)', '/elsewhere', null]) {
      apiRequest.mockResolvedValueOnce({ url });
      const result = await actions.choose(event({ plan: 'b' }));
      expect(result.status).toBe(502);
      expect(result.data).toEqual({
        error: 'The payment page could not be opened. Try again.',
        plan: 'b'
      });
    }
  });

  it('refuses a plan that is not a key without calling the API', async () => {
    for (const plan of ['', 'Plan B', '../b']) {
      const result = await actions.choose(event({ plan }));
      expect(result.status).toBe(400);
      expect(result.data).toEqual({ error: 'That plan is not available.', plan: null });
    }
    const result = await actions.choose(event({}));
    expect(result.status).toBe(400);
    expect(apiRequest).not.toHaveBeenCalled();
  });

  it('tells a member only an admin can, and says where billing is not offered', async () => {
    apiRequest.mockRejectedValueOnce(failure(403, { detail: 'You do not have permission.' }));
    const member = await actions.choose(event({ plan: 'b' }));
    expect(member.status).toBe(403);
    expect(member.data.error).toBe('Only an organization admin can change the plan.');

    apiRequest.mockRejectedValueOnce(failure(404));
    const off = await actions.choose(event({ plan: 'b' }));
    expect(off.status).toBe(404);
    expect(off.data.error).toBe('Billing is not available here.');
  });

  it('says something useful when the API cannot be reached', async () => {
    apiRequest.mockRejectedValueOnce(new Error('fetch failed'));
    const result = await actions.choose(event({ plan: 'b' }));
    expect(result.status).toBe(400);
    expect(result.data.error).toBe('The payment page could not be opened. Try again.');
  });
});

describe('manage', () => {
  it('opens the billing portal', async () => {
    apiRequest.mockResolvedValueOnce({ url: 'https://portal.example.com/s/2' });
    const thrown = await thrownBy(() => actions.manage(event()));
    expect(thrown).toMatchObject({ status: 303, location: 'https://portal.example.com/s/2' });
    expect(posts()).toEqual([
      ['/billing/portal/', { method: 'POST', expectedStatuses: [403, 404, 409] }, { cookies }]
    ]);
  });

  it("shows the server's sentence for a 409, beside the plan the switch came from", async () => {
    apiRequest.mockRejectedValueOnce(failure(409, { detail: 'Nothing has been paid yet.' }));
    const fromCard = await actions.manage(event({ plan: 'b' }));
    expect(fromCard.status).toBe(409);
    expect(fromCard.data).toEqual({ error: 'Nothing has been paid yet.', plan: 'b' });

    apiRequest.mockRejectedValueOnce(failure(409, { detail: 'Nothing has been paid yet.' }));
    const fromTop = await actions.manage(event());
    expect(fromTop.data).toEqual({ error: 'Nothing has been paid yet.', plan: null });
  });

  it('never follows an address that is not https', async () => {
    apiRequest.mockResolvedValueOnce({ url: 'http://portal.example.com/s/2' });
    const result = await actions.manage(event());
    expect(result.status).toBe(502);
    expect(result.data.error).toBe('The billing portal could not be opened. Try again.');
  });

  it('tells a member only an admin can', async () => {
    apiRequest.mockRejectedValueOnce(failure(403));
    const result = await actions.manage(event());
    expect(result.status).toBe(403);
    expect(result.data.error).toBe('Only an organization admin can change the plan.');
  });
});

describe('switch and keep', () => {
  it("post the plan to the change endpoint and stay with the server's sentence", async () => {
    for (const [name, message] of [
      ['switch', 'You are on Plan B now.'],
      ['keep', 'You stay on Plan A.']
    ]) {
      apiRequest.mockReset();
      apiRequest.mockResolvedValueOnce({ message, plan: { key: 'b', name: 'Plan B' } });
      const result = await actions[name](event({ plan: 'b' }));
      expect(result).toEqual({ message, plan: 'b' });
      expect(posts()).toEqual([
        [
          '/billing/change/',
          {
            method: 'POST',
            body: { plan: 'b' },
            expectedStatuses: [400, 402, 403, 404, 409]
          },
          { cookies }
        ]
      ]);
    }
  });

  it("shows the server's sentence for a failed payment beside the plan", async () => {
    const sentence =
      'The payment for Plan B did not go through, so this organization stays on Plan A.';
    apiRequest.mockRejectedValueOnce(failure(402, { detail: sentence }));
    const result = await actions.switch(event({ plan: 'b' }));
    expect(result.status).toBe(402);
    expect(result.data).toEqual({ error: sentence, plan: 'b' });
  });

  it("shows the server's sentence for a 409", async () => {
    apiRequest.mockRejectedValueOnce(
      failure(409, { detail: 'This organization has no subscription. Choose a plan first.' })
    );
    const result = await actions.keep(event({ plan: 'a' }));
    expect(result.status).toBe(409);
    expect(result.data).toEqual({
      error: 'This organization has no subscription. Choose a plan first.',
      plan: 'a'
    });
  });

  it('tells a member only an admin can, and says where billing is not offered', async () => {
    apiRequest.mockRejectedValueOnce(failure(403, { detail: 'You do not have permission.' }));
    const member = await actions.switch(event({ plan: 'b' }));
    expect(member.status).toBe(403);
    expect(member.data.error).toBe('Only an organization admin can change the plan.');

    apiRequest.mockRejectedValueOnce(failure(404));
    const off = await actions.switch(event({ plan: 'b' }));
    expect(off.status).toBe(404);
    expect(off.data.error).toBe('Billing is not available here.');
  });

  it('refuses a plan that is not a key without calling the API', async () => {
    for (const plan of ['', 'Plan B', '../b']) {
      const result = await actions.switch(event({ plan }));
      expect(result.status).toBe(400);
      expect(result.data).toEqual({ error: 'That plan is not available.', plan: null });
    }
    expect(apiRequest).not.toHaveBeenCalled();
  });

  it('says something useful when the API cannot be reached or fails', async () => {
    apiRequest.mockRejectedValueOnce(new Error('fetch failed'));
    const offline = await actions.switch(event({ plan: 'b' }));
    expect(offline.data.error).toBe('The plan could not be changed. Try again.');

    apiRequest.mockRejectedValueOnce(failure(502, { detail: 'Billing is unavailable.' }));
    const down = await actions.keep(event({ plan: 'a' }));
    expect(down.status).toBe(502);
    expect(down.data.error).toBe('The plan could not be changed. Try again.');
  });
});
