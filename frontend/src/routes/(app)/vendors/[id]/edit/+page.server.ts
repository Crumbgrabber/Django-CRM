import { fail, redirect } from '@sveltejs/kit';
import { getAccountFormOptions } from '#lib/server/v2/accounts.js';
import { getOrgPeopleAndTeams } from '#lib/server/v2/org-people.js';
import { getVendor, updateVendor, vendorFormBody } from '#lib/server/v2/vendors.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => ({
  options: await getAccountFormOptions(event),
  people: await getOrgPeopleAndTeams(event.cookies),
  vendor: await getVendor(event, event.params.id)
});

export const actions: Actions = {
  save: async (event) => {
    const body = vendorFormBody(await event.request.formData());
    let vendor;
    try {
      vendor = await updateVendor(event, event.params.id, body);
    } catch (err) {
      return fail(400, { error: readableError(err, 'Could not save this vendor.'), values: body });
    }
    redirect(303, `/vendors/${vendor.id}`);
  }
};
