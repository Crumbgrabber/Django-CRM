import { describe, it, expect, vi, beforeEach } from 'vitest';

const apiRequest = vi.fn();
vi.mock('#lib/api-helpers.js', () => ({
  apiRequest: (/** @type {any[]} */ ...a) => apiRequest(...a)
}));

const { actions } = await import('./+page.server.js');

/** @param {Record<string, string>} fields */
function createEvent(fields) {
  const body = new FormData();
  for (const [key, value] of Object.entries(fields)) body.set(key, value);
  return /** @type {any} */ ({
    request: new Request('http://test/leads/new?/create', { method: 'POST', body }),
    cookies: { get: () => 'token' }
  });
}

describe('new lead create action', () => {
  beforeEach(() => {
    apiRequest.mockReset();
  });

  it('opens the lead it just created', async () => {
    apiRequest.mockResolvedValue({ error: false, message: 'Lead Created Successfully', id: 'l-9' });
    await expect(actions.create(createEvent({ first_name: 'Ada' }))).rejects.toMatchObject({
      status: 303,
      location: '/leads/l-9'
    });
    expect(apiRequest.mock.calls[0][0]).toBe('/leads/');
  });

  it('keeps the form when the API refuses it', async () => {
    apiRequest.mockRejectedValue({ status: 400, body: { error: true, errors: {} } });
    const result = await actions.create(createEvent({ first_name: 'Ada' }));
    expect(result).toMatchObject({ status: 400, data: { values: { first_name: 'Ada' } } });
  });
});
