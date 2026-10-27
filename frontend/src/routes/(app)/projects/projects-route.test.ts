/**
 * The project pages: the module guard (including an API that does not list
 * Projects), what the detail load asks for by module and role, and the bill,
 * amount and comment actions.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';

let respond: (path: string, options: any) => Promise<any> = async () => {
  throw new Error('offline');
};
let asked: string[] = [];
vi.mock('#lib/api-helpers.js', () => ({
  apiRequest: (path: string, options: any) => {
    asked.push(path);
    return respond(path, options);
  }
}));

const { moduleGuard } = await import('#lib/server/v2/modules.js');
const { load, actions } = await import('./[id]/+page.server.js');

const row = (key: string, available: boolean = true) => ({
  key,
  label: key,
  available,
  enabled: available
});

const PROJECT = {
  id: 'pr1',
  name: 'Rebuild',
  account: { id: 'a1', name: 'Acme' },
  deal: null,
  status: 'active',
  billing_type: 'fixed_fee',
  currency: 'EUR',
  budget_hours: null,
  budget_amount: '12000.00',
  hourly_rate: null,
  assigned_to: [],
  tags: [],
  burn: {},
  rates: [],
  comments: [],
  attachments: [],
  invoices: [],
  can_edit: true,
  can_delete: true,
  can_bill: true
};

function api({
  modules = [row('projects'), row('timesheet'), row('invoices'), row('tasks')],
  project = PROJECT,
  extra
}: { modules?: any[] | null; project?: any; extra?: (path: string, options: any) => any } = {}) {
  respond = async (path, options) => {
    if (path === '/org/modules/') {
      if (modules === null) throw Object.assign(new Error('down'), { status: 500 });
      return { modules, can_edit: false };
    }
    const handled = extra?.(path, options);
    if (handled !== undefined) return handled;
    if (path === '/projects/pr1/') return project;
    if (path.startsWith('/projects/pr1/time-entries/')) return [];
    if (path.startsWith('/projects/pr1/unbilled/')) {
      return { entry_count: 2, hours: '3.00', value: '300.00', currency: 'EUR' };
    }
    if (path.startsWith('/tasks/')) return { tasks: [] };
    if (path.startsWith('/custom-fields/')) return { definitions: [] };
    throw Object.assign(new Error('unexpected'), { status: 500 });
  };
}

const event = (search: string = '') =>
  ({
    cookies: { get: () => 'token' },
    params: { id: 'pr1' },
    locals: { user: { id: 'u1' }, org_settings: { timezone: 'UTC' } },
    url: new URL(`http://x/projects/pr1${search}`),
    route: { id: '/(app)/projects/[id]' }
  }) as any;

const post = (fields: Record<string, string>) => {
  const body = new FormData();
  for (const [k, v] of Object.entries(fields)) body.set(k, v);
  return {
    ...event(),
    request: new Request('http://x/projects/pr1', { method: 'POST', body })
  } as any;
};

beforeEach(() => {
  asked = [];
});

describe('the projects module guard', () => {
  it('serves the pages while the list carries Projects', async () => {
    api();
    expect(await moduleGuard(event())).toEqual({});
  });

  it('answers as an off module where the API does not list Projects at all', async () => {
    api({ modules: [row('timesheet'), row('invoices')] });
    await expect(moduleGuard(event())).rejects.toMatchObject({
      status: 404,
      body: { code: 'module_off', module: 'projects', label: 'Projects' }
    });
  });

  it('answers as an off module where an admin switched it off', async () => {
    api({ modules: [row('projects', false)] });
    await expect(moduleGuard(event())).rejects.toMatchObject({
      status: 404,
      body: { code: 'module_off', module: 'projects' }
    });
  });
});

describe('the project load', () => {
  it('asks for the time and tasks while their modules are on, and no preview unasked', async () => {
    api();
    const data = (await load(event())) as any;
    expect(asked).toContain('/projects/pr1/time-entries/');
    expect(asked.some((p) => p.startsWith('/tasks/?') && p.includes('project=pr1'))).toBe(true);
    expect(asked.some((p) => p.includes('/unbilled/'))).toBe(false);
    expect(data.time.entries).toEqual([]);
    expect(data.offers).toEqual({
      billTime: true,
      billRetainer: false,
      invoiceAmount: true
    });
  });

  it('leaves the time out while Timesheet is off, and with it Bill time', async () => {
    api({ modules: [row('projects'), row('timesheet', false), row('invoices'), row('tasks')] });
    const data = (await load(event('?bill=1'))) as any;
    expect(asked.some((p) => p.includes('time-entries'))).toBe(false);
    expect(data.time.entries).toBeNull();
    expect(data.offers.billTime).toBe(false);
    expect(data.bill.open).toBe(false);
  });

  it('opens the preview for an admin, dated today by default', async () => {
    api();
    const data = (await load(event('?bill=1'))) as any;
    expect(data.bill.open).toBe(true);
    expect(data.bill.upTo).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    expect(data.bill.unbilled).toMatchObject({ entry_count: 2, value: 300 });
  });

  it('never asks a member for the admin-only preview', async () => {
    api({ project: { ...PROJECT, can_bill: false } });
    const data = (await load(event('?bill=1&up_to=2026-10-31'))) as any;
    expect(asked.some((p) => p.includes('/unbilled/'))).toBe(false);
    expect(data.bill.open).toBe(false);
    expect(data.offers).toEqual({
      billTime: false,
      billRetainer: false,
      invoiceAmount: false
    });
  });

  it('offers the retainer bill, not Bill time, on a retainer that can bill now', async () => {
    const usage = {
      month: '2026-10-01',
      used_hours: '4.00',
      available_hours: '10.00',
      overage_hours: '0.00',
      billable_now: true
    };
    api({ project: { ...PROJECT, billing_type: 'retainer', retainer_usage: usage } });
    const data = (await load(event())) as any;
    expect(data.offers).toEqual({ billTime: false, billRetainer: true, invoiceAmount: false });
    expect(data.retainerUsage).toMatchObject({ month: '2026-10-01', used_hours: 4 });
  });

  it('never opens Bill time on a retainer, even with ?bill=1', async () => {
    api({ project: { ...PROJECT, billing_type: 'retainer' } });
    const data = (await load(event('?bill=1'))) as any;
    expect(data.bill.open).toBe(false);
    expect(asked.some((p) => p.includes('/unbilled/'))).toBe(false);
  });

  it('offers no retainer bill when the API says nothing is billable, or to a member', async () => {
    const usage = {
      month: '2026-10-01',
      used_hours: '0.00',
      available_hours: null,
      overage_hours: '0.00'
    };
    api({
      project: {
        ...PROJECT,
        billing_type: 'retainer',
        retainer_usage: { ...usage, billable_now: false }
      }
    });
    expect(((await load(event())) as any).offers.billRetainer).toBe(false);
    api({
      project: {
        ...PROJECT,
        can_bill: false,
        billing_type: 'retainer',
        retainer_usage: { ...usage, billable_now: true }
      }
    });
    expect(((await load(event())) as any).offers.billRetainer).toBe(false);
  });

  it('keeps only tasks that are on this project, whatever the list returned', async () => {
    api({
      extra: (path) =>
        path.startsWith('/tasks/')
          ? {
              tasks: [
                { id: 't1', title: 'Mine', project: 'pr1', assigned_to: [] },
                { id: 't2', title: 'Other', project: 'pr2', assigned_to: [] },
                { id: 't3', title: 'Loose', assigned_to: [] }
              ]
            }
          : undefined
    });
    const data = (await load(event())) as any;
    expect(data.tasks.map((t: any) => t.id)).toEqual(['t1']);
  });
});

describe('the project actions', () => {
  it('bills the time and opens the new draft', async () => {
    let sent: any = null;
    api({
      extra: (path, options) => {
        if (path === '/invoices/from-time-entries/') {
          sent = options.body;
          return { invoice_id: 'i1', invoice_number: 'INV-1' };
        }
      }
    });
    await expect(
      actions.billTime(post({ up_to: '2026-10-31', group_by: 'task' }))
    ).rejects.toMatchObject({ status: 303, location: '/invoices/i1' });
    expect(sent).toEqual({ project_id: 'pr1', group_by: 'task', up_to: '2026-10-31' });
  });

  it('shows a member the refusal beside the bill', async () => {
    api({
      extra: (path) => {
        if (path === '/invoices/from-time-entries/') {
          throw Object.assign(new Error('HTTP 403'), {
            status: 403,
            body: { error: true, message: 'Only admins can create invoices from time entries.' }
          });
        }
      }
    });
    const result = (await actions.billTime(post({ group_by: 'entry' }))) as any;
    expect(result.status).toBe(403);
    expect(result.data.billError).toMatch(/Only admins/);
  });

  it('bills the retainer month and opens the draft', async () => {
    let called = '';
    let sent: unknown;
    api({
      extra: (path, options) => {
        if (path === '/projects/pr1/retainer/bill/') {
          called = options.method;
          sent = options.body;
          return { invoice_id: 'i3', invoice_number: 'INV-3', month: '2026-10' };
        }
      }
    });
    await expect(actions.billRetainer(post({ month: '2026-10' }))).rejects.toMatchObject({
      status: 303,
      location: '/invoices/i3'
    });
    expect(called).toBe('POST');
    expect(sent).toEqual({ month: '2026-10' });
  });

  it('shows the retainer refusal beside the button', async () => {
    api({
      extra: (path) => {
        if (path === '/projects/pr1/retainer/bill/') {
          throw Object.assign(new Error('HTTP 400'), {
            status: 400,
            body: { error: true, message: 'This month is already billed.' }
          });
        }
      }
    });
    const result = (await actions.billRetainer(post({}))) as any;
    expect(result.status).toBe(400);
    expect(result.data.retainerError).toBe('This month is already billed.');
  });

  it('refuses a percentage over 100 without asking the API', async () => {
    api();
    const result = (await actions.invoiceAmount(
      post({ mode: 'percent', value: '150', budget_amount: '12000' })
    )) as any;
    expect(result.status).toBe(400);
    expect(result.data.amountError).toMatch(/at most 100/);
    expect(asked).toEqual([]);
  });

  it('invoices an amount and opens the draft', async () => {
    api({
      extra: (path) =>
        path === '/projects/pr1/invoice-amount/'
          ? { invoice_id: 'i2', invoice_number: 'INV-2' }
          : undefined
    });
    await expect(
      actions.invoiceAmount(post({ mode: 'amount', value: '2500', budget_amount: '' }))
    ).rejects.toMatchObject({ status: 303, location: '/invoices/i2' });
  });

  it('refuses an empty comment without asking the API', async () => {
    api();
    const result = (await actions.comment(post({ comment: '  ' }))) as any;
    expect(result.status).toBe(400);
    expect(result.data.noteError).toBe('Write a comment or attach a file first.');
    expect(asked).toEqual([]);
  });
});

describe('after review', () => {
  it('reopens the bill panel when the bill posts back without JavaScript', async () => {
    api();
    const data = (await load(event('?bill=1&up_to=2026-10-31&/billTime'))) as any;
    expect(data.bill.open).toBe(true);
    expect(data.bill.upTo).toBe('2026-10-31');
    expect(asked).toContain('/projects/pr1/unbilled/?up_to=2026-10-31');
  });

  it('starts a timer billable as the page says the project is', async () => {
    let sent: any = null;
    api({
      extra: (path, options) => {
        if (path === '/projects/pr1/time-entries/start/') {
          sent = options.body;
          return {};
        }
      }
    });
    await actions.startTimer(post({ billable: 'false', task: 't1' }));
    expect(sent).toEqual({ billable: false, task: 't1' });
  });

  const logAs = async (admin: boolean) => {
    let sent: any = null;
    api({
      extra: (path, options) => {
        if (path === '/projects/pr1/time-entries/') {
          sent = options.body;
          return {};
        }
      }
    });
    const e = post({ minutes: '30', description: 'Copy', hourly_rate: '500' });
    e.locals = { ...e.locals, profile: { is_organization_admin: admin } };
    await actions.logTime(e);
    return sent;
  };

  it('sends no typed rate for a member, and an admin’s as typed', async () => {
    expect(await logAs(false)).not.toHaveProperty('hourly_rate');
    expect((await logAs(true))?.hourly_rate).toBe('500.00');
  });
});
