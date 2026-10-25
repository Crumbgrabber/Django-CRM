/**
 * A task's project stays a choice on its forms when the picker's first 200
 * projects do not hold it, so the form neither clears it nor blocks on it.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';

const related = vi.hoisted(() => ({ value: /** @type {any} */ (null) }));
const asked = vi.hoisted(() => /** @type {string[]} */ ([]));
const ID = '4d60686d-bd3d-4e33-b114-ab36f194a6cd';

vi.mock('#lib/server/v2/modules.js', () => ({
  getModules: async () => ({
    canEdit: false,
    modules: [{ key: 'projects', label: 'Projects', available: true }]
  })
}));
vi.mock('#lib/server/v2/tasks.js', () => ({
  getTaskFormOptions: async () => ({ owners: [], accounts: [] }),
  getTask: async () => ({ task: { id: 'k1', title: 'x', related: related.value } }),
  createTask: async () => ({}),
  updateTask: async () => ({})
}));
vi.mock('#lib/server/v2/tickets.js', () => ({ listTickets: async () => ({ results: [] }) }));
vi.mock('#lib/server/v2/deals.js', () => ({ listDeals: async () => ({ results: [] }) }));
vi.mock('#lib/server/v2/leads.js', () => ({ listLeads: async () => ({ results: [] }) }));
vi.mock('#lib/server/v2/projects.js', () => ({
  projectChoices: async () => [{ id: 'p1', name: 'Listed' }],
  projectChoice: async (/** @type {any} */ _e, /** @type {string} */ id) => {
    asked.push(id);
    return id === ID ? { id: ID, name: 'Far down the list' } : null;
  }
}));
vi.mock('#lib/server/v2/record-custom-fields.js', () => ({
  fieldsForNew: async () => [],
  readCustomFields: async () => ({ values: undefined, definitions: [] }),
  saveRefusal: () => ({ error: '', fieldErrors: {} })
}));

const newLoad = (await import('./new/+page.server.js')).load;
const editLoad = (await import('./[id]/edit/+page.server.js')).load;

/** @param {string} [search] */
const event = (search = '') =>
  /** @type {any} */ ({
    cookies: {},
    params: { id: 'k1' },
    locals: {},
    url: new URL(`http://x/tasks/new${search}`)
  });

beforeEach(() => {
  related.value = null;
  asked.length = 0;
});

describe('the task project picker', () => {
  it('keeps the task’s own project on the edit form when it is not listed', async () => {
    related.value = { kind: 'project', id: ID, name: 'Far down the list', href: '' };
    const data = /** @type {any} */ (await editLoad(event()));
    expect(data.parents.project).toEqual([
      { id: ID, name: 'Far down the list' },
      { id: 'p1', name: 'Listed' }
    ]);
    expect(data.form).toMatchObject({ parent_kind: 'project', parent_id: ID });
  });

  it('prefills a listed project without another read', async () => {
    const data = /** @type {any} */ (await newLoad(event('?project=p1')));
    expect(data.prefill).toEqual({ parent_kind: 'project', project: 'p1' });
    expect(asked).toEqual([]);
  });

  it('reads and offers a ?project= past the first 200, and ignores one it cannot see', async () => {
    const data = /** @type {any} */ (await newLoad(event(`?project=${ID}`)));
    expect(data.prefill).toEqual({ parent_kind: 'project', project: ID });
    expect(data.parents.project[0]).toEqual({ id: ID, name: 'Far down the list' });

    const hidden = /** @type {any} */ (
      await newLoad(event('?project=5d60686d-bd3d-4e33-b114-ab36f194a6cd'))
    );
    expect(hidden.prefill).toBeNull();
    expect(hidden.parents.project).toEqual([{ id: 'p1', name: 'Listed' }]);
  });
});
