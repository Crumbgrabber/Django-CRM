import { describe, it, expect, vi, beforeEach } from 'vitest';

const apiRequest = vi.fn();
vi.mock('#lib/api-helpers.js', () => ({
  apiRequest: (...a: any[]) => apiRequest(...a)
}));

const { actions } = await import('./+page.server.js');

function event(fields: Record<string, string>) {
  const body = new FormData();
  for (const [key, value] of Object.entries(fields)) body.set(key, value);
  return {
    request: new Request('http://test/settings/web-forms', { method: 'POST', body }),
    cookies: { get: () => undefined }
  } as any;
}

beforeEach(() => apiRequest.mockReset());

describe('web form create', () => {
  it('creates a web form for the target sent and refuses one without a target', async () => {
    apiRequest.mockResolvedValue({ id: 'f-1' });
    await expect(
      actions.create(event({ name: 'Contact', target: 'ticket' }))
    ).rejects.toMatchObject({ status: 303, location: '/settings/web-forms/f-1' });
    expect(apiRequest.mock.calls[0][1].body).toMatchObject({ name: 'Contact', target: 'ticket' });

    apiRequest.mockClear();
    const refused = (await actions.create(event({ name: 'Contact' }))) as any;
    expect(refused).toMatchObject({ status: 400 });
    expect(refused.data.create.error).toBeTruthy();
    expect(apiRequest).not.toHaveBeenCalled();
  });
});
