import { fail, redirect, type ActionFailure } from '@sveltejs/kit';
import { listAccounts } from '#lib/server/v2/accounts.js';
import { listContacts } from '#lib/server/v2/contacts.js';
import { listProducts } from '#lib/server/v2/products.js';
import { createRecurringInvoice, type RecurringValues } from '#lib/server/v2/recurring.js';
import {
  fieldsForNew,
  readCustomFields,
  saveRefusal
} from '#lib/server/v2/record-custom-fields.js';
import { apiStatus } from '#lib/api-errors.js';
import type { Actions, PageServerLoad } from './$types';

type ContactRow = {
  id: string;
  name: string;
  email: string;
  account: { id: string; name: string } | null;
};

/**
 * Same three pickers as the one-off invoice builder: account and contact are
 * both required by the serializer, which also cross-checks that the contact
 * belongs to the chosen account, and the product catalogue feeds the line-item
 * rows. Contacts carry their account so the page can offer only the ones that
 * pass that rule.
 */
export const load: PageServerLoad = async ({ cookies }) => {
  const [accounts, contacts, products, customFields] = await Promise.all([
    listAccounts({ cookies }, new URLSearchParams({ limit: '1000' })),
    listContacts({ cookies }, new URLSearchParams({ limit: '1000' })),
    listProducts({ cookies }),
    fieldsForNew(cookies, 'RecurringInvoice')
  ]);

  return {
    accounts: accounts.results.map((a) => ({ id: a.id, name: a.name || 'Unnamed account' })),
    contacts: contacts.results.map((c: ContactRow) => ({
      id: c.id,
      name: c.name || c.email || 'Unnamed contact',
      account_id: c.account?.id ?? null,
      account_name: c.account?.name ?? ''
    })),
    products: products.results
      .filter((p) => p.is_active)
      .map((p) => ({ id: p.id, name: p.name, sku: p.sku, price: p.price })),
    customFields
  };
};

export const actions: Actions = {
  /**
   * Create the schedule. The page serialises the whole builder into one
   * `payload` field so the dynamic line-item list travels intact; the server
   * owns org, totals and invoices_generated. There is no per-schedule detail
   * route (`invoices/recurring/[id]/` does not exist), so on success we land
   * back on the schedules list rather than inventing a redirect target.
   *
   * Annotated so the refusal with `fieldErrors` is not folded into the bare one.
   */
  create: async ({
    cookies,
    request
  }): Promise<ActionFailure<{ error: string; fieldErrors?: Record<string, string> }>> => {
    const form = await request.formData();
    let values: RecurringValues;
    try {
      values = JSON.parse(form.get('payload')?.toString() || '{}');
    } catch {
      return fail(400, { error: 'The schedule form could not be read. Please try again.' });
    }

    // Custom fields come from their own inputs, never from the builder's payload.
    delete values.custom_fields;
    const custom = await readCustomFields(cookies, 'RecurringInvoice', form);
    if (custom.refusal) return fail(503, custom.refusal);
    if (custom.values) values.custom_fields = custom.values;

    try {
      await createRecurringInvoice({ cookies }, values);
    } catch (err) {
      return fail(apiStatus(err) === 403 ? 403 : 400, {
        ...saveRefusal(err, custom.definitions, 'Could not create the schedule.')
      });
    }

    redirect(303, '/invoices/recurring');
  }
};
