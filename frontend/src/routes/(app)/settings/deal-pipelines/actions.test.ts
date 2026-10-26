import { describe, it, expect, vi, beforeEach } from 'vitest';

const apiRequest = vi.fn();
vi.mock('#lib/api-helpers.js', () => ({
  apiRequest: (...a: any[]) => apiRequest(...a)
}));

// Imports nothing from `$app/*`, so the standalone vitest config can load it.
const { actions, load } = await import('./+page.server.js');

/**
 * A JWT carrying the claims the API signs: `role` and the admin fact derived
 * from it. Only the payload is ever decoded.
 */
function token(role: string) {
  const payload = Buffer.from(
    JSON.stringify({ role, is_organization_admin: role === 'ADMIN' })
  ).toString('base64url');
  return `h.${payload}.s`;
}

function cookies(role = 'ADMIN') {
  return { get: (name: string) => (name === 'jwt_access' ? token(role) : undefined) };
}

function event(fields: Record<string, string>, role?: string) {
  const body = new FormData();
  for (const [key, value] of Object.entries(fields)) body.set(key, value);
  return {
    request: new Request('http://test/settings/deal-pipelines', { method: 'POST', body }),
    cookies: cookies(role)
  } as any;
}

const PIPELINES = {
  pipelines: [
    {
      id: 'p-1',
      name: 'Sales',
      is_default: true,
      stages: [{ id: 's-1', code: 'PROSPECTING', label: 'Prospecting', kind: 'open' }]
    },
    {
      id: 'p-2',
      name: 'Renewals',
      is_default: false,
      stages: [
        { id: 's-a', code: 'A', label: 'A', kind: 'open' },
        { id: 's-b', code: 'B', label: 'B', kind: 'won' },
        { id: 's-c', code: 'C', label: 'C', kind: 'lost' }
      ]
    }
  ]
};

describe('deal pipelines load', () => {
  beforeEach(() => apiRequest.mockReset());

  it('shows the requested pipeline, and can_edit for an admin', async () => {
    apiRequest.mockResolvedValueOnce(PIPELINES);
    const data = (await load({
      cookies: cookies('ADMIN'),
      url: new URL('http://t/?pipeline=p-2')
    } as any)) as any;
    expect(apiRequest.mock.calls[0][0]).toBe('/opportunities/pipelines/');
    expect(data.pipeline.id).toBe('p-2');
    expect(data.pipeline.stages.map((s: any) => s.kind)).toEqual(['open', 'won', 'lost']);
    expect(data.can_edit).toBe(true);
  });

  it('falls back to the default pipeline for an unknown id, and a member cannot edit', async () => {
    apiRequest.mockResolvedValueOnce(PIPELINES);
    const data = (await load({
      cookies: cookies('USER'),
      url: new URL('http://t/?pipeline=nope')
    } as any)) as any;
    expect(data.pipeline.id).toBe('p-1');
    expect(data.can_edit).toBe(false);
  });
});

describe('deal pipeline actions', () => {
  beforeEach(() => apiRequest.mockReset());

  it('turns a member 403 into a sentence, not the raw backend string', async () => {
    apiRequest.mockRejectedValueOnce(Object.assign(new Error('403'), { status: 403 }));
    const result = (await actions.renamePipeline(event({ id: 'p-2', name: 'X' }, 'USER'))) as any;
    expect(result.status).toBe(403);
    expect(result.data.renamePipeline.error).toBe('Only an admin can change deal pipelines.');
  });

  it('sends a new stage with blank days as null, never as 0', async () => {
    apiRequest.mockResolvedValueOnce({});
    await actions.createStage(
      event({ pipeline_id: 'p-2', label: 'Verbal yes', kind: 'open', expected_days: '5' })
    );
    expect(apiRequest.mock.calls[0][0]).toBe('/opportunities/pipelines/p-2/stages/');
    expect(apiRequest.mock.calls[0][1].body).toEqual({
      label: 'Verbal yes',
      kind: 'open',
      expected_days: 5,
      warning_days: null
    });
  });

  it.each([
    [{ label: '', kind: 'open' }, 'Give the stage a name.'],
    [{ label: 'X', kind: 'closed' }, 'Pick open, won or lost.'],
    [{ label: 'X', kind: 'open', expected_days: '0' }, 'Days are a whole number'],
    [{ label: 'X', kind: 'open', warning_days: '2.5' }, 'Days are a whole number']
  ])('refuses %j before calling the API', async (fields, message) => {
    const result = (await actions.createStage(event({ pipeline_id: 'p-2', ...fields }))) as any;
    expect(result.status).toBe(400);
    expect(result.data.stage.error).toContain(message);
    expect(apiRequest).not.toHaveBeenCalled();
  });

  it('reorders by sending every stage id once, read fresh from the API', async () => {
    apiRequest.mockResolvedValueOnce(PIPELINES.pipelines[1]).mockResolvedValueOnce({});
    await actions.moveStage(event({ pipeline_id: 'p-2', id: 's-c', direction: 'up' }));
    expect(apiRequest.mock.calls[0][0]).toBe('/opportunities/pipelines/p-2/');
    expect(apiRequest.mock.calls[1][0]).toBe('/opportunities/pipelines/p-2/stages/reorder/');
    expect(apiRequest.mock.calls[1][1].body).toEqual({ stage_ids: ['s-a', 's-c', 's-b'] });
  });

  it('does not call reorder for a move past the end', async () => {
    apiRequest.mockResolvedValueOnce(PIPELINES.pipelines[1]);
    await actions.moveStage(event({ pipeline_id: 'p-2', id: 's-a', direction: 'up' }));
    expect(apiRequest).toHaveBeenCalledTimes(1);
  });

  it("shows the server's refusal to delete a stage that still holds deals", async () => {
    apiRequest.mockRejectedValueOnce(
      Object.assign(new Error('400'), {
        status: 400,
        body: {
          error: true,
          errors: 'This stage still holds 2 deal(s). Move them to another stage first.'
        }
      })
    );
    const result = (await actions.deleteStage(event({ id: 's-a' }))) as any;
    expect(result.status).toBe(400);
    expect(result.data.stageList.error).toBe(
      'This stage still holds 2 deal(s). Move them to another stage first.'
    );
  });
});
