/**
 * The tickets list's bulk actions report a refused batch instead of throwing.
 *
 * The API refuses a batch outright for a few reasons, a batch over 200 ids
 * among them (issue #829). The actions let that throw, which surfaced as an
 * error page instead of a sentence in the bulk bar's banner.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';

const apiRequest = vi.fn();
vi.mock('#lib/api-helpers.js', () => ({
  apiRequest: (...a: any[]) => apiRequest(...a)
}));

const { actions } = await import('../../../routes/(app)/tickets/+page.server.js');

function actionEvent(entries: [string, string][]) {
  const body = new FormData();
  for (const [key, value] of entries) body.append(key, value);
  return {
    request: new Request('http://test/tickets', { method: 'POST', body }),
    cookies: { get: () => 'token' }
  } as any;
}

const REFUSAL = 'Select at most 200 tickets at a time.';

/** What `apiRequest` throws for the `{error: true, errors: "<sentence>"}` envelope. */
function refused() {
  return Object.assign(new Error(`errors: ${REFUSAL}`), {
    status: 400,
    body: { error: true, errors: REFUSAL }
  });
}

const UPDATE = [
  ['ids', 'a'],
  ['field', 'priority'],
  ['value', 'Urgent']
] as [string, string][];
const DELETE = [['ids', 'a']] as [string, string][];

const REFUSABLE: ['bulkUpdate' | 'bulkDelete', [string, string][]][] = [
  ['bulkUpdate', UPDATE],
  ['bulkDelete', DELETE]
];

describe('ticket bulk actions', () => {
  beforeEach(() => apiRequest.mockReset());

  it.each(REFUSABLE)(
    '%s returns the API sentence when the batch is refused',
    async (name, entries) => {
      apiRequest.mockRejectedValueOnce(refused());
      const result = (await actions[name](actionEvent(entries))) as any;
      expect(result.status).toBe(400);
      expect(result.data.message).toBe(REFUSAL);
    }
  );

  it('a batch that runs still returns its summary', async () => {
    apiRequest.mockResolvedValueOnce({ results: [{ id: 'a', status: 'updated' }] });
    const result = (await actions.bulkUpdate(actionEvent(UPDATE))) as any;
    expect(result.ok).toBe(true);
    expect(result.summary.updated).toBe(1);
  });
});
