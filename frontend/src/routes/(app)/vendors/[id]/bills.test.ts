import { expect, it, vi } from 'vitest';
const getVendor = vi.fn();
const listBills = vi.fn();
vi.mock('#lib/server/v2/vendors.js', () => ({ getVendor, listBills, deleteVendor: vi.fn() }));
const { load } = await import('./+page.server.js');
it('loads all vendor bills and sums non-void balances separately per currency', async () => {
  getVendor.mockResolvedValue({ id: 'vendor', currency: 'USD' });
  listBills
    .mockResolvedValueOnce({
      next: 'next',
      results: [
        { id: 'a', currency: 'USD', balance_due: '10.20', status: 'UNPAID' },
        { id: 'b', currency: 'EUR', balance_due: '5.10', status: 'UNPAID' },
        { id: 'c', currency: 'USD', balance_due: '99.00', status: 'VOID' }
      ]
    })
    .mockResolvedValueOnce({
      next: null,
      results: [{ id: 'd', currency: 'USD', balance_due: '0.10', status: 'PARTIALLY_PAID' }]
    });
  const event = { params: { id: 'vendor' }, parent: async () => ({ modules: null }) } as any;
  expect(await load(event)).toMatchObject({
    balances: [
      { currency: 'USD', amount: 10.3 },
      { currency: 'EUR', amount: 5.1 }
    ],
    bills: expect.any(Array)
  });
  expect(listBills).toHaveBeenNthCalledWith(
    2,
    event,
    new URLSearchParams({ vendor: 'vendor', limit: '100', offset: '3' })
  );
});
it('skips the bills request while Bills is off', async () => {
  listBills.mockClear();
  getVendor.mockResolvedValue({ id: 'vendor', currency: 'USD' });
  const modules = [{ key: 'bills', available: false }];
  const event = { params: { id: 'vendor' }, parent: async () => ({ modules }) } as any;
  expect(await load(event)).toMatchObject({ bills: [], balances: [] });
  expect(listBills).not.toHaveBeenCalled();
});
