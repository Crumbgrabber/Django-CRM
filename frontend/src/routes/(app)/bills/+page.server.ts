import { listBills } from '#lib/server/v2/vendors.js';
import { readPaging, withPaging } from '#lib/server/v2/paging.js';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
  const input = event.url.searchParams;
  const status = ['UNPAID', 'PARTIALLY_PAID', 'PAID', 'VOID'].includes(input.get('status') ?? '')
    ? input.get('status')!
    : '';
  const overdue = input.get('overdue') === 'true';
  const params = withPaging(new URLSearchParams(), event.url);
  if (status) params.set('status', status);
  if (overdue) params.set('overdue', 'true');
  return { bills: await listBills(event, params), status, overdue, paging: readPaging(event.url) };
};
