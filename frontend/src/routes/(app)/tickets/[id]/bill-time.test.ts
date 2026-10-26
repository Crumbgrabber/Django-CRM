/**
 * Bill time on a ticket: the entries are read again on the server, never
 * taken from the form, and only the stopped, billable, unbilled ones go.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';

let respond: (path: string, options: any) => Promise<any> = async () => {
  throw new Error('offline');
};
let calls: { path: string; options: any }[] = [];
vi.mock('#lib/api-helpers.js', () => ({
  apiRequest: (path: string, options: any) => {
    calls.push({ path, options });
    return respond(path, options);
  }
}));

const { actions } = await import('./+page.server.js');
const billTime = (actions as any).billTime;

const ENTRIES = [
  { id: 'e1', ended_at: 'x', billable: true, duration_minutes: 30, currency: 'USD' },
  { id: 'e2', ended_at: 'x', billable: true, invoiced: true, duration_minutes: 30 },
  { id: 'e3', ended_at: null, billable: true, duration_minutes: 0 },
  { id: 'e4', ended_at: 'x', billable: true, duration_minutes: 15, currency: 'USD' }
];

const post = (fields: Record<string, string>) => {
  const body = new FormData();
  for (const [k, v] of Object.entries(fields)) body.set(k, v);
  return {
    cookies: { get: () => 'token' },
    params: { id: 't1' },
    request: new Request('http://x/tickets/t1', { method: 'POST', body })
  };
};

beforeEach(() => {
  calls = [];
});

describe('billing a ticket’s time', () => {
  it('bills the entries that are ready, grouped as asked, and opens the draft', async () => {
    respond = async (path) => {
      if (path === '/cases/t1/time-entries/') return ENTRIES;
      if (path === '/invoices/from-time-entries/') return { invoice_id: 'i1' };
      throw new Error('unexpected');
    };
    await expect(
      billTime(post({ account_id: 'a1', group_by: 'person', entry_ids: 'e2' }))
    ).rejects.toMatchObject({ status: 303, location: '/invoices/i1' });
    const sent = calls.find((c) => c.path === '/invoices/from-time-entries/');
    expect(sent?.options.body).toEqual({
      account_id: 'a1',
      entry_ids: ['e1', 'e4'],
      group_by: 'person'
    });
  });

  it('says so when nothing is ready, without asking to bill', async () => {
    respond = async (path) => {
      if (path === '/cases/t1/time-entries/') return [ENTRIES[1], ENTRIES[2]];
      throw new Error('unexpected');
    };
    const result = await billTime(post({ account_id: 'a1' }));
    expect(result.status).toBe(400);
    expect(result.data.timeError).toBe('Nothing on this ticket is ready to bill.');
    expect(calls.some((c) => c.path === '/invoices/from-time-entries/')).toBe(false);
  });

  it('shows a member the API’s refusal', async () => {
    respond = async (path) => {
      if (path === '/cases/t1/time-entries/') return ENTRIES;
      throw Object.assign(new Error('HTTP 403'), {
        status: 403,
        body: { error: true, message: 'Only admins can create invoices from time entries.' }
      });
    };
    const result = await billTime(post({ account_id: 'a1' }));
    expect(result.status).toBe(403);
    expect(result.data.timeError).toMatch(/Only admins/);
  });
});

describe('a timer already running elsewhere', () => {
  it('names the project it runs on, so the panel can link to it', async () => {
    const startTimer = (actions as any).startTimer;
    respond = async () => {
      throw Object.assign(new Error('HTTP 409'), {
        status: 409,
        body: {
          error: true,
          errors: 'You already have a timer running.',
          running_case_id: null,
          running_project_id: 'pr1'
        }
      });
    };
    const result = await startTimer({ cookies: { get: () => 'token' }, params: { id: 't1' } });
    expect(result.status).toBe(409);
    expect(result.data).toMatchObject({ runningProjectId: 'pr1', runningTicketId: null });
  });
});
