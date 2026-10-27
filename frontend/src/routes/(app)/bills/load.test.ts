import { beforeEach, expect, it, vi } from 'vitest';
const listBills = vi.fn();
vi.mock('#lib/server/v2/vendors.js', () => ({ listBills }));
const { load } = await import('./+page.server.js');
beforeEach(() => {
  listBills.mockReset();
  listBills.mockResolvedValue({ count: 0, results: [] });
});
it('forwards status, overdue and pagination', async () => {
  const event = {
    url: new URL('http://test/bills?status=UNPAID&overdue=true&offset=25&vendor=foreign')
  } as any;
  expect(await load(event)).toMatchObject({ status: 'UNPAID', overdue: true, offset: 25 });
  expect(listBills).toHaveBeenCalledWith(
    event,
    new URLSearchParams({ limit: '25', offset: '25', status: 'UNPAID', overdue: 'true' })
  );
});
it('clears invalid filters and pagination', async () => {
  expect(
    await load({
      url: new URL('http://test/bills?status=bad&overdue=false&offset=Infinity')
    } as any)
  ).toMatchObject({ status: '', overdue: false, offset: 0 });
});
