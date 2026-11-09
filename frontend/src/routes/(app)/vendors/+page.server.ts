import { listVendors } from '#lib/server/v2/vendors.js';
import { readPaging, withPaging } from '#lib/server/v2/paging.js';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
  const params = withPaging(new URLSearchParams(event.url.searchParams), event.url);
  return {
    vendors: await listVendors(event, params),
    search: params.get('search') ?? '',
    paging: readPaging(event.url)
  };
};
