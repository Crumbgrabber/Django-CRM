import { describe, it, expect, vi } from 'vitest';

const refusal = vi.hoisted(() => ({ value: /** @type {any} */ (null) }));

vi.mock('#lib/server/v2/tasks.js', () => ({
  FILTER_FIELDS: [],
  listTasks: async () => ({ results: [], totals: {}, owners: [] }),
  setTaskDone: async () => {
    throw refusal.value;
  }
}));
vi.mock('#lib/server/v2/org-people.js', () => ({
  getOrgPeopleAndTeams: async () => ({ people: [] }),
  resolveMe: () => null
}));

const { actions } = await import('./+page.server.js');
const toggle = /** @type {any} */ (actions).toggle;

/** A list-row tick, as the page posts it. */
function event() {
  const body = new FormData();
  body.set('id', 't1');
  body.set('done', 'true');
  return /** @type {any} */ ({ request: { formData: async () => body }, cookies: {} });
}

/**
 * A refused tick shows the API's reason as a sentence. A PATCH 400 carries a
 * per-field `errors` map, which this action used to pass to the page as is, so
 * the row printed "[object Object]".
 */
describe('task list tick refused', () => {
  it('says what the API refused, as text', async () => {
    refusal.value = Object.assign(new Error('status: Not a valid choice.'), {
      status: 400,
      body: { error: true, errors: { status: ['Not a valid choice.'] } }
    });

    const result = await toggle(event());

    expect(result.status).toBe(400);
    expect(result.data.error).toBe('status: Not a valid choice.');
  });

  it('keeps its own words for a 403', async () => {
    refusal.value = Object.assign(new Error('Forbidden'), { status: 403, body: {} });

    const result = await toggle(event());

    expect(result.status).toBe(403);
    expect(result.data.error).toBe('That task is not yours to change.');
  });
});
