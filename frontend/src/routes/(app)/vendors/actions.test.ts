import { beforeEach, expect, it, vi } from 'vitest';
const apiRequest = vi.fn();
vi.mock('#lib/api-helpers.js', () => ({ apiRequest: (...args: unknown[]) => apiRequest(...args) }));
const create = (await import('./new/+page.server.js')).actions.save;
const update = (await import('./[id]/edit/+page.server.js')).actions.save;
const remove = (await import('./[id]/+page.server.js')).actions.delete;
function event(entries: [string, string][] = []) {
  const body = new FormData();
  for (const [key, value] of entries) body.append(key, value);
  return {
    cookies: { get: () => 'token' },
    params: { id: 'one' },
    request: new Request('http://test/vendors', { method: 'POST', body })
  } as any;
}
beforeEach(() => {
  apiRequest.mockReset();
});
it('redirects to the created vendor', async () => {
  apiRequest.mockResolvedValue({ id: 'one' });
  await expect(create(event([['name', 'Hosting']]))).rejects.toMatchObject({
    status: 303,
    location: '/vendors/one'
  });
});
it('returns submitted values and error after a refused save', async () => {
  apiRequest.mockRejectedValue(
    Object.assign(new Error('name: Already exists.'), {
      status: 400,
      body: { name: ['Already exists.'] }
    })
  );
  const response = await update(event([['name', 'Hosting']]));
  expect(response).toMatchObject({ status: 400, data: { values: { name: 'Hosting' } } });
  expect(response?.data.error).toContain('Already exists');
});
it.each([
  ['create', create, '/vendors/', 'POST'],
  ['update', update, '/vendors/one/', 'PATCH']
] as const)(
  '%s sends explicit empty assignments when all selections are cleared',
  async (_, save, url, method) => {
    apiRequest.mockResolvedValue({ id: 'one' });
    await expect(
      save(
        event([
          ['name', 'Hosting'],
          ['assigned_to_present', '1'],
          ['teams_present', '1']
        ])
      )
    ).rejects.toMatchObject({ status: 303, location: '/vendors/one' });
    expect(apiRequest).toHaveBeenCalledWith(
      url,
      { method, body: { name: 'Hosting', is_active: false, assigned_to: [], teams: [] } },
      expect.objectContaining({ params: { id: 'one' } })
    );
  }
);
it('returns a delete refusal without redirecting', async () => {
  apiRequest.mockRejectedValue(
    Object.assign(new Error('Forbidden.'), { status: 403, body: { detail: 'Forbidden.' } })
  );
  expect(await remove(event())).toMatchObject({ status: 400, data: { error: 'Forbidden.' } });
});
it('redirects to the list after deletion', async () => {
  apiRequest.mockResolvedValue(undefined);
  await expect(remove(event())).rejects.toMatchObject({ status: 303, location: '/vendors' });
});
