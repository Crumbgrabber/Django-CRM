import { describe, it, expect, vi, beforeEach } from 'vitest';

const apiRequest = vi.fn();
vi.mock('#lib/api-helpers.js', () => ({
  apiRequest: (...a: any[]) => apiRequest(...a)
}));

const { actions } = await import('./+page.server.js');

function convertEvent(id: string) {
  const body = new FormData();
  body.set('id', id);
  return {
    request: new Request('http://test/invoices/estimates?/convert', { method: 'POST', body }),
    cookies: { get: () => 'token' }
  } as any;
}

describe('raise invoice from an estimate', () => {
  beforeEach(() => {
    apiRequest.mockReset();
  });

  it('opens the new invoice, deposit invoice or not', async () => {
    apiRequest.mockResolvedValue({
      error: false,
      message: 'Estimate converted to invoice',
      invoice: { id: 'i2' },
      deposit_invoice: { id: 'i1', invoice_number: 'INV-0042', status: 'Draft' }
    });
    await expect(actions.convert(convertEvent('e1'))).rejects.toMatchObject({
      status: 303,
      location: '/invoices/i2'
    });
    expect(apiRequest.mock.calls[0][0]).toBe('/invoices/estimates/e1/convert/');
    expect(apiRequest.mock.calls[0][1]).toEqual({ method: 'POST' });
  });

  it("shows the API's sentence for a second conversion", async () => {
    apiRequest.mockRejectedValue(
      Object.assign(new Error('Estimate already converted'), {
        status: 400,
        body: { error: true, errors: 'Estimate already converted' }
      })
    );
    const result = (await actions.convert(convertEvent('e1'))) as any;
    expect(result).toMatchObject({ status: 400, data: { error: 'Estimate already converted' } });
  });

  it('asks which estimate when none was given', async () => {
    const result = (await actions.convert(convertEvent(''))) as any;
    expect(result.status).toBe(400);
    expect(apiRequest).not.toHaveBeenCalled();
  });
});
