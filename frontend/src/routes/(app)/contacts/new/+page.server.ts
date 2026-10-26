import { fail, redirect } from '@sveltejs/kit';
import { EDITABLE_FIELDS, createContact, getContactFormOptions } from '#lib/server/v2/contacts.js';
import {
  fieldsForNew,
  readCustomFields,
  saveRefusal
} from '#lib/server/v2/record-custom-fields.js';
import type { Actions, PageServerLoad } from './$types';

/**
 * `?account=<id>` preselects the company, so "add somebody at this account"
 * arrives with the account already chosen. An id that is not one of this org's
 * accounts is dropped rather than trusted. The picker is built from the API's
 * own list, and the serializer checks the org again on save.
 */
export const load: PageServerLoad = async ({ cookies, url }) => {
  const [options, customFields] = await Promise.all([
    getContactFormOptions({ cookies }, url.searchParams.get('account')),
    fieldsForNew(cookies, 'Contact')
  ]);
  return { ...options, customFields };
};

export const actions: Actions = {
  create: async ({ cookies, request }) => {
    const form = await request.formData();

    const values: Record<string, string | boolean> = {};
    for (const field of EDITABLE_FIELDS) {
      if (field === 'do_not_call' || field === 'is_active') continue;
      if (form.has(field)) values[field] = form.get(field)?.toString().trim() ?? '';
    }
    values.do_not_call = form.get('do_not_call') === 'on';
    // On create there is nothing to preserve, so the owner is always sent,
    // including empty, which is how a contact is deliberately left unowned.
    values.assigned_to = form.get('assigned_to')?.toString().trim() ?? '';

    const custom = await readCustomFields(cookies, 'Contact', form);
    // The typed custom values ride with the scalars, so a refused save restores both.
    const submitted = { ...values, custom_fields: custom.values };
    if (custom.refusal) return fail(503, { values: submitted, ...custom.refusal });

    let created: Awaited<ReturnType<typeof createContact>> | undefined;
    try {
      created = await createContact({ cookies }, submitted);
    } catch (err) {
      return fail(400, {
        values: submitted,
        ...saveRefusal(err, custom.definitions, 'Could not create this contact.')
      });
    }

    // The API returns the new id. Landing on the person is the point of adding
    // one; landing back on the list makes you go and find them.
    redirect(303, created?.id ? `/contacts/${created.id}` : '/contacts');
  }
};
