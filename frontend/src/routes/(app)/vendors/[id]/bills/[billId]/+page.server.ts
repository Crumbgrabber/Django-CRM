import { error, fail, redirect } from '@sveltejs/kit';
import {
  getVendor,
  getBill,
  updateBill,
  deleteBill,
  billFormBody
} from '#lib/server/v2/vendors.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import type { Actions, PageServerLoad, RequestEvent } from './$types';

async function ownedBill(event: RequestEvent) {
  const bill = await getBill(event, event.params.billId);
  if (bill.vendor !== event.params.id) error(404, 'Bill not found.');
  return bill;
}
export const load: PageServerLoad = async (event) => ({
  vendor: await getVendor(event, event.params.id),
  bill: await ownedBill(event)
});
export const actions: Actions = {
  save: async (event) => {
    await ownedBill(event);
    const body = { ...billFormBody(await event.request.formData()), vendor: event.params.id };
    try {
      await updateBill(event, event.params.billId, body);
    } catch (err) {
      return fail(400, { error: readableError(err, 'Could not save this bill.'), values: body });
    }
    redirect(303, `/vendors/${event.params.id}`);
  },
  status: async (event) => {
    const bill = await ownedBill(event);
    try {
      await updateBill(event, bill.id, { status: bill.status === 'VOID' ? 'UNPAID' : 'VOID' });
    } catch (err) {
      return fail(400, { error: readableError(err, 'Could not change this bill.') });
    }
    return { message: bill.status === 'VOID' ? 'Bill un-voided.' : 'Bill voided.' };
  },
  delete: async (event) => {
    await ownedBill(event);
    try {
      await deleteBill(event, event.params.billId);
    } catch (err) {
      return fail(400, { error: readableError(err, 'Could not delete this bill.') });
    }
    redirect(303, `/vendors/${event.params.id}`);
  }
};
