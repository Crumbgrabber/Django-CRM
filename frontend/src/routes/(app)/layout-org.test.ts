/**
 * The shell hands every page the org's timezone from the JWT's org claim, so
 * a form's "today" default (`todayIn`) is the org's day without a fetch.
 */
import { describe, it, expect, vi } from 'vitest';

// Every count and the terminology lookup fail; the shell tolerates that.
vi.mock('#lib/api-helpers.js', () => ({
  apiRequest: async () => {
    throw new Error('offline');
  }
}));

const { load } = await import('./+layout.server.js');

function event(orgSettings: any) {
  return {
    locals: { org: { name: 'Acme' }, org_settings: orgSettings, profile: {} },
    cookies: { get: () => 'token' }
  } as any;
}

describe('the shell org', () => {
  it('carries the org timezone from the token claim', async () => {
    const shell = (await load(event({ default_currency: 'INR', timezone: 'Asia/Kolkata' }))) as any;
    expect(shell.org.timezone).toBe('Asia/Kolkata');
  });

  it('is UTC for a token minted before the claim existed', async () => {
    const shell = (await load(event({ default_currency: 'USD' }))) as any;
    expect(shell.org.timezone).toBe('UTC');
  });
});
