import { describe, it, expect, vi, beforeEach } from 'vitest';

const checkDuplicates = vi.fn();
vi.mock('#lib/server/v2/duplicates.js', () => ({
  checkDuplicates: (...a: any[]) => checkDuplicates(...a)
}));

const { POST } = await import('./+server.js');

function call(body: string) {
  return POST({
    params: { module: 'leads' },
    request: new Request('http://x/api/duplicates/leads', { method: 'POST', body }),
    cookies: { get: () => 'tok' }
  } as any);
}

beforeEach(() => checkDuplicates.mockReset());

describe('POST /api/duplicates/[module]', () => {
  it.each(['[1,2]', '"text"', 'null', '42', 'not json'])(
    'refuses a body that is not a JSON object: %s',
    async (body) => {
      const res = await call(body);
      expect(res.status).toBe(400);
      expect(await res.json()).toEqual({ duplicates: [] });
      expect(checkDuplicates).not.toHaveBeenCalled();
    }
  );

  it('forwards an object to the check', async () => {
    checkDuplicates.mockResolvedValueOnce([{ id: 'a', name: 'Ann' }]);
    const res = await call('{"email":"ann@example.com"}');
    expect(await res.json()).toEqual({ duplicates: [{ id: 'a', name: 'Ann' }] });
    expect(checkDuplicates.mock.calls[0][1]).toBe('leads');
    expect(checkDuplicates.mock.calls[0][2]).toEqual({ email: 'ann@example.com' });
  });
});
