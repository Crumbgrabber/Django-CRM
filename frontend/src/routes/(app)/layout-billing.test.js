/**
 * The shell asks whether this install offers billing and hands the answer to
 * every page; a 404 is remembered, and any failure leaves it null with the
 * shell intact, so no page mentions billing there.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';

/** @type {(endpoint: string) => Promise<any>} */
let respond = async () => {
  throw new Error('offline');
};

vi.mock('#lib/api-helpers.js', () => ({
  /** @param {string} endpoint */
  apiRequest: (endpoint) => respond(endpoint)
}));

const { load } = await import('./+layout.server.js');
const { resetBillingAbsentMemo } = await import('#lib/server/v2/billing.js');

const event = () =>
  /** @type {any} */ ({
    locals: { org: { name: 'Acme' }, org_settings: {}, profile: {} },
    cookies: { get: () => 'token' }
  });

/** @type {string[]} */
let asked = [];

/** @param {() => Promise<any>} billing */
function route(billing) {
  respond = async (endpoint) => {
    if (endpoint.startsWith('/billing/')) {
      asked.push(endpoint);
      return billing();
    }
    throw new Error('offline');
  };
}

const notFound = async () => {
  throw Object.assign(new Error('Not found'), { status: 404 });
};

describe('the shell billing answer', () => {
  beforeEach(() => {
    asked = [];
    resetBillingAbsentMemo();
  });

  it('carries the plan the server names', async () => {
    route(async () => ({ plan: { key: 'a', name: 'Plan A' }, can_manage: false }));
    const shell = /** @type {any} */ (await load(event()));
    expect(shell.billing.plan.name).toBe('Plan A');
    expect(shell.billing.plans).toBeNull();
  });

  it('carries null where billing is not offered, and asks once per process', async () => {
    route(notFound);
    expect(/** @type {any} */ (await load(event())).billing).toBeNull();
    expect(/** @type {any} */ (await load(event())).billing).toBeNull();
    expect(asked).toEqual(['/billing/']);
  });

  it('still loads the shell when the billing call fails', async () => {
    route(async () => {
      throw Object.assign(new Error('boom'), { status: 500 });
    });
    const shell = /** @type {any} */ (await load(event()));
    expect(shell.billing).toBeNull();
    expect(shell.org.name).toBe('Acme');
  });
});
