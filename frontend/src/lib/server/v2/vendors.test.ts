import { beforeEach, expect, it, vi } from 'vitest';
const apiRequest = vi.fn();
vi.mock('#lib/api-helpers.js', () => ({ apiRequest: (...args: unknown[]) => apiRequest(...args) }));
const { listVendors, getVendor, createVendor, updateVendor, deleteVendor, vendorFormBody } =
  await import('./vendors.js');
const event = { cookies: { get: () => 'token' } } as any;
beforeEach(() => {
  apiRequest.mockReset();
});

it('forwards search and pagination without client-supplied org', async () => {
  apiRequest.mockResolvedValue({ count: 1, results: [] });
  expect(
    (
      await listVendors(
        event,
        new URLSearchParams({ search: 'Host', offset: '25', org: 'foreign' })
      )
    ).count
  ).toBe(1);
  expect(apiRequest).toHaveBeenCalledWith('/vendors/?search=Host&offset=25&limit=25', {}, event);
});

it('reads, creates, patches and deletes the record', async () => {
  apiRequest.mockResolvedValue({ id: 'one' });
  expect(await getVendor(event, 'one')).toEqual({ id: 'one' });
  await createVendor(event, { name: 'Hosting' });
  await updateVendor(event, 'one', { name: 'Cloud' });
  await deleteVendor(event, 'one');
  expect(apiRequest.mock.calls.map((call) => call.slice(0, 2))).toEqual([
    ['/vendors/one/', {}],
    ['/vendors/', { method: 'POST', body: { name: 'Hosting' } }],
    ['/vendors/one/', { method: 'PATCH', body: { name: 'Cloud' } }],
    ['/vendors/one/', { method: 'DELETE' }]
  ]);
});

it('propagates refused writes', async () => {
  apiRequest.mockRejectedValue(new Error('Refused'));
  await expect(createVendor(event, { name: 'Duplicate' })).rejects.toThrow('Refused');
});

it('accepts editable fields only and explicitly clears unchecked state', () => {
  const form = new FormData();
  form.set('name', ' Hosting ');
  form.set('org', 'foreign');
  form.set('created_by', 'other');
  form.set('email', '');
  expect(vendorFormBody(form)).toEqual({ name: 'Hosting', email: null, is_active: false });
});

it('preserves omitted relationships and supports clearing or multiple assignments', () => {
  const form = new FormData();
  expect(vendorFormBody(form)).not.toHaveProperty('assigned_to');
  form.set('assigned_to_present', '1');
  expect(vendorFormBody(form).assigned_to).toEqual([]);
  form.append('assigned_to', 'first');
  form.append('assigned_to', 'second');
  expect(vendorFormBody(form).assigned_to).toEqual(['first', 'second']);
});

const { listBills, getBill, createBill, updateBill, deleteBill, billFormBody } =
  await import('./vendors.js');
it('lists bills with supported filters only', async () => {
  apiRequest.mockResolvedValue({ count: 0, results: [] });
  await listBills(
    event,
    new URLSearchParams({
      vendor: 'one',
      status: 'UNPAID',
      overdue: 'true',
      offset: '25',
      org: 'foreign'
    })
  );
  expect(apiRequest).toHaveBeenCalledWith(
    '/vendors/bills/?vendor=one&status=UNPAID&overdue=true&offset=25&limit=25',
    {},
    event
  );
});
it('reads and writes bills through their endpoint', async () => {
  apiRequest.mockResolvedValue({ id: 'bill' });
  await getBill(event, 'bill');
  await createBill(event, { vendor: 'one', bill_date: '2026-10-01' });
  await updateBill(event, 'bill', { status: 'VOID' });
  await deleteBill(event, 'bill');
  expect(apiRequest.mock.calls.map((call) => call.slice(0, 2))).toEqual([
    ['/vendors/bills/bill/', {}],
    ['/vendors/bills/', { method: 'POST', body: { vendor: 'one', bill_date: '2026-10-01' } }],
    ['/vendors/bills/bill/', { method: 'PATCH', body: { status: 'VOID' } }],
    ['/vendors/bills/bill/', { method: 'DELETE' }]
  ]);
});
it('keeps decimal values and accepts only editable bill fields', () => {
  const form = new FormData();
  for (const [key, value] of Object.entries({
    bill_number: ' B1 ',
    bill_date: '2026-10-01',
    due_date: '',
    total_amount: '10.20',
    amount_paid: '0',
    vendor: 'foreign',
    org: 'foreign',
    status: 'PAID',
    balance_due: '0'
  }))
    form.set(key, value);
  expect(billFormBody(form)).toEqual({
    bill_number: 'B1',
    bill_date: '2026-10-01',
    due_date: null,
    total_amount: '10.20',
    amount_paid: '0'
  });
});
it('maps missing bills to 404 and propagates access refusals', async () => {
  apiRequest.mockRejectedValue({ status: 404 });
  await expect(getBill(event, 'missing')).rejects.toMatchObject({ status: 404 });
  apiRequest.mockRejectedValue({ status: 403 });
  await expect(updateBill(event, 'bill', { notes: 'test' })).rejects.toMatchObject({ status: 403 });
});
it('sets amount paid to the total when paid in full is ticked', () => {
  const form = new FormData();
  form.set('total_amount', '50.00');
  form.set('amount_paid', '10');
  form.set('paid_in_full', 'on');
  expect(billFormBody(form).amount_paid).toBe('50.00');
  form.delete('paid_in_full');
  expect(billFormBody(form).amount_paid).toBe('10');
});
