import { beforeEach, expect, it, vi } from 'vitest';
const listVendors = vi.fn();
const createBill = vi.fn();
vi.mock('#lib/server/v2/vendors.js', async (original) => ({
  ...(await original<typeof import('#lib/server/v2/vendors.js')>()),
  listVendors,
  createBill
}));
const { load, actions } = await import('./+page.server.js');
const post = (fields: Record<string, string>) => {
  const body = new FormData();
  for (const [k, v] of Object.entries(fields)) body.set(k, v);
  return { request: new Request('http://test', { method: 'POST', body }) } as any;
};
const valid = { bill_date: '2026-10-01', currency: 'USD', total_amount: '25', amount_paid: '0' };
beforeEach(() => {
  listVendors.mockReset();
  createBill.mockReset();
});
it('loads vendors for the picker', async () => {
  listVendors.mockResolvedValue({ count: 1, results: [{ id: 'v1', name: 'Meta Ads' }] });
  expect(await load({} as any)).toMatchObject({ vendor: null, vendors: [{ id: 'v1' }] });
});
it('refuses a bill without a vendor', async () => {
  const result = await actions.save(post(valid));
  expect(result).toMatchObject({ status: 400, data: { error: 'Choose a vendor.' } });
  expect(createBill).not.toHaveBeenCalled();
});
it('creates the bill, paid in full, and redirects to it', async () => {
  createBill.mockResolvedValue({ id: 'b1' });
  await expect(
    actions.save(post({ ...valid, vendor: 'v1', paid_in_full: 'on' }))
  ).rejects.toMatchObject({ status: 303, location: '/vendors/v1/bills/b1' });
  expect(createBill.mock.calls[0][1]).toMatchObject({ vendor: 'v1', amount_paid: '25' });
});
it('shows backend errors and keeps the values', async () => {
  createBill.mockRejectedValue({ status: 400, data: { vendor: ['Invalid vendor.'] } });
  const result = await actions.save(post({ ...valid, vendor: 'v1' }));
  expect(result).toMatchObject({ status: 400, data: { values: { vendor: 'v1' } } });
});
