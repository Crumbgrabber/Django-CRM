import { listBills } from '#lib/server/v2/vendors.js';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
  const input = event.url.searchParams;
  const status = ['UNPAID', 'PARTIALLY_PAID', 'PAID', 'VOID'].includes(input.get('status') ?? '')
    ? input.get('status')!
    : '';
  const overdue = input.get('overdue') === 'true';
  const rawOffset = Number(input.get('offset'));
  const offset = Number.isFinite(rawOffset) ? Math.max(0, Math.floor(rawOffset)) : 0;
  const params = new URLSearchParams({ limit: '25', offset: String(offset) });
  if (status) params.set('status', status);
  if (overdue) params.set('overdue', 'true');
  return { bills: await listBills(event, params), status, overdue, offset };
};
