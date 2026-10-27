import { beforeEach, expect, it, vi } from 'vitest';
const apiRequest = vi.fn();
vi.mock('#lib/api-helpers.js', () => ({ apiRequest: (...args: unknown[]) => apiRequest(...args) }));
const create = (await import('./new/+page.server.js')).actions.save;
const edit = (await import('./[billId]/+page.server.js')).actions;
const load = (await import('./[billId]/+page.server.js')).load;
function event(entries: [string, string][] = []) {
  const body = new FormData();
  for (const [key, value] of entries) body.append(key, value);
  return {
    cookies: { get: () => 'token' },
    params: { id: 'vendor', billId: 'bill' },
    request: new Request('http://test/vendors/vendor/bills/bill', { method: 'POST', body })
  } as any;
}
let bill: { id: string; vendor: string; status: string };
beforeEach(() => {
  bill = { id: 'bill', vendor: 'vendor', status: 'UNPAID' };
  apiRequest.mockReset();
  apiRequest.mockImplementation(async (url, options) => {
    if (url === '/vendors/vendor/') return { id: 'vendor', currency: 'USD' };
    if (!options.method) return bill;
    return { id: 'bill' };
  });
});
it('creates a bill with the URL vendor regardless of submitted vendor', async () => {
  await expect(
    create(
      event([
        ['vendor', 'foreign'],
        ['bill_date', '2026-10-01']
      ])
    )
  ).rejects.toMatchObject({ status: 303, location: '/vendors/vendor/bills/bill' });
  expect(apiRequest).toHaveBeenCalledWith(
    '/vendors/bills/',
    { method: 'POST', body: { vendor: 'vendor', bill_date: '2026-10-01' } },
    expect.anything()
  );
});
it('saves editable amounts without accepting a paid status from the form', async () => {
  await expect(
    edit.save(
      event([
        ['amount_paid', '5.50'],
        ['status', 'PAID'],
        ['vendor', 'foreign']
      ])
    )
  ).rejects.toMatchObject({ status: 303, location: '/vendors/vendor' });
  expect(apiRequest).toHaveBeenCalledWith(
    '/vendors/bills/bill/',
    { method: 'PATCH', body: { vendor: 'vendor', amount_paid: '5.50' } },
    expect.anything()
  );
});
it.each(['UNPAID', 'PARTIALLY_PAID', 'PAID', 'VOID'])(
  'toggles %s using the stored status',
  async (status) => {
    bill.status = status;
    expect(await edit.status(event([['status', 'PAID']]))).toHaveProperty('message');
    expect(apiRequest).toHaveBeenCalledWith(
      '/vendors/bills/bill/',
      { method: 'PATCH', body: { status: status === 'VOID' ? 'UNPAID' : 'VOID' } },
      expect.anything()
    );
  }
);
it.each(['save', 'status', 'delete'] as const)(
  'rejects a mismatched vendor before %s',
  async (action) => {
    bill.vendor = 'foreign';
    await expect(edit[action](event())).rejects.toMatchObject({ status: 404 });
    expect(apiRequest).toHaveBeenCalledTimes(1);
  }
);
it('refuses to load a bill under a different vendor', async () => {
  bill.vendor = 'foreign';
  await expect(load(event())).rejects.toMatchObject({ status: 404 });
});
it.each(['create', 'save', 'status', 'delete'] as const)(
  'shows backend errors after refused %s',
  async (action) => {
    apiRequest.mockImplementation(async (url, options) => {
      if (options.method) throw { status: 400, body: { error: true, errors: 'Bill cannot be changed.' } };
      return url === '/vendors/vendor/' ? { id: 'vendor' } : bill;
    });
    const response = await (action === 'create' ? create : edit[action])(
      event([['total_amount', 'bad']])
    );
    expect(response).toMatchObject({ status: 400, data: { error: 'Bill cannot be changed.' } });
    if (action === 'create' || action === 'save')
      expect(response?.data).toHaveProperty('values.total_amount', 'bad');
  }
);
it('deletes and redirects to the vendor', async () => {
  await expect(edit.delete(event())).rejects.toMatchObject({
    status: 303,
    location: '/vendors/vendor'
  });
  expect(apiRequest).toHaveBeenCalledWith(
    '/vendors/bills/bill/',
    { method: 'DELETE' },
    expect.anything()
  );
});
it('propagates permission refusal without writing', async () => {
  apiRequest.mockRejectedValue({ status: 403 });
  await expect(edit.save(event())).rejects.toMatchObject({ status: 403 });
  expect(apiRequest).toHaveBeenCalledTimes(1);
});
