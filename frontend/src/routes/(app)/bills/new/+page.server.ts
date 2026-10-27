import { fail, redirect } from '@sveltejs/kit';
import { listVendors, createBill, billFormBody } from '#lib/server/v2/vendors.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
  const vendors = await listVendors(event, new URLSearchParams({ limit: '500' }));
  return { vendor: null, vendors: vendors.results, bill: null };
};
export const actions: Actions = {
  save: async (event) => {
    const form = await event.request.formData();
    const vendor = form.get('vendor')?.toString() ?? '';
    const body = { ...billFormBody(form), vendor };
    if (!vendor) return fail(400, { error: 'Choose a vendor.', values: body });
    let bill;
    try {
      bill = await createBill(event, body);
    } catch (err) {
      return fail(400, { error: readableError(err, 'Could not save this bill.'), values: body });
    }
    redirect(303, `/vendors/${vendor}/bills/${bill.id}`);
  }
};
