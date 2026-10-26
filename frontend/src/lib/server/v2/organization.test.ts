import { describe, expect, it, vi } from 'vitest';

vi.mock('#lib/api-helpers.js', () => ({ apiRequest: vi.fn() }));

const { viewerIsAdmin, getNumbering } = await import('./organization.js');
const { apiRequest } = (await import('#lib/api-helpers.js')) as any;

function cookiesWith(claims: Record<string, unknown> | null) {
  const token =
    claims === null
      ? undefined
      : `h.${Buffer.from(JSON.stringify(claims)).toString('base64url')}.s`;
  return {
    get: (name: string) => (name === 'jwt_access' ? token : undefined)
  } as any;
}

describe('viewerIsAdmin', () => {
  it('reads the signed admin fact, not the role', () => {
    expect(viewerIsAdmin(cookiesWith({ role: 'ADMIN', is_organization_admin: true }))).toBe(true);
    expect(viewerIsAdmin(cookiesWith({ role: 'USER', is_organization_admin: true }))).toBe(true);
    expect(viewerIsAdmin(cookiesWith({ role: 'USER', is_organization_admin: false }))).toBe(false);
    expect(viewerIsAdmin(cookiesWith({ role: 'ADMIN' }))).toBe(false);
  });

  it('is false with no token or an undecodable one', () => {
    expect(viewerIsAdmin(cookiesWith(null))).toBe(false);
    expect(viewerIsAdmin({ get: () => 'not-a-jwt' } as any)).toBe(false);
  });
});

describe('getNumbering', () => {
  const cookies = { get: () => 'token' } as any;

  it("reads the org's numbering and nothing else", async () => {
    apiRequest.mockResolvedValueOnce({
      company_name: 'Acme',
      tax_id: 'GB123',
      invoice_number_prefix: 'INVNSD-',
      estimate_number_prefix: 'ESTNSD-',
      number_date_part: 'YEAR',
      number_padding: 5,
      invoice_number_start: 1
    });
    expect(await getNumbering({ cookies })).toEqual({
      invoice_number_prefix: 'INVNSD-',
      estimate_number_prefix: 'ESTNSD-',
      number_date_part: 'YEAR',
      number_padding: 5,
      invoice_number_start: 1
    });
    expect(apiRequest.mock.lastCall[0]).toBe('/org/settings/');
  });

  it('is null when the read fails, so a form loses its preview and not itself', async () => {
    apiRequest.mockRejectedValueOnce(Object.assign(new Error('down'), { status: 502 }));
    expect(await getNumbering({ cookies })).toBeNull();
  });
});
