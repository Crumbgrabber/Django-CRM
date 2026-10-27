import { describe, it, expect, vi, beforeEach } from 'vitest';

const apiRequest = vi.fn();
vi.mock('#lib/api-helpers.js', () => ({
  apiRequest: (...a: any[]) => apiRequest(...a)
}));

const { actions } = await import('./+page.server.js');

const builderBody = {
  title: 'Website rebuild',
  account_id: 'a1',
  contact_id: 'c1',
  currency: 'USD',
  issue_date: '2026-10-27',
  line_items: [{ name: 'Design', description: '', quantity: 1, unit_price: 4000 }],
  introduction: 'Hello,\n\nHere is the plan.',
  deposit_percent: '30.00',
  start_project: true,
  project_billing_type: 'time_and_materials'
};

function createEvent(payload: unknown, admin = true) {
  const body = new FormData();
  body.set('payload', JSON.stringify(payload));
  return {
    request: new Request('http://test/invoices/estimates/new?/create', { method: 'POST', body }),
    cookies: { get: () => 'token' },
    locals: { profile: { is_organization_admin: admin } }
  } as any;
}

describe('new estimate create action', () => {
  beforeEach(() => {
    apiRequest.mockReset();
  });

  it('sends the introduction, deposit and project choice as the builder gave them', async () => {
    apiRequest.mockResolvedValue({ estimate: { id: 'e1' } });
    await expect(actions.create(createEvent(builderBody))).rejects.toMatchObject({
      status: 303,
      location: '/invoices/estimates'
    });
    const [path, options] = apiRequest.mock.calls[0];
    expect(path).toBe('/invoices/estimates/');
    expect(options.method).toBe('POST');
    expect(options.body).toMatchObject({
      introduction: 'Hello,\n\nHere is the plan.',
      deposit_percent: '30.00',
      start_project: true,
      project_billing_type: 'time_and_materials'
    });
  });

  it('never sends the project choice for a member who is not an admin', async () => {
    apiRequest.mockResolvedValue({ estimate: { id: 'e1' } });
    await expect(actions.create(createEvent(builderBody, false))).rejects.toMatchObject({
      status: 303
    });
    const body = apiRequest.mock.calls[0][1].body;
    expect(body).not.toHaveProperty('start_project');
    expect(body).not.toHaveProperty('project_billing_type');
    expect(body).toMatchObject({
      deposit_percent: '30.00',
      introduction: builderBody.introduction
    });
  });

  it("shows the API's sentence when it refuses the project", async () => {
    apiRequest.mockRejectedValue(
      Object.assign(new Error('start_project: Projects is switched off.'), {
        status: 400,
        body: { error: true, errors: { start_project: ['Projects is switched off.'] } }
      })
    );
    const result = (await actions.create(createEvent(builderBody))) as any;
    expect(result.status).toBe(400);
    expect(result.data.error).toContain('Projects is switched off.');
  });
});
