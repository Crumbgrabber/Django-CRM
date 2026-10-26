import { fail, redirect, type ActionFailure } from '@sveltejs/kit';
import { listAccounts } from '#lib/server/v2/accounts.js';
import { listContacts } from '#lib/server/v2/contacts.js';
import { listProducts } from '#lib/server/v2/products.js';
import { createInvoice } from '#lib/server/v2/invoices.js';
import {
  fieldsForNew,
  readCustomFields,
  saveRefusal
} from '#lib/server/v2/record-custom-fields.js';
import { getNumbering } from '#lib/server/v2/organization.js';
import { apiStatus } from '#lib/api-errors.js';
import type { Actions, PageServerLoad } from './$types';
import type { FormBody } from '#lib/api-helpers.js';
import type { components } from '#lib/api-schema.js';

type Schemas = components['schemas'];

type ContactRow = {
  id: string;
  name: string;
  email: string;
  account: { id: string; name: string } | null;
};

/**
 * The builder needs three pickers: account (required), contact (required, the
 * create serializer enforces it and cross-validates it against the account),
 * and the product catalogue for line items. All three reuse the real list
 * layers; nothing here is a fixture. Contacts carry their primary account so
 * the page can offer only the ones that pass the account↔contact rule. The
 * org's numbering format feeds the "Assigned on save" preview.
 */
export const load: PageServerLoad = async ({ cookies }) => {
  const [accounts, contacts, products, numbering, customFields] = await Promise.all([
    listAccounts({ cookies }, new URLSearchParams({ limit: '1000' })),
    listContacts({ cookies }, new URLSearchParams({ limit: '1000' })),
    listProducts({ cookies }),
    getNumbering({ cookies }),
    fieldsForNew(cookies, 'Invoice')
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
    numbering,
    customFields
  };
};

export const actions: Actions = {
  /**
   * Create the draft. The page serialises the whole builder into one `payload`
   * field so the dynamic line-item list travels intact; the server owns org,
   * totals, number, token, and forces the status to Draft. On success we land on
   * the new invoice; on rejection the DRF field errors surface in the banner.
   *
   * Annotated so the refusal with `fieldErrors` is not folded into the bare one.
   */
  create: async ({
    cookies,
    request
  }): Promise<ActionFailure<{ error: string; fieldErrors?: Record<string, string> }>> => {
    const form = await request.formData();
    let parsed: unknown;
    try {
      parsed = JSON.parse(form.get('payload')?.toString() || '{}');
    } catch {
      parsed = null;
    }
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return fail(400, { error: 'The invoice form could not be read. Please try again.' });
    }
    const body = parsed as FormBody<Schemas['InvoiceBodyRequest']>;

    // Custom fields come from their own inputs, never from the builder's payload.
    delete body.custom_fields;
    const custom = await readCustomFields(cookies, 'Invoice', form);
    if (custom.refusal) return fail(503, custom.refusal);
    if (custom.values) body.custom_fields = custom.values;

    if (!body.account_id) return fail(400, { error: 'Choose an account.' });
    if (!body.contact_id) return fail(400, { error: 'Choose a contact.' });
    if (!Array.isArray(body.line_items) || body.line_items.length === 0) {
      return fail(400, { error: 'Add at least one line with a description and an amount.' });
    }

    let created;
    try {
      created = await createInvoice({ cookies }, body);
    } catch (err) {
      return fail(apiStatus(err) === 403 ? 403 : 400, {
        ...saveRefusal(err, custom.definitions, 'Could not create the invoice.')
      });
    }

    redirect(303, created?.id ? `/invoices/${created.id}` : '/invoices');
  }
};
