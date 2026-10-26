import { describe, it, expect, vi } from 'vitest';

const portal = vi.hoisted(() => {
  class PortalError extends Error {
    declare status: number;
    declare data: any;

    constructor(status: number, data: any) {
      super('portal request failed');
      this.status = status;
      this.data = data;
    }
  }
  return { PortalError, failWith: 404 as number };
});

vi.mock('#lib/server/portal.js', () => ({
  ACCESS_COOKIE: 'access',
  ORG_COOKIE: 'org',
  PortalError: portal.PortalError,
  clearSession: () => {},
  loginPath: () => '/portal/login',
  createCase: async () => ({}),
  listArticles: async () => {
    throw new portal.PortalError(portal.failWith, { error: 'x' });
  }
}));

const { load } = await import('./+page.server.js');

async function run(status: number) {
  portal.failWith = status;
  const cookies = { get: () => 'token' };
  const url = new URL('http://localhost/portal/articles');
  try {
    await load({ cookies, url } as any);
  } catch (err) {
    return err;
  }
  return undefined;
}

describe('articles list when its module is off', () => {
  it('shows a plain not-found when the articles list answers 404', async () => {
    const err = await run(404);
    expect(err).toMatchObject({
      status: 404,
      body: { message: 'There is nothing to show here right now.' }
    });
  });

  it('still rethrows other portal errors as before', async () => {
    const err = await run(500);
    expect(err).toBeInstanceOf(portal.PortalError);
    expect((err as { status: number }).status).toBe(500);
  });
});
