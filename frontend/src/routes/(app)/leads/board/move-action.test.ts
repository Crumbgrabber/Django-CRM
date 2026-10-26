import { describe, it, expect, vi, beforeEach } from 'vitest';

const apiRequest = vi.fn();
vi.mock('#lib/api-helpers.js', () => ({
  apiRequest: (...a: any[]) => apiRequest(...a)
}));

// This route module imports nothing from `$app/*`, so the standalone vitest
// config can load it (see the note in `vitest.config.js`).
const { actions } = await import('./+page.server.js');

function moveEvent(fields: Record<string, string>) {
  const body = new FormData();
  for (const [key, value] of Object.entries(fields)) body.set(key, value);
  return {
    request: new Request('http://test/leads/board?/move', { method: 'POST', body }),
    cookies: { get: () => 'token' }
  } as any;
}

describe('leads board move action', () => {
  beforeEach(() => {
    apiRequest.mockReset();
  });

  it('persists a move into a stage', async () => {
    apiRequest.mockResolvedValue({ error: false });
    const result = await actions.move(moveEvent({ id: 'l-1', stage_id: 's-2', below_id: 'l-3' }));
    expect(result).toEqual({ success: true });
    expect(apiRequest.mock.calls[0][1].body).toEqual({ stage_id: 's-2', below_lead_id: 'l-3' });
  });

  it('sends "No stage" as an explicit null stage_id', async () => {
    apiRequest.mockResolvedValue({ error: false });
    const result = await actions.move(moveEvent({ id: 'l-1', stage_id: 'unstaged' }));
    expect(result).toEqual({ success: true });
    expect(apiRequest.mock.calls[0][0]).toBe('/leads/l-1/move/');
    const body = apiRequest.mock.calls[0][1].body;
    expect(body).toEqual({ stage_id: null });
    expect('stage_id' in body).toBe(true);
  });

  it('refuses a request missing the lead or the stage', async () => {
    const result = (await actions.move(moveEvent({ id: 'l-1' }))) as any;
    expect(result.status).toBe(400);
    expect(apiRequest).not.toHaveBeenCalled();
  });

  it('keeps a 404 (a lead the caller may not edit) a 404, with a sentence', async () => {
    apiRequest.mockRejectedValue(Object.assign(new Error('Not found.'), { status: 404 }));
    const result = (await actions.move(moveEvent({ id: 'l-1', stage_id: 's-2' }))) as any;
    expect(result.status).toBe(404);
    expect(result.data.error).toBe('That lead is not one you can move.');
  });

  it('turns any other refusal into a 400 carrying the reason', async () => {
    apiRequest.mockRejectedValue(
      Object.assign(new Error('This lead is in the Inbound pipeline.'), { status: 400 })
    );
    const result = (await actions.move(moveEvent({ id: 'l-1', stage_id: 's-9' }))) as any;
    expect(result.status).toBe(400);
    expect(result.data.error).toBe('This lead is in the Inbound pipeline.');
  });
});
