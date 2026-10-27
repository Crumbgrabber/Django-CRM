import { fail, redirect } from '@sveltejs/kit';
import { getVendor, createBill, billFormBody } from '#lib/server/v2/vendors.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => ({
  vendor: await getVendor(event, event.params.id),
  bill: null
});
export const actions: Actions = {
  save: async (event) => {
    const vendor = await getVendor(event, event.params.id);
    const body = { ...billFormBody(await event.request.formData()), vendor: vendor.id };
    let bill;
    try {
      bill = await createBill(event, body);
    } catch (err) {
      return fail(400, { error: readableError(err, 'Could not save this bill.'), values: body });
    }
    redirect(303, `/vendors/${vendor.id}/bills/${bill.id}`);
  }
};
