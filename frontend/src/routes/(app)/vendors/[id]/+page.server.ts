import { fail, redirect } from '@sveltejs/kit';
import { getVendor, deleteVendor, listBills } from '#lib/server/v2/vendors.js';
import { isOn } from '#lib/v2/modules.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
  const vendor = await getVendor(event, event.params.id);
  const { modules } = await event.parent();
  const billsOn = isOn(modules, 'bills');
  const bills = [];
  let offset = 0;
  while (billsOn) {
    const page = await listBills(
      event,
      new URLSearchParams({ vendor: vendor.id, limit: '100', offset: String(offset) })
    );
    bills.push(...page.results);
    if (!page.next || !page.results.length) break;
    offset += page.results.length;
  }
  const balances: Record<string, number> = {};
  for (const bill of bills) {
    if (bill.status === 'VOID') continue;
    const currency = bill.currency || vendor.currency || '';
    balances[currency] = (balances[currency] ?? 0) + Math.round(Number(bill.balance_due) * 100);
  }
  return {
    vendor,
    billsOn,
    bills,
    balances: Object.entries(balances).map(([currency, cents]) => ({
      currency,
      amount: cents / 100
    }))
  };
};
export const actions: Actions = {
  delete: async (event) => {
    try {
      await deleteVendor(event, event.params.id);
    } catch (err) {
      return fail(400, { error: readableError(err, 'Could not delete this vendor.') });
    }
    redirect(303, '/vendors');
  }
};
