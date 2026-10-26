/**
 * Custom fields on every built-in record page: what each New, detail and edit
 * page loads, and what each save sends. Route modules are imported by path, as
 * in relay-callers.test.ts.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';

const apiRequest = vi.fn();
vi.mock('#lib/api-helpers.js', () => ({
  apiRequest: (...a: any[]) => apiRequest(...a)
}));

const R = '../../../routes/(app)';
const contactsNew = (await import(`${R}/contacts/new/+page.server.js`)) as any;
const contactEdit = (await import(`${R}/contacts/[id]/edit/+page.server.js`)) as any;
const accountsNew = (await import(`${R}/accounts/new/+page.server.js`)) as any;
const accountEdit = (await import(`${R}/accounts/[id]/edit/+page.server.js`)) as any;
const dealsNew = (await import(`${R}/pipeline/new/+page.server.js`)) as any;
const dealEdit = (await import(`${R}/pipeline/[id]/edit/+page.server.js`)) as any;
const tasksNew = (await import(`${R}/tasks/new/+page.server.js`)) as any;
const taskEdit = (await import(`${R}/tasks/[id]/edit/+page.server.js`)) as any;
const ticketsNew = (await import(`${R}/tickets/new/+page.server.js`)) as any;
const ticketEdit = (await import(`${R}/tickets/[id]/edit/+page.server.js`)) as any;
const leadsNew = (await import(`${R}/leads/new/+page.server.js`)) as any;
const leadEdit = (await import(`${R}/leads/[id]/edit/+page.server.js`)) as any;
const invoicesNew = (await import(`${R}/invoices/new/+page.server.js`)) as any;
const invoiceDetail = (await import(`${R}/invoices/[id]/+page.server.js`)) as any;
const estimatesNew = (await import(`${R}/invoices/estimates/new/+page.server.js`)) as any;
const recurringNew = (await import(`${R}/invoices/recurring/new/+page.server.js`)) as any;
const { getContact } = await import('./contacts.js');
const { getAccount } = await import('./accounts.js');
const { getDeal } = await import('./deals.js');
const { getTask } = await import('./tasks.js');
const { getTicket } = await import('./tickets.js');
const { getInvoice } = await import('./invoices.js');
const { getLead } = await import('./leads.js');

const ID = '11111111-1111-4111-8111-111111111111';
const cookies = { get: () => 'token' } as any;

const REQUIRED = {
  key: 'member_no',
  label: 'Member number',
  field_type: 'text',
  is_required: true,
  display_order: 0
};
const PICK = {
  key: 'tier',
  label: 'Tier',
  field_type: 'dropdown',
  options: [{ value: 'gold', label: 'Gold' }],
  display_order: 1
};

function formOf(fields: Record<string, string | string[]>) {
  const body = new FormData();
  for (const [k, v] of Object.entries(fields)) {
    for (const one of Array.isArray(v) ? v : [v]) body.append(k, one);
  }
  return body;
}

function post(fields: Record<string, string | string[]>, path: string = '/x') {
  return {
    request: new Request(`http://app.test${path}`, { method: 'POST', body: formOf(fields) }),
    url: new URL(`http://app.test${path}`),
    cookies,
    params: { id: ID },
    locals: {}
  } as any;
}

async function outcome(run: () => Promise<any>) {
  try {
    return await run();
  } catch (thrown: any) {
    if (thrown?.status >= 300 && thrown?.status < 400) return { redirect: thrown.location };
    throw thrown;
  }
}

/**
 * Answers the definitions read for any target with `defs`, and every write
 * through `write`.
 */
function serve(defs: any[], write: (path: string, options: any) => any = () => ({ id: ID })) {
  apiRequest.mockImplementation(async (path, options = {}) => {
    if (String(path).startsWith('/custom-fields/')) return { definitions: defs };
    if (options.method && options.method !== 'GET') return write(path, options);
    return {};
  });
}

const writesTo = (prefix: string) =>
  apiRequest.mock.calls.filter(
    (c) => String(c[0]).startsWith(prefix) && c[1]?.method && c[1].method !== 'GET'
  );

const fieldRefusal = () =>
  Object.assign(new Error('custom_fields: [object Object]'), {
    status: 400,
    body: { error: true, errors: { custom_fields: { member_no: 'is required' } } }
  });

beforeEach(() => {
  apiRequest.mockReset();
});

describe('a required contact field (the New contact form)', () => {
  it('is offered on the form, sent on create, and the create lands on the contact', async () => {
    apiRequest.mockImplementation(async (path, options = {}) => {
      if (String(path).startsWith('/custom-fields/')) return { definitions: [REQUIRED] };
      if (path === '/contacts/' && options.method === 'POST') {
        // The API's own rule: no value for a required field is a 400.
        if (!options.body.custom_fields?.member_no) throw fieldRefusal();
        return { id: ID };
      }
      if (String(path).startsWith('/contacts/')) return { countries: [], users: [] };
      if (String(path).startsWith('/accounts/')) return { active_accounts: { open_accounts: [] } };
      return {};
    });

    const page = await contactsNew.load(post({}, '/contacts/new'));
    expect(page.customFields).toEqual([
      expect.objectContaining({ key: 'member_no', is_required: true, value: '' })
    ]);

    const result = await outcome(() =>
      contactsNew.actions.create(
        post({
          first_name: 'Ada',
          last_name: 'Lovelace',
          cf__rendered: 'member_no',
          cf_member_no: 'M-42'
        })
      )
    );
    expect(result).toEqual({ redirect: `/contacts/${ID}` });
    const [, options] = writesTo('/contacts/')[0];
    expect(options.body.custom_fields).toEqual({ member_no: 'M-42' });
  });

  it('puts the refusal beside the field and keeps what was typed', async () => {
    serve([REQUIRED], () => {
      throw fieldRefusal();
    });
    const result = await contactsNew.actions.create(
      post({ first_name: 'Ada', last_name: 'L', cf__rendered: 'member_no', cf_member_no: '' })
    );
    expect(result.status).toBe(400);
    expect(result.data.fieldErrors).toEqual({ member_no: 'Member number is required.' });
    expect(result.data.error).toBe('Member number is required.');
    expect(result.data.values.custom_fields).toEqual({ member_no: null });
  });

  it('sends no custom_fields key from an org with no fields', async () => {
    serve([]);
    await outcome(() =>
      contactsNew.actions.create(post({ first_name: 'Ada', last_name: 'L', cf__rendered: '' }))
    );
    expect('custom_fields' in writesTo('/contacts/')[0][1].body).toBe(false);
  });
});

describe('every New page sends the fields it rendered', () => {
  const CASES: [string, any, Record<string, string>, string, string][] = [
    ['leads', leadsNew, { first_name: 'A', last_name: 'B' }, '/leads/', 'Lead'],
    ['accounts', accountsNew, { name: 'Acme' }, '/accounts/', 'Account'],
    ['deals', dealsNew, { name: 'Big deal' }, '/opportunities/', 'Opportunity'],
    ['tasks', tasksNew, { title: 'Call back' }, '/tasks/', 'Task'],
    ['tickets', ticketsNew, { name: 'Printer down' }, '/cases/', 'Case']
  ];

  it.each(CASES)('%s', async (_name, route, fields, endpoint, target) => {
    serve([REQUIRED, PICK]);
    await outcome(() =>
      route.actions.create(
        post({ ...fields, cf__rendered: 'member_no,tier', cf_member_no: 'M-1', cf_tier: 'gold' })
      )
    );
    const defsRead = apiRequest.mock.calls.find((c) => String(c[0]).startsWith('/custom-fields/'));
    expect(defsRead?.[0]).toContain(`target_model=${target}&`);
    const [, options] = writesTo(endpoint)[0];
    expect(options.body.custom_fields).toEqual({ member_no: 'M-1', tier: 'gold' });
  });
});

describe('every edit page sends the fields it rendered, and only those', () => {
  const CASES: [string, any, Record<string, string>, string][] = [
    ['leads', leadEdit, { first_name: 'A' }, `/leads/${ID}/`],
    ['contacts', contactEdit, { first_name: 'A' }, `/contacts/${ID}/`],
    ['accounts', accountEdit, { name: 'Acme' }, `/accounts/${ID}/`],
    ['deals', dealEdit, { name: 'Big deal' }, `/opportunities/${ID}/`],
    ['tasks', taskEdit, { title: 'Call back' }, `/tasks/${ID}/`],
    ['tickets', ticketEdit, { name: 'Printer down' }, `/cases/${ID}/`]
  ];

  it.each(CASES)('%s', async (_name, route, fields, endpoint) => {
    serve([REQUIRED, PICK], () => ({}));
    await outcome(() =>
      route.actions.save(
        post({ ...fields, cf__rendered: 'tier', cf_tier: 'gold', cf_member_no: 'x' })
      )
    );
    const [, options] = writesTo(endpoint)[0];
    expect(options.method).toBe('PATCH');
    expect(options.body.custom_fields).toEqual({ tier: 'gold' });
  });

  it('lands a refusal beside its field on an edit page', async () => {
    serve([REQUIRED], () => {
      throw fieldRefusal();
    });
    const result = await contactEdit.actions.save(
      post({ first_name: 'A', cf__rendered: 'member_no', cf_member_no: '' })
    );
    expect(result.status).toBe(400);
    expect(result.data.fieldErrors).toEqual({ member_no: 'Member number is required.' });
  });
});

describe('the billing builders take fields from their inputs, never the payload', () => {
  const payload = (more: Record<string, any>) =>
    JSON.stringify({
      account_id: ID,
      contact_id: ID,
      title: 'Monthly',
      line_items: [{ description: 'x', quantity: 1, unit_price: 1 }],
      custom_fields: { forged: 'yes' },
      ...more
    });

  const CASES: [string, any, string, string][] = [
    ['invoice', invoicesNew, '/invoices/', 'Invoice'],
    ['estimate', estimatesNew, '/invoices/estimates/', 'Estimate'],
    ['recurring invoice', recurringNew, '/invoices/recurring/', 'RecurringInvoice']
  ];

  it.each(CASES)('%s', async (_name, route, endpoint, target) => {
    serve([PICK], () => ({ invoice: { id: ID } }));
    await outcome(() =>
      route.actions.create(post({ payload: payload({}), cf__rendered: 'tier', cf_tier: 'gold' }))
    );
    const defsRead = apiRequest.mock.calls.find((c) => String(c[0]).startsWith('/custom-fields/'));
    expect(defsRead?.[0]).toContain(`target_model=${target}&`);
    const [, options] = writesTo(endpoint)[0];
    expect(options.body.custom_fields).toEqual({ tier: 'gold' });
  });

  it('sends none when the builder rendered none', async () => {
    serve([]);
    await outcome(() => invoicesNew.actions.create(post({ payload: payload({}) })));
    expect('custom_fields' in writesTo('/invoices/')[0][1].body).toBe(false);
  });

  it('loads the inputs for each builder', async () => {
    apiRequest.mockImplementation(async (path) =>
      String(path).startsWith('/custom-fields/') ? { definitions: [PICK] } : {}
    );
    const inputs = await recurringNew.load(post({}));
    expect(inputs.customFields.map((f: any) => f.key)).toEqual(['tier']);
  });
});

describe('the invoice "Edit fields" form', () => {
  it('sends custom_fields and nothing else', async () => {
    serve([PICK], () => ({}));
    const result = await outcome(() =>
      invoiceDetail.actions.fields(post({ cf__rendered: 'tier', cf_tier: 'gold', status: 'Paid' }))
    );
    expect(result).toEqual({ redirect: `/invoices/${ID}` });
    const [, options] = writesTo(`/invoices/${ID}/`)[0];
    expect(options).toMatchObject({ method: 'PUT', body: { custom_fields: { tier: 'gold' } } });
    expect(Object.keys(options.body)).toEqual(['custom_fields']);
  });

  it('keeps the form open with the refusal beside the field', async () => {
    serve([REQUIRED], () => {
      throw fieldRefusal();
    });
    const result = await invoiceDetail.actions.fields(
      post({ cf__rendered: 'member_no', cf_member_no: '' })
    );
    expect(result.status).toBe(400);
    expect(result.data).toEqual({
      fieldsError: 'Member number is required.',
      fieldErrors: { member_no: 'Member number is required.' },
      values: { custom_fields: { member_no: null } }
    });
  });

  it('opens the form from the link', async () => {
    apiRequest.mockResolvedValue({ invoice: { id: ID, line_items: [] } });
    const data = await invoiceDetail.load(post({}, `/invoices/${ID}?fields=edit`));
    expect(data.editFields).toBe(true);
  });
});

describe('detail pages read the fields from their own response', () => {
  const defs = { custom_field_definitions: [REQUIRED, PICK] };
  const values = { custom_fields: { tier: 'gold' } };

  const CASES: [string, () => Promise<any>, any][] = [
    [
      'contact',
      () => getContact({ cookies }, ID),
      { contact_obj: { id: ID, assigned_to: [], teams: [], ...values }, ...defs }
    ],
    ['account', () => getAccount({ cookies }, ID), { account_obj: { id: ID, ...values }, ...defs }],
    ['deal', () => getDeal({ cookies }, ID), { opportunity_obj: { id: ID, ...values }, ...defs }],
    ['task', () => getTask({ cookies }, ID), { task_obj: { id: ID, ...values }, ...defs }],
    [
      'ticket',
      () => getTicket({ cookies }, ID),
      { cases_obj: { id: ID, name: 'T', status: 'New', priority: 'Low', ...values }, ...defs }
    ],
    ['invoice', () => getInvoice({ cookies }, ID), { invoice: { id: ID, ...values }, ...defs }],
    ['lead', () => getLead({ cookies }, ID), { lead_obj: { id: ID, ...values }, ...defs }]
  ];

  it.each(CASES)('%s', async (_name, read, response) => {
    apiRequest.mockImplementation(async (path) => {
      if (String(path).startsWith('/custom-fields/')) throw new Error('no extra call expected');
      return String(path).includes(ID) && !String(path).includes('duplicates') ? response : {};
    });
    const data = await read();
    expect(data.customFields).toEqual([
      { key: 'member_no', label: 'Member number', field_type: 'text', value: '', filled: false },
      { key: 'tier', label: 'Tier', field_type: 'dropdown', value: 'Gold', filled: true }
    ]);
  });

  it('shows no block when the org has no active fields', async () => {
    apiRequest.mockResolvedValue({
      contact_obj: { id: ID, assigned_to: [], teams: [], custom_fields: { old: 'kept' } },
      custom_field_definitions: []
    });
    expect((await getContact({ cookies }, ID)).customFields).toEqual([]);
  });
});
