import { describe, it, expect, vi, beforeEach } from 'vitest';

const apiRequest = vi.fn();
vi.mock('#lib/api-helpers.js', () => ({
  apiRequest: (...a: any[]) => apiRequest(...a)
}));

// Imports only `@sveltejs/kit` and `#lib`, so the standalone vitest config can
// load it (see the note in `vitest.config.js`).
const { actions } = await import('./+page.server.js');

/**
 * `_apply_tags` leaves an absent `tags` alone and REPLACES the article's tags
 * with the active ids in a present one. The form only draws a box per active
 * tag, so sending the ticked boxes on every save dropped any archived tag the
 * article carried. Tags now go only when the boxes changed.
 */

function saveEvent(entries: [string, string][]) {
  const body = new FormData();
  for (const [key, value] of entries) body.append(key, value);
  return {
    request: new Request('http://test/solutions/s1/edit?/save', { method: 'POST', body }),
    cookies: { get: () => 'token' },
    params: { id: 's1' }
  } as any;
}

async function save(entries: [string, string][]) {
  try {
    return await actions.save(saveEvent(entries));
  } catch (thrown: any) {
    return thrown;
  }
}

/** An article tagged Billing (active, has a box) and an archived tag (no box). */
const untouched = [
  ['title', 'Reset a password'],
  ['description', 'Open settings, then security, then reset.'],
  ['status', 'draft'],
  ['status_original', 'draft'],
  ['tags', 'tag-billing'],
  ['tags_original', 'tag-billing']
] as [string, string][];

describe('solution edit save', () => {
  beforeEach(() => {
    apiRequest.mockReset();
    apiRequest.mockResolvedValue({});
  });

  it('leaves tags out when the boxes are as they were, so an archived tag survives', async () => {
    const result = await save(untouched);
    expect(result.status).toBe(303);
    const [path, options] = apiRequest.mock.calls[0];
    expect(path).toBe('/cases/solutions/s1/');
    expect(options.method).toBe('PATCH');
    expect(options.body).not.toHaveProperty('tags');
    expect(options.body.title).toBe('Reset a password');
  });

  it('leaves tags out when the org has no active tags to draw', async () => {
    const result = await save(untouched.filter(([k]) => k !== 'tags' && k !== 'tags_original'));
    expect(result.status).toBe(303);
    expect(apiRequest.mock.calls[0][1].body).not.toHaveProperty('tags');
  });

  it('sends the ticked boxes once one changed', async () => {
    await save([...untouched, ['tags', 'tag-access']]);
    expect(apiRequest.mock.calls[0][1].body.tags).toEqual(['tag-billing', 'tag-access']);
  });

  it('sends an explicit empty list when the last box is unticked', async () => {
    await save(untouched.filter(([k]) => k !== 'tags'));
    expect(apiRequest.mock.calls[0][1].body.tags).toEqual([]);
  });

  it('echoes the ticked boxes on a rejected save, even when they were not sent', async () => {
    apiRequest.mockRejectedValue(Object.assign(new Error('x'), { status: 400, body: {} }));
    const result = (await save(untouched)) as any;
    expect(result.status).toBe(400);
    expect(result.data.values.tags).toEqual(['tag-billing']);
  });
});
