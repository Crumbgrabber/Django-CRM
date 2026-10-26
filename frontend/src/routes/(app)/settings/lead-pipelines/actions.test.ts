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
    request: new Request('http://test/settings/lead-pipelines', { method: 'POST', body }),
    cookies: cookies(role)
  } as any;
}

const STAGES = [
  { id: 's-b', name: 'B', order: 2 },
  { id: 's-a', name: 'A', order: 1 },
  { id: 's-c', name: 'C', order: 3 }
];

describe('lead pipelines load', () => {
  beforeEach(() => apiRequest.mockReset());

  it('shows the requested pipeline, its stages in order, and can_edit for an admin', async () => {
    apiRequest
      .mockResolvedValueOnce({
        pipelines: [
          { id: 'p-1', name: 'Inbound', stage_count: 3 },
          { id: 'p-2', name: 'Outbound', stage_count: 0 }
        ]
      })
      .mockResolvedValueOnce({ id: 'p-2', name: 'Outbound', stages: STAGES });
    const data = (await load({
      cookies: cookies('ADMIN'),
      url: new URL('http://t/?pipeline=p-2')
    } as any)) as any;
    expect(apiRequest.mock.calls[1][0]).toBe('/leads/pipelines/p-2/');
    expect(data.pipeline.stages.map((s: any) => s.id)).toEqual(['s-a', 's-b', 's-c']);
    expect(data.can_edit).toBe(true);
  });

  it('falls back to the first pipeline for an unknown id, and a member cannot edit', async () => {
    apiRequest
      .mockResolvedValueOnce({ pipelines: [{ id: 'p-1', name: 'Inbound' }] })
      .mockResolvedValueOnce({ id: 'p-1', name: 'Inbound', stages: [] });
    const data = (await load({
      cookies: cookies('USER'),
      url: new URL('http://t/?pipeline=nope')
    } as any)) as any;
    expect(apiRequest.mock.calls[1][0]).toBe('/leads/pipelines/p-1/');
    expect(data.can_edit).toBe(false);
  });

  it('makes one call and no detail request when there are no pipelines', async () => {
    apiRequest.mockResolvedValueOnce({ pipelines: [] });
    const data = (await load({ cookies: cookies(), url: new URL('http://t/') } as any)) as any;
    expect(data.pipeline).toBeNull();
    expect(apiRequest).toHaveBeenCalledTimes(1);
  });
});

describe('lead pipelines actions', () => {
  beforeEach(() => apiRequest.mockReset());

  it('reorders by sending every stage id, read fresh, with the one swapped', async () => {
    apiRequest.mockResolvedValueOnce({ id: 'p-1', stages: STAGES }).mockResolvedValueOnce({});
    const result = await actions.moveStage(
      event({ pipeline_id: 'p-1', id: 's-c', direction: 'up' })
    );
    expect(result).toEqual({ moved: true });
    const [url, options] = apiRequest.mock.calls[1];
    expect(url).toBe('/leads/pipelines/p-1/stages/reorder/');
    expect(options.body).toEqual({ stage_ids: ['s-a', 's-c', 's-b'] });
  });

  it('does not call reorder for a stage already at the top', async () => {
    apiRequest.mockResolvedValueOnce({ id: 'p-1', stages: STAGES });
    await actions.moveStage(event({ pipeline_id: 'p-1', id: 's-a', direction: 'up' }));
    expect(apiRequest).toHaveBeenCalledTimes(1);
  });

  it('refuses a direction that is not up or down without calling the API', async () => {
    const result = (await actions.moveStage(
      event({ pipeline_id: 'p-1', id: 's-a', direction: 'sideways' })
    )) as any;
    expect(result.status).toBe(400);
    expect(apiRequest).not.toHaveBeenCalled();
  });

  it('sends a cleared status mapping as null and the probability as a number', async () => {
    apiRequest.mockResolvedValueOnce({});
    await actions.updateStage(
      event({
        id: 's-1',
        name: ' Qualified ',
        stage_type: 'won',
        maps_to_status: '',
        win_probability: '40'
      })
    );
    const [url, options] = apiRequest.mock.calls[0];
    expect(url).toBe('/leads/stages/s-1/');
    expect(options.method).toBe('PUT');
    expect(options.body).toEqual({
      name: 'Qualified',
      stage_type: 'won',
      maps_to_status: null,
      win_probability: 40
    });
  });

  it('adds a stage without an order so the API puts it last', async () => {
    apiRequest.mockResolvedValueOnce({});
    await actions.createStage(
      event({ pipeline_id: 'p-1', name: 'Demo', stage_type: 'open', maps_to_status: 'in process' })
    );
    const [url, options] = apiRequest.mock.calls[0];
    expect(url).toBe('/leads/pipelines/p-1/stages/');
    expect(options.body).not.toHaveProperty('order');
    expect(options.body.maps_to_status).toBe('in process');
  });

  it('shows the API sentence when a stage delete is refused for its leads', async () => {
    apiRequest.mockRejectedValueOnce(
      Object.assign(
        new Error('This stage still has 2 lead(s). Move them to another stage first.'),
        { status: 400 }
      )
    );
    const result = (await actions.deleteStage(event({ id: 's-1' }))) as any;
    expect(result.status).toBe(400);
    expect(result.data.stageList.error).toBe(
      'This stage still has 2 lead(s). Move them to another stage first.'
    );
  });

  it('turns a 403 into the admin-only sentence', async () => {
    apiRequest.mockRejectedValueOnce(
      Object.assign(new Error('Permission denied'), { status: 403 })
    );
    const result = (await actions.deletePipeline(event({ id: 'p-1' }, 'USER'))) as any;
    expect(result.status).toBe(403);
    expect(result.data.deletePipeline.error).toBe('Only an admin can change lead pipelines.');
  });

  it('refuses a blank pipeline name without calling the API', async () => {
    const result = (await actions.createPipeline(event({ name: '   ' }))) as any;
    expect(result.status).toBe(400);
    expect(apiRequest).not.toHaveBeenCalled();
  });

  it('creates a pipeline with its default stages and lands on it', async () => {
    apiRequest.mockResolvedValueOnce({ id: 'p-9' });
    await expect(actions.createPipeline(event({ name: 'Partners' }))).rejects.toMatchObject({
      status: 303,
      location: '/settings/lead-pipelines?pipeline=p-9'
    });
    expect(apiRequest.mock.calls[0][1].body).toEqual({
      name: 'Partners',
      create_default_stages: true
    });
  });
});
