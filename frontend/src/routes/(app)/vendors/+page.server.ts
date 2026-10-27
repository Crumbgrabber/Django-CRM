import { listVendors } from '#lib/server/v2/vendors.js';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
  const params = new URLSearchParams(event.url.searchParams);
  const offset = Math.max(0, Math.floor(Number(params.get('offset')) || 0));
  params.set('limit', '25');
  params.set('offset', String(offset));
  return { vendors: await listVendors(event, params), search: params.get('search') ?? '', offset };
};
